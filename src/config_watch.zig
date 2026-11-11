//! Configuration dependencies and a portable, content-based master watcher.
//! Loaders record paths before opening them, including missing files/globs, so
//! fixing a rejected configuration can trigger another attempt automatically.
const std = @import("std");
const os = @import("os.zig");
const c = std.c;
const Hash = std.crypto.hash.sha2.Sha256;
pub const Kind = enum { file, glob, tls, credentials };
const Entry = struct { path: []const u8, kind: Kind, digest: ?[32]u8, changed: bool = false };
/// The single ACME child may be writing this pair. Observe its final state only
/// after it exits; intermediate writes must not supersede its own reload.
pub const Writer = struct {
    certificate: []const u8,
    key: []const u8,
    fn matches(w: Writer, path: []const u8) bool {
        return std.mem.eql(u8, w.certificate, path) or std.mem.eql(u8, w.key, path);
    }
};

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

    pub fn credentialsChanged(s: *const Sources, path: []const u8) bool {
        for (s.entries.items) |entry| {
            if (entry.kind == .credentials and entry.changed and std.mem.eql(u8, entry.path, path)) return true;
        }
        return false;
    }

    pub fn usesWriter(s: *const Sources, writer: Writer) bool {
        for (s.entries.items) |entry| if (entry.kind == .tls and writer.matches(entry.path)) return true;
        return false;
    }

    fn acknowledge(s: *Sources, writer: Writer) void {
        for (s.entries.items) |*entry| {
            if (entry.kind == .tls and writer.matches(entry.path)) {
                entry.digest = fingerprint(s.gpa, entry.path, .tls);
                entry.changed = false;
            }
        }
    }

    fn scan(s: *Sources, writer: ?Writer) bool {
        var changed = false;
        for (s.entries.items) |*entry| {
            if (writer) |w| {
                if (entry.kind == .tls and w.matches(entry.path)) continue;
            }
            const next = fingerprint(s.gpa, entry.path, entry.kind);
            const equal = if (next) |digest|
                if (entry.digest) |previous| std.mem.eql(u8, &digest, &previous) else false
            else
                entry.digest == null;
            changed = changed or !equal;
            entry.changed = entry.changed or !equal;
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

    pub fn poll(w: *Watcher, now: i64, writer: ?Writer) bool {
        if (now < w.next_poll_ms) return false;
        w.next_poll_ms = now + poll_interval_ms;
        const active_changed = w.active.scan(writer);
        const attempt_changed = w.attempt.scan(writer);
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

    pub fn beginAttempt(w: *Watcher, writer: ?Writer) void {
        // A manual reload also acknowledges changes already present on disk.
        _ = w.active.scan(writer);
        w.attempt.deinit();
        w.changed_ms = null;
    }

    pub fn acknowledgeTls(w: *Watcher, writer: Writer) void {
        w.active.acknowledge(writer);
        w.attempt.acknowledge(writer);
    }

    pub fn credentialsChanged(w: *const Watcher, path: []const u8) bool {
        return w.active.credentialsChanged(path) or w.attempt.credentialsChanged(path);
    }

    pub fn accept(w: *Watcher) void {
        w.active.deinit();
        w.active = w.attempt;
        w.attempt = .{ .gpa = w.active.gpa };
    }
};
