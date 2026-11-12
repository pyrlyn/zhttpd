//! JWT HS256 verification. No algorithm negotiation; exp, issuer and audience required.
const std = @import("std");
pub const Policy = struct { secret: []const u8, issuer: []const u8, audience: []const u8, scope: []const u8 = "" };
pub const Identity = struct { subject: []const u8, scope: []const u8 };
fn decode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const bytes = try a.alloc(u8, decoder.calcSizeForSlice(s) catch return error.Unauthorized);
    decoder.decode(bytes, s) catch return error.Unauthorized;
    return bytes;
}
fn string(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const value = v.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}
pub fn verify(a: std.mem.Allocator, token: []const u8, policy: Policy, now: i64) !Identity {
    if (policy.secret.len < 32 or policy.issuer.len == 0 or policy.audience.len == 0) return error.InvalidAuthPolicy;
    if (token.len > 8192) return error.Unauthorized;
    var it = std.mem.splitScalar(u8, token, '.');
    const head = it.next() orelse return error.Unauthorized;
    const payload = it.next() orelse return error.Unauthorized;
    const signature = it.next() orelse return error.Unauthorized;
    if (it.next() != null) return error.Unauthorized;
    const sig = try decode(a, signature);
    if (sig.len != 32) return error.Unauthorized;
    var expected: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, token[0 .. head.len + 1 + payload.len], policy.secret);
    if (!std.crypto.timing_safe.eql([32]u8, expected, sig[0..32].*)) return error.Unauthorized;
    const h = std.json.parseFromSliceLeaky(std.json.Value, a, try decode(a, head), .{}) catch return error.Unauthorized;
    if (!std.mem.eql(u8, string(h, "alg") orelse return error.Unauthorized, "HS256")) return error.Unauthorized;
    if (h.object.contains("crit") or h.object.contains("b64")) return error.Unauthorized;
    const p = std.json.parseFromSliceLeaky(std.json.Value, a, try decode(a, payload), .{}) catch return error.Unauthorized;
    if (p != .object) return error.Unauthorized;
    const exp = p.object.get("exp") orelse return error.Unauthorized;
    if (exp != .integer or exp.integer <= now) return error.Unauthorized;
    if (p.object.get("nbf")) |nbf| if (nbf != .integer or nbf.integer > now) return error.Unauthorized;
    if (!std.mem.eql(u8, string(p, "iss") orelse return error.Unauthorized, policy.issuer)) return error.Unauthorized;
    const aud = p.object.get("aud") orelse return error.Unauthorized;
    var matched = false;
    if (aud == .string) matched = std.mem.eql(u8, aud.string, policy.audience) else if (aud == .array) {
        for (aud.array.items) |v| if (v == .string and std.mem.eql(u8, v.string, policy.audience)) {
            matched = true;
        };
    }
    if (!matched) return error.Unauthorized;
    const subject = string(p, "sub") orelse return error.Unauthorized;
    if (subject.len == 0) return error.Unauthorized;
    const scope = string(p, "scope") orelse "";
    if (!hasScopes(scope, policy.scope)) return error.Forbidden;
    return .{ .subject = subject, .scope = scope };
}
pub fn hasScopes(granted: []const u8, required: []const u8) bool {
    var wanted = std.mem.tokenizeScalar(u8, required, ' ');
    while (wanted.next()) |want| {
        var actual = std.mem.tokenizeScalar(u8, granted, ' ');
        const found = while (actual.next()) |have| {
            if (std.mem.eql(u8, want, have)) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}
test "scope matching uses complete tokens and requires every scope" {
    try std.testing.expect(hasScopes("read write", "write read"));
    try std.testing.expect(!hasScopes("reader write", "read"));
}
