//! Table of nginx directives zhttpd knows about: where they may appear, how many
//! arguments they take, and whether zhttpd implements them.
//!
//! * `supported`: implemented (see `note` for limits).
//! * `ignored`:   valid nginx, accepted with a warning, no effect (mostly tuning knobs).
//! Anything not in this table is "unknown": a warning by default, an error with `--strict`.
//! `zhttpd --directives` prints this table as Markdown.
const std = @import("std");

pub const Ctx = packed struct(u16) {
    main: bool = false,
    events: bool = false,
    http: bool = false,
    srv: bool = false,
    loc: bool = false,
    sif: bool = false, // `if` in server
    lif: bool = false, // `if` in location
    ups: bool = false, // upstream
    lmt: bool = false, // limit_except
    stream: bool = false,
    mail: bool = false,
    _pad: u5 = 0,

    pub fn has(a: Ctx, b: Ctx) bool {
        return @as(u16, @bitCast(a)) & @as(u16, @bitCast(b)) != 0;
    }
};

pub const Args = enum { none, one, two, three, one_two, one_three, two_three, one_four, more1, more2, flag, any };

pub const Status = enum { supported, ignored };

pub const Spec = struct {
    name: []const u8,
    ctx: Ctx,
    args: Args,
    block: bool = false,
    status: Status,
    note: []const u8 = "",
};

const M: Ctx = .{ .main = true };
const E: Ctx = .{ .events = true };
const H: Ctx = .{ .http = true };
const S: Ctx = .{ .srv = true };
const L: Ctx = .{ .loc = true };
const U: Ctx = .{ .ups = true };
const HSL: Ctx = .{ .http = true, .srv = true, .loc = true };
const HSLI: Ctx = .{ .http = true, .srv = true, .loc = true, .lif = true };
const SL: Ctx = .{ .srv = true, .loc = true };
const HS: Ctx = .{ .http = true, .srv = true };
const REW: Ctx = .{ .srv = true, .loc = true, .sif = true, .lif = true };
const ANYH: Ctx = .{ .http = true, .srv = true, .loc = true, .sif = true, .lif = true, .lmt = true, .ups = true };
const ALL: Ctx = .{ .main = true, .events = true, .http = true, .srv = true, .loc = true, .sif = true, .lif = true, .ups = true, .lmt = true, .stream = true, .mail = true };

pub const table = [_]Spec{
    // ---- core (main) ----
    .{ .name = "worker_processes", .ctx = M, .args = .one, .status = .supported, .note = "number or `auto`; workers are forked processes sharing the listen sockets (SO_REUSEPORT where `reuseport` is set)" },
    .{ .name = "events", .ctx = M, .args = .none, .block = true, .status = .supported },
    .{ .name = "http", .ctx = M, .args = .none, .block = true, .status = .supported },
    .{ .name = "error_log", .ctx = .{ .main = true, .http = true, .srv = true, .loc = true, .stream = true, .mail = true }, .args = .more1, .status = .supported, .note = "file or `stderr`; level filter; `syslog:`/`memory:` targets fall back to stderr" },
    .{ .name = "pid", .ctx = M, .args = .one, .status = .supported, .note = "pid file written by the master" },
    .{ .name = "daemon", .ctx = M, .args = .flag, .status = .ignored, .note = "always runs in the foreground (use systemd/launchd)" },
    .{ .name = "master_process", .ctx = M, .args = .flag, .status = .ignored },
    .{ .name = "user", .ctx = M, .args = .one_two, .status = .ignored, .note = "no privilege drop yet" },
    .{ .name = "worker_rlimit_nofile", .ctx = M, .args = .one, .status = .supported, .note = "setrlimit(RLIMIT_NOFILE)" },
    .{ .name = "worker_rlimit_core", .ctx = M, .args = .one, .status = .ignored },
    .{ .name = "worker_priority", .ctx = M, .args = .one, .status = .ignored },
    .{ .name = "worker_cpu_affinity", .ctx = M, .args = .more1, .status = .ignored },
    .{ .name = "worker_shutdown_timeout", .ctx = M, .args = .one, .status = .ignored },
    .{ .name = "working_directory", .ctx = M, .args = .one, .status = .ignored },
    .{ .name = "env", .ctx = M, .args = .one, .status = .ignored },
    .{ .name = "load_module", .ctx = M, .args = .one, .status = .ignored, .note = "dynamic nginx modules cannot be loaded" },
    .{ .name = "pcre_jit", .ctx = M, .args = .flag, .status = .ignored, .note = "own regex engine" },
    .{ .name = "thread_pool", .ctx = M, .args = .two_three, .status = .ignored },
    .{ .name = "timer_resolution", .ctx = M, .args = .one, .status = .ignored },
    .{ .name = "lock_file", .ctx = M, .args = .one, .status = .ignored },
    .{ .name = "ssl_engine", .ctx = M, .args = .one, .status = .ignored },
    .{ .name = "debug_points", .ctx = M, .args = .one, .status = .ignored },
    .{ .name = "stream", .ctx = M, .args = .none, .block = true, .status = .ignored, .note = "TCP/UDP proxy module not implemented; the whole block is skipped" },
    .{ .name = "mail", .ctx = M, .args = .none, .block = true, .status = .ignored, .note = "mail proxy not implemented; block skipped" },
    // ---- events ----
    .{ .name = "worker_connections", .ctx = E, .args = .one, .status = .supported, .note = "per-worker connection cap (client + upstream sockets)" },
    .{ .name = "use", .ctx = E, .args = .one, .status = .supported, .note = "`kqueue` (macOS/BSD) or `epoll` (Linux); others rejected" },
    .{ .name = "multi_accept", .ctx = E, .args = .flag, .status = .supported },
    .{ .name = "accept_mutex", .ctx = E, .args = .flag, .status = .ignored },
    .{ .name = "accept_mutex_delay", .ctx = E, .args = .one, .status = .ignored },
    .{ .name = "worker_aio_requests", .ctx = E, .args = .one, .status = .ignored },
    .{ .name = "debug_connection", .ctx = E, .args = .one, .status = .ignored },
    // ---- http core ----
    .{ .name = "server", .ctx = H, .args = .none, .block = true, .status = .supported },
    .{ .name = "server", .ctx = U, .args = .more1, .status = .supported, .note = "in `upstream`: `host:port`; weight/backup/max_fails ignored" },
    .{ .name = "location", .ctx = SL, .args = .one_two, .block = true, .status = .supported, .note = "`=`, `^~`, prefix, `~`, `~*`, `@name`; nested locations" },
    .{ .name = "listen", .ctx = S, .args = .more1, .status = .supported, .note = "addr:port, port, [::]:port, unix: no; params `default_server`, `ssl`, `reuseport`, `backlog=`, `ipv6only=`; `http2`/`quic`/`proxy_protocol` ignored with warning" },
    .{ .name = "server_name", .ctx = S, .args = .more1, .status = .supported, .note = "exact, `*.example.com`, `www.example.*`, `.example.com`, `~regex` (named captures become variables), `_`/`\"\"`" },
    .{ .name = "root", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .one, .status = .supported, .note = "variables allowed" },
    .{ .name = "alias", .ctx = L, .args = .one, .status = .supported, .note = "prefix and regex locations (regex: with captures)" },
    .{ .name = "index", .ctx = HSL, .args = .more1, .status = .supported },
    .{ .name = "try_files", .ctx = SL, .args = .more2, .status = .supported, .note = "files, `dir/`, `=code`, last-arg uri or `@named`" },
    .{ .name = "error_page", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .more2, .status = .supported, .note = "codes, `=code`/`=`, uri, `@named`, absolute URL (302)" },
    .{ .name = "recursive_error_pages", .ctx = HSL, .args = .flag, .status = .ignored, .note = "always off" },
    .{ .name = "internal", .ctx = L, .args = .none, .status = .supported },
    .{ .name = "default_type", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "types", .ctx = HSL, .args = .none, .block = true, .status = .supported },
    .{ .name = "types_hash_max_size", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "types_hash_bucket_size", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "server_names_hash_max_size", .ctx = H, .args = .one, .status = .ignored },
    .{ .name = "server_names_hash_bucket_size", .ctx = H, .args = .one, .status = .ignored },
    .{ .name = "variables_hash_max_size", .ctx = H, .args = .one, .status = .ignored },
    .{ .name = "variables_hash_bucket_size", .ctx = H, .args = .one, .status = .ignored },
    .{ .name = "map_hash_max_size", .ctx = H, .args = .one, .status = .ignored },
    .{ .name = "map_hash_bucket_size", .ctx = H, .args = .one, .status = .ignored },
    .{ .name = "proxy_headers_hash_max_size", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "proxy_headers_hash_bucket_size", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "sendfile", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .flag, .status = .supported, .note = "sendfile(2) for plain-HTTP static files" },
    .{ .name = "sendfile_max_chunk", .ctx = HSL, .args = .one, .status = .supported, .note = "static-file send budget per event-loop turn, including TLS; default 2m, 0 disables" },
    .{ .name = "tcp_nopush", .ctx = HSL, .args = .flag, .status = .ignored, .note = "headers and first body bytes are already coalesced" },
    .{ .name = "tcp_nodelay", .ctx = HSL, .args = .flag, .status = .supported },
    .{ .name = "keepalive_timeout", .ctx = HSL, .args = .one_two, .status = .supported, .note = "second arg (Keep-Alive header) ignored" },
    .{ .name = "keepalive_requests", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "keepalive_time", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "keepalive_disable", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "client_max_body_size", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "client_body_buffer_size", .ctx = HSL, .args = .one, .status = .ignored, .note = "bodies are buffered in memory up to client_max_body_size" },
    .{ .name = "client_body_timeout", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "client_header_timeout", .ctx = HS, .args = .one, .status = .supported },
    .{ .name = "client_header_buffer_size", .ctx = HS, .args = .one, .status = .ignored },
    .{ .name = "large_client_header_buffers", .ctx = HS, .args = .two, .status = .ignored, .note = "fixed 16 KiB header buffer" },
    .{ .name = "client_body_temp_path", .ctx = HSL, .args = .one_four, .status = .ignored },
    .{ .name = "client_body_in_file_only", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "send_timeout", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "reset_timedout_connection", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "lingering_close", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "lingering_time", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "lingering_timeout", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "server_tokens", .ctx = HSL, .args = .one, .status = .supported, .note = "`on`/`off`/`build`" },
    .{ .name = "absolute_redirect", .ctx = HSL, .args = .flag, .status = .supported },
    .{ .name = "server_name_in_redirect", .ctx = HSL, .args = .flag, .status = .supported },
    .{ .name = "port_in_redirect", .ctx = HSL, .args = .flag, .status = .supported },
    .{ .name = "msie_padding", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "msie_refresh", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "log_not_found", .ctx = HSL, .args = .flag, .status = .supported },
    .{ .name = "log_subrequest", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "etag", .ctx = HSL, .args = .flag, .status = .supported },
    .{ .name = "if_modified_since", .ctx = HSL, .args = .one, .status = .supported, .note = "`off`/`exact`/`before`" },
    .{ .name = "merge_slashes", .ctx = HS, .args = .flag, .status = .supported },
    .{ .name = "ignore_invalid_headers", .ctx = HS, .args = .flag, .status = .ignored },
    .{ .name = "underscores_in_headers", .ctx = HS, .args = .flag, .status = .ignored },
    .{ .name = "chunked_transfer_encoding", .ctx = HSL, .args = .flag, .status = .supported },
    .{ .name = "open_file_cache", .ctx = HSL, .args = .one_two, .status = .supported, .note = "per-worker fd/stat cache" },
    .{ .name = "open_file_cache_valid", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "open_file_cache_min_uses", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "open_file_cache_errors", .ctx = HSL, .args = .flag, .status = .supported },
    .{ .name = "aio", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "aio_write", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "directio", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "output_buffers", .ctx = HSL, .args = .two, .status = .ignored },
    .{ .name = "postpone_output", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "resolver", .ctx = HSL, .args = .more1, .status = .ignored, .note = "upstream names resolved once at startup" },
    .{ .name = "resolver_timeout", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "satisfy", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "limit_except", .ctx = L, .args = .more1, .block = true, .status = .supported, .note = "only `deny all`/`allow`/`deny` inside" },
    .{ .name = "limit_rate", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .one, .status = .ignored },
    .{ .name = "limit_rate_after", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .one, .status = .ignored },
    .{ .name = "http2", .ctx = HS, .args = .flag, .status = .ignored, .note = "HTTP/2 not implemented" },
    .{ .name = "http3", .ctx = HS, .args = .flag, .status = .ignored, .note = "HTTP/3 not implemented" },
    .{ .name = "quic_retry", .ctx = HS, .args = .flag, .status = .ignored },
    .{ .name = "subrequest_output_buffer_size", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "disable_symlinks", .ctx = HSL, .args = .one_two, .status = .ignored },
    .{ .name = "charset", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .one, .status = .supported, .note = "adds `; charset=` to text types" },
    .{ .name = "charset_types", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "source_charset", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .one, .status = .ignored },
    .{ .name = "override_charset", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .flag, .status = .ignored },
    // ---- log ----
    .{ .name = "access_log", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true, .lmt = true }, .args = .more1, .status = .supported, .note = "`off`, path + format; buffered/gzip/if= params ignored" },
    .{ .name = "log_format", .ctx = H, .args = .more2, .status = .supported, .note = "escape= ignored" },
    .{ .name = "open_log_file_cache", .ctx = HSL, .args = .one_four, .status = .ignored },
    // ---- index / autoindex / static ----
    .{ .name = "autoindex", .ctx = HSL, .args = .flag, .status = .supported, .note = "HTML listing" },
    .{ .name = "autoindex_exact_size", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "autoindex_localtime", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "autoindex_format", .ctx = HSL, .args = .one, .status = .ignored },
    // ---- rewrite ----
    .{ .name = "rewrite", .ctx = REW, .args = .two_three, .status = .supported, .note = "`last`, `break`, `redirect`, `permanent`; captures" },
    .{ .name = "return", .ctx = REW, .args = .one_two, .status = .supported, .note = "incl. 444 (close)" },
    .{ .name = "set", .ctx = REW, .args = .two, .status = .supported },
    .{ .name = "if", .ctx = .{ .srv = true, .loc = true }, .args = .more1, .block = true, .status = .supported, .note = "conditions: `$v`, `=`, `!=`, `~`, `~*`, `!~`, `!~*`, `-f -d -e -x` and negations; inside: rewrite-module directives, `add_header`, `root`, `access_log`, `error_page`" },
    .{ .name = "break", .ctx = REW, .args = .none, .status = .supported },
    .{ .name = "rewrite_log", .ctx = .{ .http = true, .srv = true, .loc = true, .sif = true, .lif = true }, .args = .flag, .status = .ignored },
    .{ .name = "uninitialized_variable_warn", .ctx = .{ .http = true, .srv = true, .loc = true, .sif = true, .lif = true }, .args = .flag, .status = .ignored },
    // ---- access / auth ----
    .{ .name = "allow", .ctx = .{ .http = true, .srv = true, .loc = true, .lmt = true }, .args = .one, .status = .supported, .note = "IPv4/IPv6 address or CIDR, `all`" },
    .{ .name = "deny", .ctx = .{ .http = true, .srv = true, .loc = true, .lmt = true }, .args = .one, .status = .supported },
    .{ .name = "auth_basic", .ctx = .{ .http = true, .srv = true, .loc = true, .lmt = true }, .args = .one, .status = .ignored, .note = "NOT enforced: protected locations would be open; zhttpd warns loudly" },
    .{ .name = "auth_basic_user_file", .ctx = .{ .http = true, .srv = true, .loc = true, .lmt = true }, .args = .one, .status = .ignored },
    .{ .name = "auth_request", .ctx = HSL, .args = .one, .status = .ignored, .note = "NOT enforced" },
    .{ .name = "auth_request_set", .ctx = HSL, .args = .two, .status = .ignored },
    // ---- headers / expires ----
    .{ .name = "add_header", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .two_three, .status = .supported, .note = "nginx inheritance rule (only if none at current level), `always`" },
    .{ .name = "add_trailer", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .two_three, .status = .ignored },
    .{ .name = "expires", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .one_two, .status = .supported, .note = "`off`, `epoch`, `max`, `[modified] [-]time`; `@time` ignored" },
    // ---- map / geo / split ----
    .{ .name = "map", .ctx = H, .args = .two, .block = true, .status = .supported, .note = "exact, `default`, `~`/`~*` regex, `hostnames` and `volatile` flags; `include` inside works" },
    .{ .name = "geo", .ctx = H, .args = .one_two, .block = true, .status = .ignored },
    .{ .name = "split_clients", .ctx = H, .args = .two, .block = true, .status = .ignored },
    // ---- upstream ----
    .{ .name = "upstream", .ctx = H, .args = .one, .block = true, .status = .supported, .note = "round-robin over `server` entries; no health checks" },
    .{ .name = "keepalive", .ctx = U, .args = .one, .status = .ignored, .note = "no upstream connection pooling yet" },
    .{ .name = "keepalive_timeout", .ctx = U, .args = .one, .status = .ignored },
    .{ .name = "least_conn", .ctx = U, .args = .none, .status = .ignored },
    .{ .name = "ip_hash", .ctx = U, .args = .none, .status = .ignored },
    .{ .name = "hash", .ctx = U, .args = .one_two, .status = .ignored },
    .{ .name = "zone", .ctx = U, .args = .one_two, .status = .ignored },
    // ---- proxy ----
    .{ .name = "proxy_pass", .ctx = .{ .loc = true, .lif = true, .lmt = true }, .args = .one, .status = .supported, .note = "`http://host:port[/uri]` or upstream name; `https://` upstreams not supported" },
    .{ .name = "proxy_set_header", .ctx = HSL, .args = .two, .status = .supported },
    .{ .name = "proxy_http_version", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "proxy_pass_request_headers", .ctx = HSL, .args = .flag, .status = .supported },
    .{ .name = "proxy_pass_request_body", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "proxy_hide_header", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "proxy_pass_header", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "proxy_redirect", .ctx = HSL, .args = .one_two, .status = .ignored, .note = "Location from upstream is passed unchanged" },
    .{ .name = "proxy_connect_timeout", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "proxy_read_timeout", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "proxy_send_timeout", .ctx = HSL, .args = .one, .status = .supported },
    .{ .name = "proxy_buffering", .ctx = HSL, .args = .flag, .status = .ignored, .note = "always streams (like `off`)" },
    .{ .name = "proxy_buffer_size", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "proxy_buffers", .ctx = HSL, .args = .two, .status = .ignored },
    .{ .name = "proxy_busy_buffers_size", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "proxy_request_buffering", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "proxy_intercept_errors", .ctx = HSL, .args = .flag, .status = .supported },
    .{ .name = "proxy_next_upstream", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "proxy_next_upstream_tries", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "proxy_next_upstream_timeout", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "proxy_cache", .ctx = HSL, .args = .one, .status = .ignored, .note = "no cache" },
    .{ .name = "proxy_cache_path", .ctx = H, .args = .more2, .status = .ignored },
    .{ .name = "proxy_cache_valid", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "proxy_cache_key", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "proxy_cache_bypass", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "proxy_no_cache", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "proxy_cache_use_stale", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "proxy_cache_lock", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "proxy_temp_path", .ctx = HSL, .args = .one_four, .status = .ignored },
    .{ .name = "proxy_max_temp_file_size", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "proxy_ignore_headers", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "proxy_ssl_server_name", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "proxy_ssl_verify", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "proxy_ssl_protocols", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "proxy_cookie_path", .ctx = HSL, .args = .one_two, .status = .ignored },
    .{ .name = "proxy_cookie_domain", .ctx = HSL, .args = .one_two, .status = .ignored },
    .{ .name = "proxy_socket_keepalive", .ctx = HSL, .args = .flag, .status = .ignored },
    // ---- fastcgi / uwsgi / scgi / grpc / memcached: not implemented ----
    .{ .name = "fastcgi_pass", .ctx = .{ .loc = true, .lif = true }, .args = .one, .status = .ignored, .note = "FastCGI not implemented: location answers 502" },
    .{ .name = "fastcgi_param", .ctx = HSL, .args = .two_three, .status = .ignored },
    .{ .name = "fastcgi_index", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "fastcgi_split_path_info", .ctx = L, .args = .one, .status = .ignored },
    .{ .name = "fastcgi_read_timeout", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "fastcgi_buffers", .ctx = HSL, .args = .two, .status = .ignored },
    .{ .name = "fastcgi_buffer_size", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "fastcgi_intercept_errors", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "uwsgi_pass", .ctx = .{ .loc = true, .lif = true }, .args = .one, .status = .ignored, .note = "answers 502" },
    .{ .name = "uwsgi_param", .ctx = HSL, .args = .two_three, .status = .ignored },
    .{ .name = "scgi_pass", .ctx = .{ .loc = true, .lif = true }, .args = .one, .status = .ignored, .note = "answers 502" },
    .{ .name = "scgi_param", .ctx = HSL, .args = .two_three, .status = .ignored },
    .{ .name = "grpc_pass", .ctx = .{ .loc = true, .lif = true }, .args = .one, .status = .ignored, .note = "answers 502" },
    .{ .name = "grpc_set_header", .ctx = HSL, .args = .two, .status = .ignored },
    .{ .name = "memcached_pass", .ctx = .{ .loc = true, .lif = true }, .args = .one, .status = .ignored },
    // ---- gzip ----
    .{ .name = "gzip", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .flag, .status = .ignored, .note = "responses are sent uncompressed" },
    .{ .name = "gzip_vary", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "gzip_types", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "gzip_proxied", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "gzip_comp_level", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "gzip_min_length", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "gzip_buffers", .ctx = HSL, .args = .two, .status = .ignored },
    .{ .name = "gzip_http_version", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "gzip_disable", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "gzip_static", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "gunzip", .ctx = HSL, .args = .flag, .status = .ignored },
    // ---- ssl ----
    .{ .name = "ssl_certificate", .ctx = HS, .args = .one, .status = .supported, .note = "PEM (OpenSSL); multiple certs: first used" },
    .{ .name = "ssl_certificate_key", .ctx = HS, .args = .one, .status = .supported },
    .{ .name = "ssl_protocols", .ctx = HS, .args = .more1, .status = .supported, .note = "TLSv1.2 / TLSv1.3 (older rejected by OpenSSL 3 defaults)" },
    .{ .name = "ssl_ciphers", .ctx = HS, .args = .one, .status = .supported, .note = "TLS 1.2 cipher list" },
    .{ .name = "ssl_conf_command", .ctx = HS, .args = .two, .status = .supported, .note = "`Ciphersuites`, etc. via SSL_CONF" },
    .{ .name = "ssl_prefer_server_ciphers", .ctx = HS, .args = .flag, .status = .supported },
    .{ .name = "ssl_session_cache", .ctx = HS, .args = .more1, .status = .supported, .note = "`shared:NAME:SIZE` maps to a per-worker OpenSSL cache of equivalent size; `off`/`none`" },
    .{ .name = "ssl_session_timeout", .ctx = HS, .args = .one, .status = .supported },
    .{ .name = "ssl_session_tickets", .ctx = HS, .args = .flag, .status = .supported, .note = "ticket key generated per master start, shared by workers" },
    .{ .name = "ssl_session_ticket_key", .ctx = HS, .args = .one, .status = .ignored },
    .{ .name = "ssl_ecdh_curve", .ctx = HS, .args = .one, .status = .supported },
    .{ .name = "ssl_dhparam", .ctx = HS, .args = .one, .status = .ignored },
    .{ .name = "ssl_buffer_size", .ctx = HS, .args = .one, .status = .ignored },
    .{ .name = "ssl_early_data", .ctx = HS, .args = .flag, .status = .ignored },
    .{ .name = "ssl_stapling", .ctx = HS, .args = .flag, .status = .ignored },
    .{ .name = "ssl_stapling_verify", .ctx = HS, .args = .flag, .status = .ignored },
    .{ .name = "ssl_trusted_certificate", .ctx = HS, .args = .one, .status = .ignored },
    .{ .name = "ssl_client_certificate", .ctx = HS, .args = .one, .status = .ignored },
    .{ .name = "ssl_verify_client", .ctx = HS, .args = .one, .status = .ignored },
    .{ .name = "ssl_reject_handshake", .ctx = HS, .args = .flag, .status = .supported },
    .{ .name = "ssl", .ctx = HS, .args = .flag, .status = .ignored, .note = "obsolete; use `listen ... ssl`" },
    // ---- real ip ----
    .{ .name = "set_real_ip_from", .ctx = HSL, .args = .one, .status = .ignored, .note = "$remote_addr stays the peer address" },
    .{ .name = "real_ip_header", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "real_ip_recursive", .ctx = HSL, .args = .flag, .status = .ignored },
    // ---- limits ----
    .{ .name = "limit_req_zone", .ctx = H, .args = .three, .status = .ignored, .note = "rate limiting not enforced" },
    .{ .name = "limit_req", .ctx = HSL, .args = .one_three, .status = .ignored },
    .{ .name = "limit_req_status", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "limit_conn_zone", .ctx = H, .args = .two, .status = .ignored },
    .{ .name = "limit_conn", .ctx = HSL, .args = .two, .status = .ignored },
    .{ .name = "limit_conn_status", .ctx = HSL, .args = .one, .status = .ignored },
    // ---- misc modules ----
    .{ .name = "stub_status", .ctx = SL, .args = .any, .status = .ignored },
    .{ .name = "sub_filter", .ctx = HSL, .args = .two, .status = .ignored },
    .{ .name = "sub_filter_once", .ctx = HSL, .args = .flag, .status = .ignored },
    .{ .name = "ssi", .ctx = .{ .http = true, .srv = true, .loc = true, .lif = true }, .args = .flag, .status = .ignored },
    .{ .name = "mp4", .ctx = L, .args = .none, .status = .ignored },
    .{ .name = "flv", .ctx = L, .args = .none, .status = .ignored },
    .{ .name = "dav_methods", .ctx = HSL, .args = .more1, .status = .ignored },
    .{ .name = "valid_referers", .ctx = SL, .args = .more1, .status = .ignored },
    .{ .name = "userid", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "mirror", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "slice", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "secure_link", .ctx = HSL, .args = .one, .status = .ignored },
    .{ .name = "image_filter", .ctx = L, .args = .one_three, .status = .ignored },
    .{ .name = "empty_gif", .ctx = L, .args = .none, .status = .ignored },
    .{ .name = "random_index", .ctx = L, .args = .flag, .status = .ignored },
};

pub fn lookup(name: []const u8, ctx: Ctx) ?*const Spec {
    // Some names exist in two contexts with different specs (keepalive_timeout, server).
    var fallback: ?*const Spec = null;
    for (&table) |*s| {
        if (!std.mem.eql(u8, s.name, name)) continue;
        if (s.ctx.has(ctx)) return s;
        fallback = s;
    }
    return fallback;
}

pub fn argsOk(a: Args, n: usize) bool {
    return switch (a) {
        .none => n == 0,
        .one, .flag => n == 1,
        .two => n == 2,
        .three => n == 3,
        .one_two => n == 1 or n == 2,
        .one_three => n >= 1 and n <= 3,
        .two_three => n == 2 or n == 3,
        .one_four => n >= 1 and n <= 4,
        .more1 => n >= 1,
        .more2 => n >= 2,
        .any => true,
    };
}

/// Markdown table for README / `--directives`.
pub fn writeMarkdown(w: *std.Io.Writer) !void {
    try w.writeAll("| directive | status | notes |\n|---|---|---|\n");
    for (table) |s| {
        try w.print("| `{s}` | {s} | {s} |\n", .{ s.name, if (s.status == .supported) "supported" else "accepted, ignored (warning)", s.note });
    }
}
