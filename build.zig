const std = @import("std");

const E2eGroup = enum { core, reload, tls, sni, acme, encryption, rotation, acme_reload, acme_auto };

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

    const load_balancer_mod = b.addModule("load_balancer", .{ .root_source_file = b.path("src/load_balancer.zig"), .target = target, .optimize = optimize, .link_libc = true });
    load_balancer_mod.addCSourceFile(.{ .file = b.path("src/load_balancer/backend.c"), .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-Wall", "-Wextra", "-Werror" } });
    load_balancer_mod.linkSystemLibrary("pthread", .{});
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
    http_mod.addImport("load_balancer", load_balancer_mod);
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

    const raft_build = b.addSystemCommand(&.{ "bash", "scripts/build-raft.sh" });
    raft_build.setCwd(b.path("."));
    b.step("raft", "Build the optional zhttpd-raft consensus companion (Go required)").dependOn(&raft_build.step);
    const raft_test = b.addSystemCommand(&.{ "go", "-C", "modules/raft", "test", "./..." });
    raft_test.setCwd(b.path("."));
    b.step("test-raft", "Test the Raft state machine and exports").dependOn(&raft_test.step);

    const e2e_python = b.option([]const u8, "e2e-python", "Python with tests/requirements-e2e.txt installed") orelse "python3";
    const e2e_command = if (std.mem.indexOfScalar(u8, e2e_python, '/') != null) (b.root.joinString(b.allocator, e2e_python) catch @panic("OOM")) else e2e_python;
    const raft_e2e = b.addSystemCommand(&.{e2e_command});
    raft_e2e.addFileArg(b.path("tests/raft_e2e.py"));
    raft_e2e.addArtifactArg(exe);
    raft_e2e.addArg("zig-out/bin/zhttpd-raft");
    raft_e2e.setCwd(b.path("."));
    raft_e2e.step.dependOn(&raft_build.step);
    b.step("test-raft-e2e", "Test Raft failover, durable state, membership and load balancing").dependOn(&raft_e2e.step);
    // The default target keeps the complete sequential suite. CI can fan out
    // ACME/DNS scripts into isolated processes, one per configuration adapter.
    const e2e_group = b.option(E2eGroup, "e2e-group", "Run only this E2E group (default: all)");
    const parallel_adapters = b.option(bool, "e2e-parallel-adapters", "Run ACME/DNS adapters concurrently (bounded by -j)") orelse false;
    const e2e = b.addSystemCommand(&.{e2e_command});
    e2e.addFileArg(b.path("tests/protocols.py"));
    e2e.addArtifactArg(exe);
    e2e.setCwd(b.path("."));
    b.step("test-protocols", "Run HTTP/1.1, HTTP/2 and HTTP/3 wire tests").dependOn(&e2e.step);
    const e2e_step = b.step("test-e2e", "Run protocol, configuration, logging, SDK, FastCGI/WSGI and ACME E2E");
    const benchmark_gate = b.addSystemCommand(&.{e2e_command});
    benchmark_gate.addFileArg(b.path("tests/bench-target.py"));
    var previous: ?*std.Build.Step = null;
    if (e2e_group == null or e2e_group == .core) {
        previous = &e2e.step;
        e2e_step.dependOn(&benchmark_gate.step);
    }
    for ([_]struct { group: E2eGroup, script: []const u8, args: []const []const u8 = &.{} }{
        .{ .group = .tls, .script = "tls-io.py" },
        .{ .group = .core, .script = "error-pages.py" },
        .{ .group = .core, .script = "config_e2e.py" },
        .{ .group = .reload, .script = "auto_reload_e2e.py" },
        .{ .group = .tls, .script = "tls_files_e2e.py" },
        .{ .group = .tls, .script = "tls_password_e2e.py" },
        .{ .group = .sni, .script = "sni_password_e2e.py" },
        .{ .group = .reload, .script = "dns_env_reload_e2e.py" },
        .{ .group = .core, .script = "load_balancer_e2e.py" },
        .{ .group = .core, .script = "logging_e2e.py" },
        .{ .group = .core, .script = "gateway_e2e.py" },
        .{ .group = .acme, .script = "acme_e2e.py" },
        .{ .group = .encryption, .script = "acme_encryption_e2e.py" },
        .{ .group = .rotation, .script = "acme_password_rotation_e2e.py" },
        .{ .group = .rotation, .script = "acme_migration_e2e.py" },
        .{ .group = .acme, .script = "acme_sni_e2e.py" },
        .{ .group = .acme_reload, .script = "acme_reload_e2e.py" },
        .{ .group = .acme_auto, .script = "acme_reload_e2e.py", .args = &.{"--auto"} },
    }) |check_spec| {
        if (e2e_group != null and e2e_group != check_spec.group) continue;
        const shard_adapters = parallel_adapters and switch (check_spec.group) {
            .reload, .acme, .encryption, .rotation, .acme_reload, .acme_auto => true,
            .core, .tls, .sni => false,
        };
        const adapters: []const ?[]const u8 = if (shard_adapters)
            &.{ "self", "nginx", "apache", "litespeed", "caddy" }
        else
            &.{null};
        for (adapters) |adapter| {
            const check = b.addSystemCommand(&.{e2e_command});
            check.addFileArg(b.path(b.fmt("tests/{s}", .{check_spec.script})));
            check.addArtifactArg(exe);
            check.addArgs(check_spec.args);
            if (adapter) |name| check.addArg(name);
            check.setCwd(b.path("."));
            if (shard_adapters) {
                // Inherited stdio takes Zig's global lock and serializes runs.
                // Capture/check the result instead, but never cache execution.
                check.expectExitCode(0);
                check.has_side_effects = true;
                check.step.name = b.fmt("{s} ({s})", .{ check_spec.script, adapter.? });
                // Each invocation owns its temporary files and local CA/DNS.
                // Keep every shard as a required dependency, including failures.
                e2e_step.dependOn(&check.step);
            } else {
                if (previous) |step| check.step.dependOn(step);
                previous = &check.step;
            }
        }
    }
    if (e2e_group == null or e2e_group == .core) {
        const ws_check = b.addSystemCommand(&.{e2e_command});
        ws_check.addFileArg(b.path("tests/websocket_e2e.py"));
        ws_check.addArtifactArg(exe);
        for (examples) |example| ws_check.addArtifactArg(example);
        if (previous) |step| ws_check.step.dependOn(step);
        previous = &ws_check.step;
    }
    if (previous) |step| e2e_step.dependOn(step);

    const lb_tests = b.addRunArtifact(b.addTest(.{ .root_module = load_balancer_mod }));
    b.step("test-load-balancer", "Test the independent load balancer module").dependOn(&lb_tests.step);
    const lb_e2e = b.addSystemCommand(&.{e2e_command});
    lb_e2e.addFileArg(b.path("tests/load_balancer_e2e.py"));
    lb_e2e.addArtifactArg(exe);
    lb_e2e.setCwd(b.path("."));
    b.step("test-load-balancer-e2e", "Run shared metrics and 307 redirect wire tests (requires curl)").dependOn(&lb_e2e.step);

    const http_tests = b.addRunArtifact(b.addTest(.{ .root_module = http_mod }));
    b.step("test-http", "Test HTTP independently of nginx").dependOn(&http_tests.step);
    const nginx_tests = b.addRunArtifact(b.addTest(.{ .root_module = nginx_mod }));
    b.step("test-nginx", "Test nginx configuration adapter").dependOn(&nginx_tests.step);

    const tests = b.addTest(.{ .root_module = lib_mod });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    // Cache compilation, never the result of a unit-test execution.
    for ([_]*std.Build.Step.Run{ run_tests, lb_tests, http_tests, nginx_tests }) |check| {
        check.has_side_effects = true;
    }
    const test_step = b.step("test", "Run all independent module unit tests");
    if (http and target.result.os.tag == .linux) {
        const datagrams = b.addExecutable(.{
            .name = "quic-io-test",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        datagrams.root_module.addCSourceFile(.{ .file = b.path("tests/quic_io.c"), .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-Wall", "-Wextra", "-Werror" } });
        if (openssl) |p| {
            datagrams.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
            datagrams.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libssl.a", .{p}) });
            datagrams.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libcrypto.a", .{p}) });
        } else {
            datagrams.root_module.linkSystemLibrary("ssl", .{});
            datagrams.root_module.linkSystemLibrary("crypto", .{});
        }
        if (http_deps) |p| {
            datagrams.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
            datagrams.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libnghttp2.a", .{p}) });
            datagrams.root_module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libnghttp3.a", .{p}) });
        } else {
            datagrams.root_module.linkSystemLibrary("nghttp2", .{});
            datagrams.root_module.linkSystemLibrary("nghttp3", .{});
        }
        const run_datagrams = b.addRunArtifact(datagrams);
        b.step("test-quic-io", "Test QUIC datagram batching and fallback").dependOn(&run_datagrams.step);
        test_step.dependOn(&run_datagrams.step);
    }
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&lb_tests.step);
    test_step.dependOn(&http_tests.step);
    test_step.dependOn(&nginx_tests.step);
    for ([_]*std.Build.Module{ settings_mod, apache_mod, caddy_mod, litespeed_mod, websocket_mod, fastcgi_mod, wsgi_mod, acme_mod, logging_mod, expression_mod }) |mod| {
        const check = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
        check.setCwd(b.path("."));
        check.has_side_effects = true;
        test_step.dependOn(&check.step);
    }
}
