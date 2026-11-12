//! Socket helpers over libc: listen/accept/connect, non-blocking I/O results, sendfile.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const Addr = @import("../http/addr.zig").Addr;
const os = @import("../os.zig");

pub const Io = union(enum) { ok: usize, again, eof, err: c_int };

pub fn errno() c_int {
    return os.errnoInt();
}

fn isAgain(e: c_int) bool {
    return e == @backingInt(c.E.AGAIN) or e == @backingInt(c.E.INTR);
}

pub fn read(fd: c_int, buf: []u8) Io {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n > 0) return .{ .ok = @intCast(n) };
        if (n == 0) return .eof;
        const e = errno();
        if (e == @backingInt(c.E.INTR)) continue;
        if (isAgain(e)) return .again;
        return .{ .err = e };
    }
}

pub fn write(fd: c_int, buf: []const u8) Io {
    while (true) {
        const n = c.write(fd, buf.ptr, buf.len);
        if (n >= 0) return .{ .ok = @intCast(n) };
        const e = errno();
        if (e == @backingInt(c.E.INTR)) continue;
        if (isAgain(e)) return .again;
        return .{ .err = e };
    }
}

pub fn writev(fd: c_int, iov: []const c.iovec_const) Io {
    while (true) {
        const n = c.writev(fd, iov.ptr, @intCast(iov.len));
        if (n >= 0) return .{ .ok = @intCast(n) };
        const e = errno();
        if (e == @backingInt(c.E.INTR)) continue;
        if (isAgain(e)) return .again;
        return .{ .err = e };
    }
}

const darwin_c = struct {
    extern "c" fn sendfile(fd: c_int, s: c_int, offset: i64, len: *i64, hdtr: ?*anyopaque, flags: c_int) c_int;
};

/// Send up to `len` bytes of `file` at `off` to socket `sock`.
pub fn sendFile(sock: c_int, file: c_int, off: u64, len: u64) Io {
    if (comptime builtin.os.tag.isDarwin()) {
        var l: i64 = @intCast(@min(len, 1 << 30));
        const r = darwin_c.sendfile(file, sock, @intCast(off), &l, null, 0);
        if (r == 0) return if (l == 0) .eof else .{ .ok = @intCast(l) };
        const e = errno();
        if (isAgain(e)) return if (l > 0) .{ .ok = @intCast(l) } else .again;
        return .{ .err = e };
    } else {
        var o: i64 = @intCast(off);
        const n = std.os.linux.sendfile(sock, file, &o, @min(len, 1 << 30));
        const signed: isize = @bitCast(n);
        if (signed > 0) return .{ .ok = @intCast(signed) };
        if (signed == 0) return .eof;
        const e: c_int = @intCast(-signed);
        if (isAgain(e)) return .again;
        return .{ .err = e };
    }
}

pub fn pread(fd: c_int, buf: []u8, off: u64) isize {
    return c.pread(fd, buf.ptr, buf.len, @intCast(off));
}

pub fn setNonblock(fd: c_int) bool {
    const fl = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (fl < 0) return false;
    return c.fcntl(fd, c.F.SETFL, fl | @as(c_int, @bitCast(c.O{ .NONBLOCK = true }))) >= 0;
}

pub fn setCloexec(fd: c_int) void {
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
}

pub fn setInt(fd: c_int, level: i32, opt: u32, v: c_int) bool {
    return c.setsockopt(fd, level, opt, std.mem.asBytes(&v), @sizeOf(c_int)) == 0;
}

pub fn setNoDelay(fd: c_int) void {
    _ = setInt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, 1);
}

pub fn setNoSigpipe(fd: c_int) void {
    if (comptime builtin.os.tag.isDarwin()) _ = setInt(fd, c.SOL.SOCKET, 0x1022, 1); // SO_NOSIGPIPE
}

pub const SockAddr = extern union {
    any: c.sockaddr,
    in: c.sockaddr.in,
    in6: c.sockaddr.in6,
    storage: c.sockaddr.storage,
};

pub fn toSockAddr(a: Addr, out: *SockAddr) c.socklen_t {
    out.* = std.mem.zeroes(SockAddr);
    if (a.family == .v4) {
        out.in.family = c.AF.INET;
        out.in.port = std.mem.nativeToBig(u16, a.port);
        out.in.addr = @bitCast(a.ip[0..4].*);
        if (comptime builtin.os.tag.isDarwin()) out.in.len = @sizeOf(c.sockaddr.in);
        return @sizeOf(c.sockaddr.in);
    }
    out.in6.family = c.AF.INET6;
    out.in6.port = std.mem.nativeToBig(u16, a.port);
    out.in6.addr = a.ip;
    if (comptime builtin.os.tag.isDarwin()) out.in6.len = @sizeOf(c.sockaddr.in6);
    return @sizeOf(c.sockaddr.in6);
}

pub fn fromSockAddr(sa: *const SockAddr) Addr {
    var a: Addr = .{};
    if (sa.any.family == c.AF.INET6) {
        a.family = .v6;
        a.ip = sa.in6.addr;
        a.port = std.mem.bigToNative(u16, sa.in6.port);
        // v4-mapped -> v4
        if (std.mem.allEqual(u8, a.ip[0..10], 0) and a.ip[10] == 0xff and a.ip[11] == 0xff) {
            var v4: Addr = .{ .port = a.port };
            @memcpy(v4.ip[0..4], a.ip[12..16]);
            return v4;
        }
    } else {
        a.ip[0..4].* = @bitCast(sa.in.addr);
        a.port = std.mem.bigToNative(u16, sa.in.port);
    }
    return a;
}

pub fn localAddr(fd: c_int) Addr {
    var sa: SockAddr = undefined;
    var len: c.socklen_t = @sizeOf(SockAddr);
    if (c.getsockname(fd, &sa.any, &len) != 0) return .{};
    return fromSockAddr(&sa);
}

pub const ListenError = error{ Socket, Bind, Listen };

pub fn listenSocket(a: Addr, backlog: i32, reuseport: bool, ipv6only: bool, err_out: *c_int) ListenError!c_int {
    const fam: c_uint = if (a.family == .v4) c.AF.INET else c.AF.INET6;
    const fd = c.socket(fam, c.SOCK.STREAM, 0);
    if (fd < 0) {
        err_out.* = errno();
        return error.Socket;
    }
    setCloexec(fd);
    _ = setInt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, 1);
    if (reuseport) _ = setInt(fd, c.SOL.SOCKET, c.SO.REUSEPORT, 1);
    if (a.family == .v6) _ = setInt(fd, c.IPPROTO.IPV6, IPV6_V6ONLY, if (ipv6only) 1 else 0);
    var sa: SockAddr = undefined;
    const len = toSockAddr(a, &sa);
    if (c.bind(fd, &sa.any, len) != 0) {
        err_out.* = errno();
        _ = c.close(fd);
        return error.Bind;
    }
    if (c.listen(fd, @intCast(if (backlog < 0) 511 else backlog)) != 0) {
        err_out.* = errno();
        _ = c.close(fd);
        return error.Listen;
    }
    _ = setNonblock(fd);
    return fd;
}

pub fn listenUdp(a: Addr, reuseport: bool, ipv6only: bool, err_out: *c_int) error{ Socket, Bind, Listen }!c_int {
    const fam: c_uint = if (a.family == .v4) c.AF.INET else c.AF.INET6;
    const fd = c.socket(fam, c.SOCK.DGRAM, 0);
    if (fd < 0) {
        err_out.* = errno();
        return error.Socket;
    }
    errdefer close(fd);
    setCloexec(fd);
    if (reuseport and !setInt(fd, c.SOL.SOCKET, c.SO.REUSEPORT, 1)) {
        err_out.* = errno();
        return error.Socket;
    }
    if (a.family == .v6) _ = setInt(fd, c.IPPROTO.IPV6, IPV6_V6ONLY, if (ipv6only) 1 else 0);
    var sa: SockAddr = undefined;
    const len = toSockAddr(a, &sa);
    if (c.bind(fd, &sa.any, len) != 0) {
        err_out.* = errno();
        return error.Bind;
    }
    if (!setNonblock(fd)) {
        err_out.* = errno();
        return error.Socket;
    }
    return fd;
}

const IPV6_V6ONLY: u32 = if (builtin.os.tag.isDarwin()) 27 else 26;

pub const Accepted = struct { fd: c_int, peer: Addr };

pub fn accept(lfd: c_int) union(enum) { ok: Accepted, again, err: c_int } {
    var sa: SockAddr = undefined;
    var len: c.socklen_t = @sizeOf(SockAddr);
    while (true) {
        const fd = c.accept(lfd, &sa.any, &len);
        if (fd >= 0) {
            setCloexec(fd);
            _ = setNonblock(fd);
            setNoSigpipe(fd);
            return .{ .ok = .{ .fd = fd, .peer = fromSockAddr(&sa) } };
        }
        const e = errno();
        if (e == @backingInt(c.E.INTR) or e == @backingInt(c.E.CONNABORTED)) continue;
        if (isAgain(e)) return .again;
        return .{ .err = e };
    }
}

/// Start a non-blocking connect. Returns the fd (connection may be in progress).
pub fn connectStart(a: Addr, err_out: *c_int) ?c_int {
    const fam: c_uint = if (a.family == .v4) c.AF.INET else c.AF.INET6;
    const fd = c.socket(fam, c.SOCK.STREAM, 0);
    if (fd < 0) {
        err_out.* = errno();
        return null;
    }
    setCloexec(fd);
    _ = setNonblock(fd);
    setNoSigpipe(fd);
    setNoDelay(fd);
    var sa: SockAddr = undefined;
    const len = toSockAddr(a, &sa);
    if (c.connect(fd, &sa.any, len) != 0) {
        const e = errno();
        if (e != @backingInt(c.E.INPROGRESS) and e != @backingInt(c.E.INTR)) {
            err_out.* = e;
            _ = c.close(fd);
            return null;
        }
    }
    return fd;
}

/// Pending socket error (0 = connected).
pub fn soError(fd: c_int) c_int {
    var v: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, std.mem.asBytes(&v), &len) != 0) return errno();
    return v;
}

pub fn close(fd: c_int) void {
    _ = c.close(fd);
}
