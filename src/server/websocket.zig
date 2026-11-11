//! HTTP/1.1 Upgrade adapter for the reusable WebSocket module.
const std = @import("std");
const ws = @import("websocket");
const Conn = @import("conn.zig").Conn;
const handler = @import("handler.zig");

fn token(value: []const u8, wanted: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, value, ", \t");
    while (it.next()) |v| if (std.ascii.eqlIgnoreCase(v, wanted)) return true;
    return false;
}
pub fn upgrade(c: *Conn, callbacks: ws.Callbacks) void {
    const r = &c.req;
    if (c.stream_protocol != 0 or r.method != .GET or r.version != .http11 or r.chunked or (r.content_length orelse 0) != 0 or
        !token(r.header("connection") orelse "", "upgrade") or !std.ascii.eqlIgnoreCase(r.header("upgrade") orelse "", "websocket")) return handler.finalize(c, 400);
    if (!std.mem.eql(u8, r.header("sec-websocket-version") orelse "", "13")) return handler.finalize(c, 400);
    var accept: [28]u8 = undefined;
    ws.acceptKey(r.header("sec-websocket-key") orelse "", &accept) catch return handler.finalize(c, 400);
    const session = c.w.gpa.create(ws.Session) catch return handler.finalize(c, 500);
    session.* = .{ .a = c.w.gpa, .callbacks = callbacks };
    const reply = std.fmt.allocPrint(c.w.gpa, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch {
        c.w.gpa.destroy(session);
        return handler.finalize(c, 500);
    };
    defer c.w.gpa.free(reply);
    session.output.appendSlice(c.w.gpa, reply) catch {
        session.deinit();
        c.w.gpa.destroy(session);
        return handler.finalize(c, 500);
    };
    c.websocket = session;
    c.state = .websocket;
    c.ctx.status = 101;
    c.keep_alive = false;
    c.deadline = c.w.now_ms + c.ctx.conf.keepalive_timeout_ms;
    feed(c, c.rbuf[r.head_len..c.rlen]);
}
fn feed(c: *Conn, bytes: []const u8) void {
    c.websocket.?.feed(bytes) catch |err| c.websocket.?.close(switch (err) {
        error.InvalidUtf8 => 1007,
        error.MessageTooLarge => 1009,
        else => 1002,
    });
}
pub fn drive(c: *Conn) void {
    const s = c.websocket.?;
    while (true) {
        while (s.sent < s.output.items.len) switch (c.sendRaw(s.output.items[s.sent..])) {
            .ok => |n| {
                s.sent += n;
                c.ctx.bytes_sent += n;
            },
            .again => return,
            else => {
                c.finishRequest();
                return;
            },
        };
        s.output.clearRetainingCapacity();
        s.sent = 0;
        if (s.closing) {
            c.finishRequest();
            return;
        }
        switch (c.recv(&c.rbuf)) {
            .ok => |n| {
                c.deadline = c.w.now_ms + c.ctx.conf.keepalive_timeout_ms;
                feed(c, c.rbuf[0..n]);
            },
            .again => return,
            else => {
                c.finishRequest();
                return;
            },
        }
    }
}
