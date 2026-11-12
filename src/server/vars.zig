//! Evaluation of nginx variables / complex values for one request.
const std = @import("std");
const expr = @import("expression");
const config = @import("../http/config.zig");
const Regex = @import("../regex.zig").Regex;
const Request = @import("../http/request.zig").Request;
const response = @import("../http/response.zig");
const Addr = @import("../http/addr.zig").Addr;
const os = @import("../os.zig");

pub const version = "0.1.0";

pub const SetVar = struct { name: []const u8, value: []const u8 };

/// Per-request state that variables read. Owned by the connection, reset per request.
pub const Ctx = struct {
    srv: *config.Server,
    loc: ?*config.Location = null,
    conf: *config.LocConf,
    cfg: *const config.Config,
    req: *const Request,
    uri: []const u8 = "",
    args: []const u8 = "",
    /// Captures of the last regex that matched (location, rewrite, if) and their subject.
    caps: Regex.Captures = .{},
    caps_subject: []const u8 = "",
    caps_re: ?*const Regex = null,
    /// server_name regex captures (named ones become variables)
    host_caps: Regex.Captures = .{},
    host_subject: []const u8 = "",
    host_re: ?*const Regex = null,
    set_vars: [16]SetVar = undefined,
    nset: usize = 0,
    internal: bool = false,
    error_page_done: bool = false,
    redirects: u8 = 0,
    status: u16 = 0,
    method_override_get: bool = false,
    request_filename: []const u8 = "",
    document_root: []const u8 = "",
    upstream_addr: []const u8 = "",
    proxy_host: []const u8 = "", // per-request value when proxy_pass has variables
    upstream_status: u16 = 0,
    // connection facts
    scheme_https: bool = false,
    stream_protocol: u8 = 0,
    local: Addr = .{},
    peer: Addr = .{},
    conn_id: u64 = 0,
    conn_requests: u32 = 0,
    request_length: usize = 0,
    body: []const u8 = "",
    start_ms: i64 = 0,
    now_ms: i64 = 0,
    wall_sec: i64 = 0,
    wall_usec: i64 = 0,
    gmtoff: i64 = 0,
    bytes_sent: u64 = 0,
    body_bytes_sent: u64 = 0,
    sent_headers: []const u8 = "", // raw response head for $sent_http_*

    pub fn setVar(c: *Ctx, name: []const u8, value: []const u8) void {
        for (c.set_vars[0..c.nset]) |*v| {
            if (std.mem.eql(u8, v.name, name)) {
                v.value = value;
                return;
            }
        }
        if (c.nset < c.set_vars.len) {
            c.set_vars[c.nset] = .{ .name = name, .value = value };
            c.nset += 1;
        }
    }
};

pub const Error = error{OutOfMemory};

/// Evaluate `e` into a new arena string.
pub fn eval(a: std.mem.Allocator, c: *Ctx, e: expr.Expr) Error![]const u8 {
    if (e.isLiteral()) return e.literal();
    var out: std.ArrayList(u8) = .empty;
    try evalInto(a, c, e, &out);
    return out.items;
}

pub fn evalInto(a: std.mem.Allocator, c: *Ctx, e: expr.Expr, out: *std.ArrayList(u8)) Error!void {
    for (e.parts) |p| switch (p) {
        .lit => |l| try out.appendSlice(a, l),
        .v => |v| try appendVar(a, c, v, out, 0),
    };
}

/// Value of a variable or null when it is "not found" (nginx prints "" or "-" in logs).
pub fn appendVar(a: std.mem.Allocator, c: *Ctx, v: expr.Var, out: *std.ArrayList(u8), depth: u8) Error!void {
    var nb: [64]u8 = undefined;
    const r = c.req;
    const s: []const u8 = switch (v) {
        .uri => c.uri,
        .request_uri => r.target,
        .args => c.args,
        .is_args => if (c.args.len > 0) "?" else "",
        .request_method => if (c.method_override_get) "GET" else r.method_raw,
        .request => if (c.stream_protocol != 0) try std.fmt.allocPrint(a, "{s} {s} HTTP/{d}.0", .{ r.method_raw, r.target, c.stream_protocol }) else r.line,
        .server_protocol => if (c.stream_protocol == 2) "HTTP/2.0" else if (c.stream_protocol == 3) "HTTP/3.0" else if (r.version == .http10) "HTTP/1.0" else "HTTP/1.1",
        .scheme => if (c.scheme_https) "https" else "http",
        .https => if (c.scheme_https) "on" else "",
        .host => blk: {
            if (r.host) |h| {
                var hb: [256]u8 = undefined;
                const rt = @import("router.zig");
                if (rt.normalizeHost(h, &hb)) |n| break :blk try a.dupe(u8, n);
            }
            break :blk c.srv.primary_name;
        },
        .hostname => hostname(),
        .server_name => c.srv.primary_name,
        .server_addr => try a.dupe(u8, c.local.formatIp(&nb)),
        .server_port => try std.fmt.allocPrint(a, "{d}", .{c.local.port}),
        .remote_addr => try a.dupe(u8, c.peer.formatIp(&nb)),
        .remote_port => try std.fmt.allocPrint(a, "{d}", .{c.peer.port}),
        .document_root => c.document_root,
        .realpath_root => c.document_root,
        .request_filename => c.request_filename,
        .fastcgi_script_name => if (std.mem.endsWith(u8, c.uri, "/")) try std.fmt.allocPrint(a, "{s}{s}", .{ c.uri, c.conf.fastcgi_index }) else c.uri,
        .content_type => r.header("content-type") orelse "",
        .content_length => r.header("content-length") orelse "",
        .request_length => try std.fmt.allocPrint(a, "{d}", .{c.request_length}),
        .status => try std.fmt.allocPrint(a, "{d:0>3}", .{c.status}),
        .body_bytes_sent => try std.fmt.allocPrint(a, "{d}", .{c.body_bytes_sent}),
        .bytes_sent => try std.fmt.allocPrint(a, "{d}", .{c.bytes_sent}),
        .request_time => blk: {
            const ms: u64 = @intCast(@max(0, c.now_ms - c.start_ms));
            break :blk try std.fmt.allocPrint(a, "{d}.{d:0>3}", .{ ms / 1000, ms % 1000 });
        },
        .time_local => blk: {
            var b: [26]u8 = undefined;
            break :blk try a.dupe(u8, response.logDate(&b, c.wall_sec, c.gmtoff));
        },
        .time_iso8601 => blk: {
            const cv = response.civil(c.wall_sec + c.gmtoff);
            const off: u64 = @abs(c.gmtoff);
            break :blk try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(cv.year)), cv.month, cv.day, cv.hour, cv.min, cv.sec, @as(u8, if (c.gmtoff < 0) '-' else '+'), off / 3600, off / 60 % 60 });
        },
        .msec => try std.fmt.allocPrint(a, "{d}.{d:0>3}", .{ c.wall_sec, @divTrunc(c.wall_usec, 1000) }),
        .connection => try std.fmt.allocPrint(a, "{d}", .{c.conn_id}),
        .connection_requests => try std.fmt.allocPrint(a, "{d}", .{c.conn_requests}),
        .pid => try std.fmt.allocPrint(a, "{d}", .{std.c.getpid()}),
        .nginx_version => version,
        .proxy_host => if (c.proxy_host.len > 0) c.proxy_host else if (c.conf.proxy) |p| p.host else "",
        .proxy_port => if (c.conf.proxy) |p| try std.fmt.allocPrint(a, "{d}", .{p.port}) else "",
        .proxy_add_x_forwarded_for => blk: {
            const ip = c.peer.formatIp(&nb);
            if (r.header("x-forwarded-for")) |xff| break :blk try std.fmt.allocPrint(a, "{s}, {s}", .{ xff, ip });
            break :blk try a.dupe(u8, ip);
        },
        .upstream_addr => c.upstream_addr,
        .upstream_status => if (c.upstream_status != 0) try std.fmt.allocPrint(a, "{d}", .{c.upstream_status}) else "",
        .http => |name| r.headerVar(name) orelse "",
        .sent_http => |name| sentHeader(c.sent_headers, name) orelse "",
        .arg => |name| argValue(c.args, name) orelse "",
        .cookie => |name| cookieValue(r.header("cookie") orelse "", name) orelse "",
        .capture => |n| blk: {
            if (c.caps.group(c.caps_subject, n)) |g| break :blk g;
            break :blk "";
        },
        .named => |name| try named(a, c, name, depth),
    };
    try out.appendSlice(a, s);
}

fn named(a: std.mem.Allocator, c: *Ctx, name: []const u8, depth: u8) Error![]const u8 {
    for (c.set_vars[0..c.nset]) |v| {
        if (std.mem.eql(u8, v.name, name)) return v.value;
    }
    if (c.caps_re) |re| {
        for (re.names) |n| if (std.mem.eql(u8, n.name, name)) return c.caps.group(c.caps_subject, n.group) orelse "";
    }
    if (c.host_re) |re| {
        for (re.names) |n| if (std.mem.eql(u8, n.name, name)) return c.host_caps.group(c.host_subject, n.group) orelse "";
    }
    if (std.mem.eql(u8, name, "request_body")) return c.body;
    if (std.mem.eql(u8, name, "remote_user")) return "";
    if (c.cfg.findMap(name)) |m| {
        if (depth > 8) return "";
        return evalMap(a, c, m, depth + 1);
    }
    return "";
}

fn evalMap(a: std.mem.Allocator, c: *Ctx, m: *const config.Map, depth: u8) Error![]const u8 {
    var src: std.ArrayList(u8) = .empty;
    for (m.source.parts) |p| switch (p) {
        .lit => |l| try src.appendSlice(a, l),
        .v => |v| try appendVar(a, c, v, &src, depth),
    };
    var key = src.items;
    if (m.hostnames) key = std.ascii.lowerString(key, key);
    if (m.exact.get(key)) |val| return evalDepth(a, c, val, depth);
    for (m.regexes) |r| {
        var caps: Regex.Captures = .{};
        if (r.re.search(key, &caps) catch false) {
            const saved = .{ c.caps, c.caps_subject, c.caps_re };
            c.caps = caps;
            c.caps_subject = key;
            c.caps_re = r.re;
            const v = try evalDepth(a, c, r.value, depth);
            c.caps, c.caps_subject, c.caps_re = saved;
            return v;
        }
    }
    return evalDepth(a, c, m.default, depth);
}

fn evalDepth(a: std.mem.Allocator, c: *Ctx, e: expr.Expr, depth: u8) Error![]const u8 {
    if (e.isLiteral()) return e.literal();
    var out: std.ArrayList(u8) = .empty;
    for (e.parts) |p| switch (p) {
        .lit => |l| try out.appendSlice(a, l),
        .v => |v| try appendVar(a, c, v, &out, depth),
    };
    return out.items;
}

pub fn argValue(args: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, args, '&');
    while (it.next()) |kv| {
        const eqi = std.mem.indexOfScalar(u8, kv, '=') orelse kv.len;
        if (std.ascii.eqlIgnoreCase(kv[0..eqi], name)) return if (eqi < kv.len) kv[eqi + 1 ..] else "";
    }
    return null;
}

pub fn cookieValue(cookies: []const u8, name: []const u8) ?[]const u8 {
    return @import("../http/cookie.zig").read(cookies, name);
}

fn sentHeader(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next();
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const hn = line[0..colon];
        if (hn.len != name.len) continue;
        var ok = true;
        for (hn, name) |x, y| {
            const yy = if (y == '_') '-' else y;
            if (std.ascii.toLower(x) != std.ascii.toLower(yy)) ok = false;
        }
        if (ok) return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

var hostname_buf: [256]u8 = undefined;
var hostname_len: usize = 0;

pub fn hostname() []const u8 {
    if (hostname_len == 0) {
        if (std.c.gethostname(&hostname_buf, hostname_buf.len) == 0) {
            hostname_len = std.mem.indexOfScalar(u8, &hostname_buf, 0) orelse hostname_buf.len;
        }
    }
    return hostname_buf[0..hostname_len];
}

test "arg and cookie lookup" {
    try std.testing.expectEqualStrings("2", argValue("a=1&b=2", "b").?);
    try std.testing.expect(argValue("a=1", "c") == null);
    try std.testing.expectEqualStrings("xyz", cookieValue("s=1; sid=xyz", "sid").?);
}
