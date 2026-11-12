const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tls = b.option(bool, "tls", "Build with TLS (links OpenSSL libssl/libcrypto)") orelse false;
    const backend = b.option(enum { openssl, aws_lc }, "tls-backend", "TLS implementation (default: openssl)") orelse .openssl;
    const openssl = b.option([]const u8, "openssl", "TLS library install prefix (include/ and lib/)");
    if (backend == .aws_lc and (!tls or openssl == null))
        @panic("-Dtls-backend=aws_lc requires -Dtls=true and -Dopenssl=<AWS-LC install prefix>");

    const opts = b.addOptions();
    opts.addOption(bool, "tls", tls);
    opts.addOption(bool, "aws_lc", backend == .aws_lc);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addOptions("build_options", opts);
    if (tls) {
        if (backend == .aws_lc) {
            lib_mod.addCSourceFile(.{ .file = b.path("src/server/aws_lc.c"), .flags = &.{"-std=c11"} });
            lib_mod.linkSystemLibrary("pthread", .{});
        }
        if (openssl) |p| {
            lib_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
            // static archives so the binary does not depend on a system OpenSSL
            lib_mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libssl.a", .{p}) });
            lib_mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libcrypto.a", .{p}) });
        } else {
            lib_mod.linkSystemLibrary("ssl", .{});
            lib_mod.linkSystemLibrary("crypto", .{});
        }
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zhttpd", lib_mod);
    const exe = b.addExecutable(.{ .name = "zhttpd", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run zhttpd (pass args after --)").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = lib_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
