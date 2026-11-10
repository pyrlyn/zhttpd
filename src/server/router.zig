//! Virtual server selection (Host / server_name) and location matching, in nginx order.
const std = @import("std");
const config = @import("../conf/config.zig");
const Regex = @import("../regex.zig").Regex;
const Location = config.Location;
const Server = config.Server;
const Addr = @import("../conf/addr.zig").Addr;

pub const Match = struct {
    loc: ?*Location,
    /// Captures of the matching regex location (for $1.. and named captures).
    caps: Regex.Captures = .{},
};

/// nginx ngx_http_core_find_location:
/// 1. exact (`=`) match wins immediately;
/// 2. the longest matching prefix is remembered; its nested locations are searched
///    recursively and a nested regex/exact result wins;
/// 3. if that prefix is `^~`, it is used without checking regexes;
/// 4. regex locations of this level are checked in config order, first match wins;
/// 5. otherwise the remembered prefix is used.
pub fn findLocation(locs: []const *Location, uri: []const u8) Match {
    var caps: Regex.Captures = .{};
    const loc = find(locs, uri, &caps);
    return .{ .loc = loc, .caps = caps };
}

fn find(locs: []const *Location, uri: []const u8, caps: *Regex.Captures) ?*Location {
    for (locs) |l| {
        if (l.kind == .exact and std.mem.eql(u8, l.name, uri)) return l;
    }
    var best: ?*Location = null;
    for (locs) |l| {
        if (l.kind != .prefix and l.kind != .prefix_noregex) continue;
        if (!std.mem.startsWith(u8, uri, l.name)) continue;
        if (best == null or l.name.len > best.?.name.len) best = l;
    }
    var result = best;
    if (best) |b| {
        if (b.children.len > 0) {
            if (find(b.children, uri, caps)) |r| {
                if (r.kind == .regex or r.kind == .regex_icase or r.kind == .exact) return r;
                result = r;
            }
        }
        if (b.kind == .prefix_noregex or result.?.kind == .prefix_noregex) return result;
    }
    for (locs) |l| {
        if (l.kind != .regex and l.kind != .regex_icase) continue;
        var c: Regex.Captures = .{};
        if (l.re.?.search(uri, &c) catch false) {
            caps.* = c;
            return l;
        }
    }
    return result;
}

pub fn findNamed(srv: *const Server, name: []const u8) ?*Location {
    for (srv.named) |l| if (std.mem.eql(u8, l.name, name)) return l;
    return null;
}

/// Pick the virtual server for `host` among those reachable through `listen` at `local`.
/// Order: exact name, longest leading wildcard, longest trailing wildcard, first regex,
/// then the default server of the address:port.
pub fn selectServer(listen: *const config.Listen, local: Addr, host_raw: ?[]const u8, caps: *Regex.Captures, host_buf: []u8) *Server {
    const host = normalizeHost(host_raw orelse return listen.defaultFor(local), host_buf) orelse return listen.defaultFor(local);
    var best_lead: ?*Server = null;
    var best_lead_len: usize = 0;
    var best_trail: ?*Server = null;
    var best_trail_len: usize = 0;
    var seen: [64]usize = undefined;
    var nseen: usize = 0;
    for (listen.entries) |e| {
        if (!(e.addr.isWildcard() or e.addr.sameHost(local))) continue;
        const s = e.server;
        // a server with several listen lines appears several times; check it once
        var dup = false;
        for (seen[0..nseen]) |x| {
            if (x == s.index) dup = true;
        }
        if (dup) continue;
        if (nseen < seen.len) {
            seen[nseen] = s.index;
            nseen += 1;
        }
        for (s.names) |n| switch (n) {
            .exact => |x| if (std.mem.eql(u8, x, host)) return s,
            .lead => |x| if (host.len > x.len and std.mem.endsWith(u8, host, x) and x.len > best_lead_len) {
                best_lead = s;
                best_lead_len = x.len;
            },
            .lead_dot => |x| if ((std.mem.eql(u8, host, x) or (host.len > x.len and std.mem.endsWith(u8, host, x) and host[host.len - x.len - 1] == '.')) and x.len + 1 > best_lead_len) {
                best_lead = s;
                best_lead_len = x.len + 1;
            },
            .trail => |x| if (host.len > x.len and std.mem.startsWith(u8, host, x) and x.len > best_trail_len) {
                best_trail = s;
                best_trail_len = x.len;
            },
            .re => {},
        };
    }
    if (best_lead) |s| return s;
    if (best_trail) |s| return s;
    for (listen.entries) |e| {
        if (!(e.addr.isWildcard() or e.addr.sameHost(local))) continue;
        for (e.server.names) |n| {
            if (n != .re) continue;
            var c: Regex.Captures = .{};
            if (n.re.search(host, &c) catch false) {
                caps.* = c;
                return e.server;
            }
        }
    }
    return listen.defaultFor(local);
}

/// Lowercase, strip the port and a trailing dot. Returns null for empty hosts.
pub fn normalizeHost(raw: []const u8, buf: []u8) ?[]const u8 {
    var h = raw;
    if (h.len > 0 and h[0] == '[') {
        const end = std.mem.indexOfScalar(u8, h, ']') orelse return null;
        h = h[0 .. end + 1];
    } else if (std.mem.lastIndexOfScalar(u8, h, ':')) |c| {
        h = h[0..c];
    }
    if (h.len > 0 and h[h.len - 1] == '.') h = h[0 .. h.len - 1];
    if (h.len == 0 or h.len > buf.len) return null;
    return std.ascii.lowerString(buf[0..h.len], h);
}

// ---------------------------------------------------------------- tests
const t = std.testing;
const Diag = @import("../conf/diag.zig").Diag;

fn locName(m: Match) []const u8 {
    const l = m.loc orelse return "<none>";
    return l.name;
}

test "location matching follows the nginx docs example" {
    var diag: Diag = .{ .gpa = t.allocator };
    defer diag.deinit();
    // https://nginx.org/en/docs/http/ngx_http_core_module.html#location
    const cfg = try config.loadString(t.allocator,
        \\http { server { listen 8080;
        \\  location = / { return 200 A; }
        \\  location / { return 200 B; }
        \\  location /documents/ { return 200 C; }
        \\  location ^~ /images/ { return 200 D; }
        \\  location ~* \.(gif|jpg|jpeg)$ { return 200 E; }
        \\} }
    , .{ .prefix = "/p", .conf_prefix = "/p" }, &diag);
    defer config.destroy(t.allocator, cfg);
    const locs = cfg.servers[0].locations;
    try t.expectEqualStrings("/", locName(findLocation(locs, "/")));
    try t.expectEqual(config.LocKind.exact, findLocation(locs, "/").loc.?.kind);
    try t.expectEqual(config.LocKind.prefix, findLocation(locs, "/index.html").loc.?.kind);
    try t.expectEqualStrings("/documents/", locName(findLocation(locs, "/documents/document.html")));
    try t.expectEqualStrings("/images/", locName(findLocation(locs, "/images/1.gif")));
    try t.expectEqualStrings("\\.(gif|jpg|jpeg)$", locName(findLocation(locs, "/documents/1.jpg")));
    try t.expectEqualStrings("\\.(gif|jpg|jpeg)$", locName(findLocation(locs, "/DOCUMENTS/1.JPG")));
}

test "nested locations, regex order, captures" {
    var diag: Diag = .{ .gpa = t.allocator };
    defer diag.deinit();
    const cfg = try config.loadString(t.allocator,
        \\http { server { listen 8080;
        \\  location /static/ {
        \\     location ~ \.css$ { return 200 nested-css; }
        \\     location /static/img/ { return 200 img; }
        \\  }
        \\  location ~ ^/u/(\d+)$ { return 200 user; }
        \\  location ~ ^/u/ { return 200 second; }
        \\  location ~ \.css$ { return 200 outer-css; }
        \\  location /x { }
        \\} }
    , .{ .prefix = "/p", .conf_prefix = "/p" }, &diag);
    defer config.destroy(t.allocator, cfg);
    const locs = cfg.servers[0].locations;
    try t.expectEqualStrings("\\.css$", locName(findLocation(locs, "/static/a.css")));
    try t.expectEqual(@as(usize, 0), findLocation(locs, "/static/a.css").loc.?.children.len);
    try t.expectEqualStrings("/static/img/", locName(findLocation(locs, "/static/img/a.png")));
    const m = findLocation(locs, "/u/42");
    try t.expectEqualStrings("^/u/(\\d+)$", locName(m));
    try t.expectEqualStrings("42", m.caps.group("/u/42", 1).?);
    try t.expectEqualStrings("^/u/", locName(findLocation(locs, "/u/abc")));
    try t.expectEqualStrings("/x", locName(findLocation(locs, "/xyz")));
    try t.expect(findLocation(locs, "/nothing").loc == null);
}

test "server_name selection" {
    var diag: Diag = .{ .gpa = t.allocator };
    defer diag.deinit();
    const cfg = try config.loadString(t.allocator,
        \\http {
        \\  server { listen 8080; server_name _; }
        \\  server { listen 8080 default_server; server_name default.test; }
        \\  server { listen 8080; server_name example.com www.example.com; }
        \\  server { listen 8080; server_name *.example.com; }
        \\  server { listen 8080; server_name .example.org; }
        \\  server { listen 8080; server_name mail.*; }
        \\  server { listen 8080; server_name ~^(?<user>[a-z]+)\.users\.test$; }
        \\}
    , .{ .prefix = "/p", .conf_prefix = "/p" }, &diag);
    defer config.destroy(t.allocator, cfg);
    const l = &cfg.listens[0];
    var caps: Regex.Captures = .{};
    var hb: [256]u8 = undefined;
    var local: Addr = .{ .port = 8080 };
    local.ip[0..4].* = .{ 127, 0, 0, 1 };
    try t.expectEqual(@as(usize, 2), selectServer(l, local, "Example.COM:8080", &caps, &hb).index);
    try t.expectEqual(@as(usize, 2), selectServer(l, local, "www.example.com.", &caps, &hb).index);
    try t.expectEqual(@as(usize, 3), selectServer(l, local, "a.b.example.com", &caps, &hb).index);
    try t.expectEqual(@as(usize, 4), selectServer(l, local, "example.org", &caps, &hb).index);
    try t.expectEqual(@as(usize, 4), selectServer(l, local, "x.example.org", &caps, &hb).index);
    try t.expectEqual(@as(usize, 5), selectServer(l, local, "mail.foo.net", &caps, &hb).index);
    try t.expectEqual(@as(usize, 6), selectServer(l, local, "ivan.users.test", &caps, &hb).index);
    try t.expectEqualStrings("ivan", caps.group("ivan.users.test", 1).?);
    try t.expectEqual(@as(usize, 1), selectServer(l, local, "unknown.net", &caps, &hb).index);
    try t.expectEqual(@as(usize, 1), selectServer(l, local, null, &caps, &hb).index);
}
