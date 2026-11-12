//! QPACK (RFC 9204) restricted to the static table: the decoder advertises
//! a dynamic table capacity of 0, so field sections reference only static
//! entries and literals. The encoder never uses the dynamic table or
//! Huffman coding.
const std = @import("std");
const tables = @import("qpack_tables.zig");

pub const Field = tables.Field;
pub const static_table = tables.static_table;

pub const Error = error{ Decompression, NoSpace };

/// QPACK_DECOMPRESSION_FAILED.
pub const decompression_failed: u64 = 0x200;

// ---------------------------------------------------------------------------
// Prefixed integers (RFC 7541 §5.1)

pub fn readInt(buf: []const u8, pos: *usize, comptime prefix: u4) Error!u64 {
    if (pos.* >= buf.len) return error.Decompression;
    const mask: u8 = (1 << prefix) - 1;
    var v: u64 = buf[pos.*] & mask;
    pos.* += 1;
    if (v < mask) return v;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= buf.len or shift > 56) return error.Decompression;
        const b = buf[pos.*];
        pos.* += 1;
        v += @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        shift += 7;
    }
}

pub fn writeInt(out: []u8, pos: *usize, comptime prefix: u4, flags: u8, v: u64) Error!void {
    const mask: u8 = (1 << prefix) - 1;
    if (pos.* >= out.len) return error.NoSpace;
    if (v < mask) {
        out[pos.*] = flags | @as(u8, @intCast(v));
        pos.* += 1;
        return;
    }
    out[pos.*] = flags | mask;
    pos.* += 1;
    var r = v - mask;
    while (r >= 128) : (r >>= 7) {
        if (pos.* >= out.len) return error.NoSpace;
        out[pos.*] = @as(u8, @intCast(r & 0x7f)) | 0x80;
        pos.* += 1;
    }
    if (pos.* >= out.len) return error.NoSpace;
    out[pos.*] = @intCast(r);
    pos.* += 1;
}

// ---------------------------------------------------------------------------
// Huffman decoding (RFC 7541 Appendix B; the code is canonical)

const fast_bits = 12;
const fast_mask: u64 = (1 << fast_bits) - 1;

/// Fast-table entry: up to two whole symbols in the next `fast_bits` bits.
/// sym1 | sym2 << 8 | len1 << 16 | len2 << 21 | count << 26.
const FastEntry = u32;

const Huff = struct {
    fast: [1 << fast_bits]FastEntry,
    /// Canonical decoding for longer codes.
    first: [31]u32,
    count: [31]u16,
    offset: [31]u16,
    syms: [257]u16,
};

const huff: Huff = blk: {
    @setEvalBranchQuota(400_000);
    var h: Huff = undefined;
    h.first = @splat(0);
    h.count = @splat(0);
    h.offset = @splat(0);
    var n: u16 = 0;
    for (1..31) |len| {
        h.offset[len] = n;
        for (0..257) |s| if (tables.huff_lens[s] == len) {
            if (h.count[len] == 0) h.first[len] = tables.huff_codes[s];
            h.syms[n] = s;
            n += 1;
            h.count[len] += 1;
        };
    }
    // One symbol per prefix first: sym | len << 8 (len 0 = no short code).
    var one: [1 << fast_bits]u16 = @splat(0);
    for (0..256) |s| {
        const len: u16 = tables.huff_lens[s];
        if (len > fast_bits) continue;
        const base = tables.huff_codes[s] << (fast_bits - len);
        for (0..(1 << (fast_bits - len))) |k| one[base + k] = @as(u16, s) | (len << 8);
    }
    for (0..(1 << fast_bits)) |p| {
        const e1: u32 = one[p];
        const len1: u32 = e1 >> 8;
        if (len1 == 0) {
            h.fast[p] = 0;
            continue;
        }
        var e: u32 = (e1 & 0xff) | (len1 << 16) | (1 << 26);
        // The remaining bits, zero-padded, select a second symbol; it counts
        // only if its whole code fits in what is left.
        const e2: u32 = one[(p << len1) & ((1 << fast_bits) - 1)];
        const len2: u32 = e2 >> 8;
        if (len2 != 0 and len1 + len2 <= fast_bits) e = (e & ~@as(u32, 3 << 26)) | ((e2 & 0xff) << 8) | (len2 << 21) | (2 << 26);
        h.fast[p] = e;
    }
    break :blk h;
};

/// Decodes a Huffman string into `out`; returns the decoded length.
pub fn huffDecode(in: []const u8, out: []u8) Error!usize {
    var acc: u64 = 0;
    var nbits: u32 = 0;
    var i: usize = 0;
    var o: usize = 0;
    while (true) {
        if (nbits < 32) {
            if (in.len - i >= 4) {
                acc = (acc << 32) | std.mem.readInt(u32, in[i..][0..4], .big);
                i += 4;
                nbits += 32;
            } else while (nbits <= 56 and i < in.len) : (i += 1) {
                acc = (acc << 8) | in[i];
                nbits += 8;
            }
        }
        if (nbits == 0) break;
        // Fast path: a full table window and room for two symbols, so both
        // are taken as the entry says without tail checks.
        if (nbits >= fast_bits and out.len - o >= 2) {
            const e = huff.fast[@intCast((acc >> @intCast(nbits - fast_bits)) & fast_mask)];
            if (e != 0) {
                out[o] = @truncate(e);
                out[o + 1] = @truncate(e >> 8);
                o += e >> 26;
                nbits -= ((e >> 16) & 0x1f) + ((e >> 21) & 0x1f);
                continue;
            }
        }
        const peek: usize = @intCast(if (nbits >= fast_bits)
            (acc >> @intCast(nbits - fast_bits)) & fast_mask
        else
            (acc << @intCast(fast_bits - nbits)) & fast_mask);
        const e = huff.fast[peek];
        const len1: u32 = (e >> 16) & 0x1f;
        if (len1 != 0 and len1 <= nbits) {
            if (o >= out.len) return error.NoSpace;
            out[o] = @truncate(e);
            o += 1;
            nbits -= len1;
            const len2: u32 = (e >> 21) & 0x1f;
            if (e >> 26 == 2 and len2 <= nbits) {
                if (o >= out.len) return error.NoSpace;
                out[o] = @truncate(e >> 8);
                o += 1;
                nbits -= len2;
            }
            continue;
        }
        // Long code, or the tail of the string.
        var code: u32 = 0;
        var len: u32 = 0;
        var found = false;
        while (len < 30 and len < nbits) {
            len += 1;
            code = (code << 1) | @as(u32, @intCast((acc >> @intCast(nbits - len)) & 1));
            if (huff.count[len] != 0 and code >= huff.first[len] and code - huff.first[len] < huff.count[len]) {
                const sym = huff.syms[huff.offset[len] + (code - huff.first[len])];
                if (sym == 256) return error.Decompression; // EOS in the string
                if (o >= out.len) return error.NoSpace;
                out[o] = @intCast(sym);
                o += 1;
                nbits -= len;
                found = true;
                break;
            }
        }
        if (found) continue;
        // Padding: fewer than 8 bits, all ones (a prefix of EOS).
        if (i < in.len or nbits >= 8) return error.Decompression;
        const pad_mask = (@as(u64, 1) << @intCast(nbits)) - 1;
        if (acc & pad_mask != pad_mask) return error.Decompression;
        break;
    }
    return o;
}

// ---------------------------------------------------------------------------
// Field section decoding

/// Iterates over the field lines of one encoded field section. Huffman
/// strings are decoded into `scratch`, which must hold at least 8/5 of the
/// section size.
pub const Decoder = struct {
    buf: []const u8,
    pos: usize = 0,
    scratch: []u8,
    used: usize = 0,

    pub fn init(block: []const u8, scratch: []u8) Error!Decoder {
        var d = Decoder{ .buf = block, .scratch = scratch };
        const ric = try readInt(block, &d.pos, 8);
        if (ric != 0) return error.Decompression; // no dynamic table
        _ = try readInt(block, &d.pos, 7); // sign + delta base: irrelevant
        return d;
    }

    fn string(d: *Decoder, comptime prefix: u4) Error![]const u8 {
        if (d.pos >= d.buf.len) return error.Decompression;
        const h = d.buf[d.pos] & (@as(u8, 1) << prefix) != 0;
        const len = try readInt(d.buf, &d.pos, prefix);
        if (len > d.buf.len - d.pos) return error.Decompression;
        const raw = d.buf[d.pos..][0..@intCast(len)];
        d.pos += @intCast(len);
        if (!h) return raw;
        const n = try huffDecode(raw, d.scratch[d.used..]);
        const s = d.scratch[d.used..][0..n];
        d.used += n;
        return s;
    }

    pub fn next(d: *Decoder) Error!?Field {
        if (d.pos >= d.buf.len) return null;
        const b = d.buf[d.pos];
        if (b & 0x80 != 0) {
            // Indexed field line; T must be static.
            if (b & 0x40 == 0) return error.Decompression;
            const idx = try readInt(d.buf, &d.pos, 6);
            if (idx >= static_table.len) return error.Decompression;
            return static_table[@intCast(idx)];
        }
        if (b & 0x40 != 0) {
            // Literal with name reference.
            if (b & 0x10 == 0) return error.Decompression;
            const idx = try readInt(d.buf, &d.pos, 4);
            if (idx >= static_table.len) return error.Decompression;
            const value = try d.string(7);
            return .{ .name = static_table[@intCast(idx)].name, .value = value };
        }
        if (b & 0x20 != 0) {
            // Literal with literal name.
            const name = try d.string(3);
            const value = try d.string(7);
            return .{ .name = name, .value = value };
        }
        // Post-base forms reference the dynamic table.
        return error.Decompression;
    }
};

// ---------------------------------------------------------------------------
// Field section encoding

const ValueEntry = struct { []const u8, u8 };

/// Static-table entries of one field name: the first index (for name
/// references) and every (value, index) pair with that name.
const NameInfo = struct { name: []const u8, first: u8, values: []const ValueEntry };

const name_infos = blk: {
    @setEvalBranchQuota(200_000);
    var names: [static_table.len][]const u8 = undefined;
    var n: usize = 0;
    for (static_table) |f| {
        var seen = false;
        for (names[0..n]) |x| if (std.mem.eql(u8, x, f.name)) {
            seen = true;
        };
        if (!seen) {
            names[n] = f.name;
            n += 1;
        }
    }
    var list: [n]NameInfo = undefined;
    for (names[0..n], 0..) |name, k| {
        var vals: [static_table.len]ValueEntry = undefined;
        var m: usize = 0;
        var first: ?u8 = null;
        for (static_table, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) {
            if (first == null) first = i;
            vals[m] = .{ f.value, i };
            m += 1;
        };
        const final = vals[0..m].*;
        list[k] = .{ .name = name, .first = first.?, .values = &final };
    }
    break :blk list;
};

const max_name_len = blk: {
    var m: usize = 0;
    for (name_infos) |ni| m = @max(m, ni.name.len);
    break :blk m;
};

/// `a.len == b.len`; compares 8 bytes at a time against a constant.
inline fn eqlConst(a: []const u8, comptime b: []const u8) bool {
    if (b.len < 8) {
        inline for (b, 0..) |ch, i| if (a[i] != ch) return false;
        return true;
    }
    comptime var i = 0;
    inline while (i + 8 <= b.len) : (i += 8) {
        if (std.mem.readInt(u64, a[i..][0..8], .little) != comptime std.mem.readInt(u64, b[i..][0..8], .little)) return false;
    }
    if (b.len % 8 != 0) {
        const t = b.len - 8;
        if (std.mem.readInt(u64, a[t..][0..8], .little) != comptime std.mem.readInt(u64, b[t..][0..8], .little)) return false;
    }
    return true;
}

const Lookup = struct { first: u8, exact: ?u8 };

/// Static-table name index of `name` and, if present, the exact entry for
/// (`name`, `value`).
fn lookup(name: []const u8, value: []const u8) ?Lookup {
    @setEvalBranchQuota(100_000);
    switch (name.len) {
        inline 1...max_name_len => |len| {
            inline for (name_infos) |ni| {
                if (ni.name.len == len and eqlConst(name, ni.name)) {
                    var exact: ?u8 = null;
                    inline for (ni.values) |v| {
                        if (exact == null and value.len == v[0].len and eqlConst(value, v[0])) exact = v[1];
                    }
                    return .{ .first = ni.first, .exact = exact };
                }
            }
            return null;
        },
        else => return null,
    }
}

fn exactIndex(name: []const u8, value: []const u8) ?u8 {
    const l = lookup(name, value) orelse return null;
    return l.exact;
}

pub const Encoder = struct {
    out: []u8,
    pos: usize = 0,

    pub fn init(out: []u8) Error!Encoder {
        if (out.len < 2) return error.NoSpace;
        out[0] = 0; // required insert count
        out[1] = 0; // delta base
        return .{ .out = out, .pos = 2 };
    }

    fn raw(e: *Encoder, comptime prefix: u4, flags: u8, s: []const u8) Error!void {
        try writeInt(e.out, &e.pos, prefix, flags, s.len);
        if (s.len > e.out.len - e.pos) return error.NoSpace;
        @memcpy(e.out[e.pos..][0..s.len], s);
        e.pos += s.len;
    }

    /// `name` must be lowercase.
    pub fn field(e: *Encoder, name: []const u8, value: []const u8) Error!void {
        if (lookup(name, value)) |l| {
            if (l.exact) |idx| return writeInt(e.out, &e.pos, 6, 0xc0, idx);
            try writeInt(e.out, &e.pos, 4, 0x50, l.first);
            return e.raw(7, 0, value);
        }
        try e.raw(3, 0x20, name);
        try e.raw(7, 0, value);
    }

    pub fn status(e: *Encoder, code: u16) Error!void {
        const idx: ?u8 = switch (code) {
            103 => 24,
            200 => 25,
            304 => 26,
            404 => 27,
            503 => 28,
            100 => 63,
            204 => 64,
            206 => 65,
            302 => 66,
            400 => 67,
            403 => 68,
            421 => 69,
            425 => 70,
            500 => 71,
            else => null,
        };
        if (idx) |i| return writeInt(e.out, &e.pos, 6, 0xc0, i);
        var digits: [3]u8 = undefined;
        digits[0] = @intCast('0' + code / 100 % 10);
        digits[1] = @intCast('0' + code / 10 % 10);
        digits[2] = @intCast('0' + code % 10);
        try writeInt(e.out, &e.pos, 4, 0x50, 24);
        try e.raw(7, 0, &digits);
    }

    pub fn bytes(e: *const Encoder) []const u8 {
        return e.out[0..e.pos];
    }
};

// ---------------------------------------------------------------------------

test "prefixed integers (RFC 7541 C.1)" {
    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    try writeInt(&buf, &pos, 5, 0, 1337);
    try std.testing.expectEqualSlices(u8, &.{ 0x1f, 0x9a, 0x0a }, buf[0..pos]);
    var rp: usize = 0;
    try std.testing.expectEqual(@as(u64, 1337), try readInt(buf[0..pos], &rp, 5));
    try std.testing.expectError(error.Decompression, readInt(&.{ 0x1f, 0x9a }, &rp, 5));
}

test "huffman decode (RFC 7541 C.4.1)" {
    var out: [64]u8 = undefined;
    const enc = [_]u8{ 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff };
    const n = try huffDecode(&enc, &out);
    try std.testing.expectEqualStrings("www.example.com", out[0..n]);
    const enc2 = [_]u8{ 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf };
    try std.testing.expectEqualStrings("no-cache", out[0..try huffDecode(&enc2, &out)]);
    const enc3 = [_]u8{ 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f };
    try std.testing.expectEqualStrings("custom-key", out[0..try huffDecode(&enc3, &out)]);
    // Long codes: "\x00" is 13 bits (0x1ff8), padded with ones.
    const enc4 = [_]u8{ 0xff, 0xc7 };
    try std.testing.expectEqualSlices(u8, &.{0}, out[0..try huffDecode(&enc4, &out)]);
    // Padding longer than 7 bits / not all ones.
    try std.testing.expectError(error.Decompression, huffDecode(&.{ 0xf1, 0xff }, &out));
    try std.testing.expectError(error.Decompression, huffDecode(&.{0x00}, &out));
}

test "field section round trip" {
    var buf: [256]u8 = undefined;
    var e = try Encoder.init(&buf);
    try e.status(200);
    try e.status(418);
    try e.field("content-type", "text/html; charset=utf-8");
    try e.field("content-length", "612");
    try e.field("x-custom", "v");
    var scratch: [256]u8 = undefined;
    var d = try Decoder.init(e.bytes(), &scratch);
    const want = [_]Field{
        .{ .name = ":status", .value = "200" },
        .{ .name = ":status", .value = "418" },
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "content-length", .value = "612" },
        .{ .name = "x-custom", .value = "v" },
    };
    for (want) |w| {
        const f = (try d.next()).?;
        try std.testing.expectEqualStrings(w.name, f.name);
        try std.testing.expectEqualStrings(w.value, f.value);
    }
    try std.testing.expect(try d.next() == null);
}

test "decoder rejects dynamic references" {
    var scratch: [16]u8 = undefined;
    try std.testing.expectError(error.Decompression, Decoder.init(&.{ 0x01, 0x00 }, &scratch));
    var d = try Decoder.init(&.{ 0x00, 0x00, 0x80 }, &scratch);
    try std.testing.expectError(error.Decompression, d.next());
    var d2 = try Decoder.init(&.{ 0x00, 0x00, 0x10 }, &scratch);
    try std.testing.expectError(error.Decompression, d2.next());
}

test "decode a Huffman-coded request" {
    // :method GET, :scheme https, :path /index.html (huffman), :authority example.com (literal)
    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    buf[0] = 0;
    buf[1] = 0;
    pos = 2;
    try writeInt(&buf, &pos, 6, 0xc0, 17);
    try writeInt(&buf, &pos, 6, 0xc0, 23);
    // :path, huffman "/index.html" = 60 d5 48 5f 2b ce 9a 68 ... use "no-cache" instead
    try writeInt(&buf, &pos, 4, 0x50, 1);
    const hv = [_]u8{ 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf };
    try writeInt(&buf, &pos, 7, 0x80, hv.len);
    @memcpy(buf[pos..][0..hv.len], &hv);
    pos += hv.len;
    var scratch: [64]u8 = undefined;
    var d = try Decoder.init(buf[0..pos], &scratch);
    try std.testing.expectEqualStrings("GET", (try d.next()).?.value);
    try std.testing.expectEqualStrings("https", (try d.next()).?.value);
    const p = (try d.next()).?;
    try std.testing.expectEqualStrings(":path", p.name);
    try std.testing.expectEqualStrings("no-cache", p.value);
}

test "exact static index" {
    const long: [200]u8 = @splat('v');
    for (static_table, 0..) |f, i| try std.testing.expectEqual(@as(?u8, @intCast(i)), exactIndex(f.name, f.value));
    try std.testing.expectEqual(@as(?u8, 52), exactIndex("content-type", "text/html; charset=utf-8"));
    try std.testing.expectEqual(@as(?u8, null), exactIndex("content-type", "text/x-unknown"));
    try std.testing.expectEqual(@as(?u8, null), exactIndex("x-long", &long));
}

fn testHuffEncode(in: []const u8, out: []u8) usize {
    var acc: u64 = 0;
    var nbits: u6 = 0;
    var o: usize = 0;
    for (in) |ch| {
        const len: u6 = @intCast(tables.huff_lens[ch]);
        acc = (acc << len) | tables.huff_codes[ch];
        nbits += len;
        while (nbits >= 8) {
            nbits -= 8;
            out[o] = @truncate(acc >> nbits);
            o += 1;
        }
    }
    if (nbits > 0) {
        out[o] = @truncate((acc << (8 - nbits)) | ((@as(u64, 1) << (8 - nbits)) - 1));
        o += 1;
    }
    return o;
}

test "huffman decode round trip" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var src: [300]u8 = undefined;
    var enc: [1200]u8 = undefined;
    var dec: [300]u8 = undefined;
    for (0..2000) |round| {
        const n = rnd.uintLessThan(usize, src.len + 1);
        for (src[0..n]) |*b| b.* = if (round % 2 == 0) rnd.int(u8) else "abcdefghijklmnopqrstuvwxyz0123456789/.-:"[rnd.uintLessThan(usize, 40)];
        const m = testHuffEncode(src[0..n], &enc);
        const k = try huffDecode(enc[0..m], &dec);
        try std.testing.expectEqualSlices(u8, src[0..n], dec[0..k]);
        if (n > 0) try std.testing.expectError(error.NoSpace, huffDecode(enc[0..m], dec[0 .. n - 1]));
    }
}
