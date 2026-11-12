//! Variable-length integers (RFC 9000 §16) and bounded readers/writers.
const std = @import("std");

pub const Error = error{Truncated};
pub const max_varint: u64 = (1 << 62) - 1;

pub fn varintLen(v: u64) usize {
    if (v < 64) return 1;
    if (v < 16384) return 2;
    if (v < 1 << 30) return 4;
    return 8;
}

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub inline fn left(r: *const Reader) usize {
        return r.buf.len - r.pos;
    }
    pub inline fn done(r: *const Reader) bool {
        return r.pos >= r.buf.len;
    }
    pub inline fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.buf.len) return error.Truncated;
        r.pos += 1;
        return r.buf[r.pos - 1];
    }
    pub inline fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.buf.len - r.pos) return error.Truncated;
        r.pos += n;
        return r.buf[r.pos - n .. r.pos];
    }
    pub inline fn int(r: *Reader, comptime T: type) Error!T {
        const b = try r.bytes(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .big);
    }
    pub inline fn varint(r: *Reader) Error!u64 {
        if (r.pos >= r.buf.len) return error.Truncated;
        const first = r.buf[r.pos];
        const len = @as(usize, 1) << @intCast(first >> 6);
        if (len > r.buf.len - r.pos) return error.Truncated;
        var v: u64 = first & 0x3f;
        for (r.buf[r.pos + 1 .. r.pos + len]) |b| v = (v << 8) | b;
        r.pos += len;
        return v;
    }
};

pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    pub inline fn left(w: *const Writer) usize {
        return w.buf.len - w.pos;
    }
    pub inline fn byte(w: *Writer, b: u8) void {
        w.buf[w.pos] = b;
        w.pos += 1;
    }
    pub inline fn bytes(w: *Writer, b: []const u8) void {
        @memcpy(w.buf[w.pos..][0..b.len], b);
        w.pos += b.len;
    }
    pub inline fn int(w: *Writer, comptime T: type, v: T) void {
        std.mem.writeInt(T, w.buf[w.pos..][0..@sizeOf(T)], v, .big);
        w.pos += @sizeOf(T);
    }
    pub inline fn varint(w: *Writer, v: u64) void {
        w.pos += putVarint(w.buf[w.pos..], v);
    }
    /// Fixed-width encoding, used for length fields patched after the body.
    pub inline fn varintWidth(w: *Writer, v: u64, width: usize) void {
        putVarintWidth(w.buf[w.pos..][0..width], v);
        w.pos += width;
    }
};

pub inline fn putVarint(out: []u8, v: u64) usize {
    if (v < 64) {
        out[0] = @intCast(v);
        return 1;
    }
    if (v < 16384) {
        std.mem.writeInt(u16, out[0..2], @intCast(v | 0x4000), .big);
        return 2;
    }
    if (v < 1 << 30) {
        std.mem.writeInt(u32, out[0..4], @intCast(v | 0x8000_0000), .big);
        return 4;
    }
    std.mem.writeInt(u64, out[0..8], v | 0xc000_0000_0000_0000, .big);
    return 8;
}

pub inline fn putVarintWidth(out: []u8, v: u64, width: usize) void {
    switch (width) {
        1 => out[0] = @intCast(v),
        2 => std.mem.writeInt(u16, out[0..2], @intCast(v | 0x4000), .big),
        4 => std.mem.writeInt(u32, out[0..4], @intCast(v | 0x8000_0000), .big),
        else => std.mem.writeInt(u64, out[0..8], v | 0xc000_0000_0000_0000, .big),
    }
}

test "varint round trip (RFC 9000 A.1)" {
    const cases = [_]struct { hex: []const u8, v: u64 }{
        .{ .hex = "c2197c5eff14e88c", .v = 151288809941952652 },
        .{ .hex = "9d7f3e7d", .v = 494878333 },
        .{ .hex = "7bbd", .v = 15293 },
        .{ .hex = "25", .v = 37 },
        .{ .hex = "4025", .v = 37 },
    };
    for (cases) |c| {
        var b: [8]u8 = undefined;
        const raw = try std.fmt.hexToBytes(&b, c.hex);
        var r = Reader{ .buf = raw };
        try std.testing.expectEqual(c.v, try r.varint());
        try std.testing.expect(r.done());
    }
    var out: [8]u8 = undefined;
    for ([_]u64{ 0, 63, 64, 16383, 16384, (1 << 30) - 1, 1 << 30, max_varint }) |v| {
        const n = putVarint(&out, v);
        try std.testing.expectEqual(varintLen(v), n);
        var r = Reader{ .buf = out[0..n] };
        try std.testing.expectEqual(v, try r.varint());
    }
    var r = Reader{ .buf = &[_]u8{0x40} };
    try std.testing.expectError(error.Truncated, r.varint());
}
