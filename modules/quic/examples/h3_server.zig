//! Minimal HTTP/3 server answering every request with a fixed body.
//! Used for interop checks and early load measurements.
//!
//!   h3-server --port 8443 --cert cert.pem --key key.pem [--size 612]
const std = @import("std");
const zquic = @import("zquic");
const tls = zquic.tls;
const h3 = zquic.h3;

extern "c" fn TLS_server_method() *const anyopaque;
extern "c" fn SSL_CTX_new(m: *const anyopaque) ?*tls.SSL_CTX;
extern "c" fn SSL_CTX_ctrl(ctx: *tls.SSL_CTX, cmd: c_int, larg: c_long, parg: ?*anyopaque) c_long;
extern "c" fn SSL_CTX_use_certificate_chain_file(ctx: *tls.SSL_CTX, file: [*:0]const u8) c_int;
extern "c" fn SSL_CTX_use_PrivateKey_file(ctx: *tls.SSL_CTX, file: [*:0]const u8, ty: c_int) c_int;
extern "c" fn SSL_CTX_set_alpn_select_cb(ctx: *tls.SSL_CTX, cb: *const fn (?*tls.SSL, *[*]const u8, *u8, [*]const u8, c_uint, ?*anyopaque) callconv(.c) c_int, arg: ?*anyopaque) void;
extern "c" fn socket(domain: c_int, ty: c_int, proto: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, val: ?*const anyopaque, len: u32) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn poll(fds: [*]PollFd, n: c_ulong, timeout: c_int) c_int;
extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) ?*anyopaque;

const PollFd = extern struct { fd: c_int, events: i16, revents: i16 };
const builtin = @import("builtin");
const is_linux = builtin.os.tag == .linux;

fn alpnSelect(_: ?*tls.SSL, out: *[*]const u8, outlen: *u8, in: [*]const u8, inlen: c_uint, _: ?*anyopaque) callconv(.c) c_int {
    var i: usize = 0;
    while (i < inlen) {
        const l = in[i];
        if (i + 1 + l > inlen) break;
        if (std.mem.eql(u8, in[i + 1 ..][0..l], "h3")) {
            out.* = in + i + 1;
            outlen.* = l;
            return 0; // SSL_TLSEXT_ERR_OK
        }
        i += 1 + l;
    }
    return 3; // SSL_TLSEXT_ERR_NOACK -> handshake fails without ALPN
}

var body: []u8 = &.{};
var content_length: []const u8 = "";
var stop = std.atomic.Value(bool).init(false);

const Resp = struct { off: usize = 0 };

fn onRequest(_: ?*anyopaque, r: *h3.Request) void {
    const st = std.heap.c_allocator.create(Resp) catch {
        r.reset(h3.Error.internal);
        r.release();
        return;
    };
    st.* = .{};
    r.app = st;
    const fields = [_]h3.Field{
        .{ .name = "server", .value = "zquic" },
        .{ .name = "content-type", .value = "text/html" },
        .{ .name = "content-length", .value = content_length },
    };
    r.sendHeaders(200, &fields, body.len == 0) catch {
        r.reset(h3.Error.internal);
        done(r);
        return;
    };
    pump(r);
}

fn pump(r: *h3.Request) void {
    const st: *Resp = @ptrCast(@alignCast(r.app orelse return));
    while (st.off < body.len) {
        const n = r.writeData(body[st.off..]) catch {
            done(r);
            return;
        };
        if (n == 0) return;
        st.off += n;
    }
    if (body.len > 0) r.finish();
    done(r);
}

fn done(r: *h3.Request) void {
    if (r.app) |p| std.heap.c_allocator.destroy(@as(*Resp, @ptrCast(@alignCast(p))));
    r.app = null;
    r.release();
}

fn onWritable(_: ?*anyopaque, r: *h3.Request) void {
    pump(r);
}

fn onAborted(_: ?*anyopaque, r: *h3.Request, _: u64) void {
    done(r);
}

fn onSignal(_: c_int) callconv(.c) void {
    stop.store(true, .monotonic);
}

pub fn main(init: std.process.Init) !void {
    const a = std.heap.c_allocator;
    var port: u16 = 8443;
    var cert: [:0]const u8 = "cert.pem";
    var key: [:0]const u8 = "key.pem";
    var size: usize = 612;
    var it = try init.minimal.args.iterateAllocator(a);
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) port = try std.fmt.parseInt(u16, it.next().?, 10);
        if (std.mem.eql(u8, arg, "--cert")) cert = it.next().?;
        if (std.mem.eql(u8, arg, "--key")) key = it.next().?;
        if (std.mem.eql(u8, arg, "--size")) size = try std.fmt.parseInt(usize, it.next().?, 10);
    }
    body = try a.alloc(u8, size);
    @memset(body, 'a');
    var clbuf: [24]u8 = undefined;
    content_length = try std.fmt.bufPrint(&clbuf, "{d}", .{size});

    const ctx = SSL_CTX_new(TLS_server_method()) orelse return error.Ssl;
    _ = SSL_CTX_ctrl(ctx, 123, 0x0304, null); // min TLS 1.3
    _ = SSL_CTX_ctrl(ctx, 124, 0x0304, null); // max TLS 1.3
    if (SSL_CTX_use_certificate_chain_file(ctx, cert) != 1) return error.Cert;
    if (SSL_CTX_use_PrivateKey_file(ctx, key, 1) != 1) return error.Key;
    SSL_CTX_set_alpn_select_cb(ctx, alpnSelect, null);

    const fd = socket(2, 2, 0);
    if (fd < 0) return error.Socket;
    var sa: [16]u8 = @splat(0);
    if (is_linux) {
        std.mem.writeInt(u16, sa[0..2], 2, .little);
    } else {
        sa[0] = 16;
        sa[1] = 2;
    }
    std.mem.writeInt(u16, sa[2..4], port, .big);
    const one: c_int = 1;
    _ = setsockopt(fd, if (is_linux) 1 else 0xffff, if (is_linux) 2 else 4, &one, 4); // SO_REUSEADDR
    if (bind(fd, &sa, 16) != 0) return error.Bind;
    _ = fcntl(fd, 4, @as(c_int, if (is_linux) 0o4000 else 4)); // O_NONBLOCK

    const sv = try h3.Server.init(a, ctx, .{}, .{
        .request = onRequest,
        .writable = onWritable,
        .aborted = onAborted,
    });
    var bound = zquic.conn.Addr{ .port = port };
    bound.ip[10] = 0xff;
    bound.ip[11] = 0xff;
    const sock = try zquic.udp.Socket.init(a, fd, bound);
    sv.ep.sink = sock.sink();
    _ = signal(2, onSignal);
    _ = signal(15, onSignal);
    std.debug.print("h3-server listening on udp/{d}, body {d} bytes\n", .{ port, size });

    var shutting = false;
    while (true) {
        if (stop.load(.monotonic) and !shutting) {
            shutting = true;
            sv.shutdown();
            sv.ep.flush();
        }
        if (shutting and sv.ep.connCount() == 0) break;
        var pfd = [_]PollFd{.{ .fd = fd, .events = 1, .revents = 0 }};
        _ = poll(&pfd, 1, sv.ep.timeoutMs());
        _ = sock.receive(sv.ep, 8);
        sv.ep.updateClock();
        sv.ep.onTimers();
        sv.ep.flush();
    }
    sv.deinit();
    sock.deinit(a);
}
