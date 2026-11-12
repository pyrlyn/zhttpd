//! Embeddable native HTTP application on zhttpd's existing event loop.
const std = @import("std");
const http = @import("http");
const settings = @import("settings");
pub const application = http.application;
pub const Context = application.Context;
pub const Route = struct {
    path: []const u8,
    methods: []const []const u8 = &.{"GET"},
    application: application.Application,
    idempotency: bool = false,
};
pub const Options = struct {
    max_body_size: u64 = 1024 * 1024,
    gzip: bool = false,
    cors: http.config.Cors = .{},
    jwt: ?application.auth.Policy = null,
    rate_limit: u32 = 0,
    rate_burst: u32 = 1,
};
var running = false;
pub fn stop() void {
    http.server.worker.sig_terminate = true;
}
pub fn serve(address: []const u8, routes: []const Route, options: Options) !void {
    const a = std.heap.c_allocator;
    var diag: http.diag.Diag = .{ .gpa = a };
    defer diag.deinit();
    var b = try settings.Builder.init(a, "http-sdk", ".", &diag);
    defer settings.destroy(a, b.cfg);
    const node: settings.Node = .{ .name = "http", .args = &.{}, .file = "sdk", .line = 0 };
    const srv = try b.server(node, null);
    srv.conf.json_errors = true;
    srv.conf.client_max_body_size = options.max_body_size;
    srv.conf.gzip = options.gzip;
    srv.conf.cors = options.cors;
    srv.conf.jwt = options.jwt;
    srv.conf.rate_limit = options.rate_limit;
    srv.conf.rate_burst = options.rate_burst;
    for (routes) |r| {
        const loc = try b.locationMethods(srv, node, r.path, .exact, r.methods);
        loc.conf.application = r.application;
        loc.conf.idempotency = r.idempotency;
    }
    try b.listen(srv, try b.address(node, address, 8080), false, false);
    try serveConfig(b.cfg);
}
/// Attach Application to LocConf in a loaded TOML config, then serve with its TLS/logging/timeouts.
/// Config and callback captures must remain alive until this function returns.
pub fn serveConfig(cfg: *http.config.Config) !void {
    if (running) return error.AlreadyRunning;
    running = true;
    defer running = false;
    const a = std.heap.c_allocator;
    var diag: http.diag.Diag = .{ .gpa = a };
    defer diag.deinit();
    for (cfg.servers) |srv| {
        try http.server.policy.validate(srv.conf);
        try http.server.policy.validateLocations(srv.locations);
    }
    try http.server.multiplex.validate(cfg);
    if (http.server.tls.enabled) try http.server.tls.validateConfig(a, cfg, &diag);
    const listeners = try a.alloc(http.server.worker.Listener, cfg.listens.len);
    defer a.free(listeners);
    var initialized: usize = 0;
    defer for (listeners[0..initialized]) |*l| {
        http.server.multiplex.freeH3(l);
        if (l.sni) |sni| if (http.server.tls.enabled) http.server.tls.freeSni(a, sni);
        http.server.net.close(l.fd);
    };
    for (cfg.listens, 0..) |*l, i| {
        var errno: c_int = 0;
        const fd = if (l.opts.quic) try http.server.net.listenUdp(l.addr, false, l.opts.ipv6only, &errno) else try http.server.net.listenSocket(l.addr, l.opts.backlog, false, l.opts.ipv6only, &errno);
        listeners[i] = .{ .fd = fd, .listen = l };
        initialized += 1;
        if (l.opts.ssl or l.opts.quic) {
            if (!http.server.tls.enabled) return error.TlsNotBuilt;
            listeners[i].sni = try http.server.tls.buildSni(a, cfg, l, &diag);
        }
    }
    http.server.worker.sig_terminate = false;
    http.server.worker.sig_quit = false;
    http.server.worker.sig_reopen = false;
    var w = try http.server.worker.Worker.init(a, cfg, listeners, 2, 0);
    defer w.deinit();
    w.run();
}
