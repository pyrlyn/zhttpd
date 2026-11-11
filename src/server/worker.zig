//! A worker process: one event loop, a pool of connections, timers, logs.
const std = @import("std");
const filecache = @import("filecache.zig");
const c = std.c;
const config = @import("../http/config.zig");
const loop_mod = @import("loop.zig");
const net = @import("net.zig");
const tls = @import("tls.zig");
const multiplex = @import("multiplex.zig");
const vars = @import("vars.zig");
const conn_mod = @import("conn.zig");
const Conn = conn_mod.Conn;
const Tag = conn_mod.Tag;
const proxy = @import("proxy.zig");
const response = @import("../http/response.zig");

pub const Listener = struct {
    tag: Tag align(8) = .{ .kind = .listener },
    fd: c_int,
    listen: *const config.Listen,
    sni: ?*tls.SniTable = null,
    quic: ?*anyopaque = null,
    worker: ?*Worker = null,
};

const logging = @import("logging");
pub const LogLevel = logging.Level;

/// Signals set these; the loop checks them after every wakeup.
pub var sig_terminate: bool = false;
pub var sig_quit: bool = false;
pub var sig_reopen: bool = false;

pub const LogFile = struct { path: []const u8, fd: c_int };

pub const Worker = struct {
    gpa: std.mem.Allocator,
    cfg: *config.Config,
    loop: loop_mod.Loop,
    listeners: []Listener,
    logs: std.ArrayList(LogFile) = .empty,
    error_fd: c_int,
    error_level: u8,
    active: ?*Conn = null,
    nconns: u32 = 0,
    max_conns: u32,
    balancer: @import("load_balancer").Runtime = .{},
    pool: ?*Conn = null,
    graveyard: ?*Conn = null,
    posted_head: ?*Conn = null,
    posted_tail: ?*Conn = null,
    now_ms: i64 = 0,
    wall_sec: i64 = 0,
    wall_usec: i64 = 0,
    gmtoff: i64 = 0,
    date_sec: i64 = -1,
    date_buf: [29]u8 = undefined,
    modified_sec: ?i64 = null,
    modified_buf: [29]u8 = undefined,
    next_id: u64 = 1,
    stopping: bool = false,
    page_buf: [response.page_buffer_size]u8 = undefined,
    log_buf: [65536]u8 = undefined,
    accept_paused_until: i64 = 0,
    /// connection being processed, for the `client: ..., request: ...` suffix of error logs
    current: ?*Conn = null,
    files: filecache.Cache = .{},
    tokens_on: []const u8 = "zhttpd/" ++ vars.version,

    pub fn init(gpa: std.mem.Allocator, cfg: *config.Config, listeners: []Listener, error_fd: c_int, worker_index: u32) !Worker {
        _ = worker_index;
        var w: Worker = .{
            .gpa = gpa,
            .cfg = cfg,
            .loop = try loop_mod.Loop.init(),
            .listeners = listeners,
            .error_fd = error_fd,
            .error_level = cfg.error_log.level,
            .max_conns = cfg.worker_connections,
        };
        errdefer w.loop.deinit();
        w.files = try filecache.Cache.init(gpa, cfg.open_file_cache_max);
        errdefer w.files.deinit(gpa);
        w.balancer = try @import("load_balancer").Runtime.init(gpa, cfg.load_balancer, cfg.worker_processes);
        w.updateTime();
        w.gmtoff = localOffset(w.wall_sec);
        return w;
    }

    /// Release an embedded worker after run() returns.
    pub fn deinit(w: *Worker) void {
        w.balancer.deinit();
        while (w.active) |cn| cn.close();
        w.bury();
        while (w.pool) |cn| {
            w.pool = cn.next;
            std.heap.page_allocator.destroy(cn);
        }
        for (w.logs.items) |l| if (l.fd > 2) net.close(l.fd);
        w.logs.deinit(w.gpa);
        w.files.deinit(w.gpa);
        w.loop.deinit();
    }

    pub fn tokens(w: *Worker, t: config.ServerTokens) []const u8 {
        return switch (t) {
            .on, .build => w.tokens_on,
            .off => "zhttpd",
        };
    }

    pub fn date(w: *Worker) []const u8 {
        if (w.date_sec != w.wall_sec) {
            _ = response.httpDate(&w.date_buf, w.wall_sec);
            w.date_sec = w.wall_sec;
        }
        return &w.date_buf;
    }

    fn updateTime(w: *Worker) void {
        w.now_ms = loop_mod.nowMs();
        const t = loop_mod.wallNow();
        w.wall_sec = t.sec;
        w.wall_usec = t.usec;
    }

    /// Cache formatting only, keyed by the actual file metadata. File contents
    /// and metadata still follow open_file_cache's usual validation rules.
    pub fn lastModified(w: *Worker, sec: i64) []const u8 {
        if (w.modified_sec == null or w.modified_sec.? != sec) {
            _ = response.httpDate(&w.modified_buf, sec);
            w.modified_sec = sec;
        }
        return &w.modified_buf;
    }

    pub fn run(w: *Worker) void {
        defer w.balancer.deinit();
        for (w.listeners) |*l| {
            if (l.listen.opts.quic and !multiplex.startH3(l, w)) {
                w.errlog(.emerg, "cannot initialize HTTP/3 listener", .{});
                return;
            }
            w.loop.addListen(l.fd, @intFromPtr(&l.tag)) catch {
                w.errlog(.emerg, "cannot watch listen socket", .{});
                return;
            };
        }
        var events: [512]loop_mod.Event = undefined;
        var last_sweep: i64 = w.now_ms;
        while (true) {
            if (sig_terminate) break;
            if (sig_reopen) {
                sig_reopen = false;
                w.reopenLogs();
            }
            if (sig_quit and !w.stopping) w.beginStop();
            if (w.stopping and w.nconns == 0) break;
            var modern = false;
            for (w.listeners) |l| modern = modern or l.quic != null;
            var cn_it = w.active;
            while (cn_it) |cn| : (cn_it = cn.next) modern = modern or cn.multiplex != null;
            const evs = w.loop.wait(&events, if (w.posted_head != null) 0 else if (modern) 5 else 1000);
            w.updateTime();
            w.balancer.update(w.nconns);
            for (evs) |ev| w.dispatch(ev);
            for (w.listeners) |*l| multiplex.driveH3(l);
            cn_it = w.active;
            while (cn_it) |cn| {
                cn_it = cn.next;
                if (cn.state == .multiplexed) multiplex.driveH2(cn);
            }
            w.runPosted();
            w.bury();
            if (w.now_ms - last_sweep >= 500) {
                last_sweep = w.now_ms;
                w.sweepTimeouts();
                w.bury();
            }
        }
        for (w.listeners) |*l| multiplex.freeH3(l);
        // close everything
        while (w.active) |cn| cn.close();
        w.bury();
    }

    fn beginStop(w: *Worker) void {
        w.stopping = true;
        for (w.listeners) |*l| {
            multiplex.freeH3(l);
            w.loop.remove(l.fd);
            net.close(l.fd);
        }
        w.listeners = &.{};
        // idle keep-alive connections close now
        var it = w.active;
        while (it) |cn| {
            it = cn.next;
            if ((cn.state == .read_head and cn.rlen == 0 and cn.requests > 0) or cn.state == .multiplexed) cn.close();
        }
        w.bury();
    }

    pub fn post(w: *Worker, cn: *Conn) void {
        if (cn.posted or cn.state == .closed) return;
        cn.posted = true;
        cn.posted_prev = w.posted_tail;
        cn.posted_next = null;
        if (w.posted_tail) |tail| tail.posted_next = cn else w.posted_head = cn;
        w.posted_tail = cn;
    }

    pub fn unpost(w: *Worker, cn: *Conn) void {
        if (!cn.posted) return;
        if (cn.posted_prev) |prev| prev.posted_next = cn.posted_next else w.posted_head = cn.posted_next;
        if (cn.posted_next) |next| next.posted_prev = cn.posted_prev else w.posted_tail = cn.posted_prev;
        cn.posted = false;
        cn.posted_prev = null;
        cn.posted_next = null;
    }

    fn runPosted(w: *Worker) void {
        const last = w.posted_tail orelse return;
        while (w.posted_head) |cn| {
            w.unpost(cn);
            w.current = cn;
            cn.drive();
            w.current = null;
            // Newly posted continuations wait for the next event-loop turn.
            if (cn == last) break;
        }
    }

    fn dispatch(w: *Worker, ev: loop_mod.Event) void {
        const tag: *align(8) Tag = @ptrFromInt(ev.udata);
        switch (tag.kind) {
            .listener => {
                const l: *Listener = @alignCast(@fieldParentPtr("tag", tag));
                if (l.quic != null) multiplex.driveH3(l) else w.acceptAll(l);
            },
            .client => {
                const cn: *Conn = @alignCast(@fieldParentPtr("tag", tag));
                if (cn.state == .closed) return;
                if (cn.stream_protocol != 0 and ev.eof) {
                    cn.close();
                    return;
                }
                if (ev.readable or ev.eof) cn.tls_read.ready = true;
                if (ev.eof) cn.tls_read.eof = true;
                w.current = cn;
                defer w.current = null;
                cn.drive();
            },
            .upstream => {
                const cn: *Conn = @alignCast(@fieldParentPtr("up_tag", tag));
                if (cn.state != .proxy) return;
                w.current = cn;
                defer w.current = null;
                proxy.onUpstreamEvent(cn, ev.writable or ev.eof);
            },
        }
    }

    fn acceptAll(w: *Worker, l: *Listener) void {
        if (w.stopping or w.now_ms < w.accept_paused_until) return;
        var budget: u32 = if (w.cfg.multi_accept) 1024 else 64;
        while (budget > 0) : (budget -= 1) {
            switch (net.accept(l.fd)) {
                .ok => |acc| {
                    if (w.nconns >= w.max_conns) {
                        w.errlog(.alert, "{d} worker_connections are not enough", .{w.max_conns});
                        net.close(acc.fd);
                        continue;
                    }
                    const cn = w.acquire() orelse {
                        net.close(acc.fd);
                        return;
                    };
                    cn.init(w, acc.fd, acc.peer, l.listen);
                    cn.id = w.next_id;
                    w.next_id += 1;
                    if (l.listen.entries[0].server.conf.tcp_nodelay) net.setNoDelay(acc.fd);
                    if (tls.enabled) if (l.sni) |sni| {
                        cn.ssl = tls.newConn(sni, acc.fd) orelse {
                            cn.state = .read_head;
                            cn.close();
                            continue;
                        };
                        cn.state = .handshake;
                    };
                    w.loop.add(acc.fd, @intFromPtr(&cn.tag)) catch {
                        cn.close();
                        continue;
                    };
                    // Start TLS from its readiness event. Handshakes inside
                    // multi_accept delay connections that are already active.
                    if (tls.enabled and cn.ssl != null) continue;
                    // data usually arrives with the connection: try right away
                    w.current = cn;
                    cn.drive();
                    w.current = null;
                },
                .again => return,
                .err => |e| {
                    w.errlog(.alert, "accept() failed ({d}: {s})", .{ e, @import("../os.zig").strerror(e) });
                    if (e == @backingInt(c.E.MFILE) or e == @backingInt(c.E.NFILE)) w.accept_paused_until = w.now_ms + 500;
                    return;
                },
            }
        }
    }

    pub fn acquire(w: *Worker) ?*Conn {
        const cn = if (w.pool) |p| blk: {
            w.pool = p.next;
            break :blk p;
        } else blk: {
            const p = std.heap.page_allocator.create(Conn) catch return null;
            p.* = .{};
            break :blk p;
        };
        cn.prev = null;
        cn.next = w.active;
        if (w.active) |a| a.prev = cn;
        w.active = cn;
        w.nconns += 1;
        w.balancer.update(w.nconns);
        return cn;
    }

    /// Unlink a closed connection; it is recycled after the current event batch.
    pub fn release(w: *Worker, cn: *Conn) void {
        if (cn.prev) |p| p.next = cn.next else w.active = cn.next;
        if (cn.next) |n| n.prev = cn.prev;
        w.nconns -= 1;
        w.balancer.update(w.nconns);
        cn.prev = null;
        cn.next = w.graveyard;
        w.graveyard = cn;
    }

    fn bury(w: *Worker) void {
        while (w.graveyard) |cn| {
            w.graveyard = cn.next;
            cn.next = w.pool;
            w.pool = cn;
        }
    }

    fn sweepTimeouts(w: *Worker) void {
        var it = w.active;
        while (it) |cn| {
            it = cn.next;
            if (cn.deadline != 0 and cn.deadline <= w.now_ms) cn.onTimeout();
        }
    }

    // ------------------------------------------------------------------ logs

    /// Access log files are opened on first use (O_APPEND, shared safely by workers).
    fn logFd(w: *Worker, path: []const u8) c_int {
        for (w.logs.items) |l| if (std.mem.eql(u8, l.path, path)) return l.fd;
        var fd: c_int = -1;
        if (std.mem.eql(u8, path, "/dev/stdout")) fd = 1 else if ((std.mem.eql(u8, path, "/dev/stderr") or std.mem.eql(u8, path, "stderr"))) fd = 2 else {
            const z = w.gpa.dupeSentinel(u8, path, 0) catch return -1;
            defer w.gpa.free(z);
            fd = c.open(z, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
            if (fd < 0) {
                const message = "zhttpd: cannot open log file\n";
                _ = c.write(2, message.ptr, message.len);
            }
        }
        w.logs.append(w.gpa, .{ .path = path, .fd = fd }) catch {};
        return fd;
    }

    pub fn accessLog(w: *Worker, cn: *Conn) void {
        if (!w.cfg.logging_enabled) return;
        const logs = cn.ctx.conf.access_logs orelse return;
        if (logs.len == 0) return;
        cn.ctx.now_ms = w.now_ms;
        cn.ctx.wall_sec = w.wall_sec;
        cn.ctx.wall_usec = w.wall_usec;
        for (logs) |lg| {
            const fd = w.logFd(lg.path);
            if (fd < 0) continue;
            var line: std.ArrayList(u8) = .initBuffer(&w.log_buf);
            var fba: std.heap.FixedBufferAllocator = .init(cn.arena_mem[cn.fba.end_index..]);
            const a = fba.allocator();
            for (lg.format.expr.parts) |p| switch (p) {
                .lit => |s| logging.appendBounded(&line, s),
                .v => |v| {
                    var tmp: std.ArrayList(u8) = .empty;
                    vars.appendVar(a, &cn.ctx, v, &tmp, 0) catch {};
                    if (tmp.items.len == 0) logging.appendBounded(&line, "-") else logging.appendEscaped(&line, tmp.items, lg.format.escape);
                },
            };
            logging.appendBounded(&line, "\n");
            _ = c.write(fd, line.items.ptr, line.items.len);
        }
    }

    pub fn errlog(w: *Worker, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        if (!w.cfg.logging_enabled) return;
        const local_log = if (w.current) |cn| (if (cn.in_request) cn.ctx.conf.error_log else null) else null;
        if (@backingInt(level) > (if (local_log) |l| l.level else w.error_level)) return;
        const local_fd = if (local_log) |l| w.logFd(l.path) else w.error_fd;
        const output_fd = if (local_fd >= 0) local_fd else 2;
        var buf: [2048]u8 = undefined;
        const cv = response.civil(w.wall_sec + w.gmtoff);
        var bw: std.Io.Writer = .fixed(&buf);
        bw.print("{d:0>4}/{d:0>2}/{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} [{s}] {d}#0: ", .{ @as(u64, @intCast(cv.year)), cv.month, cv.day, cv.hour, cv.min, cv.sec, @tagName(level), c.getpid() }) catch {};
        bw.print(fmt, args) catch {};
        if (w.current) |cn| if (cn.in_request) {
            var ab: [48]u8 = undefined;
            bw.print(", client: {s}, server: {s}, request: \"{s}\"", .{ cn.peer.formatIp(&ab), cn.ctx.srv.primary_name, cn.req.line }) catch {};
            if (cn.ctx.upstream_addr.len > 0) bw.print(", upstream: \"http://{s}{s}\"", .{ cn.ctx.upstream_addr, cn.req.path }) catch {};
            if (cn.req.host) |h| bw.print(", host: \"{s}\"", .{h}) catch {};
        };
        bw.writeAll("\n") catch {};
        const out = bw.buffered();
        _ = c.write(output_fd, out.ptr, out.len);
    }

    fn reopenLogs(w: *Worker) void {
        for (w.logs.items) |*l| {
            if (l.fd <= 2) continue;
            const z = w.gpa.dupeSentinel(u8, l.path, 0) catch continue;
            defer w.gpa.free(z);
            const fd = c.open(z, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
            if (fd >= 0) {
                _ = c.dup2(fd, l.fd);
                net.close(fd);
            }
        }
    }
};

extern "c" fn tzset() void;

test "posted continuations are unique and can be removed before pool reuse" {
    var w: Worker = undefined;
    w.posted_head = null;
    w.posted_tail = null;
    var conns: [3]Conn = @splat(.{});
    for (&conns) |*cn| w.post(cn);
    w.post(&conns[1]);
    try std.testing.expect(w.posted_head == &conns[0]);
    try std.testing.expect(w.posted_tail == &conns[2]);
    w.unpost(&conns[1]);
    try std.testing.expect(conns[0].posted_next == &conns[2]);
    try std.testing.expect(conns[2].posted_prev == &conns[0]);
    try std.testing.expect(!conns[1].posted);
    w.unpost(&conns[0]);
    w.unpost(&conns[2]);
    w.unpost(&conns[2]);
    try std.testing.expect(w.posted_head == null and w.posted_tail == null);
    conns[1].state = .closed;
    w.post(&conns[1]);
    try std.testing.expect(w.posted_head == null);
    conns[1].state = .read_head;
    w.post(&conns[1]);
    try std.testing.expect(w.posted_head == &conns[1] and w.posted_tail == &conns[1]);
    try std.testing.expect(conns[1].posted_prev == null and conns[1].posted_next == null);
}

extern "c" fn localtime_r(t: *const c.time_t, out: *Tm) ?*Tm;
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

pub fn localOffset(now: i64) i64 {
    tzset();
    var tm: Tm = undefined;
    const t: c.time_t = @intCast(now);
    if (localtime_r(&t, &tm) == null) return 0;
    return tm.gmtoff;
}
