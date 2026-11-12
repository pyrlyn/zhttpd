const std = @import("std");
const sdk = @import("websocket_sdk");
const Callback = *const fn (?*anyopaque, *sdk.Peer, [*]const u8, usize, c_int) callconv(.c) void;
const CCallbacks = extern struct { context: ?*anyopaque, on_message: ?Callback };
fn message(context: ?*anyopaque, peer: *sdk.Peer, bytes: []const u8, binary: bool) void {
    const callbacks: *const CCallbacks = @ptrCast(@alignCast(context.?));
    if (callbacks.on_message) |cb| cb(callbacks.context, peer, bytes.ptr, bytes.len, @intFromBool(binary));
}
export fn zws_server_run(address: ?[*:0]const u8, callbacks: ?*const CCallbacks) c_int {
    const target = address orelse return -1;
    var copied = if (callbacks) |c| c.* else CCallbacks{ .context = null, .on_message = null };
    sdk.serve(std.mem.span(target), if (copied.on_message == null) .{} else .{ .context = &copied, .on_message = message }) catch return -1;
    return 0;
}
export fn zws_send(peer: ?*sdk.Peer, data: ?[*]const u8, size: usize, binary: c_int) c_int {
    const p = peer orelse return -1;
    if (size > sdk.protocol.max_message or (data == null and size != 0)) return -1;
    p.send(if (data) |d| d[0..size] else "", binary != 0) catch return -1;
    return 0;
}
export fn zws_close(peer: ?*sdk.Peer, code: u16) void {
    if (peer) |p| p.close(code);
}
export fn zws_stop() void {
    sdk.stop();
}
