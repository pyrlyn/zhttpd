//! Packet headers, packet numbers and header protection (RFC 9000 §17,
//! RFC 9001 §5.4), plus stateless Version Negotiation, Retry and
//! Stateless Reset datagrams.
const std = @import("std");
const wire = @import("wire.zig");
const crypto = @import("crypto.zig");

pub const version_1: u32 = 1;
pub const max_cid_len = 20;
pub const min_initial_size = 1200;

pub const LongType = enum(u2) { initial = 0, zero_rtt = 1, handshake = 2, retry = 3 };

pub const Error = error{ Malformed, Truncated, Decrypt };

pub const Cid = struct {
    len: u8 = 0,
    bytes: [max_cid_len]u8 = undefined,

    pub fn init(b: []const u8) Cid {
        var c = Cid{ .len = @intCast(b.len) };
        @memcpy(c.bytes[0..b.len], b);
        return c;
    }
    pub inline fn slice(c: *const Cid) []const u8 {
        return c.bytes[0..c.len];
    }
    pub fn eql(a: *const Cid, b: []const u8) bool {
        return std.mem.eql(u8, a.slice(), b);
    }
};

pub const Header = struct {
    long: bool,
    ty: LongType = .initial,
    version: u32 = version_1,
    dcid: []const u8,
    scid: []const u8 = &.{},
    token: []const u8 = &.{},
    /// Offset of the (protected) packet number within the datagram slice.
    pn_offset: usize,
    /// Total length of this packet in the datagram (coalescing boundary).
    len: usize,
};

/// Parses the invariant and version-1 header fields of the packet at the
/// start of `buf`. Short headers carry our fixed-length connection IDs.
pub fn parseHeader(buf: []const u8, short_dcid_len: usize) Error!Header {
    if (buf.len < 1) return error.Truncated;
    const first = buf[0];
    if (first & 0x80 == 0) {
        if (buf.len < 1 + short_dcid_len) return error.Truncated;
        return .{ .long = false, .dcid = buf[1 .. 1 + short_dcid_len], .pn_offset = 1 + short_dcid_len, .len = buf.len };
    }
    var r = wire.Reader{ .buf = buf, .pos = 1 };
    const version = r.int(u32) catch return error.Truncated;
    const dl = r.byte() catch return error.Truncated;
    if (dl > max_cid_len and version == version_1) return error.Malformed;
    const dcid = r.bytes(dl) catch return error.Truncated;
    const sl = r.byte() catch return error.Truncated;
    if (sl > max_cid_len and version == version_1) return error.Malformed;
    const scid = r.bytes(sl) catch return error.Truncated;
    var h = Header{ .long = true, .version = version, .dcid = dcid, .scid = scid, .pn_offset = 0, .len = buf.len };
    if (version != version_1) return h;
    // RFC 9000 §17.2: the fixed bit must be set in version 1 packets.
    if (first & 0x40 == 0) return error.Malformed;
    h.ty = @enumFromInt((first >> 4) & 3);
    if (h.ty == .retry) return h;
    if (h.ty == .initial) {
        const tl = r.varint() catch return error.Truncated;
        h.token = r.bytes(tl) catch return error.Truncated;
    }
    const length = r.varint() catch return error.Truncated;
    if (length > r.left()) return error.Truncated;
    h.pn_offset = r.pos;
    h.len = r.pos + length;
    return h;
}

/// RFC 9000 §A.3.
pub fn decodePn(largest: ?u64, truncated: u64, pn_len: usize) u64 {
    const expected = if (largest) |l| l + 1 else 0;
    const bits: u6 = @intCast(pn_len * 8);
    const win: u64 = @as(u64, 1) << bits;
    const hwin = win / 2;
    const mask = win - 1;
    const candidate = (expected & ~mask) | truncated;
    if (candidate + hwin <= expected and candidate < (1 << 62) - win) return candidate + win;
    if (candidate > expected + hwin and candidate >= win) return candidate - win;
    return candidate;
}

/// Shortest packet-number encoding that the peer can decode (RFC 9000 §A.2).
pub fn pnLen(pn: u64, largest_acked: ?u64) usize {
    const unacked = if (largest_acked) |l| pn - l else pn + 1;
    if (unacked < 1 << 7) return 1;
    if (unacked < 1 << 15) return 2;
    if (unacked < 1 << 23) return 3;
    return 4;
}

pub const Unprotected = struct { pn: u64, pn_len: usize };

/// Removes header protection in place. `pkt` starts at the packet's first
/// byte and spans exactly its length.
pub fn unprotect(pkt: []u8, pn_offset: usize, hp: *const crypto.Hp, largest: ?u64) Error!Unprotected {
    if (pkt.len < pn_offset + 4 + 16) return error.Truncated;
    const mask = hp.mask(pkt[pn_offset + 4 ..][0..16]);
    pkt[0] ^= mask[0] & @as(u8, if (pkt[0] & 0x80 != 0) 0x0f else 0x1f);
    const pn_len: usize = (pkt[0] & 3) + 1;
    var truncated: u64 = 0;
    for (0..pn_len) |i| {
        pkt[pn_offset + i] ^= mask[1 + i];
        truncated = (truncated << 8) | pkt[pn_offset + i];
    }
    return .{ .pn = decodePn(largest, truncated, pn_len), .pn_len = pn_len };
}

pub fn protect(pkt: []u8, pn_offset: usize, pn_len: usize, hp: *const crypto.Hp) void {
    const mask = hp.mask(pkt[pn_offset + 4 ..][0..16]);
    pkt[0] ^= mask[0] & @as(u8, if (pkt[0] & 0x80 != 0) 0x0f else 0x1f);
    for (0..pn_len) |i| pkt[pn_offset + i] ^= mask[1 + i];
}

pub inline fn writePn(out: []u8, pn: u64, pn_len: usize) void {
    var i: usize = pn_len;
    var v = pn;
    while (i > 0) {
        i -= 1;
        out[i] = @truncate(v);
        v >>= 8;
    }
}

/// Writes a version 1 long header up to and including the packet number.
/// The 2-byte length field is patched by `finishLong`.
pub fn writeLong(w: *wire.Writer, ty: LongType, dcid: []const u8, scid: []const u8, pn: u64, pn_len: usize) struct { len_pos: usize, pn_offset: usize } {
    w.byte(0xc0 | (@as(u8, @intFromEnum(ty)) << 4) | @as(u8, @intCast(pn_len - 1)));
    w.int(u32, version_1);
    w.byte(@intCast(dcid.len));
    w.bytes(dcid);
    w.byte(@intCast(scid.len));
    w.bytes(scid);
    if (ty == .initial) w.byte(0);
    const len_pos = w.pos;
    w.pos += 2;
    const pn_offset = w.pos;
    writePn(w.buf[w.pos..], pn, pn_len);
    w.pos += pn_len;
    return .{ .len_pos = len_pos, .pn_offset = pn_offset };
}

pub fn writeShort(w: *wire.Writer, dcid: []const u8, key_phase: bool, pn: u64, pn_len: usize) usize {
    w.byte(0x40 | (@as(u8, @intFromBool(key_phase)) << 2) | @as(u8, @intCast(pn_len - 1)));
    w.bytes(dcid);
    const pn_offset = w.pos;
    writePn(w.buf[w.pos..], pn, pn_len);
    w.pos += pn_len;
    return pn_offset;
}

/// RFC 9000 §17.2.1. Returns the datagram length.
pub fn versionNegotiation(out: []u8, dcid: []const u8, scid: []const u8, random: u8) usize {
    var w = wire.Writer{ .buf = out };
    w.byte(0x80 | (random & 0x7f));
    w.int(u32, 0);
    w.byte(@intCast(dcid.len));
    w.bytes(dcid);
    w.byte(@intCast(scid.len));
    w.bytes(scid);
    w.int(u32, version_1);
    // Reserved version (RFC 9000 §15) exercises client version handling.
    w.int(u32, 0x1a2a3a4a);
    return w.pos;
}

const retry_key = [16]u8{ 0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a, 0x1d, 0x76, 0x6b, 0x54, 0xe3, 0x68, 0xc8, 0x4e };
const retry_nonce = [12]u8{ 0x46, 0x15, 0x99, 0xd3, 0x5d, 0x63, 0x2b, 0xf2, 0x23, 0x98, 0x25, 0xbb };

fn retryTag(odcid: []const u8, pkt: []const u8) [16]u8 {
    var pseudo: [1 + max_cid_len + 256 + 64]u8 = undefined;
    pseudo[0] = @intCast(odcid.len);
    @memcpy(pseudo[1..][0..odcid.len], odcid);
    @memcpy(pseudo[1 + odcid.len ..][0..pkt.len], pkt);
    var tag: [16]u8 = undefined;
    std.crypto.aead.aes_gcm.Aes128Gcm.encrypt(&.{}, &tag, &.{}, pseudo[0 .. 1 + odcid.len + pkt.len], retry_nonce, retry_key);
    return tag;
}

/// RFC 9000 §17.2.5 Retry packet with integrity tag (RFC 9001 §5.8).
pub fn retry(out: []u8, dcid: []const u8, scid: []const u8, odcid: []const u8, token: []const u8, random: u8) usize {
    var w = wire.Writer{ .buf = out };
    w.byte(0xf0 | (random & 0x0f));
    w.int(u32, version_1);
    w.byte(@intCast(dcid.len));
    w.bytes(dcid);
    w.byte(@intCast(scid.len));
    w.bytes(scid);
    w.bytes(token);
    const tag = retryTag(odcid, out[0..w.pos]);
    w.bytes(&tag);
    return w.pos;
}

/// Stateless reset (RFC 9000 §10.3): random bits shaped like a short header,
/// ending in the token. `len` must be smaller than the triggering datagram.
pub fn statelessReset(out: []u8, len: usize, token: *const [16]u8, random: []const u8) usize {
    std.debug.assert(len >= 21 and len <= out.len);
    @memcpy(out[0 .. len - 16], random[0 .. len - 16]);
    out[0] = (out[0] & 0x3f) | 0x40;
    @memcpy(out[len - 16 .. len], token);
    return len;
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "packet number decoding (RFC 9000 A.3)" {
    try std.testing.expectEqual(@as(u64, 0xa82f9b32), decodePn(0xa82f30ea, 0x9b32, 2));
    try std.testing.expectEqual(@as(u64, 0), decodePn(null, 0, 1));
    try std.testing.expectEqual(@as(u64, 256), decodePn(255, 0, 1));
    try std.testing.expectEqual(@as(usize, 2), pnLen(0xac5c02, 0xabe8b3));
    try std.testing.expectEqual(@as(usize, 3), pnLen(0xace8fe, 0xabe8b3));
}

test "RFC 9001 A.4 retry integrity" {
    var out: [128]u8 = undefined;
    const n = retry(&out, &.{}, &hex("f067a5502a4262b5"), &hex("8394c8f03e515708"), "token", 0xf);
    try std.testing.expectEqualSlices(u8, &hex("ff000000010008f067a5502a4262b5746f6b656e04a265ba2eff4d829058fb3f0f2496ba"), out[0..n]);
}

test "RFC 9001 A.2/A.3 client and server initial protection" {
    var cs: [32]u8 = undefined;
    var ss: [32]u8 = undefined;
    const dcid = hex("8394c8f03e515708");
    crypto.initialSecrets(&dcid, &cs, &ss);
    // A.3 server initial: header and ACK + CRYPTO payload.
    var keys = try crypto.Keys.init(.aes128gcm, &ss, true);
    defer keys.deinit();
    const payload = hex("02000000000600405a020000560303eefce7f7b37ba1d1632e96677825ddf73988cfc79825df566dc5430b9a045a1200130100002e00330024001d00209d3c940d89690b84d08a60993c144eca684d1081287c834d5311bcf32bb9da1a002b00020304");
    var pkt: [256]u8 = undefined;
    var w = wire.Writer{ .buf = &pkt };
    const h = writeLong(&w, .initial, &.{}, &hex("f067a5502a4262b5"), 1, 2);
    w.bytes(&payload);
    std.mem.writeInt(u16, pkt[h.len_pos..][0..2], @intCast((w.pos - h.pn_offset + 16) | 0x4000), .big);
    keys.seal(1, pkt[0..h.pn_offset + 2], pkt[h.pn_offset + 2 .. w.pos], pkt[w.pos..][0..16]);
    w.pos += 16;
    protect(pkt[0..w.pos], h.pn_offset, 2, &keys.hp);
    const expected = hex("cf000000010008f067a5502a4262b5004075c0d95a482cd0991cd25b0aac406a5816b6394100f37a1c69797554780bb38cc5a99f5ede4cf73c3ec2493a1839b3dbcba3f6ea46c5b7684df3548e7ddeb9c3bf9c73cc3f3bded74b562bfb19fb84022f8ef4cdd93795d77d06edbb7aaf2f58891850abbdca3d20398c276456cbc42158407dd074ee");
    try std.testing.expectEqualSlices(u8, &expected, pkt[0..w.pos]);
    // Round trip through header parsing and unprotection.
    var rx = try crypto.Keys.init(.aes128gcm, &ss, false);
    defer rx.deinit();
    const ph = try parseHeader(pkt[0..w.pos], 8);
    try std.testing.expect(ph.long and ph.ty == .initial and ph.len == w.pos);
    const u = try unprotect(pkt[0..ph.len], ph.pn_offset, &rx.hp, null);
    try std.testing.expectEqual(@as(u64, 1), u.pn);
    const body_start = ph.pn_offset + u.pn_len;
    try rx.open(u.pn, pkt[0..body_start], pkt[body_start .. ph.len - 16], pkt[ph.len - 16 ..][0..16].*);
    try std.testing.expectEqualSlices(u8, &payload, pkt[body_start .. ph.len - 16]);
}
