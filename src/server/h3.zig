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
const hd = @import("h3_head.zig");

const zh3 = zquic.h3;
const QAddr = zquic.conn.Addr;
const Request = zh3.Request;

/// Largest HTTP/1.x response head accepted from the engine.
const response_head_cap = hd.response_head_cap;
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
    /// Upper bound of the validated request head not yet handed to the
    /// engine (0: none). It is written straight into the engine's buffer.
    head_bound: usize = 0,
    authority: []const u8 = "",
    content_length: ?[]const u8 = null,
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

/// Validates the decoded request for conversion into HTTP/1.1 text, which
/// `read` writes later. False: malformed.
fn convert(st: *Stream, r: *Request) bool {
    const p = hd.plan(r) orelse return false;
    st.chunked = p.chunked;
    st.body_left = p.body_left;
    st.body_end = p.body_end;
    st.authority = p.authority;
    st.content_length = p.content_length;
    st.head_bound = p.bound;
    return true;
}

/// Writes the HTTP/1.1 request head; `out` holds at least `st.head_bound` bytes.
fn emitHead(st: *Stream, r: *Request, out: []u8) usize {
    const n = hd.emit(r, st.authority, st.chunked, st.content_length, out[0..st.head_bound]);
    st.head_bound = 0;
    return n;
}

// ---------------------------------------------------------------- engine I/O

pub fn read(st: *Stream, buf: []u8) net.Io {
    const r = st.req orelse return .{ .err = 0 };
    if (st.head_bound != 0) {
        if (buf.len >= st.head_bound) return .{ .ok = emitHead(st, r, buf) };
        // Smaller engine buffer: stage the head and hand it over in parts.
        st.input.ensureUnusedCapacity(st.server.alloc, st.head_bound) catch return .{ .err = 0 };
        const n = emitHead(st, r, st.input.unusedCapacitySlice());
        st.input.items.len += n;
    }
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
    // The engine normally writes the whole head at once: submit it from its
    // buffer in one pass. Anything else takes the collecting path below.
    if (st.head.items.len == 0) switch (submitDirect(r, data)) {
        .sent => |end| {
            st.submitted = true;
            return .{ .ok = end };
        },
        .blocked => return .again,
        .invalid => return .{ .err = 0 },
        .fallback => {},
    };
    const a = st.server.alloc;
    const old = st.head.items.len;
    const take = @min(data.len, response_head_cap - old);
    if (take == 0) return .{ .err = 0 };
    if (st.head.capacity - old >= take) {
        st.head.appendSliceAssumeCapacity(data[0..take]);
    } else st.head.appendSlice(a, data[0..take]) catch return .{ .err = 0 };
    const end = hd.headEnd(st.head.items, old -| 3) orelse return .{ .ok = take };
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

const Direct = union(enum) { sent: usize, blocked, invalid, fallback };

/// Submits a complete, well-formed final response head found at the start of
/// `data` without collecting it (see `hd.parseDirect`). `.fallback` sends
/// nothing; the collecting path then applies the same rules as before. A
/// field section the transport rejects is `.invalid`, as on that path.
fn submitDirect(r: *Request, data: []const u8) Direct {
    var fields: [hd.max_response_fields]zh3.Field = undefined;
    var names: [hd.names_cap + 16]u8 = undefined;
    const f = hd.parseDirect(zh3.Field, data, &fields, &names) orelse return .fallback;
    r.sendHeaders(f.status, fields[0..f.count], false) catch |e| return switch (e) {
        error.WouldBlock => .blocked,
        else => .invalid,
    };
    return .{ .sent = f.end };
}

fn submit(st: *Stream, r: *Request) enum { sent, informational, blocked, invalid } {
    var fields: [hd.max_response_fields]zh3.Field = undefined;
    const f = switch (hd.parseCollected(zh3.Field, st.head.items, &fields)) {
        .final => |f| f,
        .informational => return .informational,
        .invalid => return .invalid,
    };
    r.sendHeaders(f.status, fields[0..f.count], false) catch |e| return switch (e) {
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
