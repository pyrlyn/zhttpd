//! HTTP/3 server (RFC 9114) over the zquic transport. QPACK uses only the
//! static table (dynamic capacity 0, no blocked streams). Requests are
//! exposed as decoded field lists plus a body reader; responses are written
//! as HEADERS and DATA frames straight into the stream send buffer.
const std = @import("std");
const conn_mod = @import("conn.zig");
const ep_mod = @import("endpoint.zig");
const qpack = @import("qpack.zig");
const wire = @import("wire.zig");
const tls = @import("tls.zig");

const Conn = conn_mod.Conn;
const Stream = conn_mod.Stream;
pub const Endpoint = ep_mod.Endpoint;
pub const Field = qpack.Field;

pub const Error = struct {
    pub const no_error: u64 = 0x100;
    pub const general_protocol: u64 = 0x101;
    pub const internal: u64 = 0x102;
    pub const stream_creation: u64 = 0x103;
    pub const closed_critical_stream: u64 = 0x104;
    pub const frame_unexpected: u64 = 0x105;
    pub const frame: u64 = 0x106;
    pub const excessive_load: u64 = 0x107;
    pub const id: u64 = 0x108;
    pub const settings: u64 = 0x109;
    pub const missing_settings: u64 = 0x10a;
    pub const request_rejected: u64 = 0x10b;
    pub const request_cancelled: u64 = 0x10c;
    pub const request_incomplete: u64 = 0x10d;
    pub const message: u64 = 0x10e;
};

const frame_data = 0x00;
const frame_headers = 0x01;
const frame_cancel_push = 0x03;
const frame_settings = 0x04;
const frame_push_promise = 0x05;
const frame_goaway = 0x07;
/// Largest client bidirectional stream id: first-phase GOAWAY value.
const max_goaway_id: u64 = (1 << 62) - 4;
const frame_max_push_id = 0x0d;

const setting_qpack_capacity = 0x01;
const setting_max_field_section = 0x06;
const setting_blocked_streams = 0x07;

/// Largest encoded request field section accepted.
pub const max_field_section: usize = 16 * 1024;
/// Largest header list (decoded) the server advertises.
const max_fields = 128;

pub const Handler = struct {
    ctx: ?*anyopaque = null,
    /// Request headers are complete. The application owns `req` until it
    /// calls `req.release()`.
    request: *const fn (?*anyopaque, *Request) void,
    /// Body bytes or the end of the request are available.
    readable: *const fn (?*anyopaque, *Request) void = noopReq,
    /// Send space became available after a short write.
    writable: *const fn (?*anyopaque, *Request) void = noopReq,
    /// The stream was reset/stopped by the peer or the connection closed.
    /// The application must still call `release()`.
    aborted: *const fn (?*anyopaque, *Request, u64) void = noopAbort,
    /// A TLS object was created (SNI/certificate selection hook).
    ssl_created: *const fn (?*anyopaque, *Conn, *tls.SSL) bool = noopSsl,

    fn noopReq(_: ?*anyopaque, _: *Request) void {}
    fn noopAbort(_: ?*anyopaque, _: *Request, _: u64) void {}
    fn noopSsl(_: ?*anyopaque, _: *Conn, _: *tls.SSL) bool {
        return true;
    }
};

const FrameHeader = struct { ty: u64, len: u64, size: usize };

/// Parses a frame header from the readable bytes without consuming them.
/// Returns null when more bytes are needed.
fn peekFrame(s: *const Stream) ?FrameHeader {
    var tmp: [16]u8 = undefined;
    const n = s.peekInto(&tmp);
    var r = wire.Reader{ .buf = tmp[0..n] };
    const ty = r.varint() catch return null;
    const len = r.varint() catch return null;
    return .{ .ty = ty, .len = len, .size = r.pos };
}

fn peekVarint(s: *const Stream) ?struct { v: u64, size: usize } {
    var tmp: [8]u8 = undefined;
    const n = s.peekInto(&tmp);
    var r = wire.Reader{ .buf = tmp[0..n] };
    const v = r.varint() catch return null;
    return .{ .v = v, .size = r.pos };
}

/// Discards up to `n` readable bytes; returns the number discarded.
fn skip(s: *Stream, n: u64) u64 {
    const k = @min(n, s.available());
    s.consume(@intCast(k));
    return k;
}

fn isReservedH2Frame(ty: u64) bool {
    return ty == 0x02 or ty == 0x06 or ty == 0x08 or ty == 0x09;
}

pub const Request = struct {
    session: *Session,
    stream: ?*Stream,
    app: ?*anyopaque = null,
    state: enum { headers, body, trailers, done } = .headers,
    /// Bytes left in the current frame (DATA payload or skipped frame).
    frame_left: u64 = 0,
    frame_ty: u64 = 0,
    in_frame: bool = false,
    released: bool = false,
    aborted: bool = false,
    /// `Handler.request` was called; the application owns the request.
    delivered: bool = false,
    block: std.ArrayList(u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    fields: std.ArrayList(Field) = .empty,
    method: []const u8 = "",
    scheme: []const u8 = "",
    authority: []const u8 = "",
    path: []const u8 = "",
    protocol: []const u8 = "",
    /// Reserved send slice for zero-copy DATA (header space included).
    reserved: []u8 = &.{},
    /// `reserved` points into the server bounce buffer, not the stream ring.
    bounced: bool = false,
    next_free: ?*Request = null,

    pub fn id(r: *const Request) u64 {
        return if (r.stream) |s| s.id else 0;
    }

    pub fn conn(r: *const Request) *Conn {
        return r.session.conn;
    }

    /// Regular (non-pseudo) request fields.
    pub fn headers(r: *const Request) []const Field {
        return r.fields.items;
    }

    // ---- request body ----

    /// Reads request body bytes, skipping frame headers, unknown frames and
    /// trailers. Returns 0 when nothing is available (see `ended`).
    pub fn read(r: *Request, out: []u8) usize {
        const s = r.stream orelse return 0;
        var done: usize = 0;
        while (done < out.len and (r.state == .body or r.state == .trailers)) {
            if (!r.in_frame) {
                if (!r.nextFrame(s)) break;
                continue;
            }
            if (r.frame_ty == frame_data) {
                const want: usize = @intCast(@min(r.frame_left, out.len - done));
                const n = s.read(out[done..][0..want]);
                r.frame_left -= n;
                done += n;
                if (r.frame_left == 0) r.in_frame = false;
                if (n < want) break;
            } else if (r.frame_ty == frame_headers) {
                if (!r.collectTrailers(s)) break;
            } else {
                r.frame_left -= skip(s, r.frame_left);
                if (r.frame_left != 0) break;
                r.in_frame = false;
            }
        }
        r.checkEnd(s);
        return done;
    }

    /// The whole request body (and trailers) has been read.
    pub fn ended(r: *Request) bool {
        if (r.state == .done) return true;
        if (r.stream) |s| r.checkEnd(s);
        return r.state == .done;
    }

    fn checkEnd(r: *Request, s: *Stream) void {
        if (r.state == .done or r.state == .headers) return;
        if (r.in_frame or !s.finReceived() or s.available() != 0) return;
        r.state = .done;
    }

    fn nextFrame(r: *Request, s: *Stream) bool {
        const fh = peekFrame(s) orelse {
            if (s.finReceived() and s.available() > 0) r.session.fail(Error.frame);
            return false;
        };
        if (isReservedH2Frame(fh.ty) or fh.ty == frame_settings or fh.ty == frame_goaway or
            fh.ty == frame_max_push_id or fh.ty == frame_cancel_push or fh.ty == frame_push_promise)
        {
            r.session.fail(Error.frame_unexpected);
            return false;
        }
        if (r.state == .trailers and (fh.ty == frame_data or fh.ty == frame_headers)) {
            r.session.fail(Error.frame_unexpected);
            return false;
        }
        s.consume(fh.size);
        r.frame_ty = fh.ty;
        r.frame_left = fh.len;
        r.in_frame = true;
        if (fh.ty == frame_headers) {
            if (fh.len > max_field_section) {
                r.abort(Error.excessive_load);
                return false;
            }
            r.block.clearRetainingCapacity();
        }
        if (fh.len == 0 and fh.ty != frame_headers) r.in_frame = false;
        return true;
    }

    /// Accumulates a HEADERS payload; true once complete.
    fn collectBlock(r: *Request, s: *Stream) bool {
        const a = r.session.server.alloc;
        while (r.frame_left > 0) {
            const p = s.peek();
            if (p.len == 0) return false;
            const n: usize = @intCast(@min(p.len, r.frame_left));
            r.block.appendSlice(a, p[0..n]) catch {
                r.abort(Error.internal);
                return false;
            };
            s.consume(n);
            r.frame_left -= n;
        }
        r.in_frame = false;
        return true;
    }

    fn collectTrailers(r: *Request, s: *Stream) bool {
        if (!r.collectBlock(s)) return false;
        // Validate the encoding; trailer fields are not forwarded.
        var scratch: [1024]u8 = undefined;
        var d = qpack.Decoder.init(r.block.items, &scratch) catch {
            r.session.fail(qpack.decompression_failed);
            return false;
        };
        while (d.next() catch {
            r.session.fail(qpack.decompression_failed);
            return false;
        }) |_| {}
        r.state = .trailers;
        return true;
    }

    /// Parses the request head; returns true once headers were delivered.
    fn pumpHead(r: *Request) bool {
        const s = r.stream orelse return false;
        while (r.state == .headers) {
            if (!r.in_frame) {
                const fh = peekFrame(s) orelse {
                    if (s.finReceived()) r.abort(Error.request_incomplete);
                    return false;
                };
                if (fh.ty == frame_data) {
                    r.session.fail(Error.frame_unexpected);
                    return false;
                }
                if (!r.nextFrame(s)) return false;
                continue;
            }
            if (r.frame_ty != frame_headers) {
                r.frame_left -= skip(s, r.frame_left);
                if (r.frame_left != 0) return false;
                r.in_frame = false;
                continue;
            }
            if (!r.collectBlock(s)) return false;
            if (!r.decodeHead()) return false;
            r.state = .body;
            return true;
        }
        return false;
    }

    fn decodeHead(r: *Request) bool {
        const a = r.session.server.alloc;
        r.scratch.resize(a, r.block.items.len * 2 + 64) catch {
            r.abort(Error.internal);
            return false;
        };
        var d = qpack.Decoder.init(r.block.items, r.scratch.items) catch {
            r.session.fail(qpack.decompression_failed);
            return false;
        };
        d.cache = &r.session.huff_cache;
        r.fields.clearRetainingCapacity();
        var regular = false;
        while (true) {
            const f = (d.next() catch {
                r.session.fail(qpack.decompression_failed);
                return false;
            }) orelse break;
            if (f.name.len == 0) return r.malformed();
            for (f.name) |ch| if (ch >= 'A' and ch <= 'Z') return r.malformed();
            if (f.name[0] == ':') {
                if (regular) return r.malformed();
                const slot: *[]const u8 = if (std.mem.eql(u8, f.name, ":method"))
                    &r.method
                else if (std.mem.eql(u8, f.name, ":scheme"))
                    &r.scheme
                else if (std.mem.eql(u8, f.name, ":authority"))
                    &r.authority
                else if (std.mem.eql(u8, f.name, ":path"))
                    &r.path
                else if (std.mem.eql(u8, f.name, ":protocol"))
                    &r.protocol
                else
                    return r.malformed();
                if (slot.len != 0) return r.malformed();
                if (f.value.len == 0 and slot != &r.authority) return r.malformed();
                slot.* = f.value;
                continue;
            }
            regular = true;
            if (r.fields.items.len >= max_fields) {
                r.abort(Error.excessive_load);
                return false;
            }
            r.fields.append(a, f) catch {
                r.abort(Error.internal);
                return false;
            };
        }
        if (r.method.len == 0) return r.malformed();
        if (!std.mem.eql(u8, r.method, "CONNECT") and (r.scheme.len == 0 or r.path.len == 0)) return r.malformed();
        return true;
    }

    fn malformed(r: *Request) bool {
        r.abort(Error.message);
        return false;
    }

    /// Stream error: resets both directions and reports the abort.
    fn abort(r: *Request, code: u64) void {
        if (r.stream) |s| {
            s.stopSending(code);
            s.reset(code);
        }
        r.state = .done;
        r.notifyAborted(code);
    }

    fn notifyAborted(r: *Request, code: u64) void {
        if (r.aborted) return;
        r.aborted = true;
        if (!r.delivered) {
            // The application never saw it: release internally.
            if (!r.released) r.release();
            return;
        }
        const h = &r.session.server.handler;
        h.aborted(h.ctx, r, code);
    }

    // ---- response ----

    /// Bytes of DATA payload the stream can accept now.
    pub fn writable(r: *Request) usize {
        const s = r.stream orelse return 0;
        return s.writable() -| 9;
    }

    /// Writes the response HEADERS frame. Returns error.WouldBlock when the
    /// send buffer cannot hold the whole frame.
    pub fn sendHeaders(r: *Request, status: u16, fields: []const Field, end: bool) !void {
        const s = r.stream orelse return error.Closed;
        var stack: [4096]u8 = undefined;
        var heap: []u8 = &.{};
        defer if (heap.len > 0) r.session.server.alloc.free(heap);
        var size: usize = 64;
        for (fields) |f| size += f.name.len + f.value.len + 12;
        // Encode straight into contiguous ring space when there is room, with
        // a 4-byte frame length (varints need not be minimal, RFC 9000 §16).
        if (size + 5 <= s.writable()) direct: {
            const b = try s.reserve(size + 5);
            if (b.len < size + 5 or size >= 1 << 30) break :direct;
            var e = qpack.Encoder.init(b[5..]) catch break :direct;
            e.status(status) catch break :direct;
            for (fields) |f| e.field(f.name, f.value) catch break :direct;
            b[0] = frame_headers;
            wire.putVarintWidth(b[1..], e.pos, 4);
            s.commit(5 + e.pos);
            if (end) s.finish();
            return;
        }
        const buf = if (size + 9 <= stack.len) stack[0..] else blk: {
            heap = try r.session.server.alloc.alloc(u8, size + 9);
            break :blk heap;
        };
        var e = try qpack.Encoder.init(buf[9..]);
        try e.status(status);
        for (fields) |f| try e.field(f.name, f.value);
        const block_len = e.pos;
        const hl = 1 + wire.varintLen(block_len);
        const start = 9 - hl;
        buf[start] = frame_headers;
        _ = wire.putVarint(buf[start + 1 ..], block_len);
        const frame = buf[start .. 9 + block_len];
        if (s.writable() < frame.len) {
            s.want_write = true;
            return error.WouldBlock;
        }
        const n = try s.write(frame);
        std.debug.assert(n == frame.len);
        if (end) s.finish();
    }

    /// Writes one DATA frame with up to `data.len` bytes; returns the payload
    /// bytes accepted (0 when blocked).
    pub fn writeData(r: *Request, data: []const u8) !usize {
        const s = r.stream orelse return error.Closed;
        if (data.len == 0) return 0;
        const room = s.writable();
        if (room < 10) {
            s.want_write = true;
            return 0;
        }
        const n = @min(data.len, room - 9);
        var hdr: [9]u8 = undefined;
        hdr[0] = frame_data;
        const hl = 1 + wire.putVarint(hdr[1..], n);
        _ = try s.write(hdr[0..hl]);
        const w = try s.write(data[0..n]);
        std.debug.assert(w == n);
        return n;
    }

    /// Zero-copy DATA: returns contiguous space for up to `max` payload
    /// bytes (may be shorter, or empty when blocked). Follow with
    /// `commitData`.
    pub fn reserveData(r: *Request, max: usize) ![]u8 {
        const s = r.stream orelse return error.Closed;
        r.reserved = &.{};
        r.bounced = false;
        if (max == 0) return &.{};
        const room = s.writable();
        const min_chunk: usize = @min(max, 64);
        if (room < 5 + min_chunk) {
            s.want_write = true;
            return &.{};
        }
        const want = @min(max, room - 5, (1 << 30) - 1);
        const b = try s.reserve(5 + want);
        if (b.len >= 5 + @min(want, min_chunk)) {
            r.reserved = b;
            return b[5..];
        }
        // The ring wraps within a few bytes. Its data may already be fully
        // acknowledged, so waiting for an ACK could stall forever: fill the
        // server bounce buffer instead and copy it in on commit.
        const bounce = &r.session.server.bounce;
        const k: usize = @min(want, bounce.len - 5);
        r.reserved = bounce[0 .. 5 + k];
        r.bounced = true;
        return r.reserved[5..];
    }

    /// Commits `n` bytes written into the slice from `reserveData`. Call it
    /// before any other request reserves (the bounce buffer is shared).
    pub fn commitData(r: *Request, n: usize) void {
        const s = r.stream orelse return;
        const res = r.reserved;
        const bounced = r.bounced;
        r.reserved = &.{};
        r.bounced = false;
        if (n == 0 or res.len < 5 + n) return;
        res[0] = frame_data;
        wire.putVarintWidth(res[1..], n, 4);
        if (!bounced) return s.commit(5 + n);
        // reserveData checked the room and grew the ring, so this copies all.
        const w = s.write(res[0 .. 5 + n]) catch 0;
        if (w != 5 + n) s.reset(Error.internal);
    }

    /// Ends the response (FIN).
    pub fn finish(r: *Request) void {
        if (r.stream) |s| s.finish();
    }

    /// Abandons the request with `code` (RESET_STREAM + STOP_SENDING).
    pub fn reset(r: *Request, code: u64) void {
        if (r.stream) |s| {
            s.stopSending(code);
            s.reset(code);
        }
        r.state = .done;
    }

    /// The application is finished with the request. Unread request data
    /// is stopped with H3_NO_ERROR; an unfinished response is reset.
    pub fn release(r: *Request) void {
        if (r.released) return;
        r.released = true;
        r.app = null;
        if (r.stream) |s| {
            if (s.hasRecv() and !s.finished() and s.stop_code == null and s.peer_reset == null and s.send.fin)
                s.stopSending(Error.no_error);
            if (!s.send.fin and s.reset_code == null) s.reset(Error.request_cancelled);
            s.app = null;
            s.release();
            r.stream = null;
        }
        r.session.server.freeRequest(r);
    }
};

pub const Session = struct {
    server: *Server,
    conn: *Conn,
    app: ?*anyopaque = null,
    control: ?*Stream = null,
    peer_control: ?*Stream = null,
    peer_encoder: ?*Stream = null,
    peer_decoder: ?*Stream = null,
    settings_received: bool = false,
    /// Lowest request stream id that will be refused (after GOAWAY).
    goaway_id: ?u64 = null,
    /// Highest client bidirectional stream id seen plus 4.
    next_request_id: u64 = 0,
    huff_cache: qpack.HuffCache = .{},
    prev: ?*Session = null,
    next: ?*Session = null,

    fn fail(se: *Session, code: u64) void {
        se.conn.closeApp(code, "");
    }

    fn openControl(se: *Session) void {
        const s = se.conn.openUni() catch {
            se.fail(Error.stream_creation);
            return;
        };
        se.control = s;
        var buf: [32]u8 = undefined;
        var w = wire.Writer{ .buf = &buf };
        w.byte(0x00); // control stream type
        w.byte(frame_settings);
        var body: [16]u8 = undefined;
        var bw = wire.Writer{ .buf = &body };
        bw.varint(setting_qpack_capacity);
        bw.varint(0);
        bw.varint(setting_blocked_streams);
        bw.varint(0);
        bw.varint(setting_max_field_section);
        bw.varint(max_field_section);
        w.varint(bw.pos);
        w.bytes(body[0..bw.pos]);
        _ = s.write(buf[0..w.pos]) catch {
            se.fail(Error.internal);
        };
    }

    /// Graceful shutdown (RFC 9114 §5.2): GOAWAY with the largest stream id
    /// first, so requests already in flight are still accepted; the transport
    /// closes once idle after a grace period, and requests arriving past it are
    /// refused with H3_REQUEST_REJECTED.
    pub fn shutdown(se: *Session) void {
        if (se.goaway_id != null) return;
        se.goaway_id = max_goaway_id;
        if (se.control) |s| {
            var buf: [16]u8 = undefined;
            var w = wire.Writer{ .buf = &buf };
            w.byte(frame_goaway);
            w.varint(wire.varintLen(max_goaway_id));
            w.varint(max_goaway_id);
            _ = s.write(buf[0..w.pos]) catch {};
        }
        se.conn.closeWhenIdle(Error.no_error);
    }

    fn onUni(se: *Session, s: *Stream) void {
        while (true) {
            if (s == se.peer_control) return se.onControl(s);
            if (s == se.peer_encoder or s == se.peer_decoder) {
                // Static-only QPACK: instructions carry nothing we use.
                _ = skip(s, s.available());
                if (s.finReceived()) se.fail(Error.closed_critical_stream);
                return;
            }
            const t = peekVarint(s) orelse {
                if (s.finReceived()) {
                    s.release();
                }
                return;
            };
            s.consume(t.size);
            switch (t.v) {
                0x00 => {
                    if (se.peer_control != null) return se.fail(Error.stream_creation);
                    se.peer_control = s;
                },
                0x02 => {
                    if (se.peer_encoder != null) return se.fail(Error.stream_creation);
                    se.peer_encoder = s;
                },
                0x03 => {
                    if (se.peer_decoder != null) return se.fail(Error.stream_creation);
                    se.peer_decoder = s;
                },
                0x01 => return se.fail(Error.stream_creation), // push from a client
                else => {
                    // Unknown or reserved type: abandon reading.
                    s.stopSending(Error.stream_creation);
                    s.release();
                    return;
                },
            }
        }
    }

    fn onControl(se: *Session, s: *Stream) void {
        while (true) {
            const fh = peekFrame(s) orelse break;
            if (fh.len > 4096) return se.fail(Error.excessive_load);
            if (s.available() < fh.size + fh.len) break;
            var payload: [4096 + 16]u8 = undefined;
            const total: usize = @intCast(fh.size + fh.len);
            _ = s.read(payload[0..total]);
            const body = payload[fh.size..total];
            if (!se.settings_received and fh.ty != frame_settings) return se.fail(Error.missing_settings);
            switch (fh.ty) {
                frame_settings => {
                    if (se.settings_received) return se.fail(Error.frame_unexpected);
                    se.settings_received = true;
                    var r = wire.Reader{ .buf = body };
                    var seen: u8 = 0;
                    while (r.left() > 0) {
                        const k = r.varint() catch return se.fail(Error.frame);
                        _ = r.varint() catch return se.fail(Error.frame);
                        if (k >= 0x02 and k <= 0x05) return se.fail(Error.settings);
                        if (k <= 7) {
                            const bit = @as(u8, 1) << @intCast(k);
                            if (seen & bit != 0) return se.fail(Error.settings);
                            seen |= bit;
                        }
                    }
                },
                frame_goaway => {
                    var r = wire.Reader{ .buf = body };
                    _ = r.varint() catch return se.fail(Error.frame);
                    if (r.left() != 0) return se.fail(Error.frame);
                    // Client shutdown: answer with our own GOAWAY and drain.
                    se.shutdown();
                },
                frame_max_push_id, frame_cancel_push => {
                    var r = wire.Reader{ .buf = body };
                    _ = r.varint() catch return se.fail(Error.frame);
                    if (r.left() != 0) return se.fail(Error.frame);
                },
                frame_data, frame_headers, frame_push_promise => return se.fail(Error.frame_unexpected),
                else => if (isReservedH2Frame(fh.ty)) return se.fail(Error.frame_unexpected),
            }
        }
        if (s.finReceived() and s.available() == 0) se.fail(Error.closed_critical_stream);
    }
};

pub const Server = struct {
    alloc: std.mem.Allocator,
    ep: *Endpoint,
    handler: Handler,
    sessions: ?*Session = null,
    free_reqs: ?*Request = null,
    nfree: usize = 0,
    shutting_down: bool = false,
    /// Staging for `Request.reserveData` when a send ring wraps.
    bounce: [4096]u8 = undefined,

    pub fn init(a: std.mem.Allocator, ssl_ctx: *tls.SSL_CTX, cfg: conn_mod.Config, handler: Handler) !*Server {
        const sv = try a.create(Server);
        errdefer a.destroy(sv);
        sv.* = .{ .alloc = a, .ep = undefined, .handler = handler };
        sv.ep = try Endpoint.init(a, ssl_ctx, cfg, .{
            .ctx = sv,
            .conn_ready = connReady,
            .conn_closed = connClosed,
            .stream_open = streamOpen,
            .stream_readable = streamReadable,
            .stream_writable = streamWritable,
            .stream_reset = streamReset,
            .ssl_created = sslCreated,
        });
        return sv;
    }

    pub fn deinit(sv: *Server) void {
        sv.ep.deinit();
        while (sv.free_reqs) |r| {
            sv.free_reqs = r.next_free;
            sv.destroyRequest(r);
        }
        sv.alloc.destroy(sv);
    }

    /// Graceful shutdown: GOAWAY on every connection, close when idle.
    pub fn shutdown(sv: *Server) void {
        sv.shutting_down = true;
        var it = sv.sessions;
        while (it) |se| {
            it = se.next;
            se.shutdown();
        }
    }

    fn destroyRequest(sv: *Server, r: *Request) void {
        r.block.deinit(sv.alloc);
        r.scratch.deinit(sv.alloc);
        r.fields.deinit(sv.alloc);
        sv.alloc.destroy(r);
    }

    fn newRequest(sv: *Server, se: *Session, s: *Stream) ?*Request {
        if (sv.free_reqs) |r| {
            sv.free_reqs = r.next_free;
            sv.nfree -= 1;
            var block = r.block;
            var scratch = r.scratch;
            var fields = r.fields;
            block.clearRetainingCapacity();
            scratch.clearRetainingCapacity();
            fields.clearRetainingCapacity();
            r.* = .{ .session = se, .stream = s, .block = block, .scratch = scratch, .fields = fields };
            return r;
        }
        const r = sv.alloc.create(Request) catch return null;
        r.* = .{ .session = se, .stream = s };
        return r;
    }

    fn freeRequest(sv: *Server, r: *Request) void {
        if (sv.nfree >= 256 or r.block.capacity > 4096 or r.scratch.capacity > 8192) {
            sv.destroyRequest(r);
            return;
        }
        r.next_free = sv.free_reqs;
        sv.free_reqs = r;
        sv.nfree += 1;
    }

    fn from(ctx: ?*anyopaque) *Server {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn sslCreated(ctx: ?*anyopaque, c: *Conn, ssl: *tls.SSL) bool {
        const sv = from(ctx);
        return sv.handler.ssl_created(sv.handler.ctx, c, ssl);
    }

    fn connReady(ctx: ?*anyopaque, c: *Conn) void {
        const sv = from(ctx);
        const se = sv.alloc.create(Session) catch {
            c.closeApp(Error.internal, "");
            return;
        };
        se.* = .{ .server = sv, .conn = c, .next = sv.sessions };
        if (sv.sessions) |h| h.prev = se;
        sv.sessions = se;
        c.app = se;
        se.openControl();
        if (sv.shutting_down) se.shutdown();
    }

    fn connClosed(ctx: ?*anyopaque, c: *Conn) void {
        const sv = from(ctx);
        const se: *Session = @ptrCast(@alignCast(c.app orelse return));
        c.app = null;
        if (se.prev) |p| p.next = se.next else sv.sessions = se.next;
        if (se.next) |n| n.prev = se.prev;
        sv.alloc.destroy(se);
    }

    fn session(s: *Stream) ?*Session {
        return @ptrCast(@alignCast(s.conn.app orelse return null));
    }

    fn streamOpen(ctx: ?*anyopaque, s: *Stream) void {
        const sv = from(ctx);
        const se = session(s) orelse {
            // Streams before the handshake completed (0-RTT is not offered).
            s.stopSending(Error.request_rejected);
            s.reset(Error.request_rejected);
            s.release();
            return;
        };
        if (s.isUni()) return;
        if (s.id + 4 > se.next_request_id) se.next_request_id = s.id + 4;
        if (se.goaway_id) |g| if (s.id >= g or se.conn.drainGraceOver()) {
            s.stopSending(Error.request_rejected);
            s.reset(Error.request_rejected);
            s.release();
            return;
        };
        const r = sv.newRequest(se, s) orelse {
            s.stopSending(Error.internal);
            s.reset(Error.internal);
            s.release();
            return;
        };
        s.app = r;
    }

    fn streamReadable(ctx: ?*anyopaque, s: *Stream) void {
        const sv = from(ctx);
        const se = session(s) orelse return;
        if (s.isUni()) return se.onUni(s);
        const r: *Request = @ptrCast(@alignCast(s.app orelse return));
        if (r.state == .headers) {
            if (r.pumpHead()) {
                r.delivered = true;
                sv.handler.request(sv.handler.ctx, r);
            }
            return;
        }
        if (r.released or r.aborted) return;
        sv.handler.readable(sv.handler.ctx, r);
    }

    fn streamWritable(ctx: ?*anyopaque, s: *Stream) void {
        const sv = from(ctx);
        if (s.isUni()) return;
        const r: *Request = @ptrCast(@alignCast(s.app orelse return));
        if (r.released or r.aborted or r.state == .headers) return;
        sv.handler.writable(sv.handler.ctx, r);
    }

    fn streamReset(ctx: ?*anyopaque, s: *Stream, code: u64) void {
        _ = ctx;
        if (s.isUni()) {
            const se = session(s) orelse return;
            if (s == se.peer_control or s == se.peer_encoder or s == se.peer_decoder) {
                if (s.conn.state == .open) se.fail(Error.closed_critical_stream);
            }
            return;
        }
        const r: *Request = @ptrCast(@alignCast(s.app orelse return));
        if (s.conn.state != .open) {
            // Connection teardown: the stream object dies with the connection.
            r.stream = null;
            s.app = null;
        }
        r.notifyAborted(code);
    }
};
