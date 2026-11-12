//! UDP socket I/O for an Endpoint: batched receive with destination
//! address (PKTINFO) and batched GSO send on Linux; plain recvmsg/sendmsg
//! elsewhere.
const std = @import("std");
const builtin = @import("builtin");
const ep_mod = @import("endpoint.zig");
const Endpoint = ep_mod.Endpoint;
const OutMsg = ep_mod.OutMsg;
const Addr = ep_mod.Addr;

const is_linux = builtin.os.tag == .linux;

const iovec = extern struct { base: [*]u8, len: usize };

const msghdr = if (is_linux) extern struct {
    name: ?*anyopaque,
    namelen: u32,
    iov: [*]iovec,
    iovlen: usize,
    control: ?*anyopaque,
    controllen: usize,
    flags: c_int,
} else extern struct {
    name: ?*anyopaque,
    namelen: u32,
    iov: [*]iovec,
    iovlen: c_int,
    control: ?*anyopaque,
    controllen: u32,
    flags: c_int,
};

const mmsghdr = extern struct { hdr: msghdr, len: c_uint };

const cmsghdr = if (is_linux) extern struct { len: usize, level: c_int, type: c_int } else extern struct { len: u32, level: c_int, type: c_int };

const AF_INET: u16 = 2;
const AF_INET6: u16 = if (is_linux) 10 else 30;
const IPPROTO_IP: c_int = 0;
const IPPROTO_IPV6: c_int = 41;
const IP_PKTINFO: c_int = if (is_linux) 8 else 26;
const IP_RECVPKTINFO: c_int = if (is_linux) 8 else 26;
const IPV6_RECVPKTINFO: c_int = if (is_linux) 49 else 61;
const IPV6_PKTINFO: c_int = if (is_linux) 50 else 46;
const SOL_UDP: c_int = 17;
const UDP_SEGMENT: c_int = 103;
const MSG_DONTWAIT: c_int = if (is_linux) 0x40 else 0x80;
const EAGAIN: c_int = if (is_linux) 11 else 35;
const EINTR: c_int = 4;
const EIO: c_int = 5;
const EINVAL: c_int = 22;

const in_pktinfo = extern struct { ifindex: c_uint, spec_dst: [4]u8, addr: [4]u8 };
const in6_pktinfo = extern struct { addr: [16]u8, ifindex: c_uint };

/// Socket address storage in the platform layout.
const SockAddr = extern struct { bytes: [28]u8 align(4) = @splat(0) };

extern "c" fn recvmsg(fd: c_int, msg: *msghdr, flags: c_int) isize;
extern "c" fn sendmsg(fd: c_int, msg: *const msghdr, flags: c_int) isize;
extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, val: ?*const anyopaque, len: u32) c_int;
const linux_mmsg = struct {
    extern "c" fn recvmmsg(fd: c_int, msgs: [*]mmsghdr, n: c_uint, flags: c_int, timeout: ?*anyopaque) c_int;
    extern "c" fn sendmmsg(fd: c_int, msgs: [*]mmsghdr, n: c_uint, flags: c_int) c_int;
};

fn errno() c_int {
    return std.c._errno().*;
}

fn toSock(a: *const Addr, out: *SockAddr) u32 {
    out.* = .{};
    const b = &out.bytes;
    if (a.v6) {
        if (is_linux) {
            std.mem.writeInt(u16, b[0..2], AF_INET6, .little);
        } else {
            b[0] = 28;
            b[1] = @intCast(AF_INET6);
        }
        std.mem.writeInt(u16, b[2..4], a.port, .big);
        @memcpy(b[8..24], &a.ip);
        std.mem.writeInt(u32, b[24..28], a.scope, .little);
        return 28;
    }
    if (is_linux) {
        std.mem.writeInt(u16, b[0..2], AF_INET, .little);
    } else {
        b[0] = 16;
        b[1] = @intCast(AF_INET);
    }
    std.mem.writeInt(u16, b[2..4], a.port, .big);
    @memcpy(b[4..8], a.ip[12..16]);
    return 16;
}

pub fn fromSock(raw: *const anyopaque) Addr {
    const b: *const [28]u8 = @ptrCast(raw);
    const fam: u16 = if (is_linux) std.mem.readInt(u16, b[0..2], .little) else b[1];
    var a = Addr{ .port = std.mem.readInt(u16, b[2..4], .big) };
    if (fam == AF_INET6) {
        a.v6 = true;
        @memcpy(&a.ip, b[8..24]);
        a.scope = std.mem.readInt(u32, b[24..28], .little);
    } else {
        a.ip[10] = 0xff;
        a.ip[11] = 0xff;
        @memcpy(a.ip[12..16], b[4..8]);
    }
    return a;
}

/// Enables destination-address reporting on a bound UDP socket.
pub fn prepare(fd: c_int, v6: bool) void {
    const one: c_int = 1;
    if (v6) {
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_RECVPKTINFO, &one, @sizeOf(c_int));
        _ = setsockopt(fd, IPPROTO_IP, IP_RECVPKTINFO, &one, @sizeOf(c_int));
    } else {
        _ = setsockopt(fd, IPPROTO_IP, IP_RECVPKTINFO, &one, @sizeOf(c_int));
    }
}

const batch = 32;
const slot = 2048;
const ctl_len = 64;

pub const Socket = struct {
    fd: c_int,
    /// Address the socket is bound to (fallback when PKTINFO is absent).
    bound: Addr,
    gso: bool = is_linux,
    rx: *[batch][slot]u8,
    names: [batch]SockAddr = undefined,
    ctl: [batch][ctl_len]u8 align(8) = undefined,
    iov: [batch]iovec = undefined,
    hdrs: [batch]mmsghdr = undefined,
    tx_names: [64]SockAddr = undefined,
    tx_ctl: [64][ctl_len]u8 align(8) = undefined,
    tx_iov: [64]iovec = undefined,
    tx_hdrs: [64]mmsghdr = undefined,

    pub fn init(a: std.mem.Allocator, fd: c_int, bound: Addr) !*Socket {
        const s = try a.create(Socket);
        s.* = .{ .fd = fd, .bound = bound, .rx = try a.create([batch][slot]u8) };
        prepare(fd, bound.v6);
        return s;
    }

    pub fn deinit(s: *Socket, a: std.mem.Allocator) void {
        a.destroy(s.rx);
        a.destroy(s);
    }

    pub fn sink(s: *Socket) ep_mod.Sink {
        return .{ .ctx = s, .send = sendCb };
    }

    fn localFrom(s: *Socket, h: *const msghdr) Addr {
        var a = s.bound;
        if (h.controllen == 0) return a;
        const base: [*]const u8 = @ptrCast(h.control.?);
        var off: usize = 0;
        while (off + @sizeOf(cmsghdr) <= h.controllen) {
            const c: *align(1) const cmsghdr = @ptrCast(base + off);
            if (c.len < @sizeOf(cmsghdr)) break;
            const data = base + off + @sizeOf(cmsghdr);
            if (c.level == IPPROTO_IP and c.type == IP_PKTINFO) {
                const p: *align(1) const in_pktinfo = @ptrCast(data);
                a.v6 = false;
                a.ip = @splat(0);
                a.ip[10] = 0xff;
                a.ip[11] = 0xff;
                @memcpy(a.ip[12..16], &p.addr);
            } else if (c.level == IPPROTO_IPV6 and c.type == IPV6_PKTINFO) {
                const p: *align(1) const in6_pktinfo = @ptrCast(data);
                a.v6 = true;
                a.ip = p.addr;
            }
            off += std.mem.alignForward(usize, c.len, @sizeOf(usize));
        }
        return a;
    }

    /// Reads datagrams until the socket is drained or `max_batches` batches
    /// were processed. Returns the number of datagrams.
    pub fn receive(s: *Socket, ep: *Endpoint, max_batches: usize) usize {
        var total: usize = 0;
        var round: usize = 0;
        while (round < max_batches) : (round += 1) {
            for (0..batch) |i| {
                s.iov[i] = .{ .base = &s.rx[i], .len = slot };
                s.hdrs[i] = .{ .hdr = .{
                    .name = &s.names[i],
                    .namelen = @sizeOf(SockAddr),
                    .iov = @ptrCast(&s.iov[i]),
                    .iovlen = 1,
                    .control = &s.ctl[i],
                    .controllen = ctl_len,
                    .flags = 0,
                }, .len = 0 };
            }
            var n: usize = 0;
            if (is_linux) {
                const r = linux_mmsg.recvmmsg(s.fd, &s.hdrs, batch, MSG_DONTWAIT, null);
                if (r < 0) {
                    if (errno() == EINTR) continue;
                    break;
                }
                n = @intCast(r);
            } else {
                while (n < batch) {
                    const r = recvmsg(s.fd, &s.hdrs[n].hdr, MSG_DONTWAIT);
                    if (r < 0) break;
                    s.hdrs[n].len = @intCast(r);
                    n += 1;
                }
            }
            if (n == 0) break;
            ep.updateClock();
            for (0..n) |i| {
                const h = &s.hdrs[i];
                if (h.hdr.flags & 0x20 != 0) continue; // MSG_TRUNC (Linux) / truncated
                const peer = fromSock(&s.names[i]);
                const local = s.localFrom(&h.hdr);
                ep.recv(s.rx[i][0..h.len], peer, local);
            }
            total += n;
            if (n < batch) break;
        }
        return total;
    }

    fn sendCb(ctx: ?*anyopaque, buf: []const u8, msgs: []const OutMsg) void {
        const s: *Socket = @ptrCast(@alignCast(ctx));
        s.sendAll(buf, msgs);
    }

    fn fillMsg(s: *Socket, i: usize, buf: []const u8, m: *const OutMsg, off: u32, len: u32, seg: u16, nseg: u16) void {
        s.tx_iov[i] = .{ .base = @constCast(buf.ptr + off), .len = len };
        const namelen = toSock(&m.to, &s.tx_names[i]);
        var cl: usize = 0;
        const ctl: [*]u8 = &s.tx_ctl[i];
        if (is_linux and nseg > 1) {
            const c: *align(1) cmsghdr = @ptrCast(ctl);
            c.* = .{ .len = @sizeOf(cmsghdr) + 2, .level = SOL_UDP, .type = UDP_SEGMENT };
            std.mem.writeInt(u16, ctl[@sizeOf(cmsghdr)..][0..2], seg, .little);
            cl += std.mem.alignForward(usize, @sizeOf(cmsghdr) + 2, @sizeOf(usize));
        }
        if (is_linux and !std.mem.allEqual(u8, &m.from.ip, 0) and m.from.v6 == m.to.v6) {
            const c: *align(1) cmsghdr = @ptrCast(ctl + cl);
            if (m.from.v6) {
                c.* = .{ .len = @sizeOf(cmsghdr) + @sizeOf(in6_pktinfo), .level = IPPROTO_IPV6, .type = IPV6_PKTINFO };
                const p: *align(1) in6_pktinfo = @ptrCast(ctl + cl + @sizeOf(cmsghdr));
                p.* = .{ .addr = m.from.ip, .ifindex = 0 };
                cl += std.mem.alignForward(usize, @sizeOf(cmsghdr) + @sizeOf(in6_pktinfo), @sizeOf(usize));
            } else {
                c.* = .{ .len = @sizeOf(cmsghdr) + @sizeOf(in_pktinfo), .level = IPPROTO_IP, .type = IP_PKTINFO };
                const p: *align(1) in_pktinfo = @ptrCast(ctl + cl + @sizeOf(cmsghdr));
                p.* = .{ .ifindex = 0, .spec_dst = m.from.ip[12..16].*, .addr = @splat(0) };
                cl += std.mem.alignForward(usize, @sizeOf(cmsghdr) + @sizeOf(in_pktinfo), @sizeOf(usize));
            }
        }
        s.tx_hdrs[i] = .{ .hdr = .{
            .name = &s.tx_names[i],
            .namelen = namelen,
            .iov = @ptrCast(&s.tx_iov[i]),
            .iovlen = 1,
            .control = if (cl > 0) ctl else null,
            .controllen = @intCast(cl),
            .flags = 0,
        }, .len = 0 };
    }

    fn sendAll(s: *Socket, buf: []const u8, msgs: []const OutMsg) void {
        if (!is_linux or !s.gso) {
            for (msgs) |*m| s.sendSplit(buf, m);
            return;
        }
        for (msgs, 0..) |*m, i| s.fillMsg(i, buf, m, m.off, m.len, m.seg, m.nseg);
        var done: usize = 0;
        while (done < msgs.len) {
            const r = linux_mmsg.sendmmsg(s.fd, s.tx_hdrs[done..].ptr, @intCast(msgs.len - done), 0);
            if (r < 0) {
                const e = errno();
                if (e == EINTR) continue;
                if (e == EIO or e == EINVAL) {
                    // No GSO on this path/device: fall back to one datagram per send.
                    s.gso = false;
                    for (msgs[done..]) |*m| s.sendSplit(buf, m);
                }
                return;
            }
            if (r == 0) return;
            done += @intCast(r);
        }
    }

    fn sendSplit(s: *Socket, buf: []const u8, m: *const OutMsg) void {
        var off = m.off;
        const end = m.off + m.len;
        while (off < end) {
            const len: u32 = @min(m.seg, end - off);
            s.fillMsg(0, buf, m, off, len, @intCast(len), 1);
            _ = sendmsg(s.fd, &s.tx_hdrs[0].hdr, 0);
            off += len;
        }
    }
};
