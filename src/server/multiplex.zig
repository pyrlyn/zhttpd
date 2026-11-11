//! Optional HTTP/2 + HTTP/3 transport. The codec owns one socketpair endpoint;
//! the other is a normal Conn, retaining routing, access checks and proxy logic.
const std = @import("std");
const config = @import("../http/config.zig");
const tls = @import("tls.zig");
const net = @import("net.zig");
const Conn = @import("conn.zig").Conn;
const Worker = @import("worker.zig").Worker;
const Listener = @import("worker.zig").Listener;
pub const enabled = @import("build_options").http;
const Open = *const fn (?*anyopaque, c_int, *const net.SockAddr, *const net.SockAddr, c_int) callconv(.c) c_int;
extern "c" fn zhttp_h2_new(*tls.SSL, *anyopaque, Open, *const net.SockAddr, *const net.SockAddr) ?*anyopaque;
extern "c" fn zhttp_h2_drive(*anyopaque) c_int;
extern "c" fn zhttp_h2_free(*anyopaque) void;
extern "c" fn zhttp_h3_new(*tls.SSL_CTX, c_int, *anyopaque, Open, c_uint) ?*anyopaque;
extern "c" fn zhttp_h3_drive(*anyopaque) void;
extern "c" fn zhttp_h3_free(*anyopaque) void;

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

fn openStream(w: *Worker, listen: *const config.Listen, fd: c_int, peer: *const net.SockAddr, local: *const net.SockAddr, protocol: c_int) c_int {
    if (w.stopping or w.nconns >= w.max_conns) return 0;
    const cn = w.acquire() orelse return 0;
    cn.init(w, fd, net.fromSockAddr(peer), listen);
    cn.local = net.fromSockAddr(local);
    cn.stream_protocol = @intCast(protocol);
    cn.id = w.next_id;
    w.next_id += 1;
    w.loop.add(fd, @intFromPtr(&cn.tag)) catch {
        // The codec closes fd on failure; do not close it twice.
        cn.state = .closed;
        w.release(cn);
        return 0;
    };
    return 1;
}
fn openH2(user: ?*anyopaque, fd: c_int, peer: *const net.SockAddr, local: *const net.SockAddr, protocol: c_int) callconv(.c) c_int {
    const cn: *Conn = @ptrCast(@alignCast(user.?));
    return openStream(cn.w, cn.listen, fd, peer, local, protocol);
}
fn openH3(user: ?*anyopaque, fd: c_int, peer: *const net.SockAddr, local: *const net.SockAddr, protocol: c_int) callconv(.c) c_int {
    const l: *Listener = @ptrCast(@alignCast(user.?));
    return openStream(l.worker.?, l.listen, fd, peer, local, protocol);
}
pub fn startH2(cn: *Conn) bool {
    if (!enabled) return false;
    var peer: net.SockAddr = undefined;
    var local: net.SockAddr = undefined;
    _ = net.toSockAddr(cn.peer, &peer);
    _ = net.toSockAddr(cn.local, &local);
    cn.multiplex = zhttp_h2_new(cn.ssl.?, cn, openH2, &peer, &local) orelse return false;
    return true;
}
pub fn driveH2(cn: *Conn) void {
    if (!enabled) unreachable;
    const result = zhttp_h2_drive(cn.multiplex.?);
    if (result == 0) cn.close() else if (result == 2) {
        cn.deadline = cn.w.now_ms + cn.defaultServer().conf.keepalive_timeout_ms;
    }
}
pub fn freeH2(cn: *Conn) void {
    if (enabled) if (cn.multiplex) |p| zhttp_h2_free(p);
    cn.multiplex = null;
}
pub fn startH3(l: *Listener, w: *Worker) bool {
    if (!enabled) return false;
    l.worker = w;
    l.quic = zhttp_h3_new(l.sni.?.default_ctx, l.fd, l, openH3, w.max_conns) orelse return false;
    return true;
}
pub fn driveH3(l: *Listener) void {
    if (enabled) if (l.quic) |p| zhttp_h3_drive(p);
}
pub fn freeH3(l: *Listener) void {
    if (enabled) if (l.quic) |p| zhttp_h3_free(p);
    l.quic = null;
}
