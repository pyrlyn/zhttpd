//! HTTP/1.0 and HTTP/1.1 request head parser.
//!
//! Zero-copy: every slice in `Request` points into the caller's receive buffer; the only
//! writable scratch is the caller-provided `path_buf` for the decoded/normalized path.
//! The parser is restartable: call `parseHead` whenever new bytes arrive; it returns
//! `.incomplete` until the blank line ending the head has been received.
const std = @import("std");

pub const max_headers = 100;

pub const Method = enum { GET, HEAD, POST, PUT, DELETE, OPTIONS, PATCH, TRACE, CONNECT, other };

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Version = enum(u8) { http10 = 10, http11 = 11 };

pub const Request = struct {
    // Keep frequently read flags beside the slices, ahead of the header array
    // in Zig's automatic layout (the unused header slots can span pages).
    method: Method align(8) = .GET,
    method_raw: []const u8 = "",
    /// Request target exactly as sent ($request_uri).
    target: []const u8 = "",
    /// Normalized path ($uri); borrows the request buffer or `path_buf`.
    path: []const u8 = "",
    /// Query string without '?' ($args).
    args: []const u8 = "",
    version: Version align(8) = .http11,
    /// Full request line without CRLF ($request).
    line: []const u8 = "",
    headers: [max_headers]Header = undefined,
    nheaders: usize = 0,
    host: ?[]const u8 = null,
    content_length: ?u64 = null,
    chunked: bool align(8) = false,
    keep_alive: bool align(8) = true,
    expect_continue: bool align(8) = false,
    /// Bytes of the head including the final blank line.
    head_len: usize = 0,

    /// Header slots beyond nheaders are never read. Reset only live metadata:
    /// assigning the whole struct copies a 3 KiB undefined header array too.
    pub fn reset(req: *Request) void {
        inline for (@typeInfo(Request).@"struct".field_names) |name| {
            if (comptime !std.mem.eql(u8, name, "headers")) {
                @field(req, name) = @field(@as(Request, .{}), name);
            }
        }
    }

    pub fn header(r: *const Request, name: []const u8) ?[]const u8 {
        for (r.headers[0..r.nheaders]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }

    /// `$http_x_forwarded_for` style lookup: '_' in `name` matches '-' in header names.
    pub fn headerVar(r: *const Request, name: []const u8) ?[]const u8 {
        outer: for (r.headers[0..r.nheaders]) |h| {
            if (h.name.len != name.len) continue;
            for (h.name, name) |a, b| {
                const bb = if (b == '_') '-' else b;
                if (std.ascii.toLower(a) != std.ascii.toLower(bb)) continue :outer;
            }
            return h.value;
        }
        return null;
    }
};

pub const Status = enum { complete, incomplete };

/// Errors map to HTTP status codes the server answers with before closing.
pub const ParseError = error{
    BadRequest, // 400
    UriTooLong, // 414
    HeadersTooLarge, // 400 "Request Header Or Cookie Too Large" (nginx)
    NotImplemented, // 501 (unknown transfer-coding)
    VersionNotSupported, // 505
};

pub fn errorStatus(e: ParseError) u16 {
    return switch (e) {
        error.BadRequest, error.HeadersTooLarge => 400,
        error.UriTooLong => 414,
        error.NotImplemented => 501,
        error.VersionNotSupported => 505,
    };
}

pub const Limits = struct {
    max_head: usize = 16 * 1024,
    max_uri: usize = 8 * 1024,
};

/// Find the end of the head. `scan_from` lets callers avoid rescanning bytes already seen.
fn findHeadEnd(buf: []const u8, scan_from: usize) ?usize {
    var i = if (scan_from >= 3) scan_from - 3 else 0;
    while (std.mem.indexOfScalarPos(u8, buf, i, '\n')) |nl| {
        // "\n\n" or "\n\r\n"
        if (nl + 1 < buf.len and buf[nl + 1] == '\n') return nl + 2;
        if (nl + 2 < buf.len and buf[nl + 1] == '\r' and buf[nl + 2] == '\n') return nl + 3;
        i = nl + 1;
    }
    return null;
}

/// Parse a request head from `buf`. On `.complete`, `req` is filled and `req.head_len`
/// tells where the body (or next pipelined request) starts.
pub fn parseHead(buf: []const u8, scan_from: usize, req: *Request, path_buf: []u8, limits: Limits, merge_slashes: bool) ParseError!Status {
    // RFC 9112 2.2: ignore at least one empty line before the request-line
    var start: usize = 0;
    while (start < buf.len and (buf[start] == '\r' or buf[start] == '\n')) start += 1;
    const end = findHeadEnd(buf, @max(scan_from, start)) orelse {
        if (buf.len >= limits.max_head) {
            // Distinguish a huge request line (414) from huge headers.
            if (std.mem.indexOfScalarPos(u8, buf, start, '\n') == null) return error.UriTooLong;
            return error.HeadersTooLarge;
        }
        return .incomplete;
    };
    if (end > limits.max_head) return error.HeadersTooLarge;
    req.reset();
    req.head_len = end;
    const head = buf[start..end];
    var lines = std.mem.splitScalar(u8, head, '\n');
    const first = trimCr(lines.next() orelse return error.BadRequest);
    try parseRequestLine(first, req, path_buf, limits, merge_slashes);
    while (lines.next()) |raw| {
        const line = trimCr(raw);
        if (line.len == 0) break;
        if (line[0] == ' ' or line[0] == '\t') {
            // obsolete line folding: reject like nginx does for HTTP/1.1
            return error.BadRequest;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        const name = line[0..colon];
        if (name.len == 0) return error.BadRequest;
        for (name) |ch| if (!tchar_table[ch]) return error.BadRequest;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (hasNulOrCr(value)) return error.BadRequest;
        if (req.nheaders == max_headers) return error.HeadersTooLarge;
        req.headers[req.nheaders] = .{ .name = name, .value = value };
        req.nheaders += 1;
        try interpretHeader(req, name, value);
    }
    if (req.version == .http11 and req.host == null) return error.BadRequest;
    if (req.chunked and req.content_length != null) {
        // RFC 9112 6.3: chunked wins; nginx rejects the combination as smuggling-prone.
        return error.BadRequest;
    }
    return .complete;
}

fn trimCr(s: []const u8) []const u8 {
    return if (s.len > 0 and s[s.len - 1] == '\r') s[0 .. s.len - 1] else s;
}

const tchar_table: [256]bool = blk: {
    var table: [256]bool = @splat(false);
    for (0..256) |c| table[c] = isTchar(c);
    break :blk table;
};

/// Positions of one byte value in `h`, in increasing order. Compares 16
/// bytes at a time and keeps the current block's match mask, so walking a
/// short-line head costs about one vector compare per 16 bytes instead of a
/// search call per line.
pub const ByteIter = struct {
    h: []const u8,
    c: u8,
    base: usize = 0,
    bits: u16 = 0,
    loaded: bool = false,

    fn mask(it: *const ByteIter, base: usize) u16 {
        const V = @Vector(16, u8);
        var tail: [16]u8 = @splat(~it.c);
        const x: V = if (base + 16 <= it.h.len) it.h[base..][0..16].* else blk: {
            @memcpy(tail[0 .. it.h.len - base], it.h[base..]);
            break :blk tail;
        };
        return @bitCast(x == @as(V, @splat(it.c)));
    }

    /// First position at or after `from`.
    pub fn next(it: *ByteIter, from: usize) ?usize {
        if (from >= it.h.len) return null;
        var base = from & ~@as(usize, 15);
        if (!it.loaded or base != it.base) {
            it.base = base;
            it.bits = it.mask(base);
            it.loaded = true;
        }
        var m = it.bits & (@as(u16, 0xffff) << @intCast(from - base));
        while (m == 0) {
            base += 16;
            if (base >= it.h.len) return null;
            it.base = base;
            it.bits = it.mask(base);
            m = it.bits;
        }
        return base + @ctz(m);
    }
};

/// True when any byte of `v` matches `pred`, a function from a byte vector to
/// a bool vector. Checks 16 bytes at a time, then the tail with one or two
/// (overlapping) 8-byte vectors; only strings shorter than 8 go byte by byte.
pub fn anyByte(v: []const u8, comptime pred: anytype) bool {
    var i: usize = 0;
    while (i + 16 <= v.len) : (i += 16) {
        const x: @Vector(16, u8) = v[i..][0..16].*;
        if (@reduce(.Or, pred(x))) return true;
    }
    const rest = v.len - i;
    if (rest == 0) return false;
    if (v.len >= 8) {
        if (rest > 8) {
            const x: @Vector(8, u8) = v[i..][0..8].*;
            if (@reduce(.Or, pred(x))) return true;
        }
        const x: @Vector(8, u8) = v[v.len - 8 ..][0..8].*;
        return @reduce(.Or, pred(x));
    }
    for (v[i..]) |ch| {
        const x: @Vector(1, u8) = .{ch};
        if (pred(x)[0]) return true;
    }
    return false;
}

fn splat(comptime T: type, c: u8) T {
    return @splat(c);
}

pub fn isNulOrCr(x: anytype) @TypeOf(x == x) {
    const T = @TypeOf(x);
    return (x == splat(T, 0)) | (x == splat(T, '\r'));
}

/// Control characters, space and DEL: never valid in a request target.
pub fn isCtlOrSpace(x: anytype) @TypeOf(x == x) {
    const T = @TypeOf(x);
    return (x <= splat(T, 0x20)) | (x == splat(T, 0x7f));
}

fn isHostSeparator(x: anytype) @TypeOf(x == x) {
    const T = @TypeOf(x);
    return (x == splat(T, '/')) | (x == splat(T, '\\')) | (x == splat(T, ' '));
}

fn hasNulOrCr(v: []const u8) bool {
    return anyByte(v, isNulOrCr);
}

fn isTchar(ch: u8) bool {
    return switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn interpretHeader(req: *Request, name: []const u8, value: []const u8) ParseError!void {
    switch (name.len) {
        4 => if (std.ascii.eqlIgnoreCase(name, "host")) {
            if (req.host != null) return error.BadRequest;
            if (value.len == 0 and req.version == .http11) return error.BadRequest;
            if (anyByte(value, isHostSeparator)) return error.BadRequest;
            req.host = value;
        },
        6 => if (std.ascii.eqlIgnoreCase(name, "expect")) {
            if (std.ascii.eqlIgnoreCase(value, "100-continue")) req.expect_continue = true;
        },
        10 => if (std.ascii.eqlIgnoreCase(name, "connection")) {
            var it = std.mem.tokenizeAny(u8, value, ", \t");
            while (it.next()) |tok| {
                if (std.ascii.eqlIgnoreCase(tok, "close")) req.keep_alive = false;
                if (std.ascii.eqlIgnoreCase(tok, "keep-alive") and req.version == .http10) req.keep_alive = true;
            }
        },
        14 => if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            const n = std.fmt.parseInt(u64, value, 10) catch return error.BadRequest;
            if (req.content_length) |old| if (old != n) return error.BadRequest;
            req.content_length = n;
        },
        17 => if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (req.version == .http10) return error.BadRequest;
            // only "chunked" (possibly with identity) is supported, like nginx
            var it = std.mem.tokenizeAny(u8, value, ", \t");
            var saw_chunked = false;
            while (it.next()) |tok| {
                if (std.ascii.eqlIgnoreCase(tok, "chunked")) {
                    saw_chunked = true;
                } else if (!std.ascii.eqlIgnoreCase(tok, "identity")) return error.NotImplemented;
            }
            if (!saw_chunked) return error.NotImplemented;
            req.chunked = true;
        },
        else => {},
    }
}

fn parseRequestLine(line: []const u8, req: *Request, path_buf: []u8, limits: Limits, merge_slashes: bool) ParseError!void {
    req.line = line;
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadRequest;
    const method = line[0..sp1];
    if (method.len == 0) return error.BadRequest;
    for (method) |ch| if (!(ch >= 'A' and ch <= 'Z') and ch != '_' and ch != '-') return error.BadRequest;
    req.method_raw = method;
    req.method = std.meta.stringToEnum(Method, method) orelse .other;
    var rest = line[sp1 + 1 ..];
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    const sp2 = std.mem.lastIndexOfScalar(u8, rest, ' ') orelse {
        // HTTP/0.9 simple request: not supported
        return error.BadRequest;
    };
    const target = std.mem.trimEnd(u8, rest[0..sp2], " ");
    const ver = rest[sp2 + 1 ..];
    if (target.len == 0) return error.BadRequest;
    if (target.len > limits.max_uri) return error.UriTooLong;
    if (std.mem.eql(u8, ver, "HTTP/1.1")) {
        req.version = .http11;
        req.keep_alive = true;
    } else if (std.mem.eql(u8, ver, "HTTP/1.0")) {
        req.version = .http10;
        req.keep_alive = false;
    } else if (ver.len == 8 and std.mem.startsWith(u8, ver, "HTTP/") and std.ascii.isDigit(ver[5]) and ver[6] == '.' and std.ascii.isDigit(ver[7])) {
        if (ver[5] == '1') {
            req.version = .http11; // HTTP/1.x minor > 1: treat as 1.1
        } else return error.VersionNotSupported;
    } else return error.BadRequest;
    if (anyByte(target, isCtlOrSpace)) return error.BadRequest;
    req.target = target;
    var path_part = target;
    if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) {
        // absolute-form: host from the URI overrides Host (RFC 9112 3.2.2)
        const after = target[std.mem.indexOf(u8, target, "//").? + 2 ..];
        const slash = std.mem.indexOfAny(u8, after, "/?") orelse after.len;
        req.host = after[0..slash];
        path_part = if (slash < after.len) after[slash..] else "/";
    } else if (method.len == 7 and std.mem.eql(u8, method, "OPTIONS") and std.mem.eql(u8, target, "*")) {
        req.path = "*";
        return;
    } else if (target[0] != '/') return error.BadRequest;
    if (std.mem.indexOfScalar(u8, path_part, '?')) |q| {
        req.args = path_part[q + 1 ..];
        path_part = path_part[0..q];
    }
    if (path_part.len == 0) path_part = "/";
    req.path = normalizePath(path_part, path_buf, merge_slashes) orelse return error.BadRequest;
}

/// Percent-decode and resolve `.`/`..` segments (and optionally merge slashes), like
/// nginx's ngx_http_parse_complex_uri. Returns null for paths escaping the root,
/// encoded NUL bytes or bad escapes. `out` must be at least `raw.len` bytes.
pub fn normalizePath(raw: []const u8, out: []u8, merge_slashes: bool) ?[]const u8 {
    if (raw.len == 0 or raw[0] != '/' or out.len < raw.len) return null;
    // Most paths already have their canonical spelling. Keep the input slice
    // instead of copying it twice; complex paths use the same decoder below.
    if (std.mem.indexOfScalar(u8, raw, '%') == null and
        std.mem.indexOf(u8, raw, "/.") == null and
        (!merge_slashes or std.mem.indexOf(u8, raw, "//") == null)) return raw;
    // pass 1: percent-decode (+ merge slashes)
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var ch = raw[i];
        if (ch == '%') {
            if (i + 2 >= raw.len) return null;
            const v = std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16) catch return null;
            if (v == 0) return null;
            ch = v;
            i += 2;
        }
        if (ch == '/' and merge_slashes and n > 0 and out[n - 1] == '/') continue;
        out[n] = ch;
        n += 1;
    }
    // pass 2: resolve "." and ".." segments in place. out[0..w] is the resolved path
    // without a trailing slash (w == 0 means the root).
    var w: usize = 0;
    var r: usize = 0; // out[r] == '/'
    var dir_end = false;
    while (r < n) {
        const seg_start = r + 1;
        var seg_end = seg_start;
        while (seg_end < n and out[seg_end] != '/') seg_end += 1;
        const seg = out[seg_start..seg_end];
        const last = seg_end >= n;
        if (std.mem.eql(u8, seg, ".")) {
            dir_end = true;
        } else if (std.mem.eql(u8, seg, "..")) {
            if (w == 0) return null; // above root
            while (w > 0 and out[w - 1] != '/') w -= 1;
            w -= 1;
            dir_end = true;
        } else if (seg.len == 0 and last) {
            dir_end = true; // trailing slash
        } else {
            out[w] = '/';
            std.mem.copyForwards(u8, out[w + 1 .. w + 1 + seg.len], seg);
            w += 1 + seg.len;
            dir_end = false;
        }
        if (last) break;
        r = seg_end;
    }
    if (w == 0 or dir_end) {
        out[w] = '/';
        w += 1;
    }
    return out[0..w];
}

/// Incremental decoder for `Transfer-Encoding: chunked` bodies. Decodes in place:
/// payload bytes are compacted to the front of the buffer passed to `feed`.
pub const ChunkedDecoder = struct {
    state: enum { size, ext, size_lf, data, data_cr, data_lf, trailer_start, trailer, trailer_lf, final_lf, done } = .size,
    remaining: u64 = 0,
    size_digits: u8 = 0,

    pub const Result = struct { consumed: usize, produced: usize };

    pub const Error = error{BadChunk};

    /// Process `buf[0..]`; decoded bytes are written to `buf[0..produced]`.
    pub fn feed(d: *ChunkedDecoder, buf: []u8) Error!Result {
        var i: usize = 0;
        var o: usize = 0;
        while (i < buf.len and d.state != .done) {
            const ch = buf[i];
            switch (d.state) {
                .size => {
                    if (std.fmt.charToDigit(ch, 16)) |v| {
                        if (d.size_digits >= 15) return error.BadChunk;
                        d.remaining = d.remaining * 16 + v;
                        d.size_digits += 1;
                    } else |_| {
                        if (d.size_digits == 0) return error.BadChunk;
                        if (ch == ';' or ch == ' ' or ch == '\t') {
                            d.state = .ext;
                        } else if (ch == '\r') {
                            d.state = .size_lf;
                        } else if (ch == '\n') {
                            d.afterSizeLine();
                        } else return error.BadChunk;
                    }
                    i += 1;
                },
                .ext => {
                    if (ch == '\r') d.state = .size_lf else if (ch == '\n') d.afterSizeLine();
                    i += 1;
                },
                .size_lf => {
                    if (ch != '\n') return error.BadChunk;
                    d.afterSizeLine();
                    i += 1;
                },
                .data => {
                    const take: usize = @intCast(@min(d.remaining, buf.len - i));
                    std.mem.copyForwards(u8, buf[o .. o + take], buf[i .. i + take]);
                    o += take;
                    i += take;
                    d.remaining -= take;
                    if (d.remaining == 0) d.state = .data_cr;
                },
                .data_cr => {
                    if (ch == '\r') d.state = .data_lf else if (ch == '\n') d.reset() else return error.BadChunk;
                    i += 1;
                },
                .data_lf => {
                    if (ch != '\n') return error.BadChunk;
                    d.reset();
                    i += 1;
                },
                .trailer_start => {
                    if (ch == '\r') d.state = .final_lf else if (ch == '\n') d.state = .done else d.state = .trailer;
                    i += 1;
                },
                .trailer => {
                    if (ch == '\n') d.state = .trailer_start else if (ch == '\r') d.state = .trailer_lf;
                    i += 1;
                },
                .trailer_lf => {
                    if (ch != '\n') return error.BadChunk;
                    d.state = .trailer_start;
                    i += 1;
                },
                .final_lf => {
                    if (ch != '\n') return error.BadChunk;
                    d.state = .done;
                    i += 1;
                },
                .done => unreachable,
            }
        }
        return .{ .consumed = i, .produced = o };
    }

    fn afterSizeLine(d: *ChunkedDecoder) void {
        d.state = if (d.remaining == 0) .trailer_start else .data;
    }
    fn reset(d: *ChunkedDecoder) void {
        d.state = .size;
        d.remaining = 0;
        d.size_digits = 0;
    }
    pub fn isDone(d: *const ChunkedDecoder) bool {
        return d.state == .done;
    }
};

// ---------------------------------------------------------------- tests
const t = std.testing;

fn parse(s: []const u8, req: *Request, pb: []u8) ParseError!Status {
    return parseHead(s, 0, req, pb, .{}, true);
}

test "parse simple GET 1.1" {
    var req: Request = .{};
    var pb: [256]u8 = undefined;
    const s = "GET /a/./b/../c%20d?x=1&y=2 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: t\r\n\r\nNEXT";
    try t.expectEqual(Status.complete, try parse(s, &req, &pb));
    try t.expectEqual(Method.GET, req.method);
    try t.expectEqualStrings("/a/c d", req.path);
    try t.expectEqualStrings("x=1&y=2", req.args);
    try t.expectEqualStrings("example.com", req.host.?);
    try t.expect(req.keep_alive);
    try t.expectEqualStrings("NEXT", s[req.head_len..]);
    try t.expectEqualStrings("t", req.headerVar("user_agent").?);
}

test "reused request resets metadata and hides previous headers" {
    var req: Request = .{};
    var pb: [256]u8 = undefined;
    _ = try parse("POST /old?q=1 HTTP/1.1\r\nHost: old\r\nContent-Length: 7\r\nExpect: 100-continue\r\nConnection: close\r\nX-Old: secret\r\n\r\n", &req, &pb);
    try t.expect(req.expect_continue);
    _ = try parse("GET /new HTTP/1.1\r\nHost: new\r\n\r\n", &req, &pb);
    try t.expectEqual(Method.GET, req.method);
    try t.expectEqualStrings("/new", req.path);
    try t.expectEqualStrings("", req.args);
    try t.expectEqualStrings("new", req.host.?);
    try t.expectEqual(@as(usize, 1), req.nheaders);
    try t.expect(req.header("x-old") == null);
    try t.expect(req.content_length == null);
    try t.expect(!req.expect_continue and !req.chunked and req.keep_alive);
}

test "incomplete, 1.0 keep-alive, pipelining" {
    var req: Request = .{};
    var pb: [256]u8 = undefined;
    try t.expectEqual(Status.incomplete, try parse("GET / HTTP/1.1\r\nHost: a\r\n", &req, &pb));
    try t.expectEqual(Status.complete, try parse("GET / HTTP/1.0\r\n\r\n", &req, &pb));
    try t.expect(!req.keep_alive);
    try t.expectEqual(Status.complete, try parse("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", &req, &pb));
    try t.expect(req.keep_alive);
    const two = "GET /1 HTTP/1.1\r\nHost: a\r\n\r\nGET /2 HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n";
    try t.expectEqual(Status.complete, try parse(two, &req, &pb));
    try t.expectEqualStrings("/1", req.path);
    const rest = two[req.head_len..];
    try t.expectEqual(Status.complete, try parse(rest, &req, &pb));
    try t.expectEqualStrings("/2", req.path);
    try t.expect(!req.keep_alive);
}

test "malformed requests" {
    var req: Request = .{};
    var pb: [256]u8 = undefined;
    const bad = [_]struct { s: []const u8, e: ParseError }{
        .{ .s = "GET / HTTP/1.1\r\n\r\n", .e = error.BadRequest }, // no Host
        .{ .s = "GET /../etc/passwd HTTP/1.0\r\n\r\n", .e = error.BadRequest },
        .{ .s = "GET /%00 HTTP/1.0\r\n\r\n", .e = error.BadRequest },
        .{ .s = "GET /%zz HTTP/1.0\r\n\r\n", .e = error.BadRequest },
        .{ .s = "get / HTTP/1.0\r\n\r\n", .e = error.BadRequest },
        .{ .s = "GET / HTTP/2.0\r\n\r\n", .e = error.VersionNotSupported },
        .{ .s = "GET / FOO/1.0\r\n\r\n", .e = error.BadRequest },
        .{ .s = "GET /\r\n\r\n", .e = error.BadRequest },
        .{ .s = "GET / HTTP/1.1\r\nHost: a\r\nBad Header: x\r\n\r\n", .e = error.BadRequest },
        .{ .s = "GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", .e = error.BadRequest },
        .{ .s = "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: abc\r\n\r\n", .e = error.BadRequest },
        .{ .s = "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n", .e = error.BadRequest },
        .{ .s = "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip\r\n\r\n", .e = error.NotImplemented },
        .{ .s = "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n", .e = error.BadRequest },
        .{ .s = "GET / HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n", .e = error.BadRequest },
    };
    for (bad) |b| {
        t.expectError(b.e, parse(b.s, &req, &pb)) catch |err| {
            std.debug.print("case: {s}\n", .{b.s});
            return err;
        };
    }
    // oversized
    var big: [20000]u8 = @splat('a');
    @memcpy(big[0..5], "GET /");
    try t.expectError(error.UriTooLong, parse(&big, &req, &pb));
}

test "normalize path" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("/", normalizePath("/", &buf, true).?);
    try t.expectEqualStrings("/a/", normalizePath("//a//", &buf, true).?);
    try t.expectEqualStrings("//a//", normalizePath("//a//", &buf, false).?);
    try t.expectEqualStrings("/b", normalizePath("/a/../b", &buf, true).?);
    try t.expectEqualStrings("/a/", normalizePath("/a/b/..", &buf, true).?);
    try t.expectEqualStrings("/a/", normalizePath("/a/.", &buf, true).?);
    try t.expect(normalizePath("/..", &buf, true) == null);
    try t.expectEqualStrings("/a b", normalizePath("/a%20b", &buf, true).?);
}

test "chunked decoder: split at every byte" {
    const body = "4\r\nWiki\r\n5;ext=1\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nX-Trailer: 1\r\n\r\nNEXT";
    // whole
    {
        var buf: [128]u8 = undefined;
        @memcpy(buf[0..body.len], body);
        var d: ChunkedDecoder = .{};
        const r = try d.feed(buf[0..body.len]);
        try t.expect(d.isDone());
        try t.expectEqualStrings("Wikipedia in\r\n\r\nchunks.", buf[0..r.produced]);
        try t.expectEqualStrings("NEXT", body[r.consumed..]);
    }
    // byte by byte
    var d: ChunkedDecoder = .{};
    var out: [64]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (!d.isDone()) : (i += 1) {
        var one = [1]u8{body[i]};
        const r = try d.feed(&one);
        try t.expectEqual(@as(usize, 1), r.consumed);
        if (r.produced == 1) {
            out[n] = one[0];
            n += 1;
        }
    }
    try t.expectEqualStrings("Wikipedia in\r\n\r\nchunks.", out[0..n]);
}

test "chunked decoder rejects garbage" {
    var d: ChunkedDecoder = .{};
    var b1 = "zz\r\n".*;
    try t.expectError(error.BadChunk, d.feed(&b1));
    d = .{};
    var b2 = "3\r\nabcX".*;
    try t.expectError(error.BadChunk, d.feed(&b2));
}

test "anyByte covers every length and position" {
    var buf: [40]u8 = undefined;
    for (0..buf.len + 1) |len| {
        @memset(buf[0..len], 'a');
        try std.testing.expect(!anyByte(buf[0..len], isNulOrCr));
        for (0..len) |pos| {
            buf[pos] = '\r';
            try std.testing.expect(anyByte(buf[0..len], isNulOrCr));
            buf[pos] = 0x7f;
            try std.testing.expect(anyByte(buf[0..len], isCtlOrSpace));
            try std.testing.expect(!anyByte(buf[0..len], isNulOrCr));
            buf[pos] = '\\';
            try std.testing.expect(anyByte(buf[0..len], isHostSeparator));
            buf[pos] = 'a';
        }
    }
}

test "ByteIter matches a linear scan" {
    var buf: [70]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = if (i % 7 == 3 or i == 69) '\n' else 'x';
    for (0..buf.len + 1) |len| {
        var it: ByteIter = .{ .h = buf[0..len], .c = '\n' };
        var from: usize = 0;
        while (true) {
            const want = std.mem.indexOfScalarPos(u8, buf[0..len], from, '\n');
            try std.testing.expectEqual(want, it.next(from));
            from = (want orelse break) + 1;
        }
    }
}
