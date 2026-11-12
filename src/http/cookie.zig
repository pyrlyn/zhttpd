const std = @import("std");
pub const Options = struct {
    path: []const u8 = "/",
    domain: ?[]const u8 = null,
    max_age: ?i64 = null,
    secure: bool = true,
    http_only: bool = true,
    same_site: enum { Strict, Lax, None } = .Lax,
};
pub fn read(raw: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, raw, ';');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        if (std.mem.eql(u8, p[0..eq], name)) return p[eq + 1 ..];
    }
    return null;
}
pub fn serialize(a: std.mem.Allocator, name: []const u8, value: []const u8, options: Options) ![]const u8 {
    if (name.len == 0) return error.InvalidCookie;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", ch) == null) return error.InvalidCookie;
    for (value) |ch| if (ch < 0x21 or ch > 0x7e or std.mem.indexOfScalar(u8, "\";,\\", ch) != null) return error.InvalidCookie;
    for ([_][]const u8{ options.path, options.domain orelse "" }) |attr| for (attr) |ch| {
        if (ch < 0x20 or ch >= 0x7f or ch == ';') return error.InvalidCookie;
    };
    if (options.same_site == .None and !options.secure) return error.InvalidCookie;
    if (std.mem.startsWith(u8, name, "__Secure-") and !options.secure) return error.InvalidCookie;
    if (std.mem.startsWith(u8, name, "__Host-") and (!options.secure or options.domain != null or !std.mem.eql(u8, options.path, "/"))) return error.InvalidCookie;
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{s}={s}; Path={s}; SameSite={s}", .{ name, value, options.path, @tagName(options.same_site) });
    if (options.domain) |d| try out.writer.print("; Domain={s}", .{d});
    if (options.max_age) |age| try out.writer.print("; Max-Age={d}", .{age});
    if (options.secure) try out.writer.writeAll("; Secure");
    if (options.http_only) try out.writer.writeAll("; HttpOnly");
    return out.toOwnedSlice();
}
test "safe cookie attributes and deletion" {
    const a = std.testing.allocator;
    const value = try serialize(a, "sid", "", .{ .max_age = 0 });
    defer a.free(value);
    try std.testing.expect(std.mem.indexOf(u8, value, "Max-Age=0; Secure; HttpOnly") != null);
    try std.testing.expectError(error.InvalidCookie, serialize(a, "x", "a\r\nX: yes", .{}));
    try std.testing.expectError(error.InvalidCookie, serialize(a, "x", "ok", .{ .same_site = .None, .secure = false }));
}
