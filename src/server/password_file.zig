//! Bounded, non-interactive PEM passphrase files. No secrets enter Config/Diag.
const std = @import("std");
const os = @import("../os.zig");
const c = std.c;

pub const PasswordFile = struct {
    pub const max_bytes = 64 * 1024;
    pub const max_passwords = 64;
    pub const max_password_bytes = 1023;
    bytes: [max_bytes + 1]u8 = undefined,
    lines: [max_passwords][]const u8 = undefined,
    count: usize = 0,

    pub fn deinit(p: *PasswordFile) void {
        std.crypto.secureZero(u8, &p.bytes);
        p.count = 0;
    }

    pub fn read(p: *PasswordFile, allocator: std.mem.Allocator, path: []const u8) !void {
        const name = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(name);
        const fd = c.open(name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true });
        if (fd < 0) return error.CannotOpenPasswordFile;
        defer _ = c.close(fd);
        const meta = os.fstat(fd) orelse return error.CannotStatPasswordFile;
        if (meta.kind != .file) return error.PasswordFileMustBeRegular;
        if (meta.size > max_bytes) return error.PasswordFileTooLarge;
        var used: usize = 0;
        while (used < p.bytes.len) {
            const n = c.read(fd, p.bytes[used..].ptr, p.bytes.len - used);
            if (n < 0) {
                if (os.errnoNow() == .INTR) continue;
                return error.CannotReadPasswordFile;
            }
            if (n == 0) break;
            used += @intCast(n);
        }
        if (used > max_bytes) return error.PasswordFileTooLarge;
        try p.parse(used);
    }

    pub fn digest(p: *const PasswordFile) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        defer std.crypto.secureZero(u8, std.mem.asBytes(&hash));
        for (p.lines[0..p.count]) |line| {
            hash.update(line);
            hash.update("\x00");
        }
        var result: [32]u8 = undefined;
        hash.final(&result);
        return result;
    }

    fn parse(p: *PasswordFile, size: usize) !void {
        p.count = 0;
        var lines = std.mem.splitScalar(u8, p.bytes[0..size], '\n');
        while (lines.next()) |raw| {
            const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
            if (line.len == 0) continue;
            if (line.len > max_password_bytes) return error.PassphraseTooLong;
            if (std.mem.indexOfScalar(u8, line, 0) != null) return error.InvalidPassphrase;
            if (p.count == max_passwords) return error.TooManyPassphrases;
            p.lines[p.count] = line;
            p.count += 1;
        }
        if (p.count == 0) return error.EmptyPasswordFile;
    }
};

test "passphrases preserve whitespace and literal characters with LF or CRLF" {
    var p: PasswordFile = .{};
    defer p.deinit();
    const input = "\r\n  #literal 'secret'  \r\nsecond\nlast";
    @memcpy(p.bytes[0..input.len], input);
    try p.parse(input.len);
    try std.testing.expectEqual(@as(usize, 3), p.count);
    try std.testing.expectEqualStrings("  #literal 'secret'  ", p.lines[0]);
    try std.testing.expectEqualStrings("second", p.lines[1]);
    try std.testing.expectEqualStrings("last", p.lines[2]);
}

test "invalid passphrase files fail without returning any contents" {
    var p: PasswordFile = .{};
    defer p.deinit();
    try std.testing.expectError(error.EmptyPasswordFile, p.parse(0));
    p.bytes[0] = 0;
    try std.testing.expectError(error.InvalidPassphrase, p.parse(1));
    @memset(p.bytes[0..1024], 'x');
    try std.testing.expectError(error.PassphraseTooLong, p.parse(1024));
    for (0..65) |i| {
        p.bytes[i * 2] = 'x';
        p.bytes[i * 2 + 1] = '\n';
    }
    try std.testing.expectError(error.TooManyPassphrases, p.parse(130));
}
