//! Optional HTTP/2 + HTTP/3 transport. Bounded codec buffers feed a normal Conn,
//! retaining routing, access checks and proxy logic without internal sockets.
const std = @import("std");
const config = @import("../http/config.zig");
const tls = @import("tls.zig");
const net = @import("net.zig");
const Addr = @import("../http/addr.zig").Addr;
const Conn = @import("conn.zig").Conn;
const Worker = @import("worker.zig").Worker;
const Listener = @import("worker.zig").Listener;
const h3 = @import("h3.zig");
pub const enabled = @import("build_options").http;
const Open = *const fn (?*anyopaque, *anyopaque, *const net.SockAddr, *const net.SockAddr, c_int) callconv(.c) ?*anyopaque;
const Drive = *const fn (*anyopaque) callconv(.c) void;
extern "c" fn zhttp_h2_new(*tls.SSL, *anyopaque, Open, Drive, Drive, *const net.SockAddr, *const net.SockAddr) ?*anyopaque;
extern "c" fn zhttp_h2_drive(*anyopaque) c_int;
extern "c" fn zhttp_h2_free(*anyopaque) void;
extern "c" fn zhttp_tx_attach(*tls.SSL) c_int;
extern "c" fn zhttp_stream_read(*anyopaque, [*]u8, usize) isize;
extern "c" fn zhttp_stream_write(*anyopaque, [*]const u8, usize) isize;
extern "c" fn zhttp_stream_finish(*anyopaque) void;
extern "c" fn zhttp_stream_file(*anyopaque, c_int, u64, u64) isize;

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
    return openStreamAddr(w, listen, stream, net.fromSockAddr(peer), net.fromSockAddr(local), @intCast(protocol));
}
pub fn openStreamAddr(w: *Worker, listen: *const config.Listen, stream: *anyopaque, peer: Addr, local: Addr, protocol: u8) ?*anyopaque {
    if (w.stopping or w.nconns >= w.max_conns) return null;
    const cn = w.acquire() orelse return null;
    cn.init(w, -1, peer, listen);
    cn.transport_stream = stream;
    cn.local = local;
    cn.stream_protocol = protocol;
    cn.id = w.next_id;
    w.next_id += 1;
    return cn;
}
fn openH2(user: ?*anyopaque, stream: *anyopaque, peer: *const net.SockAddr, local: *const net.SockAddr, protocol: c_int) callconv(.c) ?*anyopaque {
    const cn: *Conn = @ptrCast(@alignCast(user.?));
    return openStream(cn.w, cn.listen, stream, peer, local, protocol);
}
fn driveRequest(ptr: *anyopaque) callconv(.c) void {
    driveRequestConn(@ptrCast(@alignCast(ptr)));
}
pub fn driveRequestConn(cn: *Conn) void {
    const previous = cn.w.current;
    cn.w.current = cn;
    defer cn.w.current = previous;
    cn.drive();
}
fn closeRequest(ptr: *anyopaque) callconv(.c) void {
    const cn: *Conn = @ptrCast(@alignCast(ptr));
    cn.close();
}
pub fn readStream(stream: *anyopaque, protocol: u8, buf: []u8) net.Io {
    if (!enabled) unreachable;
    if (protocol == 3) return h3.read(@ptrCast(@alignCast(stream)), buf);
    const n = zhttp_stream_read(stream, buf.ptr, buf.len);
    return if (n > 0) .{ .ok = @intCast(n) } else if (n == 0) .eof else if (n == -1) .again else .{ .err = 0 };
}
pub fn writeStream(stream: *anyopaque, protocol: u8, buf: []const u8) net.Io {
    if (!enabled) unreachable;
    if (protocol == 3) return h3.write(@ptrCast(@alignCast(stream)), buf);
    const n = zhttp_stream_write(stream, buf.ptr, buf.len);
    return if (n >= 0) .{ .ok = @intCast(n) } else if (n == -1) .again else .{ .err = 0 };
}
pub fn finishStream(stream: *anyopaque, protocol: u8) void {
    if (!enabled) unreachable;
    if (protocol == 3) return h3.finishStream(@ptrCast(@alignCast(stream)));
    zhttp_stream_finish(stream);
}
pub fn sendFile(stream: *anyopaque, protocol: u8, fd: c_int, offset: u64, remaining: u64) net.Io {
    if (!enabled) unreachable;
    if (protocol == 3) return h3.sendFile(@ptrCast(@alignCast(stream)), fd, offset, remaining);
    const n = zhttp_stream_file(stream, fd, offset, remaining);
    return if (n > 0) .{ .ok = @intCast(n) } else if (n == -1) .again else .{ .err = 0 };
}
/// Seal HTTP/2 output records in userspace (tls_tx.c). Must run before the
/// application write keys exist, i.e. during ALPN selection.
pub fn attachTx(ssl: *tls.SSL) void {
    if (enabled) _ = zhttp_tx_attach(ssl);
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
fn h3Server(l: *const Listener) ?*h3.Server {
    return @ptrCast(@alignCast(l.quic orelse return null));
}
pub fn startH3(l: *Listener, w: *Worker) bool {
    if (!enabled) return false;
    l.worker = w;
    l.quic = h3.start(l, w) orelse return false;
    return true;
}
/// Listener readable: receive datagrams, run timers, transmit.
pub fn driveH3(l: *Listener) void {
    if (enabled) if (h3Server(l)) |s| {
        l.pending = h3.drive(s);
    };
}
/// Timers and output for responses produced outside listener events.
pub fn serviceH3(l: *Listener) void {
    if (enabled) if (h3Server(l)) |s| h3.service(s);
}
pub fn waitH3(l: *const Listener) i32 {
    if (enabled) if (h3Server(l)) |s| return h3.waitMs(s);
    return 1000;
}
pub fn freeH3(l: *Listener) void {
    if (enabled) if (h3Server(l)) |s| h3.free(s);
    l.quic = null;
    l.pending = false;
}
