//! One client connection: an explicit state machine driven by readiness events.
//!
//! Request buffers are borrowed from a bounded worker pool while a request is
//! active. Idle keep-alive and TLS/codec connections retain only transport state.
const std = @import("std");
const c = std.c;
const config = @import("../http/config.zig");
const Addr = @import("../http/addr.zig").Addr;
const request = @import("../http/request.zig");
const Request = request.Request;
const net = @import("net.zig");
const tls = @import("tls.zig");
const multiplex = @import("multiplex.zig");
const vars = @import("vars.zig");
const handler = @import("handler.zig");
const proxy = @import("proxy.zig");
const Worker = @import("worker.zig").Worker;
const router = @import("router.zig");
const Regex = @import("../regex.zig").Regex;

pub const rbuf_size = 16 * 1024;
pub const wbuf_size = 16 * 1024;
pub const arena_size = 16 * 1024;
pub const path_size = 8 * 1024;

pub const Kind = enum(u8) { listener, client, upstream };
pub const Tag = struct { kind: Kind };

pub const State = enum { handshake, multiplexed, websocket, read_head, read_body, sending, proxy, lingering, closed };
pub const BodyMode = enum { none, length, chunked };
pub const AfterBody = enum { respond, proxy };

pub const Flush = enum { done, again, err };

/// Reusable request storage. Pointers into it remain valid through logging,
/// proxy teardown and the last output write, but never across an idle request.
pub const RequestData = struct {
    next: ?*RequestData = null,
    req: Request = undefined,
    ctx: vars.Ctx = undefined,
    up: proxy.Upstream = undefined,
    rbuf: [rbuf_size]u8 = undefined,
    wbuf: [wbuf_size]u8 = undefined,
    path_buf: [path_size]u8 = undefined,
    arena_mem: [arena_size]u8 = undefined,

    pub fn init(data: *RequestData) void {
        // Do not copy undefined buffers: that would commit every mapped page.
        data.req.reset();
        data.up.fd = -1;
        data.up.phase = .idle;
        data.up.request_owned = null;
    }
};

pub const Conn = struct {
    tag: Tag align(8) = .{ .kind = .client },
    up_tag: Tag align(8) = .{ .kind = .upstream },
    w: *Worker = undefined,
    fd: c_int align(8) = -1,
    ssl: ?*tls.SSL = null,
    multiplex: ?*anyopaque = null,
    transport_stream: ?*anyopaque = null,
    stream_protocol: u8 = 0,
    websocket: ?*@import("websocket").Session = null,
    tls_read: tls.ReadState align(8) = .{},
    listen: *const config.Listen = undefined,
    local: Addr align(8) = .{},
    peer: Addr align(8) = .{},
    id: u64 = 0,
    // Keep hot scalar fields with the pointers, ahead of byte-aligned buffers
    // in Zig's automatic struct layout. Otherwise state lands on the last page.
    state: State align(8) = .read_head,
    prev: ?*Conn = null,
    next: ?*Conn = null,
    grave_next: ?*Conn = null,
    posted: bool align(8) = false,
    posted_prev: ?*Conn = null,
    posted_next: ?*Conn = null,
    deadline: i64 = 0,
    requests: u32 align(8) = 0,

    data: ?*RequestData = null,

    // input
    rbuf: []u8 = undefined,
    rlen: usize = 0,
    scan: usize = 0,

    // request body
    body_mode: BodyMode align(8) = .none,
    body_left: u64 = 0,
    chunk: request.ChunkedDecoder = .{},
    body_store: bool align(8) = false,
    body_limit: u64 = 0,
    body_pos: usize = 0,
    body: std.ArrayList(u8) = .empty,
    after_body: AfterBody align(8) = .respond,

    // output
    wbuf: []u8 = undefined,
    segs: [4][]const u8 = undefined,
    nsegs: u8 align(8) = 0,
    seg_i: u8 align(8) = 0,
    file_fd: c_int align(8) = -1,
    /// file_fd belongs to the worker's open file cache: never close it here
    file_borrowed: bool align(8) = false,
    file_off: u64 = 0,
    file_end: u64 = 0,
    file_sendfile: bool align(8) = false,
    close_after: bool align(8) = false,
    keep_alive: bool align(8) = false,
    drop: bool align(8) = false, // `return 444`

    // request
    req: *Request = undefined,
    path_buf: []u8 = undefined,
    arena_mem: []u8 = undefined,
    fba: std.heap.FixedBufferAllocator = undefined,
    ctx: *vars.Ctx = undefined,
    in_request: bool align(8) = false,
    start_ms: i64 = 0,
    up: *proxy.Upstream = undefined,
    head_len: usize = 0, // response head length in wbuf

    fn acquireData(conn: *Conn) bool {
        if (conn.data != null) return true;
        const data = conn.w.acquireRequestData() orelse return false;
        data.init();
        conn.data = data;
        conn.req = &data.req;
        conn.ctx = &data.ctx;
        conn.up = &data.up;
        conn.rbuf = &data.rbuf;
        conn.wbuf = &data.wbuf;
        conn.path_buf = &data.path_buf;
        conn.arena_mem = &data.arena_mem;
        return true;
    }

    fn releaseData(conn: *Conn) void {
        if (conn.data) |data| {
            conn.w.releaseRequestData(data);
            conn.data = null;
        }
        conn.body.clearAndFree(conn.w.gpa);
    }

    pub fn headSlice(conn: *Conn) []const u8 {
        return conn.wbuf[0..conn.head_len];
    }

    pub fn arena(conn: *Conn) std.mem.Allocator {
        return conn.fba.allocator();
    }

    /// Reset per-connection state after accept (the struct is pooled).
    pub fn init(conn: *Conn, w: *Worker, fd: c_int, peer: Addr, listen: *const config.Listen) void {
        conn.w = w;
        conn.fd = fd;
        conn.peer = peer;
        conn.listen = listen;
        conn.local = if (fd >= 0 and listen.addr.isWildcard()) net.localAddr(fd) else listen.addr;
        conn.ssl = null;
        conn.multiplex = null;
        conn.transport_stream = null;
        conn.stream_protocol = 0;
        conn.websocket = null;
        conn.tls_read = .{};
        conn.state = .read_head;
        conn.requests = 0;
        conn.rlen = 0;
        conn.scan = 0;
        conn.nsegs = 0;
        conn.seg_i = 0;
        conn.file_fd = -1;
        conn.in_request = false;
        conn.body.clearRetainingCapacity();
        conn.start_ms = 0;
        conn.deadline = w.now_ms + defaultServer(conn).client_header_timeout_ms;
    }

    pub fn defaultServer(conn: *Conn) *config.Server {
        return conn.listen.defaultFor(conn.local);
    }

    // ------------------------------------------------------------- raw I/O (TLS aware)

    pub fn recv(conn: *Conn, buf: []u8) net.Io {
        if (multiplex.enabled) if (conn.transport_stream) |stream| return multiplex.readStream(stream, buf);
        if (tls.enabled and tls.track_read_ready) if (conn.ssl) |ssl| {
            if (!conn.tls_read.ready and !conn.tls_read.eof and !conn.tls_read.want_write and !tls.hasPending(ssl)) return .again;
        };
        if (tls.enabled) if (conn.ssl) |ssl| {
            const r = tls.read(ssl, buf);
            // SSL_read may need to write protocol traffic (e.g. KeyUpdate).
            // Preserve its retry even when the encrypted input was drained.
            conn.tls_read.want_write = r == .want_write;
            return switch (r) {
                .ok => |n| .{ .ok = n },
                .want_read, .want_write => .again,
                .eof => .eof,
                .err => .{ .err = 0 },
            };
        };
        return net.read(conn.fd, buf);
    }

    pub fn sendRaw(conn: *Conn, buf: []const u8) net.Io {
        if (multiplex.enabled) if (conn.transport_stream) |stream| return multiplex.writeStream(stream, buf);
        if (tls.enabled) if (conn.ssl) |ssl| return switch (tls.write(ssl, buf)) {
            .ok => |n| .{ .ok = n },
            .want_read, .want_write => .again,
            .eof => .eof,
            .err => .{ .err = 0 },
        };
        return net.write(conn.fd, buf);
    }

    // ------------------------------------------------------------- output

    pub fn setOutput(conn: *Conn, segs: []const []const u8) void {
        conn.nsegs = 0;
        conn.seg_i = 0;
        for (segs) |s| {
            if (s.len == 0) continue;
            conn.segs[conn.nsegs] = s;
            conn.nsegs += 1;
        }
    }

    pub fn outputPending(conn: *const Conn) bool {
        return conn.seg_i < conn.nsegs or conn.file_off < conn.file_end;
    }

    /// Write queued segments, then the file range. Partial progress is kept.
    pub fn flush(conn: *Conn) Flush {
        while (true) {
            while (conn.seg_i < conn.nsegs) {
                const r = blk: {
                    if (conn.ssl == null and conn.transport_stream == null and conn.nsegs - conn.seg_i > 1) {
                        var iov: [4]c.iovec_const = undefined;
                        var n: usize = 0;
                        for (conn.segs[conn.seg_i..conn.nsegs]) |s| {
                            iov[n] = .{ .base = s.ptr, .len = s.len };
                            n += 1;
                        }
                        break :blk net.writev(conn.fd, iov[0..n]);
                    }
                    break :blk conn.sendRaw(conn.segs[conn.seg_i]);
                };
                switch (r) {
                    .ok => |n0| {
                        var n = n0;
                        conn.ctx.bytes_sent += n;
                        while (n > 0 and conn.seg_i < conn.nsegs) {
                            const s = conn.segs[conn.seg_i];
                            if (n >= s.len) {
                                n -= s.len;
                                conn.seg_i += 1;
                            } else {
                                conn.segs[conn.seg_i] = s[n..];
                                n = 0;
                            }
                        }
                        conn.deadline = conn.w.now_ms + conn.ctx.conf.send_timeout_ms;
                    },
                    .again => return .again,
                    .eof, .err => return .err,
                }
            }
            if (conn.file_off >= conn.file_end) return .done;
            if (multiplex.enabled) if (conn.transport_stream) |stream| {
                // Read into the codec's bounded output buffer directly, avoiding
                // a second userspace copy through the HTTP/1 write buffer.
                switch (multiplex.sendFile(stream, conn.file_fd, conn.file_off, conn.file_end - conn.file_off)) {
                    .ok => |n| {
                        conn.file_off += n;
                        conn.ctx.bytes_sent += n;
                        conn.deadline = conn.w.now_ms + conn.ctx.conf.send_timeout_ms;
                    },
                    .again => return .again,
                    .eof, .err => return .err,
                }
                continue;
            };
            if (conn.file_sendfile and conn.ssl == null and conn.transport_stream == null) {
                const r = net.sendFile(conn.fd, conn.file_fd, conn.file_off, conn.file_end - conn.file_off);
                switch (r) {
                    .ok => |n| {
                        conn.file_off += n;
                        conn.ctx.bytes_sent += n;
                        conn.deadline = conn.w.now_ms + conn.ctx.conf.send_timeout_ms;
                    },
                    .again => return .again,
                    .eof, .err => return .err,
                }
            } else {
                const want: usize = @intCast(@min(conn.wbuf.len, conn.file_end - conn.file_off));
                const n = net.pread(conn.file_fd, conn.wbuf[0..want], conn.file_off);
                if (n <= 0) return .err; // file truncated under us
                const got: usize = @intCast(n);
                conn.file_off += got;
                conn.setOutput(&.{conn.wbuf[0..got]});
            }
        }
    }

    // ------------------------------------------------------------- state machine

    pub fn drive(conn: *Conn) void {
        if (conn.posted) return;
        while (true) {
            const progressed = switch (conn.state) {
                .handshake => conn.doHandshake(),
                .multiplexed => blk: {
                    multiplex.driveH2(conn);
                    break :blk false;
                },
                .websocket => blk: {
                    @import("websocket.zig").drive(conn);
                    break :blk false;
                },
                .read_head => conn.readHead(),
                .read_body => conn.readBody(),
                .sending => conn.doSend(),
                .proxy => proxy.drive(conn),
                .lingering => conn.doLinger(),
                .closed => false,
            };
            if (!progressed) return;
            // Give other ready connections a turn after each response. The
            // continuation must run even without another edge from the OS:
            // pipelined bytes may already be in rbuf or inside OpenSSL.
            if (conn.state == .read_head and !conn.in_request and conn.requests > 0) {
                if (tls.enabled and tls.track_read_ready) if (conn.ssl) |ssl| {
                    if (conn.rlen == 0 and !conn.tls_read.ready and !conn.tls_read.eof and !tls.hasPending(ssl)) return;
                };
                conn.w.post(conn);
                return;
            }
        }
    }

    fn doHandshake(conn: *Conn) bool {
        if (!tls.enabled) unreachable;
        switch (tls.handshake(conn.ssl.?)) {
            .ok => {
                if (multiplex.enabled and tls.isH2(conn.ssl.?)) {
                    if (!multiplex.startH2(conn)) {
                        conn.close();
                        return false;
                    }
                    conn.state = .multiplexed;
                    conn.deadline = 0; // per-stream request deadlines remain active
                } else conn.state = .read_head;
                return true;
            },
            .want_read, .want_write => return false,
            else => {
                conn.close();
                return false;
            },
        }
    }

    fn readHead(conn: *Conn) bool {
        if (!conn.acquireData()) {
            conn.close();
            return false;
        }
        const srv0 = conn.defaultServer();
        const limits: request.Limits = .{ .max_head = rbuf_size - 1024, .max_uri = path_size };
        while (true) {
            if (conn.rlen > 0) {
                const st = request.parseHead(conn.rbuf[0..conn.rlen], conn.scan, conn.req, conn.path_buf, limits, srv0.merge_slashes) catch |e| {
                    conn.badRequest(request.errorStatus(e));
                    return true;
                };
                if (st == .complete) {
                    if (conn.stream_protocol != 0) {
                        // Internal wire framing is HTTP/1.1 for request bodies,
                        // HTTP/1.0 for close-delimited responses. User variables
                        // retain the actual client protocol separately.
                        conn.req.version = .http10;
                        conn.req.keep_alive = false;
                    }
                    conn.startRequest();
                    return true;
                }
                conn.scan = conn.rlen;
            }
            switch (conn.recv(conn.rbuf[conn.rlen..])) {
                .ok => |n| {
                    if (conn.rlen == 0) {
                        conn.start_ms = conn.w.now_ms;
                        if (conn.requests > 0) conn.deadline = conn.w.now_ms + srv0.client_header_timeout_ms;
                    }
                    conn.rlen += n;
                },
                .again => {
                    if (conn.rlen == 0) conn.releaseData();
                    return false;
                },
                .eof, .err => {
                    conn.close();
                    return false;
                },
            }
        }
    }

    /// Answer a malformed request (400/414/501/505) and close, like nginx.
    fn badRequest(conn: *Conn, status: u16) void {
        conn.req.reset();
        conn.req.version = .http10;
        conn.req.keep_alive = false;
        conn.req.line = std.mem.sliceTo(conn.rbuf[0..@min(conn.rlen, 1024)], '\r');
        conn.beginRequest(conn.defaultServer());
        conn.close_after = true;
        conn.body_mode = .none;
        handler.finalize(conn, status);
        conn.afterHandler();
    }

    fn beginRequest(conn: *Conn, srv: *config.Server) void {
        conn.requests += 1;
        conn.in_request = true;
        if (conn.start_ms == 0) conn.start_ms = conn.w.now_ms;
        conn.fba = .init(conn.arena_mem);
        conn.close_after = false;
        conn.drop = false;
        conn.nsegs = 0;
        conn.seg_i = 0;
        conn.file_fd = -1;
        conn.file_off = 0;
        conn.file_end = 0;
        conn.after_body = .respond;
        conn.body_store = false;
        conn.body.clearRetainingCapacity();
        conn.body_pos = conn.req.head_len;
        conn.ctx.* = .{
            .srv = srv,
            .conf = srv.conf,
            .cfg = conn.w.cfg,
            .req = conn.req,
            .uri = conn.req.path,
            .args = conn.req.args,
            .scheme_https = conn.ssl != null or conn.stream_protocol != 0,
            .stream_protocol = conn.stream_protocol,
            .local = conn.local,
            .peer = conn.peer,
            .conn_id = conn.id,
            .conn_requests = conn.requests,
            .request_length = conn.req.head_len,
            .start_ms = conn.start_ms,
            .gmtoff = conn.w.gmtoff,
        };
    }

    fn startRequest(conn: *Conn) void {
        var caps: Regex.Captures = .{};
        var hb: [256]u8 = undefined;
        const srv = router.selectServer(conn.listen, conn.local, conn.req.host, &caps, &hb);
        conn.beginRequest(srv);
        if (caps.n > 0) {
            if (conn.req.host) |h| {
                // remember which server_name regex matched, for named captures
                const host = router.normalizeHost(h, &hb) orelse "";
                for (srv.names) |n| if (n == .re and n.re.isMatch(host)) {
                    conn.ctx.host_re = n.re;
                    conn.ctx.host_subject = conn.arena().dupe(u8, host) catch "";
                    _ = n.re.search(conn.ctx.host_subject, &conn.ctx.host_caps) catch {};
                    break;
                };
            }
        }
        conn.body_mode = if (conn.req.chunked) .chunked else if ((conn.req.content_length orelse 0) > 0) .length else .none;
        conn.body_left = conn.req.content_length orelse 0;
        conn.chunk = .{};
        handler.process(conn);
        conn.afterHandler();
    }

    /// The handler queued a response or a proxy action; decide about the body.
    pub fn afterHandler(conn: *Conn) void {
        if (conn.state == .websocket) return;
        if (conn.body_mode != .none and !conn.close_after and !conn.drop) {
            if (conn.req.expect_continue and conn.body_pos == conn.rlen) {
                if (conn.body_store) {
                    _ = conn.sendRaw("HTTP/1.1 100 Continue\r\n\r\n");
                } else {
                    // nginx answers the final status without reading the body
                    conn.close_after = true;
                    conn.keep_alive = false;
                    conn.state = .sending;
                    return;
                }
            }
            conn.state = .read_body;
            conn.deadline = conn.w.now_ms + conn.ctx.conf.client_body_timeout_ms;
            return;
        }
        conn.bodyDone();
    }

    fn bodyDone(conn: *Conn) void {
        conn.ctx.body = conn.body.items;
        if (conn.after_body == .proxy and !conn.close_after) {
            proxy.start(conn);
        } else {
            conn.state = .sending;
        }
    }

    fn readBody(conn: *Conn) bool {
        while (true) {
            if (conn.body_pos < conn.rlen) {
                const avail = conn.rbuf[conn.body_pos..conn.rlen];
                var done = false;
                switch (conn.body_mode) {
                    .length => {
                        const take: usize = @intCast(@min(avail.len, conn.body_left));
                        if (!conn.storeBody(avail[0..take])) return true;
                        conn.body_pos += take;
                        conn.body_left -= take;
                        done = conn.body_left == 0;
                    },
                    .chunked => {
                        const r = conn.chunk.feed(avail) catch {
                            conn.bodyError(400);
                            return true;
                        };
                        if (!conn.storeBody(avail[0..r.produced])) return true;
                        conn.body_pos += r.consumed;
                        done = conn.chunk.isDone();
                    },
                    .none => done = true,
                }
                conn.ctx.request_length = conn.body_pos;
                if (done) {
                    conn.bodyDone();
                    return true;
                }
            }
            if (conn.body_pos == conn.rlen) {
                conn.body_pos = conn.req.head_len;
                conn.rlen = conn.req.head_len;
            }
            if (conn.rlen == conn.rbuf.len) {
                // keep the head, move pending body bytes right after it
                const pending = conn.rlen - conn.body_pos;
                std.mem.copyForwards(u8, conn.rbuf[conn.req.head_len..][0..pending], conn.rbuf[conn.body_pos..conn.rlen]);
                conn.body_pos = conn.req.head_len;
                conn.rlen = conn.body_pos + pending;
            }
            switch (conn.recv(conn.rbuf[conn.rlen..])) {
                .ok => |n| {
                    conn.rlen += n;
                    conn.deadline = conn.w.now_ms + conn.ctx.conf.client_body_timeout_ms;
                },
                .again => return false,
                .eof, .err => {
                    conn.close();
                    return false;
                },
            }
        }
    }

    fn storeBody(conn: *Conn, data: []const u8) bool {
        if (!conn.body_store or data.len == 0) return true;
        if (conn.body_limit != 0 and conn.body.items.len + data.len > conn.body_limit) {
            conn.bodyError(413);
            return false;
        }
        conn.body.appendSlice(conn.w.gpa, data) catch {
            conn.bodyError(500);
            return false;
        };
        return true;
    }

    fn bodyError(conn: *Conn, status: u16) void {
        conn.close_after = true;
        conn.after_body = .respond;
        conn.body_store = false;
        conn.nsegs = 0;
        conn.seg_i = 0;
        conn.closeFile();
        conn.fba = .init(conn.arena_mem);
        conn.ctx.error_page_done = false;
        handler.finalize(conn, status);
        conn.state = .sending;
    }

    fn doSend(conn: *Conn) bool {
        if (conn.drop) {
            conn.finishRequest();
            return conn.state != .closed;
        }
        switch (conn.flush()) {
            .done => {
                conn.finishRequest();
                return conn.state != .closed;
            },
            .again => return false,
            .err => {
                conn.keep_alive = false;
                conn.finishRequest();
                return false;
            },
        }
    }

    pub fn closeFile(conn: *Conn) void {
        if (conn.file_fd >= 0) {
            if (!conn.file_borrowed) net.close(conn.file_fd);
            conn.file_fd = -1;
        }
        conn.file_borrowed = false;
        conn.file_off = 0;
        conn.file_end = 0;
    }

    /// Response fully sent (or aborted): log, then keep-alive or close.
    pub fn finishRequest(conn: *Conn) void {
        conn.ctx.now_ms = conn.w.now_ms;
        conn.ctx.wall_sec = conn.w.wall_sec;
        conn.ctx.wall_usec = conn.w.wall_usec;
        if (!conn.drop or true) conn.w.accessLog(conn);
        conn.closeFile();
        proxy.release(conn);
        conn.in_request = false;
        conn.start_ms = 0;
        if (conn.body.capacity > 256 * 1024) conn.body.clearAndFree(conn.w.gpa);
        if (conn.drop) {
            conn.close();
            return;
        }
        if (!conn.keep_alive or conn.w.stopping) {
            if (conn.close_after and conn.body_mode != .none) {
                conn.startLinger();
                return;
            }
            conn.close();
            return;
        }
        if (tls.enabled and conn.requests == 1) if (conn.ssl) |ssl| {
            tls.trackReads(ssl, &conn.tls_read);
        };
        // pipelined bytes after this request move to the front
        const next = conn.body_pos;
        const rest = conn.rlen - next;
        if (rest > 0) std.mem.copyForwards(u8, conn.rbuf[0..rest], conn.rbuf[next..conn.rlen]);
        conn.rlen = rest;
        conn.scan = 0;
        conn.nsegs = 0;
        conn.seg_i = 0;
        conn.state = .read_head;
        conn.deadline = conn.w.now_ms + if (rest > 0) conn.defaultServer().client_header_timeout_ms else conn.ctx.conf.keepalive_timeout_ms;
        if (rest == 0) conn.releaseData();
        if (rest > 0) conn.start_ms = conn.w.now_ms;
    }

    /// Half-close and drain the client's unread body for a while, so it sees our response
    /// instead of a reset (nginx `lingering_close`).
    fn startLinger(conn: *Conn) void {
        if (conn.transport_stream != null) {
            conn.close();
            return;
        }
        _ = c.shutdown(conn.fd, 1);
        conn.state = .lingering;
        conn.deadline = conn.w.now_ms + 5000;
    }

    fn doLinger(conn: *Conn) bool {
        var buf: [4096]u8 = undefined;
        while (true) switch (net.read(conn.fd, &buf)) {
            .ok => {},
            .again => return false,
            .eof, .err => {
                conn.close();
                return false;
            },
        };
    }

    pub fn onTimeout(conn: *Conn) void {
        switch (conn.state) {
            .proxy => proxy.onTimeout(conn),
            .read_body => {
                // nginx answers 408 without sending it (closes)
                conn.ctx.status = 408;
                conn.keep_alive = false;
                conn.drop = true;
                conn.finishRequest();
            },
            else => {
                if (conn.in_request) {
                    conn.keep_alive = false;
                    conn.w.accessLog(conn);
                }
                conn.close();
            },
        }
    }

    pub fn close(conn: *Conn) void {
        if (conn.state == .closed) return;
        conn.w.unpost(conn);
        conn.closeFile();
        proxy.release(conn);
        multiplex.freeH2(conn);
        if (conn.websocket) |session| {
            session.deinit();
            conn.w.gpa.destroy(session);
            conn.websocket = null;
        }
        if (tls.enabled) if (conn.ssl) |ssl| {
            tls.free(ssl);
            conn.ssl = null;
        };
        if (multiplex.enabled) if (conn.transport_stream) |stream| {
            multiplex.finishStream(stream);
            conn.transport_stream = null;
        };
        if (conn.fd >= 0) net.close(conn.fd);
        conn.fd = -1;
        conn.state = .closed;
        conn.releaseData();
        conn.w.release(conn);
    }
};

test "request storage is detached on idle and initialized again on reuse" {
    const t = std.testing;
    try t.expect(@sizeOf(Conn) <= 1024); // Keep idle connection records small.
    var w: Worker = undefined;
    w.gpa = t.allocator;
    w.request_pool = null;
    w.request_pool_count = 0;
    var first: Conn = .{ .w = &w };
    var second: Conn = .{ .w = &w };
    try t.expect(first.acquireData());
    const storage = first.data.?;
    @memset(first.rbuf, 0xa5);
    first.req.nheaders = 3;
    first.up.fd = 123;
    try first.body.appendSlice(t.allocator, "upload");
    first.releaseData();
    try t.expect(first.data == null);
    try t.expectEqual(@as(usize, 0), first.body.capacity);
    try t.expect(second.acquireData());
    try t.expect(second.data.? == storage);
    try t.expectEqual(@as(usize, 0), second.req.nheaders);
    try t.expectEqual(@as(c_int, -1), second.up.fd);
    try t.expect(second.up.request_owned == null);
    try t.expectEqual(@as(u8, 0xa5), second.rbuf[0]);
    try t.expectEqual(@as(u8, 0xa5), second.rbuf[rbuf_size - 1]);
    second.releaseData();
    std.heap.page_allocator.destroy(w.acquireRequestData().?);
}
