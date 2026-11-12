//! Native OpenLiteSpeed httpd_config.conf adapter (not Apache-compatible syntax).
const std = @import("std");
const http = @import("http");
const support = @import("settings");
const B = support.Builder;
const N = support.Node;
const Error = support.Error;
const C = http.config;
const eq = support.eql;
pub const destroy = support.destroy;

fn path(b: *B, n: N, value: []const u8, vh_root: []const u8) Error![]const u8 {
    if (std.mem.startsWith(u8, value, "$SERVER_ROOT")) return std.fmt.allocPrint(b.a, "{s}{s}", .{ b.cfg.prefix, value[12..] });
    if (std.mem.startsWith(u8, value, "$VH_ROOT")) return std.fmt.allocPrint(b.a, "{s}{s}", .{ vh_root, value[8..] });
    if (std.mem.indexOfScalar(u8, value, '$') != null) return b.fail(n, "unsupported OpenLiteSpeed path variable", .{});
    return b.fullPath(vh_root, value);
}
fn names(b: *B, s: *C.Server, values: []const []const u8) Error!void {
    for (values) |v| {
        var it = std.mem.tokenizeAny(u8, v, ", ");
        while (it.next()) |name| try b.name(s, name);
    }
}
fn ssl(b: *B, s: *C.Server, nodes: []N, vh_root: []const u8) Error!void {
    for (nodes) |n| {
        try b.arity(n, 1, 1);
        if (eq(n.name, "certFile")) s.tls.certificate = try path(b, n, n.args[0], vh_root) else if (eq(n.name, "keyFile")) s.tls.certificate_key = try path(b, n, n.args[0], vh_root) else if (eq(n.name, "certChain")) {
            if (!try b.flag(n, n.args[0])) return b.fail(n, "certFile must contain the certificate chain", .{});
        } else if (eq(n.name, "sslProtocol")) {
            const mask = try b.number(n, n.args[0]);
            if (mask == 24) s.tls.protocols = &.{ "TLSv1.2", "TLSv1.3" } else if (mask == 8) s.tls.protocols = &.{"TLSv1.2"} else if (mask == 16) s.tls.protocols = &.{"TLSv1.3"} else return b.fail(n, "only TLS 1.2/1.3 protocol masks are supported", .{});
        } else return b.fail(n, "unsupported OpenLiteSpeed TLS setting {s}", .{n.name});
    }
}
fn logs(b: *B, lc: *C.LocConf, n: N, vh_root: []const u8) Error!void {
    try b.arity(n, 1, 1);
    const target = try path(b, n, n.args[0], vh_root);
    var format: []const u8 = http.logging.combined;
    var inherit = false;
    var level: u8 = 3;
    for (n.children orelse return b.fail(n, "log requires block", .{})) |child| {
        try b.arity(child, 1, 1);
        if (eq(child.name, "logFormat") and eq(n.name, "accesslog")) format = try b.apacheFormat(child, child.args[0]) else if (eq(child.name, "useServer")) inherit = try b.flag(child, child.args[0]) else if (eq(child.name, "logLevel") and eq(n.name, "errorlog")) level = http.logging.level(child.args[0]) orelse return b.fail(child, "invalid log level", .{}) else return b.fail(child, "unsupported log option {s}", .{child.name});
    }
    if (inherit) return;
    if (eq(n.name, "accesslog")) {
        lc.access_logs = null;
        try b.accessLog(lc, n, target, try b.logFormat(n, "litespeed", format, .default));
    } else lc.error_log = .{ .path = try b.logPath(n, target), .level = level };
}
fn host(b: *B, s: *C.Server, nodes: []N, vh_root: []const u8) Error!void {
    for (nodes) |n| if (eq(n.name, "accesslog") or eq(n.name, "errorlog")) {
        try logs(b, s.conf, n, vh_root);
    };
    for (nodes) |n| if (eq(n.name, "docRoot")) {
        try b.arity(n, 1, 1);
        s.conf.root = try b.literal(try path(b, n, n.args[0], vh_root));
    };
    for (nodes) |n| {
        if (eq(n.name, "docRoot") or eq(n.name, "accesslog") or eq(n.name, "errorlog")) continue;
        if (eq(n.name, "vhDomain") or eq(n.name, "vhAliases")) {
            try names(b, s, n.args);
        } else if (eq(n.name, "index")) {
            const children = n.children orelse return b.fail(n, "index requires block", .{});
            for (children) |child| {
                if (eq(child.name, "indexFiles")) {
                    var values: std.ArrayList([]const u8) = .empty;
                    for (child.args) |v| {
                        var it = std.mem.tokenizeAny(u8, v, ", ");
                        while (it.next()) |entry| try values.append(b.a, entry);
                    }
                    try b.indexes(s.conf, values.items);
                } else if (eq(child.name, "autoIndex")) {
                    try b.arity(child, 1, 1);
                    s.conf.autoindex = try b.flag(child, child.args[0]);
                } else if (eq(child.name, "useServer")) {
                    try b.arity(child, 1, 1);
                    if (try b.flag(child, child.args[0])) return b.fail(child, "server index inheritance is not configured", .{});
                } else return b.fail(child, "unsupported index setting {s}", .{child.name});
            }
        } else if (eq(n.name, "vhssl")) {
            try ssl(b, s, n.children orelse return b.fail(n, "vhssl requires block", .{}), vh_root);
        } else if (eq(n.name, "context")) {
            try b.arity(n, 1, 1);
            const children = n.children orelse return b.fail(n, "context requires block", .{});
            const loc = try b.location(s, n, n.args[0]);
            for (children) |child| {
                try b.arity(child, 1, 1);
                if (eq(child.name, "type")) {
                    if (!eq(child.args[0], "static")) return b.fail(child, "only static contexts are supported", .{});
                } else if (eq(child.name, "location")) loc.conf.alias = try b.literal(try path(b, child, child.args[0], vh_root)) else if (eq(child.name, "allowBrowse")) {
                    if (!try b.flag(child, child.args[0])) loc.conf.access = try b.a.dupe(C.AccessRule, &.{.{ .allow = false, .all = true }});
                } else return b.fail(child, "unsupported context setting {s}", .{child.name});
            }
        } else if (eq(n.name, "enableGzip")) {
            try b.arity(n, 1, 1);
            if (try b.flag(n, n.args[0])) return b.fail(n, "gzip is not implemented", .{});
        } else return b.fail(n, "unsupported OpenLiteSpeed vhost setting {s}", .{n.name});
    }
}
pub fn load(gpa: std.mem.Allocator, file: []const u8, root: []const u8, diag: *http.diag.Diag) Error!*C.Config {
    return loadObserved(gpa, file, root, null, diag);
}
pub fn loadObserved(gpa: std.mem.Allocator, file: []const u8, root: []const u8, sources: ?*http.config_watch.Sources, diag: *http.diag.Diag) Error!*C.Config {
    var b = try B.init(gpa, file, root, diag);
    b.sources = sources;
    errdefer destroy(gpa, b.cfg);
    const nodes = try b.read(file, .braces);
    const defaults = try b.server(.{ .name = "main", .args = &.{}, .file = file, .line = 0 }, null);
    for (nodes) |n| if (eq(n.name, "accesslog") or eq(n.name, "errorlog")) try logs(&b, defaults.conf, n, root);
    var hosts: std.StringHashMapUnmanaged(*C.Server) = .empty;
    for (nodes) |n| {
        if (eq(n.name, "listener") or eq(n.name, "accesslog") or eq(n.name, "errorlog")) continue;
        if (!eq(n.name, "virtualhost")) return b.fail(n, "unsupported OpenLiteSpeed server setting {s}", .{n.name});
        try b.arity(n, 1, 1);
        const children = n.children orelse return b.fail(n, "virtualhost requires block", .{});
        if (hosts.contains(n.args[0])) return b.fail(n, "duplicate virtualhost", .{});
        var vh_root = b.cfg.prefix;
        var config_file: ?[]const u8 = null;
        for (children) |child| if (eq(child.name, "vhRoot")) {
            try b.arity(child, 1, 1);
            vh_root = try path(&b, child, child.args[0], b.cfg.prefix);
        };
        for (children) |child| {
            if (eq(child.name, "vhRoot")) continue;
            if (eq(child.name, "configFile")) {
                try b.arity(child, 1, 1);
                config_file = try path(&b, child, child.args[0], vh_root);
            } else return b.fail(child, "unsupported virtualhost setting {s}", .{child.name});
        }
        const s = try b.server(n, defaults);
        s.conf.root = try b.literal(vh_root);
        try host(&b, s, try b.read(config_file orelse return b.fail(n, "virtualhost requires configFile", .{}), .braces), vh_root);
        try hosts.put(b.a, n.args[0], s);
    }
    for (nodes) |n| if (eq(n.name, "listener")) {
        try b.arity(n, 1, 1);
        const children = n.children orelse return b.fail(n, "listener requires block", .{});
        var addr: ?http.addr.Addr = null;
        var secure = false;
        var tls_nodes: std.ArrayList(N) = .empty;
        for (children) |child| {
            if (eq(child.name, "map")) continue;
            try b.arity(child, 1, 1);
            if (eq(child.name, "address")) addr = try b.address(child, child.args[0], 80) else if (eq(child.name, "secure")) secure = try b.flag(child, child.args[0]) else if (eq(child.name, "certFile") or eq(child.name, "keyFile") or eq(child.name, "certChain") or eq(child.name, "sslProtocol")) try tls_nodes.append(b.a, child) else return b.fail(child, "unsupported listener setting {s}", .{child.name});
        }
        var mapped = false;
        for (children) |child| if (eq(child.name, "map")) {
            try b.arity(child, 2, 32);
            const base = hosts.get(child.args[0]) orelse return b.fail(child, "unknown mapped virtualhost {s}", .{child.args[0]});
            // Listener TLS and names belong to this mapping, not other listeners.
            const s = try b.server(child, base);
            s.locations = base.locations;
            s.names = &.{};
            s.primary_name = "";
            try names(&b, s, child.args[1..]);
            if (secure) {
                try ssl(&b, s, tls_nodes.items, b.cfg.prefix);
                s.http2 = true;
            }
            try b.listen(s, addr orelse return b.fail(n, "listener requires address", .{}), secure, false);
            mapped = true;
        };
        if (!mapped) return b.fail(n, "listener requires map", .{});
    };
    if (b.cfg.listens.len == 0) return b.fail(.{ .name = "", .args = &.{}, .file = file, .line = 0 }, "no OpenLiteSpeed listeners configured", .{});
    return b.cfg;
}
