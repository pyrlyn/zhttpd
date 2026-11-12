const std = @import("std");
pub const max_bytes = 8 * 1024 * 1024;
pub fn accepts(raw: []const u8) bool {
    var it = std.mem.splitScalar(u8, raw, ',');
    var wildcard = false;
    while (it.next()) |part| {
        var params = std.mem.splitScalar(u8, part, ';');
        const name = std.mem.trim(u8, params.next().?, " \t");
        var quality: f32 = 1;
        while (params.next()) |p| {
            const v = std.mem.trim(u8, p, " \t");
            if (std.mem.startsWith(u8, v, "q=")) quality = std.fmt.parseFloat(f32, v[2..]) catch 0;
        }
        const allowed = quality > 0 and quality <= 1;
        if (std.ascii.eqlIgnoreCase(name, "gzip")) return allowed;
        if (std.mem.eql(u8, name, "*")) wildcard = allowed;
    }
    return wildcard;
}
pub fn encode(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(a, 4096);
    const buffer = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(buffer);
    const compressor = try a.create(std.compress.flate.Compress);
    defer a.destroy(compressor);
    compressor.* = try .init(&out.writer, buffer, .gzip, .fastest);
    try compressor.writer.writeAll(input);
    try compressor.finish();
    return out.toOwnedSlice();
}
test "gzip quality zero overrides wildcard" {
    try std.testing.expect(!accepts("br, gzip;q=0, *;q=1"));
    try std.testing.expect(accepts("gzip;q=0.5"));
}
