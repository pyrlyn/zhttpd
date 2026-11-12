//! Socket addresses for `listen`, `proxy_pass`, `allow`/`deny`.
const std = @import("std");

pub const Addr = struct {
    family: enum(u8) { v4, v6 } = .v4,
    ip: [16]u8 = @splat(0),
    port: u16 = 0,

    pub fn isWildcard(a: Addr) bool {
        return std.mem.allEqual(u8, a.ip[0..if (a.family == .v4) 4 else 16], 0);
    }
    pub fn eql(a: Addr, b: Addr) bool {
        return a.family == b.family and a.port == b.port and std.mem.eql(u8, &a.ip, &b.ip);
    }
    pub fn sameHost(a: Addr, b: Addr) bool {
        return a.family == b.family and std.mem.eql(u8, &a.ip, &b.ip);
    }

    /// Text form without port: `127.0.0.1` / `::1`.
    pub fn formatIp(a: Addr, buf: []u8) []const u8 {
        if (a.family == .v4) return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a.ip[0], a.ip[1], a.ip[2], a.ip[3] }) catch "?";
        // RFC 5952-ish: compress the longest zero run.
        var words: [8]u16 = undefined;
        for (0..8) |i| words[i] = (@as(u16, a.ip[2 * i]) << 8) | a.ip[2 * i + 1];
        var best_s: usize = 8;
        var best_l: usize = 0;
        var i: usize = 0;
        while (i < 8) {
            if (words[i] != 0) {
                i += 1;
                continue;
            }
            const s = i;
            while (i < 8 and words[i] == 0) i += 1;
            if (i - s > best_l and i - s > 1) {
                best_s = s;
                best_l = i - s;
            }
        }
        var w: std.Io.Writer = .fixed(buf);
        i = 0;
        while (i < 8) {
            if (i == best_s) {
                w.writeAll("::") catch return "?";
                i += best_l;
                continue;
            }
            if (i > 0 and i != best_s + best_l) w.writeByte(':') catch return "?";
            w.print("{x}", .{words[i]}) catch return "?";
            i += 1;
        }
        return w.buffered();
    }
};

pub fn parseIp4(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |part| {
        if (n == 4 or part.len == 0 or part.len > 3) return null;
        out[n] = std.fmt.parseInt(u8, part, 10) catch return null;
        n += 1;
    }
    return if (n == 4) out else null;
}

pub fn parseIp6(s: []const u8) ?[16]u8 {
    var out: [16]u8 = @splat(0);
    var head: [8]u16 = undefined;
    var tail: [8]u16 = undefined;
    var nh: usize = 0;
    var nt: usize = 0;
    var seen_gap = false;
    const gap = std.mem.indexOf(u8, s, "::");
    const parse = struct {
        fn f(part: []const u8, dst: *[8]u16, n: *usize) bool {
            if (part.len == 0) return true;
            var it = std.mem.splitScalar(u8, part, ':');
            while (it.next()) |g| {
                if (n.* == 8 or g.len == 0 or g.len > 4) return false;
                dst[n.*] = std.fmt.parseInt(u16, g, 16) catch return false;
                n.* += 1;
            }
            return true;
        }
    }.f;
    if (gap) |g| {
        seen_gap = true;
        if (!parse(s[0..g], &head, &nh)) return null;
        if (!parse(s[g + 2 ..], &tail, &nt)) return null;
        if (nh + nt > 7) return null;
    } else {
        if (!parse(s, &head, &nh)) return null;
        if (nh != 8) return null;
    }
    for (0..nh) |i| {
        out[2 * i] = @intCast(head[i] >> 8);
        out[2 * i + 1] = @truncate(head[i]);
    }
    for (0..nt) |i| {
        const k = 8 - nt + i;
        out[2 * k] = @intCast(tail[i] >> 8);
        out[2 * k + 1] = @truncate(tail[i]);
    }
    return out;
}

/// Parse a `listen`/`proxy_pass` host:port. `default_port` is used when absent.
/// Accepts `80`, `*:80`, `1.2.3.4`, `1.2.3.4:80`, `[::]:80`, `[::1]`, `localhost:80`.
/// Hostnames other than `localhost` are resolved by the caller via getaddrinfo (returns null here).
pub fn parseHostPort(s: []const u8, default_port: u16) ?struct { addr: Addr, host: []const u8 } {
    var a: Addr = .{ .port = default_port };
    if (s.len > 0 and s[0] == '[') {
        const end = std.mem.indexOfScalar(u8, s, ']') orelse return null;
        a.family = .v6;
        a.ip = parseIp6(s[1..end]) orelse return null;
        if (end + 1 < s.len) {
            if (s[end + 1] != ':') return null;
            a.port = std.fmt.parseInt(u16, s[end + 2 ..], 10) catch return null;
        }
        return .{ .addr = a, .host = s[0 .. end + 1] };
    }
    // bare port
    if (std.fmt.parseInt(u16, s, 10)) |p| {
        a.port = p;
        return .{ .addr = a, .host = "*" };
    } else |_| {}
    var host = s;
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |c| {
        a.port = std.fmt.parseInt(u16, s[c + 1 ..], 10) catch return null;
        host = s[0..c];
    }
    if (std.mem.eql(u8, host, "*")) return .{ .addr = a, .host = host };
    if (std.mem.eql(u8, host, "localhost")) {
        a.ip[0..4].* = .{ 127, 0, 0, 1 };
        return .{ .addr = a, .host = host };
    }
    if (parseIp4(host)) |ip| {
        a.ip[0..4].* = ip;
        return .{ .addr = a, .host = host };
    }
    return null;
}

pub const Cidr = struct {
    addr: Addr,
    bits: u8,

    pub fn parse(s: []const u8) ?Cidr {
        var ip = s;
        var bits: ?u8 = null;
        if (std.mem.indexOfScalar(u8, s, '/')) |sl| {
            ip = s[0..sl];
            bits = std.fmt.parseInt(u8, s[sl + 1 ..], 10) catch return null;
        }
        var a: Addr = .{};
        if (parseIp4(ip)) |v4| {
            a.ip[0..4].* = v4;
            const b = bits orelse 32;
            if (b > 32) return null;
            return .{ .addr = a, .bits = b };
        }
        a.family = .v6;
        a.ip = parseIp6(ip) orelse return null;
        const b = bits orelse 128;
        if (b > 128) return null;
        return .{ .addr = a, .bits = b };
    }

    pub fn contains(c: Cidr, a: Addr) bool {
        var ip = a.ip;
        var fam = a.family;
        // IPv4-mapped IPv6 (::ffff:a.b.c.d) vs IPv4 rules
        if (fam == .v6 and c.addr.family == .v4 and std.mem.allEqual(u8, ip[0..10], 0) and ip[10] == 0xff and ip[11] == 0xff) {
            const v4 = ip[12..16].*;
            ip = @splat(0);
            ip[0..4].* = v4;
            fam = .v4;
        }
        if (fam != c.addr.family) return false;
        var bits: usize = c.bits;
        var i: usize = 0;
        while (bits >= 8) : (i += 1) {
            if (ip[i] != c.addr.ip[i]) return false;
            bits -= 8;
        }
        if (bits == 0) return true;
        const mask: u8 = @truncate(@as(u16, 0xff00) >> @intCast(bits));
        return (ip[i] & mask) == (c.addr.ip[i] & mask);
    }
};

test "addr parsing" {
    const t = std.testing;
    try t.expectEqual(@as(u16, 8080), parseHostPort("127.0.0.1:8080", 80).?.addr.port);
    try t.expect(parseHostPort("[::]:80", 80).?.addr.isWildcard());
    try t.expect(parseHostPort("80", 0).?.addr.isWildcard());
    try t.expect(parseHostPort("example.com:80", 80) == null);
    const c = Cidr.parse("10.0.0.0/8").?;
    try t.expect(c.contains(parseHostPort("10.1.2.3", 0).?.addr));
    try t.expect(!c.contains(parseHostPort("11.1.2.3", 0).?.addr));
    const c6 = Cidr.parse("2001:db8::/32").?;
    var a: Addr = .{ .family = .v6, .ip = parseIp6("2001:db8:1::5").? };
    try t.expect(c6.contains(a));
    a.ip = parseIp6("::1").?;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("::1", a.formatIp(&buf));
}
