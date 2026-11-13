//! Packet-protection microbenchmark: Zig std AES-GCM (pre-keyed) versus
//! OpenSSL EVP (pre-keyed context) at QUIC packet sizes.
const std = @import("std");
const crypto = @import("crypto.zig");
const clock = @import("clock.zig");

pub fn main() void {
    const sizes = [_]usize{ 30, 200, 700, 1200, 1400 };
    var buf: [1500]u8 = @splat(0x5a);
    var tag: [16]u8 = undefined;
    const key: [32]u8 = @splat(1);
    const iters: u64 = 400_000;
    inline for (.{ crypto.Suite.aes128gcm, crypto.Suite.chacha20 }) |suite| {
        const z = crypto.ZigAead.init(suite, key[0..suite.keyLen()]);
        var o = crypto.ossl.Aead.init(suite, key[0..suite.keyLen()], true) catch unreachable;
        defer o.deinit();
        for (sizes) |size| {
            const nonce: [12]u8 = @splat(3);
            var t0 = clock.nowNs();
            for (0..iters) |_| z.seal(nonce, buf[0..20], buf[20 .. 20 + size], &tag);
            const zn = clock.nowNs() - t0;
            t0 = clock.nowNs();
            for (0..iters) |_| o.seal(nonce, buf[0..20], buf[20 .. 20 + size], &tag);
            const on = clock.nowNs() - t0;
            std.debug.print("{s} {d:>5} B: zig {d:>6.1} ns/pkt  openssl {d:>6.1} ns/pkt\n", .{
                @tagName(suite),                                                size,
                @as(f64, @floatFromInt(zn)) / @as(f64, @floatFromInt(iters)), @as(f64, @floatFromInt(on)) / @as(f64, @floatFromInt(iters)),
            });
        }
    }
    const hp = crypto.Hp.init(.aes128gcm, key[0..16]);
    const t0 = clock.nowNs();
    var acc: u8 = 0;
    var sample: [16]u8 = @splat(9);
    for (0..iters) |i| {
        sample[0] = @truncate(i);
        acc ^= hp.mask(&sample)[0];
    }
    std.debug.print("hp aes128: {d:.1} ns ({d})\n", .{ @as(f64, @floatFromInt(clock.nowNs() - t0)) / @as(f64, @floatFromInt(iters)), acc });
}
