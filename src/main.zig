//! zhttpd command line and master process (nginx-compatible flags and signals).
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const z = @import("zhttpd");
const config = z.nginx.config;
const Diag = z.http.diag.Diag;
const net = z.server.net;
const tls = z.server.tls;
const multiplex = z.server.multiplex;
const worker_mod = z.server.worker;
const os = z.os;

const usage =
    \\Usage: zhttpd [-?hvVtTq] [-s signal] [-p prefix] [-c filename] [-g directives] [--strict]
    \\
    \\Options:
    \\  -?,-h         : this help
    \\  -v            : show version and exit
    \\  -V            : show version and build options and exit
    \\  -t            : test configuration and exit
    \\  -T            : test configuration, dump it and exit
    \\  -q            : suppress non-error messages during configuration testing
    \\  -s signal     : send signal to a master process: stop, quit, reopen, reload
    \\  --compatibility name : direct file format: nginx/apache/litespeed/caddy
    \\  -p prefix     : set prefix path (default: see README)
    \\  -c filename   : set configuration file (default: config.toml)
    \\  -g directives : set global directives out of configuration file (daemon/master_process/worker_processes/pid)
    \\  --strict      : unknown directives are errors instead of warnings
    \\  --directives  : print the supported/ignored directive table (Markdown) and exit
    \\
;

const Opts = struct {
    conf: []const u8 = "config.toml",
    compatibility: z.app_config.Compatibility = .nginx,
    prefix: ?[]const u8 = null,
    test_only: bool = false,
    dump: bool = false,
    quiet: bool = false,
    strict: bool = false,
    signal: ?[]const u8 = null,
    globals: ?[]const u8 = null,
};

var stderr_buf: [4096]u8 = undefined;

fn eprint(comptime fmt: []const u8, args: anytype) void {
    var w: std.Io.Writer = .fixed(&stderr_buf);
    w.print(fmt, args) catch {};
    const out = w.buffered();
    _ = c.write(2, out.ptr, out.len);
}

fn outWrite(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const n = c.write(1, s.ptr + off, s.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const gpa = std.heap.c_allocator;
    const argv = init.minimal.args.toSlice(arena) catch return 1;
    var o: Opts = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a: []const u8 = argv[i];
        const nextArg = struct {
            fn f(av: []const [:0]const u8, idx: *usize, flag: []const u8) ?[]const u8 {
                idx.* += 1;
                if (idx.* >= av.len) {
                    eprint("zhttpd: option \"{s}\" requires {s}\n", .{ flag, switch (flag[1]) {
                        'c' => "file name",
                        'p' => "directory name",
                        's' => "signal",
                        else => "parameter",
                    } });
                    return null;
                }
                return av[idx.*];
            }
        }.f;
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "-?") or std.mem.eql(u8, a, "--help")) {
            eprint("zhttpd version: zhttpd/{s}\n{s}", .{ z.server.vars.version, usage });
            return 0;
        } else if (std.mem.eql(u8, a, "-v")) {
            eprint("zhttpd version: zhttpd/{s}\n", .{z.server.vars.version});
            return 0;
        } else if (std.mem.eql(u8, a, "-V")) {
            eprint("zhttpd version: zhttpd/{s}\nbuilt with Zig {s}, event backend {s}, TLS {s}, HTTP/2+HTTP/3 {s}\n", .{ z.server.vars.version, builtin.zig_version_string, z.server.loop.name, if (tls.enabled) "OpenSSL" else "disabled", if (multiplex.enabled) "enabled" else "disabled" });
            return 0;
        } else if (std.mem.eql(u8, a, "-t")) {
            o.test_only = true;
        } else if (std.mem.eql(u8, a, "-T")) {
            o.test_only = true;
            o.dump = true;
        } else if (std.mem.eql(u8, a, "-q")) {
            o.quiet = true;
        } else if (std.mem.eql(u8, a, "--strict")) {
            o.strict = true;
        } else if (std.mem.eql(u8, a, "--directives")) {
            var buf: [256 * 1024]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            z.conf.directives.writeMarkdown(&w) catch {};
            outWrite(w.buffered());
            return 0;
        } else if (std.mem.eql(u8, a, "--compatibility")) {
            const mode = nextArg(argv, &i, a) orelse return 1;
            o.compatibility = std.meta.stringToEnum(z.app_config.Compatibility, mode) orelse {
                eprint("zhttpd: compatibility must be self, nginx, apache, litespeed or caddy\n", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, a, "-c")) {
            o.conf = nextArg(argv, &i, a) orelse return 1;
        } else if (std.mem.eql(u8, a, "-p")) {
            o.prefix = nextArg(argv, &i, a) orelse return 1;
        } else if (std.mem.eql(u8, a, "-s")) {
            o.signal = nextArg(argv, &i, a) orelse return 1;
        } else if (std.mem.eql(u8, a, "-g")) {
            o.globals = nextArg(argv, &i, a) orelse return 1;
        } else if (std.mem.startsWith(u8, a, "-c") and a.len > 2) {
            o.conf = a[2..];
        } else if (std.mem.startsWith(u8, a, "-p") and a.len > 2) {
            o.prefix = a[2..];
        } else {
            eprint("zhttpd: invalid option: \"{s}\"\n", .{a});
            return 1;
        }
    }

    const conf_path = absPath(arena, o.conf) catch return 1;
    const conf_dir = std.fs.path.dirname(conf_path) orelse "/";
    const prefix = if (o.prefix) |p| withSlash(arena, absPath(arena, p) catch return 1) else defaultPrefix(arena, conf_dir);
    const copts: config.Options = .{
        .prefix = prefix,
        .conf_prefix = withSlash(arena, conf_dir),
        .strict = o.strict,
        .quiet_ignored = o.quiet,
    };

    var diag: Diag = .{ .gpa = gpa, .echo = true };
    defer diag.deinit();
    var sources: z.http.config_watch.Sources = .{ .gpa = gpa };
    defer sources.deinit();
    const cfg = z.app_config.load(gpa, conf_path, .{ .prefix = copts.prefix, .conf_prefix = copts.conf_prefix, .strict = copts.strict, .quiet_ignored = copts.quiet_ignored, .compatibility = o.compatibility, .sources = &sources }, &diag) catch {
        if (o.test_only) eprint("zhttpd: configuration file {s} test failed\n", .{conf_path});
        return 1;
    };
    if (o.globals) |g| applyGlobals(cfg, g, &diag) catch {
        eprint("zhttpd: invalid -g directives \"{s}\"\n", .{g});
        return 1;
    };

    if (o.signal) |sig| return sendSignal(cfg, sig);

    cfg.load_balancer.validateWorkers(cfg.worker_processes) catch {
        eprint("zhttpd: [emerg] load_balancer supports at most 256 workers\n", .{});
        return 1;
    };

    multiplex.validate(cfg) catch |err| {
        eprint("zhttpd: [emerg] HTTP protocol configuration: {s} (HTTP/2 and HTTP/3 require -Dtls=true -Dhttp=true)\n", .{@errorName(err)});
        return 1;
    };
    if (o.test_only) {
        // also verify certificates like nginx -t does
        if (tls.enabled) {
            tls.validateConfig(gpa, cfg, &diag) catch {
                eprint("zhttpd: configuration file {s} test failed\n", .{conf_path});
                return 1;
            };
        } else for (cfg.listens) |l| if (l.opts.ssl) {
            eprint("zhttpd: [emerg] this zhttpd binary was built without TLS (-Dtls=true) but \"listen ... ssl\" is used\n", .{});
            eprint("zhttpd: configuration file {s} test failed\n", .{conf_path});
            return 1;
        };
        if (!o.quiet) {
            eprint("zhttpd: the configuration file {s} syntax is ok\n", .{conf_path});
            eprint("zhttpd: configuration file {s} test is successful\n", .{conf_path});
            if (cfg.unknown_count + cfg.ignored_count > 0)
                eprint("zhttpd: note: {d} unknown and {d} accepted-but-ignored directive uses (see warnings above)\n", .{ cfg.unknown_count, cfg.ignored_count });
        }
        if (o.dump) {
            var buf: [1024 * 1024]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            for (cfg.source_files) |f| {
                w.print("# configuration file {s}:\n", .{f}) catch {};
                var e: c_int = 0;
                const text = os.readFileAlloc(gpa, f, &e) catch continue;
                defer gpa.free(text);
                w.writeAll(text) catch {};
                if (text.len > 0 and text[text.len - 1] != '\n') w.writeAll("\n") catch {};
                w.writeAll("\n") catch {};
            }
            outWrite(w.buffered());
        }
        return 0;
    }
    return master(gpa, cfg, copts, conf_path, o, &sources);
}

fn absPath(a: std.mem.Allocator, p: []const u8) ![]const u8 {
    if (p.len > 0 and p[0] == '/') return p;
    var buf: [4096]u8 = undefined;
    const cwd = c.getcwd(&buf, buf.len) orelse return error.Cwd;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.sliceTo(cwd, 0), p });
}

fn withSlash(a: std.mem.Allocator, p: []const u8) []const u8 {
    if (p.len > 0 and p[p.len - 1] == '/') return p;
    return std.fmt.allocPrint(a, "{s}/", .{p}) catch p;
}

/// nginx resolves relative paths (logs, root) against its compiled-in prefix. zhttpd
/// guesses it: `<prefix>/conf/nginx.conf` (tarball layout) -> `<prefix>/`, otherwise
/// `/usr/share/nginx/` when it exists (Debian/Ubuntu packages), else the config directory.
fn defaultPrefix(a: std.mem.Allocator, conf_dir: []const u8) []const u8 {
    if (std.mem.eql(u8, std.fs.path.basename(conf_dir), "conf")) {
        return withSlash(a, std.fs.path.dirname(conf_dir) orelse "/");
    }
    if (os.stat("/usr/share/nginx")) |m| if (m.kind == .dir) return "/usr/share/nginx/";
    return withSlash(a, conf_dir);
}

/// `-g "daemon off; worker_processes 2;"`
fn applyGlobals(cfg: *config.Config, g: []const u8, diag: *Diag) !void {
    var ast = try z.conf.parser.parseString(std.heap.c_allocator, g, "command line", .{ .conf_prefix = "/" }, diag);
    defer ast.deinit();
    for (ast.root) |d| {
        if (std.mem.eql(u8, d.name, "worker_processes") and d.args.len == 1) {
            cfg.worker_processes = if (std.mem.eql(u8, d.args[0], "auto")) os.ncpu() else try std.fmt.parseInt(u32, d.args[0], 10);
        } else if (std.mem.eql(u8, d.name, "pid") and d.args.len == 1) {
            cfg.pid_path = if (std.mem.eql(u8, d.args[0], "off")) null else try cfg.arena.allocator().dupe(u8, d.args[0]);
        } else if (std.mem.eql(u8, d.name, "daemon") or std.mem.eql(u8, d.name, "master_process")) {
            // always foreground with a master process
        } else {
            diag.add(.warn, null, 0, "directive \"{s}\" in -g is ignored", .{d.name});
        }
    }
}

fn readPid(cfg: *config.Config) ?c.pid_t {
    const p = cfg.pid_path orelse return null;
    var e: c_int = 0;
    const data = os.readFileAlloc(std.heap.c_allocator, p, &e) catch {
        eprint("zhttpd: [error] open() \"{s}\" failed ({d}: {s})\n", .{ p, e, os.strerror(e) });
        return null;
    };
    defer std.heap.c_allocator.free(data);
    return std.fmt.parseInt(c.pid_t, std.mem.trim(u8, data, " \r\n\t"), 10) catch {
        eprint("zhttpd: [error] invalid PID number \"{s}\" in \"{s}\"\n", .{ std.mem.trim(u8, data, " \r\n\t"), p });
        return null;
    };
}

fn sendSignal(cfg: *config.Config, sig: []const u8) u8 {
    const signo: c_int = if (std.mem.eql(u8, sig, "stop")) SIGTERM else if (std.mem.eql(u8, sig, "quit")) SIGQUIT else if (std.mem.eql(u8, sig, "reload")) SIGHUP else if (std.mem.eql(u8, sig, "reopen")) SIGUSR1 else {
        eprint("zhttpd: invalid option: \"-s {s}\"\n", .{sig});
        return 1;
    };
    const pid = readPid(cfg) orelse return 1;
    if (kill(pid, signo) != 0) {
        const e = os.errnoInt();
        eprint("zhttpd: [alert] kill({d}, {d}) failed ({d}: {s})\n", .{ pid, signo, e, os.strerror(e) });
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------- master

var m_terminate: bool = false;
var m_quit: bool = false;
var m_reload: bool = false;
var m_reopen: bool = false;
var m_child: bool = false;

fn masterSignal(sig: c_int) callconv(.c) void {
    if (sig == SIGTERM or sig == SIGINT) m_terminate = true;
    if (sig == SIGQUIT) m_quit = true;
    if (sig == SIGHUP) m_reload = true;
    if (sig == SIGUSR1) m_reopen = true;
    if (sig == SIGCHLD) m_child = true;
}

fn workerSignal(sig: c_int) callconv(.c) void {
    if (sig == SIGTERM or sig == SIGINT) worker_mod.sig_terminate = true;
    if (sig == SIGQUIT) worker_mod.sig_quit = true;
    if (sig == SIGUSR1) worker_mod.sig_reopen = true;
}

const SigFn = *const fn (c_int) callconv(.c) void;
extern "c" fn signal(sig: c_int, handler: ?*const anyopaque) ?*const anyopaque;
extern "c" fn kill(pid: c.pid_t, sig: c_int) c_int;

const SIGINT = 2;
const SIGQUIT = 3;
const SIGTERM = 15;
const SIGHUP = 1;
const SIGPIPE = 13;
const SIGUSR1: c_int = if (builtin.os.tag == .linux) 10 else 30;
const SIGCHLD: c_int = if (builtin.os.tag == .linux) 17 else 20;

fn installSignals(handler: SigFn) void {
    for ([_]c_int{ SIGTERM, SIGINT, SIGQUIT, SIGHUP, SIGUSR1, SIGCHLD }) |s| _ = signal(s, @ptrCast(handler));
    _ = signal(SIGPIPE, @ptrFromInt(1)); // SIG_IGN
}

/// Listen sockets for one configuration generation.
const Generation = struct {
    cfg: *config.Config,
    /// per Listen: fds (1 shared, or one per worker with reuseport on Linux)
    fds: [][]c_int,
    sni: []?*tls.SniTable,
    pids: []c.pid_t,
    error_fd: c_int,
};

const Sock = struct { addr: z.http.addr.Addr, fd: c_int, used: bool, quic: bool };

fn openErrorLog(cfg: *config.Config) c_int {
    const p = cfg.error_log.path;
    if (std.mem.eql(u8, p, "stderr") or std.mem.eql(u8, p, "/dev/stderr")) return 2;
    const zp = std.heap.c_allocator.dupeSentinel(u8, p, 0) catch return 2;
    defer std.heap.c_allocator.free(zp);
    const fd = c.open(zp, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) {
        const e = os.errnoInt();
        eprint("zhttpd: [warn] could not open error log file: open() \"{s}\" failed ({d}: {s}), logging to stderr\n", .{ p, e, os.strerror(e) });
        return 2;
    }
    return fd;
}

fn prepare(gpa: std.mem.Allocator, cfg: *config.Config, old: []Sock, diag: *Diag) !Generation {
    try multiplex.validate(cfg);
    try cfg.load_balancer.validateWorkers(cfg.worker_processes);
    const nw = @max(cfg.worker_processes, 1);
    const fds = try gpa.alloc([]c_int, cfg.listens.len);
    errdefer gpa.free(fds);
    @memset(fds, &.{});
    const sni = try gpa.alloc(?*tls.SniTable, cfg.listens.len);
    @memset(sni, null);
    errdefer {
        for (sni) |table| if (table) |t| {
            if (tls.enabled) tls.freeSni(gpa, t);
        };
        gpa.free(sni);
        for (fds) |list| {
            for (list) |fd| {
                if (fd < 0) continue;
                var reused = false;
                for (old) |socket| {
                    if (socket.fd == fd) {
                        reused = true;
                        break;
                    }
                }
                if (!reused) net.close(fd);
            }
            gpa.free(list);
        }
    }
    for (cfg.listens, 0..) |*l, li| {
        const per_worker = builtin.os.tag == .linux and l.opts.reuseport and !l.opts.quic;
        const n: usize = if (per_worker) nw else 1;
        fds[li] = try gpa.alloc(c_int, n);
        @memset(fds[li], -1);
        for (0..n) |k| {
            // reuse a socket from the previous generation (reload) when possible
            var reused: ?c_int = null;
            if (!per_worker) for (old) |*s| {
                if (!s.used and s.quic == l.opts.quic and s.addr.eql(l.addr)) {
                    s.used = true;
                    reused = s.fd;
                    break;
                }
            };
            if (reused) |fd| {
                fds[li][k] = fd;
                continue;
            }
            var e: c_int = 0;
            fds[li][k] = (if (l.opts.quic) net.listenUdp(l.addr, l.opts.ipv6only, &e) else net.listenSocket(l.addr, l.opts.backlog, per_worker or l.opts.reuseport, l.opts.ipv6only, &e)) catch |err| {
                var ab: [64]u8 = undefined;
                const what = switch (err) {
                    error.Socket => "socket()",
                    error.Bind => "bind()",
                    error.Listen => "listen()",
                };
                eprint("zhttpd: [emerg] {s} to {s}{s}{s}:{d} failed ({d}: {s})\n", .{ what, if (l.addr.family == .v6) "[" else "", l.addr.formatIp(&ab), if (l.addr.family == .v6) "]" else "", l.addr.port, e, os.strerror(e) });
                return error.Listen;
            };
        }
        sni[li] = null;
        if (l.opts.ssl) {
            if (!tls.enabled) {
                eprint("zhttpd: [emerg] this zhttpd binary was built without TLS (-Dtls=true) but \"listen ... ssl\" is used\n", .{});
                return error.Tls;
            }
            sni[li] = tls.buildSni(gpa, cfg, l, diag) catch return error.Tls;
        }
    }
    return .{ .cfg = cfg, .fds = fds, .sni = sni, .pids = try gpa.alloc(c.pid_t, nw), .error_fd = openErrorLog(cfg) };
}

fn spawnWorker(gpa: std.mem.Allocator, gen: *Generation, idx: usize) c.pid_t {
    const pid = c.fork();
    if (pid != 0) return pid;
    // child
    installSignals(workerSignal);
    var listeners: std.ArrayList(worker_mod.Listener) = .empty;
    for (gen.cfg.listens, 0..) |*l, li| {
        const fds = gen.fds[li];
        const fd = if (fds.len > 1) fds[idx % fds.len] else fds[0];
        if (fds.len > 1) for (fds, 0..) |other, k| {
            if (k != idx % fds.len) net.close(other);
        };
        // A single worker owns each QUIC socket: UDP packets of a connection
        // must reach the same OpenSSL engine, including during worker restarts.
        if (l.opts.quic and idx != 0) {
            net.close(fd);
            continue;
        }
        listeners.append(gpa, .{ .fd = fd, .listen = l, .sni = gen.sni[li] }) catch c.exit(2);
    }
    var w = worker_mod.Worker.init(gpa, gen.cfg, listeners.items, gen.error_fd, @intCast(idx)) catch c.exit(2);
    w.run();
    c.exit(0);
}

fn writePid(cfg: *config.Config) void {
    const p = cfg.pid_path orelse return;
    const zp = std.heap.c_allocator.dupeSentinel(u8, p, 0) catch return;
    defer std.heap.c_allocator.free(zp);
    const fd = c.open(zp, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) {
        const e = os.errnoInt();
        eprint("zhttpd: [emerg] open() \"{s}\" failed ({d}: {s})\n", .{ p, e, os.strerror(e) });
        return;
    }
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{c.getpid()}) catch return;
    _ = c.write(fd, s.ptr, s.len);
    net.close(fd);
}

fn removePid(cfg: *config.Config) void {
    const p = cfg.pid_path orelse return;
    const zp = std.heap.c_allocator.dupeSentinel(u8, p, 0) catch return;
    defer std.heap.c_allocator.free(zp);
    _ = c.unlink(zp);
}

fn signalAll(gen: *Generation, sig: c_int) void {
    for (gen.pids) |p| if (p > 0) {
        _ = kill(p, sig);
    };
}

fn sleepMs(ms: u32) void {
    var ts: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000) };
    _ = c.nanosleep(&ts, null);
}

fn raiseNofile(want: ?u64) void {
    var rl: c.rlimit = undefined;
    if (c.getrlimit(.NOFILE, &rl) != 0) return;
    const target: u64 = want orelse @min(@as(u64, @intCast(rl.max)), 65536);
    if (rl.cur >= target) return;
    var v: u64 = @min(target, @as(u64, @intCast(rl.max)));
    // macOS rejects values above kern.maxfilesperproc (EINVAL): step down until accepted
    while (v > rl.cur) : (v = v * 3 / 4) {
        var nrl = rl;
        nrl.cur = @intCast(v);
        if (c.setrlimit(.NOFILE, &nrl) == 0) {
            if (v < target) eprint("zhttpd: [warn] RLIMIT_NOFILE raised to {d} (wanted {d})\n", .{ v, target });
            return;
        }
    }
    eprint("zhttpd: [alert] setrlimit(RLIMIT_NOFILE, {d}) failed\n", .{target});
}

fn destroyConfig(gpa: std.mem.Allocator, cfg: *config.Config) void {
    cfg.deinit();
    gpa.destroy(cfg);
}

fn validateReload(gpa: std.mem.Allocator, cfg: *config.Config, active: *const config.Config, globals: ?[]const u8, diag: *Diag) !void {
    if (globals) |g| try applyGlobals(cfg, g, diag);
    try multiplex.validate(cfg);
    try cfg.load_balancer.validateWorkers(cfg.worker_processes);
    if (tls.enabled) {
        try tls.validateConfig(gpa, cfg, diag);
    } else {
        for (cfg.listens) |l| if (l.opts.ssl) {
            return error.Tls;
        };
    }
    for (cfg.acme) |ac| {
        if (ac.challenge != .@"http-01") continue;
        for (active.listens) |l| {
            if (!l.opts.quic and l.addr.port == ac.http_port) {
                diag.add(.emerg, null, 0, "ACME HTTP-01 port {d} is occupied by the active configuration", .{ac.http_port});
                return error.AcmePortConflict;
            }
        }
    }
}

fn master(gpa: std.mem.Allocator, cfg0: *config.Config, copts: config.Options, conf_path: []const u8, o: Opts, sources: *z.http.config_watch.Sources) u8 {
    var watcher: z.http.config_watch.Watcher = .{ .active = sources.*, .attempt = .{ .gpa = gpa } };
    sources.* = .{ .gpa = gpa };
    defer watcher.deinit();
    // worker_rlimit_nofile, or as high as the hard limit allows (bounded) when unset
    raiseNofile(cfg0.worker_rlimit_nofile);
    installSignals(masterSignal);
    var diag: Diag = .{ .gpa = gpa, .echo = true };
    for (cfg0.acme) |ac| if (!z.http.acme.ready(ac)) {
        if (!tls.enabled) {
            eprint("zhttpd: [emerg] automatic ACME requires a TLS-enabled build\n", .{});
            return 1;
        }
        tls.validateConfig(gpa, cfg0, &diag) catch return 1;
        eprint("zhttpd: issuing initial ACME certificate {s} for {s}\n", .{ ac.name, ac.domain });
        const child = z.http.acme.start(gpa, ac, 2) catch return 1;
        var status: c_int = 0;
        const started = z.server.loop.nowMs();
        while (c.waitpid(child, &status, c.W.NOHANG) == 0) {
            if (m_terminate or m_quit or z.server.loop.nowMs() - started > @as(i64, ac.operation_timeout_seconds) * 1000) {
                _ = kill(child, 9);
                _ = c.waitpid(child, &status, 0);
                return 1;
            }
            sleepMs(100);
        }
        if (status != 0 or !z.http.acme.ready(ac)) {
            eprint("zhttpd: [emerg] initial ACME issuance failed; HTTPS was not started\n", .{});
            return 1;
        }
    };
    var acme_jobs = z.http.acme.renewals(gpa, cfg0.acme, &.{}) catch return 1;
    defer gpa.free(acme_jobs);
    var gen = prepare(gpa, cfg0, &.{}, &diag) catch return 1;
    writePid(cfg0);
    var ab: [64]u8 = undefined;
    for (cfg0.listens) |l| eprint("zhttpd: listening on {s}{s}{s}:{d}{s}\n", .{ if (l.addr.family == .v6) "[" else "", l.addr.formatIp(&ab), if (l.addr.family == .v6) "]" else "", l.addr.port, if (l.opts.quic) " (quic)" else if (l.opts.ssl) " (ssl)" else "" });
    for (gen.pids, 0..) |*p, k| p.* = spawnWorker(gpa, &gen, k);
    eprint("zhttpd: master {d} started {d} worker(s), event method {s}\n", .{ c.getpid(), gen.pids.len, z.server.loop.name });

    var acme_pid: c.pid_t = 0;
    var acme_started: i64 = 0;
    var acme_before: ?[32]u8 = null;
    var acme_active: z.http.acme.Settings = undefined;
    // A candidate owns its settings until activated or discarded. An obsolete
    // issuer may finish cleanup, but cannot activate its superseded candidate.
    var pending: ?*config.Config = null;
    var retired: ?*config.Config = null;
    var acme_pending = false;
    var acme_cancelled = false;
    var refresh_tls = false;
    var old: std.ArrayList(c.pid_t) = .empty; // workers of previous generations, shutting down
    while (true) {
        sleepMs(100);
        // reap children
        while (true) {
            var status: c_int = 0;
            const pid = c.waitpid(-1, &status, c.W.NOHANG);
            if (pid <= 0) break;
            if (pid == acme_pid) {
                acme_pid = 0;
                if (acme_cancelled) {
                    acme_cancelled = false;
                    if (retired) |cfg| destroyConfig(gpa, cfg);
                    retired = null;
                    continue;
                }
                if (acme_pending) {
                    acme_pending = false;
                    if (status != 0 or !z.http.acme.ready(acme_active)) {
                        eprint("zhttpd: [error] ACME reload issuance {s} failed; keeping the old configuration\n", .{acme_active.name});
                        destroyConfig(gpa, pending.?);
                        pending = null;
                    }
                    continue;
                }
                // Use the settings of the completed child, never an array index
                // from a configuration that may have been reordered during reload.
                const ac = acme_active;
                for (acme_jobs) |*job| {
                    if (!std.mem.eql(u8, job.settings.certificate, ac.certificate)) continue;
                    if (status == 0) {
                        const after = z.http.acme.fingerprint(ac.certificate);
                        if (after != null and (acme_before == null or !std.mem.eql(u8, &after.?, &acme_before.?))) refresh_tls = true;
                    } else eprint("zhttpd: [error] ACME renewal {s} failed; current HTTPS configuration remains active\n", .{ac.name});
                    job.next_check_ms = z.server.loop.nowMs() + @as(i64, if (status == 0) job.settings.check_interval_seconds else @min(job.settings.check_interval_seconds, 3600)) * 1000;
                }
                continue;
            }
            var respawn: ?usize = null;
            for (gen.pids, 0..) |p, k| if (p == pid) {
                respawn = k;
            };
            for (old.items, 0..) |p, k| if (p == pid) {
                _ = old.swapRemove(k);
                break;
            };
            if (respawn) |k| {
                if (m_terminate or m_quit) {
                    gen.pids[k] = 0;
                } else {
                    eprint("zhttpd: [alert] worker process {d} exited with status {d}, respawning\n", .{ pid, status });
                    gen.pids[k] = spawnWorker(gpa, &gen, k);
                }
            }
        }
        if (m_terminate or m_quit) {
            if (acme_pid > 0) _ = kill(acme_pid, 9);
            const sig: c_int = if (m_terminate) SIGTERM else SIGQUIT;
            signalAll(&gen, sig);
            for (old.items) |p| _ = kill(p, sig);
            var waited: u32 = 0;
            while (waited < 600) : (waited += 1) {
                var status: c_int = 0;
                const pid = c.waitpid(-1, &status, 0);
                if (pid < 0) break;
            }
            removePid(cfg0);
            return 0;
        }
        const now = z.server.loop.nowMs();
        if (acme_pid > 0 and now - acme_started > @as(i64, acme_active.operation_timeout_seconds) * 1000) _ = kill(acme_pid, 9);
        if (m_reopen) {
            m_reopen = false;
            signalAll(&gen, SIGUSR1);
        }
        if (gen.cfg.auto_reload and watcher.poll(now)) {
            eprint("zhttpd: [notice] configuration files changed, scheduling reload\n", .{});
            m_reload = true;
        }
        if (m_reload) {
            m_reload = false;
            watcher.beginAttempt();
            eprint("zhttpd: [notice] reconfiguring\n", .{});
            if (pending) |cfg| {
                if (acme_pending) {
                    retired = cfg;
                    acme_cancelled = true;
                    acme_pending = false;
                } else destroyConfig(gpa, cfg);
                pending = null;
            }
            const ncfg = z.app_config.load(gpa, conf_path, .{ .prefix = copts.prefix, .conf_prefix = copts.conf_prefix, .strict = copts.strict, .quiet_ignored = copts.quiet_ignored, .compatibility = o.compatibility, .sources = &watcher.attempt }, &diag) catch {
                eprint("zhttpd: [emerg] reload failed, keeping the old configuration\n", .{});
                continue;
            };
            validateReload(gpa, ncfg, gen.cfg, o.globals, &diag) catch {
                destroyConfig(gpa, ncfg);
                eprint("zhttpd: [emerg] reload failed, keeping the old configuration\n", .{});
                continue;
            };
            pending = ncfg;
        }
        var missing: ?z.http.acme.Settings = null;
        if (pending) |cfg| {
            for (cfg.acme) |ac| {
                if (!z.http.acme.ready(ac)) {
                    missing = ac;
                    break;
                }
            }
        }
        // Keep serving the active generation throughout issuance. Activation is
        // one transaction after every certificate has passed TLS validation.
        if ((pending != null and missing == null and !acme_pending and !watcher.unsettled()) or (pending == null and refresh_tls)) {
            const ncfg = pending orelse gen.cfg;
            const owns_candidate = pending != null;
            pending = null;
            refresh_tls = false;
            var socks: std.ArrayList(Sock) = .empty;
            defer socks.deinit(gpa);
            for (gen.cfg.listens, 0..) |l, li| if (gen.fds[li].len == 1) {
                socks.append(gpa, .{ .addr = l.addr, .fd = gen.fds[li][0], .used = false, .quic = l.opts.quic }) catch {};
            };
            const next_jobs = z.http.acme.renewals(gpa, ncfg.acme, acme_jobs) catch {
                if (owns_candidate) destroyConfig(gpa, ncfg);
                eprint("zhttpd: [emerg] cannot allocate ACME renewal schedule\n", .{});
                continue;
            };
            const ngen = prepare(gpa, ncfg, socks.items, &diag) catch {
                gpa.free(next_jobs);
                if (owns_candidate) destroyConfig(gpa, ncfg);
                eprint("zhttpd: [emerg] reload failed, keeping the old configuration\n", .{});
                continue;
            };
            gpa.free(acme_jobs);
            acme_jobs = next_jobs;
            var next = ngen;
            for (next.pids, 0..) |*p, k| p.* = spawnWorker(gpa, &next, k);
            for (gen.pids) |p| if (p > 0) {
                _ = kill(p, SIGQUIT);
                old.append(gpa, p) catch {};
            };
            // close sockets the new generation does not use
            for (socks.items) |s| if (!s.used) net.close(s.fd);
            for (gen.fds) |fds| if (fds.len > 1) for (fds) |fd| net.close(fd);
            gen = next;
            if (owns_candidate) watcher.accept();
            eprint("zhttpd: [notice] reload complete\n", .{});
        }
        if (acme_pid == 0 and missing != null and !watcher.unsettled()) {
            const ac = missing.?;
            eprint("zhttpd: issuing reload ACME certificate {s} for {s}\n", .{ ac.name, ac.domain });
            acme_active = ac;
            acme_started = now;
            acme_pid = z.http.acme.start(gpa, ac, gen.error_fd) catch 0;
            acme_pending = acme_pid > 0;
            if (!acme_pending) {
                eprint("zhttpd: [error] cannot start ACME reload issuance; keeping the old configuration\n", .{});
                destroyConfig(gpa, pending.?);
                pending = null;
            }
        }
        if (acme_pid == 0 and pending == null) {
            var due: ?usize = null;
            for (acme_jobs, 0..) |job, i| {
                if (now >= job.next_check_ms and (due == null or job.next_check_ms < acme_jobs[due.?].next_check_ms)) due = i;
            }
            if (due) |i| {
                const ac = acme_jobs[i].settings;
                acme_active = ac;
                acme_before = z.http.acme.fingerprint(ac.certificate);
                acme_pid = z.http.acme.start(gpa, ac, gen.error_fd) catch 0;
                acme_started = now;
                acme_jobs[i].next_check_ms = now + @as(i64, @min(ac.check_interval_seconds, 3600)) * 1000;
                if (acme_pid == 0) eprint("zhttpd: [error] cannot start ACME renewal {s}\n", .{ac.name});
            }
        }
    }
}
