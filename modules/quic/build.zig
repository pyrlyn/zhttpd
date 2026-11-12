const std = @import("std");

/// zquic: QUIC v1 server transport (RFC 9000/9001/9002) plus a minimal
/// HTTP/3 + QPACK layer. Standalone package: it does not import zhttpd code.
///
///   zig build test [-Dopenssl=<prefix>]   unit tests
///   zig build bench-crypto -Dopenssl=<prefix>
///
/// TLS 1.3 handshakes use OpenSSL 3.5's third-party QUIC API
/// (SSL_set_quic_tls_cbs); packet protection uses keyed Zig AES-GCM /
/// ChaCha20-Poly1305 by default, or OpenSSL EVP with -Dopenssl-aead=true.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const openssl = b.option([]const u8, "openssl", "OpenSSL 3.5+ install prefix (include/ and lib/)");
    const openssl_aead = b.option(bool, "openssl-aead", "Use OpenSSL EVP for packet AEAD (default; false selects Zig std)") orelse true;

    const opts = b.addOptions();
    opts.addOption(bool, "openssl_aead", openssl_aead);

    const mod = b.addModule("zquic", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("zquic_options", opts);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addOptions("zquic_options", opts);
    linkOpenssl(b, test_mod, openssl);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run zquic unit tests").dependOn(&run_tests.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_crypto.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addOptions("zquic_options", opts);
    linkOpenssl(b, bench_mod, openssl);
    const bench = b.addExecutable(.{ .name = "bench-crypto", .root_module = bench_mod });
    b.step("bench-crypto", "Packet protection microbenchmark").dependOn(&b.addRunArtifact(bench).step);
    b.installArtifact(bench);
}

fn linkOpenssl(b: *std.Build, m: *std.Build.Module, prefix: ?[]const u8) void {
    if (prefix) |p| {
        m.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
        m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libssl.a", .{p}) });
        m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libcrypto.a", .{p}) });
    } else {
        m.linkSystemLibrary("ssl", .{});
        m.linkSystemLibrary("crypto", .{});
    }
}
