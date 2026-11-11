//! Standalone HTTP runtime: request/response codecs, transports and server.
//! Accepts config.Config from any adapter; does not import the nginx module.
const std = @import("std");
pub const config_watch = @import("config_watch.zig");
pub const os = @import("os.zig");
pub const regex = @import("regex.zig");
pub const diag = @import("http/diag.zig");
pub const addr = @import("http/addr.zig");
pub const expr = @import("expression");
pub const acme = @import("acme");
pub const fastcgi = @import("fastcgi");
pub const logging = @import("logging");
pub const websocket = @import("websocket");
pub const config = @import("http/config.zig");
pub const request = @import("http/request.zig");
pub const response = @import("http/response.zig");

pub const server = struct {
    pub const router = @import("server/router.zig");
    pub const loop = @import("server/loop.zig");
    pub const net = @import("server/net.zig");
    pub const multiplex = @import("server/multiplex.zig");
    pub const tls = @import("server/tls.zig");
    pub const acme_encrypted = @import("server/acme_encrypted.zig");
    pub const vars = @import("server/vars.zig");
    pub const conn = @import("server/conn.zig");
    pub const handler = @import("server/handler.zig");
    pub const proxy = @import("server/proxy.zig");
    pub const worker = @import("server/worker.zig");
    pub const filecache = @import("server/filecache.zig");
};
test {
    std.testing.refAllDecls(server);
}
test {
    std.testing.refAllDecls(@This());
}
