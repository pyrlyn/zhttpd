const std = @import("std");
const Conn = @import("conn.zig").Conn;
const app = @import("../http/application.zig");
const handler = @import("handler.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
/// Per-worker, five-minute replay window. Full cache fails before executing the handler.
pub const ReplayCache = struct {
    pub const Entry = struct {
        arena: ?std.heap.ArenaAllocator = null,
        key: [32]u8 = undefined,
        fingerprint: [32]u8 = undefined,
        expires: i64 = 0,
        response: ?app.Response = null,
        started: bool = false,
        keep_middleware_headers: bool = true,
    };
    entries: [128]Entry = @splat(.{}),
    pub fn deinit(cache: *ReplayCache) void {
        for (&cache.entries) |*e| if (e.arena) |*a| a.deinit();
    }
    fn reserve(cache: *ReplayCache, allocator: std.mem.Allocator, now: i64, key: [32]u8, fingerprint: [32]u8) !*Entry {
        var free: ?*Entry = null;
        for (&cache.entries) |*entry| {
            if (entry.expires <= now) {
                if (entry.arena) |*a| a.deinit();
                entry.* = .{};
                if (free == null) free = entry;
            } else if (std.mem.eql(u8, &entry.key, &key)) {
                if (!std.mem.eql(u8, &entry.fingerprint, &fingerprint)) return error.Conflict;
                return entry;
            }
        }
        const entry = free orelse return error.CacheFull;
        entry.* = .{ .arena = std.heap.ArenaAllocator.init(allocator), .key = key, .fingerprint = fingerprint, .expires = now + 300_000 };
        return entry;
    }
};
fn hashPart(h: *Sha256, value: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, value.len, .little);
    h.update(&len);
    h.update(value);
}
fn prepare(cn: *Conn, identity: ?app.auth.Identity) !?*ReplayCache.Entry {
    if (!cn.ctx.conf.idempotency or cn.req.method == .GET or cn.req.method == .HEAD or cn.req.method == .OPTIONS) return null;
    const key = cn.req.header("idempotency-key") orelse return error.BadRequest;
    if (key.len == 0 or key.len > 128) return error.BadRequest;
    for (key) |ch| if (ch < 0x21 or ch > 0x7e) return error.BadRequest;
    var kh = Sha256.init(.{});
    hashPart(&kh, key);
    hashPart(&kh, cn.req.host orelse "");
    hashPart(&kh, cn.req.method_raw);
    hashPart(&kh, cn.ctx.uri);
    // Authenticated subjects never share results. Unauthenticated callers are scoped by peer IP.
    var peer: [64]u8 = undefined;
    hashPart(&kh, if (identity) |id| id.subject else cn.peer.formatIp(&peer));
    var scope = @intFromPtr(cn.ctx.conf);
    kh.update(std.mem.asBytes(&scope));
    var fh = Sha256.init(.{});
    hashPart(&fh, cn.req.target);
    hashPart(&fh, cn.body.items);
    var canonical: std.ArrayList(@import("../http/request.zig").Header) = .empty;
    for (cn.req.headers[0..cn.req.nheaders]) |h| {
        var skip = false;
        for ([_][]const u8{ "authorization", "connection", "content-length", "transfer-encoding", "idempotency-key", "host" }) |name| if (std.ascii.eqlIgnoreCase(h.name, name)) {
            skip = true;
        };
        if (identity == null and std.ascii.eqlIgnoreCase(h.name, "authorization")) skip = false;
        if (!skip) {
            try canonical.append(cn.appAllocator(), .{ .name = try std.ascii.allocLowerString(cn.appAllocator(), h.name), .value = h.value });
        }
    }
    std.mem.sort(@import("../http/request.zig").Header, canonical.items, {}, struct {
        fn less(_: void, a: @import("../http/request.zig").Header, b: @import("../http/request.zig").Header) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    for (canonical.items) |h| {
        hashPart(&fh, h.name);
        hashPart(&fh, h.value);
    }
    if (identity) |id| hashPart(&fh, id.scope);
    return cn.w.replays.reserve(cn.w.gpa, cn.w.now_ms, kh.finalResult(), fh.finalResult());
}
fn save(entry: *ReplayCache.Entry, response: app.Response) !void {
    // Retain a tombstone for oversized output instead of accidentally executing it twice.
    var size = response.body.len;
    for (response.headers.items) |h| size += h.name.len + h.value.len;
    if (size > 64 * 1024) return error.ResponseTooLarge;
    entry.response = try copyResponse(entry.arena.?.allocator(), response);
}
fn copyResponse(a: std.mem.Allocator, response: app.Response) !app.Response {
    var copy = response;
    copy.body = try a.dupe(u8, response.body);
    if (response.content_type) |ct| copy.content_type = try a.dupe(u8, ct);
    copy.headers = .empty;
    for (response.headers.items) |h| try copy.headers.append(a, .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) });
    return copy;
}
fn send(cn: *Conn, response: app.Response) void {
    var headers: std.Io.Writer.Allocating = .init(cn.appAllocator());
    for (response.headers.items) |h| headers.writer.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return handler.finalize(cn, 500);
    handler.writeSimple(cn, response.status, response.content_type, response.body, headers.written());
}
fn errorResponse(ctx: *app.Context, status: u16) !void {
    ctx.response = .{};
    try ctx.sendJson(status, .{ .@"error" = .{ .status = status, .message = @import("../http/response.zig").reason(status) } });
    if (status == 401) try ctx.addHeader("WWW-Authenticate", "Bearer");
}
fn invoke(ctx: *app.Context, runtime_data: ?*anyopaque) anyerror!void {
    const cn: *Conn = @ptrCast(@alignCast(runtime_data.?));
    const entry = prepare(cn, ctx.identity) catch |err| return errorResponse(ctx, if (err == error.BadRequest) 400 else if (err == error.Conflict) 409 else 503);
    if (entry) |e| {
        if (e.response) |response| {
            // Only replay the handler's result. Before/after middleware runs anew,
            // including authentication and authorization that may have changed.
            var headers = ctx.response.headers;
            ctx.response = try copyResponse(ctx.allocator, response);
            if (e.keep_middleware_headers) {
                try headers.appendSlice(ctx.allocator, ctx.response.headers.items);
                ctx.response.headers = headers;
            }
            try ctx.addHeader("Idempotency-Replayed", "true");
            return;
        }
        if (e.started) return errorResponse(ctx, 409);
        e.started = true;
    }
    const before = if (entry != null) try ctx.allocator.dupe(@import("../http/request.zig").Header, ctx.response.headers.items) else &.{};
    var keep_headers = true;
    cn.ctx.conf.application.?.handler(ctx) catch |err| {
        keep_headers = false;
        try errorResponse(ctx, app.errorStatus(err));
    };
    validate(ctx.response) catch {
        keep_headers = false;
        try errorResponse(ctx, 500);
    };
    if (entry) |e| {
        var result = ctx.response;
        // Middleware response headers are recomputed on each request, not cached.
        if (result.headers.items.len < before.len) keep_headers = false else {
            for (before, result.headers.items[0..before.len]) |old, current| {
                if (!std.mem.eql(u8, old.name, current.name) or !std.mem.eql(u8, old.value, current.value)) keep_headers = false;
            }
        }
        e.keep_middleware_headers = keep_headers;
        if (keep_headers) result.headers.items = result.headers.items[before.len..];
        result.headers.capacity = result.headers.items.len;
        save(e, result) catch {}; // bounded tombstone prevents repeated side effects on failure
    }
}
pub fn run(cn: *Conn) void {
    var ctx: app.Context = .{ .allocator = cn.appAllocator(), .request = &cn.req, .body = cn.body.items, .now = cn.w.wall_sec, .identity = cn.identity };
    var next: app.Next = .{ .app = cn.ctx.conf.application.?, .terminal = .{ .call = invoke, .data = cn } };
    next.run(&ctx) catch |err| {
        errorResponse(&ctx, app.errorStatus(err)) catch return handler.finalize(cn, 500);
    };
    validate(ctx.response) catch {
        errorResponse(&ctx, 500) catch return handler.finalize(cn, 500);
    };
    send(cn, ctx.response);
}

fn validate(response: app.Response) !void {
    if (response.status < 200 or response.status > 599) return error.InvalidStatus;
    if (response.content_type) |ct| for (ct) |ch| {
        if (ch < 0x20 or ch == 0x7f) return error.InvalidHeader;
    };
    var size: usize = 0;
    for (response.headers.items) |h| {
        try app.validateHeader(h.name, h.value);
        size +|= h.name.len + h.value.len + 4;
    }
    if (size > 12 * 1024) return error.TooManyHeaders;
}

test "replays own response memory, reject changed payload, and expire" {
    var cache: ReplayCache = .{};
    defer cache.deinit();
    const key: [32]u8 = @splat(1);
    const fingerprint: [32]u8 = @splat(2);
    const entry = try cache.reserve(std.testing.allocator, 100, key, fingerprint);
    entry.started = true;
    var original = [_]u8{ 'o', 'k' };
    try save(entry, .{ .status = 201, .body = &original });
    original[0] = 'X';
    const replay = try cache.reserve(std.testing.allocator, 200, key, fingerprint);
    try std.testing.expectEqualStrings("ok", replay.response.?.body);
    try std.testing.expectError(error.Conflict, cache.reserve(std.testing.allocator, 200, key, @as([32]u8, @splat(3))));
    const fresh = try cache.reserve(std.testing.allocator, 300100, key, fingerprint);
    try std.testing.expect(!fresh.started and fresh.response == null);
}
