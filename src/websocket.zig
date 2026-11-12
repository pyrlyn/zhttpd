//! RFC 6455 server framing and callback API. No HTTP/configuration dependency.
const std = @import("std");
pub const max_message = 64 * 1024;
pub const Callbacks = struct {
    context: ?*anyopaque = null,
    on_message: ?*const fn (?*anyopaque, *Peer, []const u8, bool) void = null,
};
pub const Peer = struct {
    session: *Session,
    pub fn send(p: *Peer, data: []const u8, binary: bool) !void {
        try p.session.queue(if (binary) 2 else 1, data);
    }
    pub fn close(p: *Peer, code: u16) void {
        p.session.close(code);
    }
};
pub fn acceptKey(key: []const u8, out: *[28]u8) !void {
    if (key.len != 24) return error.InvalidKey;
    var decoded: [16]u8 = undefined;
    const size = std.base64.standard.Decoder.calcSizeForSlice(key) catch return error.InvalidKey;
    if (size != 16) return error.InvalidKey;
    std.base64.standard.Decoder.decode(&decoded, key) catch return error.InvalidKey;
    var input: [60]u8 = undefined;
    @memcpy(input[0..24], key);
    @memcpy(input[24..], "258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&input, &digest, .{});
    _ = std.base64.standard.Encoder.encode(out, &digest);
}
pub const Session = struct {
    a: std.mem.Allocator,
    callbacks: Callbacks,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    fragment: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    fragmented: u8 = 0,
    closing: bool = false,

    pub fn deinit(s: *Session) void {
        s.input.deinit(s.a);
        s.output.deinit(s.a);
        s.fragment.deinit(s.a);
    }
    pub fn queue(s: *Session, opcode: u8, data: []const u8) !void {
        if (data.len > max_message or s.output.items.len + data.len + 10 > max_message * 2) return error.MessageTooLarge;
        try s.output.append(s.a, 0x80 | opcode);
        if (data.len < 126) try s.output.append(s.a, @intCast(data.len)) else if (data.len <= 65535) {
            try s.output.appendSlice(s.a, &.{ 126, @intCast(data.len >> 8), @truncate(data.len) });
        } else {
            try s.output.appendSlice(s.a, &.{ 127, 0, 0, 0, 0, 0, 1, 0, 0 });
        }
        try s.output.appendSlice(s.a, data);
    }
    pub fn close(s: *Session, code: u16) void {
        if (s.closing) return;
        s.queue(8, &.{ @intCast(code >> 8), @truncate(code) }) catch {};
        s.closing = true;
    }
    fn message(s: *Session, opcode: u8, data: []const u8) !void {
        if (opcode == 1 and !std.unicode.utf8ValidateSlice(data)) return error.InvalidUtf8;
        var peer: Peer = .{ .session = s };
        if (s.callbacks.on_message) |callback| callback(s.callbacks.context, &peer, data, opcode == 2) else try peer.send(data, opcode == 2);
    }
    pub fn feed(s: *Session, data: []const u8) !void {
        if (s.closing) return;
        if (s.input.items.len + data.len > max_message + 16384) return error.MessageTooLarge;
        try s.input.appendSlice(s.a, data);
        var used: usize = 0;
        while (!s.closing) {
            const bytes = s.input.items[used..];
            if (bytes.len < 2) break;
            const fin = bytes[0] & 0x80 != 0;
            const opcode = bytes[0] & 15;
            if (bytes[0] & 0x70 != 0 or bytes[1] & 0x80 == 0) return error.Protocol;
            if (!(opcode == 0 or opcode == 1 or opcode == 2 or opcode == 8 or opcode == 9 or opcode == 10)) return error.Protocol;
            var len: u64 = bytes[1] & 0x7f;
            var header: usize = 2;
            if (len == 126) {
                if (bytes.len < 4) break;
                len = (@as(u64, bytes[2]) << 8) | bytes[3];
                header = 4;
                if (len < 126) return error.Protocol;
            } else if (len == 127) {
                if (bytes.len < 10) break;
                if (bytes[2] & 0x80 != 0) return error.Protocol;
                len = 0;
                for (bytes[2..10]) |v| len = (len << 8) | v;
                header = 10;
                if (len <= 65535) return error.Protocol;
            }
            if (opcode >= 8 and (!fin or len > 125)) return error.Protocol;
            if (len > max_message) return error.MessageTooLarge;
            const n: usize = @intCast(len);
            if (bytes.len < header + 4 + n) break;
            const mask = bytes[header..][0..4].*;
            const payload = bytes[header + 4 ..][0..n];
            for (payload, 0..) |*v, i| v.* ^= mask[i % 4];
            switch (opcode) {
                8 => {
                    if (n == 1) return error.Protocol;
                    if (n >= 2) {
                        const code = (@as(u16, payload[0]) << 8) | payload[1];
                        if (!validClose(code)) return error.Protocol;
                        if (!std.unicode.utf8ValidateSlice(payload[2..])) return error.InvalidUtf8;
                    }
                    try s.queue(8, payload);
                    s.closing = true;
                },
                9 => try s.queue(10, payload),
                10 => {},
                0 => {
                    if (s.fragmented == 0) return error.Protocol;
                    if (s.fragment.items.len + n > max_message) return error.MessageTooLarge;
                    try s.fragment.appendSlice(s.a, payload);
                    if (fin) {
                        try s.message(s.fragmented, s.fragment.items);
                        s.fragmented = 0;
                        s.fragment.clearRetainingCapacity();
                    }
                },
                1, 2 => {
                    if (s.fragmented != 0) return error.Protocol;
                    if (fin) try s.message(opcode, payload) else {
                        s.fragmented = opcode;
                        try s.fragment.appendSlice(s.a, payload);
                    }
                },
                else => unreachable,
            }
            used += header + 4 + n;
        }
        if (used > 0) {
            std.mem.copyForwards(u8, s.input.items[0 .. s.input.items.len - used], s.input.items[used..]);
            s.input.items.len -= used;
        }
    }
};
fn validClose(code: u16) bool {
    return (code >= 1000 and code <= 1014 and code != 1004 and code != 1005 and code != 1006) or (code >= 3000 and code <= 4999);
}

test "RFC 6455 handshake example" {
    var accept: [28]u8 = undefined;
    try acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &accept);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
    try std.testing.expectError(error.InvalidKey, acceptKey("bad", &accept));
}
test "client masks are mandatory" {
    var s: Session = .{ .a = std.testing.allocator, .callbacks = .{} };
    defer s.deinit();
    try std.testing.expectError(error.Protocol, s.feed(&.{ 0x81, 1, 'x' }));
}
