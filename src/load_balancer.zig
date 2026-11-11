//! Independent load-aware redirect policy and asynchronous shared-directory backend.
const std = @import("std");
pub const max_nodes = 32;
pub const marker = "__zhttpd_lb";

pub const Settings = struct {
    enabled: bool = false,
    node_id: []const u8 = "",
    backend: []const u8 = "",
    node_ids: []const []const u8 = &.{},
    node_urls: []const []const u8 = &.{},
    interval_ms: u32 = 1000,
    ttl_ms: u32 = 5000,
    threshold_percent: u32 = 80,
    min_improvement_percent: u32 = 10,
    max_connections: u32 = 0,
    memory_limit_mb: u32 = 0,
    cpu_capacity: u32 = 1,

    pub fn validateWorkers(s: Settings, workers: u32) !void {
        if (s.enabled and workers > 256) return error.TooManyLoadBalancerWorkers;
    }

    pub fn validate(s: Settings) !void {
        if (!s.enabled) return;
        if (s.backend.len == 0 or std.mem.indexOfScalar(u8, s.backend, 0) != null or
            s.node_ids.len < 2 or s.node_ids.len > max_nodes or s.node_ids.len != s.node_urls.len or
            s.max_connections == 0 or s.memory_limit_mb == 0 or s.cpu_capacity == 0 or
            s.interval_ms < 100 or s.interval_ms > 60000 or s.ttl_ms < 3000 or s.ttl_ms > 300000 or
            s.ttl_ms < s.interval_ms * 3 or s.threshold_percent == 0 or s.threshold_percent > 100 or
            s.min_improvement_percent == 0 or s.min_improvement_percent > 100) return error.InvalidLoadBalancer;
        var found = false;
        for (s.node_ids, s.node_urls, 0..) |id, url, i| {
            if (id.len == 0 or id.len > 63) return error.InvalidLoadBalancer;
            for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return error.InvalidLoadBalancer;
            if (!validOrigin(url)) return error.InvalidLoadBalancer;
            for (s.node_ids[0..i], s.node_urls[0..i]) |other, origin| {
                if (std.mem.eql(u8, id, other) or std.ascii.eqlIgnoreCase(url, origin)) return error.InvalidLoadBalancer;
            }
            found = found or std.mem.eql(u8, id, s.node_id);
        }
        if (!found) return error.InvalidLoadBalancer;
    }
};

fn validOrigin(url: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, url, "http://")) url[7..] else if (std.mem.startsWith(u8, url, "https://")) url[8..] else return false;
    if (rest.len == 0 or rest.len > 255) return false;
    for (rest) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, ".-:[]", ch) == null) return false;
    const uri = std.Uri.parse(url) catch return false;
    const host = uri.host orelse return false;
    return host.percent_encoded.len > 0 and (uri.port orelse 1) != 0;
}

pub const Sample = extern struct {
    connections: u64 = 0,
    memory_bytes: u64 = 0,
    cpu: f64 = 0, // CPU seconds per wall second (1.0 = one busy core).
    connection_limit: u64 = 0,
    memory_limit: u64 = 0,
    cpu_capacity: u32 = 0,
    valid: u32 = 0,
    expires_ms: i64 = 0, // Receiver's monotonic clock; never extends a heartbeat's TTL.

    pub fn score(s: Sample, now_ms: i64) ?f64 {
        if (s.valid == 0 or now_ms >= s.expires_ms or s.connection_limit == 0 or s.memory_limit == 0 or s.cpu_capacity == 0 or !std.math.isFinite(s.cpu) or s.cpu < 0) return null;
        return @max(@as(f64, @floatFromInt(s.connections)) / @as(f64, @floatFromInt(s.connection_limit)), @max(s.cpu / @as(f64, @floatFromInt(s.cpu_capacity)), @as(f64, @floatFromInt(s.memory_bytes)) / @as(f64, @floatFromInt(s.memory_limit))));
    }
};

pub fn select(s: Settings, samples: []const Sample, now_ms: i64, secure: bool) ?usize {
    if (!s.enabled or samples.len != s.node_ids.len) return null;
    var local: ?f64 = null;
    for (s.node_ids, samples) |id, sample| if (std.mem.eql(u8, id, s.node_id)) {
        local = sample.score(now_ms);
    };
    const load = local orelse return null;
    const threshold = @as(f64, @floatFromInt(s.threshold_percent)) / 100;
    const margin = @as(f64, @floatFromInt(s.min_improvement_percent)) / 100;
    if (load <= threshold) return null;
    var best: ?usize = null;
    var best_score: f64 = threshold;
    for (s.node_ids, s.node_urls, samples, 0..) |id, url, sample, i| {
        if (std.mem.eql(u8, id, s.node_id) or (secure and !std.mem.startsWith(u8, url, "https://"))) continue;
        const score = sample.score(now_ms) orelse continue;
        if (score < best_score and load - score >= margin) {
            best = i;
            best_score = score;
        }
    }
    return best;
}

/// A response header alone cannot survive a client redirect. Reserve a query key
/// instead; any occurrence suppresses balancing, including malformed values.
/// Strip only the generated suffix to preserve the original query byte for byte.
pub fn redirectedTarget(target: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |part| {
        const name = part[0 .. std.mem.indexOfScalar(u8, part, '=') orelse part.len];
        if (std.mem.eql(u8, name, marker)) {
            const suffix = marker ++ "=1";
            if (std.mem.endsWith(u8, target, "&" ++ suffix)) return target[0 .. target.len - suffix.len - 1];
            if (std.mem.eql(u8, target[q + 1 ..], suffix)) return target[0..q];
            return target; // User-supplied reserved key: bypass, never trust as a destination.
        }
    }
    return null;
}

pub fn location(a: std.mem.Allocator, origin: []const u8, target: []const u8) !?[]const u8 {
    // Only origin-form targets; keep raw escaping and query ordering intact.
    if (target.len == 0 or target[0] != '/' or std.mem.indexOfScalar(u8, target, '#') != null or redirectedTarget(target) != null) return null;
    return try std.fmt.allocPrint(a, "{s}{s}{s}" ++ marker ++ "=1", .{ origin, target, if (std.mem.indexOfScalar(u8, target, '?') != null) "&" else "?" });
}

extern fn zlb_start(backend: [*:0]const u8, ids: [*]const [*:0]const u8, count: u32, local: u32, workers: u32, interval: u32, ttl: u32, connections: u64, memory: u64, cpus: u32) ?*anyopaque;
extern fn zlb_stop(handle: *anyopaque) void;
extern fn zlb_update(handle: *anyopaque, active: u32) void;
extern fn zlb_snapshot(handle: *anyopaque, out: [*]Sample) c_int;

pub const Runtime = struct {
    handle: ?*anyopaque = null,
    settings: Settings = .{},

    pub fn init(a: std.mem.Allocator, settings: Settings, workers: u32) !Runtime {
        if (!settings.enabled) return .{};
        try settings.validate();
        try settings.validateWorkers(workers);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const tmp = arena.allocator();
        var ids: [max_nodes][*:0]const u8 = undefined;
        var local: u32 = 0;
        for (settings.node_ids, 0..) |id, i| {
            ids[i] = try tmp.dupeSentinel(u8, id, 0);
            if (std.mem.eql(u8, id, settings.node_id)) local = @intCast(i);
        }
        const handle = zlb_start(try tmp.dupeSentinel(u8, settings.backend, 0), &ids, @intCast(settings.node_ids.len), local, @max(workers, 1), settings.interval_ms, settings.ttl_ms, settings.max_connections, @as(u64, settings.memory_limit_mb) * 1024 * 1024, settings.cpu_capacity) orelse return error.LoadBalancerInit;
        return .{ .handle = handle, .settings = settings };
    }
    pub fn deinit(r: *Runtime) void {
        if (r.handle) |h| zlb_stop(h);
        r.handle = null;
    }
    pub fn update(r: *Runtime, active: u32) void {
        if (r.handle) |h| zlb_update(h, active);
    }
    pub fn destination(r: *Runtime, now_ms: i64, secure: bool) ?[]const u8 {
        const h = r.handle orelse return null;
        var samples: [max_nodes]Sample = undefined;
        // Never wait for the collector, even for its short snapshot swap.
        if (zlb_snapshot(h, &samples) == 0) return null;
        const i = select(r.settings, samples[0..r.settings.node_ids.len], now_ms, secure) orelse return null;
        return r.settings.node_urls[i];
    }
};

test "selection considers every metric, freshness, capacity, margin and TLS" {
    const t = std.testing;
    const s: Settings = .{ .enabled = true, .node_id = "a", .node_ids = &.{ "a", "b", "c" }, .node_urls = &.{ "https://a", "https://b", "http://c" } };
    const base: Sample = .{ .valid = 1, .expires_ms = 100, .connection_limit = 100, .memory_limit = 100, .cpu_capacity = 2 };
    var samples = [_]Sample{ base, base, base };
    try t.expectEqual(null, select(s, &samples, 0, false));
    samples[0].connections = 90;
    samples[1].cpu = 1;
    try t.expectEqual(@as(?usize, 2), select(s, &samples, 0, false));
    try t.expectEqual(@as(?usize, 1), select(s, &samples, 0, true));
    samples[2].memory_bytes = 90;
    samples[1].expires_ms = 0;
    try t.expectEqual(null, select(s, &samples, 0, false));
    samples[1] = base;
    samples[0].connections = 0;
    samples[0].cpu = 1.9;
    try t.expectEqual(@as(?usize, 1), select(s, &samples, 0, false));
    samples[0].cpu = 0;
    samples[0].memory_bytes = 90;
    try t.expectEqual(@as(?usize, 1), select(s, &samples, 0, false));
    samples[1].connections = 79;
    var narrow = s;
    narrow.min_improvement_percent = 20;
    try t.expectEqual(null, select(narrow, &samples, 0, false));
    try t.expectEqual(null, select(s, &samples, 100, false));
    samples[0].cpu = std.math.nan(f64);
    try t.expectEqual(null, select(s, &samples, 0, false));
}

test "one-hop URL marker preserves escaping and empty queries" {
    const t = std.testing;
    for ([_][]const u8{ "/", "/a%2Fb?x=%26&x=2", "/p?", "/p?x=1&" }) |target| {
        const loc = (try location(t.allocator, "https://b", target)).?;
        defer t.allocator.free(loc);
        const routed = loc["https://b".len..];
        try t.expectEqualStrings(target, redirectedTarget(routed).?);
        try t.expectEqual(null, try location(t.allocator, "https://a", routed));
    }
    try t.expect(redirectedTarget("/?__zhttpd_lb=garbage&x=1") != null);
    try t.expectEqual(null, try location(t.allocator, "https://b", "http://a/path"));
    try t.expectEqual(null, try location(t.allocator, "https://b", "/path#fragment"));
}

test "settings require bounded safe origins and unique membership" {
    const t = std.testing;
    var s: Settings = .{ .enabled = true, .backend = "/tmp/cluster", .node_id = "a", .node_ids = &.{ "a", "b" }, .node_urls = &.{ "http://a:8080", "https://b" }, .max_connections = 100, .memory_limit_mb = 1024 };
    try s.validate();
    try s.validateWorkers(256);
    try t.expectError(error.TooManyLoadBalancerWorkers, s.validateWorkers(257));
    s.node_urls = &.{ "http://a:8080", "https://b/path" };
    try t.expectError(error.InvalidLoadBalancer, s.validate());
    s.node_urls = &.{ "http://a:8080", "https://b\r\nInjected:yes" };
    try t.expectError(error.InvalidLoadBalancer, s.validate());
    s.node_urls = &.{ "http://a:8080", "https://b" };
    s.node_ids = &.{ "a", "a" };
    try t.expectError(error.InvalidLoadBalancer, s.validate());
}
