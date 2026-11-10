//! Thin libc helpers used outside the hot path (config loading, file metadata).
//! We link libc and call it directly instead of `std.Io`, so the server's own
//! event loop owns all blocking decisions.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const is_linux = builtin.os.tag == .linux;
pub const is_darwin = builtin.os.tag.isDarwin();

pub const Kind = enum { file, dir, other };
pub const Meta = struct { kind: Kind, size: u64, mtime: i64, ino: u64 = 0 };

pub fn errnoNow() c.E {
    return @enumFromInt(@as(u16, @intCast(c._errno().*)));
}

pub fn errnoInt() c_int {
    return c._errno().*;
}

/// Human-readable strerror for config error messages.
pub fn strerror(e: c_int) []const u8 {
    return std.mem.span(libc_strerror(e));
}
const libc_strerror = @extern(*const fn (c_int) callconv(.c) [*:0]const u8, .{ .name = "strerror" });

fn kindOf(mode: u32) Kind {
    const fmt = mode & 0o170000;
    return if (fmt == 0o100000) .file else if (fmt == 0o040000) .dir else .other;
}

/// stat() a NUL-terminated path; null when it does not exist / cannot be stat'ed.
pub fn statZ(path: [*:0]const u8) ?Meta {
    if (is_linux) {
        var sx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, path, 0, .{ .TYPE = true, .MODE = true, .SIZE = true, .MTIME = true, .INO = true }, &sx);
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
        return .{ .kind = kindOf(sx.mode), .size = sx.size, .mtime = sx.mtime.sec, .ino = sx.ino };
    } else {
        var st: c.Stat = undefined;
        if (c.stat(path, &st) != 0) return null;
        return .{ .kind = kindOf(@intCast(st.mode)), .size = @intCast(st.size), .mtime = st.mtime().sec, .ino = @intCast(st.ino) };
    }
}

pub fn fstat(fd: c.fd_t) ?Meta {
    if (is_linux) {
        var sx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(fd, "", std.os.linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .SIZE = true, .MTIME = true, .INO = true }, &sx);
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
        return .{ .kind = kindOf(sx.mode), .size = sx.size, .mtime = sx.mtime.sec, .ino = sx.ino };
    } else {
        var st: c.Stat = undefined;
        if (c.fstat(fd, &st) != 0) return null;
        return .{ .kind = kindOf(@intCast(st.mode)), .size = @intCast(st.size), .mtime = st.mtime().sec, .ino = @intCast(st.ino) };
    }
}

/// stat() a path that is not NUL-terminated (copies into a stack buffer).
pub fn stat(path: []const u8) ?Meta {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return statZ(buf[0..path.len :0]);
}

pub const ReadError = error{ OpenFailed, ReadFailed, OutOfMemory };

/// Read a whole file. On OpenFailed, `errno_out` gets the errno for the message.
pub fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8, errno_out: *c_int) ReadError![]u8 {
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    const fd = c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) {
        errno_out.* = errnoInt();
        return error.OpenFailed;
    }
    defer _ = c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    while (true) {
        try list.ensureUnusedCapacity(gpa, 16384);
        const n = c.read(fd, list.unusedCapacitySlice().ptr, list.unusedCapacitySlice().len);
        if (n < 0) {
            if (errnoNow() == .INTR) continue;
            errno_out.* = errnoInt();
            return error.ReadFailed;
        }
        if (n == 0) break;
        list.items.len += @intCast(n);
    }
    return list.toOwnedSlice(gpa);
}

/// List entry names in a directory (no "." / ".."), unsorted. Caller frees each name and the slice.
pub fn listDir(gpa: std.mem.Allocator, dir: []const u8) ![][]u8 {
    const z = try gpa.dupeSentinel(u8, dir, 0);
    defer gpa.free(z);
    const d = c.opendir(z) orelse return error.OpenFailed;
    defer _ = c.closedir(d);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    while (c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        try out.append(gpa, try gpa.dupe(u8, name));
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeList(gpa: std.mem.Allocator, names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

/// Shell-style wildcard match for `include` globs: `*`, `?`, `[...]`.
pub fn fnmatch(pat: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pat.len) {
            switch (pat[p]) {
                '*' => {
                    star_p = p;
                    star_n = n;
                    p += 1;
                    continue;
                },
                '?' => {
                    p += 1;
                    n += 1;
                    continue;
                },
                '[' => {
                    if (std.mem.indexOfScalarPos(u8, pat, p + 1, ']')) |end| {
                        var neg = false;
                        var i = p + 1;
                        if (i < end and (pat[i] == '!' or pat[i] == '^')) {
                            neg = true;
                            i += 1;
                        }
                        var ok = false;
                        while (i < end) : (i += 1) {
                            if (i + 2 < end and pat[i + 1] == '-') {
                                if (name[n] >= pat[i] and name[n] <= pat[i + 2]) ok = true;
                                i += 2;
                            } else if (pat[i] == name[n]) ok = true;
                        }
                        if (ok != neg) {
                            p = end + 1;
                            n += 1;
                            continue;
                        }
                    } else if (name[n] == '[') {
                        p += 1;
                        n += 1;
                        continue;
                    }
                },
                else => if (pat[p] == name[n]) {
                    p += 1;
                    n += 1;
                    continue;
                },
            }
        }
        if (star_p) |sp| {
            p = sp + 1;
            star_n += 1;
            n = star_n;
            continue;
        }
        return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

pub fn hasGlob(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "*?[") != null;
}

/// Expand a glob like `/etc/nginx/sites-enabled/*` or `conf.d/*.conf` (wildcards only in
/// the last path component, like nginx in practice). Sorted, hidden files skipped, like glob(3).
pub fn glob(gpa: std.mem.Allocator, pattern: []const u8) ![][]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, pattern, '/');
    const dir = if (slash) |s| (if (s == 0) "/" else pattern[0..s]) else ".";
    const base = if (slash) |s| pattern[s + 1 ..] else pattern;
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| gpa.free(n);
        out.deinit(gpa);
    }
    const names = listDir(gpa, dir) catch return out.toOwnedSlice(gpa);
    defer freeList(gpa, names);
    for (names) |n| {
        if (n.len > 0 and n[0] == '.' and !(base.len > 0 and base[0] == '.')) continue;
        if (!fnmatch(base, n)) continue;
        const full = if (slash != null) try std.fmt.allocPrint(gpa, "{s}/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, n }) else try gpa.dupe(u8, n);
        try out.append(gpa, full);
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

pub fn ncpu() u32 {
    const n = std.Thread.getCpuCount() catch 1;
    return @intCast(@max(1, n));
}

test "fnmatch" {
    try std.testing.expect(fnmatch("*.conf", "default.conf"));
    try std.testing.expect(!fnmatch("*.conf", "default.conf.bak"));
    try std.testing.expect(fnmatch("*", "default"));
    try std.testing.expect(fnmatch("site-[a-c]?.conf", "site-b1.conf"));
    try std.testing.expect(!fnmatch("site-[!a-c]?.conf", "site-b1.conf"));
}

/// Resolve a hostname with getaddrinfo (startup only). Appends unique addresses; false if none.
pub fn resolve(alloc: std.mem.Allocator, host: []const u8, port: u16, out: anytype) bool {
    const Addr = @import("conf/addr.zig").Addr;
    const hz = alloc.dupeSentinel(u8, host, 0) catch return false;
    var res: ?*c.addrinfo = null;
    var hints = std.mem.zeroes(c.addrinfo);
    hints.socktype = c.SOCK.STREAM;
    if (@intFromEnum(c.getaddrinfo(hz, null, &hints, &res)) != 0 or res == null) return false;
    defer c.freeaddrinfo(res.?);
    var found = false;
    var it: ?*c.addrinfo = res;
    while (it) |ai| : (it = ai.next) {
        const sa = ai.addr orelse continue;
        var a: Addr = .{ .port = port };
        if (sa.family == c.AF.INET) {
            const in: *const c.sockaddr.in = @ptrCast(@alignCast(sa));
            a.ip[0..4].* = @bitCast(in.addr);
        } else if (sa.family == c.AF.INET6) {
            const in6: *const c.sockaddr.in6 = @ptrCast(@alignCast(sa));
            a.family = .v6;
            a.ip = in6.addr;
        } else continue;
        var dup = false;
        for (out.items) |x| {
            if (x.eql(a)) dup = true;
        }
        if (!dup) out.append(alloc, a) catch return found;
        found = true;
    }
    return found;
}
