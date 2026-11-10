//! Thin readiness backend chosen at compile time: kqueue on macOS/BSD, epoll on Linux.
//! Sockets are registered once, edge-triggered, for both read and write readiness, so
//! the hot path never changes registrations (one syscall per wakeup batch).
//! Handlers must therefore read/write until EAGAIN.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const use_kqueue = builtin.os.tag.isDarwin() or builtin.os.tag == .freebsd or builtin.os.tag == .openbsd or builtin.os.tag == .netbsd;
pub const name = if (use_kqueue) "kqueue" else "epoll";

pub const Event = struct { udata: usize, readable: bool, writable: bool, eof: bool };

pub const Loop = if (use_kqueue) Kqueue else Epoll;

const Kqueue = struct {
    kq: c_int,
    out: [512]c.Kevent = undefined,

    pub fn init() !Kqueue {
        const kq = c.kqueue();
        if (kq < 0) return error.LoopInit;
        return .{ .kq = kq };
    }
    pub fn deinit(l: *Kqueue) void {
        _ = c.close(l.kq);
    }

    fn change(l: *Kqueue, ch: []const c.Kevent) !void {
        if (c.kevent(l.kq, ch.ptr, @intCast(ch.len), undefined, 0, null) < 0) return error.LoopCtl;
    }

    /// Level-triggered read interest (listen sockets).
    pub fn addListen(l: *Kqueue, fd: c_int, udata: usize) !void {
        try l.change(&.{.{ .ident = @intCast(fd), .filter = c.EVFILT.READ, .flags = c.EV.ADD, .fflags = 0, .data = 0, .udata = udata }});
    }
    /// Edge-triggered read + write interest.
    pub fn add(l: *Kqueue, fd: c_int, udata: usize) !void {
        try l.change(&.{
            .{ .ident = @intCast(fd), .filter = c.EVFILT.READ, .flags = c.EV.ADD | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = udata },
            .{ .ident = @intCast(fd), .filter = c.EVFILT.WRITE, .flags = c.EV.ADD | c.EV.CLEAR, .fflags = 0, .data = 0, .udata = udata },
        });
    }
    /// Closing the fd removes kqueue registrations automatically.
    pub fn remove(l: *Kqueue, fd: c_int) void {
        _ = l;
        _ = fd;
    }

    pub fn wait(l: *Kqueue, out: []Event, timeout_ms: i32) []Event {
        const ts: c.timespec = .{ .sec = @divTrunc(timeout_ms, 1000), .nsec = @rem(timeout_ms, 1000) * 1_000_000 };
        const max = @min(out.len, l.out.len);
        const n = c.kevent(l.kq, undefined, 0, &l.out, @intCast(max), if (timeout_ms < 0) null else &ts);
        if (n <= 0) return out[0..0];
        const cnt: usize = @intCast(n);
        for (l.out[0..cnt], 0..) |ev, i| {
            out[i] = .{
                .udata = ev.udata,
                .readable = ev.filter == c.EVFILT.READ,
                .writable = ev.filter == c.EVFILT.WRITE,
                .eof = (ev.flags & c.EV.EOF) != 0,
            };
        }
        return out[0..cnt];
    }
};

const Epoll = struct {
    ep: c_int,
    out: [512]std.os.linux.epoll_event = undefined,
    const L = std.os.linux;

    pub fn init() !Epoll {
        const ep = c.epoll_create1(L.EPOLL.CLOEXEC);
        if (ep < 0) return error.LoopInit;
        return .{ .ep = ep };
    }
    pub fn deinit(l: *Epoll) void {
        _ = c.close(l.ep);
    }
    pub fn addListen(l: *Epoll, fd: c_int, udata: usize) !void {
        var ev: L.epoll_event = .{ .events = L.EPOLL.IN | L.EPOLL.EXCLUSIVE, .data = .{ .ptr = udata } };
        if (c.epoll_ctl(l.ep, L.EPOLL.CTL_ADD, fd, @ptrCast(&ev)) < 0) {
            ev.events = L.EPOLL.IN; // EXCLUSIVE needs Linux 4.5+
            if (c.epoll_ctl(l.ep, L.EPOLL.CTL_ADD, fd, @ptrCast(&ev)) < 0) return error.LoopCtl;
        }
    }
    pub fn add(l: *Epoll, fd: c_int, udata: usize) !void {
        var ev: L.epoll_event = .{ .events = L.EPOLL.IN | L.EPOLL.OUT | L.EPOLL.RDHUP | L.EPOLL.ET, .data = .{ .ptr = udata } };
        if (c.epoll_ctl(l.ep, L.EPOLL.CTL_ADD, fd, @ptrCast(&ev)) < 0) return error.LoopCtl;
    }
    pub fn remove(l: *Epoll, fd: c_int) void {
        _ = c.epoll_ctl(l.ep, L.EPOLL.CTL_DEL, fd, null);
    }
    pub fn wait(l: *Epoll, out: []Event, timeout_ms: i32) []Event {
        const max = @min(out.len, l.out.len);
        const n = c.epoll_wait(l.ep, @ptrCast(&l.out), @intCast(max), timeout_ms);
        if (n <= 0) return out[0..0];
        const cnt: usize = @intCast(n);
        for (l.out[0..cnt], 0..) |ev, i| {
            const e = ev.events;
            out[i] = .{
                .udata = ev.data.ptr,
                .readable = (e & (L.EPOLL.IN | L.EPOLL.ERR | L.EPOLL.HUP | L.EPOLL.RDHUP)) != 0,
                .writable = (e & (L.EPOLL.OUT | L.EPOLL.ERR)) != 0,
                .eof = (e & (L.EPOLL.HUP | L.EPOLL.RDHUP | L.EPOLL.ERR)) != 0,
            };
        }
        return out[0..cnt];
    }
};

/// Monotonic milliseconds.
pub fn nowMs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Wall clock seconds and microseconds.
pub fn wallNow() struct { sec: i64, usec: i64 } {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    return .{ .sec = ts.sec, .usec = @divTrunc(ts.nsec, 1000) };
}
