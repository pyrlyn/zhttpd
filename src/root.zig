//! Compatibility facade. The http and nginx modules are independently importable.
const std = @import("std");
pub const http = @import("http");
pub const nginx = @import("nginx");
pub const apache = @import("apache");
pub const litespeed = @import("litespeed");
pub const caddy = @import("caddy");
pub const settings = @import("settings");
pub const logging = http.logging;
pub const websocket = http.websocket;
pub const fastcgi = http.fastcgi;
pub const load_balancer = http.load_balancer;
pub const acme = http.acme;
pub const app_config = @import("app_config.zig");
// Existing consumers can keep these names while adopting http/nginx imports.
pub const conf = nginx;
pub const server = http.server;
pub const os = http.os;
pub const regex = http.regex;

test {
    std.testing.refAllDecls(@This());
    _ = @import("realworld_test.zig");
}
