//! Shared log formats and escaping for every configuration adapter.
const std = @import("std");
const expr = @import("expression");
pub const Level = enum(u8) { emerg, alert, crit, err, warn, notice, info, debug };
pub const Escape = enum { default, json, none };
pub const Format = struct { name: []const u8, expr: expr.Expr, escape: Escape = .default };
pub const AccessLog = struct { path: []const u8, format: *const Format };
pub const ErrorLog = struct { path: []const u8, level: u8 = 3 };
pub const common = "$remote_addr - - [$time_local] \"$request\" $status $body_bytes_sent";
pub const combined = common ++ " \"$http_referer\" \"$http_user_agent\"";
// Stable zhttpd JSON schema, also used by the Caddy compatibility adapter.
pub const json = "{\"time\":\"$time_iso8601\",\"remote_addr\":\"$remote_addr\",\"method\":\"$request_method\",\"uri\":\"$request_uri\",\"protocol\":\"$server_protocol\",\"status\":$status,\"bytes\":$body_bytes_sent,\"duration\":$request_time}";

pub fn level(value: []const u8) ?u8 {
    inline for (.{ "emerg", "alert", "crit", "err", "warn", "notice", "info", "debug" }, 0..) |name, i| if (std.ascii.eqlIgnoreCase(value, name)) return i;
    if (std.ascii.eqlIgnoreCase(value, "error")) return 3;
    if (std.ascii.eqlIgnoreCase(value, "warning")) return 4;
    return null;
}
pub fn compile(a: std.mem.Allocator, name: []const u8, text: []const u8, escape: Escape) !*Format {
    const f = try a.create(Format);
    errdefer a.destroy(f);
    f.* = .{ .name = name, .expr = try expr.compile(a, text), .escape = escape };
    return f;
}
/// Translate the supported Apache/OLS percent fields into shared variables.
/// Unsupported modifiers are errors, never silently replaced by empty text.
pub fn apache(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '%') {
            if (text[i] == '$' or text[i] == '\n' or text[i] == '\r') return error.BadFormat;
            try out.append(a, text[i]);
            continue;
        }
        i += 1;
        if (i >= text.len) return error.BadFormat;
        if (text[i] == '>') {
            i += 1;
            if (i >= text.len or text[i] != 's') return error.BadFormat;
        }
        if (text[i] == '{') {
            const end = std.mem.indexOfScalarPos(u8, text, i, '}') orelse return error.BadFormat;
            if (end + 1 >= text.len or (text[end + 1] != 'i' and text[end + 1] != 'o')) return error.BadFormat;
            try out.appendSlice(a, if (text[end + 1] == 'i') "${http_" else "${sent_http_");
            for (text[i + 1 .. end]) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return error.BadFormat;
                try out.append(a, if (ch == '-') '_' else std.ascii.toLower(ch));
            }
            try out.append(a, '}');
            i = end + 1;
            continue;
        }
        try out.appendSlice(a, switch (text[i]) {
            'a', 'h' => "${remote_addr}",
            'l', 'u' => "-",
            't' => "[${time_local}]",
            'r' => "${request}",
            's' => "${status}",
            'b', 'B' => "${body_bytes_sent}",
            'm' => "${request_method}",
            'U' => "${uri}",
            'H' => "${server_protocol}",
            'v', 'V' => "${server_name}",
            'p' => "${server_port}",
            '%' => "%",
            else => return error.BadFormat,
        });
    }
    return out.toOwnedSlice(a);
}
pub fn appendBounded(line: *std.ArrayList(u8), s: []const u8) void {
    const n = @min(s.len, line.capacity - line.items.len);
    line.appendSliceAssumeCapacity(s[0..n]);
}
pub fn appendEscaped(line: *std.ArrayList(u8), s: []const u8, escape: Escape) void {
    if (escape == .none) return appendBounded(line, s);
    const hex = "0123456789ABCDEF";
    const valid_utf8 = std.unicode.utf8ValidateSlice(s);
    for (s) |ch| {
        if (escape == .json) {
            if (ch < 0x20 or (!valid_utf8 and ch >= 0x80)) {
                if (line.capacity - line.items.len < 6) return;
                line.appendSliceAssumeCapacity(&.{ '\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 15] });
            } else if (ch == '"' or ch == '\\') {
                if (line.capacity - line.items.len < 2) return;
                line.appendSliceAssumeCapacity(&.{ '\\', ch });
            } else {
                if (line.items.len == line.capacity) return;
                line.appendAssumeCapacity(ch);
            }
        } else if (ch == '"' or ch == '\\' or ch < 0x20 or ch >= 0x7f) {
            if (line.capacity - line.items.len < 4) return;
            line.appendSliceAssumeCapacity(&.{ '\\', 'x', hex[ch >> 4], hex[ch & 15] });
        } else {
            if (line.items.len == line.capacity) return;
            line.appendAssumeCapacity(ch);
        }
    }
}
test "Apache fields and JSON escaping" {
    const a = std.testing.allocator;
    const translated = try apache(a, "%h %>s %{User-Agent}i");
    defer a.free(translated);
    try std.testing.expectEqualStrings("${remote_addr} ${status} ${http_user_agent}", translated);
    try std.testing.expectError(error.BadFormat, apache(a, "%{unsupported}x"));
    var buf: [128]u8 = undefined;
    var out: std.ArrayList(u8) = .initBuffer(&buf);
    appendEscaped(&out, "a\n\"\\", .json);
    try std.testing.expectEqualStrings("a\\u000A\\\"\\\\", out.items);
}
