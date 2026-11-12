//! One server-side QUIC connection: packet protection, frame processing,
//! loss recovery, flow control, streams, connection IDs, paths and the
//! TLS 1.3 handshake through OpenSSL's QUIC TLS callbacks.
const std = @import("std");
const crypto = @import("crypto.zig");
const wire = @import("wire.zig");
const packet = @import("packet.zig");
const ranges = @import("ranges.zig");
const tp = @import("tp.zig");
const rec = @import("recovery.zig");
const sbuf = @import("stream.zig");
const tls = @import("tls.zig");
const ep_mod = @import("endpoint.zig");
const Endpoint = ep_mod.Endpoint;

pub const Cid = packet.Cid;
pub const cid_len = 8;
pub const max_local_cids = 4;
pub const max_peer_cids = 4;
const crypto_window: u64 = 64 * 1024;
const max_ack_ranges = 32;
const min_packet_room = 24;

pub const Err = enum(u64) {
    no_error = 0x0,
    internal = 0x1,
    connection_refused = 0x2,
    flow_control = 0x3,
    stream_limit = 0x4,
    stream_state = 0x5,
    final_size = 0x6,
    frame_encoding = 0x7,
    transport_parameter = 0x8,
    connection_id_limit = 0x9,
    protocol_violation = 0xa,
    invalid_token = 0xb,
    application = 0xc,
    crypto_buffer_exceeded = 0xd,
    key_update = 0xe,
    aead_limit = 0xf,
    no_viable_path = 0x10,
    _,
};

pub const Addr = struct {
    ip: [16]u8 = @splat(0),
    port: u16 = 0,
    v6: bool = false,
    scope: u32 = 0,

    pub fn eql(a: *const Addr, b: *const Addr) bool {
        return a.port == b.port and a.v6 == b.v6 and std.mem.eql(u8, &a.ip, &b.ip);
    }
    pub fn sameHost(a: *const Addr, b: *const Addr) bool {
        return a.v6 == b.v6 and std.mem.eql(u8, &a.ip, &b.ip);
    }
};

pub const Config = struct {
    idle_timeout_ms: u64 = 60_000,
    max_data: u64 = 8 * 1024 * 1024,
    max_stream_data_bidi: u64 = 64 * 1024,
    max_stream_data_uni: u64 = 64 * 1024,
    max_streams_bidi: u64 = 128,
    max_streams_uni: u64 = 3,
    max_ack_delay_ms: u64 = 25,
    ack_delay_exponent: u6 = 3,
    /// Largest UDP payload this endpoint sends once the path allows it.
    max_datagram: usize = 1452,
    /// Bytes an application may buffer per stream before writes block.
    stream_send_buffer: usize = 64 * 1024,
    disable_migration: bool = false,
    retry: bool = false,
    /// Error code for STOP_SENDING/RESET_STREAM when a stream is released
    /// with unfinished directions (H3_NO_ERROR by default).
    release_error_code: u64 = 0x100,
};

/// Application hooks. Called synchronously from packet processing and
/// timers; the application may call stream/connection functions from them.
pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// Handshake completed; `conn.app` may be set.
    conn_ready: *const fn (?*anyopaque, *Conn) void = noopConn,
    /// Connection is closing/closed; streams are already notified.
    conn_closed: *const fn (?*anyopaque, *Conn) void = noopConn,
    /// A peer-initiated stream appeared.
    stream_open: *const fn (?*anyopaque, *Stream) void = noopStream,
    /// New contiguous data, FIN, or reset is available.
    stream_readable: *const fn (?*anyopaque, *Stream) void = noopStream,
    /// Send buffer space became available after a blocked write.
    stream_writable: *const fn (?*anyopaque, *Stream) void = noopStream,
    /// Peer sent STOP_SENDING (code) or RESET_STREAM, or the connection died.
    stream_reset: *const fn (?*anyopaque, *Stream, u64) void = noopReset,
    /// A new TLS object was created for a connection (SNI/ALPN setup).
    ssl_created: *const fn (?*anyopaque, *Conn, *tls.SSL) bool = noopSsl,

    fn noopSsl(_: ?*anyopaque, _: *Conn, _: *tls.SSL) bool {
        return true;
    }
    fn noopConn(_: ?*anyopaque, _: *Conn) void {}
    fn noopStream(_: ?*anyopaque, _: *Stream) void {}
    fn noopReset(_: ?*anyopaque, _: *Stream, _: u64) void {}
};

pub const Level = enum(u2) { initial = 0, handshake = 1, app = 2 };

pub const Stream = struct {
    id: u64,
    conn: *Conn,
    send: sbuf.SendBuf = .{},
    recv: sbuf.RecvBuf = .{},
    app: ?*anyopaque = null,
    /// Our RESET_STREAM error code.
    reset_code: ?u64 = null,
    reset_final: u64 = 0,
    reset_acked: bool = false,
    /// Our STOP_SENDING error code.
    stop_code: ?u64 = null,
    peer_reset: ?u64 = null,
    peer_stop: ?u64 = null,
    ctrl: packed struct { max_data: bool = false, reset: bool = false, stop: bool = false } = .{},
    queued: bool = false,
    ctrl_queued: bool = false,
    want_write: bool = false,
    /// On the connection's event list (read and/or write notification).
    readable_queued: bool = false,
    ev_read: bool = false,
    ev_write: bool = false,
    released: bool = false,
    freeing: bool = false,
    next: ?*Stream = null,
    ctrl_next: ?*Stream = null,
    ev_next: ?*Stream = null,

    pub inline fn isUni(s: *const Stream) bool {
        return s.id & 2 != 0;
    }
    pub inline fn isLocal(s: *const Stream) bool {
        return s.id & 1 != 0;
    }
    pub inline fn hasSend(s: *const Stream) bool {
        return !s.isUni() or s.isLocal();
    }
    pub inline fn hasRecv(s: *const Stream) bool {
        return !s.isUni() or !s.isLocal();
    }

    fn sendDone(s: *const Stream) bool {
        if (!s.hasSend()) return true;
        if (s.reset_code != null) return s.reset_acked;
        return s.send.allAcked();
    }
    fn recvDone(s: *const Stream) bool {
        if (!s.hasRecv()) return true;
        return s.peer_reset != null or s.stop_code != null or s.recv.finished();
    }

    // ---- application API ----

    /// Contiguous readable bytes (may be a prefix of what is available).
    pub fn peek(s: *const Stream) []const u8 {
        if (s.peer_reset != null or s.stop_code != null) return &.{};
        return s.recv.peek();
    }

    pub fn consume(s: *Stream, n: usize) void {
        if (n == 0) return;
        s.recv.consume(n);
        s.conn.onConsumed(s, n);
    }

    pub fn read(s: *Stream, out: []u8) usize {
        var done: usize = 0;
        while (done < out.len) {
            const p = s.peek();
            if (p.len == 0) break;
            const n = @min(p.len, out.len - done);
            @memcpy(out[done..][0..n], p[0..n]);
            s.consume(n);
            done += n;
        }
        return done;
    }

    /// Contiguous readable bytes, possibly across the ring wrap.
    pub fn available(s: *const Stream) u64 {
        if (s.peer_reset != null or s.stop_code != null) return 0;
        return s.recv.available();
    }

    /// Copies readable bytes without consuming them.
    pub fn peekInto(s: *const Stream, out: []u8) usize {
        if (s.peer_reset != null or s.stop_code != null) return 0;
        return s.recv.peekInto(out);
    }

    /// FIN received and every byte up to it is readable.
    pub fn finReceived(s: *const Stream) bool {
        return s.recv.finKnownAndReceived();
    }

    /// FIN received and all data consumed.
    pub fn finished(s: *const Stream) bool {
        return s.recv.finished();
    }

    /// Bytes that can be written without blocking.
    pub fn writable(s: *Stream) usize {
        if (!s.canWrite()) return 0;
        const n = s.conn.cfg().stream_send_buffer -| @as(usize, @intCast(s.send.buffered()));
        if (n == 0) s.want_write = true;
        return n;
    }

    fn canWrite(s: *const Stream) bool {
        return s.hasSend() and !s.send.fin and s.reset_code == null and s.conn.state == .open;
    }

    pub fn write(s: *Stream, data: []const u8) error{ Closed, OutOfMemory }!usize {
        if (!s.canWrite()) return error.Closed;
        const n = try s.send.write(s.conn.alloc, data, s.conn.cfg().stream_send_buffer);
        if (n < data.len) s.want_write = true;
        if (n > 0) s.conn.queueStream(s);
        return n;
    }

    /// Zero-copy write: returns ring space to fill, then `commit`.
    pub fn reserve(s: *Stream, want: usize) error{ Closed, OutOfMemory }![]u8 {
        if (!s.canWrite()) return error.Closed;
        const b = try s.send.reserve(s.conn.alloc, want, s.conn.cfg().stream_send_buffer);
        if (b.len < want) s.want_write = true;
        return b;
    }
    pub fn commit(s: *Stream, n: usize) void {
        if (n == 0) return;
        s.send.commit(n);
        s.conn.queueStream(s);
    }

    pub fn finish(s: *Stream) void {
        if (!s.canWrite()) return;
        s.send.finish();
        s.conn.queueStream(s);
    }

    /// Abandons the sending side (RESET_STREAM).
    pub fn reset(s: *Stream, code: u64) void {
        if (!s.hasSend() or s.reset_code != null or s.send.allAcked()) return;
        s.reset_code = code;
        s.reset_final = s.send.end;
        s.ctrl.reset = true;
        s.conn.queueCtrl(s);
    }

    /// Abandons the receiving side (STOP_SENDING) and discards data.
    pub fn stopSending(s: *Stream, code: u64) void {
        if (!s.hasRecv() or s.stop_code != null or s.peer_reset != null) return;
        s.stop_code = code;
        const unread = s.recv.highest - s.recv.read;
        s.recv.consume(s.recv.available());
        s.conn.rx_consumed += unread;
        if (!s.recv.finKnownAndReceived()) {
            s.ctrl.stop = true;
            s.conn.queueCtrl(s);
        }
        s.recv.deinit(s.conn.alloc);
        s.conn.maybeWindowUpdate();
    }

    /// The application no longer references the stream. The transport keeps
    /// it until both directions are settled.
    pub fn release(s: *Stream) void {
        s.released = true;
        s.app = null;
        const code = s.conn.cfg().release_error_code;
        if (s.hasRecv() and !s.recvDone()) s.stopSending(code);
        if (s.hasSend() and !s.send.fin and s.reset_code == null) s.reset(code);
        s.conn.maybeFree(s);
    }
};

const Space = struct {
    rx: ?crypto.Keys = null,
    tx: ?crypto.Keys = null,
    next_pn: u64 = 0,
    largest_acked: ?u64 = null,
    sent: rec.SentRing = .{},
    loss_time: u64 = 0,
    last_eliciting_time: u64 = 0,
    eliciting_in_flight: u32 = 0,
    recv_pns: ranges.RangeSet(max_ack_ranges) = .{},
    recv_floor: u64 = 0,
    largest_rx: ?u64 = null,
    largest_rx_time: u64 = 0,
    /// Ack-eliciting packets received since the last ACK was sent.
    ack_unsent: u32 = 0,
    /// A packet arrived since the last ACK frame was sent.
    ack_dirty: bool = false,
    ack_deadline: u64 = 0,
    crypto_tx: sbuf.SendBuf = .{ .max = std.math.maxInt(u64) },
    crypto_rx: sbuf.RecvBuf = .{ .max = crypto_window },
    probes: u8 = 0,
    discarded: bool = false,

    fn deinit(s: *Space, a: std.mem.Allocator) void {
        if (s.rx) |*k| k.deinit();
        if (s.tx) |*k| k.deinit();
        s.rx = null;
        s.tx = null;
        s.sent.deinit(a);
        s.crypto_tx.deinit(a);
        s.crypto_rx.deinit(a);
    }
};

const LocalCid = struct {
    seq: u64 = 0,
    cid: [cid_len]u8 = undefined,
    token: [16]u8 = undefined,
    active: bool = false,
    pending: bool = false,
};

const PeerCid = struct {
    seq: u64 = 0,
    cid: Cid = .{},
    token: ?[16]u8 = null,
    active: bool = false,
    retire_pending: bool = false,
};

pub const State = enum { handshake, open, closing, draining, closed };

pub const CloseInfo = struct { app: bool, code: u64, frame: u64 = 0, reason: []const u8 = "" };

pub const Datagram = struct { len: usize, to: Addr, from: Addr };

const ProcError = error{ Close, Drop, OutOfMemory };

pub const Conn = struct {
    ep: *Endpoint,
    alloc: std.mem.Allocator,
    state: State = .handshake,
    ssl: ?*tls.SSL = null,
    tls_read: u32 = tls.level_none,
    tls_write: u32 = tls.level_none,
    tls_done: bool = false,
    alert: ?u8 = null,
    handshake_done_pending: bool = false,
    discard_handshake_pending: bool = false,
    spaces: [3]Space = .{ .{}, .{}, .{} },
    suite: crypto.Suite = .aes128gcm,
    key_phase: bool = false,
    tx_phase: bool = false,
    rx_prev: ?crypto.Keys = null,
    rx_next: ?crypto.Keys = null,
    phase_start_pn: u64 = 0,
    tx_phase_start_pn: u64 = 0,
    tx_phase_acked: bool = false,
    tx_phase_packets: u64 = 0,
    // connection IDs
    odcid: Cid = .{},
    odcid_registered: bool = false,
    local_cids: [max_local_cids]LocalCid = @splat(.{}),
    local_seq: u64 = 0,
    peer_cids: [max_peer_cids]PeerCid = @splat(.{}),
    peer_cid: usize = 0,
    peer_retire_prior: u64 = 0,
    rx_dcid: [cid_len]u8 = undefined,
    // path
    peer: Addr,
    local: Addr,
    validated: bool = false,
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    challenge: ?[8]u8 = null,
    challenge_pending: bool = false,
    challenge_deadline: u64 = 0,
    prev_peer: ?Addr = null,
    response: ?[8]u8 = null,
    mtu: usize = packet.min_initial_size,
    /// Pending path MTU probe size (DPLPMTUD, RFC 9000 §14.4), 0 when none.
    mtu_probe: u16 = 0,
    mtu_probing: bool = false,
    // recovery
    log: rec.FrameLog = .{},
    rtt: rec.Rtt = .{},
    cc: rec.NewReno = rec.NewReno.init(packet.min_initial_size),
    pto_count: u32 = 0,
    // flow control
    rx_max: u64 = 0,
    rx_highest: u64 = 0,
    rx_consumed: u64 = 0,
    max_data_pending: bool = false,
    tx_max: u64 = 0,
    tx_sent: u64 = 0,
    // streams
    streams: std.AutoHashMapUnmanaged(u64, *Stream) = .{},
    /// Removals since the stream map last dropped its tombstones.
    stream_removals: usize = 0,
    peer_seen: [2]ranges.RangeSet(32) = .{ .{}, .{} },
    max_streams: [2]u64 = .{ 0, 0 },
    max_streams_pending: [2]bool = .{ false, false },
    closed_streams: [2]u64 = .{ 0, 0 },
    peer_max_uni: u64 = 0,
    local_uni_next: u64 = 0,
    send_head: ?*Stream = null,
    send_tail: ?*Stream = null,
    ctrl_head: ?*Stream = null,
    ctrl_tail: ?*Stream = null,
    ev_head: ?*Stream = null,
    ev_tail: ?*Stream = null,
    free_list: ?*Stream = null,
    // lifecycle
    peer_params: tp.Params = .{},
    idle_timeout: u64 = 0,
    idle_deadline: u64 = 0,
    close: ?CloseInfo = null,
    close_reason: [64]u8 = undefined,
    close_pending: bool = false,
    close_deadline: u64 = 0,
    close_rx_count: u32 = 0,
    drain_close: ?u64 = null,
    drain_after: u64 = 0,
    tp_buf: [256]u8 = undefined,
    app: ?*anyopaque = null,
    // endpoint bookkeeping
    deadline: u64 = std.math.maxInt(u64),
    heap_idx: usize = std.math.maxInt(usize),
    dirty: bool = false,
    dirty_next: ?*Conn = null,

    inline fn cfg(c: *const Conn) *const Config {
        return &c.ep.cfg;
    }
    inline fn now(c: *const Conn) u64 {
        return c.ep.now;
    }
    inline fn cb(c: *const Conn) *const Callbacks {
        return &c.ep.callbacks;
    }

    // ------------------------------------------------------------------
    // Creation

    /// Creates a connection for a client Initial. `odcid` is the client's
    /// original destination CID (from a Retry token when Retry was used).
    pub fn create(ep: *Endpoint, hdr: *const packet.Header, odcid: []const u8, retry_scid: ?[]const u8, peer: Addr, local: Addr) !*Conn {
        const a = ep.alloc;
        const c = try a.create(Conn);
        errdefer a.destroy(c);
        c.* = .{ .ep = ep, .alloc = a, .peer = peer, .local = local };
        const conf = &ep.cfg;
        c.odcid = Cid.init(odcid);
        c.peer_cids[0] = .{ .seq = 0, .cid = Cid.init(hdr.scid), .active = true };
        c.rx_max = conf.max_data;
        c.max_streams = .{ conf.max_streams_bidi, conf.max_streams_uni };
        c.idle_timeout = conf.idle_timeout_ms * 1000;
        c.idle_deadline = ep.now + c.idle_timeout;
        if (retry_scid != null) c.validated = true;

        // Initial keys come from the DCID the client used in this Initial.
        var cs: [32]u8 = undefined;
        var ss: [32]u8 = undefined;
        crypto.initialSecrets(hdr.dcid, &cs, &ss);
        c.spaces[0].rx = try crypto.Keys.init(.aes128gcm, &cs, false);
        c.spaces[0].tx = try crypto.Keys.init(.aes128gcm, &ss, true);

        errdefer for (&c.spaces) |*sp| sp.deinit(a);
        try c.issueCid();
        errdefer c.unregisterCids();
        c.rx_dcid = c.local_cids[0].cid;

        const ssl = tls.SSL_new(ep.ssl_ctx) orelse return error.OutOfMemory;
        c.ssl = ssl;
        errdefer {
            tls.SSL_free(ssl);
            c.ssl = null;
        }
        if (tls.SSL_set_quic_tls_cbs(ssl, &dispatch, c) != 1) return error.Tls;
        tls.SSL_set_accept_state(ssl);
        if (!ep.callbacks.ssl_created(ep.callbacks.ctx, c, ssl)) return error.Tls;

        var params = tp.Params{
            .original_dcid = c.odcid,
            .max_idle_timeout_ms = conf.idle_timeout_ms,
            .stateless_reset_token = c.local_cids[0].token,
            .max_udp_payload_size = @max(conf.max_datagram, 1200),
            .initial_max_data = conf.max_data,
            .initial_max_stream_data_bidi_local = 0,
            .initial_max_stream_data_bidi_remote = conf.max_stream_data_bidi,
            .initial_max_stream_data_uni = conf.max_stream_data_uni,
            .initial_max_streams_bidi = conf.max_streams_bidi,
            .initial_max_streams_uni = conf.max_streams_uni,
            .ack_delay_exponent = conf.ack_delay_exponent,
            .max_ack_delay_ms = conf.max_ack_delay_ms,
            .disable_active_migration = conf.disable_migration,
            .active_connection_id_limit = max_peer_cids,
            .initial_scid = Cid.init(&c.local_cids[0].cid),
        };
        if (retry_scid) |r| params.retry_scid = Cid.init(r);
        // OpenSSL keeps a reference to the parameter bytes, not a copy.
        const n = tp.encode(&params, &c.tp_buf);
        if (tls.SSL_set_quic_tls_transport_params(ssl, &c.tp_buf, n) != 1) return error.Tls;
        return c;
    }

    pub fn destroy(c: *Conn) void {
        const a = c.alloc;
        var it = c.streams.valueIterator();
        while (it.next()) |s| c.freeStream(s.*);
        c.streams.deinit(a);
        while (c.free_list) |s| {
            c.free_list = s.next;
            a.destroy(s);
        }
        for (&c.spaces) |*sp| sp.deinit(a);
        if (c.rx_prev) |*k| k.deinit();
        if (c.rx_next) |*k| k.deinit();
        c.log.deinit(a);
        if (c.ssl) |s| tls.SSL_free(s);
        c.unregisterCids();
        a.destroy(c);
    }

    pub fn unregisterAll(c: *Conn) void {
        c.unregisterCids();
    }

    fn unregisterCids(c: *Conn) void {
        for (&c.local_cids) |*l| {
            if (l.active) c.ep.unregisterCid(&l.cid);
            l.active = false;
        }
        if (c.odcid_registered) c.ep.unregisterOdcid(c.odcid.slice());
        c.odcid_registered = false;
    }

    fn issueCid(c: *Conn) !void {
        for (&c.local_cids) |*l| {
            if (l.active) continue;
            var id: [cid_len]u8 = undefined;
            while (true) {
                tls.random(&id);
                if (c.ep.lookup(&id) == null) break;
            }
            l.* = .{ .seq = c.local_seq, .cid = id, .token = c.ep.resetToken(&id), .active = true, .pending = c.local_seq > 0 };
            c.local_seq += 1;
            try c.ep.registerCid(&l.cid, c);
            return;
        }
    }

    pub fn initialScid(c: *const Conn) []const u8 {
        for (&c.local_cids) |*l| if (l.active and l.seq == 0) return &l.cid;
        for (&c.local_cids) |*l| if (l.active) return &l.cid;
        return &c.local_cids[0].cid;
    }

    inline fn dcid(c: *const Conn) []const u8 {
        return c.peer_cids[c.peer_cid].cid.slice();
    }

    // ------------------------------------------------------------------
    // TLS callbacks

    const dispatch = [_]tls.Dispatch{
        .{ .function_id = tls.fn_crypto_send, .function = @ptrCast(&cryptoSend) },
        .{ .function_id = tls.fn_crypto_recv_rcd, .function = @ptrCast(&cryptoRecv) },
        .{ .function_id = tls.fn_crypto_release_rcd, .function = @ptrCast(&cryptoRelease) },
        .{ .function_id = tls.fn_yield_secret, .function = @ptrCast(&yieldSecret) },
        .{ .function_id = tls.fn_got_transport_params, .function = @ptrCast(&gotParams) },
        .{ .function_id = tls.fn_alert, .function = @ptrCast(&gotAlert) },
        .{ .function_id = 0, .function = null },
    };

    fn levelOf(l: u32) ?Level {
        return switch (l) {
            tls.level_none => .initial,
            tls.level_handshake => .handshake,
            tls.level_application => .app,
            else => null,
        };
    }

    fn cryptoSend(_: *tls.SSL, buf: [*]const u8, len: usize, consumed: *usize, arg: ?*anyopaque) callconv(.c) c_int {
        const c: *Conn = @ptrCast(@alignCast(arg));
        consumed.* = 0;
        const lvl = levelOf(c.tls_write) orelse return 0;
        const sp = &c.spaces[@intFromEnum(lvl)];
        if (sp.discarded) return 0;
        _ = sp.crypto_tx.write(c.alloc, buf[0..len], std.math.maxInt(usize)) catch return 0;
        consumed.* = len;
        c.markDirty();
        return 1;
    }

    fn cryptoRecv(_: *tls.SSL, buf: *?[*]const u8, len: *usize, arg: ?*anyopaque) callconv(.c) c_int {
        const c: *Conn = @ptrCast(@alignCast(arg));
        len.* = 0;
        buf.* = null;
        const lvl = levelOf(c.tls_read) orelse return 1;
        const p = c.spaces[@intFromEnum(lvl)].crypto_rx.peek();
        buf.* = p.ptr;
        len.* = p.len;
        return 1;
    }

    fn cryptoRelease(_: *tls.SSL, n: usize, arg: ?*anyopaque) callconv(.c) c_int {
        const c: *Conn = @ptrCast(@alignCast(arg));
        const lvl = levelOf(c.tls_read) orelse return 0;
        const r = &c.spaces[@intFromEnum(lvl)].crypto_rx;
        if (n > r.available()) return 0;
        r.consume(n);
        r.max = r.read + crypto_window;
        return 1;
    }

    fn yieldSecret(ssl: *tls.SSL, level: u32, direction: c_int, secret: [*]const u8, len: usize, arg: ?*anyopaque) callconv(.c) c_int {
        const c: *Conn = @ptrCast(@alignCast(arg));
        const lvl = levelOf(level) orelse return 0; // 0-RTT is not enabled
        const id = tls.suiteId(ssl) orelse return 0;
        const suite = crypto.Suite.fromTls(id) orelse return 0;
        if (len != suite.secretLen()) return 0;
        const sp = &c.spaces[@intFromEnum(lvl)];
        const keys = crypto.Keys.init(suite, secret[0..len], direction == 1) catch return 0;
        if (direction == 1) {
            if (sp.tx) |*k| k.deinit();
            sp.tx = keys;
            c.tls_write = level;
        } else {
            if (sp.rx) |*k| k.deinit();
            sp.rx = keys;
            c.tls_read = level;
        }
        if (lvl == .app) c.suite = suite;
        return 1;
    }

    fn gotParams(_: *tls.SSL, params: [*]const u8, len: usize, arg: ?*anyopaque) callconv(.c) c_int {
        const c: *Conn = @ptrCast(@alignCast(arg));
        const p = tp.decodeClient(params[0..len]) catch return 0;
        // RFC 9000 §7.3: initial_source_connection_id must match the SCID.
        if (!p.initial_scid.?.eql(c.peer_cids[0].cid.slice())) return 0;
        c.peer_params = p;
        c.tx_max = p.initial_max_data;
        c.peer_max_uni = p.initial_max_streams_uni;
        if (p.max_idle_timeout_ms != 0) c.idle_timeout = @min(c.idle_timeout, p.max_idle_timeout_ms * 1000);
        if (c.idle_timeout == 0) c.idle_timeout = p.max_idle_timeout_ms * 1000;
        return 1;
    }

    fn gotAlert(_: *tls.SSL, code: u8, arg: ?*anyopaque) callconv(.c) c_int {
        const c: *Conn = @ptrCast(@alignCast(arg));
        c.alert = code;
        return 1;
    }

    fn driveTls(c: *Conn) ProcError!void {
        const ssl = c.ssl orelse return;
        tls.ERR_clear_error();
        const ret = if (c.tls_done) tls.SSL_read(ssl, null, 0) else tls.SSL_do_handshake(ssl);
        if (ret <= 0) {
            const e = tls.SSL_get_error(ssl, ret);
            switch (e) {
                tls.ssl_error_want_read, tls.ssl_error_want_write, tls.ssl_error_want_x509_lookup, tls.ssl_error_want_client_hello_cb, tls.ssl_error_want_retry_verify => {},
                else => {
                    const code: u64 = 0x100 + @as(u64, c.alert orelse 80);
                    return c.fail(@enumFromInt(code), 0x06);
                },
            }
            if (c.alert) |al| return c.fail(@enumFromInt(0x100 + @as(u64, al)), 0x06);
            return;
        }
        if (c.tls_done) return;
        if (tls.alpn(ssl).len == 0) return c.fail(@enumFromInt(0x100 + 120), 0x06);
        if (c.peer_params.initial_scid == null) return c.fail(.transport_parameter, 0x06);
        if (c.spaces[2].tx == null or c.spaces[2].rx == null) return c.fail(.internal, 0x06);
        c.tls_done = true;
        c.state = .open;
        c.validated = true;
        c.handshake_done_pending = true;
        c.discard_handshake_pending = true;
        const target = @min(c.cfg().max_datagram, c.peer_params.max_udp_payload_size);
        if (target > c.mtu) c.mtu_probe = @intCast(target);
        c.rx_next = try c.spaces[2].rx.?.next();
        // Extra connection IDs for migration.
        while (c.activeLocalCids() < @min(max_local_cids, c.peer_params.active_connection_id_limit)) try c.issueCid();
        c.markDirty();
        c.cb().conn_ready(c.cb().ctx, c);
    }

    fn activeLocalCids(c: *const Conn) usize {
        var n: usize = 0;
        for (&c.local_cids) |*l| n += @intFromBool(l.active);
        return n;
    }

    // ------------------------------------------------------------------
    // Errors and closing

    fn fail(c: *Conn, code: Err, frame: u64) ProcError {
        c.startClose(.{ .app = false, .code = @intFromEnum(code), .frame = frame });
        return error.Close;
    }

    fn closeWith(c: *Conn, code: Err, frame: u64) void {
        c.startClose(.{ .app = false, .code = @intFromEnum(code), .frame = frame });
    }

    fn startClose(c: *Conn, info: CloseInfo) void {
        if (c.state == .closing or c.state == .draining or c.state == .closed) return;
        var i = info;
        const n = @min(i.reason.len, c.close_reason.len);
        @memcpy(c.close_reason[0..n], i.reason[0..n]);
        i.reason = c.close_reason[0..n];
        c.close = i;
        c.close_pending = true;
        c.enterTerminal(.closing);
    }

    fn enterTerminal(c: *Conn, st: State) void {
        c.state = st;
        c.close_deadline = c.now() + 3 * c.rtt.pto(c.peer_params.max_ack_delay_ms * 1000);
        c.notifyClosed();
        c.markDirty();
    }

    fn notifyClosed(c: *Conn) void {
        const code: u64 = if (c.close) |ci| ci.code else 0;
        var it = c.streams.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (!s.released) c.cb().stream_reset(c.cb().ctx, s, code);
        }
        c.cb().conn_closed(c.cb().ctx, c);
    }

    /// Closes with `code` once every peer-initiated bidirectional stream is
    /// released and fully acknowledged (graceful HTTP/3 shutdown). The close
    /// waits at least three PTOs so requests the peer sent before it saw the
    /// shutdown, but which were lost or reordered, still arrive and are served.
    pub fn closeWhenIdle(c: *Conn, code: u64) void {
        if (c.state != .open and c.state != .handshake) return;
        c.drain_close = code;
        c.drain_after = c.now() + 3 * c.rtt.pto(c.peer_params.max_ack_delay_ms * 1000);
        c.markDirty();
    }

    /// True once a graceful close has passed its grace period; new peer
    /// requests after this point should be refused.
    pub fn drainGraceOver(c: *const Conn) bool {
        return c.drain_close != null and c.now() >= c.drain_after;
    }

    /// Peer-initiated bidirectional streams still held by the transport.
    pub fn activeBidi(c: *const Conn) usize {
        var n: usize = 0;
        var it = c.streams.keyIterator();
        while (it.next()) |id| n += @intFromBool(id.* & 3 == 0);
        return n;
    }

    /// Application-initiated close (CONNECTION_CLOSE 0x1d).
    pub fn closeApp(c: *Conn, code: u64, reason: []const u8) void {
        c.startClose(.{ .app = true, .code = code, .reason = reason });
    }

    // ------------------------------------------------------------------
    // Receiving

    /// Processes one (coalesced) packet. `pkt` spans exactly the packet.
    pub fn recvPacket(c: *Conn, pkt: []u8, hdr: *const packet.Header, peer: Addr, local: Addr) void {
        if (c.state == .draining or c.state == .closed) return;
        const lvl: Level = if (!hdr.long) .app else switch (hdr.ty) {
            .initial => .initial,
            .handshake => .handshake,
            else => return,
        };
        const sp = &c.spaces[@intFromEnum(lvl)];
        if (sp.discarded) return;
        var keys: *crypto.Keys = if (sp.rx) |*k| k else return;
        const un = packet.unprotect(pkt, hdr.pn_offset, &keys.hp, sp.largest_rx) catch return;
        const hl = hdr.pn_offset + un.pn_len;
        if (pkt.len < hl + crypto.tag_len) return;
        var phase_change = false;
        if (lvl == .app) {
            const phase = pkt[0] & 0x04 != 0;
            if (phase != c.key_phase) {
                if (un.pn < c.phase_start_pn) {
                    keys = if (c.rx_prev) |*k| k else return;
                } else {
                    if (c.rx_next == null) c.rx_next = keys.next() catch return;
                    keys = &c.rx_next.?;
                    phase_change = true;
                }
            }
        }
        const body = pkt[hl .. pkt.len - crypto.tag_len];
        keys.open(un.pn, pkt[0..hl], body, pkt[pkt.len - crypto.tag_len ..][0..crypto.tag_len].*) catch return;
        if (c.state == .closing) {
            // RFC 9000 §10.2.1: answer with CONNECTION_CLOSE, sparingly.
            c.close_rx_count += 1;
            if (std.math.isPowerOfTwo(c.close_rx_count)) {
                c.close_pending = true;
                c.markDirty();
            }
            return;
        }
        const reserved: u8 = if (hdr.long) 0x0c else 0x18;
        if (pkt[0] & reserved != 0) {
            c.closeWith(.protocol_violation, 0);
            return;
        }
        if (un.pn < sp.recv_floor or sp.recv_pns.contains(un.pn)) return;
        if (phase_change) c.commitKeyUpdate(un.pn) catch {
            c.closeWith(.internal, 0);
            return;
        };
        if (lvl == .handshake and !c.validated) c.validated = true;
        if (lvl == .app and (sp.largest_rx == null or un.pn > sp.largest_rx.?)) {
            var cid_changed = false;
            if (!std.mem.eql(u8, hdr.dcid, &c.rx_dcid)) {
                cid_changed = true;
                @memcpy(&c.rx_dcid, hdr.dcid[0..cid_len]);
            }
            if (!peer.eql(&c.peer)) c.onPeerAddressChange(peer, local, cid_changed);
        }
        c.idle_deadline = c.now() + c.idleTimeout();

        const eliciting = c.processFrames(lvl, body) catch |e| switch (e) {
            error.Drop => return,
            error.Close, error.OutOfMemory => {
                if (e == error.OutOfMemory) c.closeWith(.internal, 0);
                return;
            },
        };
        _ = sp.recv_pns.add(un.pn, un.pn + 1);
        if (sp.largest_rx == null or un.pn > sp.largest_rx.?) {
            sp.largest_rx = un.pn;
            sp.largest_rx_time = c.now();
        }
        sp.ack_dirty = true;
        if (eliciting) {
            sp.ack_unsent += 1;
            if (lvl != .app or sp.ack_unsent >= 2) {
                sp.ack_deadline = c.now();
            } else if (sp.ack_deadline == 0) {
                sp.ack_deadline = c.now() + c.cfg().max_ack_delay_ms * 1000;
            }
            c.markDirty();
        }
        if (lvl == .handshake and !c.spaces[0].discarded) c.discardSpace(.initial);
        if (c.discard_handshake_pending) {
            c.discard_handshake_pending = false;
            c.discardSpace(.initial);
            c.discardSpace(.handshake);
        }
        c.flushEvents();
    }

    fn idleTimeout(c: *const Conn) u64 {
        return @max(c.idle_timeout, 3 * c.rtt.pto(c.peer_params.max_ack_delay_ms * 1000));
    }

    fn commitKeyUpdate(c: *Conn, pn: u64) !void {
        if (c.rx_prev) |*k| k.deinit();
        c.rx_prev = c.spaces[2].rx;
        c.spaces[2].rx = c.rx_next;
        c.rx_next = try c.spaces[2].rx.?.next();
        c.key_phase = !c.key_phase;
        c.phase_start_pn = pn;
        if (c.tx_phase != c.key_phase) {
            // Peer-initiated update: respond with new send keys.
            const n = try c.spaces[2].tx.?.next();
            c.spaces[2].tx.?.deinit();
            c.spaces[2].tx = n;
            c.tx_phase = c.key_phase;
            c.tx_phase_start_pn = c.spaces[2].next_pn;
            c.tx_phase_acked = false;
            c.tx_phase_packets = 0;
        }
    }

    /// Starts a locally-initiated key update (RFC 9001 §6.1).
    pub fn initiateKeyUpdate(c: *Conn) !void {
        if (c.state != .open or !c.tx_phase_acked or c.tx_phase != c.key_phase) return error.NotAllowed;
        const n = try c.spaces[2].tx.?.next();
        c.spaces[2].tx.?.deinit();
        c.spaces[2].tx = n;
        c.tx_phase = !c.tx_phase;
        c.tx_phase_start_pn = c.spaces[2].next_pn;
        c.tx_phase_acked = false;
        c.tx_phase_packets = 0;
    }

    fn discardSpace(c: *Conn, lvl: Level) void {
        const sp = &c.spaces[@intFromEnum(lvl)];
        if (sp.discarded) return;
        // Remove its bytes in flight from congestion control.
        var i: usize = 0;
        while (i < sp.sent.count) : (i += 1) {
            const s = sp.sent.at(i);
            if (s.state == .pending and s.in_flight) c.cc.remove(s.size);
        }
        sp.deinit(c.alloc);
        sp.* = .{ .discarded = true };
        c.pto_count = 0;
        c.releaseLog();
        if (lvl == .handshake and c.odcid_registered) {
            c.ep.unregisterOdcid(c.odcid.slice());
            c.odcid_registered = false;
        }
    }

    fn onPeerAddressChange(c: *Conn, peer: Addr, local: Addr, cid_changed: bool) void {
        if (c.cfg().disable_migration or c.state != .open) return;
        // A peer that moves to a new connection ID gets a fresh one from us.
        if (cid_changed) c.rotatePeerCid();
        if (c.prev_peer == null and c.validated) c.prev_peer = c.peer;
        const nat_rebind = peer.sameHost(&c.peer);
        c.peer = peer;
        c.local = local;
        c.validated = false;
        c.rx_bytes = 0;
        c.tx_bytes = 0;
        if (!nat_rebind) {
            c.cc.reset();
            c.rtt = .{};
            c.mtu = packet.min_initial_size;
        }
        var ch: [8]u8 = undefined;
        tls.random(&ch);
        c.challenge = ch;
        c.challenge_pending = true;
        c.challenge_deadline = c.now() + 3 * c.rtt.pto(c.peer_params.max_ack_delay_ms * 1000);
        c.markDirty();
    }

    fn rotatePeerCid(c: *Conn) void {
        for (&c.peer_cids, 0..) |*p, i| {
            if (i == c.peer_cid or !p.active or p.retire_pending) continue;
            c.peer_cids[c.peer_cid].retire_pending = true;
            c.peer_cid = i;
            return;
        }
    }

    // ------------------------------------------------------------------
    // Frames

    fn processFrames(c: *Conn, lvl: Level, payload: []const u8) ProcError!bool {
        var r = wire.Reader{ .buf = payload };
        var eliciting = false;
        if (payload.len == 0) return c.fail(.protocol_violation, 0);
        while (!r.done()) {
            const ty = r.varint() catch return c.fail(.frame_encoding, 0);
            if (lvl != .app) switch (ty) {
                0x00, 0x01, 0x02, 0x03, 0x06, 0x1c => {},
                else => return c.fail(.protocol_violation, ty),
            };
            if (ty != 0x00 and ty != 0x02 and ty != 0x03 and ty != 0x1c and ty != 0x1d) eliciting = true;
            switch (ty) {
                0x00 => while (r.pos < r.buf.len and r.buf[r.pos] == 0) {
                    r.pos += 1;
                },
                0x01 => {},
                0x02, 0x03 => try c.onAckFrame(lvl, &r, ty == 0x03),
                0x04 => try c.onResetStream(&r),
                0x05 => try c.onStopSending(&r),
                0x06 => try c.onCrypto(lvl, &r),
                0x07 => return c.fail(.protocol_violation, ty),
                0x08...0x0f => try c.onStreamFrame(&r, ty),
                0x10 => {
                    const v = r.varint() catch return c.fail(.frame_encoding, ty);
                    c.tx_max = @max(c.tx_max, v);
                },
                0x11 => try c.onMaxStreamData(&r),
                0x12, 0x13 => {
                    const v = r.varint() catch return c.fail(.frame_encoding, ty);
                    if (v > 1 << 60) return c.fail(.frame_encoding, ty);
                    if (ty == 0x13) c.peer_max_uni = @max(c.peer_max_uni, v);
                },
                0x14 => _ = r.varint() catch return c.fail(.frame_encoding, ty),
                0x15 => {
                    const id = r.varint() catch return c.fail(.frame_encoding, ty);
                    _ = r.varint() catch return c.fail(.frame_encoding, ty);
                    if (id & 3 == 3 or (id & 1 == 1 and !c.localStreamOpened(id))) return c.fail(.stream_state, ty);
                },
                0x16, 0x17 => {
                    const v = r.varint() catch return c.fail(.frame_encoding, ty);
                    if (v > 1 << 60) return c.fail(.frame_encoding, ty);
                },
                0x18 => try c.onNewCid(&r),
                0x19 => try c.onRetireCid(&r),
                0x1a => {
                    const d = r.bytes(8) catch return c.fail(.frame_encoding, ty);
                    c.response = d[0..8].*;
                    c.markDirty();
                },
                0x1b => {
                    const d = r.bytes(8) catch return c.fail(.frame_encoding, ty);
                    if (c.challenge) |ch| if (std.mem.eql(u8, &ch, d)) {
                        c.challenge = null;
                        c.challenge_pending = false;
                        c.validated = true;
                        c.prev_peer = null;
                    };
                },
                0x1c, 0x1d => {
                    _ = r.varint() catch return c.fail(.frame_encoding, ty);
                    if (ty == 0x1c) _ = r.varint() catch return c.fail(.frame_encoding, ty);
                    const rl = r.varint() catch return c.fail(.frame_encoding, ty);
                    _ = r.bytes(rl) catch return c.fail(.frame_encoding, ty);
                    c.close = null;
                    c.enterTerminal(.draining);
                    return error.Close;
                },
                0x1e => return c.fail(.protocol_violation, ty),
                else => return c.fail(.frame_encoding, ty),
            }
            if (c.state == .closing or c.state == .draining) return error.Close;
        }
        return eliciting;
    }

    fn localStreamOpened(c: *const Conn, id: u64) bool {
        if (id & 2 != 0) return (id >> 2) < c.local_uni_next;
        return false;
    }

    fn onCrypto(c: *Conn, lvl: Level, r: *wire.Reader) ProcError!void {
        const off = r.varint() catch return c.fail(.frame_encoding, 0x06);
        const len = r.varint() catch return c.fail(.frame_encoding, 0x06);
        const data = r.bytes(len) catch return c.fail(.frame_encoding, 0x06);
        if (off + len > wire.max_varint) return c.fail(.frame_encoding, 0x06);
        const sp = &c.spaces[@intFromEnum(lvl)];
        const before = sp.crypto_rx.available();
        _ = sp.crypto_rx.insert(c.alloc, off, data, false) catch |e| switch (e) {
            error.FlowControl => return c.fail(.crypto_buffer_exceeded, 0x06),
            error.Drop => return error.Drop,
            error.OutOfMemory => return error.OutOfMemory,
            error.FinalSize => unreachable,
        };
        if (sp.crypto_rx.available() > before) try c.driveTls();
    }

    fn onStreamFrame(c: *Conn, r: *wire.Reader, ty: u64) ProcError!void {
        const id = r.varint() catch return c.fail(.frame_encoding, ty);
        const off = if (ty & 0x04 != 0) r.varint() catch return c.fail(.frame_encoding, ty) else 0;
        const len = if (ty & 0x02 != 0) r.varint() catch return c.fail(.frame_encoding, ty) else r.left();
        const data = r.bytes(len) catch return c.fail(.frame_encoding, ty);
        if (off + len > wire.max_varint) return c.fail(.frame_encoding, ty);
        const fin = ty & 0x01 != 0;
        if (id & 1 != 0) {
            // Server-initiated: only bidirectional streams could carry peer data.
            return c.fail(.stream_state, ty);
        }
        const s = try c.peerStream(id, ty) orelse return;
        if (s.peer_reset != null) return;
        if (s.stop_code != null) {
            // Discarding: validate and count the bytes, but do not store them.
            const grew = s.recv.discard(off, len, fin) catch |e| switch (e) {
                error.FlowControl => return c.fail(.flow_control, ty),
                error.FinalSize => return c.fail(.final_size, ty),
                else => unreachable,
            };
            c.rx_highest += grew;
            if (c.rx_highest > c.rx_max) return c.fail(.flow_control, ty);
            c.rx_consumed += grew;
            c.maybeWindowUpdate();
            return;
        }
        const before = s.recv.available();
        const had_fin = s.recv.final != null;
        const grew = s.recv.insert(c.alloc, off, data, fin) catch |e| switch (e) {
            error.FlowControl => return c.fail(.flow_control, ty),
            error.FinalSize => return c.fail(.final_size, ty),
            error.Drop => return error.Drop,
            error.OutOfMemory => return error.OutOfMemory,
        };
        c.rx_highest += grew;
        if (c.rx_highest > c.rx_max) return c.fail(.flow_control, ty);
        if (s.recv.available() > before or (!had_fin and s.recv.final != null)) c.queueEvent(s);
    }

    /// Looks up or implicitly opens a peer-initiated stream. Null means the
    /// stream was already closed and the frame is ignored.
    fn peerStream(c: *Conn, id: u64, ty: u64) ProcError!?*Stream {
        if (c.streams.get(id)) |s| return s;
        const uni: usize = @intFromBool(id & 2 != 0);
        const idx = id >> 2;
        if (idx >= c.max_streams[uni]) return c.fail(.stream_limit, ty);
        if (c.peer_seen[uni].contains(idx)) return null;
        c.peer_seen[uni].addCover(idx, idx + 1);
        const s = try c.newStream(id);
        s.recv.max = if (uni == 1) c.cfg().max_stream_data_uni else c.cfg().max_stream_data_bidi;
        if (uni == 0) s.send.max = c.peer_params.initial_max_stream_data_bidi_local;
        c.cb().stream_open(c.cb().ctx, s);
        return s;
    }

    fn newStream(c: *Conn, id: u64) ProcError!*Stream {
        const s = if (c.free_list) |f| blk: {
            c.free_list = f.next;
            break :blk f;
        } else try c.alloc.create(Stream);
        s.* = .{ .id = id, .conn = c };
        // Stream ids only grow and every stream is removed again, so the
        // open-addressing map fills with tombstones that lengthen each probe
        // (every new id is a miss). Compact it once they reach half its size;
        // nothing iterates the map here.
        if (c.stream_removals >= 32 and c.stream_removals * 2 >= c.streams.capacity()) {
            c.streams.rehash(std.hash_map.AutoContext(u64){});
            c.stream_removals = 0;
        }
        c.streams.put(c.alloc, id, s) catch |e| {
            c.alloc.destroy(s);
            return e;
        };
        return s;
    }

    fn onResetStream(c: *Conn, r: *wire.Reader) ProcError!void {
        const id = r.varint() catch return c.fail(.frame_encoding, 0x04);
        const code = r.varint() catch return c.fail(.frame_encoding, 0x04);
        const final = r.varint() catch return c.fail(.frame_encoding, 0x04);
        if (id & 1 != 0) return c.fail(.stream_state, 0x04);
        const s = try c.peerStream(id, 0x04) orelse return;
        if (s.peer_reset != null) return;
        if (s.recv.final) |f| if (f != final) return c.fail(.final_size, 0x04);
        if (final < s.recv.highest) return c.fail(.final_size, 0x04);
        if (final > s.recv.max) return c.fail(.flow_control, 0x04);
        const grew = final - s.recv.highest;
        c.rx_highest += grew;
        if (c.rx_highest > c.rx_max) return c.fail(.flow_control, 0x04);
        if (s.stop_code == null) c.rx_consumed += final - s.recv.read;
        s.recv.highest = final;
        s.recv.final = final;
        s.peer_reset = code;
        s.recv.deinit(c.alloc);
        c.maybeWindowUpdate();
        if (!s.released) c.cb().stream_reset(c.cb().ctx, s, code);
        c.maybeFree(s);
    }

    fn onStopSending(c: *Conn, r: *wire.Reader) ProcError!void {
        const id = r.varint() catch return c.fail(.frame_encoding, 0x05);
        const code = r.varint() catch return c.fail(.frame_encoding, 0x05);
        var s: *Stream = undefined;
        if (id & 1 != 0) {
            if (!c.localStreamOpened(id)) return c.fail(.stream_state, 0x05);
            s = c.streams.get(id) orelse return;
        } else {
            if (id & 2 != 0) return c.fail(.stream_state, 0x05);
            s = try c.peerStream(id, 0x05) orelse return;
        }
        if (s.peer_stop != null) return;
        s.peer_stop = code;
        s.reset(code);
        if (!s.released) c.cb().stream_reset(c.cb().ctx, s, code);
    }

    fn onMaxStreamData(c: *Conn, r: *wire.Reader) ProcError!void {
        const id = r.varint() catch return c.fail(.frame_encoding, 0x11);
        const v = r.varint() catch return c.fail(.frame_encoding, 0x11);
        if (id & 3 == 2) return c.fail(.stream_state, 0x11);
        if (id & 1 != 0 and !c.localStreamOpened(id)) return c.fail(.stream_state, 0x11);
        const s = if (id & 1 != 0) c.streams.get(id) orelse return else try c.peerStream(id, 0x11) orelse return;
        if (v > s.send.max) {
            s.send.max = v;
            if (s.send.hasPending()) c.queueStream(s);
        }
    }

    fn onNewCid(c: *Conn, r: *wire.Reader) ProcError!void {
        const seq = r.varint() catch return c.fail(.frame_encoding, 0x18);
        const prior = r.varint() catch return c.fail(.frame_encoding, 0x18);
        const len = r.byte() catch return c.fail(.frame_encoding, 0x18);
        if (len < 1 or len > packet.max_cid_len or prior > seq) return c.fail(.frame_encoding, 0x18);
        const id = r.bytes(len) catch return c.fail(.frame_encoding, 0x18);
        const token = r.bytes(16) catch return c.fail(.frame_encoding, 0x18);
        if (c.dcid().len == 0) return c.fail(.protocol_violation, 0x18);
        if (prior > c.peer_retire_prior) {
            c.peer_retire_prior = prior;
            for (&c.peer_cids) |*p| if (p.active and p.seq < prior) {
                p.retire_pending = true;
            };
        }
        var known = false;
        for (&c.peer_cids) |*p| if (p.active and p.seq == seq) {
            if (!p.cid.eql(id)) return c.fail(.protocol_violation, 0x18);
            known = true;
        };
        if (!known and seq >= c.peer_retire_prior) {
            const slot = for (&c.peer_cids) |*p| {
                if (!p.active) break p;
            } else return c.fail(.connection_id_limit, 0x18);
            slot.* = .{ .seq = seq, .cid = Cid.init(id), .token = token[0..16].*, .active = true };
        } else if (!known) {
            // Already retired by retire_prior_to: retire it right away.
            const slot = for (&c.peer_cids) |*p| {
                if (!p.active) break p;
            } else return c.fail(.connection_id_limit, 0x18);
            slot.* = .{ .seq = seq, .cid = Cid.init(id), .active = true, .retire_pending = true };
        }
        if (c.peer_cids[c.peer_cid].retire_pending) {
            for (&c.peer_cids, 0..) |*p, i| if (p.active and !p.retire_pending) {
                c.peer_cid = i;
                break;
            };
        }
        c.markDirty();
    }

    fn onRetireCid(c: *Conn, r: *wire.Reader) ProcError!void {
        const seq = r.varint() catch return c.fail(.frame_encoding, 0x19);
        if (seq >= c.local_seq) return c.fail(.protocol_violation, 0x19);
        for (&c.local_cids) |*l| if (l.active and l.seq == seq) {
            c.ep.unregisterCid(&l.cid);
            l.active = false;
            c.issueCid() catch return error.OutOfMemory;
            c.markDirty();
            return;
        };
    }

    // ------------------------------------------------------------------
    // Acknowledgements and loss

    fn onAckFrame(c: *Conn, lvl: Level, r: *wire.Reader, ecn: bool) ProcError!void {
        const ty: u64 = if (ecn) 0x03 else 0x02;
        const largest = r.varint() catch return c.fail(.frame_encoding, ty);
        const delay_raw = r.varint() catch return c.fail(.frame_encoding, ty);
        const count = r.varint() catch return c.fail(.frame_encoding, ty);
        const first = r.varint() catch return c.fail(.frame_encoding, ty);
        if (first > largest) return c.fail(.frame_encoding, ty);
        const sp = &c.spaces[@intFromEnum(lvl)];
        if (largest >= sp.next_pn) return c.fail(.protocol_violation, ty);
        const t = c.now();
        var newly_largest: ?*rec.Sent = null;
        var any_eliciting = false;
        var any_newly = false;
        var hi = largest;
        var lo = largest - first;
        var i: u64 = 0;
        while (true) {
            c.ackRange(sp, lo, hi, &newly_largest, &any_eliciting, &any_newly, largest);
            if (i == count) break;
            i += 1;
            const gap = r.varint() catch return c.fail(.frame_encoding, ty);
            const len = r.varint() catch return c.fail(.frame_encoding, ty);
            if (gap + 2 > lo or len > lo - gap - 2) return c.fail(.frame_encoding, ty);
            hi = lo - gap - 2;
            lo = hi - len;
        }
        if (ecn) for (0..3) |_| {
            _ = r.varint() catch return c.fail(.frame_encoding, ty);
        };
        if (sp.largest_acked == null or largest > sp.largest_acked.?) sp.largest_acked = largest;
        if (newly_largest) |s| if (any_eliciting) {
            var delay: u64 = 0;
            if (lvl == .app) {
                delay = delay_raw << @intCast(@min(c.peer_params.ack_delay_exponent, 20));
                if (c.state == .open) delay = @min(delay, c.peer_params.max_ack_delay_ms * 1000);
            }
            c.rtt.update(t - s.time, delay);
        };
        if (any_newly) {
            c.detectLoss(sp);
            c.pto_count = 0;
            sp.probes = 0;
            c.releaseLog();
            c.markDirty();
        }
    }

    fn ackRange(c: *Conn, sp: *Space, lo: u64, hi: u64, newly_largest: *?*rec.Sent, any_eliciting: *bool, any_newly: *bool, largest: u64) void {
        if (sp.sent.count == 0) return;
        const first = sp.sent.first_pn;
        const last = first + sp.sent.count - 1;
        if (hi < first or lo > last) return;
        var pn = @min(hi, last);
        const stop = @max(lo, first);
        while (true) : (pn -= 1) {
            const s = sp.sent.get(pn).?;
            if (s.state == .pending) {
                s.state = .acked;
                if (pn == largest) newly_largest.* = s;
                any_newly.* = true;
                if (s.ack_eliciting) {
                    any_eliciting.* = true;
                    sp.eliciting_in_flight -|= 1;
                }
                if (s.in_flight) c.cc.onAcked(s.size, s.time, false);
                c.onFramesAcked(s);
                if (sp == &c.spaces[2] and pn >= c.tx_phase_start_pn) c.tx_phase_acked = true;
            }
            if (pn == stop) break;
        }
    }

    fn onFramesAcked(c: *Conn, s: *const rec.Sent) void {
        var k: u32 = 0;
        while (k < s.nframes) : (k += 1) {
            const f = c.log.get(s.frames +% k).*;
            switch (f.kind) {
                .stream => if (c.streams.get(f.id)) |st| {
                    st.send.onAck(f.offset, f.len, f.fin);
                    if (st.want_write and st.send.buffered() <= c.cfg().stream_send_buffer / 2) {
                        st.want_write = false;
                        c.queueWritable(st);
                    }
                    c.maybeFree(st);
                },
                .crypto => {
                    const sp = &c.spaces[@intCast(f.id)];
                    if (!sp.discarded) sp.crypto_tx.onAck(f.offset, f.len, false);
                },
                .reset_stream => if (c.streams.get(f.id)) |st| {
                    st.reset_acked = true;
                    c.maybeFree(st);
                },
                .ping => if (f.id > 0) {
                    c.mtu = f.id;
                    c.cc.mds = f.id;
                    c.mtu_probe = 0;
                    c.mtu_probing = false;
                },
                .ack => {
                    // The peer saw our ACK up to f.id: stop repeating older ranges.
                    const sp = &c.spaces[@intCast(f.offset)];
                    if (!sp.discarded and f.id + 1 > sp.recv_floor) {
                        sp.recv_floor = f.id + 1;
                        sp.recv_pns.removeBelow(f.id + 1);
                    }
                },
                else => {},
            }
        }
    }

    fn onFramesLost(c: *Conn, s: *const rec.Sent) void {
        var k: u32 = 0;
        while (k < s.nframes) : (k += 1) {
            const f = c.log.get(s.frames +% k).*;
            switch (f.kind) {
                .stream => if (c.streams.get(f.id)) |st| {
                    if (st.reset_code == null) {
                        st.send.onLost(f.offset, f.len, f.fin);
                        c.queueStream(st);
                    }
                },
                .crypto => {
                    const sp = &c.spaces[@intCast(f.id)];
                    if (!sp.discarded) sp.crypto_tx.onLost(f.offset, f.len, false);
                },
                .max_data => c.max_data_pending = true,
                .max_stream_data => if (c.streams.get(f.id)) |st| {
                    if (st.hasRecv() and !st.recvDone() and st.recv.final == null) {
                        st.ctrl.max_data = true;
                        c.queueCtrl(st);
                    }
                },
                .max_streams_bidi => c.max_streams_pending[0] = true,
                .max_streams_uni => c.max_streams_pending[1] = true,
                .reset_stream => if (c.streams.get(f.id)) |st| {
                    if (!st.reset_acked) {
                        st.ctrl.reset = true;
                        c.queueCtrl(st);
                    }
                },
                .stop_sending => if (c.streams.get(f.id)) |st| {
                    if (st.peer_reset == null and !st.recv.finKnownAndReceived()) {
                        st.ctrl.stop = true;
                        c.queueCtrl(st);
                    }
                },
                .new_cid => for (&c.local_cids) |*l| {
                    if (l.active and l.seq == f.id) l.pending = true;
                },
                .retire_cid => for (&c.peer_cids) |*p| {
                    if (p.active and p.seq == f.id) p.retire_pending = true;
                },
                .handshake_done => c.handshake_done_pending = true,
                .ping => if (f.id > 0) {
                    // Path does not carry the probed size; stay at the current MTU.
                    c.mtu_probe = 0;
                    c.mtu_probing = false;
                },
                else => {},
            }
        }
        c.markDirty();
    }

    fn detectLoss(c: *Conn, sp: *Space) void {
        sp.loss_time = 0;
        const largest = sp.largest_acked orelse return;
        const t = c.now();
        const delay = c.rtt.lossDelay();
        const lost_before = t -| delay;
        var lost_any = false;
        var latest_lost_time: u64 = 0;
        var i: usize = 0;
        while (i < sp.sent.count) : (i += 1) {
            const s = sp.sent.at(i);
            if (s.pn > largest) break;
            if (s.state != .pending) continue;
            if (s.time <= lost_before or largest >= s.pn + rec.packet_threshold) {
                s.state = .lost;
                if (s.ack_eliciting) sp.eliciting_in_flight -|= 1;
                if (s.in_flight) {
                    c.cc.remove(s.size);
                    lost_any = true;
                    latest_lost_time = @max(latest_lost_time, s.time);
                }
                c.onFramesLost(s);
            } else {
                const lt = s.time + delay;
                if (sp.loss_time == 0 or lt < sp.loss_time) sp.loss_time = lt;
            }
        }
        if (lost_any) c.cc.onCongestion(latest_lost_time, t);
    }

    fn releaseLog(c: *Conn) void {
        var oldest: ?u32 = null;
        for (&c.spaces) |*sp| {
            if (sp.discarded) continue;
            if (sp.sent.popSettled()) |idx| {
                if (oldest == null or (idx -% c.log.head) < (oldest.? -% c.log.head)) oldest = idx;
            }
        }
        c.log.release(oldest);
    }

    const Pto = struct { t: u64, lvl: Level };

    fn ptoTime(c: *const Conn) ?Pto {
        const base = c.rtt.pto(0) << @intCast(@min(c.pto_count, 20));
        var best: ?Pto = null;
        for (&c.spaces, 0..) |*sp, li| {
            if (sp.discarded or sp.eliciting_in_flight == 0) continue;
            var d = base;
            if (li == 2) {
                if (c.state != .open) continue;
                d += (c.peer_params.max_ack_delay_ms * 1000) << @intCast(@min(c.pto_count, 20));
            }
            const t = sp.last_eliciting_time + d;
            if (best == null or t < best.?.t) best = .{ .t = t, .lvl = @enumFromInt(li) };
        }
        return best;
    }

    fn lossTimer(c: *const Conn) u64 {
        var t: u64 = 0;
        for (&c.spaces) |*sp| if (!sp.discarded and sp.loss_time != 0 and (t == 0 or sp.loss_time < t)) {
            t = sp.loss_time;
        };
        if (t != 0) return t;
        if (!c.validated and c.tx_bytes >= 3 * c.rx_bytes) return 0;
        if (c.ptoTime()) |p| return p.t;
        return 0;
    }

    fn onLossTimeout(c: *Conn) void {
        for (&c.spaces) |*sp| if (!sp.discarded and sp.loss_time != 0 and sp.loss_time <= c.now()) {
            c.detectLoss(sp);
            c.releaseLog();
            return;
        };
        const p = c.ptoTime() orelse return;
        if (p.t > c.now()) return;
        c.pto_count += 1;
        const sp = &c.spaces[@intFromEnum(p.lvl)];
        sp.probes = 2;
        // Resend the oldest unacknowledged data as the probe payload.
        var i: usize = 0;
        var n: usize = 0;
        while (i < sp.sent.count and n < 2) : (i += 1) {
            const s = sp.sent.at(i);
            if (s.state == .pending and s.ack_eliciting) {
                c.onFramesLost(s);
                n += 1;
            }
        }
        // Handshake probes also carry Initial data that may be lost.
        if (p.lvl == .handshake and !c.spaces[0].discarded) c.spaces[0].probes = 1;
        c.markDirty();
    }

    // ------------------------------------------------------------------
    // Flow control and stream bookkeeping

    fn onConsumed(c: *Conn, s: *Stream, n: usize) void {
        c.rx_consumed += n;
        const win = if (s.isUni()) c.cfg().max_stream_data_uni else c.cfg().max_stream_data_bidi;
        if (s.recv.final == null and s.recv.max - s.recv.read < win / 2) {
            s.recv.max = s.recv.read + win;
            s.ctrl.max_data = true;
            c.queueCtrl(s);
        }
        c.maybeWindowUpdate();
        if (s.recv.finished()) c.maybeFree(s);
    }

    fn maybeWindowUpdate(c: *Conn) void {
        const win = c.cfg().max_data;
        if (c.rx_max - c.rx_consumed < win / 2) {
            c.rx_max = c.rx_consumed + win;
            c.max_data_pending = true;
            c.markDirty();
        }
    }

    fn queueStream(c: *Conn, s: *Stream) void {
        if (!s.queued) {
            s.queued = true;
            s.next = null;
            if (c.send_tail) |t| t.next = s else c.send_head = s;
            c.send_tail = s;
        }
        c.markDirty();
    }

    fn queueCtrl(c: *Conn, s: *Stream) void {
        if (!s.ctrl_queued) {
            s.ctrl_queued = true;
            s.ctrl_next = null;
            if (c.ctrl_tail) |t| t.ctrl_next = s else c.ctrl_head = s;
            c.ctrl_tail = s;
        }
        c.markDirty();
    }

    fn queueEvent(c: *Conn, s: *Stream) void {
        c.pushEvent(s);
        s.ev_read = true;
    }

    fn queueWritable(c: *Conn, s: *Stream) void {
        c.pushEvent(s);
        s.ev_write = true;
    }

    fn pushEvent(c: *Conn, s: *Stream) void {
        if (s.readable_queued or s.released) return;
        s.readable_queued = true;
        s.ev_next = null;
        if (c.ev_tail) |t| t.ev_next = s else c.ev_head = s;
        c.ev_tail = s;
    }

    /// Delivers queued stream notifications outside of frame processing.
    fn flushEvents(c: *Conn) void {
        while (c.ev_head) |s| {
            c.ev_head = s.ev_next;
            if (c.ev_head == null) c.ev_tail = null;
            s.readable_queued = false;
            const rd = s.ev_read;
            const wr = s.ev_write;
            s.ev_read = false;
            s.ev_write = false;
            if (rd and !s.released and c.state == .open) c.cb().stream_readable(c.cb().ctx, s);
            if (wr and !s.released and c.state == .open) c.cb().stream_writable(c.cb().ctx, s);
            if (s.freeing) {
                s.freeing = false;
                c.maybeFree(s);
            }
        }
    }

    fn maybeFree(c: *Conn, s: *Stream) void {
        if (c.state != .open and c.state != .handshake) return;
        if (!s.released or s.freeing or !s.sendDone() or !s.recvDone()) return;
        if (s.queued or s.ctrl_queued or s.readable_queued) {
            // Unlinked lazily by the send/ctrl loops; mark for collection.
            s.freeing = true;
            return;
        }
        c.retireStream(s);
    }

    fn retireStream(c: *Conn, s: *Stream) void {
        if (c.streams.remove(s.id)) c.stream_removals += 1;
        if (s.id & 1 == 0) {
            const uni: usize = @intFromBool(s.isUni());
            c.closed_streams[uni] += 1;
            const limit = if (uni == 1) c.cfg().max_streams_uni else c.cfg().max_streams_bidi;
            const want = c.closed_streams[uni] + limit;
            if (want - c.max_streams[uni] >= @max(limit / 2, 1)) {
                c.max_streams[uni] = want;
                c.max_streams_pending[uni] = true;
                c.markDirty();
            }
        }
        if (s.recv.highest > s.recv.read and s.stop_code == null and s.peer_reset == null) c.rx_consumed += s.recv.highest - s.recv.read;
        c.freeStream(s);
        if (c.drain_close != null) c.markDirty();
    }

    fn freeStream(c: *Conn, s: *Stream) void {
        s.send.deinit(c.alloc);
        s.recv.deinit(c.alloc);
        s.next = c.free_list;
        c.free_list = s;
    }

    /// Opens a server-initiated unidirectional stream.
    pub fn openUni(c: *Conn) error{ Limit, OutOfMemory }!*Stream {
        if (c.local_uni_next >= c.peer_max_uni) return error.Limit;
        const id = (c.local_uni_next << 2) | 3;
        const s = c.newStream(id) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.OutOfMemory,
        };
        c.local_uni_next += 1;
        s.send.max = c.peer_params.initial_max_stream_data_uni;
        return s;
    }

    pub fn markDirty(c: *Conn) void {
        c.ep.markDirty(c);
    }

    // ------------------------------------------------------------------
    // Timers

    pub fn computeDeadline(c: *Conn) u64 {
        if (c.state == .closed) return 0;
        if (c.state == .closing or c.state == .draining) return c.close_deadline;
        var d = c.idle_deadline;
        const lt = c.lossTimer();
        if (lt != 0) d = @min(d, lt);
        const sp = &c.spaces[2];
        if (sp.ack_deadline != 0) d = @min(d, sp.ack_deadline);
        if (c.challenge != null) d = @min(d, c.challenge_deadline);
        if (c.drain_close != null and c.drain_after > c.now()) d = @min(d, c.drain_after);
        return d;
    }

    /// Runs expired timers. Returns false when the connection is finished.
    pub fn onTimeout(c: *Conn) bool {
        const t = c.now();
        switch (c.state) {
            .closed => return false,
            .closing, .draining => {
                if (t >= c.close_deadline) {
                    c.state = .closed;
                    return false;
                }
                return true;
            },
            else => {},
        }
        if (t >= c.idle_deadline) {
            c.close = .{ .app = false, .code = 0 };
            c.state = .closed;
            c.notifyClosed();
            return false;
        }
        if (c.challenge != null and t >= c.challenge_deadline) {
            // Validation failed: fall back to the last validated path.
            c.challenge = null;
            c.challenge_pending = false;
            if (c.prev_peer) |p| {
                c.peer = p;
                c.validated = true;
                c.prev_peer = null;
            } else {
                c.state = .closed;
                c.notifyClosed();
                return false;
            }
        }
        const lt = c.lossTimer();
        if (lt != 0 and t >= lt) c.onLossTimeout();
        if (c.spaces[2].ack_deadline != 0 and t >= c.spaces[2].ack_deadline) c.markDirty();
        return true;
    }

    // ------------------------------------------------------------------
    // Sending

    fn wantsLevel(c: *Conn, lvl: Level) bool {
        const sp = &c.spaces[@intFromEnum(lvl)];
        if (sp.discarded or sp.tx == null) return false;
        if (sp.ack_dirty and sp.ack_unsent > 0 and sp.ack_deadline != 0 and sp.ack_deadline <= c.now()) return true;
        if (sp.probes > 0) return true;
        if (sp.crypto_tx.hasPending()) return true;
        if (lvl != .app) return false;
        if (c.state != .open) return false;
        if (c.handshake_done_pending or c.max_data_pending or c.max_streams_pending[0] or c.max_streams_pending[1]) return true;
        if (c.response != null or c.challenge_pending or c.ctrl_head != null) return true;
        for (&c.local_cids) |*l| if (l.active and l.pending) return true;
        for (&c.peer_cids) |*p| if (p.active and p.retire_pending) return true;
        if (c.send_head != null and c.cc.in_flight < c.cc.cwnd) return true;
        return false;
    }

    /// Builds the next datagram into `out`. Returns null when idle.
    pub fn send(c: *Conn, out: []u8) ?Datagram {
        if (c.state == .closed or c.state == .draining) return null;
        if (c.drain_close) |code| if (c.state == .open and c.activeBidi() == 0 and c.now() >= c.drain_after) {
            c.drain_close = null;
            c.closeApp(code, "");
        };
        var max = @min(out.len, c.mtu);
        if (!c.validated) {
            const allowance = (3 * c.rx_bytes) -| c.tx_bytes;
            max = @min(max, allowance);
        }
        if (max < 64) return null;
        if (c.mtu_probe != 0 and !c.mtu_probing and c.state == .open and c.validated and out.len >= c.mtu_probe and c.cc.in_flight < c.cc.cwnd) {
            const n = c.buildMtuProbe(out);
            if (n > 0) return .{ .len = n, .to = c.peer, .from = c.local };
        }
        const buf = out[0..max];
        var pos: usize = 0;
        if (c.state == .closing) {
            if (!c.close_pending) return null;
            c.close_pending = false;
            pos = c.buildClose(buf);
        } else {
            const want = [3]bool{ c.wantsLevel(.initial), c.wantsLevel(.handshake), c.wantsLevel(.app) };
            const last: ?usize = if (want[2]) 2 else if (want[1]) 1 else if (want[0]) 0 else null;
            if (last == null) return null;
            var initial_eliciting = false;
            for (0..3) |li| {
                if (!want[li]) continue;
                if (buf.len - pos < 64) break;
                // Datagrams with ack-eliciting Initials are padded to 1200 bytes.
                const pad = if (li == last.? and (initial_eliciting or (li == 0 and c.spaces[0].crypto_tx.hasPending()))) packet.min_initial_size -| pos else 0;
                const r = c.buildPacket(@enumFromInt(li), buf[pos..], pad);
                if (li == 0 and r.eliciting) initial_eliciting = true;
                pos += r.len;
            }
            if (initial_eliciting and pos < packet.min_initial_size) {
                // Not expected: the last packet was not produced. Pad the datagram.
                const end = @min(packet.min_initial_size, buf.len);
                @memset(buf[pos..end], 0);
                pos = end;
            }
        }
        if (pos == 0) return null;
        c.tx_bytes += pos;
        return .{ .len = pos, .to = c.peer, .from = c.local };
    }

    /// Sends a PING padded to the probed size; its ACK raises the MTU.
    fn buildMtuProbe(c: *Conn, out: []u8) usize {
        const sp = &c.spaces[2];
        const keys = &(sp.tx orelse return 0);
        const size: usize = c.mtu_probe;
        const pn = sp.next_pn;
        const pn_len = packet.pnLen(pn, sp.largest_acked);
        var w = wire.Writer{ .buf = out[0..size] };
        const pn_off = packet.writeShort(&w, c.dcid(), c.tx_phase, pn, pn_len);
        w.byte(0x01);
        const end = size - crypto.tag_len;
        @memset(out[w.pos..end], 0);
        const hl = pn_off + pn_len;
        keys.seal(pn, out[0..hl], out[hl..end], out[end..][0..crypto.tag_len]);
        packet.protect(out[0..size], pn_off, pn_len, &keys.hp);
        const start = c.log.tail;
        c.log.push(c.alloc, .{ .kind = .ping, .id = size }) catch return 0;
        sp.sent.push(c.alloc, .{ .pn = pn, .time = c.now(), .frames = start, .nframes = 1, .size = @intCast(size), .ack_eliciting = false, .in_flight = false }) catch {
            c.log.tail = start;
            return 0;
        };
        sp.next_pn += 1;
        c.mtu_probing = true;
        return size;
    }

    const Built = struct { len: usize, eliciting: bool };

    fn buildPacket(c: *Conn, lvl: Level, out: []u8, pad_to: usize) Built {
        const sp = &c.spaces[@intFromEnum(lvl)];
        const keys = &(sp.tx orelse return .{ .len = 0, .eliciting = false });
        const pn = sp.next_pn;
        const pn_len = packet.pnLen(pn, sp.largest_acked);
        var w = wire.Writer{ .buf = out };
        var len_pos: usize = 0;
        var pn_off: usize = 0;
        if (lvl == .app) {
            pn_off = packet.writeShort(&w, c.dcid(), c.tx_phase, pn, pn_len);
        } else {
            const h = packet.writeLong(&w, if (lvl == .initial) .initial else .handshake, c.dcid(), c.initialScid(), pn, pn_len);
            len_pos = h.len_pos;
            pn_off = h.pn_offset;
        }
        const payload_start = w.pos;
        // Leave room for the AEAD tag.
        if (out.len < payload_start + crypto.tag_len + 8) return .{ .len = 0, .eliciting = false };
        w.buf = out[0 .. out.len - crypto.tag_len];
        const log_start = c.log.tail;
        var eliciting = false;
        var nframes: u16 = 0;

        if (sp.ack_dirty and !sp.recv_pns.isEmpty()) {
            if (c.writeAck(sp, lvl, &w)) {
                nframes += 1;
            }
        }
        const cc_ok = sp.probes > 0 or c.cc.in_flight < c.cc.cwnd;
        if (cc_ok) {
            if (lvl == .app and c.state == .open) {
                nframes += c.writeControl(&w, &eliciting);
            }
            nframes += c.writeCrypto(sp, lvl, &w, &eliciting);
            if (lvl == .app and c.state == .open) nframes += c.writeStreams(&w, &eliciting);
            if (sp.probes > 0 and !eliciting and w.left() > 1) {
                w.byte(0x01);
                eliciting = true;
                c.logFrame(.{ .kind = .ping, .id = 0 });
                nframes += 1;
            }
        }
        if (nframes == 0 or w.pos == payload_start) {
            c.log.tail = log_start;
            return .{ .len = 0, .eliciting = false };
        }
        if (sp.probes > 0 and eliciting) sp.probes -= 1;
        // Header protection samples 16 bytes starting 4 bytes after the PN.
        const min_payload = 4 -| pn_len;
        while (w.pos - payload_start < min_payload) w.byte(0);
        if (pad_to > 0) {
            const target = @min(pad_to, out.len) -| crypto.tag_len;
            if (w.pos < target) {
                @memset(out[w.pos..target], 0);
                w.pos = target;
            }
        }
        const total = w.pos + crypto.tag_len;
        if (lvl != .app) {
            const l = total - pn_off;
            out[len_pos] = @intCast(0x40 | (l >> 8));
            out[len_pos + 1] = @truncate(l);
        }
        const hl = pn_off + pn_len;
        keys.seal(pn, out[0..hl], out[hl..w.pos], out[w.pos..][0..crypto.tag_len]);
        packet.protect(out[0..total], pn_off, pn_len, &keys.hp);

        const t = c.now();
        const nf: u16 = @intCast(c.log.tail -% log_start);
        sp.sent.push(c.alloc, .{
            .pn = pn,
            .time = t,
            .frames = log_start,
            .nframes = nf,
            .size = @intCast(total),
            .ack_eliciting = eliciting,
            .in_flight = eliciting,
            .state = if (eliciting) .pending else .acked,
        }) catch {
            c.log.tail = log_start;
            c.closeWith(.internal, 0);
            return .{ .len = 0, .eliciting = false };
        };
        sp.next_pn += 1;
        if (eliciting) {
            if (sp.eliciting_in_flight == 0 or c.idle_deadline < t + c.idleTimeout()) c.idle_deadline = t + c.idleTimeout();
            sp.last_eliciting_time = t;
            sp.eliciting_in_flight += 1;
            c.cc.onSent(total);
        }
        if (lvl == .app) c.tx_phase_packets += 1;
        if (!eliciting) c.releaseLog();
        return .{ .len = total, .eliciting = eliciting };
    }

    inline fn logFrame(c: *Conn, f: rec.FrameRec) void {
        c.log.push(c.alloc, f) catch {};
    }

    fn writeAck(c: *Conn, sp: *Space, lvl: Level, w: *wire.Writer) bool {
        const items = sp.recv_pns.items();
        if (items.len == 0) return false;
        // Budget: type + largest + delay + count + first + ranges.
        var n = items.len;
        while (n > 1 and 1 + 8 * 4 + (n - 1) * 16 > w.left()) n -= 1;
        if (1 + 8 * 4 > w.left()) return false;
        const top = items[items.len - 1];
        const largest = top.end - 1;
        var delay: u64 = 0;
        if (sp.largest_rx) |lr| if (lr == largest) {
            delay = (c.now() -| sp.largest_rx_time) >> c.cfg().ack_delay_exponent;
        };
        if (lvl != .app) delay = 0;
        w.byte(0x02);
        w.varint(largest);
        w.varint(delay);
        w.varint(n - 1);
        w.varint(top.end - 1 - top.start);
        var prev_start = top.start;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            const r = items[items.len - 1 - k];
            w.varint(prev_start - r.end - 1);
            w.varint(r.end - 1 - r.start);
            prev_start = r.start;
        }
        sp.ack_dirty = false;
        sp.ack_unsent = 0;
        sp.ack_deadline = 0;
        c.logFrame(.{ .kind = .ack, .id = largest, .offset = @intFromEnum(lvl) });
        return true;
    }

    fn writeCrypto(c: *Conn, sp: *Space, lvl: Level, w: *wire.Writer, eliciting: *bool) u16 {
        var n: u16 = 0;
        while (true) {
            const room = w.left();
            if (room < 1 + 8 + 4 + 16) break;
            const ch = sp.crypto_tx.next(room - (1 + 8 + 4), std.math.maxInt(u64)) orelse break;
            if (ch.c.len == 0) break;
            w.byte(0x06);
            w.varint(ch.c.off);
            w.varintWidth(ch.c.len, 2);
            sp.crypto_tx.copy(ch.c.off, w.buf[w.pos..][0..@intCast(ch.c.len)]);
            w.pos += @intCast(ch.c.len);
            sp.crypto_tx.onSent(ch.c);
            c.logFrame(.{ .kind = .crypto, .id = @intFromEnum(lvl), .offset = ch.c.off, .len = @intCast(ch.c.len) });
            eliciting.* = true;
            n += 1;
        }
        return n;
    }

    fn writeControl(c: *Conn, w: *wire.Writer, eliciting: *bool) u16 {
        var n: u16 = 0;
        if (c.response) |d| if (w.left() >= 9) {
            w.byte(0x1b);
            w.bytes(&d);
            c.response = null;
            eliciting.* = true;
            n += 1;
        };
        if (c.challenge_pending and w.left() >= 9) {
            w.byte(0x1a);
            w.bytes(&c.challenge.?);
            c.challenge_pending = false;
            eliciting.* = true;
            n += 1;
        }
        if (c.handshake_done_pending and w.left() >= 1) {
            w.byte(0x1e);
            c.handshake_done_pending = false;
            c.logFrame(.{ .kind = .handshake_done, .id = 0 });
            eliciting.* = true;
            n += 1;
        }
        if (c.max_data_pending and w.left() >= 9) {
            w.byte(0x10);
            w.varint(c.rx_max);
            c.max_data_pending = false;
            c.logFrame(.{ .kind = .max_data, .id = 0 });
            eliciting.* = true;
            n += 1;
        }
        for (0..2) |u| if (c.max_streams_pending[u] and w.left() >= 9) {
            w.byte(if (u == 0) 0x12 else 0x13);
            w.varint(c.max_streams[u]);
            c.max_streams_pending[u] = false;
            c.logFrame(.{ .kind = if (u == 0) .max_streams_bidi else .max_streams_uni, .id = 0 });
            eliciting.* = true;
            n += 1;
        };
        for (&c.local_cids) |*l| if (l.active and l.pending and w.left() >= 1 + 8 + 8 + 1 + cid_len + 16) {
            w.byte(0x18);
            w.varint(l.seq);
            w.varint(0);
            w.byte(cid_len);
            w.bytes(&l.cid);
            w.bytes(&l.token);
            l.pending = false;
            c.logFrame(.{ .kind = .new_cid, .id = l.seq });
            eliciting.* = true;
            n += 1;
        };
        for (&c.peer_cids, 0..) |*p, i| if (p.active and p.retire_pending and i != c.peer_cid and w.left() >= 9) {
            w.byte(0x19);
            w.varint(p.seq);
            p.active = false;
            p.retire_pending = false;
            c.logFrame(.{ .kind = .retire_cid, .id = p.seq });
            eliciting.* = true;
            n += 1;
        };
        // Per-stream control frames.
        // Always consumes from the head; stops when the packet is full.
        while (c.ctrl_head) |s| {
            const nxt = s.ctrl_next;
            if (w.left() < 1 + 8 * 3) break;
            if (s.ctrl.max_data and !s.freeing) {
                w.byte(0x11);
                w.varint(s.id);
                w.varint(s.recv.max);
                c.logFrame(.{ .kind = .max_stream_data, .id = s.id });
                n += 1;
            }
            if (s.ctrl.stop and w.left() >= 1 + 8 * 2) {
                w.byte(0x05);
                w.varint(s.id);
                w.varint(s.stop_code orelse 0);
                c.logFrame(.{ .kind = .stop_sending, .id = s.id });
                n += 1;
            }
            if (s.ctrl.reset and w.left() >= 1 + 8 * 3) {
                w.byte(0x04);
                w.varint(s.id);
                w.varint(s.reset_code orelse 0);
                w.varint(s.reset_final);
                c.logFrame(.{ .kind = .reset_stream, .id = s.id });
                n += 1;
            }
            s.ctrl = .{};
            eliciting.* = true;
            c.ctrl_head = nxt;
            if (c.ctrl_tail == s) c.ctrl_tail = null;
            s.ctrl_next = null;
            s.ctrl_queued = false;
            if (s.freeing) {
                s.freeing = false;
                c.maybeFree(s);
            }
        }
        return n;
    }

    fn writeStreams(c: *Conn, w: *wire.Writer, eliciting: *bool) u16 {
        var n: u16 = 0;
        while (c.send_head) |s| {
            if (w.left() < min_packet_room) break;
            if (s.freeing or s.reset_code != null) {
                c.popSend();
                if (s.freeing) {
                    s.freeing = false;
                    c.maybeFree(s);
                }
                continue;
            }
            const hdr_max = 1 + 8 + 8 + 2;
            const credit = c.tx_max - c.tx_sent;
            const ch = s.send.next(w.left() - hdr_max, credit) orelse {
                if (s.send.sent < s.send.end and s.send.sent < s.send.max and credit == 0) break;
                c.popSend();
                continue;
            };
            if (ch.c.len == 0 and !ch.c.fin) {
                c.popSend();
                continue;
            }
            var ty: u8 = 0x08 | 0x02;
            if (ch.c.off != 0) ty |= 0x04;
            if (ch.c.fin) ty |= 0x01;
            w.byte(ty);
            w.varint(s.id);
            if (ch.c.off != 0) w.varint(ch.c.off);
            w.varintWidth(ch.c.len, 2);
            const l: usize = @intCast(ch.c.len);
            s.send.copy(ch.c.off, w.buf[w.pos..][0..l]);
            w.pos += l;
            s.send.onSent(ch.c);
            if (ch.new) c.tx_sent += ch.c.len;
            c.logFrame(.{ .kind = .stream, .id = s.id, .offset = ch.c.off, .len = @intCast(ch.c.len), .fin = ch.c.fin });
            eliciting.* = true;
            n += 1;
            if (!s.send.hasPending()) {
                c.popSend();
            } else if (s.send.lost.isEmpty() and !s.send.fin_lost and c.tx_sent >= c.tx_max and !(s.send.fin and !s.send.fin_sent and s.send.sent == s.send.end)) {
                break; // connection flow control: wait for MAX_DATA
            } else if (w.left() >= min_packet_room) {
                // Round-robin: move to the back once this stream has had a turn.
                c.popSend();
                c.queueStream(s);
            }
        }
        return n;
    }

    fn popSend(c: *Conn) void {
        const s = c.send_head.?;
        c.send_head = s.next;
        if (c.send_tail == s) c.send_tail = null;
        s.next = null;
        s.queued = false;
    }

    fn buildClose(c: *Conn, out: []u8) usize {
        const info = c.close orelse CloseInfo{ .app = false, .code = 0 };
        var pos: usize = 0;
        for (0..3) |li| {
            const sp = &c.spaces[li];
            if (sp.discarded or sp.tx == null) continue;
            if (li == 2 and !c.tls_done) continue;
            if (li < 2 and c.tls_done) continue;
            const keys = &sp.tx.?;
            const pn = sp.next_pn;
            const pn_len = packet.pnLen(pn, sp.largest_acked);
            var w = wire.Writer{ .buf = out[pos..] };
            var len_pos: usize = 0;
            var pn_off: usize = 0;
            if (li == 2) {
                pn_off = packet.writeShort(&w, c.dcid(), c.tx_phase, pn, pn_len);
            } else {
                const h = packet.writeLong(&w, if (li == 0) .initial else .handshake, c.dcid(), c.initialScid(), pn, pn_len);
                len_pos = h.len_pos;
                pn_off = h.pn_offset;
            }
            const start = w.pos;
            const reason = info.reason[0..@min(info.reason.len, w.left() -| 64)];
            if (info.app and li == 2) {
                w.byte(0x1d);
                w.varint(info.code);
            } else {
                w.byte(0x1c);
                // Application errors before 1-RTT are masked (RFC 9000 §10.2.3).
                w.varint(if (info.app) @intFromEnum(Err.application) else info.code);
                w.varint(if (info.app) 0 else info.frame);
            }
            if (info.app and li != 2) {
                w.varint(0);
            } else {
                w.varint(reason.len);
                w.bytes(reason);
            }
            while (w.pos - start < 4) w.byte(0);
            var end = w.pos + crypto.tag_len;
            if (li == 0 and end + pos < packet.min_initial_size and out.len >= packet.min_initial_size) {
                const target = packet.min_initial_size - pos - crypto.tag_len;
                @memset(w.buf[w.pos..target], 0);
                w.pos = target;
                end = w.pos + crypto.tag_len;
            }
            const pkt = out[pos..][0..end];
            if (li != 2) {
                const l = end - pn_off;
                pkt[len_pos] = @intCast(0x40 | (l >> 8));
                pkt[len_pos + 1] = @truncate(l);
            }
            const hl = pn_off + pn_len;
            keys.seal(pn, pkt[0..hl], pkt[hl..w.pos], pkt[w.pos..][0..crypto.tag_len]);
            packet.protect(pkt, pn_off, pn_len, &keys.hp);
            sp.sent.push(c.alloc, .{ .pn = pn, .time = c.now(), .frames = c.log.tail, .nframes = 0, .size = @intCast(end), .ack_eliciting = false, .in_flight = false, .state = .acked }) catch {};
            sp.next_pn += 1;
            pos += end;
        }
        return pos;
    }
};
