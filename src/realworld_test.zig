//! Parser/semantic tests on real-world configurations (tests/fixtures):
//! the default nginx.conf + mime.types from the nginx 1.30.6 tarball and a
//! Debian-style layout (conf.d/, sites-enabled/ symlinks, snippets, certbot options).
const std = @import("std");
const config = @import("conf/config.zig");
const Diag = @import("conf/diag.zig").Diag;
const router = @import("server/router.zig");
const tst = std.testing;

fn load(path: []const u8, diag: *Diag) !*config.Config {
    var buf: [4096]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse return error.Cwd;
    const abs = try std.fmt.allocPrint(tst.allocator, "{s}/{s}", .{ std.mem.sliceTo(cwd, 0), path });
    defer tst.allocator.free(abs);
    const dir = std.fs.path.dirname(abs).?;
    const conf_prefix = try std.fmt.allocPrint(tst.allocator, "{s}/", .{dir});
    defer tst.allocator.free(conf_prefix);
    const cfg = try config.load(tst.allocator, try tst.allocator.dupe(u8, abs), .{ .prefix = "/tmp/zhttpd-test/", .conf_prefix = conf_prefix, .quiet_ignored = true }, diag);
    return cfg;
}

test "nginx tarball default nginx.conf and mime.types" {
    var diag: Diag = .{ .gpa = tst.allocator };
    defer diag.deinit();
    const cfg = try load("tests/fixtures/nginx-default/nginx.conf", &diag);
    defer {
        tst.allocator.free(cfg.conf_file);
        config.destroy(tst.allocator, cfg);
    }
    try tst.expectEqual(@as(usize, 0), diag.count(.emerg));
    try tst.expectEqual(@as(u32, 1024), cfg.worker_connections);
    try tst.expectEqual(@as(usize, 1), cfg.servers.len);
    const srv = cfg.servers[0];
    try tst.expectEqualStrings("localhost", srv.primary_name);
    try tst.expectEqual(@as(u16, 80), cfg.listens[0].addr.port);
    // mime.types was included: .html -> text/html, .woff2 -> font/woff2
    try tst.expectEqualStrings("text/html", srv.conf.types.get("html").?);
    try tst.expectEqualStrings("font/woff2", srv.conf.types.get("woff2").?);
    try tst.expectEqualStrings("application/octet-stream", srv.conf.default_type);
    try tst.expect(srv.conf.sendfile);
    try tst.expectEqual(@as(u32, 65_000), srv.conf.keepalive_timeout_ms);
    // error_page 500 502 503 504 /50x.html inside the server
    try tst.expect(srv.conf.error_pages.len >= 1);
    const m = router.findLocation(srv.locations, "/50x.html");
    try tst.expectEqual(config.LocKind.exact, m.loc.?.kind);
    const root = router.findLocation(srv.locations, "/index.html");
    try tst.expectEqualStrings("/", root.loc.?.name);
}

test "Debian sites-enabled layout" {
    var diag: Diag = .{ .gpa = tst.allocator };
    defer diag.deinit();
    const cfg = try load("tests/fixtures/debian/nginx.conf", &diag);
    defer {
        tst.allocator.free(cfg.conf_file);
        config.destroy(tst.allocator, cfg);
    }
    try tst.expectEqual(@as(usize, 0), diag.count(.emerg));
    // default + example.com (redirect) + example.com (ssl)
    try tst.expectEqual(@as(usize, 3), cfg.servers.len);
    try tst.expectEqual(@as(u32, 768), cfg.worker_connections);
    // listens: 0.0.0.0:80, [::]:80, 0.0.0.0:443 ssl, [::]:443 ssl
    try tst.expectEqual(@as(usize, 4), cfg.listens.len);
    var ssl_count: usize = 0;
    for (cfg.listens) |l| {
        if (l.opts.ssl) ssl_count += 1;
    }
    try tst.expectEqual(@as(usize, 2), ssl_count);
    const site = cfg.servers[2];
    try tst.expectEqual(@as(u64, 20 * 1024 * 1024), site.conf.client_max_body_size);
    try tst.expectEqual(config.SessionCache.builtin, site.tls.session_cache);
    try tst.expect(!site.tls.session_tickets);
    // location selection, nginx order
    try tst.expectEqualStrings("/static/", router.findLocation(site.locations, "/static/app.css").loc.?.name); // ^~ beats regex
    try tst.expectEqual(config.LocKind.regex_icase, router.findLocation(site.locations, "/img/logo.PNG").loc.?.kind);
    try tst.expectEqual(config.LocKind.exact, router.findLocation(site.locations, "/healthz").loc.?.kind);
    try tst.expectEqualStrings("/admin/", router.findLocation(site.locations, "/admin/users").loc.?.name);
    try tst.expectEqualStrings("/", router.findLocation(site.locations, "/about").loc.?.name);
    try tst.expect(router.findNamed(site, "@app") != null);
    const admin = router.findLocation(site.locations, "/admin/").loc.?;
    try tst.expectEqual(@as(usize, 3), admin.conf.access.len);
    // the PHP location in the default server answers 502 (FastCGI is not implemented)
    const php = router.findLocation(cfg.servers[0].locations, "/index.php").loc.?;
    try tst.expect(php.conf.unsupported_handler != null);
    // map from conf.d
    try tst.expect(cfg.findMap("connection_upgrade") != null);
}
