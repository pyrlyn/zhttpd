//! Configuration dependencies and a portable, content-based master watcher.
//! Loaders record paths before opening them, including missing files/globs, so
//! fixing a rejected configuration can trigger another attempt automatically.
const std = @import("std");
const os = @import("os.zig");
const c = std.c;
const Hash = std.crypto.hash.sha2.Sha256;
pub const Kind = enum { file, glob };
const Entry = struct { path: []const u8, kind: Kind, digest: ?[32]u8 };

fn fingerprint(gpa: std.mem.Allocator, path: []const u8, kind: Kind) ?[32]u8 {
    var hash = Hash.init(.{});
    if (kind == .glob) {
        const matches = os.glob(gpa, path) catch return null;
        defer os.freeList(gpa, matches);
        for (matches) |name| {
            hash.update(name);
            hash.update("\x00");
        }
    } else {
        const name = gpa.dupeSentinel(u8, path, 0) catch return null;
        defer gpa.free(name);
        const fd = c.open(name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true });
        if (fd < 0) return null;
        defer _ = c.close(fd);
        const meta = os.fstat(fd) orelse return null;
        if (meta.kind != .file) return null;
        var buffer: [16384]u8 = undefined;
        // Bound each read pass to the size at open time, even if a writer keeps
        // appending. The next poll will detect any subsequent content.
        var remaining = meta.size;
        while (remaining > 0) {
            const n = c.read(fd, &buffer, @intCast(@min(remaining, buffer.len)));
            if (n < 0) {
                if (os.errnoNow() == .INTR) continue;
                return null;
            }
            if (n == 0) break;
            hash.update(buffer[0..@intCast(n)]);
            remaining -= @intCast(n);
        }
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

pub const Sources = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(s: *Sources) void {
        for (s.entries.items) |entry| s.gpa.free(entry.path);
        s.entries.deinit(s.gpa);
        s.entries = .empty;
    }

    pub fn observe(s: *Sources, path: []const u8, kind: Kind) !void {
        for (s.entries.items) |entry| {
            if (entry.kind == kind and std.mem.eql(u8, entry.path, path)) return;
        }
        const owned = try s.gpa.dupe(u8, path);
        errdefer s.gpa.free(owned);
        try s.entries.append(s.gpa, .{ .path = owned, .kind = kind, .digest = fingerprint(s.gpa, path, kind) });
    }

    fn scan(s: *Sources) bool {
        var changed = false;
        for (s.entries.items) |*entry| {
            const next = fingerprint(s.gpa, entry.path, entry.kind);
            const equal = if (next) |digest|
                if (entry.digest) |previous| std.mem.eql(u8, &digest, &previous) else false
            else
                entry.digest == null;
            changed = changed or !equal;
            entry.digest = next;
        }
        return changed;
    }
};

pub const Watcher = struct {
    active: Sources,
    attempt: Sources,
    next_poll_ms: i64 = 0,
    changed_ms: ?i64 = null,
    pub const poll_interval_ms = 250;
    pub const settle_ms = 500;

    pub fn deinit(w: *Watcher) void {
        w.active.deinit();
        w.attempt.deinit();
    }

    pub fn poll(w: *Watcher, now: i64) bool {
        if (now < w.next_poll_ms) return false;
        w.next_poll_ms = now + poll_interval_ms;
        const active_changed = w.active.scan();
        const attempt_changed = w.attempt.scan();
        if (active_changed or attempt_changed) w.changed_ms = now;
        if (w.changed_ms) |changed| {
            if (now - changed >= settle_ms) {
                w.changed_ms = null;
                return true;
            }
        }
        return false;
    }

    pub fn unsettled(w: *const Watcher) bool {
        return w.changed_ms != null;
    }

    pub fn beginAttempt(w: *Watcher) void {
        // A manual reload also acknowledges changes already present on disk.
        _ = w.active.scan();
        w.attempt.deinit();
        w.changed_ms = null;
    }

    pub fn accept(w: *Watcher) void {
        w.active.deinit();
        w.active = w.attempt;
        w.attempt = .{ .gpa = w.active.gpa };
    }
};
