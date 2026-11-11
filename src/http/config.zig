//! Runtime settings consumed by HTTP. Configuration adapters construct this
//! model; the server has no dependency on a configuration language or parser.
const std = @import("std");
const Regex = @import("../regex.zig").Regex;
const Expr = @import("expression").Expr;
const Addr = @import("addr.zig").Addr;
const Cidr = @import("addr.zig").Cidr;

pub const Mime = std.StringHashMapUnmanaged([]const u8);

pub const ErrorPage = struct { codes: []const u16, override: ?u16, use_page_status: bool, uri: Expr };
pub const AddHeader = struct { name: []const u8, value: Expr, always: bool };
pub const HeaderSet = struct { name: []const u8, value: Expr, if_not_empty: bool = false };
pub const AccessRule = struct { allow: bool, all: bool, cidr: Cidr = undefined };
pub const LogFormat = @import("logging").Format;
pub const AccessLog = @import("logging").AccessLog;
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

pub const LocConf = struct {
    root: Expr,
    alias: ?Expr = null,
    index: []Expr,
    try_files: ?[]Expr = null,
    error_pages: []ErrorPage = &.{},
    add_headers: []AddHeader = &.{},
    access: []AccessRule = &.{},
    access_logs: ?[]AccessLog, // null = off
    error_log: ?ErrorLog = null,
    client_max_body_size: u64 = 1024 * 1024,
    proxy: ?Proxy = null,
    gateway: enum { http, fastcgi, wsgi } = .http,
    fastcgi_params: []HeaderSet = &.{},
    fastcgi_index: []const u8 = "",
    websocket: ?@import("websocket").Callbacks = null,
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
    acme_certificates: []const usize = &.{},
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
    http2: bool = false,
    http3: bool = true,
    client_header_timeout_ms: u32 = 60_000,
    merge_slashes: bool = true,
    file: []const u8,
    line: u32,
};

pub const ListenOpts = struct { default_server: bool = false, ssl: bool = false, http2: bool = false, quic: bool = false, reuseport: bool = false, backlog: i32 = 511, ipv6only: bool = true };

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

pub const ErrorLog = @import("logging").ErrorLog; // 0 emerg .. 7 debug

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    /// Optional arena backing source strings; no parser/AST types enter HTTP.
    source_arena: ?std.heap.ArenaAllocator = null,
    source_files: []const []const u8 = &.{},
    retained_arenas: []std.heap.ArenaAllocator = &.{},
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
    logging_enabled: bool = true,
    auto_reload: bool = true,
    acme: []const @import("acme").Settings = &.{},
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
        for (c.retained_arenas) |*a| a.deinit();
        if (c.source_arena) |*a| a.deinit();
        c.arena.deinit();
    }

    pub fn findMap(c: *const Config, name: []const u8) ?*const Map {
        for (c.maps) |*m| if (std.mem.eql(u8, m.target, name)) return m;
        return null;
    }
};
