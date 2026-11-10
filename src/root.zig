//! zhttpd library root: everything except the CLI entry point. Tests hang off this file.
const std = @import("std");
pub const os = @import("os.zig");
pub const regex = @import("regex.zig");
pub const conf = struct {
    pub const diag = @import("conf/diag.zig");
    pub const parser = @import("conf/parser.zig");
    pub const directives = @import("conf/directives.zig");
    pub const expr = @import("conf/expr.zig");
    pub const addr = @import("conf/addr.zig");
    pub const config = @import("conf/config.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(conf);
}
pub const server = struct {
    pub const router = @import("server/router.zig");
    pub const loop = @import("server/loop.zig");
    pub const net = @import("server/net.zig");
    pub const tls = @import("server/tls.zig");
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
pub const http = struct {
    pub const request = @import("http/request.zig");
    pub const response = @import("http/response.zig");
};
test {
    std.testing.refAllDecls(http);
}
test {
    _ = @import("realworld_test.zig");
}
