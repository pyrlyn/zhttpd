//! nginx-style diagnostics: `zhttpd: [emerg] unknown directive "foo" in /etc/nginx/nginx.conf:12`.
const std = @import("std");

pub const Level = enum {
    emerg,
    warn,
    notice,
    pub fn name(l: Level) []const u8 {
        return @tagName(l);
    }
};

pub const Message = struct { level: Level, text: []const u8 };

pub const Diag = struct {
    gpa: std.mem.Allocator,
    messages: std.ArrayList(Message) = .empty,
    /// When false, messages are only collected (tests); when true, printed to stderr as they come.
    echo: bool = false,

    pub fn deinit(d: *Diag) void {
        for (d.messages.items) |m| d.gpa.free(m.text);
        d.messages.deinit(d.gpa);
    }

    pub fn add(d: *Diag, level: Level, file: ?[]const u8, line: u32, comptime fmt: []const u8, args: anytype) void {
        const body = std.fmt.allocPrint(d.gpa, fmt, args) catch return;
        defer d.gpa.free(body);
        const text = (if (file) |f|
            std.fmt.allocPrint(d.gpa, "{s} in {s}:{d}", .{ body, f, line })
        else
            d.gpa.dupe(u8, body)) catch return;
        d.messages.append(d.gpa, .{ .level = level, .text = text }) catch {
            d.gpa.free(text);
            return;
        };
        if (d.echo) std.debug.print("zhttpd: [{s}] {s}\n", .{ level.name(), text });
    }

    pub fn count(d: *const Diag, level: Level) usize {
        var n: usize = 0;
        for (d.messages.items) |m| {
            if (m.level == level) n += 1;
        }
        return n;
    }

    pub fn has(d: *const Diag, needle: []const u8) bool {
        for (d.messages.items) |m| {
            if (std.mem.indexOf(u8, m.text, needle) != null) return true;
        }
        return false;
    }
};
