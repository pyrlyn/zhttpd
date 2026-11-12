const std = @import("std");
const ws = @import("websocket_sdk");
extern "c" fn signal(c_int, ?*const anyopaque) ?*const anyopaque;
fn stop(_: c_int) callconv(.c) void {
    ws.stop();
}
fn echo(_: ?*anyopaque, peer: *ws.Peer, data: []const u8, binary: bool) void {
    peer.send(data, binary) catch peer.close(1011);
}
pub fn main(init: std.process.Init) !void {
    _ = signal(2, @ptrCast(&stop));
    _ = signal(15, @ptrCast(&stop));
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    try ws.serve(if (args.len > 1) args[1] else "127.0.0.1:8080", .{ .on_message = echo });
}
