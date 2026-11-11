//! Automatic HTTP-01 / DNS-01 certificate lifecycle using mise-pinned lego v5.
//! Account keys and renewal policy remain owned by the established ACME client.
const std = @import("std");
const c = std.c;
pub const Challenge = enum { @"http-01", @"dns-01" };
pub const Settings = struct {
    name: []const u8 = "",
    dns_env_file: ?[]const u8 = null,
    domain: []const u8 = "", // Legacy alias; normalized to domains[0].
    domains: []const []const u8 = &.{},
    cert_name: []const u8 = "",
    challenge: Challenge = .@"http-01",
    dns_provider: []const u8 = "",
    dns_resolvers: []const []const u8 = &.{},
    dns_propagation_wait_seconds: u32 = 0,
    operation_timeout_seconds: u32 = 600,
    email: []const u8 = "",
    directory: []const u8 = "https://acme-v02.api.letsencrypt.org/directory",
    storage: []const u8 = ".acme",
    client: []const u8 = "lego",
    accept_terms: bool = false,
    http_port: u16 = 80,
    renew_before_days: u16 = 30,
    check_interval_seconds: u32 = 43200,
    certificate: []const u8 = "",
    key: []const u8 = "",
};
pub fn validDomain(domain: []const u8) bool {
    if (domain.len == 0 or domain.len > 253) return false;
    var labels = std.mem.splitScalar(u8, domain, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return true;
}
extern "c" fn execvp([*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn signal(c_int, ?*const anyopaque) ?*const anyopaque;
pub fn start(a: std.mem.Allocator, settings: Settings, error_fd: c_int) !c.pid_t {
    if (settings.dns_env_file) |path| if (fingerprint(path) == null) return error.InvalidEnvironmentFile;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var values: std.ArrayList([]const u8) = .empty;
    try values.appendSlice(alloc, &.{
        settings.client, "--log.format",         "text",         "run",                                                               "--path",            settings.storage,
        "--email",       settings.email,         "--cert.name",  settings.cert_name,                                                  "--server",          settings.directory,
        "--accept-tos",  "--force-cert-domains", "--renew-days", try std.fmt.allocPrint(alloc, "{d}", .{settings.renew_before_days}), "--no-random-sleep", "--http-timeout",
        "30",
    });
    if (settings.dns_env_file) |path| try values.appendSlice(alloc, &.{ "--env-file", path });
    for (settings.domains) |domain| try values.appendSlice(alloc, &.{ "--domains", domain });
    switch (settings.challenge) {
        .@"http-01" => try values.appendSlice(alloc, &.{ "--http", "--http.address", try std.fmt.allocPrint(alloc, ":{d}", .{settings.http_port}) }),
        .@"dns-01" => {
            try values.appendSlice(alloc, &.{ "--dns", settings.dns_provider });
            for (settings.dns_resolvers) |resolver| try values.appendSlice(alloc, &.{ "--dns.resolvers", resolver });
            if (settings.dns_propagation_wait_seconds > 0) try values.appendSlice(alloc, &.{ "--dns.propagation.wait", try std.fmt.allocPrint(alloc, "{d}s", .{settings.dns_propagation_wait_seconds}) });
        },
    }
    const argv = try alloc.allocSentinel(?[*:0]const u8, values.items.len, null);
    for (values.items, 0..) |v, i| argv[i] = try alloc.dupeSentinel(u8, v, 0);
    const pid = c.fork();
    if (pid < 0) return error.Fork;
    if (pid == 0) {
        // Do not inherit the master's signal handler during certificate issuance.
        _ = signal(15, null);
        _ = signal(2, null);
        _ = signal(1, null);
        if (error_fd > 2) {
            _ = c.dup2(error_fd, 2);
            _ = c.dup2(error_fd, 1);
        }
        _ = execvp(argv[0].?, argv.ptr);
        c.exit(127);
    }
    return pid;
}
pub fn fingerprint(path: []const u8) ?[32]u8 {
    var name: [4096]u8 = undefined;
    if (path.len >= name.len) return null;
    @memcpy(name[0..path.len], path);
    name[path.len] = 0;
    const fd = c.open(name[0..path.len :0].ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [4096]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = c.read(fd, &bytes, bytes.len);
        if (n < 0) return null;
        if (n == 0) break;
        total += @intCast(n);
        if (total > 1024 * 1024) return null;
        hash.update(bytes[0..@intCast(n)]);
    }
    if (total == 0) return null;
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}
pub fn ready(settings: Settings) bool {
    return fingerprint(settings.certificate) != null and fingerprint(settings.key) != null;
}
test "HTTP-01 domain validation rejects wildcard and paths" {
    try std.testing.expect(validDomain("www.example.com"));
    for ([_][]const u8{ "*.example.com", "../cert", "x..test", "-bad.test", "x/evil" }) |value| try std.testing.expect(!validDomain(value));
}

/// RFC 6125 wildcard scope: one label, never the apex or a nested subdomain.
/// A wildcard virtual host requires the same wildcard certificate identifier.
pub fn covers(domains: []const []const u8, host: []const u8) bool {
    return matchRank(domains, host) != 0;
}
/// Exact SANs outrank wildcard coverage, regardless of configuration order.
pub fn matchRank(domains: []const []const u8, host: []const u8) u8 {
    var rank: u8 = 0;
    for (domains) |domain| {
        if (std.ascii.eqlIgnoreCase(domain, host)) return 2;
        if (!std.mem.startsWith(u8, domain, "*.")) continue;
        if (std.mem.indexOfScalar(u8, host, '*') != null) continue;
        const dot = std.mem.indexOfScalar(u8, host, '.') orelse continue;
        if (dot > 0 and std.ascii.eqlIgnoreCase(host[dot + 1 ..], domain[2..])) rank = 1;
    }
    return rank;
}
test "certificate names and wildcard coverage" {
    const domains = &.{ "example.com", "*.example.com", "other.test" };
    for ([_][]const u8{ "example.com", "WWW.Example.com", "*.example.com", "other.test" }) |host| try std.testing.expect(covers(domains, host));
    for ([_][]const u8{ "a.b.example.com", "*.sub.example.com", "evil-example.com", "example.net", ".example.com" }) |host| try std.testing.expect(!covers(domains, host));
    try std.testing.expect(!covers(&.{"*.example.com"}, "example.com"));
}

/// Per-certificate deadlines survive TLS reloads. Only one issuer runs at once,
/// avoiding HTTP-01 port and shared account-store conflicts.
pub const Renewal = struct { settings: Settings, next_check_ms: i64 = 0 };
pub fn renewals(a: std.mem.Allocator, certificates: []const Settings, previous: []const Renewal) ![]Renewal {
    const result = try a.alloc(Renewal, certificates.len);
    for (certificates, result) |certificate, *job| {
        job.* = .{ .settings = certificate };
        for (previous) |old| if (std.mem.eql(u8, old.settings.certificate, certificate.certificate)) {
            job.next_check_ms = old.next_check_ms;
            break;
        };
    }
    return result;
}

test "renewal deadlines follow certificate paths across reordering and removal" {
    const t = std.testing;
    const a: Settings = .{ .name = "a", .certificate = "/a.crt" };
    const b: Settings = .{ .name = "b", .certificate = "/b.crt" };
    const next = try renewals(t.allocator, &.{ b, a, .{ .certificate = "/c.crt" } }, &.{
        .{ .settings = a, .next_check_ms = 123 },
        .{ .settings = b, .next_check_ms = 456 },
        .{ .settings = .{ .certificate = "/removed.crt" }, .next_check_ms = 789 },
    });
    defer t.allocator.free(next);
    try t.expectEqual(@as(i64, 456), next[0].next_check_ms);
    try t.expectEqual(@as(i64, 123), next[1].next_check_ms);
    try t.expectEqual(@as(i64, 0), next[2].next_check_ms);
    try t.expectEqual(@as(u8, 2), matchRank(&.{ "*.example.com", "api.example.com" }, "api.example.com"));
    try t.expectEqual(@as(u8, 1), matchRank(&.{"*.example.com"}, "api.example.com"));
}
