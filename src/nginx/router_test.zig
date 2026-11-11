const std = @import("std");
const config = @import("config.zig");
const http = @import("http");
const Regex = http.regex.Regex;
const Addr = http.addr.Addr;
const Match = http.server.router.Match;
const findLocation = http.server.router.findLocation;
const selectServer = http.server.router.selectServer;
// ---------------------------------------------------------------- tests
const t = std.testing;
const Diag = http.diag.Diag;

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
