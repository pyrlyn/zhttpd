//! Server endpoint: routes datagrams to connections by connection ID,
//! accepts new connections, answers with Version Negotiation, Retry and
//! stateless resets, runs connection timers and batches outgoing datagrams
//! into GSO-sized messages.
const std = @import("std");
const crypto = @import("crypto.zig");
const packet = @import("packet.zig");
const tls = @import("tls.zig");
const clock = @import("clock.zig");
const conn_mod = @import("conn.zig");
pub const Conn = conn_mod.Conn;
pub const Config = conn_mod.Config;
pub const Callbacks = conn_mod.Callbacks;
pub const Addr = conn_mod.Addr;
const cid_len = conn_mod.cid_len;

pub const OutMsg = struct {
    off: u32,
    len: u32,
    /// Segment size; every segment but the last is exactly this long.
    seg: u16,
    nseg: u16,
    to: Addr,
    from: Addr,
    closed: bool = false,
};

/// Receives batches of outgoing datagrams. `buf` holds the bytes the
/// messages reference.
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    send: *const fn (?*anyopaque, buf: []const u8, msgs: []const OutMsg) void = discard,

    fn discard(_: ?*anyopaque, _: []const u8, _: []const OutMsg) void {}
};

const max_msgs = 64;
const max_gso_bytes = 65000;
const max_gso_segs = 64;
const out_cap = 256 * 1024;
const retry_token_lifetime_us = 10 * std.time.us_per_s;

pub const Endpoint = struct {
    alloc: std.mem.Allocator,
    cfg: Config,
    callbacks: Callbacks,
    sink: Sink = .{},
    ssl_ctx: *tls.SSL_CTX,
    now: u64 = 0,
    max_conns: usize = std.math.maxInt(usize),
    gso: bool = true,
    conns: std.AutoHashMapUnmanaged(u64, *Conn) = .{},
    odcids: std.StringHashMapUnmanaged(*Conn) = .{},
    nconns: usize = 0,
    heap: std.ArrayList(*Conn) = .empty,
    dirty_head: ?*Conn = null,
    dead: std.ArrayList(*Conn) = .empty,
    reset_key: [32]u8 = undefined,
    token_key: [16]u8 = undefined,
    token_aead: crypto.ossl.Aead = undefined,
    out: []u8 = &.{},
    out_pos: usize = 0,
    msgs: [max_msgs]OutMsg = undefined,
    nmsgs: usize = 0,
    resets_this_tick: u32 = 0,
    /// Set while the endpoint is shutting down: no new connections.
    closing: bool = false,

    pub fn init(a: std.mem.Allocator, ssl_ctx: *tls.SSL_CTX, cfg: Config, callbacks: Callbacks) !*Endpoint {
        const ep = try a.create(Endpoint);
        errdefer a.destroy(ep);
        ep.* = .{ .alloc = a, .cfg = cfg, .callbacks = callbacks, .ssl_ctx = ssl_ctx };
        tls.random(&ep.reset_key);
        tls.random(&ep.token_key);
        ep.token_aead = try crypto.ossl.Aead.init(.aes128gcm, &ep.token_key, true);
        errdefer ep.token_aead.deinit();
        ep.out = try a.alloc(u8, out_cap);
        ep.now = clock.nowUs();
        return ep;
    }

    pub fn deinit(ep: *Endpoint) void {
        const a = ep.alloc;
        var it = ep.conns.valueIterator();
        var list: std.ArrayList(*Conn) = .empty;
        defer list.deinit(a);
        while (it.next()) |c| {
            if (std.mem.indexOfScalar(*Conn, list.items, c.*) == null) list.append(a, c.*) catch {};
        }
        for (ep.dead.items) |c| if (std.mem.indexOfScalar(*Conn, list.items, c) == null) list.append(a, c) catch {};
        for (list.items) |c| c.destroy();
        ep.conns.deinit(a);
        ep.odcids.deinit(a);
        ep.heap.deinit(a);
        ep.dead.deinit(a);
        a.free(ep.out);
        ep.token_aead.deinit();
        a.destroy(ep);
    }

    pub fn updateClock(ep: *Endpoint) void {
        ep.now = clock.nowUs();
        ep.resets_this_tick = 0;
    }

    // ------------------------------------------------------------------
    // Connection ID registry

    inline fn key(id: []const u8) u64 {
        return std.mem.readInt(u64, id[0..cid_len], .little);
    }

    pub fn lookup(ep: *Endpoint, id: []const u8) ?*Conn {
        if (id.len == cid_len) if (ep.conns.get(key(id))) |c| return c;
        return ep.odcids.get(id);
    }

    pub fn registerCid(ep: *Endpoint, id: *const [cid_len]u8, c: *Conn) !void {
        try ep.conns.put(ep.alloc, key(id), c);
    }

    pub fn unregisterCid(ep: *Endpoint, id: *const [cid_len]u8) void {
        _ = ep.conns.remove(key(id));
    }

    pub fn unregisterOdcid(ep: *Endpoint, id: []const u8) void {
        _ = ep.odcids.remove(id);
    }

    pub fn resetToken(ep: *const Endpoint, id: []const u8) [16]u8 {
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, id, &ep.reset_key);
        return mac[0..16].*;
    }

    pub fn markDirty(ep: *Endpoint, c: *Conn) void {
        if (c.dirty) return;
        c.dirty = true;
        c.dirty_next = ep.dirty_head;
        ep.dirty_head = c;
    }

    // ------------------------------------------------------------------
    // Input

    /// Processes one received datagram. Call `flush` after a batch.
    /// Returns the connection the datagram was delivered to, if any.
    pub fn recv(ep: *Endpoint, data: []u8, peer: Addr, local: Addr) ?*Conn {
        var off: usize = 0;
        var target: ?*Conn = null;
        while (off < data.len) {
            const rest = data[off..];
            const hdr = packet.parseHeader(rest, cid_len) catch break;
            if (hdr.long and hdr.version != packet.version_1) {
                if (off == 0 and hdr.version != 0 and data.len >= packet.min_initial_size) ep.sendVersionNegotiation(&hdr, peer, local);
                break;
            }
            if (hdr.long and hdr.ty == .retry) break;
            const c = ep.lookup(hdr.dcid) orelse blk: {
                if (off != 0) break;
                if (hdr.long and hdr.ty == .initial) {
                    break :blk ep.accept(&hdr, data.len, peer, local) orelse break;
                }
                if (!hdr.long) ep.sendStatelessReset(data.len, hdr.dcid, peer, local);
                break;
            };
            if (target) |t| {
                if (t != c) break;
            } else {
                target = c;
                c.rx_bytes += data.len;
            }
            c.recvPacket(rest[0..hdr.len], &hdr, peer, local);
            off += hdr.len;
        }
        if (target) |c| ep.markDirty(c);
        return target;
    }

    fn accept(ep: *Endpoint, hdr: *const packet.Header, dgram_len: usize, peer: Addr, local: Addr) ?*Conn {
        if (dgram_len < packet.min_initial_size or hdr.dcid.len < 8) return null;
        if (ep.closing or ep.nconns >= ep.max_conns) return null;
        var odcid: []const u8 = hdr.dcid;
        var retry_scid: ?[]const u8 = null;
        var odcid_buf: [packet.max_cid_len]u8 = undefined;
        if (ep.cfg.retry) {
            if (hdr.token.len == 0) {
                ep.sendRetry(hdr, peer, local);
                return null;
            }
            const n = ep.openToken(hdr.token, &peer, &odcid_buf) orelse return null;
            odcid = odcid_buf[0..n];
            retry_scid = hdr.dcid;
        }
        const c = Conn.create(ep, hdr, odcid, retry_scid, peer, local) catch return null;
        ep.odcids.put(ep.alloc, c.odcid.slice(), c) catch {
            c.destroy();
            return null;
        };
        c.odcid_registered = true;
        ep.nconns += 1;
        return c;
    }

    fn reserveOut(ep: *Endpoint, n: usize) ?[]u8 {
        if (ep.out_pos + n > ep.out.len or ep.nmsgs == max_msgs) ep.emit();
        if (ep.out_pos + n > ep.out.len) return null;
        return ep.out[ep.out_pos..][0..n];
    }

    fn pushSingle(ep: *Endpoint, len: usize, to: Addr, from: Addr) void {
        ep.msgs[ep.nmsgs] = .{ .off = @intCast(ep.out_pos), .len = @intCast(len), .seg = @intCast(len), .nseg = 1, .to = to, .from = from, .closed = true };
        ep.nmsgs += 1;
        ep.out_pos += len;
    }

    fn sendVersionNegotiation(ep: *Endpoint, hdr: *const packet.Header, peer: Addr, local: Addr) void {
        const buf = ep.reserveOut(64 + 2 * packet.max_cid_len) orelse return;
        var r: [1]u8 = undefined;
        tls.random(&r);
        const n = packet.versionNegotiation(buf, hdr.scid, hdr.dcid, r[0]);
        ep.pushSingle(n, peer, local);
    }

    fn sendStatelessReset(ep: *Endpoint, dgram_len: usize, id: []const u8, peer: Addr, local: Addr) void {
        // Smaller than the trigger so two endpoints cannot loop; at least 21 bytes.
        if (dgram_len <= 21 + 1 or ep.resets_this_tick >= 64) return;
        ep.resets_this_tick += 1;
        const len = @min(dgram_len - 1, 43);
        const buf = ep.reserveOut(len) orelse return;
        const token = ep.resetToken(id);
        var rnd: [64]u8 = undefined;
        tls.random(rnd[0..len]);
        const n = packet.statelessReset(buf, len, &token, rnd[0..len]);
        ep.pushSingle(n, peer, local);
    }

    // Retry tokens: AES-128-GCM over (issue time, original DCID) with the
    // client address as associated data.
    fn addrBytes(a: *const Addr, out: *[19]u8) []const u8 {
        @memcpy(out[0..16], &a.ip);
        std.mem.writeInt(u16, out[16..18], a.port, .big);
        out[18] = @intFromBool(a.v6);
        return out[0..19];
    }

    fn sendRetry(ep: *Endpoint, hdr: *const packet.Header, peer: Addr, local: Addr) void {
        var token: [12 + 8 + 1 + packet.max_cid_len + 16]u8 = undefined;
        tls.random(token[0..12]);
        var pt = token[12..];
        std.mem.writeInt(u64, pt[0..8], ep.now, .big);
        pt[8] = @intCast(hdr.dcid.len);
        @memcpy(pt[9..][0..hdr.dcid.len], hdr.dcid);
        const plen = 9 + hdr.dcid.len;
        var ad: [19]u8 = undefined;
        ep.token_aead.seal(token[0..12].*, addrBytes(&peer, &ad), pt[0..plen], pt[plen..][0..16]);
        const tlen = 12 + plen + 16;
        var scid: [cid_len]u8 = undefined;
        tls.random(&scid);
        const buf = ep.reserveOut(256) orelse return;
        var r: [1]u8 = undefined;
        tls.random(&r);
        const n = packet.retry(buf, hdr.scid, &scid, hdr.dcid, token[0..tlen], r[0]);
        ep.pushSingle(n, peer, local);
    }

    fn openToken(ep: *Endpoint, token: []const u8, peer: *const Addr, out: *[packet.max_cid_len]u8) ?usize {
        if (token.len < 12 + 9 + 16 or token.len > 12 + 9 + packet.max_cid_len + 16) return null;
        var buf: [12 + 9 + packet.max_cid_len + 16]u8 = undefined;
        @memcpy(buf[0..token.len], token);
        const plen = token.len - 12 - 16;
        var ad: [19]u8 = undefined;
        var dec = crypto.ossl.Aead.init(.aes128gcm, &ep.token_key, false) catch return null;
        defer dec.deinit();
        dec.open(buf[0..12].*, addrBytes(peer, &ad), buf[12..][0..plen], buf[12 + plen ..][0..16].*) catch return null;
        const pt = buf[12..][0..plen];
        const issued = std.mem.readInt(u64, pt[0..8], .big);
        if (ep.now > issued + retry_token_lifetime_us) return null;
        const n = pt[8];
        if (n > packet.max_cid_len or 9 + n != plen) return null;
        @memcpy(out[0..n], pt[9..][0..n]);
        return n;
    }

    // ------------------------------------------------------------------
    // Output

    /// Generates and emits datagrams for every connection with work.
    pub fn flush(ep: *Endpoint) void {
        while (ep.dirty_head) |c| {
            ep.dirty_head = c.dirty_next;
            c.dirty = false;
            ep.flushConn(c);
        }
        ep.emit();
        ep.reap();
    }

    /// Transmits one connection's pending output now, ahead of the rest of
    /// the batch. Closed connections are reaped by the next `flush`.
    pub fn flushConnNow(ep: *Endpoint, c: *Conn) void {
        if (!c.dirty) return;
        var link = &ep.dirty_head;
        while (link.*) |d| : (link = &d.dirty_next) {
            if (d == c) {
                link.* = c.dirty_next;
                break;
            }
        }
        c.dirty = false;
        ep.flushConn(c);
        ep.emit();
    }

    fn flushConn(ep: *Endpoint, c: *Conn) void {
        const slot = @max(ep.cfg.max_datagram, packet.min_initial_size);
        var budget: usize = 512;
        while (budget > 0) : (budget -= 1) {
            const buf = ep.reserveOut(slot) orelse break;
            const d = c.send(buf) orelse break;
            ep.append(d);
        }
        if (budget == 0) ep.markDirty(c);
        if (c.state == .closed) {
            ep.kill(c);
            return;
        }
        ep.schedule(c);
    }

    fn append(ep: *Endpoint, d: conn_mod.Datagram) void {
        if (ep.gso and ep.nmsgs > 0) {
            const m = &ep.msgs[ep.nmsgs - 1];
            if (!m.closed and m.off + m.len == ep.out_pos and d.len <= m.seg and m.nseg < max_gso_segs and m.len + d.len <= max_gso_bytes and m.to.eql(&d.to) and m.from.eql(&d.from)) {
                m.len += @intCast(d.len);
                m.nseg += 1;
                if (d.len < m.seg) m.closed = true;
                ep.out_pos += d.len;
                return;
            }
        }
        ep.msgs[ep.nmsgs] = .{ .off = @intCast(ep.out_pos), .len = @intCast(d.len), .seg = @intCast(d.len), .nseg = 1, .to = d.to, .from = d.from, .closed = !ep.gso };
        ep.nmsgs += 1;
        ep.out_pos += d.len;
    }

    fn emit(ep: *Endpoint) void {
        if (ep.nmsgs > 0) ep.sink.send(ep.sink.ctx, ep.out[0..ep.out_pos], ep.msgs[0..ep.nmsgs]);
        ep.nmsgs = 0;
        ep.out_pos = 0;
    }

    // ------------------------------------------------------------------
    // Timers (indexed binary min-heap keyed by connection deadline)

    pub fn nextDeadline(ep: *const Endpoint) ?u64 {
        return if (ep.heap.items.len > 0) ep.heap.items[0].deadline else null;
    }

    /// Milliseconds until the next timer, for poll/epoll; -1 when none.
    pub fn timeoutMs(ep: *Endpoint) i32 {
        const d = ep.nextDeadline() orelse return -1;
        const t = clock.nowUs();
        if (d <= t) return 0;
        return @intCast(@min((d - t + 999) / 1000, std.math.maxInt(i32)));
    }

    /// Runs expired connection timers. Call `flush` afterwards.
    pub fn onTimers(ep: *Endpoint) void {
        while (ep.heap.items.len > 0 and ep.heap.items[0].deadline <= ep.now) {
            const c = ep.heap.items[0];
            ep.heapRemove(c);
            if (!c.onTimeout()) {
                ep.kill(c);
                continue;
            }
            ep.markDirty(c);
        }
    }

    fn schedule(ep: *Endpoint, c: *Conn) void {
        const d = c.computeDeadline();
        if (c.heap_idx != std.math.maxInt(usize)) {
            if (d == c.deadline) return;
            const up = d < c.deadline;
            c.deadline = d;
            if (up) ep.siftUp(c.heap_idx) else ep.siftDown(c.heap_idx);
            return;
        }
        c.deadline = d;
        ep.heap.append(ep.alloc, c) catch return;
        c.heap_idx = ep.heap.items.len - 1;
        ep.siftUp(c.heap_idx);
    }

    fn heapRemove(ep: *Endpoint, c: *Conn) void {
        const i = c.heap_idx;
        if (i == std.math.maxInt(usize)) return;
        const last = ep.heap.pop().?;
        c.heap_idx = std.math.maxInt(usize);
        if (last == c) return;
        ep.heap.items[i] = last;
        last.heap_idx = i;
        ep.siftUp(i);
        ep.siftDown(last.heap_idx);
    }

    fn siftUp(ep: *Endpoint, start: usize) void {
        const h = ep.heap.items;
        var i = start;
        while (i > 0) {
            const p = (i - 1) / 2;
            if (h[p].deadline <= h[i].deadline) break;
            std.mem.swap(*Conn, &h[p], &h[i]);
            h[p].heap_idx = p;
            h[i].heap_idx = i;
            i = p;
        }
    }

    fn siftDown(ep: *Endpoint, start: usize) void {
        const h = ep.heap.items;
        var i = start;
        while (true) {
            const l = 2 * i + 1;
            if (l >= h.len) break;
            var m = l;
            if (l + 1 < h.len and h[l + 1].deadline < h[l].deadline) m = l + 1;
            if (h[i].deadline <= h[m].deadline) break;
            std.mem.swap(*Conn, &h[m], &h[i]);
            h[m].heap_idx = m;
            h[i].heap_idx = i;
            i = m;
        }
    }

    // ------------------------------------------------------------------
    // Lifecycle

    fn kill(ep: *Endpoint, c: *Conn) void {
        ep.heapRemove(c);
        c.unregisterAll();
        c.state = .closed;
        for (ep.dead.items) |d| if (d == c) return;
        ep.dead.append(ep.alloc, c) catch {};
    }

    fn reap(ep: *Endpoint) void {
        for (ep.dead.items) |c| {
            if (c.dirty) continue; // destroyed on a later flush
            ep.nconns -= 1;
            c.destroy();
        }
        var keep: usize = 0;
        for (ep.dead.items) |c| {
            if (c.dirty) {
                ep.dead.items[keep] = c;
                keep += 1;
            }
        }
        ep.dead.shrinkRetainingCapacity(keep);
    }

    /// Closes every connection with an application error code.
    pub fn closeAll(ep: *Endpoint, code: u64, reason: []const u8) void {
        ep.closing = true;
        var it = ep.conns.valueIterator();
        while (it.next()) |c| c.*.closeApp(code, reason);
    }

    pub fn connCount(ep: *const Endpoint) usize {
        return ep.nconns;
    }
};
