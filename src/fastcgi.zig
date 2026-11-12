//! FastCGI v1 responder codec. One request (id 1) per transport connection.
const std = @import("std");
pub const Param = struct { name: []const u8, value: []const u8 };
fn length(a: std.mem.Allocator, out: *std.ArrayList(u8), size: usize) !void {
    if (size < 128) try out.append(a, @intCast(size)) else {
        if (size > 0x7fffffff) return error.TooLarge;
        const n: u32 = @intCast(size);
        try out.appendSlice(a, &.{ @as(u8, @truncate(n >> 24)) | 128, @truncate(n >> 16), @truncate(n >> 8), @truncate(n) });
    }
}
pub fn record(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: u8, data: []const u8) !void {
    var rest = data;
    while (true) {
        const size = @min(rest.len, 65535);
        try out.appendSlice(a, &.{ 1, kind, 0, 1, @intCast(size >> 8), @truncate(size), 0, 0 });
        try out.appendSlice(a, rest[0..size]);
        rest = rest[size..];
        if (rest.len == 0) break;
    }
}
pub fn encode(a: std.mem.Allocator, params: []const Param, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try record(a, &out, 1, &.{ 0, 1, 0, 0, 0, 0, 0, 0 }); // responder, no KEEP_CONN
    var env: std.ArrayList(u8) = .empty;
    defer env.deinit(a);
    for (params) |p| {
        try length(a, &env, p.name.len);
        try length(a, &env, p.value.len);
        try env.appendSlice(a, p.name);
        try env.appendSlice(a, p.value);
    }
    if (env.items.len > 0) try record(a, &out, 4, env.items);
    try record(a, &out, 4, "");
    if (body.len > 0) try record(a, &out, 5, body);
    try record(a, &out, 5, "");
    return out.toOwnedSlice(a);
}
pub const Decoder = struct {
    header: [8]u8 = undefined,
    header_size: usize = 0,
    remaining: usize = 0,
    padding: usize = 0,
    kind: u8 = 0,
    end: [8]u8 = undefined,
    end_size: usize = 0,
    stdout_closed: bool = false,
    done: bool = false,
    stderr_bytes: usize = 0,
    pub const Result = struct { consumed: usize, produced: usize };
    pub fn feed(d: *Decoder, input: []const u8, output: []u8) !Result {
        var i: usize = 0;
        var n: usize = 0;
        while (i < input.len and !d.done) {
            if (d.header_size < 8) {
                const size = @min(8 - d.header_size, input.len - i);
                @memcpy(d.header[d.header_size..][0..size], input[i..][0..size]);
                d.header_size += size;
                i += size;
                if (d.header_size < 8) break;
                if (d.header[0] != 1 or d.header[2] != 0 or d.header[3] != 1) return error.Protocol;
                d.kind = d.header[1];
                if (d.kind != 6 and d.kind != 7 and d.kind != 3) return error.Protocol;
                d.remaining = (@as(usize, d.header[4]) << 8) | d.header[5];
                d.padding = d.header[6];
                if (d.kind == 3 and (d.remaining != 8 or !d.stdout_closed)) return error.Protocol;
                if (d.kind == 6) {
                    if (d.stdout_closed) return error.Protocol;
                    if (d.remaining == 0) d.stdout_closed = true;
                }
            }
            if (d.remaining > 0) {
                var size = @min(d.remaining, input.len - i);
                if (d.kind == 6) {
                    size = @min(size, output.len - n);
                    if (size == 0) break;
                    @memcpy(output[n..][0..size], input[i..][0..size]);
                    n += size;
                } else if (d.kind == 3) {
                    @memcpy(d.end[d.end_size..][0..size], input[i..][0..size]);
                    d.end_size += size;
                } else d.stderr_bytes += size;
                d.remaining -= size;
                i += size;
                if (d.remaining > 0) break;
            }
            const padding = @min(d.padding, input.len - i);
            d.padding -= padding;
            i += padding;
            if (d.padding > 0) break;
            if (d.kind == 3) {
                for (d.end[0..5]) |value| if (value != 0) return error.Application;
                d.done = true;
            }
            d.header_size = 0;
        }
        return .{ .consumed = i, .produced = n };
    }
};
test "fragmented stdout and END_REQUEST validation" {
    const a = std.testing.allocator;
    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(a);
    try record(a, &wire, 6, "hello");
    try record(a, &wire, 6, "");
    try record(a, &wire, 3, &.{ 0, 0, 0, 0, 0, 0, 0, 0 });
    var d: Decoder = .{};
    var out: [16]u8 = undefined;
    var n: usize = 0;
    for (wire.items) |v| {
        const r = try d.feed(&.{v}, out[n..]);
        n += r.produced;
    }
    try std.testing.expect(d.done);
    try std.testing.expectEqualStrings("hello", out[0..n]);
}
