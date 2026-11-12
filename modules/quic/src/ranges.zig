//! Bounded sets of disjoint half-open u64 ranges, kept ascending. Used for
//! received packet numbers (ACK generation), acknowledged and lost stream
//! data, and out-of-order receive reassembly. When full, the lowest range is
//! dropped: callers treat that as forgotten state (an extra ACK range lost or
//! a redundant retransmission), never as data delivered.
const std = @import("std");

pub const Range = struct { start: u64, end: u64 };

pub fn RangeSet(comptime cap: usize) type {
    return struct {
        const Self = @This();
        r: [cap]Range = undefined,
        n: usize = 0,

        pub fn clear(s: *Self) void {
            s.n = 0;
        }
        pub fn isEmpty(s: *const Self) bool {
            return s.n == 0;
        }
        pub fn items(s: *const Self) []const Range {
            return s.r[0..s.n];
        }
        pub fn first(s: *const Self) ?Range {
            return if (s.n == 0) null else s.r[0];
        }
        pub fn last(s: *const Self) ?Range {
            return if (s.n == 0) null else s.r[s.n - 1];
        }
        pub fn max(s: *const Self) ?u64 {
            return if (s.n == 0) null else s.r[s.n - 1].end - 1;
        }

        pub fn contains(s: *const Self, x: u64) bool {
            var i = s.n;
            while (i > 0) {
                i -= 1;
                if (x >= s.r[i].end) return false;
                if (x >= s.r[i].start) return true;
            }
            return false;
        }

        /// Adds [start, end). Returns false when the range was already fully present.
        pub fn add(s: *Self, start: u64, end: u64) bool {
            if (start >= end) return false;
            // Fast path: append or extend the highest range (in-order arrival).
            if (s.n > 0) {
                const top = &s.r[s.n - 1];
                if (start == top.end) {
                    top.end = end;
                    return true;
                }
                if (start > top.end) return s.append(start, end);
                if (start >= top.start and end <= top.end) return false;
            } else return s.append(start, end);
            // General merge: find the first range whose end >= start.
            var i: usize = 0;
            while (i < s.n and s.r[i].end < start) i += 1;
            if (i < s.n and s.r[i].start <= start and s.r[i].end >= end) return false;
            if (i == s.n or s.r[i].start > end) {
                // Insert a new range at i.
                if (s.n == cap) {
                    if (i == 0) return false;
                    std.mem.copyForwards(Range, s.r[0 .. i - 1], s.r[1..i]);
                    s.r[i - 1] = .{ .start = start, .end = end };
                    return true;
                }
                std.mem.copyBackwards(Range, s.r[i + 1 .. s.n + 1], s.r[i..s.n]);
                s.r[i] = .{ .start = start, .end = end };
                s.n += 1;
                return true;
            }
            // Merge with i and any following overlapping ranges.
            var j = i;
            var new_end = end;
            while (j < s.n and s.r[j].start <= end) : (j += 1) new_end = @max(new_end, s.r[j].end);
            s.r[i].start = @min(s.r[i].start, start);
            s.r[i].end = new_end;
            const removed = j - i - 1;
            if (removed > 0) {
                std.mem.copyForwards(Range, s.r[i + 1 .. s.n - removed], s.r[j..s.n]);
                s.n -= removed;
            }
            return true;
        }

        fn append(s: *Self, start: u64, end: u64) bool {
            if (s.n == cap) {
                std.mem.copyForwards(Range, s.r[0 .. cap - 1], s.r[1..cap]);
                s.n -= 1;
            }
            s.r[s.n] = .{ .start = start, .end = end };
            s.n += 1;
            return true;
        }

        /// Removes everything below `x`.
        pub fn removeBelow(s: *Self, x: u64) void {
            var k: usize = 0;
            while (k < s.n and s.r[k].end <= x) k += 1;
            if (k > 0) {
                std.mem.copyForwards(Range, s.r[0 .. s.n - k], s.r[k..s.n]);
                s.n -= k;
            }
            if (s.n > 0 and s.r[0].start < x) s.r[0].start = x;
        }

        /// Removes [start, end) from the set.
        pub fn remove(s: *Self, start: u64, end: u64) void {
            var i: usize = 0;
            while (i < s.n) {
                const r = s.r[i];
                if (r.end <= start or r.start >= end) {
                    i += 1;
                    continue;
                }
                if (r.start < start and r.end > end) {
                    // Split.
                    if (s.n == cap) {
                        s.r[i].end = start; // drop the upper remainder
                        return;
                    }
                    std.mem.copyBackwards(Range, s.r[i + 2 .. s.n + 1], s.r[i + 1 .. s.n]);
                    s.r[i].end = start;
                    s.r[i + 1] = .{ .start = end, .end = r.end };
                    s.n += 1;
                    return;
                }
                if (r.start < start) {
                    s.r[i].end = start;
                    i += 1;
                } else if (r.end > end) {
                    s.r[i].start = end;
                    i += 1;
                } else {
                    std.mem.copyForwards(Range, s.r[i .. s.n - 1], s.r[i + 1 .. s.n]);
                    s.n -= 1;
                }
            }
        }

        /// Length of the contiguous run starting exactly at `x`.
        pub fn runFrom(s: *const Self, x: u64) u64 {
            for (s.r[0..s.n]) |r| {
                if (r.start > x) return 0;
                if (r.end > x) return r.end - x;
            }
            return 0;
        }
    };
}

test "range set add merge remove" {
    var s = RangeSet(4){};
    try std.testing.expect(s.add(0, 5));
    try std.testing.expect(s.add(5, 8));
    try std.testing.expect(!s.add(2, 4));
    try std.testing.expect(s.add(10, 12));
    try std.testing.expect(s.add(20, 22));
    try std.testing.expect(s.add(9, 10));
    try std.testing.expectEqual(@as(usize, 3), s.n);
    try std.testing.expect(s.add(7, 21));
    try std.testing.expectEqual(@as(usize, 1), s.n);
    try std.testing.expectEqual(Range{ .start = 0, .end = 22 }, s.r[0]);
    s.remove(3, 6);
    try std.testing.expectEqual(@as(usize, 2), s.n);
    try std.testing.expect(s.contains(2) and !s.contains(3) and s.contains(6));
    s.removeBelow(7);
    try std.testing.expectEqual(Range{ .start = 7, .end = 22 }, s.r[0]);
    try std.testing.expectEqual(@as(u64, 15), s.runFrom(7));
    // Overflow drops the lowest range.
    s.clear();
    for (0..6) |i| _ = s.add(i * 10, i * 10 + 1);
    try std.testing.expectEqual(@as(usize, 4), s.n);
    try std.testing.expectEqual(@as(u64, 20), s.r[0].start);
    try std.testing.expectEqual(@as(u64, 50), s.max().?);
}
