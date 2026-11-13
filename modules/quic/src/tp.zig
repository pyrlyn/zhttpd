//! Transport parameters (RFC 9000 §18).
const std = @import("std");
const wire = @import("wire.zig");
const Cid = @import("packet.zig").Cid;

pub const Params = struct {
    original_dcid: ?Cid = null,
    max_idle_timeout_ms: u64 = 0,
    stateless_reset_token: ?[16]u8 = null,
    max_udp_payload_size: u64 = 65527,
    initial_max_data: u64 = 0,
    initial_max_stream_data_bidi_local: u64 = 0,
    initial_max_stream_data_bidi_remote: u64 = 0,
    initial_max_stream_data_uni: u64 = 0,
    initial_max_streams_bidi: u64 = 0,
    initial_max_streams_uni: u64 = 0,
    ack_delay_exponent: u64 = 3,
    max_ack_delay_ms: u64 = 25,
    disable_active_migration: bool = false,
    active_connection_id_limit: u64 = 2,
    initial_scid: ?Cid = null,
    retry_scid: ?Cid = null,
};

pub const Error = error{TransportParameter};

const Id = enum(u64) {
    original_dcid = 0x00,
    max_idle_timeout = 0x01,
    stateless_reset_token = 0x02,
    max_udp_payload_size = 0x03,
    initial_max_data = 0x04,
    initial_max_stream_data_bidi_local = 0x05,
    initial_max_stream_data_bidi_remote = 0x06,
    initial_max_stream_data_uni = 0x07,
    initial_max_streams_bidi = 0x08,
    initial_max_streams_uni = 0x09,
    ack_delay_exponent = 0x0a,
    max_ack_delay = 0x0b,
    disable_active_migration = 0x0c,
    preferred_address = 0x0d,
    active_connection_id_limit = 0x0e,
    initial_scid = 0x0f,
    retry_scid = 0x10,
    _,
};

fn putInt(w: *wire.Writer, id: Id, v: u64) void {
    w.varint(@intFromEnum(id));
    w.varint(wire.varintLen(v));
    w.varint(v);
}
fn putBytes(w: *wire.Writer, id: Id, b: []const u8) void {
    w.varint(@intFromEnum(id));
    w.varint(b.len);
    w.bytes(b);
}

/// Server-side encoding. `out` must hold at least 256 bytes.
pub fn encode(p: *const Params, out: []u8) usize {
    var w = wire.Writer{ .buf = out };
    if (p.original_dcid) |c| putBytes(&w, .original_dcid, c.slice());
    if (p.max_idle_timeout_ms != 0) putInt(&w, .max_idle_timeout, p.max_idle_timeout_ms);
    if (p.stateless_reset_token) |t| putBytes(&w, .stateless_reset_token, &t);
    if (p.max_udp_payload_size != 65527) putInt(&w, .max_udp_payload_size, p.max_udp_payload_size);
    putInt(&w, .initial_max_data, p.initial_max_data);
    putInt(&w, .initial_max_stream_data_bidi_local, p.initial_max_stream_data_bidi_local);
    putInt(&w, .initial_max_stream_data_bidi_remote, p.initial_max_stream_data_bidi_remote);
    putInt(&w, .initial_max_stream_data_uni, p.initial_max_stream_data_uni);
    putInt(&w, .initial_max_streams_bidi, p.initial_max_streams_bidi);
    putInt(&w, .initial_max_streams_uni, p.initial_max_streams_uni);
    if (p.ack_delay_exponent != 3) putInt(&w, .ack_delay_exponent, p.ack_delay_exponent);
    if (p.max_ack_delay_ms != 25) putInt(&w, .max_ack_delay, p.max_ack_delay_ms);
    if (p.disable_active_migration) {
        w.varint(@intFromEnum(Id.disable_active_migration));
        w.varint(0);
    }
    if (p.active_connection_id_limit != 2) putInt(&w, .active_connection_id_limit, p.active_connection_id_limit);
    if (p.initial_scid) |c| putBytes(&w, .initial_scid, c.slice());
    if (p.retry_scid) |c| putBytes(&w, .retry_scid, c.slice());
    // A reserved parameter (RFC 9000 §18.1) keeps clients tolerant of unknown IDs.
    putBytes(&w, @enumFromInt(31 * 7 + 27), &.{});
    return w.pos;
}

/// Decodes a client's parameters, enforcing the §18.2 constraints.
pub fn decodeClient(buf: []const u8) Error!Params {
    var p = Params{};
    var seen: u32 = 0;
    var r = wire.Reader{ .buf = buf };
    while (!r.done()) {
        const raw = r.varint() catch return error.TransportParameter;
        const len = r.varint() catch return error.TransportParameter;
        const val = r.bytes(len) catch return error.TransportParameter;
        if (raw <= 0x10) {
            const bit = @as(u32, 1) << @intCast(raw);
            if (seen & bit != 0) return error.TransportParameter;
            seen |= bit;
        }
        const id: Id = @enumFromInt(raw);
        switch (id) {
            .original_dcid, .stateless_reset_token, .preferred_address, .retry_scid => return error.TransportParameter,
            .initial_scid => {
                if (val.len > 20) return error.TransportParameter;
                p.initial_scid = Cid.init(val);
            },
            .disable_active_migration => {
                if (val.len != 0) return error.TransportParameter;
                p.disable_active_migration = true;
            },
            .max_idle_timeout, .max_udp_payload_size, .initial_max_data, .initial_max_stream_data_bidi_local, .initial_max_stream_data_bidi_remote, .initial_max_stream_data_uni, .initial_max_streams_bidi, .initial_max_streams_uni, .ack_delay_exponent, .max_ack_delay, .active_connection_id_limit => {
                var vr = wire.Reader{ .buf = val };
                const v = vr.varint() catch return error.TransportParameter;
                if (!vr.done()) return error.TransportParameter;
                switch (id) {
                    .max_idle_timeout => p.max_idle_timeout_ms = v,
                    .max_udp_payload_size => {
                        if (v < 1200) return error.TransportParameter;
                        p.max_udp_payload_size = v;
                    },
                    .initial_max_data => p.initial_max_data = v,
                    .initial_max_stream_data_bidi_local => p.initial_max_stream_data_bidi_local = v,
                    .initial_max_stream_data_bidi_remote => p.initial_max_stream_data_bidi_remote = v,
                    .initial_max_stream_data_uni => p.initial_max_stream_data_uni = v,
                    .initial_max_streams_bidi => {
                        if (v > 1 << 60) return error.TransportParameter;
                        p.initial_max_streams_bidi = v;
                    },
                    .initial_max_streams_uni => {
                        if (v > 1 << 60) return error.TransportParameter;
                        p.initial_max_streams_uni = v;
                    },
                    .ack_delay_exponent => {
                        if (v > 20) return error.TransportParameter;
                        p.ack_delay_exponent = v;
                    },
                    .max_ack_delay => {
                        if (v >= 1 << 14) return error.TransportParameter;
                        p.max_ack_delay_ms = v;
                    },
                    .active_connection_id_limit => {
                        if (v < 2) return error.TransportParameter;
                        p.active_connection_id_limit = v;
                    },
                    else => unreachable,
                }
            },
            _ => {},
        }
    }
    if (p.initial_scid == null) return error.TransportParameter;
    return p;
}

test "transport parameters round trip and validation" {
    var out: [256]u8 = undefined;
    const sp = Params{ .initial_max_data = 1 << 20, .initial_max_streams_bidi = 100, .initial_scid = Cid.init("abcd"), .original_dcid = Cid.init("12345678") };
    const n = encode(&sp, &out);
    // A server encoding is rejected as client parameters (original_dcid).
    try std.testing.expectError(error.TransportParameter, decodeClient(out[0..n]));
    const cp = Params{ .initial_max_data = 1000, .initial_max_stream_data_bidi_local = 77, .initial_scid = Cid.init("xy"), .max_ack_delay_ms = 10 };
    const m = encode(&cp, &out);
    const d = try decodeClient(out[0..m]);
    try std.testing.expectEqual(@as(u64, 1000), d.initial_max_data);
    try std.testing.expectEqual(@as(u64, 77), d.initial_max_stream_data_bidi_local);
    try std.testing.expectEqual(@as(u64, 10), d.max_ack_delay_ms);
    try std.testing.expect(d.initial_scid.?.eql("xy"));
    // Duplicate parameter.
    var dup: [16]u8 = undefined;
    var w = wire.Writer{ .buf = &dup };
    putInt(&w, .initial_max_data, 1);
    putInt(&w, .initial_max_data, 2);
    try std.testing.expectError(error.TransportParameter, decodeClient(dup[0..w.pos]));
}
