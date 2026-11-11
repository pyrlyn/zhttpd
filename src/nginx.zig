//! nginx.conf adapter: syntax, includes, validation, inheritance and lowering
//! into http.config.Config. Dependency direction: nginx -> http.
const std = @import("std");
pub const parser = @import("nginx/parser.zig");
pub const directives = @import("nginx/directives.zig");
pub const expr = @import("nginx/expr.zig");
pub const config = @import("nginx/config.zig");
pub const diag = @import("http").diag;
pub const addr = @import("http").addr;

pub const load = config.load;
pub const loadString = config.loadString;
pub const destroy = config.destroy;

test {
    std.testing.refAllDecls(@This());
    _ = @import("nginx/router_test.zig");
}
