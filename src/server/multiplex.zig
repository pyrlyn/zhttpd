//! Optional HTTP/2 + HTTP/3 transport. Bounded codec buffers feed a normal Conn,
//! retaining routing, access checks and proxy logic without internal sockets.
const std = @import("std");
const config = @import("../http/config.zig");
const tls = @import("tls.zig");
const net = @import("net.zig");
const Conn = @import("conn.zig").Conn;
const Worker = @import("worker.zig").Worker;
const Listener = @import("worker.zig").Listener;
pub const enabled = @import("build_options").http;
const Open = *const fn (?*anyopaque, *anyopaque, *const net.SockAddr, *const net.SockAddr, c_int) callconv(.c) ?*anyopaque;
const Drive = *const fn (*anyopaque) callconv(.c) void;
extern "c" fn zhttp_h2_new(*tls.SSL, *anyopaque, Open, Drive, Drive, *const net.SockAddr, *const net.SockAddr) ?*anyopaque;
extern "c" fn zhttp_h2_drive(*anyopaque) c_int;
extern "c" fn zhttp_h2_free(*anyopaque) void;
extern "c" fn zhttp_h3_new(*tls.SSL_CTX, c_int, *anyopaque, Open, Drive, Drive, c_uint) ?*anyopaque;
extern "c" fn zhttp_h3_drive(*anyopaque) c_int;
extern "c" fn zhttp_h3_wait_ms(*anyopaque) c_int;
extern "c" fn zhttp_h3_free(*anyopaque) void;
extern "c" fn zhttp_stream_read(*anyopaque, [*]u8, usize) isize;
extern "c" fn zhttp_stream_write(*anyopaque, [*]const u8, usize) isize;
extern "c" fn zhttp_stream_writable(*anyopaque, *[*]u8, u64) isize;
extern "c" fn zhttp_stream_commit(*anyopaque, usize) void;
extern "c" fn zhttp_stream_finish(*anyopaque) void;

pub fn validate(cfg: *const config.Config) !void {
    for (cfg.listens) |l| {
        var h2 = l.opts.http2;
        for (l.entries) |e| h2 = h2 or e.server.http2;
        if ((h2 or l.opts.quic) and !enabled) return error.HttpNotBuilt;
        if (l.opts.http2 and !l.opts.ssl) return error.Http2RequiresTls;
        if (l.opts.quic and l.opts.http2) return error.IncompatibleProtocols;
        if (l.opts.quic) for (l.entries) |e| {
            if (!e.server.http3) return error.Http3Disabled;
            var tls13 = false;
            for (e.server.tls.protocols) |p| tls13 = tls13 or std.mem.eql(u8, p, "TLSv1.3");
            if (!tls13) return error.Http3RequiresTls13;
        };
    }
}

fn openStream(w: *Worker, listen: *const config.Listen, stream: *anyopaque, peer: *const net.SockAddr, local: *const net.SockAddr, protocol: c_int) ?*anyopaque {
    if (w.stopping or w.nconns >= w.max_conns) return null;
    const cn = w.acquire() orelse return null;
    cn.init(w, -1, net.fromSockAddr(peer), listen);
    cn.transport_stream = stream;
    cn.local = net.fromSockAddr(local);
    cn.stream_protocol = @intCast(protocol);
    cn.id = w.next_id;
    w.next_id += 1;
    return cn;
}
fn openH2(user: ?*anyopaque, stream: *anyopaque, peer: *const net.SockAddr, local: *const net.SockAddr, protocol: c_int) callconv(.c) ?*anyopaque {
    const cn: *Conn = @ptrCast(@alignCast(user.?));
    return openStream(cn.w, cn.listen, stream, peer, local, protocol);
}
fn openH3(user: ?*anyopaque, stream: *anyopaque, peer: *const net.SockAddr, local: *const net.SockAddr, protocol: c_int) callconv(.c) ?*anyopaque {
    const l: *Listener = @ptrCast(@alignCast(user.?));
    return openStream(l.worker.?, l.listen, stream, peer, local, protocol);
}
fn driveRequest(ptr: *anyopaque) callconv(.c) void {
    const cn: *Conn = @ptrCast(@alignCast(ptr));
    const previous = cn.w.current;
    cn.w.current = cn;
    defer cn.w.current = previous;
    cn.drive();
}
fn closeRequest(ptr: *anyopaque) callconv(.c) void {
    const cn: *Conn = @ptrCast(@alignCast(ptr));
    cn.close();
}
pub fn readStream(stream: *anyopaque, buf: []u8) net.Io {
    if (!enabled) unreachable;
    const n = zhttp_stream_read(stream, buf.ptr, buf.len);
    return if (n > 0) .{ .ok = @intCast(n) } else if (n == 0) .eof else if (n == -1) .again else .{ .err = 0 };
}
pub fn writeStream(stream: *anyopaque, buf: []const u8) net.Io {
    if (!enabled) unreachable;
    const n = zhttp_stream_write(stream, buf.ptr, buf.len);
    return if (n >= 0) .{ .ok = @intCast(n) } else if (n == -1) .again else .{ .err = 0 };
}
pub fn finishStream(stream: *anyopaque) void {
    if (!enabled) unreachable;
    zhttp_stream_finish(stream);
}
pub fn sendFile(stream: *anyopaque, fd: c_int, offset: u64, remaining: u64) net.Io {
    if (!enabled) unreachable;
    var buffer: [*]u8 = undefined;
    const capacity = zhttp_stream_writable(stream, &buffer, remaining);
    if (capacity == 0) return .again;
    if (capacity < 0) return .{ .err = 0 };
    const len: usize = @intCast(@min(@as(u64, @intCast(capacity)), remaining));
    const n = net.pread(fd, buffer[0..len], offset);
    if (n <= 0) return .{ .err = 0 };
    const written: usize = @intCast(n);
    zhttp_stream_commit(stream, written);
    return .{ .ok = written };
}
pub fn startH2(cn: *Conn) bool {
    if (!enabled) return false;
    var peer: net.SockAddr = undefined;
    var local: net.SockAddr = undefined;
    _ = net.toSockAddr(cn.peer, &peer);
    _ = net.toSockAddr(cn.local, &local);
    cn.multiplex = zhttp_h2_new(cn.ssl.?, cn, openH2, driveRequest, closeRequest, &peer, &local) orelse return false;
    return true;
}
pub fn driveH2(cn: *Conn) void {
    if (!enabled) unreachable;
    const result = zhttp_h2_drive(cn.multiplex.?);
    if (result == 0) cn.close() else if (result == 2) {
        cn.deadline = cn.w.now_ms + cn.defaultServer().conf.keepalive_timeout_ms;
        cn.w.post(cn);
    }
}
pub fn freeH2(cn: *Conn) void {
    if (enabled) if (cn.multiplex) |p| zhttp_h2_free(p);
    cn.multiplex = null;
}
pub fn startH3(l: *Listener, w: *Worker) bool {
    if (!enabled) return false;
    l.worker = w;
    l.quic = zhttp_h3_new(l.sni.?.default_ctx, l.fd, l, openH3, driveRequest, closeRequest, w.max_conns) orelse return false;
    return true;
}
pub fn driveH3(l: *Listener) void {
    if (enabled) if (l.quic) |p| {
        l.pending = zhttp_h3_drive(p) != 0;
    };
}
pub fn waitH3(l: *const Listener) i32 {
    if (enabled) if (l.quic) |p| return zhttp_h3_wait_ms(p);
    return 5;
}
pub fn freeH3(l: *Listener) void {
    if (enabled) if (l.quic) |p| zhttp_h3_free(p);
    l.quic = null;
    l.pending = false;
}
