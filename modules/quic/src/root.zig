//! zquic — QUIC v1 server transport with an HTTP/3 layer.
pub const crypto = @import("crypto.zig");
pub const clock = @import("clock.zig");
pub const wire = @import("wire.zig");
pub const packet = @import("packet.zig");
pub const ranges = @import("ranges.zig");
pub const tp = @import("tp.zig");
pub const recovery = @import("recovery.zig");
pub const stream = @import("stream.zig");
pub const tls = @import("tls.zig");
pub const conn = @import("conn.zig");
pub const endpoint = @import("endpoint.zig");
pub const udp = @import("udp.zig");
pub const qpack = @import("qpack.zig");
pub const h3 = @import("h3.zig");

test {
    _ = crypto;
    _ = wire;
    _ = packet;
    _ = ranges;
    _ = tp;
    _ = recovery;
    _ = stream;
    _ = conn;
    _ = endpoint;
    _ = udp;
    _ = qpack;
    _ = h3;
}

test "analyze all declarations" {
    const std = @import("std");
    std.testing.refAllDecls(conn);
    std.testing.refAllDecls(conn.Conn);
    std.testing.refAllDecls(conn.Stream);
    std.testing.refAllDecls(endpoint);
    std.testing.refAllDecls(endpoint.Endpoint);
    std.testing.refAllDecls(udp);
    std.testing.refAllDecls(udp.Socket);
    std.testing.refAllDecls(h3);
    std.testing.refAllDecls(h3.Request);
    std.testing.refAllDecls(h3.Session);
    std.testing.refAllDecls(h3.Server);
}
