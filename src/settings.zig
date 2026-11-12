//! Shared, format-neutral configuration reader and runtime model construction.
const std = @import("std");
pub const http = @import("http");
pub const config = http.config;
pub const Diag = http.diag.Diag;
pub const Error = error{ ConfigFailed, OutOfMemory };
pub const Node = struct {
    name: []const u8,
    args: []const []const u8,
    children: ?[]Node = null,
    file: []const u8,
    line: u32,
};
pub const Syntax = enum { braces, apache };

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub const Builder = struct {
    cfg: *config.Config,
    a: std.mem.Allocator,
    diag: *Diag,
    bytes: usize = 0,
    sources: ?*http.config_watch.Sources = null,

    pub fn init(gpa: std.mem.Allocator, file: []const u8, prefix: []const u8, diag: *Diag) Error!Builder {
        const cfg = try gpa.create(config.Config);
        cfg.* = .{ .arena = .init(gpa), .prefix = prefix, .conf_file = file, .has_http = true, .error_log = .{ .path = "stderr" } };
        return .{ .cfg = cfg, .a = cfg.arena.allocator(), .diag = diag };
    }
    pub fn fail(b: *Builder, n: Node, comptime message: []const u8, args: anytype) Error {
        b.diag.add(.emerg, n.file, n.line, message, args);
        return error.ConfigFailed;
    }
    pub fn arity(b: *Builder, n: Node, min: usize, max: usize) Error!void {
        if (n.args.len < min or n.args.len > max) return b.fail(n, "invalid arguments for {s}", .{n.name});
    }
    pub fn fullPath(b: *Builder, root: []const u8, path: []const u8) Error![]const u8 {
        if (std.fs.path.isAbsolute(path)) return path;
        return std.fs.path.resolve(b.a, &.{ root, path });
    }
    pub fn read(b: *Builder, file: []const u8, syntax: Syntax) Error![]Node {
        if (b.sources) |sources| try sources.observe(file, .file);
        var e: c_int = 0;
        const data = http.os.readFileAlloc(b.a, file, &e) catch return b.fail(.{ .name = "", .args = &.{}, .file = file, .line = 0 }, "cannot read configuration ({d})", .{e});
        b.bytes += data.len;
        if (b.bytes > 8 * 1024 * 1024) return error.ConfigFailed;
        b.cfg.source_files = try append(b.a, []const u8, b.cfg.source_files, file);
        return b.parse(data, file, syntax);
    }
    pub fn parse(b: *Builder, data: []const u8, file: []const u8, syntax: Syntax) Error![]Node {
        var p: Parser = .{ .b = b, .data = data, .file = file, .syntax = syntax };
        return p.block(null, 0);
    }
    pub fn literal(b: *Builder, text: []const u8) Error!http.expr.Expr {
        return .{ .raw = text, .parts = try b.a.dupe(http.expr.Part, &.{.{ .lit = text }}) };
    }
    pub fn server(b: *Builder, source: Node, parent: ?*config.Server) Error!*config.Server {
        const s = try b.a.create(config.Server);
        const lc = try b.a.create(config.LocConf);
        if (parent) |base| {
            s.* = base.*;
            lc.* = base.conf.*;
            s.conf = lc;
            s.locations = &.{};
            s.named = &.{};
        } else {
            const mime = try b.a.create(config.Mime);
            mime.* = .empty;
            try mime.put(b.a, "html", "text/html");
            try mime.put(b.a, "css", "text/css");
            try mime.put(b.a, "js", "application/javascript");
            try mime.put(b.a, "txt", "text/plain");
            const idx = try b.a.alloc(http.expr.Expr, 1);
            idx[0] = try b.literal("index.html");
            lc.* = .{ .root = try b.literal(b.cfg.prefix), .index = idx, .access_logs = null, .types = mime };
            s.* = .{ .index = 0, .names = &.{}, .primary_name = "", .conf = lc, .file = source.file, .line = source.line };
        }
        s.index = b.cfg.servers.len;
        b.cfg.servers = try append(b.a, *config.Server, b.cfg.servers, s);
        return s;
    }
    pub fn name(b: *Builder, s: *config.Server, value: []const u8) Error!void {
        const lower = try std.ascii.allocLowerString(b.a, value);
        if (s.primary_name.len == 0) s.primary_name = lower;
        const server_name: config.ServerName = if (std.mem.startsWith(u8, lower, "*.")) .{ .lead = lower[1..] } else .{ .exact = lower };
        s.names = try append(b.a, config.ServerName, s.names, server_name);
    }
    pub fn address(b: *Builder, n: Node, value: []const u8, default_port: u16) Error!http.addr.Addr {
        const v = if (value.len > 0 and value[0] == ':') value[1..] else value;
        const hp = http.addr.parseHostPort(v, default_port) orelse return b.fail(n, "listen address must be an IP address, localhost or wildcard: {s}", .{value});
        if (hp.addr.port == 0) return b.fail(n, "invalid zero port", .{});
        return hp.addr;
    }
    pub fn listen(b: *Builder, s: *config.Server, addr: http.addr.Addr, secure: bool, quic: bool) Error!void {
        for (b.cfg.listens) |*l| if (l.addr.eql(addr) and l.opts.quic == quic) {
            if (l.opts.ssl != secure) return b.fail(.{ .name = "listen", .args = &.{}, .file = s.file, .line = s.line }, "conflicting TLS modes on one listener", .{});
            l.entries = try append(b.a, config.Listen.Entry, l.entries, .{ .addr = addr, .server = s, .default = false });
            return;
        };
        const entries = try b.a.dupe(config.Listen.Entry, &.{.{ .addr = addr, .server = s, .default = true }});
        b.cfg.listens = try append(b.a, config.Listen, b.cfg.listens, .{ .addr = addr, .opts = .{ .ssl = secure, .quic = quic }, .entries = entries });
    }
    pub fn location(b: *Builder, s: *config.Server, n: Node, path: []const u8) Error!*config.Location {
        return b.locationKind(s, n, path, .prefix);
    }
    pub fn locationKind(b: *Builder, s: *config.Server, n: Node, path: []const u8, kind: config.LocKind) Error!*config.Location {
        if (path.len == 0 or path[0] != '/') return b.fail(n, "location must start with /", .{});
        for (s.locations) |l| if (l.kind == kind and std.mem.eql(u8, l.name, path)) return b.fail(n, "duplicate location {s}", .{path});
        const lc = try b.a.create(config.LocConf);
        lc.* = s.conf.*;
        const loc = try b.a.create(config.Location);
        loc.* = .{ .kind = kind, .name = path, .conf = lc, .file = n.file, .line = n.line };
        s.locations = try append(b.a, *config.Location, s.locations, loc);
        return loc;
    }
    pub fn logPath(b: *Builder, n: Node, value: []const u8) Error![]const u8 {
        if (eql(value, "stdout") or eql(value, "/dev/stdout")) return "/dev/stdout";
        if (eql(value, "stderr") or eql(value, "/dev/stderr")) return "/dev/stderr";
        if (value.len == 0 or value[0] == '|' or std.mem.startsWith(u8, value, "syslog:") or std.mem.indexOfScalar(u8, value, '$') != null) return b.fail(n, "unsupported log target {s}", .{value});
        return b.fullPath(b.cfg.prefix, value);
    }
    pub fn logFormat(b: *Builder, n: Node, name_: []const u8, text: []const u8, escape: http.logging.Escape) Error!*config.LogFormat {
        return http.logging.compile(b.a, name_, text, escape) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return b.fail(n, "invalid log format", .{});
        };
    }
    pub fn apacheFormat(b: *Builder, n: Node, text: []const u8) Error![]const u8 {
        return http.logging.apache(b.a, text) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return b.fail(n, "unsupported Apache log format field", .{});
        };
    }
    pub fn accessLog(b: *Builder, lc: *config.LocConf, n: Node, target: []const u8, format: *const config.LogFormat) Error!void {
        lc.access_logs = try append(b.a, config.AccessLog, lc.access_logs orelse &.{}, .{ .path = try b.logPath(n, target), .format = format });
    }
    pub fn indexes(b: *Builder, lc: *config.LocConf, names: []const []const u8) Error!void {
        lc.index = try b.a.alloc(http.expr.Expr, names.len);
        for (names, 0..) |v, i| lc.index[i] = try b.literal(v);
    }
    pub fn proxy(b: *Builder, lc: *config.LocConf, n: Node, url: []const u8) Error!void {
        const raw = if (std.mem.startsWith(u8, url, "http://")) url[7..] else url;
        if (std.mem.indexOf(u8, raw, "://") != null) return b.fail(n, "only http upstreams are supported", .{});
        const slash = std.mem.indexOfScalar(u8, raw, '/') orelse raw.len;
        const hostport = raw[0..slash];
        var addrs: std.ArrayList(http.addr.Addr) = .empty;
        var port: u16 = 80;
        if (http.addr.parseHostPort(hostport, 80)) |hp| {
            port = hp.addr.port;
            try addrs.append(b.a, hp.addr);
        } else {
            const colon = std.mem.lastIndexOfScalar(u8, hostport, ':');
            if (colon) |i| port = std.fmt.parseInt(u16, hostport[i + 1 ..], 10) catch return b.fail(n, "invalid upstream port", .{});
            if (!http.os.resolve(b.a, if (colon) |i| hostport[0..i] else hostport, port, &addrs)) return b.fail(n, "cannot resolve upstream {s}", .{hostport});
        }
        const u = try b.a.create(config.Upstream);
        u.* = .{ .name = hostport, .addrs = try addrs.toOwnedSlice(b.a) };
        b.cfg.upstreams = try append(b.a, *config.Upstream, b.cfg.upstreams, u);
        lc.proxy = .{ .upstream = u, .host = hostport, .port = port, .uri = if (slash < raw.len) try b.literal(raw[slash..]) else null };
    }
    pub fn number(b: *Builder, n: Node, value: []const u8) Error!u32 {
        return std.fmt.parseInt(u32, value, 10) catch b.fail(n, "invalid number {s}", .{value});
    }
    pub fn flag(b: *Builder, n: Node, value: []const u8) Error!bool {
        if (eql(value, "on") or eql(value, "true") or eql(value, "1")) return true;
        if (eql(value, "off") or eql(value, "false") or eql(value, "0")) return false;
        return b.fail(n, "invalid boolean {s}", .{value});
    }
};
pub fn append(a: std.mem.Allocator, comptime T: type, old: []const T, value: T) Error![]T {
    const out = try a.alloc(T, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = value;
    return out;
}
pub fn destroy(gpa: std.mem.Allocator, cfg: *config.Config) void {
    cfg.deinit();
    gpa.destroy(cfg);
}

const Token = union(enum) { word: []const u8, newline, open, close, eof };
const Parser = struct {
    b: *Builder,
    data: []const u8,
    file: []const u8,
    syntax: Syntax,
    pos: usize = 0,
    line: u32 = 1,
    fn fail(p: *Parser, message: []const u8) Error {
        return p.b.fail(.{ .name = "", .args = &.{}, .file = p.file, .line = p.line }, "{s}", .{message});
    }
    fn token(p: *Parser) Error!Token {
        while (p.pos < p.data.len) {
            const c = p.data[p.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                p.pos += 1;
                continue;
            }
            if (c == '\\' and p.pos + 1 < p.data.len and p.data[p.pos + 1] == '\n') {
                p.pos += 2;
                p.line += 1;
                continue;
            }
            if (c == '#') {
                while (p.pos < p.data.len and p.data[p.pos] != '\n') p.pos += 1;
                continue;
            }
            if (c == '\n') {
                p.pos += 1;
                p.line += 1;
                return .newline;
            }
            if (p.syntax == .braces and (c == '{' or c == '}') and (p.pos + 1 == p.data.len or std.ascii.isWhitespace(p.data[p.pos + 1]) or p.data[p.pos + 1] == '}')) {
                p.pos += 1;
                return if (c == '{') .open else .close;
            }
            var text: std.ArrayList(u8) = .empty;
            var quote: u8 = 0;
            if (c == '"' or c == '\'') {
                quote = c;
                p.pos += 1;
            }
            var ended = quote == 0;
            while (p.pos < p.data.len) {
                const ch = p.data[p.pos];
                if (quote != 0 and ch == quote) {
                    p.pos += 1;
                    ended = true;
                    if (p.syntax == .apache and p.pos < p.data.len and p.data[p.pos] == '>') {
                        try text.append(p.b.a, '>');
                        p.pos += 1;
                    }
                    break;
                }
                if (quote == 0 and std.ascii.isWhitespace(ch)) break;
                if (ch == '\n') return p.fail("newline in quoted argument");
                if (ch == '\\' and p.pos + 1 < p.data.len) {
                    const next = p.data[p.pos + 1];
                    if (next == '\n') {
                        p.pos += 2;
                        p.line += 1;
                        continue;
                    }
                    if (next == quote or next == '\\' or (quote == 0 and std.ascii.isWhitespace(next))) {
                        p.pos += 1;
                    }
                }
                try text.append(p.b.a, p.data[p.pos]);
                p.pos += 1;
            }
            if (!ended) return p.fail("unterminated quoted argument");
            return .{ .word = try text.toOwnedSlice(p.b.a) };
        }
        return .eof;
    }
    fn block(p: *Parser, closing: ?[]const u8, depth: u8) Error![]Node {
        if (depth > 32) return p.fail("configuration nesting limit exceeded");
        var nodes: std.ArrayList(Node) = .empty;
        var words: std.ArrayList([]const u8) = .empty;
        var start: u32 = p.line;
        while (true) {
            const before = p.line;
            const tok = try p.token();
            switch (tok) {
                .word => |w| {
                    if (words.items.len == 0) start = before;
                    try words.append(p.b.a, w);
                },
                .open => {
                    if (words.items.len == 0) return p.fail("block without directive");
                    const args = try words.toOwnedSlice(p.b.a);
                    try nodes.append(p.b.a, .{ .name = args[0], .args = args[1..], .children = try p.block("}", depth + 1), .file = p.file, .line = start });
                },
                .newline, .eof, .close => {
                    if (words.items.len > 0) {
                        var args = try words.toOwnedSlice(p.b.a);
                        if (p.syntax == .apache and std.mem.startsWith(u8, args[0], "</")) {
                            if (args.len != 1 or !std.mem.endsWith(u8, args[0], ">") or closing == null or !eql(args[0][2 .. args[0].len - 1], closing.?)) return p.fail("mismatched closing section");
                            return nodes.toOwnedSlice(p.b.a);
                        }
                        var name = args[0];
                        var children: ?[]Node = null;
                        if (p.syntax == .apache and std.mem.startsWith(u8, name, "<")) {
                            const last = args.len - 1;
                            if (!std.mem.endsWith(u8, args[last], ">")) return p.fail("section is missing >");
                            args[last] = args[last][0 .. args[last].len - 1];
                            name = args[0][1..];
                            children = try p.block(name, depth + 1);
                        }
                        try nodes.append(p.b.a, .{ .name = name, .args = args[1..], .children = children, .file = p.file, .line = start });
                    }
                    if (tok == .close) {
                        if (closing == null) return p.fail("unexpected }");
                        return nodes.toOwnedSlice(p.b.a);
                    }
                    if (tok == .eof) {
                        if (closing != null) return p.fail("unclosed section");
                        return nodes.toOwnedSlice(p.b.a);
                    }
                },
            }
        }
    }
};

test "shared syntax handles quoted values, blocks and continuations" {
    var diag: Diag = .{ .gpa = std.testing.allocator };
    defer diag.deinit();
    var b = try Builder.init(std.testing.allocator, "test", "/tmp", &diag);
    defer destroy(std.testing.allocator, b.cfg);
    const tree = try b.parse("site {\n root \"/a b\"\n}\n", "test", .braces);
    try std.testing.expectEqualStrings("/a b", tree[0].children.?[0].args[0]);
    try std.testing.expectError(error.ConfigFailed, b.parse("<VirtualHost *:80>\n</Directory>\n", "test", .apache));
}
