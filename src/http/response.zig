//! Response helpers: status lines, HTTP dates, branded default error pages.
const std = @import("std");
const error_page = @import("error_page.zig");
pub const page_buffer_size = error_page.buffer_size;

pub fn reason(code: u16) []const u8 {
    return switch (code) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Moved Temporarily", // nginx wording
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Not Allowed", // nginx wording
        406 => "Not Acceptable",
        408 => "Request Time-out",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Request Entity Too Large",
        414 => "Request-URI Too Large",
        415 => "Unsupported Media Type",
        416 => "Requested Range Not Satisfiable",
        421 => "Misdirected Request",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Temporarily Unavailable",
        504 => "Gateway Time-out",
        505 => "HTTP Version Not Supported",
        507 => "Insufficient Storage",
        else => "",
    };
}

/// Codes for which nginx generates its built-in HTML body.
pub fn hasDefaultPage(code: u16) bool {
    return (code >= 301 and code <= 308 and code != 304 and code != 305 and code != 306) or (code >= 400 and code <= 599 and reason(code).len > 0);
}

/// Branded errors; redirects retain the compact nginx-compatible body.
pub fn writeDefaultPage(w: *std.Io.Writer, code: u16, tokens: []const u8) !void {
    if (code >= 400) return error_page.write(w, code, reason(code), tokens);
    try w.print("<html>\r\n<head><title>{d} {s}</title></head>\r\n<body>\r\n<center><h1>{d} {s}</h1></center>\r\n<hr><center>{s}</center>\r\n</body>\r\n</html>\r\n", .{ code, reason(code), code, reason(code), tokens });
}

pub fn defaultPageLen(code: u16, tokens: []const u8) usize {
    var buf: [256]u8 = undefined;
    var sink = std.Io.Writer.Discarding.init(&buf);
    writeDefaultPage(&sink.writer, code, tokens) catch unreachable;
    return @intCast(sink.fullCount());
}

pub const Civil = struct { year: i64, month: u8, day: u8, hour: u8, min: u8, sec: u8, wday: u8 };

/// Unix seconds -> UTC civil time (Howard Hinnant's days_from_civil inverse).
pub fn civil(ts: i64) Civil {
    const days = @divFloor(ts, 86400);
    const secs: u32 = @intCast(ts - days * 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y = @as(i64, yoe) + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    const wday: u8 = @intCast(@mod(days + 4, 7)); // 1970-01-01 was a Thursday
    return .{ .year = y, .month = m, .day = d, .hour = @intCast(secs / 3600), .min = @intCast(secs / 60 % 60), .sec = @intCast(secs % 60), .wday = wday };
}

const wdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// IMF-fixdate: "Tue, 10 Nov 2026 07:30:00 GMT" (29 bytes).
pub fn httpDate(buf: *[29]u8, ts: i64) []const u8 {
    const c = civil(ts);
    return std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{ wdays[c.wday], c.day, months[c.month - 1], @as(u64, @intCast(c.year)), c.hour, c.min, c.sec }) catch unreachable;
}

/// nginx $time_local: "10/Nov/2026:09:30:00 +0200".
pub fn logDate(buf: *[26]u8, ts: i64, gmtoff: i64) []const u8 {
    const c = civil(ts + gmtoff);
    const sign: u8 = if (gmtoff < 0) '-' else '+';
    const off: u64 = @abs(gmtoff);
    return std.fmt.bufPrint(buf, "{d:0>2}/{s}/{d:0>4}:{d:0>2}:{d:0>2}:{d:0>2} {c}{d:0>2}{d:0>2}", .{ c.day, months[c.month - 1], @as(u64, @intCast(c.year)), c.hour, c.min, c.sec, sign, off / 3600, off / 60 % 60 }) catch unreachable;
}

/// Parse an HTTP date (IMF-fixdate, RFC 850, asctime). Returns unix seconds.
pub fn parseHttpDate(s: []const u8) ?i64 {
    var it = std.mem.tokenizeAny(u8, s, " ,-:");
    var parts: [8][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |p| {
        if (n == parts.len) return null;
        parts[n] = p;
        n += 1;
    }
    var day: i64 = 0;
    var mon: i64 = 0;
    var year: i64 = 0;
    var hms: [3]i64 = undefined;
    const monthIdx = struct {
        fn f(m: []const u8) ?i64 {
            for (months, 0..) |name, i| if (std.ascii.eqlIgnoreCase(name, m)) return @intCast(i + 1);
            return null;
        }
    }.f;
    if (n == 8) { // "Tue, 10 Nov 2026 07:30:00 GMT" or "Tuesday, 10-Nov-26 07:30:00 GMT"
        day = std.fmt.parseInt(i64, parts[1], 10) catch return null;
        mon = monthIdx(parts[2]) orelse return null;
        year = std.fmt.parseInt(i64, parts[3], 10) catch return null;
        if (year < 100) year += if (year < 70) 2000 else 1900;
        for (0..3) |i| hms[i] = std.fmt.parseInt(i64, parts[4 + i], 10) catch return null;
    } else if (n == 7) { // asctime: "Tue Nov 10 07:30:00 2026"
        mon = monthIdx(parts[1]) orelse return null;
        day = std.fmt.parseInt(i64, parts[2], 10) catch return null;
        for (0..3) |i| hms[i] = std.fmt.parseInt(i64, parts[3 + i], 10) catch return null;
        year = std.fmt.parseInt(i64, parts[6], 10) catch return null;
    } else return null;
    // days_from_civil
    const y = if (mon <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (mon > 2) mon - 3 else mon + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hms[0] * 3600 + hms[1] * 60 + hms[2];
}

test "dates" {
    var b: [29]u8 = undefined;
    try std.testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", httpDate(&b, 0));
    try std.testing.expectEqualStrings("Tue, 10 Nov 2026 07:30:00 GMT", httpDate(&b, 1794295800));
    try std.testing.expectEqual(@as(?i64, 1794295800), parseHttpDate("Tue, 10 Nov 2026 07:30:00 GMT"));
    try std.testing.expectEqual(@as(?i64, 1794295800), parseHttpDate("Tue Nov 10 07:30:00 2026"));
    var l: [26]u8 = undefined;
    try std.testing.expectEqualStrings("10/Nov/2026:09:30:00 +0200", logDate(&l, 1794295800, 7200));
}

test "default errors fit the worker buffer with exact lengths" {
    for (400..600) |value| {
        const code: u16 = @intCast(value);
        if (!hasDefaultPage(code)) continue;
        for ([_][]const u8{ "zhttpd", "zhttpd/0.1.0" }) |tokens| {
            var buf: [page_buffer_size]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            try writeDefaultPage(&w, code, tokens);
            const body = w.buffered();
            try std.testing.expectEqual(defaultPageLen(code, tokens), body.len);
            try std.testing.expect(std.mem.startsWith(u8, body, "<!doctype html>"));
            try std.testing.expect(std.mem.endsWith(u8, body, "</body></html>\n"));
            try std.testing.expect(std.mem.indexOf(u8, body, reason(code)) != null);
            try std.testing.expect(std.mem.indexOf(u8, body, "<script") == null);
            if (std.mem.eql(u8, tokens, "zhttpd"))
                try std.testing.expect(std.mem.indexOf(u8, body, "zhttpd/") == null);
        }
    }
}

test "error page escapes server tokens" {
    var buf: [page_buffer_size]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeDefaultPage(&w, 404, "<test>&\"'");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "&lt;test&gt;&amp;&quot;&#39;") != null);
    try std.testing.expectEqual(w.buffered().len, defaultPageLen(404, "<test>&\"'"));
}

test "redirects retain nginx layout and bodyless statuses have no default page" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeDefaultPage(&w, 301, "zhttpd");
    try std.testing.expectEqualStrings("<html>\r\n<head><title>301 Moved Permanently</title></head>\r\n<body>\r\n<center><h1>301 Moved Permanently</h1></center>\r\n<hr><center>zhttpd</center>\r\n</body>\r\n</html>\r\n", w.buffered());
    for ([_]u16{ 100, 200, 204, 304, 444 }) |code| try std.testing.expect(!hasDefaultPage(code));
}
