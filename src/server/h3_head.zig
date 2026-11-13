//! Head conversion for the HTTP/3 bridge (`h3.zig`): HTTP/3 request fields to
//! HTTP/1.1 request text, and the engine's HTTP/1.1 response head back to
//! field lists. Nothing here depends on the QUIC transport, so the rules are
//! unit-tested with the rest of the server.
const std = @import("std");
const request = @import("../http/request.zig");

/// Request fields accepted, counting the four added by the conversion.
pub const max_fields = 96;
/// Largest request head text, before the fixed parts.
pub const head_cap = 14 * 1024;
/// Largest response head collected from the engine.
pub const response_head_cap = 32 * 1024;
/// Response fields forwarded.
pub const max_response_fields = 100;
/// Lowercased response field names held by `parseDirect` (callers add 16
/// bytes of vector slack).
pub const names_cap = 2048;

pub fn eqlAny(name: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |x| if (name.len == x.len and std.mem.eql(u8, name, x)) return true;
    return false;
}

/// No NUL, CR or LF: a value copied into the HTTP/1.1 text cannot split a line.
fn safeValue(v: []const u8) bool {
    return !request.anyByte(v, isLineBreak);
}

fn isLineBreak(x: anytype) @TypeOf(x == x) {
    const T = @TypeOf(x);
    return request.isNulOrCr(x) | (x == @as(T, @splat('\n')));
}

/// No control characters, space or DEL in the request target.
fn safePath(v: []const u8) bool {
    return !request.anyByte(v, request.isCtlOrSpace);
}

// ---------------------------------------------------------------- request head

/// How a validated request is written as HTTP/1.1 text.
pub const Plan = struct {
    authority: []const u8,
    content_length: ?[]const u8,
    /// Declared request body length.
    body_left: ?u64,
    /// The body is framed as chunks (no length, more DATA may follow).
    chunked: bool,
    /// No body at all.
    body_end: bool,
    /// Upper bound of the text `emit` writes.
    bound: usize,
};

/// Validates a decoded HTTP/3 request for conversion. `r` provides `method`,
/// `scheme`, `authority` and `path` slices, `headers()` returning fields
/// with `name` and `value`, and `ended()`. Null: malformed.
pub fn plan(r: anytype) ?Plan {
    if (r.method.len == 0 or r.method.len >= 32 or r.path.len == 0 or r.path.len > 8192) return null;
    if (!std.mem.eql(u8, r.scheme, "https")) return null;
    if (!safeValue(r.method) or !safeValue(r.authority)) return null;
    if (!safePath(r.path)) return null;
    var authority = r.authority;
    var content_length: ?[]const u8 = null;
    var size: usize = r.method.len + r.path.len + authority.len + 64;
    const fields = r.headers();
    if (fields.len + 4 > max_fields) return null;
    for (fields) |f| {
        if (!safeValue(f.value)) return null;
        if (eqlAny(f.name, &.{ "connection", "transfer-encoding", "upgrade", "keep-alive", "proxy-connection" })) return null;
        if (eqlAny(f.name, &.{"host"})) {
            if (authority.len == 0) {
                authority = f.value;
            } else if (!std.mem.eql(u8, authority, f.value)) return null;
        } else if (eqlAny(f.name, &.{"te"})) {
            if (!std.mem.eql(u8, f.value, "trailers")) return null;
        } else if (eqlAny(f.name, &.{"content-length"})) {
            if (content_length != null or f.value.len == 0 or f.value.len >= 20) return null;
            for (f.value) |ch| if (ch < '0' or ch > '9') return null;
            content_length = f.value;
        }
        size += f.name.len + f.value.len + 4;
    }
    if (authority.len == 0 or authority.len >= 1024) return null;
    if (size > head_cap) return null;
    const ended = r.ended();
    var body_left: ?u64 = null;
    if (content_length) |cl| body_left = std.fmt.parseInt(u64, cl, 10) catch return null;
    return .{
        .authority = authority,
        .content_length = content_length,
        .body_left = body_left,
        .chunked = content_length == null and !ended,
        .body_end = content_length == null and ended,
        // `size` counts every variable part plus 64. The fixed text of
        // `emit` adds at most 69 bytes (Transfer-Encoding and Content-Length
        // are exclusive), within the 128 added in total.
        .bound = size + 64,
    };
}

/// Writes the HTTP/1.1 request head for `r` as planned; `out` holds at least
/// `bound` bytes of the plan. Returns the length written.
pub fn emit(r: anytype, authority: []const u8, chunked: bool, content_length: ?[]const u8, out: []u8) usize {
    var n: usize = 0;
    const put = struct {
        fn f(o: []u8, at: *usize, bytes: []const u8) void {
            @memcpy(o[at.*..][0..bytes.len], bytes);
            at.* += bytes.len;
        }
    }.f;
    put(out, &n, r.method);
    put(out, &n, " ");
    put(out, &n, r.path);
    put(out, &n, " HTTP/1.1\r\nHost: ");
    put(out, &n, authority);
    put(out, &n, "\r\nConnection: close\r\n");
    if (chunked) put(out, &n, "Transfer-Encoding: chunked\r\n");
    if (content_length) |cl| {
        put(out, &n, "Content-Length: ");
        put(out, &n, cl);
        put(out, &n, "\r\n");
    }
    for (r.headers()) |f| {
        if (eqlAny(f.name, &.{ "host", "te", "content-length", "expect" })) continue;
        put(out, &n, f.name);
        put(out, &n, ": ");
        put(out, &n, f.value);
        put(out, &n, "\r\n");
    }
    put(out, &n, "\r\n");
    return n;
}

// ---------------------------------------------------------------- response head

const ByteIter = request.ByteIter;

/// Offset just past the first "\r\n\r\n" at or after `from`.
pub fn headEnd(h: []const u8, from: usize) ?usize {
    var nl: ByteIter = .{ .h = h, .c = '\n' };
    var i = from;
    while (nl.next(i)) |j| {
        if (j >= 3 and h[j - 1] == '\r' and h[j - 2] == '\n' and h[j - 3] == '\r' and j - 3 >= from) return j + 1;
        i = j + 1;
    }
    return null;
}

/// ASCII-lowercases `h[at..][0..len]`, 16 bytes at a time; whole vectors
/// may cover bytes past the name (written back unchanged).
pub fn lower(h: []u8, at: usize, len: usize) void {
    const V = @Vector(16, u8);
    var i = at;
    const end = at + len;
    while (i < end and i + 16 <= h.len) : (i += 16) {
        const v: V = h[i..][0..16].*;
        const idx = std.simd.iota(u8, 16);
        const room: V = @splat(@intCast(@min(end - i, 16)));
        const up = (v -% @as(V, @splat('A'))) < @as(V, @splat(26));
        const lowered = @select(u8, up, v | @as(V, @splat(0x20)), v);
        h[i..][0..16].* = @select(u8, idx < room, lowered, v);
    }
    while (i < end) : (i += 1) h[i] = std.ascii.toLower(h[i]);
}

/// Writes `src` ASCII-lowercased to `dst[0..src.len]`, reading `src.ptr` up
/// to `readable` bytes. `dst` must have 16 spare bytes when `readable`
/// exceeds `src.len`.
pub fn lowerInto(dst: []u8, src: []const u8, readable: usize) void {
    const V = @Vector(16, u8);
    var i: usize = 0;
    while (i < src.len and i + 16 <= readable) : (i += 16) {
        const v: V = src.ptr[i..][0..16].*;
        const up = (v -% @as(V, @splat('A'))) < @as(V, @splat(26));
        dst[i..][0..16].* = @select(u8, up, v | @as(V, @splat(0x20)), v);
    }
    while (i < src.len) : (i += 1) dst[i] = std.ascii.toLower(src[i]);
}

/// Hop-by-hop response fields that HTTP/3 forbids (RFC 9114 4.2).
pub fn hopHeader(name: []const u8) bool {
    return switch (name.len) {
        7 => eqlAny(name, &.{ "upgrade", "trailer" }),
        10 => eqlAny(name, &.{ "connection", "keep-alive" }),
        16 => std.mem.eql(u8, name, "proxy-connection"),
        17 => std.mem.eql(u8, name, "transfer-encoding"),
        else => false,
    };
}

pub const Final = struct {
    status: u16,
    /// Fields stored in the caller's array.
    count: usize,
    /// Bytes of the head including the blank line.
    end: usize,
};

/// Parses a complete, well-formed final (2xx-9xx) response head at the start
/// of `data` in one line scan. Names are lowercased into `names`; values
/// borrow `data`. Null for anything else (partial, informational, unusual or
/// invalid heads, or more fields or name bytes than fit), which the caller
/// handles with `parseCollected` once the head is complete.
pub fn parseDirect(comptime F: type, data: []const u8, fields: []F, names: []u8) ?Final {
    const h = data[0..@min(data.len, response_head_cap)];
    if (h.len < 16 or !std.mem.startsWith(u8, h, "HTTP/1.")) return null;
    const status = std.fmt.parseInt(u16, h[9..12], 10) catch return null;
    if (status < 200 or status > 999) return null;
    var used: usize = 0;
    var count: usize = 0;
    var nls: ByteIter = .{ .h = h, .c = '\n' };
    const first = nls.next(0) orelse return null;
    if (h[first - 1] != '\r') return null;
    var pos = first + 1;
    while (true) {
        const nl = nls.next(pos) orelse return null;
        if (nl == pos or h[nl - 1] != '\r') return null;
        if (nl == pos + 1) return .{ .status = status, .count = count, .end = nl + 1 };
        const line = h[pos .. nl - 1];
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        if (colon == 0 or used + colon + 16 > names.len) return null;
        var v = colon + 1;
        while (v < line.len and (line[v] == ' ' or line[v] == '\t')) v += 1;
        const name = names[used..][0..colon];
        lowerInto(names[used..], line[0..colon], h.len - pos);
        pos = nl + 1;
        if (hopHeader(name)) continue;
        if (count == fields.len) return null;
        fields[count] = .{ .name = name, .value = line[v..] };
        count += 1;
        used += colon;
    }
}

pub const Collected = union(enum) {
    final: struct { status: u16, count: usize },
    informational,
    invalid,
};

/// Parses a complete response head (ending in the blank line) collected
/// from the engine. Names are lowercased in place; fields borrow `h`.
pub fn parseCollected(comptime F: type, h: []u8, fields: []F) Collected {
    if (h.len < 16 or !std.mem.startsWith(u8, h, "HTTP/1.")) return .invalid;
    const status = std.fmt.parseInt(u16, h[9..12], 10) catch return .invalid;
    if (status < 100 or status > 999) return .invalid;
    if (status < 200) return .informational;
    var count: usize = 0;
    // Lowercasing names below changes no '\n' or ':' byte, so the iterators'
    // cached masks stay valid.
    var nls: ByteIter = .{ .h = h, .c = '\n' };
    var colons: ByteIter = .{ .h = h, .c = ':' };
    var pos = (nls.next(0) orelse return .invalid) + 1;
    while (pos + 2 < h.len) {
        const nl = nls.next(pos) orelse return .invalid;
        if (nl == pos or h[nl - 1] != '\r') return .invalid;
        const line = h[pos .. nl - 1];
        const at = colons.next(pos) orelse return .invalid;
        if (at >= nl - 1) return .invalid;
        const colon = at - pos;
        pos = nl + 1;
        const name = line[0..colon];
        lower(h, nl - 1 - line.len, colon);
        var v = colon + 1;
        while (v < line.len and (line[v] == ' ' or line[v] == '\t')) v += 1;
        if (hopHeader(name)) continue;
        if (count == fields.len) return .invalid;
        fields[count] = .{ .name = name, .value = line[v..] };
        count += 1;
    }
    return .{ .final = .{ .status = status, .count = count } };
}

// ---------------------------------------------------------------- tests

const t = std.testing;
const Field = struct { name: []const u8, value: []const u8 };

/// `n` copies of `c`, as a comptime string.
fn rep(comptime c: u8, comptime n: usize) *const [n]u8 {
    return comptime &@as([n]u8, @splat(c));
}

const FakeRequest = struct {
    method: []const u8 = "GET",
    scheme: []const u8 = "https",
    authority: []const u8 = "example.com",
    path: []const u8 = "/",
    fields: []const Field = &.{},
    done: bool = true,

    fn headers(r: *const FakeRequest) []const Field {
        return r.fields;
    }
    fn ended(r: *const FakeRequest) bool {
        return r.done;
    }
};

/// Plans and emits `r`, checks the bound, and parses the text back.
fn roundTrip(r: *const FakeRequest, out: []u8, parsed: *request.Request, path_buf: []u8) !Plan {
    const p = plan(r) orelse return error.Rejected;
    try t.expect(out.len >= p.bound);
    // A write past the bound fails the slice bounds check.
    const n = emit(r, p.authority, p.chunked, p.content_length, out[0..p.bound]);
    try t.expect(n <= p.bound);
    try t.expectEqual(request.Status.complete, try request.parseHead(out[0..n], 0, parsed, path_buf, .{}, false));
    try t.expectEqual(n, parsed.head_len);
    return p;
}

test "request: simple GET becomes a close-delimited HTTP/1.1 head" {
    var out: [512]u8 = undefined;
    var pb: [256]u8 = undefined;
    var req: request.Request = .{};
    const r: FakeRequest = .{ .path = "/static/a.html?x=1", .fields = &.{
        .{ .name = "user-agent", .value = "t" },
        .{ .name = "accept", .value = "*/*" },
    } };
    const p = try roundTrip(&r, &out, &req, &pb);
    try t.expect(p.body_end and !p.chunked and p.body_left == null);
    const n = emit(&r, p.authority, p.chunked, p.content_length, &out);
    try t.expectEqualStrings("GET /static/a.html?x=1 HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n" ++
        "user-agent: t\r\naccept: */*\r\n\r\n", out[0..n]);
    try t.expectEqualStrings("example.com", req.host.?);
    try t.expect(!req.keep_alive);
    try t.expectEqualStrings("t", req.header("User-Agent").?);
}

test "request: body framing follows content-length and stream end" {
    var out: [512]u8 = undefined;
    var pb: [256]u8 = undefined;
    var req: request.Request = .{};

    // Open stream without a length: chunked.
    const chunked: FakeRequest = .{ .method = "POST", .done = false };
    const pc = try roundTrip(&chunked, &out, &req, &pb);
    try t.expect(pc.chunked and !pc.body_end and pc.body_left == null);
    try t.expect(req.chunked);

    // Declared length: passed through, body counted.
    const sized: FakeRequest = .{ .method = "POST", .done = false, .fields = &.{
        .{ .name = "content-length", .value = "12345" },
        .{ .name = "expect", .value = "100-continue" },
    } };
    const ps = try roundTrip(&sized, &out, &req, &pb);
    try t.expect(!ps.chunked and !ps.body_end);
    try t.expectEqual(@as(?u64, 12345), ps.body_left);
    try t.expectEqual(@as(?u64, 12345), req.content_length);
    // Expect is answered by HTTP/3 flow control, not forwarded.
    try t.expect(req.header("expect") == null);
    try t.expect(!req.expect_continue);

    // Zero length on an ended stream is still a declared length.
    const empty: FakeRequest = .{ .method = "POST", .fields = &.{.{ .name = "content-length", .value = "0" }} };
    const pe = try roundTrip(&empty, &out, &req, &pb);
    try t.expect(!pe.chunked and !pe.body_end);
    try t.expectEqual(@as(?u64, 0), pe.body_left);
}

test "request: host field supplies or must match the authority" {
    var out: [512]u8 = undefined;
    var pb: [256]u8 = undefined;
    var req: request.Request = .{};
    const from_host: FakeRequest = .{ .authority = "", .fields = &.{.{ .name = "host", .value = "h.example" }} };
    const p = try roundTrip(&from_host, &out, &req, &pb);
    try t.expectEqualStrings("h.example", p.authority);
    try t.expectEqualStrings("h.example", req.host.?);
    // The host field is not repeated.
    try t.expectEqual(@as(usize, 2), req.nheaders);

    const same: FakeRequest = .{ .fields = &.{.{ .name = "host", .value = "example.com" }} };
    _ = try roundTrip(&same, &out, &req, &pb);
    const differs: FakeRequest = .{ .fields = &.{.{ .name = "host", .value = "other.example" }} };
    try t.expect(plan(&differs) == null);
    const none: FakeRequest = .{ .authority = "" };
    try t.expect(plan(&none) == null);
}

test "request: malformed or smuggling requests are rejected" {
    const bad = [_]FakeRequest{
        .{ .method = "" },
        .{ .method = rep('A', 32) },
        .{ .path = "" },
        .{ .path = "/" ++ rep('a', 8192) },
        .{ .scheme = "http" },
        .{ .method = "GET\r\nX: y" },
        .{ .authority = "a\nb" },
        .{ .authority = rep('a', 1024) },
        .{ .path = "/a b" },
        .{ .path = "/a\x00" },
        .{ .path = "/a\x7f" },
        .{ .fields = &.{.{ .name = "x", .value = "a\r\nInjected: 1" }} },
        .{ .fields = &.{.{ .name = "x", .value = "a\x00" }} },
        .{ .fields = &.{.{ .name = "connection", .value = "close" }} },
        .{ .fields = &.{.{ .name = "transfer-encoding", .value = "chunked" }} },
        .{ .fields = &.{.{ .name = "upgrade", .value = "h2c" }} },
        .{ .fields = &.{.{ .name = "keep-alive", .value = "1" }} },
        .{ .fields = &.{.{ .name = "proxy-connection", .value = "x" }} },
        .{ .fields = &.{.{ .name = "te", .value = "gzip" }} },
        .{ .fields = &.{.{ .name = "content-length", .value = "" }} },
        .{ .fields = &.{.{ .name = "content-length", .value = "-1" }} },
        .{ .fields = &.{.{ .name = "content-length", .value = "1 " }} },
        .{ .fields = &.{.{ .name = "content-length", .value = rep('1', 20) }} },
        .{ .fields = &.{ .{ .name = "content-length", .value = "1" }, .{ .name = "content-length", .value = "1" } } },
    };
    for (bad, 0..) |r, i| {
        if (plan(&r) != null) {
            std.debug.print("accepted bad request #{d}\n", .{i});
            return error.TestUnexpectedResult;
        }
    }
    // te: trailers is the one allowed TE value and is not forwarded.
    const te: FakeRequest = .{ .fields = &.{.{ .name = "te", .value = "trailers" }} };
    try t.expect(plan(&te) != null);
}

test "request: field count and head size limits" {
    var fields: [max_fields]Field = undefined;
    for (&fields) |*f| f.* = .{ .name = "x", .value = "y" };
    const at_limit: FakeRequest = .{ .fields = fields[0 .. max_fields - 4] };
    try t.expect(plan(&at_limit) != null);
    const over: FakeRequest = .{ .fields = fields[0 .. max_fields - 3] };
    try t.expect(plan(&over) == null);

    const big = rep('v', (head_cap - 200));
    const fits: FakeRequest = .{ .fields = &.{.{ .name = "x", .value = big }} };
    try t.expect(plan(&fits) != null);
    const too_big: FakeRequest = .{ .fields = &.{.{ .name = "x", .value = big ++ rep('v', 200) }} };
    try t.expect(plan(&too_big) == null);
}

test "request: emitted head stays within the planned bound at the extremes" {
    var out: [head_cap + 1024]u8 = undefined;
    var pb: [8300]u8 = undefined;
    var req: request.Request = .{};
    // Longest method, path and authority, many fields and the largest
    // content-length; the same with chunked framing.
    var fields: [max_fields - 4]Field = undefined;
    for (&fields, 0..) |*f, i| f.* = .{ .name = if (i == 0) "content-length" else "x-f", .value = if (i == 0) rep('9', 19) else "v" };
    const long: FakeRequest = .{
        .method = rep('M', 31),
        .authority = rep('a', 1023),
        .path = "/" ++ rep('p', 8191),
        .fields = &fields,
        .done = false,
    };
    const p = try roundTrip(&long, &out, &req, &pb);
    try t.expect(!p.chunked);
    const chunked: FakeRequest = .{
        .method = long.method,
        .authority = long.authority,
        .path = long.path,
        .fields = fields[1..],
        .done = false,
    };
    const pc = try roundTrip(&chunked, &out, &req, &pb);
    try t.expect(pc.chunked);
    // The bound is exact enough to matter: the emitted head is near it.
    const n = emit(&chunked, pc.authority, pc.chunked, pc.content_length, &out);
    try t.expect(pc.bound - n <= 128);
}

fn expectFields(want: []const Field, got: []const Field) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |a, b| {
        try t.expectEqualStrings(a.name, b.name);
        try t.expectEqualStrings(a.value, b.value);
    }
}

/// Parses `head` both ways and checks they agree with `want`.
fn expectBoth(head: []const u8, status: u16, want: []const Field) !void {
    var fields: [max_response_fields]Field = undefined;
    var names: [names_cap + 16]u8 = undefined;
    const d = parseDirect(Field, head, &fields, &names) orelse return error.NoDirect;
    try t.expectEqual(status, d.status);
    try t.expectEqual(head.len, d.end);
    try expectFields(want, fields[0..d.count]);

    var copy: [4096]u8 = undefined;
    @memcpy(copy[0..head.len], head);
    var cf: [max_response_fields]Field = undefined;
    const c = parseCollected(Field, copy[0..head.len], &cf);
    try t.expect(c == .final);
    try t.expectEqual(status, c.final.status);
    try expectFields(want, cf[0..c.final.count]);
}

test "response: engine head parses directly and matches the collecting path" {
    try expectBoth("HTTP/1.1 200 OK\r\nServer: zhttpd\r\nDate: Fri, 13 Nov 2026 12:00:00 GMT\r\n" ++
        "Content-Type: text/html\r\nContent-Length: 612\r\nLast-Modified: Thu, 12 Nov 2026 00:00:00 GMT\r\n" ++
        "Connection: close\r\nETag: \"a-264\"\r\nAccept-Ranges: bytes\r\n\r\n", 200, &.{
        .{ .name = "server", .value = "zhttpd" },
        .{ .name = "date", .value = "Fri, 13 Nov 2026 12:00:00 GMT" },
        .{ .name = "content-type", .value = "text/html" },
        .{ .name = "content-length", .value = "612" },
        .{ .name = "last-modified", .value = "Thu, 12 Nov 2026 00:00:00 GMT" },
        .{ .name = "etag", .value = "\"a-264\"" },
        .{ .name = "accept-ranges", .value = "bytes" },
    });
    // All hop-by-hop fields are dropped, any case; values keep their case
    // and leading whitespace is skipped (tabs too).
    try expectBoth("HTTP/1.0 404 Not Found\r\nTRANSFER-ENCODING: chunked\r\nKeep-Alive: timeout=5\r\n" ++
        "Upgrade: h2c\r\nTrailer: x\r\nProxy-Connection: x\r\nX-Mixed-CASE-Name-Longer-Than-16:\t  Value\r\n" ++
        "Empty:\r\n\r\n", 404, &.{
        .{ .name = "x-mixed-case-name-longer-than-16", .value = "Value" },
        .{ .name = "empty", .value = "" },
    });
    // Three-digit status outside the common range.
    try expectBoth("HTTP/1.1 999 X\r\nA: b\r\n\r\n", 999, &.{.{ .name = "a", .value = "b" }});
    // A value may contain a colon; the name ends at the first.
    try expectBoth("HTTP/1.1 302 Found\r\nLocation: https://e.example:8443/x\r\n\r\n", 302, &.{
        .{ .name = "location", .value = "https://e.example:8443/x" },
    });
}

test "response: direct parse stops at the head and leaves the body" {
    var fields: [max_response_fields]Field = undefined;
    var names: [names_cap + 16]u8 = undefined;
    const head = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n";
    const d = parseDirect(Field, head ++ "hello", &fields, &names).?;
    try t.expectEqual(head.len, d.end);
    try t.expectEqual(@as(usize, 1), d.count);
}

test "response: unusual heads fall back to the collecting path" {
    var fields: [max_response_fields]Field = undefined;
    var names: [names_cap + 16]u8 = undefined;
    const fallback = [_][]const u8{
        // Partial heads.
        "HTTP/1.1 200 OK\r\nA: b\r\n",
        "HTTP/1.1 200 OK\r\nA: b\r\n\r",
        "HTTP/1.1 200",
        // Informational and invalid status lines.
        "HTTP/1.1 100 Continue\r\n\r\n",
        "HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n",
        "HTTP/1.1 099 X\r\nA: b\r\n\r\n",
        "HTTP/1.1 2x0 X\r\nA: b\r\n\r\n",
        "HTTP/2.0 200 OK\r\nA: b\r\n\r\n",
        "ICY 200 OK\r\nA: b\r\n\r\n\r\n",
        // Bare LF line ends, missing colon, empty name.
        "HTTP/1.1 200 OK\nA: b\r\n\r\n",
        "HTTP/1.1 200 OK\r\nA: b\n\r\n",
        "HTTP/1.1 200 OK\r\nA: b\r\n\n",
        "HTTP/1.1 200 OK\r\nNo colon\r\n\r\n",
        "HTTP/1.1 200 OK\r\n: v\r\n\r\n",
    };
    for (fallback, 0..) |h, i| {
        if (parseDirect(Field, h, &fields, &names) != null) {
            std.debug.print("direct accepted #{d}\n", .{i});
            return error.TestUnexpectedResult;
        }
    }
}

test "response: field and name limits fall back instead of truncating" {
    var fields: [max_response_fields]Field = undefined;
    var names: [names_cap + 16]u8 = undefined;
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Exactly the field limit parses; one more falls back, and hop fields
    // do not count toward it.
    try w.writeAll("HTTP/1.1 200 OK\r\n");
    for (0..max_response_fields) |_| try w.writeAll("A: b\r\nConnection: close\r\n");
    try w.writeAll("\r\n");
    try t.expectEqual(max_response_fields, parseDirect(Field, w.buffered(), &fields, &names).?.count);
    w.end -= 2;
    try w.writeAll("A: b\r\n\r\n");
    try t.expect(parseDirect(Field, w.buffered(), &fields, &names) == null);
    var copy: [8192]u8 = undefined;
    @memcpy(copy[0..w.end], w.buffered());
    try t.expect(parseCollected(Field, copy[0..w.end], &fields) == .invalid);

    // Name bytes beyond the stack buffer fall back; the collecting path,
    // which lowercases in place, still accepts the head.
    w.end = 0;
    try w.writeAll("HTTP/1.1 200 OK\r\n");
    for (0..3) |_| try w.writeAll("X-" ++ rep('N', 998) ++ ": v\r\n");
    try w.writeAll("\r\n");
    try t.expect(parseDirect(Field, w.buffered(), &fields, &names) == null);
    @memcpy(copy[0..w.end], w.buffered());
    const c = parseCollected(Field, copy[0..w.end], &fields);
    try t.expectEqual(@as(usize, 3), c.final.count);
    try t.expectEqualStrings("x-" ++ rep('n', 998), fields[0].name);
}

test "response: collecting path classifies informational and invalid heads" {
    var fields: [max_response_fields]Field = undefined;
    var buf: [128]u8 = undefined;
    const Tag = std.meta.Tag(Collected);
    const cases = .{
        .{ "HTTP/1.1 100 Continue\r\n\r\n", Tag.informational },
        .{ "HTTP/1.1 099 Nope\r\n\r\n", Tag.invalid },
        .{ "HTTP/2.0 200 OK\r\n\r\n", Tag.invalid },
        .{ "HTTP/1.1 200 OK\r\nNo colon\r\n\r\n", Tag.invalid },
        .{ "HTTP/1.1 200 OK\r\nA: b\n\r\n", Tag.invalid },
    };
    inline for (cases) |c| {
        @memcpy(buf[0..c[0].len], c[0]);
        try t.expectEqual(c[1], std.meta.activeTag(parseCollected(Field, buf[0..c[0].len], &fields)));
    }
}

test "headEnd finds the blank line from any resume point" {
    const h = "HTTP/1.1 200 OK\r\nA: b\r\n\r\nbody\r\n\r\n";
    const end = "HTTP/1.1 200 OK\r\nA: b\r\n\r\n".len;
    for (0..end - 3) |from| try t.expectEqual(@as(?usize, end), headEnd(h, from));
    try t.expect(headEnd("HTTP/1.1 200 OK\r\nA: b\r\n", 0) == null);
    try t.expect(headEnd("HTTP/1.1 200 OK\n\n", 0) == null);
}

test "lower and lowerInto handle every length and alignment" {
    var src: [80]u8 = undefined;
    for (&src, 0..) |*c, i| c.* = "AbZz@[`{09-_\xc0Q"[i % 14];
    for (0..48) |len| {
        for (0..17) |at| {
            var h = src;
            lower(&h, at, len);
            for (h, 0..) |c, i| {
                const want = if (i >= at and i < at + len) std.ascii.toLower(src[i]) else src[i];
                try t.expectEqual(want, c);
            }
            var dst: [96]u8 = @splat(0xee);
            lowerInto(&dst, src[at..][0..len], src.len - at);
            for (0..len) |i| try t.expectEqual(std.ascii.toLower(src[at + i]), dst[i]);
            // Nothing past the last full vector covering the name.
            const touched = if (len == 0) 0 else std.mem.alignForward(usize, len, 16);
            for (dst[@min(touched, dst.len)..]) |c| try t.expectEqual(@as(u8, 0xee), c);
        }
    }
}

test "hopHeader matches exactly the forbidden names" {
    for ([_][]const u8{ "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "trailer" }) |n|
        try t.expect(hopHeader(n));
    for ([_][]const u8{ "", "te", "trailers", "upgraded", "connections", "content-length", "keep-alivE", "transfer-encodinG" }) |n|
        try t.expect(!hopHeader(n));
}
