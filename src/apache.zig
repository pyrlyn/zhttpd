//! Apache HTTP Server configuration adapter. Lowers supported directives
//! directly to http.config.Config; never runs Apache or loads its modules.
const std = @import("std");
const support = @import("settings");
const http = @import("http");
const B = support.Builder;
const Node = support.Node;
const Error = support.Error;
const C = http.config;
const eq = support.eql;
pub const Options = struct { server_root: []const u8, sources: ?*http.config_watch.Sources = null };
pub const destroy = support.destroy;

pub fn load(gpa: std.mem.Allocator, file: []const u8, opts: Options, diag: *http.diag.Diag) Error!*C.Config {
    var b = try B.init(gpa, file, opts.server_root, diag);
    errdefer destroy(gpa, b.cfg);
    b.sources = opts.sources;
    const nodes = try expand(&b, try b.read(file, .apache), 0);
    try build(&b, nodes);
    return b.cfg;
}
pub fn loadString(gpa: std.mem.Allocator, text: []const u8, opts: Options, diag: *http.diag.Diag) Error!*C.Config {
    var b = try B.init(gpa, "httpd.conf", opts.server_root, diag);
    errdefer destroy(gpa, b.cfg);
    b.sources = opts.sources;
    const owned = try b.a.dupe(u8, text);
    try build(&b, try expand(&b, try b.parse(owned, "httpd.conf", .apache), 0));
    return b.cfg;
}
fn expand(b: *B, nodes: []Node, depth: u8) Error![]Node {
    if (depth > 16) return error.ConfigFailed;
    var out: std.ArrayList(Node) = .empty;
    for (nodes) |n| {
        if (eq(n.name, "ServerRoot")) {
            try b.arity(n, 1, 1);
            b.cfg.prefix = try b.fullPath(b.cfg.prefix, n.args[0]);
        }
        if (eq(n.name, "Include") or eq(n.name, "IncludeOptional")) {
            try b.arity(n, 1, 1);
            const path = try b.fullPath(b.cfg.prefix, n.args[0]);
            if (b.sources) |sources| try sources.observe(path, if (http.os.hasGlob(path)) .glob else .file);
            const paths: []const []const u8 = if (http.os.hasGlob(path)) try http.os.glob(b.a, path) else try b.a.dupe([]const u8, &.{path});
            if (paths.len == 0 and eq(n.name, "Include")) return b.fail(n, "Include matches no files", .{});
            for (paths) |p| {
                if (eq(n.name, "IncludeOptional")) {
                    const z = try b.a.dupeSentinel(u8, p, 0);
                    if (std.c.access(z, 0) != 0) continue;
                }
                const included = try expand(b, try b.read(p, .apache), depth + 1);
                try out.appendSlice(b.a, included);
            }
        } else try out.append(b.a, n);
    }
    return out.toOwnedSlice(b.a);
}
fn local(b: *B, lc: *C.LocConf, n: Node) Error!void {
    if (n.children != null) return b.fail(n, "unsupported nested Apache section {s}", .{n.name});
    if (eq(n.name, "DocumentRoot")) {
        try b.arity(n, 1, 1);
        lc.root = try b.literal(try b.fullPath(b.cfg.prefix, n.args[0]));
    } else if (eq(n.name, "DirectoryIndex")) {
        try b.arity(n, 1, 32);
        try b.indexes(lc, n.args);
    } else if (eq(n.name, "Require")) {
        try b.arity(n, 2, 32);
        if (eq(n.args[0], "all") and n.args.len == 2 and (eq(n.args[1], "granted") or eq(n.args[1], "denied"))) {
            lc.access = try b.a.dupe(C.AccessRule, &.{.{ .allow = eq(n.args[1], "granted"), .all = true }});
        } else if (eq(n.args[0], "ip")) {
            var rules: std.ArrayList(C.AccessRule) = .empty;
            for (n.args[1..]) |ip| try rules.append(b.a, .{ .allow = true, .all = false, .cidr = http.addr.Cidr.parse(ip) orelse return b.fail(n, "invalid Require ip address", .{}) });
            try rules.append(b.a, .{ .allow = false, .all = true });
            lc.access = try rules.toOwnedSlice(b.a);
        } else return b.fail(n, "unsupported authorization rule (not ignored)", .{});
    } else if (eq(n.name, "Options")) {
        try b.arity(n, 1, 16);
        for (n.args) |v| {
            if (eq(v, "Indexes") or eq(v, "+Indexes")) lc.autoindex = true else if (eq(v, "-Indexes")) lc.autoindex = false else if (eq(v, "FollowSymLinks") or eq(v, "+FollowSymLinks")) {} else return b.fail(n, "unsupported Options value {s}", .{v});
        }
    } else if (eq(n.name, "AllowOverride")) {
        try b.arity(n, 1, 1);
        if (!eq(n.args[0], "None")) return b.fail(n, ".htaccess overrides are not supported", .{});
    } else if (eq(n.name, "LimitRequestBody")) {
        try b.arity(n, 1, 1);
        lc.client_max_body_size = try b.number(n, n.args[0]);
    } else if (eq(n.name, "EnableSendfile")) {
        try b.arity(n, 1, 1);
        lc.sendfile = try b.flag(n, n.args[0]);
    } else if (eq(n.name, "KeepAlive")) {
        try b.arity(n, 1, 1);
        lc.keepalive_timeout_ms = if (try b.flag(n, n.args[0])) 5000 else 0;
    } else if (eq(n.name, "KeepAliveTimeout")) {
        try b.arity(n, 1, 1);
        lc.keepalive_timeout_ms = std.math.mul(u32, try b.number(n, n.args[0]), 1000) catch return b.fail(n, "timeout overflow", .{});
    } else if (eq(n.name, "MaxKeepAliveRequests")) {
        try b.arity(n, 1, 1);
        const value = try b.number(n, n.args[0]);
        lc.keepalive_requests = if (value == 0) std.math.maxInt(u32) else value;
    } else return b.fail(n, "unsupported Apache directive {s}", .{n.name});
}
fn server(b: *B, s: *C.Server, nodes: []Node, secure: *bool) Error!void {
    // Formats are registered before CustomLog regardless of source order.
    for (nodes) |n| if (eq(n.name, "LogFormat")) {
        try b.arity(n, 2, 2);
        const f = try b.logFormat(n, n.args[1], try b.apacheFormat(n, n.args[0]), .default);
        b.cfg.log_formats = try support.append(b.a, *C.LogFormat, b.cfg.log_formats, f);
    };
    var own_logs = false;
    for (nodes) |n| {
        if (eq(n.name, "LogFormat")) continue;
        if (eq(n.name, "CustomLog") or eq(n.name, "TransferLog")) {
            const custom = eq(n.name, "CustomLog");
            try b.arity(n, if (custom) 2 else 1, if (custom) 2 else 1);
            var text: []const u8 = http.logging.common;
            if (custom) {
                const value = n.args[1];
                if (eq(value, "combined")) text = http.logging.combined else if (eq(value, "common")) {} else {
                    var found = false;
                    for (b.cfg.log_formats) |f| if (eq(f.name, value)) {
                        text = f.expr.raw;
                        found = true;
                    };
                    if (!found) {
                        if (std.mem.indexOfScalar(u8, value, '%') == null) return b.fail(n, "unknown log format nickname {s}", .{value});
                        text = try b.apacheFormat(n, value);
                    }
                }
            }
            if (!own_logs) {
                s.conf.access_logs = null;
                own_logs = true;
            }
            try b.accessLog(s.conf, n, n.args[0], try b.logFormat(n, "apache", text, .default));
            continue;
        }
        if (eq(n.name, "LogLevel")) {
            try b.arity(n, 1, 1);
            const level = http.logging.level(n.args[0]) orelse return b.fail(n, "unsupported log level", .{});
            var el = s.conf.error_log orelse b.cfg.error_log;
            el.level = level;
            s.conf.error_log = el;
            continue;
        }
        if (eq(n.name, "VirtualHost") or eq(n.name, "Listen") or eq(n.name, "ServerRoot")) continue;
        if (n.children != null) continue;
        if (eq(n.name, "ServerName") or eq(n.name, "ServerAlias")) {
            try b.arity(n, 1, 32);
            if (eq(n.name, "ServerName")) {
                s.names = &.{};
                s.primary_name = "";
            }
            for (n.args) |name| try b.name(s, name);
        } else if (eq(n.name, "SSLEngine")) {
            try b.arity(n, 1, 1);
            secure.* = try b.flag(n, n.args[0]);
        } else if (eq(n.name, "SSLCertificateFile") or eq(n.name, "SSLCertificateKeyFile")) {
            try b.arity(n, 1, 1);
            const path = try b.fullPath(b.cfg.prefix, n.args[0]);
            if (eq(n.name, "SSLCertificateFile")) s.tls.certificate = path else s.tls.certificate_key = path;
        } else if (eq(n.name, "Protocols")) {
            try b.arity(n, 1, 3);
            var h1 = false;
            for (n.args) |v| {
                if (eq(v, "h2")) s.http2 = true else if (eq(v, "http/1.1")) h1 = true else return b.fail(n, "unsupported protocol {s}", .{v});
            }
            if (!h1) return b.fail(n, "Protocols must include http/1.1", .{});
        } else if (eq(n.name, "SSLProtocol")) {
            try b.arity(n, 1, 8);
            var v12 = false;
            var v13 = false;
            for (n.args) |v| {
                if (eq(v, "all") or eq(v, "+all")) {
                    v12 = true;
                    v13 = true;
                } else if (eq(v, "-all")) {
                    v12 = false;
                    v13 = false;
                } else if (eq(v, "TLSv1.2") or eq(v, "+TLSv1.2")) v12 = true else if (eq(v, "TLSv1.3") or eq(v, "+TLSv1.3")) v13 = true else if (eq(v, "-TLSv1.2")) v12 = false else if (eq(v, "-TLSv1.3")) v13 = false else if (eq(v, "-SSLv3") or eq(v, "-TLSv1") or eq(v, "-TLSv1.1")) {} else return b.fail(n, "unsupported TLS protocol {s}", .{v});
            }
            var protocols: std.ArrayList([]const u8) = .empty;
            if (v12) try protocols.append(b.a, "TLSv1.2");
            if (v13) try protocols.append(b.a, "TLSv1.3");
            if (protocols.items.len == 0) return b.fail(n, "no supported TLS protocol enabled", .{});
            s.tls.protocols = try protocols.toOwnedSlice(b.a);
        } else if (eq(n.name, "ErrorLog") or eq(n.name, "PidFile")) {
            try b.arity(n, 1, 1);
            const path = if (eq(n.name, "ErrorLog")) try b.logPath(n, n.args[0]) else try b.fullPath(b.cfg.prefix, n.args[0]);
            if (eq(n.name, "ErrorLog")) {
                var el = s.conf.error_log orelse b.cfg.error_log;
                el.path = path;
                s.conf.error_log = el;
            } else b.cfg.pid_path = path;
        } else if (eq(n.name, "ProxyPass") or eq(n.name, "Alias")) {
            try b.arity(n, 2, 2);
            const loc = try b.location(s, n, n.args[0]);
            if (eq(n.name, "ProxyPass")) try b.proxy(loc.conf, n, n.args[1]) else loc.conf.alias = try b.literal(try b.fullPath(b.cfg.prefix, n.args[1]));
        } else try local(b, s.conf, n);
    }
    for (nodes) |n| if (n.children) |children| {
        if (eq(n.name, "VirtualHost")) continue;
        try b.arity(n, 1, 1);
        const lc = if (eq(n.name, "Directory")) blk: {
            const path = try b.fullPath(b.cfg.prefix, n.args[0]);
            if (!eq(path, "/") and !std.mem.eql(u8, path, s.conf.root.literal())) return b.fail(n, "Directory currently supports / or DocumentRoot; use explicit supported access rules", .{});
            break :blk s.conf;
        } else if (eq(n.name, "Location")) (try b.location(s, n, n.args[0])).conf else return b.fail(n, "unsupported Apache section {s}", .{n.name});
        for (children) |child| try local(b, lc, child);
    };
}
fn build(b: *B, nodes: []Node) Error!void {
    const origin: Node = .{ .name = "main", .args = &.{}, .file = b.cfg.conf_file, .line = 1 };
    const base = try b.server(origin, null);
    var main_tls = false;
    try server(b, base, nodes, &main_tls);
    var listens: std.ArrayList(http.addr.Addr) = .empty;
    for (nodes) |n| if (eq(n.name, "Listen")) {
        try b.arity(n, 1, 2);
        if (n.args.len == 2 and !eq(n.args[1], "http") and !eq(n.args[1], "https")) return b.fail(n, "unsupported Listen protocol", .{});
        const addr = try b.address(n, n.args[0], 80);
        for (listens.items) |old| if (old.eql(addr)) return b.fail(n, "duplicate Listen", .{});
        try listens.append(b.a, addr);
    };
    if (listens.items.len == 0) return b.fail(origin, "Apache configuration requires Listen", .{});
    for (nodes) |n| if (eq(n.name, "VirtualHost")) {
        try b.arity(n, 1, 32);
        const block = n.children orelse return b.fail(n, "VirtualHost must be a section", .{});
        const s = try b.server(n, base);
        var secure = main_tls;
        try server(b, s, block, &secure);
        for (n.args) |address| {
            const target = try b.address(n, address, 80);
            var matched = false;
            for (listens.items) |addr| {
                if (addr.port != target.port or addr.family != target.family or !(addr.isWildcard() or target.isWildcard() or addr.sameHost(target))) continue;
                try b.listen(s, addr, secure, false);
                matched = true;
            }
            if (!matched) return b.fail(n, "VirtualHost does not match a Listen socket", .{});
        }
    };
    for (listens.items) |addr| {
        var matched = false;
        for (b.cfg.listens) |l| matched = matched or l.addr.eql(addr);
        if (!matched) try b.listen(base, addr, main_tls, false);
    }
}

test "Apache virtual hosts, roots and access rules lower to HTTP" {
    var d: http.diag.Diag = .{ .gpa = std.testing.allocator };
    defer d.deinit();
    const cfg = try loadString(std.testing.allocator, "Listen 127.0.0.1:8080\nDocumentRoot /srv/www\n<VirtualHost *:8080>\nServerName example.test\n<Directory /srv/www>\nRequire all denied\n</Directory>\n</VirtualHost>\n", .{ .server_root = "/srv" }, &d);
    defer destroy(std.testing.allocator, cfg);
    try std.testing.expectEqualStrings("example.test", cfg.listens[0].entries[0].server.primary_name);
    try std.testing.expect(!cfg.listens[0].entries[0].server.conf.access[0].allow);
    try std.testing.expectError(error.ConfigFailed, loadString(std.testing.allocator, "Listen 80\nAuthType Basic\n", .{ .server_root = "/srv" }, &d));
}
