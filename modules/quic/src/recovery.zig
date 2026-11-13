//! Loss recovery state (RFC 9002): sent-packet records, retransmittable
//! frame records, RTT estimation and NewReno congestion control. The
//! connection drives the §A.7 algorithms using these structures.
const std = @import("std");

pub const granularity_us: u64 = 1000;
pub const packet_threshold: u64 = 3;
pub const initial_rtt_us: u64 = 333_000;

pub const FrameKind = enum(u8) {
    stream,
    crypto,
    max_data,
    max_stream_data,
    max_streams_bidi,
    max_streams_uni,
    reset_stream,
    stop_sending,
    new_cid,
    retire_cid,
    handshake_done,
    ping,
    ack,
    data_blocked,
    stream_data_blocked,
    path_response,
    new_token,
};

/// What a packet carried that may need retransmission or acknowledgement
/// processing. `id` is a stream ID, sequence number or largest-acked PN.
pub const FrameRec = struct {
    id: u64,
    offset: u64 = 0,
    len: u32 = 0,
    kind: FrameKind,
    fin: bool = false,
};

pub const State = enum(u8) { pending, acked, lost };

pub const Sent = struct {
    pn: u64,
    time: u64,
    frames: u32,
    nframes: u16,
    size: u16,
    ack_eliciting: bool,
    in_flight: bool,
    state: State = .pending,
};

/// Packets in send order, indexed by packet number. Every PN of a space is
/// recorded, so lookup is index arithmetic.
pub const SentRing = struct {
    items: []Sent = &.{},
    head: usize = 0,
    count: usize = 0,
    first_pn: u64 = 0,

    pub fn deinit(r: *SentRing, a: std.mem.Allocator) void {
        if (r.items.len > 0) a.free(r.items);
        r.* = .{};
    }

    pub fn push(r: *SentRing, a: std.mem.Allocator, s: Sent) error{OutOfMemory}!void {
        if (r.count == 0) {
            r.first_pn = s.pn;
            r.head = 0;
        }
        std.debug.assert(s.pn == r.first_pn + r.count);
        if (r.count == r.items.len) {
            const cap = @max(16, r.items.len * 2);
            const n = try a.alloc(Sent, cap);
            for (0..r.count) |i| n[i] = r.items[(r.head + i) & (r.items.len -% 1)];
            if (r.items.len > 0) a.free(r.items);
            r.items = n;
            r.head = 0;
        }
        r.items[(r.head + r.count) & (r.items.len - 1)] = s;
        r.count += 1;
    }

    pub inline fn get(r: *SentRing, pn: u64) ?*Sent {
        if (pn < r.first_pn or pn >= r.first_pn + r.count) return null;
        return &r.items[(r.head + @as(usize, @intCast(pn - r.first_pn))) & (r.items.len - 1)];
    }

    pub inline fn at(r: *SentRing, i: usize) *Sent {
        return &r.items[(r.head + i) & (r.items.len - 1)];
    }

    /// Drops settled packets from the front; returns the frame-log index of
    /// the oldest record still needed, or null when nothing remains.
    pub fn popSettled(r: *SentRing) ?u32 {
        while (r.count > 0 and r.items[r.head].state != .pending) {
            r.head = (r.head + 1) & (r.items.len - 1);
            r.count -= 1;
            r.first_pn += 1;
        }
        return if (r.count > 0) r.items[r.head].frames else null;
    }
};

/// Ring of frame records shared by the packet-number spaces of a connection.
/// Records are retained until every older packet is settled.
pub const FrameLog = struct {
    items: []FrameRec = &.{},
    head: u32 = 0,
    tail: u32 = 0,

    pub fn deinit(l: *FrameLog, a: std.mem.Allocator) void {
        if (l.items.len > 0) a.free(l.items);
        l.* = .{};
    }
    pub inline fn len(l: *const FrameLog) u32 {
        return l.tail -% l.head;
    }
    pub fn push(l: *FrameLog, a: std.mem.Allocator, f: FrameRec) error{OutOfMemory}!void {
        if (l.len() == l.items.len) {
            const cap = @max(64, l.items.len * 2);
            const n = try a.alloc(FrameRec, cap);
            var i: u32 = 0;
            while (i < l.len()) : (i += 1) n[(l.head +% i) & (cap - 1)] = l.items[(l.head +% i) & (l.items.len -% 1)];
            if (l.items.len > 0) a.free(l.items);
            l.items = n;
        }
        l.items[l.tail & (l.items.len - 1)] = f;
        l.tail +%= 1;
    }
    pub inline fn get(l: *FrameLog, i: u32) *FrameRec {
        return &l.items[i & (l.items.len - 1)];
    }
    /// Releases records older than `oldest` (or all when null).
    pub fn release(l: *FrameLog, oldest: ?u32) void {
        l.head = oldest orelse l.tail;
    }
};

pub const Rtt = struct {
    latest: u64 = 0,
    smoothed: u64 = initial_rtt_us,
    variance: u64 = initial_rtt_us / 2,
    min: u64 = std.math.maxInt(u64),
    has_sample: bool = false,

    /// RFC 9002 §5.3. `ack_delay` is already limited to max_ack_delay once
    /// the handshake is confirmed.
    pub fn update(r: *Rtt, latest: u64, ack_delay: u64) void {
        r.latest = latest;
        if (!r.has_sample) {
            r.has_sample = true;
            r.min = latest;
            r.smoothed = latest;
            r.variance = latest / 2;
            return;
        }
        r.min = @min(r.min, latest);
        var adjusted = latest;
        if (latest >= r.min + ack_delay) adjusted = latest - ack_delay;
        const diff = if (r.smoothed > adjusted) r.smoothed - adjusted else adjusted - r.smoothed;
        r.variance = (3 * r.variance + diff) / 4;
        r.smoothed = (7 * r.smoothed + adjusted) / 8;
    }

    pub fn pto(r: *const Rtt, max_ack_delay: u64) u64 {
        return r.smoothed + @max(4 * r.variance, granularity_us) + max_ack_delay;
    }

    pub fn lossDelay(r: *const Rtt) u64 {
        return @max(@max(r.latest, r.smoothed) * 9 / 8, granularity_us);
    }
};

/// NewReno (RFC 9002 §7, Appendix B).
pub const NewReno = struct {
    mds: u64,
    cwnd: u64,
    ssthresh: u64 = std.math.maxInt(u64),
    in_flight: u64 = 0,
    recovery_start: ?u64 = null,
    acked_in_ca: u64 = 0,

    pub fn init(mds: u64) NewReno {
        return .{ .mds = mds, .cwnd = initialWindow(mds) };
    }
    pub fn initialWindow(mds: u64) u64 {
        return @min(10 * mds, @max(2 * mds, 14720));
    }
    pub fn minWindow(c: *const NewReno) u64 {
        return 2 * c.mds;
    }
    pub inline fn available(c: *const NewReno) u64 {
        return c.cwnd -| c.in_flight;
    }
    pub inline fn onSent(c: *NewReno, size: u64) void {
        c.in_flight += size;
    }
    pub inline fn remove(c: *NewReno, size: u64) void {
        c.in_flight -|= size;
    }
    fn inRecovery(c: *const NewReno, sent_time: u64) bool {
        return if (c.recovery_start) |s| sent_time <= s else false;
    }
    /// `app_limited` skips growth when the sender did not fill the window.
    pub fn onAcked(c: *NewReno, size: u64, sent_time: u64, app_limited: bool) void {
        c.remove(size);
        if (c.inRecovery(sent_time) or app_limited) return;
        if (c.cwnd < c.ssthresh) {
            c.cwnd += size;
        } else {
            c.acked_in_ca += size;
            if (c.acked_in_ca >= c.cwnd) {
                c.acked_in_ca -= c.cwnd;
                c.cwnd += c.mds;
            }
        }
    }
    pub fn onCongestion(c: *NewReno, sent_time: u64, now: u64) void {
        if (c.inRecovery(sent_time)) return;
        c.recovery_start = now;
        c.ssthresh = @max(c.cwnd / 2, c.minWindow());
        c.cwnd = c.ssthresh;
        c.acked_in_ca = 0;
    }
    pub fn onPersistentCongestion(c: *NewReno) void {
        c.cwnd = c.minWindow();
        c.recovery_start = null;
        c.acked_in_ca = 0;
    }
    /// A new path starts over (RFC 9000 §9.4).
    pub fn reset(c: *NewReno) void {
        const in_flight = c.in_flight;
        c.* = init(c.mds);
        c.in_flight = in_flight;
    }
};

test "sent ring and frame log" {
    const a = std.testing.allocator;
    var r = SentRing{};
    defer r.deinit(a);
    var l = FrameLog{};
    defer l.deinit(a);
    for (0..40) |i| {
        try l.push(a, .{ .kind = .ping, .id = i });
        try r.push(a, .{ .pn = i, .time = i, .frames = @intCast(i), .nframes = 1, .size = 100, .ack_eliciting = true, .in_flight = true });
    }
    try std.testing.expectEqual(@as(u64, 7), r.get(7).?.pn);
    r.get(0).?.state = .acked;
    r.get(1).?.state = .lost;
    r.get(3).?.state = .acked;
    try std.testing.expectEqual(@as(?u32, 2), r.popSettled());
    try std.testing.expectEqual(@as(u64, 2), r.first_pn);
    l.release(2);
    try std.testing.expectEqual(@as(u32, 38), l.len());
    try std.testing.expectEqual(@as(u64, 39), l.get(39).id);
    try std.testing.expect(r.get(1) == null);
}

test "rtt and newreno" {
    var rtt = Rtt{};
    rtt.update(10_000, 0);
    try std.testing.expectEqual(@as(u64, 10_000), rtt.smoothed);
    rtt.update(20_000, 5_000);
    try std.testing.expect(rtt.smoothed > 10_000 and rtt.smoothed < 20_000);
    var cc = NewReno.init(1200);
    try std.testing.expectEqual(@as(u64, 12000), cc.cwnd);
    cc.onSent(1200);
    cc.onAcked(1200, 1, false);
    try std.testing.expectEqual(@as(u64, 13200), cc.cwnd);
    cc.onSent(1200);
    cc.onCongestion(5, 10);
    try std.testing.expectEqual(@as(u64, 6600), cc.cwnd);
    cc.onAcked(1200, 5, false); // sent before recovery: no growth
    try std.testing.expectEqual(@as(u64, 6600), cc.cwnd);
}
