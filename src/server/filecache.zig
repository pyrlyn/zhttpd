//! Per-worker open file cache (nginx `open_file_cache*`).
//!
//! Caches, per path: the open descriptor, file metadata, and (with
//! open_file_cache_errors on) open() errors. Entries are revalidated with
//! stat() after open_file_cache_valid and dropped after open_file_cache's
//! inactive= time without use. The table is fixed-capacity and 4-way
//! set-associative. Four-entry buckets are allocated on first insertion, so a large
//! configured limit does not commit memory for files that are never opened.
//! Paths longer than `path_cap` are not cached.
//!
//! On Linux a cached file of at most `map_max` bytes is also mapped, so that
//! serving it copies from the page cache without a read call per request.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const os = @import("../os.zig");
const net = @import("net.zig");
const config = @import("../http/config.zig");

pub const path_cap = 232;
const ways = 4;
const can_map = builtin.os.tag == .linux;
/// Largest file that is mapped: what fits in a connection's write buffer.
const map_max = 16 * 1024;
/// Most bytes one worker keeps mapped, so many small files cannot grow its
/// resident set without bound.
const map_budget = 1024 * 1024;

/// A mapped file loses its pages when it is truncated, and reading them
/// raises SIGBUS. While `copy` runs, the handler backs the faulting page with
/// zeroes and marks the copy as failed; any other SIGBUS goes to the previous
/// disposition.
const bus = struct {
    threadlocal var lo: usize = 0;
    threadlocal var hi: usize = 0;
    threadlocal var faulted: bool = false;
    var previous: posix.Sigaction = undefined;
    var page_size: usize = 0;

    fn install() void {
        if (page_size != 0) return;
        page_size = std.heap.pageSize();
        // NODEFER: a chained handler may leave with siglongjmp.
        const act: posix.Sigaction = .{
            .handler = .{ .sigaction = onBus },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.SIGINFO | posix.SA.NODEFER,
        };
        posix.sigaction(.BUS, &act, &previous);
    }

    fn onBus(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
        const addr = @intFromPtr(info.fields.sigfault.addr);
        if (addr >= lo and addr < hi) {
            const rc = std.os.linux.mmap(@ptrFromInt(addr & ~(page_size - 1)), page_size, .{ .READ = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0);
            if (rc <= std.math.maxInt(usize) - 4096) {
                faulted = true;
                return;
            }
        }
        if (previous.flags & posix.SA.SIGINFO != 0) {
            if (previous.handler.sigaction) |f| return f(sig, info, ctx);
        } else if (previous.handler.handler) |f| {
            if (@intFromPtr(f) > 1) return f(sig);
        }
        // default action: the faulting access runs again and ends the process
        const dfl: posix.Sigaction = .{ .handler = .{ .handler = null }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(.BUS, &dfl, null);
    }

    /// Copies from a mapping whose file ends at `last`, at or after the copied
    /// bytes. False when the file may have shrunk, and `dst` then holds
    /// unspecified bytes: a page was gone, or the last byte reads as zero,
    /// which is what a cut inside a page leaves behind.
    noinline fn copy(dst: []u8, src: [*]const u8, last: *const volatile u8) bool {
        const guard_lo: *volatile usize = &lo;
        const guard_hi: *volatile usize = &hi;
        const failed: *volatile bool = &faulted;
        guard_lo.* = @intFromPtr(src);
        guard_hi.* = @intFromPtr(last) + 1;
        @memcpy(dst, src[0..dst.len]);
        const tail = last.*;
        guard_hi.* = 0;
        if (!failed.*) return tail != 0;
        failed.* = false;
        return false;
    }
};

pub const Entry = struct {
    hash: u64 = 0,
    used: bool = false,
    path_len: u16 = 0,
    fd: c_int = -1, // -1 for directories, errors and not-yet-cached entries
    err: c_int = 0,
    meta: os.Meta = .{ .kind = .other, .size = 0, .mtime = 0 },
    uses: u32 = 0,
    validated_ms: u64 = 0,
    last_ms: u64 = 0,
    /// read-only mapping of the whole file, or null
    map: ?[*]align(std.heap.page_size_min) const u8 = null,
    map_len: u32 = 0,
    path: [path_cap]u8 = undefined,
};

pub const Result = union(enum) {
    /// `owned` = the caller must close `fd` (it is not held by the cache).
    /// `entry` is set when the file is mapped (see `Cache.copyMapped`); it is
    /// valid until the next call into the cache.
    file: struct { fd: c_int, meta: os.Meta, owned: bool, entry: ?*Entry = null },
    /// not a regular file (directory etc.); no descriptor
    other: os.Meta,
    err: c_int,
};

pub const Cache = struct {
    sets: []?*[ways]Entry = &.{},
    allocator: std.mem.Allocator = undefined,
    nsets: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    mapped: usize = 0,

    pub fn init(gpa: std.mem.Allocator, max: u32) !Cache {
        if (max == 0) return .{};
        const nsets = std.math.ceilPowerOfTwo(usize, @max(1, (max + ways - 1) / ways)) catch return error.OutOfMemory;
        const sets = try gpa.alloc(?*[ways]Entry, nsets);
        @memset(sets, null);
        return .{ .sets = sets, .nsets = nsets, .allocator = gpa };
    }

    pub fn deinit(cache: *Cache, gpa: std.mem.Allocator) void {
        for (cache.sets) |bucket| {
            if (bucket) |entries| {
                for (entries) |*e| if (e.used) cache.drop(e);
                gpa.destroy(entries);
            }
        }
        if (cache.sets.len > 0) gpa.free(cache.sets);
        cache.* = .{};
    }

    /// Opens `path` (or returns the cached descriptor) using the location's settings.
    pub fn open(cache: *Cache, ofc: config.OpenFileCache, path: [:0]const u8, now: u64) Result {
        if (ofc.max == 0 or cache.nsets == 0 or path.len > path_cap) return openUncached(path);
        const h = std.hash.Wyhash.hash(0x2f, path);
        const slot = &cache.sets[h & (cache.nsets - 1)];
        const set = slot.* orelse blk: {
            const entries = cache.allocator.create([ways]Entry) catch return openUncached(path);
            entries.* = @splat(.{});
            slot.* = entries;
            break :blk entries;
        };
        var victim: *Entry = &set[0];
        for (set) |*e| {
            if (e.used and e.hash == h and e.path_len == path.len and std.mem.eql(u8, e.path[0..e.path_len], path)) {
                if (now -| e.last_ms > ofc.inactive_ms) {
                    cache.drop(e);
                    victim = e;
                    break;
                }
                e.uses +|= 1;
                e.last_ms = now;
                if (now -| e.validated_ms >= ofc.valid_ms) cache.revalidate(e, path, now);
                if (e.err != 0) {
                    if (ofc.errors) {
                        cache.hits += 1;
                        return .{ .err = e.err };
                    }
                    cache.drop(e);
                    victim = e;
                    break;
                }
                if (e.meta.kind != .file) {
                    cache.hits += 1;
                    return .{ .other = e.meta };
                }
                if (e.fd >= 0) {
                    cache.hits += 1;
                    return held(e);
                }
                // counted but not yet min_uses: open now, keep it once the threshold is met
                const r = openUncached(path);
                if (r == .file and e.uses >= ofc.min_uses) {
                    e.fd = r.file.fd;
                    e.meta = r.file.meta;
                    e.validated_ms = now;
                    cache.mapFile(e);
                    return held(e);
                }
                return r;
            }
            if (!e.used) victim = e else if (victim.used and e.last_ms < victim.last_ms) victim = e;
        }
        cache.misses += 1;
        const r = openUncached(path);
        if (r == .err and !ofc.errors) return r;
        if (victim.used) cache.drop(victim);
        victim.* = .{ .hash = h, .used = true, .path_len = @intCast(path.len), .uses = 1, .validated_ms = now, .last_ms = now };
        @memcpy(victim.path[0..path.len], path);
        switch (r) {
            .err => |e| victim.err = e,
            .other => |m| victim.meta = m,
            .file => |f| {
                victim.meta = f.meta;
                if (ofc.min_uses <= 1) {
                    victim.fd = f.fd;
                    cache.mapFile(victim);
                    return held(victim);
                }
            },
        }
        return r;
    }

    /// stat()-based lookup (try_files, index): never keeps a descriptor open by itself.
    pub fn stat(cache: *Cache, ofc: config.OpenFileCache, path: [:0]const u8, now: u64) ?os.Meta {
        if (ofc.max == 0 or cache.nsets == 0 or path.len > path_cap) return os.statZ(path);
        const h = std.hash.Wyhash.hash(0x2f, path);
        const set = cache.sets[h & (cache.nsets - 1)] orelse return os.statZ(path);
        for (set) |*e| {
            if (e.used and e.hash == h and e.path_len == path.len and std.mem.eql(u8, e.path[0..e.path_len], path)) {
                if (now -| e.last_ms > ofc.inactive_ms) break;
                if (now -| e.validated_ms >= ofc.valid_ms) cache.revalidate(e, path, now);
                if (e.err != 0) return if (ofc.errors) null else os.statZ(path);
                e.last_ms = now;
                cache.hits += 1;
                return e.meta;
            }
        }
        // not cached: a stat now; the following open() will populate the entry
        return os.statZ(path);
    }

    fn held(e: *Entry) Result {
        return .{ .file = .{ .fd = e.fd, .meta = e.meta, .owned = false, .entry = if (e.map != null) e else null } };
    }

    fn mapFile(cache: *Cache, e: *Entry) void {
        if (!can_map or e.meta.size == 0 or e.meta.size > map_max) return;
        const len = std.mem.alignForward(usize, @intCast(e.meta.size), std.heap.pageSize());
        if (cache.mapped + len > map_budget) return;
        const flags: posix.MAP = if (can_map) .{ .TYPE = .SHARED, .POPULATE = true } else .{ .TYPE = .SHARED };
        const m = posix.mmap(null, len, .{ .READ = true }, flags, e.fd, 0) catch return;
        if (can_map) bus.install();
        e.map = m.ptr;
        e.map_len = @intCast(len);
        cache.mapped += len;
        // a file that ends in a zero byte cannot be told from a shrunk one
        var probe: [1]u8 = undefined;
        _ = cache.copyMapped(e, &probe, e.meta.size - 1);
    }

    fn unmap(cache: *Cache, e: *Entry) void {
        const m = e.map orelse return;
        posix.munmap(m[0..e.map_len]);
        cache.mapped -= e.map_len;
        e.map = null;
        e.map_len = 0;
    }

    /// Unmaps the file and closes the descriptor the entry holds.
    fn release(cache: *Cache, e: *Entry) void {
        cache.unmap(e);
        if (e.fd >= 0) net.close(e.fd);
        e.fd = -1;
    }

    fn drop(cache: *Cache, e: *Entry) void {
        cache.release(e);
        e.* = .{};
    }

    /// Copies `dst.len` bytes at `start` from the mapping of `e` (the `entry`
    /// of the `open` result just returned). False when the bytes must be read
    /// from the descriptor instead, which reports a short file as it always
    /// did: the file may have shrunk under the mapping, which is then dropped.
    pub fn copyMapped(cache: *Cache, e: *Entry, dst: []u8, start: u64) bool {
        if (!can_map) return false;
        const m = e.map orelse return false;
        if (start > e.meta.size or dst.len > e.meta.size - start) return false;
        const size: usize = @intCast(e.meta.size);
        if (bus.copy(dst, m + @as(usize, @intCast(start)), &m[size - 1])) return true;
        cache.unmap(e);
        return false;
    }

    fn revalidate(cache: *Cache, e: *Entry, path: [:0]const u8, now: u64) void {
        e.validated_ms = now;
        const m = os.statZ(path) orelse {
            cache.release(e);
            e.err = os.errnoInt();
            if (e.err == 0) e.err = @backingInt(c.E.NOENT);
            return;
        };
        if (e.err == 0 and m.kind == e.meta.kind and m.ino == e.meta.ino and m.mtime == e.meta.mtime and m.size == e.meta.size) return;
        // changed: forget the old descriptor; the next open() call reopens
        cache.release(e);
        e.err = 0;
        e.meta = m;
        if (m.kind == .file) {
            switch (openUncached(path)) {
                .file => |f| {
                    e.fd = f.fd;
                    e.meta = f.meta;
                    cache.mapFile(e);
                },
                .other => |om| e.meta = om,
                .err => |er| e.err = er,
            }
        }
    }
};

pub fn openUncached(path: [:0]const u8) Result {
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return .{ .err = os.errnoInt() };
    const meta = os.fstat(fd) orelse {
        const e = os.errnoInt();
        net.close(fd);
        return .{ .err = if (e == 0) @backingInt(c.E.IO) else e };
    };
    if (meta.kind != .file) {
        net.close(fd);
        return .{ .other = meta };
    }
    return .{ .file = .{ .fd = fd, .meta = meta, .owned = true } };
}

test "file cache keeps the descriptor and revalidates" {
    const t = std.testing;
    var cache = try Cache.init(t.allocator, 16);
    defer cache.deinit(t.allocator);
    const ofc: config.OpenFileCache = .{ .max = 16, .valid_ms = 1000, .errors = true };
    const r1 = cache.open(ofc, "build.zig", 0);
    try t.expect(r1 == .file and !r1.file.owned);
    const r2 = cache.open(ofc, "build.zig", 10);
    try t.expectEqual(r1.file.fd, r2.file.fd);
    try t.expectEqual(@as(u64, 1), cache.hits);
    try t.expect(cache.open(ofc, "does-not-exist.txt", 10) == .err);
    try t.expect(cache.open(ofc, "does-not-exist.txt", 20) == .err);
    try t.expectEqual(@as(u64, 2), cache.hits);
    try t.expect(cache.open(ofc, "src", 20) == .other);
    try t.expect(cache.stat(ofc, "build.zig", 5000).?.kind == .file); // revalidated, unchanged
    const r3 = cache.open(ofc, "build.zig", 5001);
    try t.expectEqual(r1.file.fd, r3.file.fd);
}

test "file cache allocates buckets only for opened paths" {
    const t = std.testing;
    var cache = try Cache.init(t.allocator, 10000);
    defer cache.deinit(t.allocator);
    for (cache.sets) |bucket| try t.expect(bucket == null);
    const ofc: config.OpenFileCache = .{ .max = 10000 };
    try t.expect(cache.stat(ofc, "build.zig", 0) != null);
    for (cache.sets) |bucket| try t.expect(bucket == null);
    const result = cache.open(ofc, "build.zig", 0);
    try t.expect(result == .file and !result.file.owned);
    var allocated: usize = 0;
    for (cache.sets) |bucket| if (bucket != null) {
        allocated += 1;
    };
    try t.expectEqual(@as(usize, 1), allocated);
    try t.expectEqual(result.file.fd, cache.open(ofc, "build.zig", 1).file.fd);
}

test "file cache falls back to an owned descriptor when a bucket cannot be allocated" {
    const t = std.testing;
    var cache = try Cache.init(t.allocator, 4);
    defer cache.deinit(t.allocator);
    var storage: [0]u8 = .{};
    var failing: std.heap.FixedBufferAllocator = .init(&storage);
    cache.allocator = failing.allocator();
    const result = cache.open(.{ .max = 4 }, "build.zig", 0);
    try t.expect(result == .file and result.file.owned);
    net.close(result.file.fd);
    try t.expect(cache.sets[0] == null);
}

test "file cache maps small files and survives truncation" {
    if (!can_map) return error.SkipZigTest;
    const t = std.testing;
    const path = "zig-cache-map-test.tmp";
    const fd = c.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    try t.expect(fd >= 0);
    defer {
        net.close(fd);
        _ = c.unlink(path);
    }
    const body = "mapped file body";
    try t.expectEqual(@as(isize, body.len), c.write(fd, body.ptr, body.len));

    var cache = try Cache.init(t.allocator, 16);
    defer cache.deinit(t.allocator);
    const ofc: config.OpenFileCache = .{ .max = 16, .valid_ms = 1000 };
    const first = cache.open(ofc, path, 0);
    const e = first.file.entry.?;
    try t.expectEqual(std.heap.pageSize(), cache.mapped);
    var buf: [body.len]u8 = undefined;
    try t.expect(cache.copyMapped(e, &buf, 0));
    try t.expectEqualStrings(body, &buf);
    try t.expect(cache.copyMapped(e, buf[0..4], 7));
    try t.expectEqualStrings("file", buf[0..4]);
    try t.expect(!cache.copyMapped(e, &buf, 1)); // past the end of the file

    // an in-place rewrite is visible at once
    try t.expectEqual(@as(isize, 6), c.pwrite(fd, "MAPPED", 6, 0));
    try t.expect(cache.copyMapped(e, buf[0..6], 0));
    try t.expectEqualStrings("MAPPED", buf[0..6]);

    // truncation takes the pages away: the copy fails and the mapping goes
    try t.expectEqual(@as(c_int, 0), c.ftruncate(fd, 0));
    try t.expect(!cache.copyMapped(e, &buf, 0));
    try t.expectEqual(@as(usize, 0), cache.mapped);
    try t.expect(cache.open(ofc, path, 10).file.entry == null);

    // revalidation picks up the new file and maps it again
    try t.expectEqual(@as(isize, 3), c.pwrite(fd, "new", 3, 0));
    const again = cache.open(ofc, path, 5000);
    try t.expectEqual(@as(u64, 3), again.file.meta.size);
    try t.expect(cache.copyMapped(again.file.entry.?, buf[0..3], 0));
    try t.expectEqualStrings("new", buf[0..3]);

    // a cut inside the page leaves zeroes, not a fault: still not served
    try t.expectEqual(@as(c_int, 0), c.ftruncate(fd, 2));
    try t.expect(!cache.copyMapped(again.file.entry.?, buf[0..1], 0));
    try t.expectEqual(@as(usize, 0), cache.mapped);

    // a file that ends in a zero byte is read, never mapped
    try t.expectEqual(@as(isize, 4), c.pwrite(fd, "end\x00", 4, 0));
    const zero_ended = cache.open(ofc, path, 10000);
    try t.expectEqual(@as(u64, 4), zero_ended.file.meta.size);
    try t.expect(zero_ended.file.entry == null);
    try t.expectEqual(@as(usize, 0), cache.mapped);
}
