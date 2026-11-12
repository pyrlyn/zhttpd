//! Stream data buffers: a send ring that keeps bytes until acknowledged and
//! a receive ring that reassembles out-of-order STREAM/CRYPTO frames.
const std = @import("std");
const RangeSet = @import("ranges.zig").RangeSet;

fn ringCopyOut(buf: []const u8, off: u64, out: []u8) void {
    const mask = buf.len - 1;
    const pos: usize = @intCast(off & mask);
    const first = @min(out.len, buf.len - pos);
    @memcpy(out[0..first], buf[pos..][0..first]);
    if (first < out.len) @memcpy(out[first..], buf[0 .. out.len - first]);
}

fn ringCopyIn(buf: []u8, off: u64, data: []const u8) void {
    const mask = buf.len - 1;
    const pos: usize = @intCast(off & mask);
    const first = @min(data.len, buf.len - pos);
    @memcpy(buf[pos..][0..first], data[0..first]);
    if (first < data.len) @memcpy(buf[0 .. data.len - first], data[first..]);
}

/// Re-lays ring contents [lo, hi) into a larger ring.
fn ringGrow(a: std.mem.Allocator, buf: *[]u8, lo: u64, hi: u64, need: usize) error{OutOfMemory}!void {
    const cap = std.math.ceilPowerOfTwo(usize, @max(need, 256)) catch return error.OutOfMemory;
    if (cap <= buf.len) return;
    const n = try a.alloc(u8, cap);
    if (buf.len > 0) {
        var off = lo;
        while (off < hi) {
            const pos: usize = @intCast(off & (buf.len - 1));
            const len: usize = @intCast(@min(hi - off, buf.len - pos));
            ringCopyIn(n, off, buf.*[pos..][0..len]);
            off += len;
        }
        a.free(buf.*);
    }
    buf.* = n;
}

pub const Chunk = struct { off: u64, len: u64, fin: bool };

pub const SendBuf = struct {
    buf: []u8 = &.{},
    /// Bytes below `acked` are acknowledged and released.
    acked: u64 = 0,
    /// Lowest never-sent offset.
    sent: u64 = 0,
    /// End of data written by the application.
    end: u64 = 0,
    /// Peer flow-control limit (MAX_STREAM_DATA).
    max: u64 = 0,
    acked_ranges: RangeSet(16) = .{},
    lost: RangeSet(16) = .{},
    fin: bool = false,
    fin_sent: bool = false,
    fin_acked: bool = false,
    fin_lost: bool = false,

    pub fn deinit(s: *SendBuf, a: std.mem.Allocator) void {
        if (s.buf.len > 0) a.free(s.buf);
        s.buf = &.{};
    }

    /// Buffered bytes not yet acknowledged.
    pub inline fn buffered(s: *const SendBuf) u64 {
        return s.end - s.acked;
    }

    /// Copies as much of `data` as fits below `limit` buffered bytes.
    pub fn write(s: *SendBuf, a: std.mem.Allocator, data: []const u8, limit: usize) error{OutOfMemory}!usize {
        std.debug.assert(!s.fin);
        const room = limit -| @as(usize, @intCast(s.buffered()));
        const n = @min(room, data.len);
        if (n == 0) return 0;
        const need: usize = @intCast(s.buffered() + n);
        if (need > s.buf.len) try ringGrow(a, &s.buf, s.acked, s.end, need);
        ringCopyIn(s.buf, s.end, data[0..n]);
        s.end += n;
        return n;
    }

    /// Exposes writable ring space for zero-copy fills; `commit` afterwards.
    pub fn reserve(s: *SendBuf, a: std.mem.Allocator, want: usize, limit: usize) error{OutOfMemory}![]u8 {
        const room = limit -| @as(usize, @intCast(s.buffered()));
        const n = @min(room, want);
        if (n == 0) return &.{};
        const need: usize = @intCast(s.buffered() + n);
        if (need > s.buf.len) try ringGrow(a, &s.buf, s.acked, s.end, need);
        const pos: usize = @intCast(s.end & (s.buf.len - 1));
        return s.buf[pos..][0..@min(n, s.buf.len - pos)];
    }
    pub fn commit(s: *SendBuf, n: usize) void {
        s.end += n;
    }

    pub fn finish(s: *SendBuf) void {
        s.fin = true;
    }

    /// True when a frame could be sent now (ignoring connection credit).
    pub fn hasPending(s: *const SendBuf) bool {
        if (!s.lost.isEmpty() or s.fin_lost) return true;
        if (s.sent < s.end and s.sent < s.max) return true;
        return s.fin and !s.fin_sent and s.sent == s.end;
    }

    /// Whether new data is blocked by the stream limit.
    pub fn blocked(s: *const SendBuf) bool {
        return s.sent < s.end and s.sent >= s.max;
    }

    /// Next chunk to send: retransmissions first, then new data limited by
    /// `max_len` and `conn_credit` (new bytes only). `new` reports whether the
    /// chunk extends `sent`.
    pub fn next(s: *const SendBuf, max_len: u64, conn_credit: u64) ?struct { c: Chunk, new: bool } {
        if (s.lost.first()) |r| {
            const len = @min(r.end - r.start, max_len);
            const fin = s.fin and r.start + len == s.end;
            return .{ .c = .{ .off = r.start, .len = len, .fin = fin }, .new = false };
        }
        if (s.sent < s.end and s.sent < s.max and conn_credit > 0) {
            const len = @min(s.end - s.sent, max_len, s.max - s.sent, conn_credit);
            const fin = s.fin and s.sent + len == s.end;
            return .{ .c = .{ .off = s.sent, .len = len, .fin = fin }, .new = true };
        }
        if (s.fin and s.sent == s.end and (!s.fin_sent or s.fin_lost)) {
            return .{ .c = .{ .off = s.end, .len = 0, .fin = true }, .new = false };
        }
        return null;
    }

    pub fn copy(s: *const SendBuf, off: u64, out: []u8) void {
        ringCopyOut(s.buf, off, out);
    }

    /// Records that a chunk was put in a packet.
    pub fn onSent(s: *SendBuf, c: Chunk) void {
        if (c.len > 0) s.lost.remove(c.off, c.off + c.len);
        s.sent = @max(s.sent, c.off + c.len);
        if (c.fin) {
            s.fin_sent = true;
            s.fin_lost = false;
        }
    }

    pub fn onAck(s: *SendBuf, off: u64, len: u64, fin: bool) void {
        if (fin) {
            s.fin_acked = true;
            s.fin_lost = false;
        }
        if (len == 0) return;
        const end = off + len;
        if (end <= s.acked) return;
        const lo = @max(off, s.acked);
        s.lost.remove(lo, end);
        if (lo == s.acked) {
            s.acked = end;
            // Absorb ranges that are now contiguous.
            while (s.acked_ranges.first()) |r| {
                if (r.start > s.acked) break;
                s.acked = @max(s.acked, r.end);
                s.acked_ranges.removeBelow(r.end);
            }
            return;
        }
        if (s.acked_ranges.tryAdd(lo, end) == .full) {
            // Cannot remember this ACK: resend the bytes so they are acked again.
            s.lost.addCover(lo, end);
        }
    }

    pub fn onLost(s: *SendBuf, off: u64, len: u64, fin: bool) void {
        if (fin and !s.fin_acked) s.fin_lost = true;
        const end = off + len;
        if (end <= s.acked or len == 0) return;
        var lo = @max(off, s.acked);
        // Skip parts acknowledged out of order.
        for (s.acked_ranges.items()) |r| {
            if (r.end <= lo) continue;
            if (r.start >= end) break;
            if (r.start > lo) s.lost.addCover(lo, r.start);
            lo = @max(lo, r.end);
        }
        if (lo < end) s.lost.addCover(lo, end);
    }

    pub fn allAcked(s: *const SendBuf) bool {
        return s.fin and s.fin_acked and s.acked == s.end;
    }
};

pub const RecvError = error{ FlowControl, FinalSize, Drop, OutOfMemory };

pub const RecvBuf = struct {
    buf: []u8 = &.{},
    /// Bytes below `read` were consumed by the application.
    read: u64 = 0,
    /// Highest offset received + 1 (flow-control accounting).
    highest: u64 = 0,
    /// Advertised limit.
    max: u64 = 0,
    final: ?u64 = null,
    ranges: RangeSet(16) = .{},

    pub fn deinit(r: *RecvBuf, a: std.mem.Allocator) void {
        if (r.buf.len > 0) a.free(r.buf);
        r.buf = &.{};
    }

    /// Stores a frame. Returns how much `highest` grew (new flow-control
    /// bytes). `error.Drop` asks the caller to discard the packet unacknowledged.
    pub fn insert(r: *RecvBuf, a: std.mem.Allocator, off: u64, data: []const u8, fin: bool) RecvError!u64 {
        const end = off + data.len;
        if (end > r.max) return error.FlowControl;
        if (r.final) |f| {
            if (end > f or (fin and end != f)) return error.FinalSize;
        } else if (fin) {
            if (end < r.highest) return error.FinalSize;
            r.final = end;
        }
        const grew = end -| r.highest;
        if (end <= r.read) {
            r.highest = @max(r.highest, end);
            return grew;
        }
        const lo = @max(off, r.read);
        const need: usize = @intCast(end - r.read);
        if (need > r.buf.len) {
            const hi = if (r.ranges.last()) |l| l.end else r.read;
            try ringGrow(a, &r.buf, r.read, hi, need);
        }
        switch (r.ranges.tryAdd(lo, end)) {
            .full => return error.Drop,
            .present => {},
            .added => ringCopyIn(r.buf, lo, data[@intCast(lo - off)..]),
        }
        r.highest = @max(r.highest, end);
        return grew;
    }

    /// Validates and accounts a frame for a stream whose data is discarded.
    pub fn discard(r: *RecvBuf, off: u64, len: u64, fin: bool) RecvError!u64 {
        const end = off + len;
        if (end > r.max) return error.FlowControl;
        if (r.final) |f| {
            if (end > f or (fin and end != f)) return error.FinalSize;
        } else if (fin) {
            if (end < r.highest) return error.FinalSize;
            r.final = end;
        }
        const grew = end -| r.highest;
        r.highest = @max(r.highest, end);
        r.read = r.highest;
        return grew;
    }

    /// Contiguous readable bytes at `read` (first segment of the ring).
    pub fn peek(r: *const RecvBuf) []const u8 {
        const run = r.ranges.runFrom(r.read);
        if (run == 0) return &.{};
        const pos: usize = @intCast(r.read & (r.buf.len - 1));
        return r.buf[pos..][0..@intCast(@min(run, r.buf.len - pos))];
    }

    pub fn available(r: *const RecvBuf) u64 {
        return r.ranges.runFrom(r.read);
    }

    /// Copies up to `out.len` readable bytes without consuming them.
    pub fn peekInto(r: *const RecvBuf, out: []u8) usize {
        const n: usize = @intCast(@min(r.available(), out.len));
        if (n == 0) return 0;
        ringCopyOut(r.buf, r.read, out[0..n]);
        return n;
    }

    pub fn consume(r: *RecvBuf, n: u64) void {
        r.read += n;
        r.ranges.removeBelow(r.read);
    }

    /// All data up to the final size has been consumed.
    pub fn finished(r: *const RecvBuf) bool {
        return if (r.final) |f| r.read == f else false;
    }

    pub fn finKnownAndReceived(r: *const RecvBuf) bool {
        return if (r.final) |f| r.read + r.available() == f else false;
    }
};

test "send buffer ack, loss and wrap" {
    const a = std.testing.allocator;
    var s = SendBuf{ .max = 1 << 20 };
    defer s.deinit(a);
    var data: [1000]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i);
    try std.testing.expectEqual(@as(usize, 1000), try s.write(a, &data, 4096));
    s.finish();
    const c1 = s.next(400, 1 << 20).?;
    try std.testing.expect(c1.new and c1.c.off == 0 and c1.c.len == 400 and !c1.c.fin);
    s.onSent(c1.c);
    const c2 = s.next(1000, 1 << 20).?;
    try std.testing.expect(c2.c.off == 400 and c2.c.len == 600 and c2.c.fin);
    s.onSent(c2.c);
    try std.testing.expect(s.next(1000, 1 << 20) == null);
    s.onAck(400, 600, true);
    s.onLost(0, 400, false);
    const c3 = s.next(1000, 0).?;
    try std.testing.expect(!c3.new and c3.c.off == 0 and c3.c.len == 400 and !c3.c.fin);
    var out: [400]u8 = undefined;
    s.copy(0, &out);
    try std.testing.expectEqualSlices(u8, data[0..400], &out);
    s.onSent(c3.c);
    s.onAck(0, 400, false);
    try std.testing.expect(s.allAcked());
    // Ring reuse after release wraps around.
    s.fin = false;
    s.fin_sent = false;
    s.fin_acked = false;
    try std.testing.expectEqual(@as(usize, 1000), try s.write(a, &data, 4096));
    s.copy(1000, &out);
    try std.testing.expectEqualSlices(u8, data[0..400], &out);
}

test "receive buffer reassembly and limits" {
    const a = std.testing.allocator;
    var r = RecvBuf{ .max = 100 };
    defer r.deinit(a);
    try std.testing.expectEqual(@as(u64, 15), try r.insert(a, 5, "0123456789", false));
    try std.testing.expectEqual(@as(usize, 0), r.peek().len);
    _ = try r.insert(a, 0, "abcde", false);
    try std.testing.expectEqualSlices(u8, "abcde0123456789", r.peek());
    r.consume(15);
    try std.testing.expectError(error.FlowControl, r.insert(a, 95, "0123456789", false));
    _ = try r.insert(a, 15, "xy", true);
    try std.testing.expectError(error.FinalSize, r.insert(a, 17, "z", false));
    try std.testing.expect(r.finKnownAndReceived());
    r.consume(2);
    try std.testing.expect(r.finished());
}
