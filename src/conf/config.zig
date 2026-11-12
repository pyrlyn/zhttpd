//! Semantic configuration built from the nginx.conf AST.
//!
//! Inheritance follows nginx's merge rules: a level starts as a copy of its parent
//! (http -> server -> location -> nested location / if); list directives (`add_header`,
//! `error_page`, `proxy_set_header`, `allow`/`deny`, `index`, `access_log`) are inherited
//! only when the current level defines none of them; `try_files`, `proxy_pass`, `alias`,
//! `internal` and rewrite-module statements are never inherited.
//! Simple directives of a level are applied before its nested blocks are built, so their
//! position in the file relative to `location` blocks does not matter (as in nginx).
const std = @import("std");
const os = @import("../os.zig");
const Regex = @import("../regex.zig").Regex;
const parser = @import("parser.zig");
const Directive = parser.Directive;
const Diag = @import("diag.zig").Diag;
const dirs = @import("directives.zig");
const expr = @import("expr.zig");
const Expr = expr.Expr;
const addr_mod = @import("addr.zig");
const Addr = addr_mod.Addr;
const Cidr = addr_mod.Cidr;

pub const Error = error{ ConfigFailed, OutOfMemory, BadVariable };

pub const Options = struct {
    /// `-p`: prefix for relative paths (root, logs, pid).
    prefix: []const u8,
    /// Directory of the main config file: prefix for `include` and certificates.
    conf_prefix: []const u8,
    /// `--strict`: unknown directives are errors.
    strict: bool = false,
    /// Do not report "accepted but ignored" directives (they are still counted).
    quiet_ignored: bool = false,
};

pub const Mime = std.StringHashMapUnmanaged([]const u8);

pub const ErrorPage = struct { codes: []const u16, override: ?u16, use_page_status: bool, uri: Expr };
pub const AddHeader = struct { name: []const u8, value: Expr, always: bool };
pub const HeaderSet = struct { name: []const u8, value: Expr };
pub const AccessRule = struct { allow: bool, all: bool, cidr: Cidr = undefined };
pub const LogFormat = struct { name: []const u8, expr: Expr };
pub const AccessLog = struct { path: []const u8, format: *const LogFormat };
pub const Expires = union(enum) { epoch, max, offset: i64, modified: i64 };

pub const Upstream = struct {
    name: []const u8,
    addrs: []Addr,
    rr: usize = 0,
};

pub const Proxy = struct {
    upstream: *Upstream,
    /// URI part of proxy_pass (`http://b/api/` -> "/api/"), null if none was given.
    uri: ?Expr,
    /// $proxy_host: "host:port" (port omitted when 80) or upstream name.
    host: []const u8,
    port: u16,
    /// `proxy_pass http://$var...`: host[:port] evaluated per request; it must name an
    /// `upstream` block or be a literal IP[:port] (zhttpd has no runtime DNS resolver).
    dyn_host: ?Expr = null,
};

pub const CondKind = enum { truthy, eq, ne, re, file_f, file_d, file_e, file_x };
pub const Cond = struct {
    kind: CondKind,
    neg: bool = false,
    a: Expr,
    b: Expr = .{ .parts = &.{}, .raw = "" },
    re: ?*Regex = null,
};

pub const RewriteFlag = enum { none, last, brk, redirect, permanent };

pub const Stmt = union(enum) {
    ret: struct { code: u16, text: ?Expr },
    rewrite: struct { re: *Regex, repl: Expr, flag: RewriteFlag },
    set: struct { name: []const u8, value: Expr },
    brk,
    if_: struct { cond: Cond, body: []Stmt, conf: ?*LocConf },
};

pub const IfModifiedSince = enum { off, exact, before };
pub const ServerTokens = enum { on, off, build };

pub const LimitExcept = struct { methods: []const []const u8, access: []AccessRule };

const SetFlags = packed struct {
    index: bool = false,
    error_page: bool = false,
    add_header: bool = false,
    access: bool = false,
    access_log: bool = false,
    proxy_set_header: bool = false,
    proxy_hide: bool = false,
};

pub const LocConf = struct {
    root: Expr,
    alias: ?Expr = null,
    index: []Expr,
    try_files: ?[]Expr = null,
    error_pages: []ErrorPage = &.{},
    add_headers: []AddHeader = &.{},
    access: []AccessRule = &.{},
    access_logs: ?[]AccessLog, // null = off
    client_max_body_size: u64 = 1024 * 1024,
    proxy: ?Proxy = null,
    proxy_set_headers: []HeaderSet = &.{},
    proxy_hide_headers: []const []const u8 = &.{},
    proxy_http_11: bool = true, // nginx >= 1.29 default
    proxy_pass_request_headers: bool = true,
    proxy_intercept_errors: bool = false,
    proxy_connect_timeout_ms: u32 = 60_000,
    proxy_read_timeout_ms: u32 = 60_000,
    proxy_send_timeout_ms: u32 = 60_000,
    unsupported_handler: ?[]const u8 = null, // fastcgi_pass etc: answer 502
    default_type: []const u8 = "text/plain",
    types: *const Mime,
    charset: ?[]const u8 = null,
    internal: bool = false,
    absolute_redirect: bool = true,
    server_name_in_redirect: bool = false,
    port_in_redirect: bool = true,
    keepalive_timeout_ms: u32 = 75_000,
    keepalive_requests: u32 = 1000,
    client_body_timeout_ms: u32 = 60_000,
    send_timeout_ms: u32 = 60_000,
    sendfile: bool = false,
    sendfile_max_chunk: u64 = 2 * 1024 * 1024,
    tcp_nodelay: bool = true,
    server_tokens: ServerTokens = .on,
    autoindex: bool = false,
    expires: ?Expires = null,
    etag: bool = true,
    if_modified_since: IfModifiedSince = .exact,
    log_not_found: bool = true,
    open_file_cache: OpenFileCache = .{},
    chunked_transfer_encoding: bool = true,
    limit_except: ?LimitExcept = null,
    set_flags: SetFlags = .{},
};

/// open_file_cache* settings; max == 0 means off.
pub const OpenFileCache = struct {
    max: u32 = 0,
    inactive_ms: u32 = 60_000,
    valid_ms: u32 = 60_000,
    min_uses: u32 = 1,
    errors: bool = false,
};

pub const LocKind = enum { exact, prefix, prefix_noregex, regex, regex_icase, named };

pub const Location = struct {
    kind: LocKind,
    name: []const u8, // pattern / prefix / @name
    re: ?*Regex = null,
    conf: *LocConf,
    stmts: []Stmt = &.{},
    children: []*Location = &.{},
    file: []const u8,
    line: u32,
};

pub const ServerName = union(enum) {
    exact: []const u8, // lowercase; "" and "_" kept verbatim
    lead: []const u8, // "*.example.com" -> ".example.com"
    lead_dot: []const u8, // ".example.com" -> "example.com" (matches it and all subdomains)
    trail: []const u8, // "www.example.*" -> "www.example."
    re: *Regex,
};

pub const SessionCache = enum { none, off, builtin };

pub const Tls = struct {
    certificate: ?[]const u8 = null,
    certificate_key: ?[]const u8 = null,
    protocols: []const []const u8 = &.{ "TLSv1.2", "TLSv1.3" },
    ciphers: ?[]const u8 = null,
    conf_commands: []const [2][]const u8 = &.{},
    prefer_server_ciphers: bool = false,
    session_cache: SessionCache = .none,
    session_cache_size: u32 = 0,
    session_timeout_s: u32 = 300,
    session_tickets: bool = true,
    ecdh_curve: ?[]const u8 = null,
    reject_handshake: bool = false,
};

pub const Server = struct {
    index: usize,
    names: []ServerName,
    primary_name: []const u8,
    conf: *LocConf,
    stmts: []Stmt = &.{},
    locations: []*Location = &.{},
    named: []*Location = &.{},
    tls: Tls = .{},
    client_header_timeout_ms: u32 = 60_000,
    merge_slashes: bool = true,
    file: []const u8,
    line: u32,
};

pub const ListenOpts = struct { default_server: bool = false, ssl: bool = false, reuseport: bool = false, backlog: i32 = 511, ipv6only: bool = true };

/// One socket the workers listen on.
pub const Listen = struct {
    addr: Addr,
    opts: ListenOpts,
    /// Servers reachable through this socket with the address they asked for
    /// (a wildcard socket also serves servers listening on a concrete IP of the same port).
    entries: []Entry,
    pub const Entry = struct { addr: Addr, server: *Server, default: bool };

    pub fn defaultFor(l: *const Listen, local: Addr) *Server {
        var first: ?*Server = null;
        for (l.entries) |e| {
            if (!(e.addr.isWildcard() or e.addr.sameHost(local))) continue;
            if (e.default) return e.server;
            if (first == null) first = e.server;
        }
        return first orelse l.entries[0].server;
    }
};

pub const MapRegex = struct { re: *Regex, value: Expr };

pub const Map = struct {
    source: Expr,
    target: []const u8, // variable name without '$'
    default: Expr,
    hostnames: bool = false,
    exact: std.StringHashMapUnmanaged(Expr) = .empty,
    regexes: []const MapRegex = &.{},
};

pub const ErrorLog = struct { path: []const u8, level: u8 = 3 }; // 0 emerg .. 7 debug

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    ast: parser.Ast,
    prefix: []const u8,
    conf_file: []const u8,
    worker_processes: u32 = 1,
    worker_connections: u32 = 512,
    worker_rlimit_nofile: ?u64 = null,
    multi_accept: bool = false,
    event_method: ?[]const u8 = null,
    pid_path: ?[]const u8 = null,
    error_log: ErrorLog = .{ .path = "logs/error.log" },
    has_http: bool = false,
    servers: []*Server = &.{},
    listens: []Listen = &.{},
    upstreams: []*Upstream = &.{},
    maps: []Map = &.{},
    log_formats: []*LogFormat = &.{},
    /// largest open_file_cache max= anywhere in the config (per-worker cache size)
    open_file_cache_max: u32 = 0,
    ignored_count: usize = 0,
    unknown_count: usize = 0,

    pub fn deinit(c: *Config) void {
        c.ast.deinit();
        c.arena.deinit();
    }

    pub fn findMap(c: *const Config, name: []const u8) ?*const Map {
        for (c.maps) |*m| if (std.mem.eql(u8, m.target, name)) return m;
        return null;
    }
};

// ------------------------------------------------------------------ builder

const PendingListen = struct { addr: Addr, opts: ListenOpts, server: *Server };
const PendingProxy = struct { conf: *LocConf, target: []const u8, d: *const Directive };

const Builder = struct {
    a: std.mem.Allocator,
    gpa: std.mem.Allocator,
    diag: *Diag,
    opts: Options,
    cfg: *Config,
    http_tls: Tls = .{},
    http_header_timeout_ms: u32 = 60_000,
    http_merge_slashes: bool = true,
    servers: std.ArrayList(*Server) = .empty,
    upstreams: std.ArrayList(*Upstream) = .empty,
    maps: std.ArrayList(Map) = .empty,
    log_formats: std.ArrayList(*LogFormat) = .empty,
    pending_listens: std.ArrayList(PendingListen) = .empty,
    pending_proxies: std.ArrayList(PendingProxy) = .empty,
    warned: std.StringHashMapUnmanaged(void) = .empty,
    failed: bool = false,

    fn emerg(b: *Builder, d: *const Directive, comptime fmt: []const u8, args: anytype) void {
        b.diag.add(.emerg, d.file, d.line, fmt, args);
        b.failed = true;
    }
    fn warn(b: *Builder, d: *const Directive, comptime fmt: []const u8, args: anytype) void {
        b.diag.add(.warn, d.file, d.line, fmt, args);
    }

    fn fullPath(b: *Builder, p: []const u8) ![]const u8 {
        return parser.fullName(b.a, b.opts.prefix, p);
    }

    /// Certificates are relative to the conf prefix (like nginx).
    fn fullConfPath(b: *Builder, p: []const u8) ![]const u8 {
        return parser.fullName(b.a, b.opts.conf_prefix, p);
    }

    /// Validate a directive against the table for `ctx`. Returns the spec when the
    /// directive should be processed further, null when it is ignored/unknown/invalid.
    fn check(b: *Builder, d: *const Directive, ctx: dirs.Ctx) ?*const dirs.Spec {
        const spec = dirs.lookup(d.name, ctx) orelse {
            if (b.opts.strict) {
                b.emerg(d, "unknown directive \"{s}\"", .{d.name});
            } else {
                b.cfg.unknown_count += 1;
                b.warn(d, "unknown directive \"{s}\" ignored", .{d.name});
            }
            return null;
        };
        if (!spec.ctx.has(ctx)) {
            b.emerg(d, "\"{s}\" directive is not allowed here", .{d.name});
            return null;
        }
        if (spec.block and d.block == null) {
            b.emerg(d, "directive \"{s}\" has no opening \"{{\"", .{d.name});
            return null;
        }
        if (!spec.block and d.block != null) {
            b.emerg(d, "directive \"{s}\" is not terminated by \";\"", .{d.name});
            return null;
        }
        if (!dirs.argsOk(spec.args, d.args.len)) {
            b.emerg(d, "invalid number of arguments in \"{s}\" directive", .{d.name});
            return null;
        }
        if (spec.args == .flag and !(eq(d.args[0], "on") or eq(d.args[0], "off"))) {
            b.emerg(d, "invalid value \"{s}\" in \"{s}\" directive, it must be \"on\" or \"off\"", .{ d.args[0], d.name });
            return null;
        }
        if (spec.status == .ignored) {
            b.cfg.ignored_count += 1;
            const gop = b.warned.getOrPut(b.a, d.name) catch return null;
            if (!gop.found_existing and !b.opts.quiet_ignored)
                b.warn(d, "\"{s}\" directive is not implemented by zhttpd, ignored{s}{s}", .{ d.name, if (spec.note.len > 0) ": " else "", spec.note });
            if (std.mem.startsWith(u8, d.name, "auth_") and !eq(d.args[0], "off"))
                b.warn(d, "SECURITY: \"{s}\" is not enforced, the location is served without authentication", .{d.name});
            return null;
        }
        return spec;
    }

    fn flag(d: *const Directive) bool {
        return eq(d.args[0], "on");
    }

    fn compileExpr(b: *Builder, d: *const Directive, s: []const u8) Expr {
        return expr.compile(b.a, s) catch {
            b.emerg(d, "invalid variable name in \"{s}\"", .{s});
            return .{ .parts = &.{}, .raw = s };
        };
    }

    fn compileRegex(b: *Builder, d: *const Directive, pat: []const u8, icase: bool) ?*Regex {
        const re = b.a.create(Regex) catch return null;
        re.* = Regex.compile(b.a, pat, icase) catch {
            b.emerg(d, "regular expression \"{s}\" is not supported by the zhttpd regex engine (backreferences, lookbehind and atomic groups are not implemented)", .{pat});
            return null;
        };
        return re;
    }

    // ---- main

    fn buildMain(b: *Builder, root: []Directive) Error!void {
        const ctx: dirs.Ctx = .{ .main = true };
        for (root) |*d| {
            _ = b.check(d, ctx) orelse continue;
            const n = d.name;
            if (eq(n, "worker_processes")) {
                if (eq(d.args[0], "auto")) {
                    b.cfg.worker_processes = os.ncpu();
                } else {
                    b.cfg.worker_processes = std.fmt.parseInt(u32, d.args[0], 10) catch {
                        b.emerg(d, "invalid value \"{s}\" in \"worker_processes\" directive", .{d.args[0]});
                        continue;
                    };
                }
            } else if (eq(n, "worker_rlimit_nofile")) {
                b.cfg.worker_rlimit_nofile = std.fmt.parseInt(u64, d.args[0], 10) catch null;
            } else if (eq(n, "pid")) {
                b.cfg.pid_path = if (eq(d.args[0], "off")) null else try b.fullPath(d.args[0]);
            } else if (eq(n, "error_log")) {
                b.cfg.error_log = try b.parseErrorLog(d);
            } else if (eq(n, "events")) {
                try b.buildEvents(d.block.?);
            } else if (eq(n, "http")) {
                if (b.cfg.has_http) {
                    b.emerg(d, "\"http\" directive is duplicate", .{});
                    continue;
                }
                b.cfg.has_http = true;
                try b.buildHttp(d.block.?);
            }
        }
    }

    fn parseErrorLog(b: *Builder, d: *const Directive) !ErrorLog {
        var el: ErrorLog = .{ .path = "stderr" };
        const p = d.args[0];
        if (eq(p, "stderr") or eq(p, "/dev/stderr")) {} else if (std.mem.startsWith(u8, p, "syslog:") or std.mem.startsWith(u8, p, "memory:")) {
            b.warn(d, "error_log target \"{s}\" is not supported, using stderr", .{p});
        } else el.path = try b.fullPath(p);
        if (d.args.len > 1) {
            const levels = [_][]const u8{ "emerg", "alert", "crit", "error", "warn", "notice", "info", "debug" };
            for (levels, 0..) |l, i| {
                if (eq(d.args[1], l)) el.level = @intCast(i);
            }
        }
        return el;
    }

    fn buildEvents(b: *Builder, block: []Directive) Error!void {
        const ctx: dirs.Ctx = .{ .events = true };
        for (block) |*d| {
            _ = b.check(d, ctx) orelse continue;
            if (eq(d.name, "worker_connections")) {
                b.cfg.worker_connections = std.fmt.parseInt(u32, d.args[0], 10) catch {
                    b.emerg(d, "invalid number \"{s}\"", .{d.args[0]});
                    continue;
                };
            } else if (eq(d.name, "multi_accept")) {
                b.cfg.multi_accept = flag(d);
            } else if (eq(d.name, "use")) {
                const want = if (os.is_linux) "epoll" else "kqueue";
                if (!eq(d.args[0], want)) {
                    b.emerg(d, "invalid event type \"{s}\"", .{d.args[0]});
                    continue;
                }
                b.cfg.event_method = d.args[0];
            }
        }
    }

    // ---- http

    fn defaultLocConf(b: *Builder) !*LocConf {
        const types = try b.a.create(Mime);
        types.* = .empty;
        // nginx's built-in types when no `types` block is configured
        try types.put(b.a, "html", "text/html");
        try types.put(b.a, "gif", "image/gif");
        try types.put(b.a, "jpg", "image/jpeg");
        const lc = try b.a.create(LocConf);
        const idx = try b.a.alloc(Expr, 1);
        idx[0] = try expr.compile(b.a, "index.html");
        lc.* = .{
            .root = try expr.compile(b.a, try b.fullPath("html")),
            .index = idx,
            .access_logs = null,
            .types = types,
        };
        return lc;
    }

    /// New level inheriting from `parent`, with non-inherited fields reset.
    fn child(b: *Builder, parent: *const LocConf) !*LocConf {
        const lc = try b.a.create(LocConf);
        lc.* = parent.*;
        lc.try_files = null;
        lc.proxy = null;
        lc.alias = null;
        lc.internal = false;
        lc.unsupported_handler = null;
        lc.limit_except = null;
        lc.set_flags = .{};
        return lc;
    }

    fn buildHttp(b: *Builder, block: []Directive) Error!void {
        const ctx: dirs.Ctx = .{ .http = true };
        const lc = try b.defaultLocConf();
        const combined = try b.a.create(LogFormat);
        combined.* = .{ .name = "combined", .expr = try expr.compile(b.a, "$remote_addr - $remote_user [$time_local] \"$request\" $status $body_bytes_sent \"$http_referer\" \"$http_user_agent\"") };
        try b.log_formats.append(b.a, combined);
        // log_format, upstream and map are global and may be referenced before their position
        for (block) |*d| {
            if (!eq(d.name, "log_format")) continue;
            _ = b.check(d, ctx) orelse continue;
            var s: std.ArrayList(u8) = .empty;
            var start: usize = 1;
            if (d.args.len > 2 and std.mem.startsWith(u8, d.args[1], "escape=")) start = 2;
            for (d.args[start..]) |part| try s.appendSlice(b.a, part);
            const f = try b.a.create(LogFormat);
            f.* = .{ .name = d.args[0], .expr = b.compileExpr(d, s.items) };
            try b.log_formats.append(b.a, f);
        }
        const logs = try b.a.alloc(AccessLog, 1);
        logs[0] = .{ .path = try b.fullPath("logs/access.log"), .format = combined };
        lc.access_logs = logs;
        for (block) |*d| {
            if (eq(d.name, "upstream")) {
                _ = b.check(d, ctx) orelse continue;
                try b.buildUpstream(d);
            } else if (eq(d.name, "map")) {
                _ = b.check(d, ctx) orelse continue;
                try b.buildMap(d);
            }
        }
        try b.applySimple(lc, block, ctx, null);
        for (block) |*d| {
            if (!eq(d.name, "server")) continue;
            _ = b.check(d, ctx) orelse continue;
            try b.buildServer(d, lc);
        }
        b.cfg.servers = try b.servers.toOwnedSlice(b.a);
        b.cfg.upstreams = try b.upstreams.toOwnedSlice(b.a);
        b.cfg.maps = try b.maps.toOwnedSlice(b.a);
        b.cfg.log_formats = try b.log_formats.toOwnedSlice(b.a);
        try b.resolveProxies();
        try b.groupListens();
    }

    fn buildUpstream(b: *Builder, d: *const Directive) !void {
        const u = try b.a.create(Upstream);
        var addrs: std.ArrayList(Addr) = .empty;
        for (d.block.?) |*sd| {
            _ = b.check(sd, .{ .ups = true }) orelse continue;
            if (!eq(sd.name, "server")) continue;
            if (sd.args.len < 1) {
                b.emerg(sd, "invalid number of arguments in \"server\" directive", .{});
                continue;
            }
            for (sd.args[1..]) |p| {
                const gop = try b.warned.getOrPut(b.a, p);
                if (!gop.found_existing) b.warn(sd, "upstream server parameter \"{s}\" ignored", .{p});
            }
            try b.resolveInto(sd, sd.args[0], 80, &addrs);
        }
        if (addrs.items.len == 0) b.emerg(d, "no servers are inside upstream", .{});
        u.* = .{ .name = d.args[0], .addrs = try addrs.toOwnedSlice(b.a) };
        try b.upstreams.append(b.a, u);
    }

    fn resolveInto(b: *Builder, d: *const Directive, hostport: []const u8, default_port: u16, out: *std.ArrayList(Addr)) !void {
        if (addr_mod.parseHostPort(hostport, default_port)) |hp| {
            try out.append(b.a, hp.addr);
            return;
        }
        // hostname: resolved once via getaddrinfo (nginx also resolves at startup)
        var host = hostport;
        var port = default_port;
        if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |c| {
            port = std.fmt.parseInt(u16, hostport[c + 1 ..], 10) catch {
                b.emerg(d, "invalid port in \"{s}\"", .{hostport});
                return;
            };
            host = hostport[0..c];
        }
        if (!os.resolve(b.a, host, port, out)) {
            b.emerg(d, "host not found in \"{s}\"", .{hostport});
        }
    }

    fn buildMap(b: *Builder, d: *const Directive) !void {
        if (d.args[1].len < 2 or d.args[1][0] != '$') {
            b.emerg(d, "invalid variable name \"{s}\"", .{d.args[1]});
            return;
        }
        var m: Map = .{ .source = b.compileExpr(d, d.args[0]), .target = d.args[1][1..], .default = .{ .parts = &.{}, .raw = "" } };
        var res: std.ArrayList(MapRegex) = .empty;
        for (d.block.?) |*e| {
            if (e.block != null) {
                b.emerg(e, "unexpected \"{{\"", .{});
                continue;
            }
            if (eq(e.name, "hostnames") and e.args.len == 0) {
                m.hostnames = true;
                continue;
            }
            if (eq(e.name, "volatile") and e.args.len == 0) continue;
            if (e.args.len != 1) {
                b.emerg(e, "invalid number of the map parameters", .{});
                continue;
            }
            const val = b.compileExpr(e, e.args[0]);
            if (eq(e.name, "default")) {
                m.default = val;
            } else if (e.name.len > 1 and e.name[0] == '~') {
                const icase = e.name.len > 2 and e.name[1] == '*';
                const pat = e.name[if (icase) 2 else 1..];
                const re = b.compileRegex(e, pat, icase) orelse continue;
                try res.append(b.a, .{ .re = re, .value = val });
            } else {
                const key = if (e.name.len > 0 and e.name[0] == '\\') e.name[1..] else e.name;
                const k = if (m.hostnames) try std.ascii.allocLowerString(b.a, key) else key;
                try m.exact.put(b.a, k, val);
            }
        }
        m.regexes = try res.toOwnedSlice(b.a);
        try b.maps.append(b.a, m);
    }

    // ---- simple (non-block) directives shared by http/server/location/if

    fn applySimple(b: *Builder, lc: *LocConf, block: []Directive, ctx: dirs.Ctx, srv: ?*Server) Error!void {
        for (block) |*d| {
            const n = d.name;
            if (eq(n, "log_format") or eq(n, "upstream") or eq(n, "map")) continue;
            if (ctx.srv and (eq(n, "listen") or eq(n, "server_name"))) continue;
            if ((ctx.srv or ctx.loc) and eq(n, "location")) continue;
            if (ctx.http and eq(n, "server")) continue;
            if (isRewriteStmt(n)) continue;
            _ = b.check(d, ctx) orelse {
                // content handlers we do not implement: the location answers 502 instead
                // of silently serving files from root (which could leak e.g. PHP sources)
                if (isForeignHandler(n)) lc.unsupported_handler = n;
                continue;
            };
            try b.applyOne(lc, d, srv);
        }
    }

    fn isForeignHandler(n: []const u8) bool {
        const list = [_][]const u8{ "fastcgi_pass", "uwsgi_pass", "scgi_pass", "grpc_pass", "memcached_pass" };
        for (list) |x| if (eq(n, x)) return true;
        return false;
    }

    fn isRewriteStmt(n: []const u8) bool {
        return eq(n, "return") or eq(n, "rewrite") or eq(n, "set") or eq(n, "break") or eq(n, "if");
    }

    fn applyOne(b: *Builder, lc: *LocConf, d: *const Directive, srv: ?*Server) Error!void {
        const n = d.name;
        const a0 = if (d.args.len > 0) d.args[0] else "";
        if (eq(n, "root") or eq(n, "alias")) {
            if (eq(n, "root") and lc.alias != null) return b.emerg(d, "\"root\" directive is duplicate, \"alias\" directive was specified earlier", .{});
            const p = if (a0.len > 0 and a0[0] != '/' and a0[0] != '$') try b.fullPath(a0) else a0;
            // nginx drops a trailing slash on root
            const trimmed = if (eq(n, "root") and p.len > 1 and p[p.len - 1] == '/') p[0 .. p.len - 1] else p;
            const e = b.compileExpr(d, trimmed);
            if (eq(n, "root")) lc.root = e else lc.alias = e;
        } else if (eq(n, "index")) {
            const list = try b.a.alloc(Expr, d.args.len);
            for (d.args, 0..) |x, i| list[i] = b.compileExpr(d, x);
            lc.index = list;
            lc.set_flags.index = true;
        } else if (eq(n, "try_files")) {
            const list = try b.a.alloc(Expr, d.args.len);
            for (d.args, 0..) |x, i| list[i] = b.compileExpr(d, x);
            lc.try_files = list;
        } else if (eq(n, "error_page")) {
            if (!lc.set_flags.error_page) {
                lc.error_pages = &.{};
                lc.set_flags.error_page = true;
            }
            var codes: std.ArrayList(u16) = .empty;
            var override: ?u16 = null;
            var use_page = false;
            for (d.args[0 .. d.args.len - 1]) |x| {
                if (x.len > 0 and x[0] == '=') {
                    if (x.len == 1) {
                        use_page = true;
                    } else {
                        override = std.fmt.parseInt(u16, x[1..], 10) catch return b.emerg(d, "invalid value \"{s}\"", .{x});
                    }
                    continue;
                }
                const code = std.fmt.parseInt(u16, x, 10) catch return b.emerg(d, "invalid value \"{s}\"", .{x});
                if (code < 300 or code > 599) return b.emerg(d, "value \"{s}\" must be between 300 and 599", .{x});
                try codes.append(b.a, code);
            }
            lc.error_pages = try append(b.a, ErrorPage, lc.error_pages, .{ .codes = try codes.toOwnedSlice(b.a), .override = override, .use_page_status = use_page, .uri = b.compileExpr(d, d.args[d.args.len - 1]) });
        } else if (eq(n, "add_header")) {
            if (!lc.set_flags.add_header) {
                lc.add_headers = &.{};
                lc.set_flags.add_header = true;
            }
            const always = d.args.len == 3 and eq(d.args[2], "always");
            if (d.args.len == 3 and !always) return b.emerg(d, "invalid parameter \"{s}\"", .{d.args[2]});
            lc.add_headers = try append(b.a, AddHeader, lc.add_headers, .{ .name = d.args[0], .value = b.compileExpr(d, d.args[1]), .always = always });
        } else if (eq(n, "allow") or eq(n, "deny")) {
            if (!lc.set_flags.access) {
                lc.access = &.{};
                lc.set_flags.access = true;
            }
            lc.access = try append(b.a, AccessRule, lc.access, b.accessRule(d));
        } else if (eq(n, "access_log")) {
            if (eq(a0, "off")) {
                lc.access_logs = null;
                lc.set_flags.access_log = true;
                return;
            }
            if (!lc.set_flags.access_log or lc.access_logs == null) {
                lc.access_logs = &.{};
                lc.set_flags.access_log = true;
            }
            var fmt: *const LogFormat = b.log_formats.items[0];
            if (d.args.len > 1 and std.mem.indexOfScalar(u8, d.args[1], '=') == null) {
                var found = false;
                for (b.log_formats.items) |f| {
                    if (eq(f.name, d.args[1])) {
                        fmt = f;
                        found = true;
                    }
                }
                if (!found) return b.emerg(d, "unknown log format \"{s}\"", .{d.args[1]});
            }
            const path = if (eq(a0, "stderr") or eq(a0, "/dev/stderr") or eq(a0, "/dev/stdout")) a0 else if (std.mem.startsWith(u8, a0, "syslog:")) blk: {
                b.warn(d, "access_log syslog target is not supported, using stderr", .{});
                break :blk "stderr";
            } else try b.fullPath(a0);
            lc.access_logs = try append(b.a, AccessLog, lc.access_logs.?, .{ .path = path, .format = fmt });
        } else if (eq(n, "client_max_body_size")) {
            lc.client_max_body_size = parseSize(a0) orelse return b.emerg(d, "\"client_max_body_size\" directive invalid value", .{});
        } else if (eq(n, "proxy_pass")) {
            try b.pending_proxies.append(b.a, .{ .conf = lc, .target = a0, .d = d });
        } else if (eq(n, "proxy_set_header")) {
            if (!lc.set_flags.proxy_set_header) {
                lc.proxy_set_headers = &.{};
                lc.set_flags.proxy_set_header = true;
            }
            lc.proxy_set_headers = try append(b.a, HeaderSet, lc.proxy_set_headers, .{ .name = d.args[0], .value = b.compileExpr(d, d.args[1]) });
        } else if (eq(n, "proxy_hide_header")) {
            if (!lc.set_flags.proxy_hide) {
                lc.proxy_hide_headers = &.{};
                lc.set_flags.proxy_hide = true;
            }
            lc.proxy_hide_headers = try append(b.a, []const u8, lc.proxy_hide_headers, a0);
        } else if (eq(n, "proxy_http_version")) {
            lc.proxy_http_11 = eq(a0, "1.1");
        } else if (eq(n, "proxy_pass_request_headers")) {
            lc.proxy_pass_request_headers = flag(d);
        } else if (eq(n, "proxy_intercept_errors")) {
            lc.proxy_intercept_errors = flag(d);
        } else if (eq(n, "proxy_connect_timeout")) {
            lc.proxy_connect_timeout_ms = b.timeArg(d) orelse return;
        } else if (eq(n, "proxy_read_timeout")) {
            lc.proxy_read_timeout_ms = b.timeArg(d) orelse return;
        } else if (eq(n, "proxy_send_timeout")) {
            lc.proxy_send_timeout_ms = b.timeArg(d) orelse return;
        } else if (eq(n, "default_type")) {
            lc.default_type = a0;
        } else if (eq(n, "types")) {
            const m = try b.a.create(Mime);
            m.* = .empty;
            for (d.block.?) |*t| {
                if (t.block != null) continue;
                for (t.args) |ext| try m.put(b.a, try std.ascii.allocLowerString(b.a, ext), t.name);
            }
            lc.types = m;
        } else if (eq(n, "charset")) {
            lc.charset = if (eq(a0, "off")) null else a0;
        } else if (eq(n, "internal")) {
            lc.internal = true;
        } else if (eq(n, "absolute_redirect")) {
            lc.absolute_redirect = flag(d);
        } else if (eq(n, "server_name_in_redirect")) {
            lc.server_name_in_redirect = flag(d);
        } else if (eq(n, "port_in_redirect")) {
            lc.port_in_redirect = flag(d);
        } else if (eq(n, "keepalive_timeout")) {
            lc.keepalive_timeout_ms = b.timeArg(d) orelse return;
        } else if (eq(n, "keepalive_requests")) {
            lc.keepalive_requests = std.fmt.parseInt(u32, a0, 10) catch return b.emerg(d, "invalid number \"{s}\"", .{a0});
        } else if (eq(n, "client_body_timeout")) {
            lc.client_body_timeout_ms = b.timeArg(d) orelse return;
        } else if (eq(n, "client_header_timeout")) {
            const v = b.timeArg(d) orelse return;
            if (srv) |s| s.client_header_timeout_ms = v else b.http_header_timeout_ms = v;
        } else if (eq(n, "merge_slashes")) {
            if (srv) |s| s.merge_slashes = flag(d) else b.http_merge_slashes = flag(d);
        } else if (eq(n, "send_timeout")) {
            lc.send_timeout_ms = b.timeArg(d) orelse return;
        } else if (eq(n, "sendfile")) {
            lc.sendfile = flag(d);
        } else if (eq(n, "sendfile_max_chunk")) {
            lc.sendfile_max_chunk = parseSize(a0) orelse return b.emerg(d, "\"sendfile_max_chunk\" directive invalid value", .{});
        } else if (eq(n, "tcp_nodelay")) {
            lc.tcp_nodelay = flag(d);
        } else if (eq(n, "server_tokens")) {
            lc.server_tokens = if (eq(a0, "off")) .off else if (eq(a0, "build")) .build else .on;
        } else if (eq(n, "autoindex")) {
            lc.autoindex = flag(d);
        } else if (eq(n, "etag")) {
            lc.etag = flag(d);
        } else if (eq(n, "log_not_found")) {
            lc.log_not_found = flag(d);
        } else if (eq(n, "open_file_cache")) {
            if (eq(a0, "off")) {
                lc.open_file_cache.max = 0;
            } else {
                var ofc = lc.open_file_cache;
                ofc.inactive_ms = 60_000;
                ofc.max = 0;
                for (d.args) |arg| {
                    if (std.mem.startsWith(u8, arg, "max=")) {
                        ofc.max = std.fmt.parseInt(u32, arg[4..], 10) catch 0;
                    } else if (std.mem.startsWith(u8, arg, "inactive=")) {
                        ofc.inactive_ms = parseTimeMs(arg[9..]) orelse return b.emerg(d, "invalid \"open_file_cache\" parameter \"{s}\"", .{arg});
                    } else return b.emerg(d, "invalid \"open_file_cache\" parameter \"{s}\"", .{arg});
                }
                if (ofc.max == 0) return b.emerg(d, "\"open_file_cache\" must have the \"max\" parameter", .{});
                lc.open_file_cache = ofc;
                b.cfg.open_file_cache_max = @max(b.cfg.open_file_cache_max, ofc.max);
            }
        } else if (eq(n, "open_file_cache_valid")) {
            lc.open_file_cache.valid_ms = b.timeArg(d) orelse return;
        } else if (eq(n, "open_file_cache_min_uses")) {
            lc.open_file_cache.min_uses = std.fmt.parseInt(u32, a0, 10) catch return b.emerg(d, "invalid number \"{s}\"", .{a0});
        } else if (eq(n, "open_file_cache_errors")) {
            lc.open_file_cache.errors = flag(d);
        } else if (eq(n, "chunked_transfer_encoding")) {
            lc.chunked_transfer_encoding = flag(d);
        } else if (eq(n, "if_modified_since")) {
            lc.if_modified_since = if (eq(a0, "off")) .off else if (eq(a0, "before")) .before else .exact;
        } else if (eq(n, "expires")) {
            lc.expires = b.parseExpires(d);
        } else if (eq(n, "error_log")) {
            // server/location error logs are folded into the main error log
        } else if (eq(n, "limit_except")) {
            var rules: std.ArrayList(AccessRule) = .empty;
            for (d.block.?) |*x| {
                _ = b.check(x, .{ .lmt = true }) orelse continue;
                if (eq(x.name, "allow") or eq(x.name, "deny")) try rules.append(b.a, b.accessRule(x));
            }
            lc.limit_except = .{ .methods = d.args, .access = try rules.toOwnedSlice(b.a) };
        } else if (std.mem.startsWith(u8, n, "ssl_")) {
            try b.applySsl(if (srv) |s| &s.tls else &b.http_tls, d);
        }
    }

    fn applySsl(b: *Builder, t: *Tls, d: *const Directive) !void {
        const n = d.name;
        const a0 = d.args[0];
        if (eq(n, "ssl_certificate")) {
            t.certificate = try b.fullConfPath(a0);
        } else if (eq(n, "ssl_certificate_key")) {
            t.certificate_key = try b.fullConfPath(a0);
        } else if (eq(n, "ssl_protocols")) {
            t.protocols = d.args;
        } else if (eq(n, "ssl_ciphers")) {
            t.ciphers = a0;
        } else if (eq(n, "ssl_conf_command")) {
            t.conf_commands = try append(b.a, [2][]const u8, t.conf_commands, .{ d.args[0], d.args[1] });
        } else if (eq(n, "ssl_prefer_server_ciphers")) {
            t.prefer_server_ciphers = flag(d);
        } else if (eq(n, "ssl_session_cache")) {
            for (d.args) |x| {
                if (eq(x, "off")) {
                    t.session_cache = .off;
                } else if (eq(x, "none")) {
                    t.session_cache = .none;
                } else if (std.mem.startsWith(u8, x, "shared:")) {
                    t.session_cache = .builtin;
                    const last = std.mem.lastIndexOfScalar(u8, x, ':').?;
                    const bytes = parseSize(x[last + 1 ..]) orelse 1024 * 1024;
                    t.session_cache_size = @intCast(@min(bytes / 256, 1 << 30)); // ~4000 sessions per MB, like nginx
                } else if (std.mem.startsWith(u8, x, "builtin")) {
                    t.session_cache = .builtin;
                    t.session_cache_size = 20480;
                    if (std.mem.indexOfScalar(u8, x, ':')) |c| t.session_cache_size = std.fmt.parseInt(u32, x[c + 1 ..], 10) catch 20480;
                }
            }
        } else if (eq(n, "ssl_session_timeout")) {
            t.session_timeout_s = (b.timeArg(d) orelse return) / 1000;
        } else if (eq(n, "ssl_session_tickets")) {
            t.session_tickets = flag(d);
        } else if (eq(n, "ssl_ecdh_curve")) {
            t.ecdh_curve = a0;
        } else if (eq(n, "ssl_reject_handshake")) {
            t.reject_handshake = flag(d);
        }
    }

    fn timeArg(b: *Builder, d: *const Directive) ?u32 {
        return parseTimeMs(d.args[0]) orelse {
            b.emerg(d, "\"{s}\" directive invalid value", .{d.name});
            return null;
        };
    }

    fn parseExpires(b: *Builder, d: *const Directive) ?Expires {
        var i: usize = 0;
        var modified = false;
        if (eq(d.args[0], "modified")) {
            modified = true;
            i = 1;
            if (d.args.len < 2) return null;
        }
        const v = d.args[i];
        if (eq(v, "off")) return null;
        if (eq(v, "epoch")) return .epoch;
        if (eq(v, "max")) return .max;
        if (v.len > 0 and v[0] == '@') {
            b.warn(d, "\"expires @time\" is not supported, ignored", .{});
            return null;
        }
        const neg = v.len > 0 and v[0] == '-';
        const ms = parseTimeMs64(if (neg or (v.len > 0 and v[0] == '+')) v[1..] else v) orelse {
            b.emerg(d, "\"expires\" directive invalid value", .{});
            return null;
        };
        const secs: i64 = @as(i64, @intCast(@min(ms / 1000, std.math.maxInt(i32)))) * @as(i64, if (neg) -1 else 1);
        return if (modified) .{ .modified = secs } else .{ .offset = secs };
    }

    fn accessRule(b: *Builder, d: *const Directive) AccessRule {
        const allow = eq(d.name, "allow");
        if (eq(d.args[0], "all")) return .{ .allow = allow, .all = true };
        if (std.mem.startsWith(u8, d.args[0], "unix:")) return .{ .allow = allow, .all = false, .cidr = .{ .addr = .{}, .bits = 255 } };
        const c = Cidr.parse(d.args[0]) orelse {
            b.emerg(d, "invalid parameter \"{s}\"", .{d.args[0]});
            return .{ .allow = allow, .all = false, .cidr = .{ .addr = .{}, .bits = 255 } };
        };
        return .{ .allow = allow, .all = false, .cidr = c };
    }

    // ---- rewrite module statements

    fn buildStmts(b: *Builder, block: []Directive, ctx: dirs.Ctx, lc: *LocConf, srv: *Server) Error![]Stmt {
        var out: std.ArrayList(Stmt) = .empty;
        for (block) |*d| {
            if (!isRewriteStmt(d.name)) continue;
            _ = b.check(d, ctx) orelse continue;
            const n = d.name;
            if (eq(n, "return")) {
                const code = std.fmt.parseInt(u16, d.args[0], 10) catch {
                    const u = d.args[0];
                    if (d.args.len == 1 and (std.mem.startsWith(u8, u, "http://") or std.mem.startsWith(u8, u, "https://") or std.mem.startsWith(u8, u, "$scheme"))) {
                        try out.append(b.a, .{ .ret = .{ .code = 302, .text = b.compileExpr(d, u) } });
                    } else b.emerg(d, "invalid return code \"{s}\"", .{u});
                    continue;
                };
                if (code > 999) {
                    b.emerg(d, "invalid return code \"{s}\"", .{d.args[0]});
                    continue;
                }
                try out.append(b.a, .{ .ret = .{ .code = code, .text = if (d.args.len > 1) b.compileExpr(d, d.args[1]) else null } });
            } else if (eq(n, "rewrite")) {
                const re = b.compileRegex(d, d.args[0], false) orelse continue;
                var fl: RewriteFlag = .none;
                if (d.args.len == 3) {
                    const f = d.args[2];
                    fl = if (eq(f, "last")) .last else if (eq(f, "break")) .brk else if (eq(f, "redirect")) .redirect else if (eq(f, "permanent")) .permanent else {
                        b.emerg(d, "invalid parameter \"{s}\"", .{f});
                        continue;
                    };
                }
                try out.append(b.a, .{ .rewrite = .{ .re = re, .repl = b.compileExpr(d, d.args[1]), .flag = fl } });
            } else if (eq(n, "set")) {
                if (d.args[0].len < 2 or d.args[0][0] != '$') {
                    b.emerg(d, "invalid variable name \"{s}\"", .{d.args[0]});
                    continue;
                }
                try out.append(b.a, .{ .set = .{ .name = d.args[0][1..], .value = b.compileExpr(d, d.args[1]) } });
            } else if (eq(n, "break")) {
                try out.append(b.a, .brk);
            } else if (eq(n, "if")) {
                const cond = b.parseCond(d) orelse continue;
                const inner_ctx: dirs.Ctx = if (ctx.srv) .{ .sif = true } else .{ .lif = true };
                // non-rewrite directives inside `if` create a nested configuration (like nginx)
                var needs_conf = false;
                for (d.block.?) |*x| {
                    if (!isRewriteStmt(x.name)) needs_conf = true;
                }
                var ifconf: ?*LocConf = null;
                if (needs_conf) {
                    const c = try b.child(lc);
                    c.try_files = lc.try_files;
                    c.proxy = lc.proxy;
                    c.alias = lc.alias;
                    try b.applySimple(c, d.block.?, inner_ctx, srv);
                    ifconf = c;
                }
                const body = try b.buildStmts(d.block.?, inner_ctx, ifconf orelse lc, srv);
                try out.append(b.a, .{ .if_ = .{ .cond = cond, .body = body, .conf = ifconf } });
            }
        }
        return out.toOwnedSlice(b.a);
    }

    fn parseCond(b: *Builder, d: *const Directive) ?Cond {
        // `if ($a = b)` arrives as "($a", "=", "b)"; strip the parentheses.
        const items = b.a.dupe([]const u8, d.args) catch return null;
        if (items.len == 0 or items[0].len == 0 or items[0][0] != '(') {
            b.emerg(d, "invalid condition \"{s}\"", .{if (items.len > 0) items[0] else ""});
            return null;
        }
        items[0] = items[0][1..];
        const last = items.len - 1;
        if (items[last].len == 0 or items[last][items[last].len - 1] != ')') {
            b.emerg(d, "invalid condition \"{s}\"", .{items[last]});
            return null;
        }
        items[last] = items[last][0 .. items[last].len - 1];
        var parts: std.ArrayList([]const u8) = .empty;
        for (items, 0..) |x, i| {
            // keep a quoted empty string (`$x = ""`) as an argument
            if (x.len > 0 or (i < d.quoted.len and d.quoted[i])) parts.append(b.a, x) catch return null;
        }
        const p = parts.items;
        if (p.len == 1) return .{ .kind = .truthy, .a = b.compileExpr(d, p[0]) };
        if (p.len == 2) {
            const op = p[0];
            const neg = op.len > 0 and op[0] == '!';
            const o = if (neg) op[1..] else op;
            const kind: CondKind = if (eq(o, "-f")) .file_f else if (eq(o, "-d")) .file_d else if (eq(o, "-e")) .file_e else if (eq(o, "-x")) .file_x else {
                b.emerg(d, "invalid condition \"{s}\"", .{op});
                return null;
            };
            return .{ .kind = kind, .neg = neg, .a = b.compileExpr(d, p[1]) };
        }
        if (p.len == 3) {
            const op = p[1];
            if (eq(op, "=") or eq(op, "!=")) return .{ .kind = if (eq(op, "=")) .eq else .ne, .a = b.compileExpr(d, p[0]), .b = b.compileExpr(d, p[2]) };
            if (eq(op, "~") or eq(op, "~*") or eq(op, "!~") or eq(op, "!~*")) {
                const icase = std.mem.endsWith(u8, op, "*");
                const re = b.compileRegex(d, p[2], icase) orelse return null;
                return .{ .kind = .re, .neg = op[0] == '!', .a = b.compileExpr(d, p[0]), .re = re };
            }
        }
        b.emerg(d, "invalid condition \"{s}\"", .{d.args[0]});
        return null;
    }

    // ---- server / location

    fn buildServer(b: *Builder, d: *const Directive, http: *const LocConf) Error!void {
        const ctx: dirs.Ctx = .{ .srv = true };
        const srv = try b.a.create(Server);
        srv.* = .{
            .index = b.servers.items.len,
            .names = &.{},
            .primary_name = "",
            .conf = try b.child(http),
            .file = d.file,
            .line = d.line,
            .tls = b.http_tls,
            .client_header_timeout_ms = b.http_header_timeout_ms,
            .merge_slashes = b.http_merge_slashes,
        };
        const block = d.block.?;
        var names: std.ArrayList(ServerName) = .empty;
        var had_listen = false;
        for (block) |*x| {
            if (eq(x.name, "listen")) {
                _ = b.check(x, ctx) orelse continue;
                had_listen = true;
                try b.parseListen(x, srv);
            } else if (eq(x.name, "server_name")) {
                _ = b.check(x, ctx) orelse continue;
                for (x.args) |nm| {
                    if (srv.primary_name.len == 0) srv.primary_name = nm;
                    if (nm.len == 0 or eq(nm, "_")) {
                        try names.append(b.a, .{ .exact = nm });
                    } else if (nm[0] == '~') {
                        const re = b.compileRegex(x, nm[1..], true) orelse continue;
                        try names.append(b.a, .{ .re = re });
                    } else if (std.mem.startsWith(u8, nm, "*.")) {
                        try names.append(b.a, .{ .lead = try std.ascii.allocLowerString(b.a, nm[1..]) });
                    } else if (nm[0] == '.') {
                        try names.append(b.a, .{ .lead_dot = try std.ascii.allocLowerString(b.a, nm[1..]) });
                    } else if (std.mem.endsWith(u8, nm, ".*")) {
                        try names.append(b.a, .{ .trail = try std.ascii.allocLowerString(b.a, nm[0 .. nm.len - 1]) });
                    } else if (std.mem.indexOfScalar(u8, nm, '*') != null) {
                        b.emerg(x, "invalid server name or wildcard \"{s}\"", .{nm});
                    } else {
                        try names.append(b.a, .{ .exact = try std.ascii.allocLowerString(b.a, nm) });
                    }
                }
            }
        }
        srv.names = try names.toOwnedSlice(b.a);
        try b.applySimple(srv.conf, block, ctx, srv);
        if (!had_listen) {
            const port: u16 = if (std.c.geteuid() == 0) 80 else 8000;
            try b.pending_listens.append(b.a, .{ .addr = .{ .port = port }, .opts = .{}, .server = srv });
        }
        srv.stmts = try b.buildStmts(block, ctx, srv.conf, srv);
        var locs: std.ArrayList(*Location) = .empty;
        var named: std.ArrayList(*Location) = .empty;
        for (block) |*x| {
            if (!eq(x.name, "location")) continue;
            _ = b.check(x, ctx) orelse continue;
            const loc = (try b.buildLocation(x, srv.conf, srv, null)) orelse continue;
            if (loc.kind == .named) try named.append(b.a, loc) else try locs.append(b.a, loc);
        }
        srv.locations = try locs.toOwnedSlice(b.a);
        srv.named = try named.toOwnedSlice(b.a);
        try b.servers.append(b.a, srv);
    }

    fn parseListen(b: *Builder, d: *const Directive, srv: *Server) !void {
        if (std.mem.startsWith(u8, d.args[0], "unix:")) {
            b.warn(d, "unix domain sockets are not supported, listen ignored", .{});
            return;
        }
        var o: ListenOpts = .{};
        for (d.args[1..]) |p| {
            if (eq(p, "default_server") or eq(p, "default")) {
                o.default_server = true;
            } else if (eq(p, "ssl")) {
                o.ssl = true;
            } else if (eq(p, "reuseport")) {
                o.reuseport = true;
            } else if (std.mem.startsWith(u8, p, "backlog=")) {
                o.backlog = std.fmt.parseInt(i32, p[8..], 10) catch 511;
            } else if (std.mem.startsWith(u8, p, "ipv6only=")) {
                o.ipv6only = eq(p[9..], "on");
            } else if (eq(p, "http2") or eq(p, "quic") or eq(p, "proxy_protocol") or eq(p, "deferred") or eq(p, "bind") or
                std.mem.startsWith(u8, p, "so_keepalive") or std.mem.startsWith(u8, p, "rcvbuf=") or std.mem.startsWith(u8, p, "sndbuf=") or
                std.mem.startsWith(u8, p, "fastopen=") or std.mem.startsWith(u8, p, "accept_filter=") or std.mem.startsWith(u8, p, "setfib="))
            {
                const gop = try b.warned.getOrPut(b.a, p);
                if (!gop.found_existing) b.warn(d, "listen parameter \"{s}\" is not supported, ignored", .{p});
                if (eq(p, "quic")) return; // QUIC listeners are UDP; skip entirely
            } else {
                return b.emerg(d, "invalid parameter \"{s}\"", .{p});
            }
        }
        var tmp: std.ArrayList(Addr) = .empty;
        try b.resolveInto(d, d.args[0], 80, &tmp);
        for (tmp.items) |a| try b.pending_listens.append(b.a, .{ .addr = a, .opts = o, .server = srv });
    }

    fn buildLocation(b: *Builder, d: *const Directive, parent: *const LocConf, srv: *Server, parent_loc: ?*Location) Error!?*Location {
        var kind: LocKind = .prefix;
        var name: []const u8 = d.args[0];
        if (d.args.len == 2) {
            const m = d.args[0];
            kind = if (eq(m, "=")) .exact else if (eq(m, "^~")) .prefix_noregex else if (eq(m, "~")) .regex else if (eq(m, "~*")) .regex_icase else {
                b.emerg(d, "invalid location modifier \"{s}\"", .{m});
                return null;
            };
            name = d.args[1];
        } else if (name.len > 0 and name[0] == '@') {
            kind = .named;
        } else if (name.len > 1 and name[0] == '=') {
            kind = .exact;
            name = name[1..];
        } else if (name.len > 2 and name[0] == '^' and name[1] == '~') {
            kind = .prefix_noregex;
            name = name[2..];
        } else if (name.len > 2 and name[0] == '~' and name[1] == '*') {
            kind = .regex_icase;
            name = name[2..];
        } else if (name.len > 1 and name[0] == '~') {
            kind = .regex;
            name = name[1..];
        }
        if (parent_loc) |pl| {
            if (pl.kind == .exact) {
                b.emerg(d, "location \"{s}\" cannot be inside the exact location \"{s}\"", .{ name, pl.name });
                return null;
            }
            if (kind == .named) {
                b.emerg(d, "named location \"{s}\" can be on the server level only", .{name});
                return null;
            }
            if ((kind == .prefix or kind == .prefix_noregex or kind == .exact) and (pl.kind == .prefix or pl.kind == .prefix_noregex) and !std.mem.startsWith(u8, name, pl.name)) {
                b.emerg(d, "location \"{s}\" is outside location \"{s}\"", .{ name, pl.name });
                return null;
            }
        }
        const loc = try b.a.create(Location);
        loc.* = .{ .kind = kind, .name = name, .conf = try b.child(parent), .file = d.file, .line = d.line };
        if (kind == .regex or kind == .regex_icase) loc.re = b.compileRegex(d, name, kind == .regex_icase) orelse return null;
        const ctx: dirs.Ctx = .{ .loc = true };
        try b.applySimple(loc.conf, d.block.?, ctx, srv);
        loc.stmts = try b.buildStmts(d.block.?, ctx, loc.conf, srv);
        var kids: std.ArrayList(*Location) = .empty;
        for (d.block.?) |*x| {
            if (!eq(x.name, "location")) continue;
            _ = b.check(x, ctx) orelse continue;
            if (try b.buildLocation(x, loc.conf, srv, loc)) |k| try kids.append(b.a, k);
        }
        loc.children = try kids.toOwnedSlice(b.a);
        return loc;
    }

    fn resolveProxies(b: *Builder) !void {
        for (b.pending_proxies.items) |pp| {
            const t = pp.target;
            if (std.mem.startsWith(u8, t, "https://")) {
                b.emerg(pp.d, "https upstreams are not supported by zhttpd: \"{s}\"", .{t});
                continue;
            }
            if (!std.mem.startsWith(u8, t, "http://")) {
                b.emerg(pp.d, "invalid URL prefix in \"{s}\"", .{t});
                continue;
            }
            const rest = t[7..];
            const slash = std.mem.indexOfScalar(u8, rest, '/');
            const hostport = if (slash) |s| rest[0..s] else rest;
            const uri: ?Expr = if (slash) |s| b.compileExpr(pp.d, rest[s..]) else null;
            if (std.mem.indexOfScalar(u8, hostport, '$') != null) {
                const empty = try b.a.create(Upstream);
                empty.* = .{ .name = hostport, .addrs = &.{} };
                pp.conf.proxy = .{ .upstream = empty, .uri = uri, .host = hostport, .port = 80, .dyn_host = b.compileExpr(pp.d, hostport) };
                continue;
            }
            var ups: ?*Upstream = null;
            for (b.cfg.upstreams) |u| {
                if (eq(u.name, hostport)) ups = u;
            }
            var port: u16 = 80;
            if (ups == null) {
                var addrs: std.ArrayList(Addr) = .empty;
                try b.resolveInto(pp.d, hostport, 80, &addrs);
                if (addrs.items.len == 0) continue;
                port = addrs.items[0].port;
                const u = try b.a.create(Upstream);
                u.* = .{ .name = hostport, .addrs = try addrs.toOwnedSlice(b.a) };
                ups = u;
            }
            const host = if (std.mem.endsWith(u8, hostport, ":80")) hostport[0 .. hostport.len - 3] else hostport;
            pp.conf.proxy = .{ .upstream = ups.?, .uri = uri, .host = host, .port = port };
        }
    }

    fn groupListens(b: *Builder) !void {
        var socks: std.ArrayList(Listen) = .empty;
        var entries: std.ArrayList(std.ArrayList(Listen.Entry)) = .empty;
        const pend = b.pending_listens.items;
        for (pend) |p| {
            // A wildcard socket for a port takes over concrete-address listens on that port.
            var key = p.addr;
            for (pend) |q| {
                if (q.addr.family == p.addr.family and q.addr.port == p.addr.port and q.addr.isWildcard()) key.ip = @splat(0);
            }
            var idx: ?usize = null;
            for (socks.items, 0..) |s, i| {
                if (s.addr.eql(key)) idx = i;
            }
            if (idx == null) {
                try socks.append(b.a, .{ .addr = key, .opts = p.opts, .entries = &.{} });
                try entries.append(b.a, .empty);
                idx = socks.items.len - 1;
            } else {
                const s = &socks.items[idx.?];
                s.opts.ssl = s.opts.ssl or p.opts.ssl;
                s.opts.reuseport = s.opts.reuseport or p.opts.reuseport;
            }
            const es = &entries.items[idx.?];
            if (p.opts.default_server) {
                for (es.items) |e| {
                    if (e.default and e.addr.eql(p.addr)) {
                        var buf: [64]u8 = undefined;
                        b.diag.add(.emerg, p.server.file, p.server.line, "a duplicate default server for {s}:{d}", .{ p.addr.formatIp(&buf), p.addr.port });
                        b.failed = true;
                    }
                }
            }
            try es.append(b.a, .{ .addr = p.addr, .server = p.server, .default = p.opts.default_server });
        }
        for (socks.items, 0..) |*s, i| s.entries = try entries.items[i].toOwnedSlice(b.a);
        b.cfg.listens = try socks.toOwnedSlice(b.a);
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn append(a: std.mem.Allocator, comptime T: type, old: []const T, item: T) ![]T {
    const n = try a.alloc(T, old.len + 1);
    @memcpy(n[0..old.len], old);
    n[old.len] = item;
    return n;
}

/// nginx size: "1024", "10k", "1m", "1g" (case-insensitive).
pub fn parseSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var mul: u64 = 1;
    switch (std.ascii.toLower(s[s.len - 1])) {
        'k' => mul = 1024,
        'm' => mul = 1024 * 1024,
        'g' => mul = 1024 * 1024 * 1024,
        else => {},
    }
    const num = if (mul != 1) s[0 .. s.len - 1] else s;
    const v = std.fmt.parseInt(u64, num, 10) catch return null;
    return v * mul;
}

/// nginx time: "60", "60s", "500ms", "1h30m", "1d", "1w", "1M", "1y". Returns milliseconds.
pub fn parseTimeMs(s: []const u8) ?u32 {
    const total = parseTimeMs64(s) orelse return null;
    return @intCast(@min(total, std.math.maxInt(u32)));
}

/// Like parseTimeMs without the u32 clamp (for `expires 1y`).
pub fn parseTimeMs64(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var total: u64 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const st = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (st == i) return null;
        const v = std.fmt.parseInt(u64, s[st..i], 10) catch return null;
        var unit: u64 = 1000;
        if (i < s.len) {
            if (i + 1 < s.len and s[i] == 'm' and s[i + 1] == 's') {
                unit = 1;
                i += 2;
            } else {
                unit = switch (s[i]) {
                    's' => 1000,
                    'm' => 60_000,
                    'h' => 3_600_000,
                    'd' => 86_400_000,
                    'w' => 7 * 86_400_000,
                    'M' => 30 * 86_400_000,
                    'y' => 365 * 86_400_000,
                    else => return null,
                };
                i += 1;
            }
        }
        total +|= v *| unit;
    }
    return total;
}

/// Build the semantic config from a parsed AST. Takes ownership of `ast`.
pub fn build(gpa: std.mem.Allocator, ast: parser.Ast, opts: Options, diag: *Diag) Error!*Config {
    const cfg = try gpa.create(Config);
    cfg.* = .{ .arena = .init(gpa), .ast = ast, .prefix = opts.prefix, .conf_file = "" };
    var b: Builder = .{ .a = cfg.arena.allocator(), .gpa = gpa, .diag = diag, .opts = opts, .cfg = cfg };
    cfg.error_log.path = b.fullPath("logs/error.log") catch return error.OutOfMemory;
    b.buildMain(ast.root) catch |e| {
        cfg.deinit();
        gpa.destroy(cfg);
        return e;
    };
    if (b.failed) {
        cfg.deinit();
        gpa.destroy(cfg);
        return error.ConfigFailed;
    }
    return cfg;
}

pub fn destroy(gpa: std.mem.Allocator, cfg: *Config) void {
    cfg.deinit();
    gpa.destroy(cfg);
}

/// Parse and build from a file, the way `zhttpd -c FILE` does.
pub fn load(gpa: std.mem.Allocator, conf_file: []const u8, opts: Options, diag: *Diag) Error!*Config {
    var ast = parser.parseFile(gpa, conf_file, .{ .conf_prefix = opts.conf_prefix }, diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => return error.ConfigFailed,
    };
    const cfg = build(gpa, ast, opts, diag) catch |e| {
        if (e != error.ConfigFailed and e != error.OutOfMemory) ast.deinit();
        return e;
    };
    cfg.conf_file = conf_file;
    return cfg;
}

/// Same as `load` but from text (tests).
pub fn loadString(gpa: std.mem.Allocator, src: []const u8, opts: Options, diag: *Diag) Error!*Config {
    const ast = parser.parseString(gpa, src, "test.conf", .{ .conf_prefix = opts.conf_prefix }, diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => return error.ConfigFailed,
    };
    return build(gpa, ast, opts, diag);
}

test "parse sizes and times" {
    const t = std.testing;
    try t.expectEqual(@as(?u64, 1048576), parseSize("1m"));
    try t.expectEqual(@as(?u64, 10240), parseSize("10K"));
    try t.expectEqual(@as(?u32, 65000), parseTimeMs("65"));
    try t.expectEqual(@as(?u32, 5400000), parseTimeMs("1h30m"));
    try t.expectEqual(@as(?u32, 500), parseTimeMs("500ms"));
}

test "build a typical config" {
    const t = std.testing;
    var diag: Diag = .{ .gpa = t.allocator };
    defer diag.deinit();
    const cfg = loadString(t.allocator,
        \\worker_processes auto;
        \\events { worker_connections 1024; }
        \\http {
        \\  default_type application/octet-stream;
        \\  keepalive_timeout 65;
        \\  gzip on;
        \\  map $http_upgrade $connection_upgrade { default upgrade; '' close; }
        \\  upstream app { server 127.0.0.1:9000; keepalive 16; }
        \\  server {
        \\    listen 80 default_server;
        \\    listen [::]:80 default_server;
        \\    server_name _;
        \\    return 444;
        \\  }
        \\  server {
        \\    listen 8080;
        \\    server_name example.com *.example.com www.example.* ~^(?<sub>.+)\.example\.org$;
        \\    root /srv/www;
        \\    add_header X-Frame-Options DENY;
        \\    location / { try_files $uri $uri/ =404; }
        \\    location /api/ { proxy_pass http://app/; proxy_set_header Host $host; }
        \\    location ~* \.(css|js)$ { expires 7d; add_header Cache-Control "public"; }
        \\    location = /404.html { internal; }
        \\    location @fallback { return 302 /; }
        \\    if ($host = old.example.com) { return 301 https://example.com$request_uri; }
        \\    frobnicate on;
        \\  }
        \\}
    , .{ .prefix = "/usr/local/nginx", .conf_prefix = "/usr/local/nginx/conf" }, &diag) catch |e| {
        for (diag.messages.items) |m| std.debug.print("got: {s}\n", .{m.text});
        return e;
    };
    defer destroy(t.allocator, cfg);
    try t.expectEqual(@as(usize, 2), cfg.servers.len);
    try t.expectEqual(@as(usize, 3), cfg.listens.len);
    try t.expectEqual(@as(u32, 65_000), cfg.servers[1].conf.keepalive_timeout_ms);
    try t.expectEqual(@as(usize, 4), cfg.servers[1].locations.len);
    try t.expectEqual(@as(usize, 1), cfg.servers[1].named.len);
    try t.expect(cfg.servers[1].locations[1].conf.proxy != null);
    try t.expectEqualStrings("/srv/www", cfg.servers[1].locations[0].conf.root.literal());
    // add_header in the regex location replaces the server-level list
    try t.expectEqual(@as(usize, 1), cfg.servers[1].locations[2].conf.add_headers.len);
    try t.expectEqual(@as(usize, 1), cfg.servers[1].locations[0].conf.add_headers.len);
    try t.expect(diag.has("unknown directive \"frobnicate\" ignored in test.conf:26"));
    try t.expect(diag.has("\"gzip\" directive is not implemented by zhttpd, ignored"));
    try t.expect(cfg.findMap("connection_upgrade") != null);
}

test "config errors are nginx-like" {
    const t = std.testing;
    const cases = [_]struct { src: []const u8, msg: []const u8 }{
        .{ .src = "http { listen 80; }", .msg = "\"listen\" directive is not allowed here in test.conf:1" },
        .{ .src = "http { server { root; } }", .msg = "invalid number of arguments in \"root\" directive in test.conf:1" },
        .{ .src = "http { sendfile maybe; }", .msg = "invalid value \"maybe\" in \"sendfile\" directive, it must be \"on\" or \"off\"" },
        .{ .src = "http { sendfile_max_chunk nope; }", .msg = "\"sendfile_max_chunk\" directive invalid value" },
        .{ .src = "http { server { location { } } }", .msg = "invalid number of arguments in \"location\" directive" },
        .{ .src = "http { server; }", .msg = "directive \"server\" has no opening \"{\"" },
        .{ .src = "events { use select; }", .msg = "invalid event type \"select\"" },
    };
    for (cases) |cs| {
        var diag: Diag = .{ .gpa = t.allocator };
        defer diag.deinit();
        try t.expectError(error.ConfigFailed, loadString(t.allocator, cs.src, .{ .prefix = "/p", .conf_prefix = "/p/conf" }, &diag));
        t.expect(diag.has(cs.msg)) catch |e| {
            for (diag.messages.items) |m| std.debug.print("got: {s}\n", .{m.text});
            return e;
        };
    }
    // strict mode turns unknown directives into errors
    var diag: Diag = .{ .gpa = t.allocator };
    defer diag.deinit();
    try t.expectError(error.ConfigFailed, loadString(t.allocator, "foo bar;", .{ .prefix = "/p", .conf_prefix = "/p", .strict = true }, &diag));
    try t.expect(diag.has("unknown directive \"foo\" in test.conf:1"));
}

test "sendfile_max_chunk defaults, inheritance and disabling" {
    const t = std.testing;
    var diag: Diag = .{ .gpa = t.allocator };
    defer diag.deinit();
    const cfg = try loadString(t.allocator,
        \\http {
        \\  server { listen 8080; }
        \\  server {
        \\    listen 8081;
        \\    sendfile_max_chunk 3m;
        \\    location /inherit { }
        \\    location /off { sendfile_max_chunk 0; }
        \\    location /small { sendfile_max_chunk 64k; }
        \\  }
        \\}
    , .{ .prefix = "/p", .conf_prefix = "/p", .strict = true }, &diag);
    defer destroy(t.allocator, cfg);
    try t.expectEqual(@as(u64, 2 * 1024 * 1024), cfg.servers[0].conf.sendfile_max_chunk);
    try t.expectEqual(@as(u64, 3 * 1024 * 1024), cfg.servers[1].locations[0].conf.sendfile_max_chunk);
    try t.expectEqual(@as(u64, 0), cfg.servers[1].locations[1].conf.sendfile_max_chunk);
    try t.expectEqual(@as(u64, 64 * 1024), cfg.servers[1].locations[2].conf.sendfile_max_chunk);
}
