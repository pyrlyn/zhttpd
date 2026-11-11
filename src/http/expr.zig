//! Compiled expressions used by the HTTP runtime. Syntax compilers live in adapters.
pub const Var = union(enum) {
    uri, // $uri / $document_uri
    request_uri,
    args, // $args / $query_string
    is_args,
    request_method,
    request,
    server_protocol,
    scheme,
    https,
    host,
    hostname,
    server_name,
    server_addr,
    server_port,
    remote_addr,
    remote_port,
    document_root,
    realpath_root,
    request_filename,
    fastcgi_script_name,
    content_type,
    content_length,
    request_length,
    status,
    body_bytes_sent,
    bytes_sent,
    request_time,
    time_local,
    time_iso8601,
    msec,
    connection,
    connection_requests,
    pid,
    nginx_version,
    proxy_host,
    proxy_port,
    proxy_add_x_forwarded_for,
    upstream_addr,
    upstream_status,
    http: []const u8, // $http_x_foo -> request header "x-foo"
    sent_http: []const u8,
    arg: []const u8,
    cookie: []const u8,
    capture: u8, // $0..$9
    named: []const u8, // named capture, `set` variable or `map` result (runtime lookup)
};

pub const Part = union(enum) {
    lit: []const u8,
    v: Var,
};

pub const Expr = struct {
    parts: []const Part,
    raw: []const u8,

    pub fn isLiteral(e: Expr) bool {
        return e.parts.len == 0 or (e.parts.len == 1 and e.parts[0] == .lit);
    }
    pub fn literal(e: Expr) []const u8 {
        if (e.parts.len == 0) return "";
        return e.parts[0].lit;
    }
};
