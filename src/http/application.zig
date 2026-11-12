//! Synchronous native handlers. Callbacks run on the event loop; do not block.
const std = @import("std");
const request = @import("request.zig");
pub const body = @import("body.zig");
pub const cookie = @import("cookie.zig");
pub const auth = @import("auth.zig");
pub const Handler = *const fn (*Context) anyerror!void;
pub const Middleware = *const fn (*Context, *Next) anyerror!void;
pub const Application = struct { handler: Handler, middleware: []const Middleware = &.{} };
pub const Response = struct { status: u16 = 200, content_type: ?[]const u8 = "text/plain", body: []const u8 = "", headers: std.ArrayList(request.Header) = .empty };
pub const Context = struct {
    allocator: std.mem.Allocator,
    request: *const request.Request,
    body: []const u8,
    now: i64,
    identity: ?auth.Identity = null,
    response: Response = .{},
    user_data: ?*anyopaque = null,
    pub fn query(c: *Context) ![]body.Field {
        return body.form(c.allocator, c.request.args);
    }
    pub fn json(c: *Context) !std.json.Value {
        if (!body.mediaType(c.request.header("content-type") orelse "", "application/json")) return error.UnsupportedMediaType;
        return body.json(c.allocator, c.body);
    }
    pub fn form(c: *Context) ![]body.Field {
        const ct = c.request.header("content-type") orelse "";
        if (body.mediaType(ct, "application/x-www-form-urlencoded")) return body.form(c.allocator, c.body);
        if (body.mediaType(ct, "multipart/form-data")) return body.multipart(c.allocator, ct, c.body);
        return error.UnsupportedMediaType;
    }
    pub fn getCookie(c: *Context, name: []const u8) ?[]const u8 {
        return cookie.read(c.request.header("cookie") orelse "", name);
    }
    pub fn setCookie(c: *Context, name: []const u8, value: []const u8, options: cookie.Options) !void {
        try c.addHeader("Set-Cookie", try cookie.serialize(c.allocator, name, value, options));
    }
    pub fn deleteCookie(c: *Context, name: []const u8, options: cookie.Options) !void {
        var opts = options;
        opts.max_age = 0;
        try c.setCookie(name, "", opts);
    }
    pub fn addHeader(c: *Context, name: []const u8, value: []const u8) !void {
        try validateHeader(name, value);
        if (c.response.headers.items.len >= 100) return error.TooManyHeaders;
        try c.response.headers.append(c.allocator, .{ .name = name, .value = value });
    }
    pub fn sendJson(c: *Context, status: u16, value: anytype) !void {
        c.response.status = status;
        c.response.content_type = "application/json";
        c.response.body = try std.json.Stringify.valueAlloc(c.allocator, value, .{});
    }
    pub fn redirect(c: *Context, status: u16, location: []const u8) !void {
        if (status != 301 and status != 302 and status != 303 and status != 307 and status != 308) return error.InvalidStatus;
        c.response.status = status;
        c.response.body = "";
        try c.addHeader("Location", location);
    }
};
pub fn validateHeader(name: []const u8, value: []const u8) !void {
    if (name.len == 0) return error.InvalidHeader;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", ch) == null) return error.InvalidHeader;
    for (value) |ch| if ((ch < 0x20 and ch != '\t') or ch == 0x7f) return error.InvalidHeader;
    for ([_][]const u8{ "Content-Length", "Transfer-Encoding", "Connection", "Content-Type", "Trailer", "Upgrade" }) |reserved| if (std.ascii.eqlIgnoreCase(name, reserved)) return error.ReservedHeader;
}
pub const Next = struct {
    app: Application,
    index: usize = 0,
    called: bool = false,
    /// Runtime hook at the handler boundary; middleware still executes on every request.
    terminal: ?struct { call: *const fn (*Context, ?*anyopaque) anyerror!void, data: ?*anyopaque } = null,
    pub fn run(n: *Next, ctx: *Context) anyerror!void {
        if (n.called) return error.NextCalledTwice;
        n.called = true;
        if (n.index == n.app.middleware.len) {
            if (n.terminal) |t| return t.call(ctx, t.data);
            return n.app.handler(ctx);
        }
        var next: Next = .{ .app = n.app, .index = n.index + 1, .terminal = n.terminal };
        return n.app.middleware[n.index](ctx, &next);
    }
};
pub fn run(app: Application, ctx: *Context) !void {
    var next: Next = .{ .app = app };
    try next.run(ctx);
}
pub fn errorStatus(err: anyerror) u16 {
    return switch (err) {
        error.BadRequest, error.TooManyFields => 400,
        error.Unauthorized => 401,
        error.Forbidden => 403,
        error.NotFound => 404,
        error.Conflict => 409,
        error.UnsupportedMediaType => 415,
        else => 500,
    };
}
test "middleware wraps handler in order and cannot call next twice" {
    const T = struct {
        fn before(c: *Context, n: *Next) !void {
            try c.addHeader("X-Before", "1");
            try n.run(c);
            try c.addHeader("X-After", "1");
        }
        fn handler(c: *Context) !void {
            try c.addHeader("X-Handler", "1");
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var req: request.Request = .{};
    var ctx: Context = .{ .allocator = arena.allocator(), .request = &req, .body = "", .now = 0 };
    var next: Next = .{ .app = .{ .handler = T.handler, .middleware = &.{T.before} } };
    try next.run(&ctx);
    try std.testing.expectEqualStrings("X-Handler", ctx.response.headers.items[1].name);
    try std.testing.expectEqualStrings("X-After", ctx.response.headers.items[2].name);
    try std.testing.expectError(error.NextCalledTwice, next.run(&ctx));
}

test {
    std.testing.refAllDecls(body);
    std.testing.refAllDecls(cookie);
    std.testing.refAllDecls(auth);
}

test "authorization middleware rejects before the replay/handler boundary" {
    const T = struct {
        fn reject(_: *Context, _: *Next) !void {
            return error.Forbidden;
        }
        fn handler(_: *Context) !void {
            return error.MustNotRun;
        }
        fn terminal(_: *Context, data: ?*anyopaque) !void {
            const called: *bool = @ptrCast(@alignCast(data.?));
            called.* = true;
        }
    };
    var called = false;
    var req: request.Request = .{};
    var ctx: Context = .{ .allocator = std.testing.allocator, .request = &req, .body = "", .now = 0 };
    var next: Next = .{ .app = .{ .handler = T.handler, .middleware = &.{T.reject} }, .terminal = .{ .call = T.terminal, .data = &called } };
    try std.testing.expectError(error.Forbidden, next.run(&ctx));
    try std.testing.expect(!called);
}
