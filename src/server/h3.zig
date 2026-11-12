//! HTTP/3 over the zquic transport. Each request stream is presented to a
//! normal `Conn` as an HTTP/1.1 byte stream (request line, headers, chunked
//! or Content-Length body); the HTTP/1.x response head is parsed back into
//! QPACK fields. Routing, limits, proxying and logging stay in the engine.
const std = @import("std");
const zquic = @import("zquic");
const net = @import("net.zig");
const os = @import("../os.zig");
const Addr = @import("../http/addr.zig").Addr;
const tls = @import("tls.zig");
const multiplex = @import("multiplex.zig");
const Conn = @import("conn.zig").Conn;
const Worker = @import("worker.zig").Worker;
const Listener = @import("worker.zig").Listener;

const zh3 = zquic.h3;
const QAddr = zquic.conn.Addr;
const Request = zh3.Request;

/// Request head conversion limits (match the HTTP/2 bridge).
const max_fields = 96;
const head_cap = 14 * 1024;
const input_cap = 64 * 1024;
/// Largest HTTP/1.x response head accepted from the engine.
const response_head_cap = 32 * 1024;
/// Receive batches (32 datagrams each) per readiness event.
const receive_batches = 8;
const pool_max = 256;

extern "c" fn pread(fd: c_int, buf: [*]u8, n: usize, off: i64) isize;

pub const Server = struct {
    alloc: std.mem.Allocator,
    listener: *Listener,
    worker: *Worker,
    h3: *zh3.Server,
    sock: *zquic.udp.Socket,
    /// Live request bridges (closed with their Conns on teardown).
    active: ?*Stream = null,
    free: ?*Stream = null,
    nfree: usize = 0,
};

pub const Stream = struct {
    server: *Server,
    req: ?*Request = null,
    cn: ?*Conn = null,
    prev: ?*Stream = null,
    next: ?*Stream = null,
    /// Converted request head followed by framed body bytes.
    input: std.ArrayList(u8) = .empty,
    input_pos: usize = 0,
    /// Response head bytes collected until the blank line.
    head: std.ArrayList(u8) = .empty,
    chunked: bool = false,
    body_end: bool = false,
    /// Declared request Content-Length still expected.
    body_left: ?u64 = null,
    submitted: bool = false,
};

// ---------------------------------------------------------------- addresses

const mapped_prefix = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };

fn toNet(a: QAddr) Addr {
    var r: Addr = .{ .port = a.port };
    if (!a.v6 or std.mem.eql(u8, a.ip[0..12], &mapped_prefix)) {
        r.family = .v4;
        @memcpy(r.ip[0..4], a.ip[12..16]);
    } else {
        r.family = .v6;
        r.ip = a.ip;
    }
    return r;
}

fn toQuic(a: Addr) QAddr {
    var r: QAddr = .{ .port = a.port };
    if (a.family == .v4) {
        @memcpy(r.ip[0..12], &mapped_prefix);
        @memcpy(r.ip[12..16], a.ip[0..4]);
    } else {
        r.v6 = true;
        r.ip = a.ip;
    }
    return r;
}

// ---------------------------------------------------------------- listener

pub fn start(l: *Listener, w: *Worker) ?*Server {
    const a = w.gpa;
    const ctx: *zquic.tls.SSL_CTX = @ptrCast(l.sni.?.default_ctx);
    const s = a.create(Server) catch return null;
    s.* = .{ .alloc = a, .listener = l, .worker = w, .h3 = undefined, .sock = undefined };
    s.h3 = zh3.Server.init(a, ctx, .{}, .{
        .ctx = s,
        .request = onRequest,
        .readable = onReadable,
        .writable = onWritable,
        .aborted = onAborted,
    }) catch {
        a.destroy(s);
        return null;
    };
    s.h3.ep.max_conns = w.max_conns;
    s.sock = zquic.udp.Socket.init(a, l.fd, toQuic(net.localAddr(l.fd))) catch {
        s.h3.deinit();
        a.destroy(s);
        return null;
    };
    s.h3.ep.sink = s.sock.sink();
    return s;
}

/// Reads ready datagrams and runs due timers. Returns true when the receive
/// budget was exhausted (more datagrams may be queued).
pub fn drive(s: *Server) bool {
    const n = s.sock.receive(s.h3.ep, receive_batches);
    service(s);
    return n >= receive_batches * 32;
}

/// Runs timers and transmits whatever the engine queued on streams.
pub fn service(s: *Server) void {
    const ep = s.h3.ep;
    ep.updateClock();
    ep.onTimers();
    ep.flush();
}

pub fn waitMs(s: *Server) i32 {
    const t = s.h3.ep.timeoutMs();
    return if (t < 0) 1000 else t;
}

pub fn free(s: *Server) void {
    // Request Conns hold bridge pointers: close them before the transport.
    while (s.active) |st| {
        if (st.cn) |cn| cn.close() else finish(st);
    }
    s.h3.ep.closeAll(zh3.Error.no_error, "");
    s.h3.ep.flush();
    s.h3.deinit();
    s.sock.deinit(s.alloc);
    while (s.free) |st| {
        s.free = st.next;
        destroyStream(s.alloc, st);
    }
    s.alloc.destroy(s);
}

// ---------------------------------------------------------------- bridges

fn newStream(s: *Server) ?*Stream {
    const st = if (s.free) |f| blk: {
        s.free = f.next;
        s.nfree -= 1;
        var input = f.input;
        var head = f.head;
        input.clearRetainingCapacity();
        head.clearRetainingCapacity();
        f.* = .{ .server = s, .input = input, .head = head };
        break :blk f;
    } else blk: {
        const f = s.alloc.create(Stream) catch return null;
        f.* = .{ .server = s };
        break :blk f;
    };
    st.next = s.active;
    if (s.active) |h| h.prev = st;
    s.active = st;
    return st;
}

fn destroyStream(a: std.mem.Allocator, st: *Stream) void {
    st.input.deinit(a);
    st.head.deinit(a);
    a.destroy(st);
}

fn recycle(st: *Stream) void {
    const s = st.server;
    if (st.prev) |p| p.next = st.next else s.active = st.next;
    if (st.next) |n| n.prev = st.prev;
    if (s.nfree >= pool_max or st.input.capacity > 16 * 1024 or st.head.capacity > 16 * 1024) {
        destroyStream(s.alloc, st);
        return;
    }
    st.prev = null;
    st.next = s.free;
    s.free = st;
    s.nfree += 1;
}

/// Ends the bridge: FIN after a submitted response, otherwise a reset.
fn finish(st: *Stream) void {
    if (st.req) |r| {
        if (st.submitted) r.finish() else r.reset(zh3.Error.internal);
        r.release();
        st.req = null;
    }
    st.cn = null;
    recycle(st);
}

fn server(ctx: ?*anyopaque) *Server {
    return @ptrCast(@alignCast(ctx.?));
}

fn bridge(r: *Request) ?*Stream {
    return @ptrCast(@alignCast(r.app orelse return null));
}

fn reject(r: *Request, code: u64) void {
    r.reset(code);
    r.release();
}

fn onRequest(ctx: ?*anyopaque, r: *Request) void {
    const s = server(ctx);
    const st = newStream(s) orelse return reject(r, zh3.Error.internal);
    st.req = r;
    r.app = st;
    if (!convert(st, r)) {
        st.req = null;
        recycle(st);
        return reject(r, zh3.Error.message);
    }
    const c = r.conn();
    const p = multiplex.openStreamAddr(s.worker, s.listener.listen, st, toNet(c.peer), toNet(c.local), 3);
    const cn: *Conn = @ptrCast(@alignCast(p orelse {
        st.req = null;
        recycle(st);
        return reject(r, zh3.Error.request_rejected);
    }));
    st.cn = cn;
    multiplex.driveRequestConn(cn);
}

fn onReadable(_: ?*anyopaque, r: *Request) void {
    const st = bridge(r) orelse return;
    if (st.cn) |cn| multiplex.driveRequestConn(cn);
}

fn onWritable(_: ?*anyopaque, r: *Request) void {
    const st = bridge(r) orelse return;
    if (st.cn) |cn| multiplex.driveRequestConn(cn);
}

fn onAborted(_: ?*anyopaque, r: *Request, _: u64) void {
    const st = bridge(r) orelse {
        r.release();
        return;
    };
    // Conn.close → finishStream releases the request.
    if (st.cn) |cn| cn.close() else finish(st);
}

// ---------------------------------------------------------------- request head

fn eqlAny(name: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |x| if (name.len == x.len and std.mem.eql(u8, name, x)) return true;
    return false;
}

const V16 = @Vector(16, u8);

/// No NUL, CR or LF: a value copied into the HTTP/1.1 text cannot split a line.
fn safeValue(v: []const u8) bool {
    var i: usize = 0;
    while (i + 16 <= v.len) : (i += 16) {
        const x: V16 = v[i..][0..16].*;
        const bad = (x == @as(V16, @splat(0))) | (x == @as(V16, @splat('\r'))) | (x == @as(V16, @splat('\n')));
        if (@reduce(.Or, bad)) return false;
    }
    for (v[i..]) |ch| if (ch == 0 or ch == '\r' or ch == '\n') return false;
    return true;
}

/// No control characters, space or DEL in the request target.
fn safePath(v: []const u8) bool {
    var i: usize = 0;
    while (i + 16 <= v.len) : (i += 16) {
        const x: V16 = v[i..][0..16].*;
        const bad = (x <= @as(V16, @splat(32))) | (x == @as(V16, @splat(127)));
        if (@reduce(.Or, bad)) return false;
    }
    for (v[i..]) |ch| if (ch <= 32 or ch == 127) return false;
    return true;
}

/// Converts the decoded request into HTTP/1.1 text. False: malformed.
fn convert(st: *Stream, r: *Request) bool {
    const a = st.server.alloc;
    if (r.method.len == 0 or r.method.len >= 32 or r.path.len == 0 or r.path.len > 8192) return false;
    if (!std.mem.eql(u8, r.scheme, "https")) return false;
    if (!safeValue(r.method) or !safeValue(r.authority)) return false;
    if (!safePath(r.path)) return false;
    var authority = r.authority;
    var content_length: ?[]const u8 = null;
    var size: usize = r.method.len + r.path.len + authority.len + 64;
    const fields = r.headers();
    if (fields.len + 4 > max_fields) return false;
    for (fields) |f| {
        if (!safeValue(f.value)) return false;
        if (eqlAny(f.name, &.{ "connection", "transfer-encoding", "upgrade", "keep-alive", "proxy-connection" })) return false;
        if (eqlAny(f.name, &.{"host"})) {
            if (authority.len == 0) {
                authority = f.value;
            } else if (!std.mem.eql(u8, authority, f.value)) return false;
        } else if (eqlAny(f.name, &.{"te"})) {
            if (!std.mem.eql(u8, f.value, "trailers")) return false;
        } else if (eqlAny(f.name, &.{"content-length"})) {
            if (content_length != null or f.value.len == 0 or f.value.len >= 20) return false;
            for (f.value) |ch| if (ch < '0' or ch > '9') return false;
            content_length = f.value;
        }
        size += f.name.len + f.value.len + 4;
    }
    if (authority.len == 0 or authority.len >= 1024) return false;
    if (size > head_cap) return false;
    const ended = r.ended();
    st.chunked = content_length == null and !ended;
    if (content_length) |cl| st.body_left = std.fmt.parseInt(u64, cl, 10) catch return false;
    st.body_end = content_length == null and ended;

    st.input.ensureTotalCapacity(a, size + 64) catch return false;
    const out = &st.input;
    out.appendSliceAssumeCapacity(r.method);
    out.appendAssumeCapacity(' ');
    out.appendSliceAssumeCapacity(r.path);
    out.appendSliceAssumeCapacity(" HTTP/1.1\r\nHost: ");
    out.appendSliceAssumeCapacity(authority);
    out.appendSliceAssumeCapacity("\r\nConnection: close\r\n");
    if (st.chunked) out.appendSliceAssumeCapacity("Transfer-Encoding: chunked\r\n");
    if (content_length) |cl| {
        out.appendSliceAssumeCapacity("Content-Length: ");
        out.appendSliceAssumeCapacity(cl);
        out.appendSliceAssumeCapacity("\r\n");
    }
    for (fields) |f| {
        if (eqlAny(f.name, &.{ "host", "te", "content-length", "expect" })) continue;
        out.appendSliceAssumeCapacity(f.name);
        out.appendSliceAssumeCapacity(": ");
        out.appendSliceAssumeCapacity(f.value);
        out.appendSliceAssumeCapacity("\r\n");
    }
    out.appendSliceAssumeCapacity("\r\n");
    return true;
}

// ---------------------------------------------------------------- engine I/O

pub fn read(st: *Stream, buf: []u8) net.Io {
    const r = st.req orelse return .{ .err = 0 };
    if (st.input_pos < st.input.items.len) {
        const n = @min(buf.len, st.input.items.len - st.input_pos);
        @memcpy(buf[0..n], st.input.items[st.input_pos..][0..n]);
        st.input_pos += n;
        if (st.input_pos == st.input.items.len) {
            st.input.clearRetainingCapacity();
            st.input_pos = 0;
        }
        return .{ .ok = n };
    }
    if (st.body_end) return .eof;
    if (st.chunked) return readChunk(st, r, buf);
    const n = r.read(buf);
    if (st.body_left) |*left| {
        if (n > left.*) return malformed(st, r);
        left.* -= n;
    }
    if (n > 0) return .{ .ok = n };
    if (r.ended()) {
        if (st.body_left != null and st.body_left.? != 0) return malformed(st, r);
        st.body_end = true;
        return .eof;
    }
    return .again;
}

fn malformed(st: *Stream, r: *Request) net.Io {
    r.reset(zh3.Error.message);
    st.body_end = true;
    return .{ .err = 0 };
}

/// Frames request DATA as HTTP/1.1 chunks directly in the engine buffer.
fn readChunk(st: *Stream, r: *Request, buf: []u8) net.Io {
    if (buf.len < 32) {
        // Tiny engine buffer: stage through the input buffer.
        var tmp: [4096]u8 = undefined;
        const res = readChunk(st, r, &tmp);
        switch (res) {
            .ok => |n| {
                st.input.appendSlice(st.server.alloc, tmp[0..n]) catch return .{ .err = 0 };
                return read(st, buf);
            },
            else => return res,
        }
    }
    const n = r.read(buf[10 .. buf.len - 2]);
    if (n == 0) {
        if (!r.ended()) return .again;
        st.body_end = true;
        @memcpy(buf[0..5], "0\r\n\r\n");
        return .{ .ok = 5 };
    }
    var hdr: [10]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "{x}\r\n", .{n}) catch unreachable;
    std.mem.copyForwards(u8, buf[h.len..][0..n], buf[10..][0..n]);
    @memcpy(buf[0..h.len], h);
    @memcpy(buf[h.len + n ..][0..2], "\r\n");
    return .{ .ok = h.len + n + 2 };
}

pub fn write(st: *Stream, data: []const u8) net.Io {
    const r = st.req orelse return .{ .err = 0 };
    if (!st.submitted) return writeHead(st, r, data);
    const n = r.writeData(data) catch return .{ .err = 0 };
    return if (n == 0) .again else .{ .ok = n };
}

/// Collects the HTTP/1.x response head; consumes bytes up to its end only.
fn writeHead(st: *Stream, r: *Request, data: []const u8) net.Io {
    const a = st.server.alloc;
    const old = st.head.items.len;
    const take = @min(data.len, response_head_cap - old);
    if (take == 0) return .{ .err = 0 };
    st.head.appendSlice(a, data[0..take]) catch return .{ .err = 0 };
    const end = headEnd(st.head.items, old -| 3) orelse return .{ .ok = take };
    st.head.shrinkRetainingCapacity(end);
    const accepted = end - old;
    switch (submit(st, r)) {
        .sent => {
            st.submitted = true;
            st.head.clearRetainingCapacity();
        },
        .informational => st.head.clearRetainingCapacity(),
        .blocked => {
            st.head.shrinkRetainingCapacity(old);
            return .again;
        },
        .invalid => return .{ .err = 0 },
    }
    return .{ .ok = accepted };
}

/// Offset just past the first "\r\n\r\n" at or after `from`.
fn headEnd(h: []const u8, from: usize) ?usize {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, h, i, '\n')) |j| {
        if (j >= 3 and h[j - 1] == '\r' and h[j - 2] == '\n' and h[j - 3] == '\r' and j - 3 >= from) return j + 1;
        i = j + 1;
    }
    return null;
}

/// ASCII-lowercases `h[at..][0..len]`, 16 bytes at a time; whole vectors
/// may cover bytes past the name (written back unchanged).
fn lower(h: []u8, at: usize, len: usize) void {
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

fn hopHeader(name: []const u8) bool {
    return eqlAny(name, &.{ "connection", "keep-alive", "transfer-encoding", "upgrade", "proxy-connection", "trailer" });
}

fn submit(st: *Stream, r: *Request) enum { sent, informational, blocked, invalid } {
    const h = st.head.items;
    if (h.len < 16 or !std.mem.startsWith(u8, h, "HTTP/1.")) return .invalid;
    const status = std.fmt.parseInt(u16, h[9..12], 10) catch return .invalid;
    if (status < 100 or status > 999) return .invalid;
    if (status < 200) return .informational;
    var fields: [100]zh3.Field = undefined;
    var count: usize = 0;
    var pos = (std.mem.indexOfScalar(u8, h, '\n') orelse return .invalid) + 1;
    while (pos + 2 < h.len) {
        const nl = std.mem.indexOfScalarPos(u8, h, pos, '\n') orelse return .invalid;
        if (nl == pos or h[nl - 1] != '\r') return .invalid;
        const line = h[pos .. nl - 1];
        pos = nl + 1;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return .invalid;
        const name = line[0..colon];
        lower(h, nl - 1 - line.len, colon);
        var v = colon + 1;
        while (v < line.len and (line[v] == ' ' or line[v] == '\t')) v += 1;
        if (hopHeader(name)) continue;
        if (count == fields.len) return .invalid;
        fields[count] = .{ .name = name, .value = line[v..] };
        count += 1;
    }
    r.sendHeaders(status, fields[0..count], false) catch |e| return switch (e) {
        error.WouldBlock => .blocked,
        else => .invalid,
    };
    return .sent;
}

pub fn sendFile(st: *Stream, fd: c_int, offset: u64, remaining: u64) net.Io {
    const r = st.req orelse return .{ .err = 0 };
    if (!st.submitted) return .{ .err = 0 };
    const want: usize = @intCast(@min(remaining, 64 * 1024));
    const buf = r.reserveData(want) catch return .{ .err = 0 };
    if (buf.len == 0) return .again;
    while (true) {
        const n = pread(fd, buf.ptr, buf.len, @intCast(offset));
        if (n < 0 and os.errnoNow() == .INTR) continue;
        if (n <= 0) {
            r.commitData(0);
            return .{ .err = 0 };
        }
        const k: usize = @intCast(n);
        r.commitData(k);
        return .{ .ok = k };
    }
}

pub fn finishStream(st: *Stream) void {
    finish(st);
}
