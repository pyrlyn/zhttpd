//! Request policies shared by static, configured responses and native applications.
const std = @import("std");
const Conn = @import("conn.zig").Conn;
const handler = @import("handler.zig");
const auth = @import("../http/auth.zig");
const config = @import("../http/config.zig");
pub fn methodAllowed(methods: []const []const u8, method: []const u8) bool {
    if (methods.len == 0) return true;
    for (methods) |m| if (std.mem.eql(u8, m, method) or (std.mem.eql(u8, method, "HEAD") and std.mem.eql(u8, m, "GET"))) return true;
    return false;
}
fn contains(values: []const []const u8, value: []const u8, insensitive: bool) bool {
    for (values) |v| if (if (insensitive) std.ascii.eqlIgnoreCase(v, value) else std.mem.eql(u8, v, value)) return true;
    return false;
}
fn origin(cn: *Conn) ?[]const u8 {
    const raw = cn.req.header("origin") orelse return null;
    const cors = cn.ctx.conf.cors;
    if (contains(cors.origins, raw, false)) return raw;
    if (!cors.credentials and contains(cors.origins, "*", false)) return "*";
    return null;
}
pub fn headers(cn: *Conn, w: *std.Io.Writer) !void {
    const cors = cn.ctx.conf.cors;
    if (cors.origins.len == 0) return;
    try w.writeAll("Vary: Origin\r\n");
    if (origin(cn)) |o| {
        try w.print("Access-Control-Allow-Origin: {s}\r\n", .{o});
        if (cors.credentials) try w.writeAll("Access-Control-Allow-Credentials: true\r\n");
        if (cn.req.method == .OPTIONS and cn.req.header("access-control-request-method") != null) {
            try w.writeAll("Vary: Access-Control-Request-Method, Access-Control-Request-Headers\r\nAccess-Control-Allow-Methods: ");
            for (cors.methods, 0..) |m, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(m);
            }
            try w.writeAll("\r\nAccess-Control-Allow-Headers: ");
            for (cors.headers, 0..) |h, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(h);
            }
            try w.print("\r\nAccess-Control-Max-Age: {d}\r\n", .{cors.max_age});
        }
    }
}
pub fn check(cn: *Conn) bool {
    const lc = cn.ctx.conf;
    if (lc.rate_limit > 0 and cn.rate_conf != lc) {
        var peer: [64]u8 = undefined;
        const key = std.hash.Wyhash.hash(@intFromPtr(lc), cn.peer.formatIp(&peer));
        if (!cn.w.rates.allow(key, cn.w.now_ms, lc.rate_limit, lc.rate_burst)) {
            handler.finalizeExtra(cn, 429, "Retry-After: 1\r\n");
            return false;
        }
        cn.rate_conf = lc;
    }
    if (lc.cors.origins.len > 0 and cn.req.header("origin") != null) {
        if (origin(cn) == null) {
            handler.finalize(cn, 403);
            return false;
        }
        if (cn.req.method == .OPTIONS) if (cn.req.header("access-control-request-method")) |method| {
            if (!contains(lc.cors.methods, method, false) or !methodAllowed(lc.methods, method)) {
                handler.finalize(cn, 403);
                return false;
            }
            var requested = std.mem.splitScalar(u8, cn.req.header("access-control-request-headers") orelse "", ',');
            while (requested.next()) |raw| {
                const h = std.mem.trim(u8, raw, " \t");
                if (h.len != 0 and !contains(lc.cors.headers, h, true)) {
                    handler.finalize(cn, 403);
                    return false;
                }
            }
            handler.writeSimple(cn, 204, null, "", "");
            return false;
        };
    }
    if (!methodAllowed(lc.methods, cn.req.method_raw)) {
        var out: std.Io.Writer.Allocating = .init(cn.arena());
        out.writer.writeAll("Allow: ") catch {};
        var methods: std.ArrayList([]const u8) = .empty;
        for (cn.ctx.srv.locations) |loc| {
            const current = cn.ctx.loc orelse continue;
            if (loc.kind != current.kind or !std.mem.eql(u8, loc.name, current.name)) continue;
            for (loc.conf.methods) |m| if (!contains(methods.items, m, false)) {
                methods.append(cn.arena(), m) catch {};
            };
        }
        if (methods.items.len == 0) methods.appendSlice(cn.arena(), lc.methods) catch {};
        if (contains(methods.items, "GET", false) and !contains(methods.items, "HEAD", false)) methods.append(cn.arena(), "HEAD") catch {};
        for (methods.items, 0..) |m, i| {
            if (i > 0) out.writer.writeAll(", ") catch {};
            out.writer.writeAll(m) catch {};
        }
        out.writer.writeAll("\r\n") catch {};
        handler.finalizeExtra(cn, 405, out.written());
        return false;
    }
    if (lc.jwt) |jwt| {
        var authorization_count: usize = 0;
        for (cn.req.headers[0..cn.req.nheaders]) |h| if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            authorization_count += 1;
        };
        if (authorization_count != 1) {
            handler.finalizeExtra(cn, 401, "WWW-Authenticate: Bearer\r\n");
            return false;
        }
        const value = cn.req.header("authorization") orelse "";
        if (value.len < 7 or !std.ascii.eqlIgnoreCase(value[0..7], "Bearer ")) {
            handler.finalizeExtra(cn, 401, "WWW-Authenticate: Bearer\r\n");
            return false;
        }
        cn.identity = auth.verify(cn.appAllocator(), value[7..], jwt, cn.w.wall_sec) catch |err| {
            handler.finalizeExtra(cn, if (err == error.Forbidden) 403 else if (err == error.OutOfMemory or err == error.InvalidAuthPolicy) 500 else 401, "WWW-Authenticate: Bearer\r\n");
            return false;
        };
    }
    if (lc.health) {
        handler.writeSimple(cn, 200, "application/json", "{\"status\":\"ok\"}\n", "Cache-Control: no-store\r\n");
        return false;
    }
    return true;
}
/// Bounded token buckets. Colliding active peers are rejected, never evicted.
pub const Rates = struct {
    const Bucket = struct { key: u64 = 0, time: i64 = 0, credit: u64 = 0, rate: u32 = 0, capacity: u64 = 0, used: bool = false };
    buckets: [4096]Bucket = @splat(.{}),
    pub fn allow(r: *Rates, key: u64, now: i64, rate: u32, burst: u32) bool {
        const b = &r.buckets[key % r.buckets.len];
        const cap = @as(u64, @max(1, burst)) * 1000;
        const elapsed: u64 = @intCast(@max(0, now - b.time));
        const credit = @min(b.capacity, b.credit +| (elapsed *| b.rate));
        if (b.used and b.key != key and credit < b.capacity) return false;
        b.credit = if (!b.used or b.key != key) cap else credit;
        b.time = now;
        b.rate = rate;
        b.capacity = cap;
        b.key = key;
        b.used = true;
        if (b.credit < 1000) return false;
        b.credit -= 1000;
        return true;
    }
};
test "rate refill, burst and collisions cannot bypass quota" {
    var rates: Rates = .{};
    try std.testing.expect(rates.allow(1, 1000, 2, 2));
    try std.testing.expect(!rates.allow(4097, 1000, 1000000, 1));
    try std.testing.expect(rates.allow(1, 1000, 2, 2));
    try std.testing.expect(!rates.allow(1, 1000, 2, 2));
    try std.testing.expect(!rates.allow(4097, 1000, 2, 2));
    try std.testing.expect(rates.allow(1, 1500, 2, 2));
}

pub fn validate(lc: *const config.LocConf) !void {
    if (lc.idempotency and lc.application == null) return error.IdempotencyRequiresNativeHandler;
    if (lc.rate_burst == 0 or lc.rate_burst > 1000000 or lc.rate_limit > 1000000) return error.InvalidRateLimit;
    if (lc.jwt) |jwt| if (jwt.secret.len < 32 or jwt.issuer.len == 0 or jwt.audience.len == 0) return error.InvalidAuthPolicy;
    for (lc.cors.origins) |value| {
        if (value.len == 0) return error.InvalidCors;
        if (lc.cors.credentials and std.mem.eql(u8, value, "*")) return error.InvalidCors;
        for (value) |ch| if (ch < 0x21 or ch > 0x7e) return error.InvalidCors;
    }
    for ([_][]const []const u8{ lc.cors.methods, lc.cors.headers }) |values| for (values) |value| {
        if (value.len == 0) return error.InvalidCors;
        for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return error.InvalidCors;
    };
}
pub fn validateLocations(locs: []const *config.Location) !void {
    for (locs) |loc| {
        try validate(loc.conf);
        try validateLocations(loc.children);
    }
}
