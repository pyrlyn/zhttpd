//! QUIC packet protection (RFC 9001 §5): key derivation, AEAD and header
//! protection. AEAD state is keyed once per epoch and direction, so sealing a
//! packet performs no key schedule or provider lookup.
const std = @import("std");
const build_options = @import("zquic_options");
const hkdf = std.crypto.kdf.hkdf;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HmacSha384 = std.crypto.auth.hmac.sha2.HmacSha384;
const Hkdf256 = hkdf.Hkdf(HmacSha256);
const Hkdf384 = hkdf.Hkdf(HmacSha384);
const Aes128 = std.crypto.core.aes.Aes128;
const Aes256 = std.crypto.core.aes.Aes256;
const Ghash = std.crypto.onetimeauth.Ghash;
const ChaChaPoly = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const ChaCha20 = std.crypto.stream.chacha.ChaCha20IETF;

pub const tag_len = 16;
pub const max_secret = 48;

pub const Suite = enum(u8) {
    aes128gcm,
    aes256gcm,
    chacha20,

    pub fn fromTls(id: u16) ?Suite {
        return switch (id) {
            0x1301 => .aes128gcm,
            0x1302 => .aes256gcm,
            0x1303 => .chacha20,
            else => null,
        };
    }
    pub fn keyLen(s: Suite) usize {
        return if (s == .aes128gcm) 16 else 32;
    }
    pub fn secretLen(s: Suite) usize {
        return if (s == .aes256gcm) 48 else 32;
    }
    /// RFC 9001 §6.6: confidentiality limit per key.
    pub fn confidentialityLimit(s: Suite) u64 {
        return if (s == .chacha20) std.math.maxInt(u62) else 1 << 23;
    }
};

pub const Error = error{ Decrypt, Unsupported };

/// TLS 1.3 HKDF-Expand-Label with an empty context.
pub fn expandLabel(suite: Suite, out: []u8, secret: []const u8, comptime label: []const u8) void {
    const full = "tls13 " ++ label;
    var info: [2 + 1 + full.len + 1]u8 = undefined;
    std.mem.writeInt(u16, info[0..2], @intCast(out.len), .big);
    info[2] = full.len;
    @memcpy(info[3..][0..full.len], full);
    info[3 + full.len] = 0;
    if (suite == .aes256gcm) {
        var prk: [48]u8 = undefined;
        @memcpy(&prk, secret[0..48]);
        Hkdf384.expand(out, &info, prk);
    } else {
        var prk: [32]u8 = undefined;
        @memcpy(&prk, secret[0..32]);
        Hkdf256.expand(out, &info, prk);
    }
}

pub const initial_salt_v1 = [_]u8{ 0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a };

/// Client and server Initial secrets for a client-chosen destination CID.
pub fn initialSecrets(dcid: []const u8, client: *[32]u8, server: *[32]u8) void {
    const initial = Hkdf256.extract(&initial_salt_v1, dcid);
    expandLabel(.aes128gcm, client, &initial, "client in");
    expandLabel(.aes128gcm, server, &initial, "server in");
}

/// AES-GCM keyed once. The two-pass CTR + aggregated GHASH implementation is
/// Zig's standard one; only the per-packet key expansion is removed.
fn ZigGcm(comptime Aes: type) type {
    return struct {
        const Self = @This();
        aes: @TypeOf(Aes.initEnc(undefined)),
        h: [16]u8,

        fn init(key: []const u8) Self {
            var k: [Aes.key_bits / 8]u8 = undefined;
            @memcpy(&k, key[0..k.len]);
            const aes = Aes.initEnc(k);
            var h: [16]u8 = undefined;
            aes.encrypt(&h, &@as([16]u8, @splat(0)));
            return .{ .aes = aes, .h = h };
        }
        fn seal(self: *const Self, nonce: [12]u8, ad: []const u8, data: []u8, tag: *[16]u8) void {
            var j: [16]u8 = undefined;
            j[0..12].* = nonce;
            std.mem.writeInt(u32, j[12..16], 1, .big);
            var t: [16]u8 = undefined;
            self.aes.encrypt(&t, &j);
            std.mem.writeInt(u32, j[12..16], 2, .big);
            std.crypto.core.modes.ctr(@TypeOf(self.aes), self.aes, data, data, j, .big);
            self.mac(ad, data, tag);
            for (tag, t) |*x, y| x.* ^= y;
        }
        fn open(self: *const Self, nonce: [12]u8, ad: []const u8, data: []u8, tag: [16]u8) Error!void {
            var j: [16]u8 = undefined;
            j[0..12].* = nonce;
            std.mem.writeInt(u32, j[12..16], 1, .big);
            var t: [16]u8 = undefined;
            self.aes.encrypt(&t, &j);
            var computed: [16]u8 = undefined;
            self.mac(ad, data, &computed);
            for (&computed, t) |*x, y| x.* ^= y;
            if (!std.crypto.timing_safe.eql([16]u8, computed, tag)) return error.Decrypt;
            std.mem.writeInt(u32, j[12..16], 2, .big);
            std.crypto.core.modes.ctr(@TypeOf(self.aes), self.aes, data, data, j, .big);
        }
        fn mac(self: *const Self, ad: []const u8, c: []const u8, out: *[16]u8) void {
            const blocks = (ad.len + 15) / 16 + (c.len + 15) / 16 + 1;
            var g = Ghash.initForBlockCount(&self.h, blocks);
            g.update(ad);
            g.pad();
            g.update(c);
            g.pad();
            var final: [16]u8 = undefined;
            std.mem.writeInt(u64, final[0..8], @as(u64, ad.len) * 8, .big);
            std.mem.writeInt(u64, final[8..16], @as(u64, c.len) * 8, .big);
            g.update(&final);
            g.final(out);
        }
    };
}

// OpenSSL EVP backend: one context per direction keeps the expanded key and
// the provider's precomputed GHASH table; each packet only sets its IV.
pub const ossl = struct {
    pub const Ctx = opaque {};
    pub const Cipher = opaque {};
    pub extern "c" fn EVP_CIPHER_CTX_new() ?*Ctx;
    pub extern "c" fn EVP_CIPHER_CTX_free(?*Ctx) void;
    pub extern "c" fn EVP_aes_128_gcm() *const Cipher;
    pub extern "c" fn EVP_aes_256_gcm() *const Cipher;
    pub extern "c" fn EVP_chacha20_poly1305() *const Cipher;
    pub extern "c" fn EVP_CipherInit_ex(*Ctx, ?*const Cipher, ?*anyopaque, ?[*]const u8, ?[*]const u8, c_int) c_int;
    pub extern "c" fn EVP_CipherUpdate(*Ctx, ?[*]u8, *c_int, [*]const u8, c_int) c_int;
    pub extern "c" fn EVP_CipherFinal_ex(*Ctx, [*]u8, *c_int) c_int;
    pub extern "c" fn EVP_CIPHER_CTX_ctrl(*Ctx, c_int, c_int, ?*anyopaque) c_int;
    const ctrl_get_tag = 0x10;
    const ctrl_set_tag = 0x11;

    pub const Aead = struct {
        ctx: *Ctx,

        pub fn init(suite: Suite, key: []const u8, encrypt: bool) error{OutOfMemory}!Aead {
            const ctx = EVP_CIPHER_CTX_new() orelse return error.OutOfMemory;
            const cipher = switch (suite) {
                .aes128gcm => EVP_aes_128_gcm(),
                .aes256gcm => EVP_aes_256_gcm(),
                .chacha20 => EVP_chacha20_poly1305(),
            };
            if (EVP_CipherInit_ex(ctx, cipher, null, key.ptr, null, @intFromBool(encrypt)) != 1) {
                EVP_CIPHER_CTX_free(ctx);
                return error.OutOfMemory;
            }
            return .{ .ctx = ctx };
        }
        pub fn deinit(a: *Aead) void {
            EVP_CIPHER_CTX_free(a.ctx);
        }
        pub fn seal(a: *const Aead, nonce: [12]u8, ad: []const u8, data: []u8, tag: *[16]u8) void {
            var n: c_int = 0;
            _ = EVP_CipherInit_ex(a.ctx, null, null, null, &nonce, 1);
            _ = EVP_CipherUpdate(a.ctx, null, &n, ad.ptr, @intCast(ad.len));
            if (data.len > 0) _ = EVP_CipherUpdate(a.ctx, data.ptr, &n, data.ptr, @intCast(data.len));
            _ = EVP_CipherFinal_ex(a.ctx, tag, &n);
            _ = EVP_CIPHER_CTX_ctrl(a.ctx, ctrl_get_tag, 16, tag);
        }
        pub fn open(a: *const Aead, nonce: [12]u8, ad: []const u8, data: []u8, tag: [16]u8) Error!void {
            var n: c_int = 0;
            var t = tag;
            _ = EVP_CipherInit_ex(a.ctx, null, null, null, &nonce, 0);
            _ = EVP_CipherUpdate(a.ctx, null, &n, ad.ptr, @intCast(ad.len));
            if (data.len > 0) _ = EVP_CipherUpdate(a.ctx, data.ptr, &n, data.ptr, @intCast(data.len));
            _ = EVP_CIPHER_CTX_ctrl(a.ctx, ctrl_set_tag, 16, &t);
            var scratch: [16]u8 = undefined;
            if (EVP_CipherFinal_ex(a.ctx, &scratch, &n) != 1) return error.Decrypt;
        }
    };
};

pub const Backend = enum { zig, openssl };
pub const backend: Backend = if (build_options.openssl_aead) .openssl else .zig;

pub const ZigAead = union(enum) {
    aes128: ZigGcm(Aes128),
    aes256: ZigGcm(Aes256),
    chacha: [32]u8,

    pub fn init(suite: Suite, key: []const u8) ZigAead {
        return switch (suite) {
            .aes128gcm => .{ .aes128 = ZigGcm(Aes128).init(key) },
            .aes256gcm => .{ .aes256 = ZigGcm(Aes256).init(key) },
            .chacha20 => .{ .chacha = key[0..32].* },
        };
    }
    pub fn seal(a: *const ZigAead, nonce: [12]u8, ad: []const u8, data: []u8, tag: *[16]u8) void {
        switch (a.*) {
            .aes128 => |*g| g.seal(nonce, ad, data, tag),
            .aes256 => |*g| g.seal(nonce, ad, data, tag),
            .chacha => |k| ChaChaPoly.encrypt(data, tag, data, ad, nonce, k),
        }
    }
    pub fn open(a: *const ZigAead, nonce: [12]u8, ad: []const u8, data: []u8, tag: [16]u8) Error!void {
        switch (a.*) {
            .aes128 => |*g| try g.open(nonce, ad, data, tag),
            .aes256 => |*g| try g.open(nonce, ad, data, tag),
            .chacha => |k| ChaChaPoly.decrypt(data, data, tag, ad, nonce, k) catch return error.Decrypt,
        }
    }
};

pub const Hp = union(enum) {
    aes128: @TypeOf(Aes128.initEnc(undefined)),
    aes256: @TypeOf(Aes256.initEnc(undefined)),
    chacha: [32]u8,

    pub fn init(suite: Suite, key: []const u8) Hp {
        return switch (suite) {
            .aes128gcm => .{ .aes128 = Aes128.initEnc(key[0..16].*) },
            .aes256gcm => .{ .aes256 = Aes256.initEnc(key[0..32].*) },
            .chacha20 => .{ .chacha = key[0..32].* },
        };
    }
    pub fn mask(h: *const Hp, sample: *const [16]u8) [5]u8 {
        var out: [16]u8 = undefined;
        switch (h.*) {
            .aes128 => |*c| c.encrypt(&out, sample),
            .aes256 => |*c| c.encrypt(&out, sample),
            .chacha => |k| {
                const zero: [5]u8 = @splat(0);
                ChaCha20.xor(out[0..5], &zero, std.mem.readInt(u32, sample[0..4], .little), k, sample[4..16].*);
            },
        }
        return out[0..5].*;
    }
};

/// Keys for one direction of one encryption level (and, for 1-RTT, one phase).
pub const Keys = struct {
    suite: Suite,
    iv: [12]u8,
    aead: if (backend == .openssl) ossl.Aead else ZigAead,
    hp: Hp,
    secret: [max_secret]u8,
    secret_len: u8,
    encrypt: bool,

    pub fn init(suite: Suite, secret: []const u8, encrypt: bool) error{OutOfMemory}!Keys {
        var key: [32]u8 = undefined;
        var hp: [32]u8 = undefined;
        const kl = suite.keyLen();
        var k: Keys = undefined;
        k.suite = suite;
        k.encrypt = encrypt;
        expandLabel(suite, key[0..kl], secret, "quic key");
        expandLabel(suite, &k.iv, secret, "quic iv");
        expandLabel(suite, hp[0..kl], secret, "quic hp");
        k.hp = Hp.init(suite, hp[0..kl]);
        k.secret_len = @intCast(secret.len);
        @memcpy(k.secret[0..secret.len], secret);
        k.aead = if (backend == .openssl) try ossl.Aead.init(suite, key[0..kl], encrypt) else ZigAead.init(suite, key[0..kl]);
        std.crypto.secureZero(u8, &key);
        std.crypto.secureZero(u8, &hp);
        return k;
    }

    pub fn deinit(k: *Keys) void {
        if (backend == .openssl) k.aead.deinit();
        std.crypto.secureZero(u8, &k.secret);
    }

    /// RFC 9001 §6: next 1-RTT generation; header protection key is retained.
    pub fn next(k: *const Keys) error{OutOfMemory}!Keys {
        var secret: [max_secret]u8 = undefined;
        const sl = k.secret_len;
        expandLabel(k.suite, secret[0..sl], k.secret[0..sl], "quic ku");
        var key: [32]u8 = undefined;
        const kl = k.suite.keyLen();
        expandLabel(k.suite, key[0..kl], secret[0..sl], "quic key");
        var n: Keys = k.*;
        expandLabel(k.suite, &n.iv, secret[0..sl], "quic iv");
        @memcpy(n.secret[0..sl], secret[0..sl]);
        n.aead = if (backend == .openssl) try ossl.Aead.init(k.suite, key[0..kl], k.encrypt) else ZigAead.init(k.suite, key[0..kl]);
        std.crypto.secureZero(u8, &key);
        std.crypto.secureZero(u8, &secret);
        return n;
    }

    inline fn nonce(k: *const Keys, pn: u64) [12]u8 {
        var n = k.iv;
        const tail = std.mem.readInt(u64, n[4..12], .big) ^ pn;
        std.mem.writeInt(u64, n[4..12], tail, .big);
        return n;
    }

    /// Encrypts `data` in place and writes the tag immediately after it.
    pub fn seal(k: *const Keys, pn: u64, ad: []const u8, data: []u8, tag: *[16]u8) void {
        k.aead.seal(k.nonce(pn), ad, data, tag);
    }

    /// Decrypts `data` (excluding its trailing tag) in place.
    pub fn open(k: *const Keys, pn: u64, ad: []const u8, data: []u8, tag: [16]u8) Error!void {
        try k.aead.open(k.nonce(pn), ad, data, tag);
    }
};

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "RFC 9001 A.1 initial secrets" {
    var c: [32]u8 = undefined;
    var s: [32]u8 = undefined;
    initialSecrets(&hex("8394c8f03e515708"), &c, &s);
    try std.testing.expectEqualSlices(u8, &hex("c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea"), &c);
    try std.testing.expectEqualSlices(u8, &hex("3c199828fd139efd216c155ad844cc81fb82fa8d7446fa7d78be803acdda951b"), &s);
    var key: [16]u8 = undefined;
    var iv: [12]u8 = undefined;
    var hp: [16]u8 = undefined;
    expandLabel(.aes128gcm, &key, &c, "quic key");
    expandLabel(.aes128gcm, &iv, &c, "quic iv");
    expandLabel(.aes128gcm, &hp, &c, "quic hp");
    try std.testing.expectEqualSlices(u8, &hex("1f369613dd76d5467730efcbe3b1a22d"), &key);
    try std.testing.expectEqualSlices(u8, &hex("fa044b2f42a3fd3b46fb255c"), &iv);
    try std.testing.expectEqualSlices(u8, &hex("9f50449e04a0e810283a1e9933adedd2"), &hp);
    expandLabel(.aes128gcm, &key, &s, "quic key");
    expandLabel(.aes128gcm, &hp, &s, "quic hp");
    try std.testing.expectEqualSlices(u8, &hex("cf3a5331653c364c88f0f379b6067e37"), &key);
    try std.testing.expectEqualSlices(u8, &hex("c206b8d9b9f0f37644430b490eeaa314"), &hp);
}

test "RFC 9001 A.5 ChaCha20 short header" {
    const secret = hex("9ac312a7f877468ebe69422748ad00a15443f18203a07d6060f688f30f21632b");
    var keys = try Keys.init(.chacha20, &secret, true);
    defer keys.deinit();
    try std.testing.expectEqualSlices(u8, &hex("e0459b3474bdd0e44a41c144"), &keys.iv);
    var ku: [32]u8 = undefined;
    expandLabel(.chacha20, &ku, &secret, "quic ku");
    try std.testing.expectEqualSlices(u8, &hex("1223504755036d556342ee9361d253421a826c9ecdf3c7148684b36b714881f9"), &ku);
    // header 4200bff4, payload PING, pn 654360564
    var pkt: [4 + 1 + 16]u8 = undefined;
    pkt[0..4].* = hex("4200bff4");
    pkt[4] = 0x01;
    keys.seal(654360564, pkt[0..4], pkt[4..5], pkt[5..21]);
    const sample = pkt[5..21];
    const m = keys.hp.mask(sample);
    try std.testing.expectEqualSlices(u8, &hex("aefefe7d03"), &m);
    pkt[0] ^= m[0] & 0x1f;
    for (0..3) |i| pkt[1 + i] ^= m[1 + i];
    try std.testing.expectEqualSlices(u8, &hex("4cfe4189655e5cd55c41f69080575d7999c25a5bfb"), &pkt);
}

test "AEAD round trip and tamper" {
    inline for (.{ Suite.aes128gcm, Suite.aes256gcm, Suite.chacha20 }) |suite| {
        var secret: [48]u8 = @splat(7);
        var tx = try Keys.init(suite, secret[0..suite.secretLen()], true);
        defer tx.deinit();
        var rx = try Keys.init(suite, secret[0..suite.secretLen()], false);
        defer rx.deinit();
        var buf: [1200]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @truncate(i);
        const orig = buf;
        var tag: [16]u8 = undefined;
        tx.seal(42, "hdr", buf[0..1000], &tag);
        try rx.open(42, "hdr", buf[0..1000], tag);
        try std.testing.expectEqualSlices(u8, orig[0..1000], buf[0..1000]);
        tx.seal(43, "hdr", buf[0..1000], &tag);
        buf[5] ^= 1;
        try std.testing.expectError(error.Decrypt, rx.open(43, "hdr", buf[0..1000], tag));
        var tx2 = try tx.next();
        defer tx2.deinit();
        var rx2 = try rx.next();
        defer rx2.deinit();
        tx2.seal(1, "x", buf[0..10], &tag);
        try rx2.open(1, "x", buf[0..10], tag);
    }
}
