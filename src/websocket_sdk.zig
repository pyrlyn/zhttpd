//! Embeddable single-event-loop WebSocket server. Call stop from a callback or
//! signal handler. One active server per process; peers live only in callbacks.
const std = @import("std");
const http = @import("http");
const support = @import("settings");
pub const protocol = @import("websocket");
pub const Peer = protocol.Peer;
pub const Callbacks = protocol.Callbacks;
const worker = http.server.worker;
var running = false;
pub fn stop() void {
    worker.sig_terminate = true;
}
pub fn serve(address: []const u8, callbacks: Callbacks) !void {
    if (running) return error.AlreadyRunning;
    running = true;
    defer running = false;
    const a = std.heap.c_allocator;
    var diag: http.diag.Diag = .{ .gpa = a };
    defer diag.deinit();
    var b = try support.Builder.init(a, "websocket-sdk", ".", &diag);
    defer support.destroy(a, b.cfg);
    const node: support.Node = .{ .name = "websocket", .args = &.{}, .file = "sdk", .line = 0 };
    const srv = try b.server(node, null);
    srv.conf.websocket = callbacks;
    const addr = try b.address(node, address, 8080);
    try b.listen(srv, addr, false, false);
    var errno: c_int = 0;
    const fd = try http.server.net.listenSocket(addr, 128, false, true, &errno);
    defer http.server.net.close(fd);
    var listeners = [_]worker.Listener{.{ .fd = fd, .listen = &b.cfg.listens[0] }};
    worker.sig_terminate = false;
    worker.sig_quit = false;
    worker.sig_reopen = false;
    var w = try worker.Worker.init(a, b.cfg, &listeners, 2, 0);
    defer w.deinit();
    w.run();
}
