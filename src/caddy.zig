//! Caddyfile adapter. Certificate issuance is owned by the shared ACME runtime.
const std = @import("std");
const support = @import("settings");
const http = @import("http");
const B = support.Builder;
const Node = support.Node;
const Error = support.Error;
const C = http.config;
pub const destroy = support.destroy;

pub fn load(gpa: std.mem.Allocator, file: []const u8, root: []const u8, diag: *http.diag.Diag) Error!*C.Config {
    return loadWithAcme(gpa, file, root, &.{}, diag);
}
pub fn loadWithAcme(gpa: std.mem.Allocator, file: []const u8, root: []const u8, acme_domains: []const []const u8, diag: *http.diag.Diag) Error!*C.Config {
    return loadObserved(gpa, file, root, acme_domains, null, diag);
}
pub fn loadObserved(gpa: std.mem.Allocator, file: []const u8, root: []const u8, acme_domains: []const []const u8, sources: ?*http.config_watch.Sources, diag: *http.diag.Diag) Error!*C.Config {
    var b = try B.init(gpa, file, root, diag);
    b.sources = sources;
    errdefer destroy(gpa, b.cfg);
    try sites(&b, try b.read(file, .braces), 0, acme_domains);
    if (b.cfg.listens.len == 0) return error.ConfigFailed;
    return b.cfg;
}
fn sites(b: *B, nodes: []Node, depth: u8, acme_domains: []const []const u8) Error!void {
    if (depth > 16) return error.ConfigFailed;
    for (nodes) |n| {
        if (std.mem.eql(u8, n.name, "import")) {
            try b.arity(n, 1, 1);
            const path = try b.fullPath(std.fs.path.dirname(n.file) orelse b.cfg.prefix, n.args[0]);
            if (b.sources) |sources| try sources.observe(path, if (http.os.hasGlob(path)) .glob else .file);
            const paths: []const []const u8 = if (http.os.hasGlob(path)) try http.os.glob(b.a, path) else try b.a.dupe([]const u8, &.{path});
            for (paths) |p| try sites(b, try b.read(p, .braces), depth + 1, acme_domains);
            continue;
        }
        const children = n.children orelse return b.fail(n, "expected Caddy site block", .{});
        const s = try b.server(n, null);
        try body(b, s, null, children);
        const names = try b.a.alloc([]const u8, n.args.len + 1);
        names[0] = n.name;
        @memcpy(names[1..], n.args);
        for (names) |raw| {
            var name = std.mem.trim(u8, raw, ",");
            const explicit_http = std.mem.startsWith(u8, name, "http://");
            const explicit_https = std.mem.startsWith(u8, name, "https://");
            if (explicit_http) name = name[7..] else if (explicit_https) name = name[8..];
            if (std.mem.indexOfScalar(u8, name, '/') != null) return b.fail(n, "site paths are not supported", .{});
            const secure = explicit_https or (!explicit_http and name.len > 0 and name[0] != ':');
            var host = name;
            var port: u16 = if (secure) 443 else 80;
            if (std.mem.lastIndexOfScalar(u8, name, ':')) |colon| {
                host = name[0..colon];
                port = std.fmt.parseInt(u16, name[colon + 1 ..], 10) catch return b.fail(n, "invalid site port", .{});
            }
            const managed = http.acme.covers(acme_domains, host);
            if (secure and !managed and (s.tls.certificate == null or s.tls.certificate_key == null)) return b.fail(n, "HTTPS requires tls certificate key or matching [acme].domains in config.toml", .{});
            // Caddy site names select hosts; they do not bind to a DNS result.
            if (host.len > 0) try b.name(s, host);
            s.http2 = secure;
            try b.listen(s, .{ .port = port }, secure, false);
        }
    }
}
fn body(b: *B, s: *C.Server, loc: ?*C.Location, nodes: []Node) Error!void {
    const lc = if (loc) |l| l.conf else s.conf;
    var handler = false;
    // root and tls configure all handlers regardless of directive order.
    for (nodes) |n| {
        if (std.mem.eql(u8, n.name, "log")) {
            if (loc != null) return b.fail(n, "log must be in site scope", .{});
            try b.arity(n, 0, 0);
            var output: []const u8 = "stderr";
            if (n.children) |children| for (children) |child| {
                if (std.mem.eql(u8, child.name, "output")) {
                    try b.arity(child, 1, 2);
                    if (child.children != null) return b.fail(child, "log rotation options are not supported; use external rotation with USR1", .{});
                    if (std.mem.eql(u8, child.args[0], "file") and child.args.len == 2) output = child.args[1] else if (child.args.len == 1 and (std.mem.eql(u8, child.args[0], "stdout") or std.mem.eql(u8, child.args[0], "stderr"))) output = child.args[0] else return b.fail(child, "unsupported log output", .{});
                } else if (std.mem.eql(u8, child.name, "format")) {
                    try b.arity(child, 1, 1);
                    if (!std.mem.eql(u8, child.args[0], "json") or child.children != null) return b.fail(child, "only format json is supported", .{});
                } else return b.fail(child, "unsupported log option {s}", .{child.name});
            };
            try b.accessLog(lc, n, output, try b.logFormat(n, "json", http.logging.json, .json));
        } else if (std.mem.eql(u8, n.name, "root")) {
            try b.arity(n, 1, 2);
            if (n.args.len == 2 and !std.mem.eql(u8, n.args[0], "*")) return b.fail(n, "root matcher is not supported", .{});
            lc.root = try b.literal(try b.fullPath(b.cfg.prefix, n.args[n.args.len - 1]));
        } else if (std.mem.eql(u8, n.name, "tls")) {
            if (loc != null or n.children != null) return b.fail(n, "unsupported tls scope/options", .{});
            try b.arity(n, 2, 2);
            s.tls.certificate = try b.fullPath(b.cfg.prefix, n.args[0]);
            s.tls.certificate_key = try b.fullPath(b.cfg.prefix, n.args[1]);
        }
    }
    for (nodes) |n| {
        if (std.mem.eql(u8, n.name, "root") or std.mem.eql(u8, n.name, "tls") or std.mem.eql(u8, n.name, "log")) continue;
        if (std.mem.eql(u8, n.name, "handle")) {
            if (loc != null) return b.fail(n, "nested handle blocks are not supported", .{});
            try b.arity(n, 1, 1);
            const path = n.args[0];
            const prefix = std.mem.endsWith(u8, path, "*");
            const child = try b.locationKind(s, n, if (prefix) path[0 .. path.len - 1] else path, if (prefix) .prefix else .exact);
            try body(b, s, child, n.children orelse return b.fail(n, "handle requires block", .{}));
        } else if (std.mem.eql(u8, n.name, "file_server")) {
            if (handler) return b.fail(n, "overlapping terminal handlers require explicit handle blocks", .{});
            try b.arity(n, 0, 1);
            handler = true;
            if (n.args.len == 1) {
                if (!std.mem.eql(u8, n.args[0], "browse")) return b.fail(n, "unsupported file_server option", .{});
                lc.autoindex = true;
            }
            if (n.children) |children| for (children) |child| {
                if (std.mem.eql(u8, child.name, "index")) {
                    try b.arity(child, 1, 16);
                    try b.indexes(lc, child.args);
                } else if (std.mem.eql(u8, child.name, "browse")) {
                    try b.arity(child, 0, 0);
                    lc.autoindex = true;
                } else return b.fail(child, "unsupported file_server option {s}", .{child.name});
            };
        } else if (std.mem.eql(u8, n.name, "respond") or std.mem.eql(u8, n.name, "redir")) {
            if (handler or n.children != null) return b.fail(n, "overlapping or unsupported response handler", .{});
            try b.arity(n, 1, 2);
            handler = true;
            const redirect = std.mem.eql(u8, n.name, "redir");
            var status: u32 = if (redirect) 302 else 200;
            var text = n.args[0];
            if (n.args.len == 2) {
                status = if (std.mem.eql(u8, n.args[1], "permanent")) 301 else if (std.mem.eql(u8, n.args[1], "temporary")) 302 else try b.number(n, n.args[1]);
            } else if (!redirect) {
                if (std.fmt.parseInt(u16, text, 10)) |code| {
                    status = code;
                    text = "";
                } else |_| {}
            }
            if (status < 200 or status > 599) return b.fail(n, "invalid response status", .{});
            if (std.mem.indexOfScalar(u8, text, '{') != null) return b.fail(n, "Caddy placeholders are not supported", .{});
            const stmt: C.Stmt = .{ .ret = .{ .code = @intCast(status), .text = try b.literal(text) } };
            if (loc) |l| l.stmts = try b.a.dupe(C.Stmt, &.{stmt}) else {
                const fallback = try b.location(s, n, "/");
                fallback.stmts = try b.a.dupe(C.Stmt, &.{stmt});
            }
        } else if (std.mem.eql(u8, n.name, "reverse_proxy")) {
            if (handler or n.children != null) return b.fail(n, "only a single HTTP upstream is supported", .{});
            try b.arity(n, 1, 1);
            handler = true;
            try b.proxy(lc, n, n.args[0]);
        } else if (std.mem.eql(u8, n.name, "header")) {
            try b.arity(n, 2, 2);
            if (n.args[0].len == 0 or std.mem.indexOfAny(u8, n.args[0], "+-?>") != null or n.children != null) return b.fail(n, "only literal response headers are supported", .{});
            lc.add_headers = try support.append(b.a, C.AddHeader, lc.add_headers, .{ .name = n.args[0], .value = try b.literal(n.args[1]), .always = true });
        } else return b.fail(n, "unsupported Caddy directive {s}", .{n.name});
    }
    if (!handler) {
        const stmt: C.Stmt = .{ .ret = .{ .code = 404, .text = null } };
        if (loc) |l| l.stmts = try b.a.dupe(C.Stmt, &.{stmt}) else {
            const fallback = try b.location(s, .{ .name = "fallback", .args = &.{}, .file = s.file, .line = s.line }, "/");
            fallback.stmts = try b.a.dupe(C.Stmt, &.{stmt});
        }
    }
}
