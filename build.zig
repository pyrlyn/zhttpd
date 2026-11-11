const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tls = b.option(bool, "tls", "Build with TLS (links OpenSSL libssl/libcrypto)") orelse false;
    const openssl = b.option([]const u8, "openssl", "OpenSSL install prefix (include/ and lib/), e.g. deps/openssl-install");

    const http = b.option(bool, "http", "Build HTTP/2 and HTTP/3 (requires TLS, nghttp2, nghttp3 and OpenSSL 3.5+)") orelse false;
    const http_deps = b.option([]const u8, "http-deps", "nghttp2/nghttp3 installation prefix");
    if (http and !tls) @panic("-Dhttp=true requires -Dtls=true");
    const opts = b.addOptions();
    opts.addOption(bool, "tls", tls);
    opts.addOption(bool, "http", http);

    const expression_mod = b.addModule("expression", .{ .root_source_file = b.path("src/expression.zig"), .target = target, .optimize = optimize });
    const logging_mod = b.addModule("logging", .{ .root_source_file = b.path("src/logging.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "expression", .module = expression_mod }} });
    const acme_mod = b.addModule("acme", .{ .root_source_file = b.path("src/acme.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const fastcgi_mod = b.addModule("fastcgi", .{ .root_source_file = b.path("src/fastcgi.zig"), .target = target, .optimize = optimize });
    const wsgi_mod = b.addModule("wsgi", .{ .root_source_file = b.path("src/wsgi.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "fastcgi", .module = fastcgi_mod }} });
    const websocket_mod = b.addModule("websocket", .{
        .root_source_file = b.path("src/websocket.zig"),
        .target = target,
        .optimize = optimize,
    });
    const http_mod = b.addModule("http", .{
        .root_source_file = b.path("src/http.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    http_mod.addOptions("build_options", opts);
    http_mod.addImport("websocket", websocket_mod);
    http_mod.addImport("expression", expression_mod);
    http_mod.addImport("logging", logging_mod);
    http_mod.addImport("fastcgi", fastcgi_mod);
    http_mod.addImport("acme", acme_mod);
    if (tls) {
        if (openssl) |p| {
            http_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
            // static archives so the binary does not depend on a system OpenSSL
            http_mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libssl.a", .{p}) });
            http_mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libcrypto.a", .{p}) });
        } else {
            http_mod.linkSystemLibrary("ssl", .{});
            http_mod.linkSystemLibrary("crypto", .{});
        }
    }

    if (http) {
        http_mod.addCSourceFile(.{ .file = b.path("src/server/multiplex.c"), .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-Wall", "-Wextra", "-Werror" } });
        if (http_deps) |p| {
            http_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
            http_mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libnghttp2.a", .{p}) });
            http_mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libnghttp3.a", .{p}) });
        } else {
            http_mod.linkSystemLibrary("nghttp2", .{});
            http_mod.linkSystemLibrary("nghttp3", .{});
        }
    }

    const nginx_mod = b.addModule("nginx", .{
        .root_source_file = b.path("src/nginx.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = http_mod }},
    });
    const settings_mod = b.addModule("settings", .{
        .root_source_file = b.path("src/settings.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "http", .module = http_mod }},
    });
    const apache_mod = b.addModule("apache", .{
        .root_source_file = b.path("src/apache.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "http", .module = http_mod }, .{ .name = "settings", .module = settings_mod } },
    });
    const litespeed_mod = b.addModule("litespeed", .{
        .root_source_file = b.path("src/litespeed.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "http", .module = http_mod }, .{ .name = "settings", .module = settings_mod } },
    });
    const caddy_mod = b.addModule("caddy", .{
        .root_source_file = b.path("src/caddy.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "http", .module = http_mod }, .{ .name = "settings", .module = settings_mod } },
    });
    const sdk_mod = b.addModule("websocket_sdk", .{ .root_source_file = b.path("src/websocket_sdk.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{ .{ .name = "http", .module = http_mod }, .{ .name = "settings", .module = settings_mod }, .{ .name = "websocket", .module = websocket_mod } } });
    const sdk_c = b.addLibrary(.{ .name = "zhttpd_websocket", .linkage = .static, .root_module = b.createModule(.{ .root_source_file = b.path("src/websocket_c.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "websocket_sdk", .module = sdk_mod }} }) });
    b.installArtifact(sdk_c);
    sdk_c.installHeader(b.path("include/zhttpd_websocket.h"), "zhttpd_websocket.h");
    sdk_c.installHeader(b.path("include/zhttpd_websocket.hpp"), "zhttpd_websocket.hpp");
    const examples_step = b.step("examples", "Build Zig, C and C++ WebSocket examples");
    var examples: [3]*std.Build.Step.Compile = undefined;
    examples[0] = b.addExecutable(.{ .name = "ws-echo-zig", .root_module = b.createModule(.{ .root_source_file = b.path("examples/websocket/echo.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "websocket_sdk", .module = sdk_mod }} }) });
    inline for (.{ "c", "cpp" }, 1..) |lang, i| {
        const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = i == 2 });
        mod.addIncludePath(b.path("include"));
        mod.addCSourceFile(.{ .file = b.path("examples/websocket/echo." ++ lang), .flags = if (i == 2) &.{"-std=c++17"} else &.{"-std=c11"} });
        mod.linkLibrary(sdk_c);
        // Static SDK archives do not propagate prebuilt library objects to C consumers.
        if (tls) {
            if (openssl) |p| {
                mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libssl.a", .{p}) });
                mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libcrypto.a", .{p}) });
            } else {
                mod.linkSystemLibrary("ssl", .{});
                mod.linkSystemLibrary("crypto", .{});
            }
        }
        if (http) {
            if (http_deps) |p| {
                mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libnghttp2.a", .{p}) });
                mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libnghttp3.a", .{p}) });
            } else {
                mod.linkSystemLibrary("nghttp2", .{});
                mod.linkSystemLibrary("nghttp3", .{});
            }
        }
        examples[i] = b.addExecutable(.{ .name = "ws-echo-" ++ lang, .root_module = mod });
    }
    for (examples) |example| examples_step.dependOn(&b.addInstallArtifact(example, .{}).step);
    const lib_mod = b.addModule("zhttpd", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "http", .module = http_mod }, .{ .name = "nginx", .module = nginx_mod }, .{ .name = "apache", .module = apache_mod }, .{ .name = "litespeed", .module = litespeed_mod }, .{ .name = "caddy", .module = caddy_mod }, .{ .name = "settings", .module = settings_mod }, .{ .name = "websocket", .module = websocket_mod } },
    });

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

    const e2e_python = b.option([]const u8, "e2e-python", "Python with tests/requirements-e2e.txt installed") orelse "python3";
    const e2e_command = if (std.mem.indexOfScalar(u8, e2e_python, '/') != null) (b.root.joinString(b.allocator, e2e_python) catch @panic("OOM")) else e2e_python;
    const e2e = b.addSystemCommand(&.{e2e_command});
    e2e.addFileArg(b.path("tests/protocols.py"));
    e2e.addArtifactArg(exe);
    e2e.setCwd(b.path("."));
    b.step("test-protocols", "Run HTTP/1.1, HTTP/2 and HTTP/3 wire tests").dependOn(&e2e.step);
    const e2e_step = b.step("test-e2e", "Run protocol, configuration, logging, SDK, FastCGI/WSGI and ACME E2E");
    e2e_step.dependOn(&e2e.step);
    var previous: *std.Build.Step = &e2e.step;
    for ([_][]const u8{ "error-pages.py", "config_e2e.py", "logging_e2e.py", "gateway_e2e.py", "acme_e2e.py", "acme_sni_e2e.py" }) |script| {
        const check = b.addSystemCommand(&.{e2e_command});
        check.addFileArg(b.path(b.fmt("tests/{s}", .{script})));
        check.addArtifactArg(exe);
        check.setCwd(b.path("."));
        check.step.dependOn(previous);
        previous = &check.step;
    }
    const ws_check = b.addSystemCommand(&.{e2e_command});
    ws_check.addFileArg(b.path("tests/websocket_e2e.py"));
    ws_check.addArtifactArg(exe);
    for (examples) |example| ws_check.addArtifactArg(example);
    ws_check.step.dependOn(previous);
    e2e_step.dependOn(&ws_check.step);

    const http_tests = b.addRunArtifact(b.addTest(.{ .root_module = http_mod }));
    b.step("test-http", "Test HTTP independently of nginx").dependOn(&http_tests.step);
    const nginx_tests = b.addRunArtifact(b.addTest(.{ .root_module = nginx_mod }));
    b.step("test-nginx", "Test nginx configuration adapter").dependOn(&nginx_tests.step);

    const tests = b.addTest(.{ .root_module = lib_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run all independent module unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&http_tests.step);
    test_step.dependOn(&nginx_tests.step);
    for ([_]*std.Build.Module{ settings_mod, apache_mod, caddy_mod, litespeed_mod, websocket_mod, fastcgi_mod, wsgi_mod, acme_mod, logging_mod, expression_mod }) |mod| {
        const check = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
        check.setCwd(b.path("."));
        test_step.dependOn(&check.step);
    }
}
