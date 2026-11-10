//! Per-worker open file cache (nginx `open_file_cache*`).
//!
//! Caches, per path: the open descriptor, file metadata, and (with
//! open_file_cache_errors on) open() errors. Entries are revalidated with
//! stat() after open_file_cache_valid and dropped after open_file_cache's
//! inactive= time without use. The table is a fixed 4-way set-associative
//! array allocated once at worker start, so lookups never allocate.
//! Paths longer than `path_cap` are not cached.
const std = @import("std");
const c = std.c;
const os = @import("../os.zig");
const net = @import("net.zig");
const config = @import("../conf/config.zig");

pub const path_cap = 232;
const ways = 4;

const Entry = struct {
    hash: u64 = 0,
    used: bool = false,
    path_len: u16 = 0,
    fd: c_int = -1, // -1 for directories, errors and not-yet-cached entries
    err: c_int = 0,
    meta: os.Meta = .{ .kind = .other, .size = 0, .mtime = 0 },
    uses: u32 = 0,
    validated_ms: u64 = 0,
    last_ms: u64 = 0,
    path: [path_cap]u8 = undefined,

    fn drop(e: *Entry) void {
        if (e.fd >= 0) net.close(e.fd);
        e.* = .{};
    }
};

pub const Result = union(enum) {
    /// `owned` = the caller must close `fd` (it is not held by the cache).
    file: struct { fd: c_int, meta: os.Meta, owned: bool },
    /// not a regular file (directory etc.); no descriptor
    other: os.Meta,
    err: c_int,
};

pub const Cache = struct {
    sets: []Entry = &.{},
    nsets: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, max: u32) !Cache {
        if (max == 0) return .{};
        const nsets = std.math.ceilPowerOfTwo(usize, @max(1, (max + ways - 1) / ways)) catch return error.OutOfMemory;
        const sets = try gpa.alloc(Entry, nsets * ways);
        for (sets) |*e| e.* = .{};
        return .{ .sets = sets, .nsets = nsets };
    }

    pub fn deinit(cache: *Cache, gpa: std.mem.Allocator) void {
        for (cache.sets) |*e| if (e.used) e.drop();
        if (cache.sets.len > 0) gpa.free(cache.sets);
        cache.* = .{};
    }

    /// Opens `path` (or returns the cached descriptor) using the location's settings.
    pub fn open(cache: *Cache, ofc: config.OpenFileCache, path: [:0]const u8, now: u64) Result {
        if (ofc.max == 0 or cache.nsets == 0 or path.len > path_cap) return openUncached(path);
        const h = std.hash.Wyhash.hash(0x2f, path);
        const set = cache.sets[(h & (cache.nsets - 1)) * ways ..][0..ways];
        var victim: *Entry = &set[0];
        for (set) |*e| {
            if (e.used and e.hash == h and e.path_len == path.len and std.mem.eql(u8, e.path[0..e.path_len], path)) {
                if (now -| e.last_ms > ofc.inactive_ms) {
                    e.drop();
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
                    e.drop();
                    victim = e;
                    break;
                }
                if (e.meta.kind != .file) {
                    cache.hits += 1;
                    return .{ .other = e.meta };
                }
                if (e.fd >= 0) {
                    cache.hits += 1;
                    return .{ .file = .{ .fd = e.fd, .meta = e.meta, .owned = false } };
                }
                // counted but not yet min_uses: open now, keep it once the threshold is met
                const r = openUncached(path);
                if (r == .file and e.uses >= ofc.min_uses) {
                    e.fd = r.file.fd;
                    e.meta = r.file.meta;
                    e.validated_ms = now;
                    return .{ .file = .{ .fd = r.file.fd, .meta = r.file.meta, .owned = false } };
                }
                return r;
            }
            if (!e.used) victim = e else if (victim.used and e.last_ms < victim.last_ms) victim = e;
        }
        cache.misses += 1;
        const r = openUncached(path);
        if (r == .err and !ofc.errors) return r;
        if (victim.used) victim.drop();
        victim.* = .{ .hash = h, .used = true, .path_len = @intCast(path.len), .uses = 1, .validated_ms = now, .last_ms = now };
        @memcpy(victim.path[0..path.len], path);
        switch (r) {
            .err => |e| victim.err = e,
            .other => |m| victim.meta = m,
            .file => |f| {
                victim.meta = f.meta;
                if (ofc.min_uses <= 1) {
                    victim.fd = f.fd;
                    return .{ .file = .{ .fd = f.fd, .meta = f.meta, .owned = false } };
                }
            },
        }
        return r;
    }

    /// stat()-based lookup (try_files, index): never keeps a descriptor open by itself.
    pub fn stat(cache: *Cache, ofc: config.OpenFileCache, path: [:0]const u8, now: u64) ?os.Meta {
        if (ofc.max == 0 or cache.nsets == 0 or path.len > path_cap) return os.statZ(path);
        const h = std.hash.Wyhash.hash(0x2f, path);
        const set = cache.sets[(h & (cache.nsets - 1)) * ways ..][0..ways];
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

    fn revalidate(cache: *Cache, e: *Entry, path: [:0]const u8, now: u64) void {
        _ = cache;
        e.validated_ms = now;
        const m = os.statZ(path) orelse {
            if (e.fd >= 0) net.close(e.fd);
            e.fd = -1;
            e.err = os.errnoInt();
            if (e.err == 0) e.err = @intFromEnum(c.E.NOENT);
            return;
        };
        if (e.err == 0 and m.kind == e.meta.kind and m.ino == e.meta.ino and m.mtime == e.meta.mtime and m.size == e.meta.size) return;
        // changed: forget the old descriptor; the next open() call reopens
        if (e.fd >= 0) net.close(e.fd);
        e.fd = -1;
        e.err = 0;
        e.meta = m;
        if (m.kind == .file) {
            switch (openUncached(path)) {
                .file => |f| {
                    e.fd = f.fd;
                    e.meta = f.meta;
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
        return .{ .err = if (e == 0) @intFromEnum(c.E.IO) else e };
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
