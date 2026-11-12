//! Bounded request parsers. All returned slices live in the caller's allocator/body.
const std = @import("std");
pub const Field = struct { name: []const u8, value: []const u8, filename: ?[]const u8 = null, content_type: ?[]const u8 = null };
pub const max_fields = 256;
pub fn decode(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const out = try a.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        out[n] = switch (raw[i]) {
            '+' => ' ',
            '%' => blk: {
                if (i + 2 >= raw.len) return error.BadRequest;
                const v = std.fmt.parseInt(u8, raw[i + 1 ..][0..2], 16) catch return error.BadRequest;
                i += 2;
                break :blk v;
            },
            else => raw[i],
        };
        n += 1;
    }
    return out[0..n];
}
pub fn form(a: std.mem.Allocator, raw: []const u8) ![]Field {
    var fields: std.ArrayList(Field) = .empty;
    var it = std.mem.splitScalar(u8, raw, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        if (fields.items.len == max_fields) return error.TooManyFields;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        try fields.append(a, .{ .name = try decode(a, pair[0..eq]), .value = try decode(a, if (eq < pair.len) pair[eq + 1 ..] else "") });
    }
    return fields.toOwnedSlice(a);
}
pub fn json(a: std.mem.Allocator, raw: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{ .allocate = .alloc_always, .max_value_len = raw.len }) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.BadRequest;
    };
}
pub fn mediaType(raw: []const u8, expected: []const u8) bool {
    var it = std.mem.splitScalar(u8, raw, ';');
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, it.next().?, " \t"), expected);
}
fn parameter(a: std.mem.Allocator, raw: []const u8, key: []const u8) !?[]const u8 {
    var i = (std.mem.indexOfScalar(u8, raw, ';') orelse return null) + 1;
    var found: ?[]const u8 = null;
    while (i < raw.len) {
        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
        const start = i;
        while (i < raw.len and raw[i] != '=' and raw[i] != ';') : (i += 1) {}
        if (i == raw.len or raw[i] != '=') return error.BadRequest;
        const name = std.mem.trim(u8, raw[start..i], " \t");
        i += 1;
        while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
        var value: []const u8 = undefined;
        if (i < raw.len and raw[i] == '"') {
            i += 1;
            var out: std.ArrayList(u8) = .empty;
            while (i < raw.len and raw[i] != '"') : (i += 1) {
                if (raw[i] == '\\') {
                    i += 1;
                    if (i == raw.len) return error.BadRequest;
                }
                if (raw[i] < 0x20 or raw[i] == 0x7f) return error.BadRequest;
                try out.append(a, raw[i]);
            }
            if (i == raw.len) return error.BadRequest;
            i += 1;
            value = try out.toOwnedSlice(a);
            while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
            if (i < raw.len and raw[i] != ';') return error.BadRequest;
        } else {
            const begin = i;
            while (i < raw.len and raw[i] != ';') : (i += 1) {}
            value = std.mem.trim(u8, raw[begin..i], " \t");
            for (value) |ch| if (ch < 0x21 or ch == 0x7f or ch == '"' or ch == '\\') return error.BadRequest;
        }
        if (std.ascii.eqlIgnoreCase(name, key)) {
            if (found != null) return error.BadRequest;
            found = value;
        }
        if (i < raw.len) i += 1;
    }
    return found;
}
pub fn multipart(a: std.mem.Allocator, content_type: []const u8, raw: []const u8) ![]Field {
    const boundary = (try parameter(a, content_type, "boundary")) orelse return error.BadRequest;
    if (boundary.len == 0 or boundary.len > 70 or boundary[boundary.len - 1] == ' ') return error.BadRequest;
    for (boundary) |ch| if (ch < 0x20 or ch > 0x7e) return error.BadRequest;
    const delimiter = try std.fmt.allocPrint(a, "--{s}", .{boundary});
    const marker = try std.fmt.allocPrint(a, "\r\n{s}", .{delimiter});
    if (!std.mem.startsWith(u8, raw, delimiter)) return error.BadRequest;
    var rest = raw[delimiter.len..];
    var result: std.ArrayList(Field) = .empty;
    while (true) {
        if (std.mem.startsWith(u8, rest, "--")) {
            if (rest.len != 2 and !std.mem.startsWith(u8, rest[2..], "\r\n")) return error.BadRequest;
            return result.toOwnedSlice(a);
        }
        if (!std.mem.startsWith(u8, rest, "\r\n")) return error.BadRequest;
        rest = rest[2..];
        const end = std.mem.indexOf(u8, rest, "\r\n\r\n") orelse return error.BadRequest;
        if (end > 8192 or result.items.len == max_fields) return error.TooManyFields;
        var disposition: ?[]const u8 = null;
        var content: ?[]const u8 = null;
        var lines = std.mem.splitSequence(u8, rest[0..end], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(line[0..colon], "Content-Disposition")) {
                if (disposition != null) return error.BadRequest;
                disposition = value;
            } else if (std.ascii.eqlIgnoreCase(line[0..colon], "Content-Type")) content = value;
        }
        const d = disposition orelse return error.BadRequest;
        if (!mediaType(d, "form-data")) return error.BadRequest;
        rest = rest[end + 4 ..];
        var offset: usize = 0;
        const finish = while (std.mem.indexOfPos(u8, rest, offset, marker)) |pos| {
            const tail = rest[pos + marker.len ..];
            if (std.mem.startsWith(u8, tail, "--") or std.mem.startsWith(u8, tail, "\r\n")) break pos;
            offset = pos + marker.len;
        } else return error.BadRequest;
        try result.append(a, .{ .name = (try parameter(a, d, "name")) orelse return error.BadRequest, .filename = try parameter(a, d, "filename"), .content_type = content, .value = rest[0..finish] });
        rest = rest[finish + marker.len ..];
    }
}
test "form preserves duplicate keys and decodes percent/plus; malformed escapes fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = try form(a, "x=a%2Bb&x=a+b&empty&%41=1");
    try std.testing.expectEqual(@as(usize, 4), fields.len);
    try std.testing.expectEqualStrings("a+b", fields[0].value);
    try std.testing.expectEqualStrings("a b", fields[1].value);
    try std.testing.expectEqualStrings("A", fields[3].name);
    try std.testing.expectError(error.BadRequest, form(a, "x=%Q0"));
}
test "multipart binary files and boundary-like bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fields = try multipart(arena.allocator(), "multipart/form-data; boundary=abc", "--abc\r\nContent-Disposition: form-data; name=upload; filename=a.bin\r\nContent-Type: application/octet-stream\r\n\r\n\x00\r\n--abcX\r\n--abc--\r\n");
    try std.testing.expectEqualStrings("\x00\r\n--abcX", fields[0].value);
    try std.testing.expectEqualStrings("a.bin", fields[0].filename.?);
}
