//! TLS via OpenSSL (libssl/libcrypto 3.x), driven non-blockingly from the event loop.
//! Built only with `-Dtls=true`; zhttpd links the same OpenSSL 3.5 LTS that the
//! benchmark's nginx is built against (deps/openssl-install, sha256-verified tarball).
const std = @import("std");
const build_options = @import("build_options");
const config = @import("../http/config.zig");
const acme = @import("acme");
const Diag = @import("../http/diag.zig").Diag;

pub const enabled = build_options.tls;

pub const SSL_CTX = opaque {};
pub const SSL = opaque {};
const SSL_METHOD = opaque {};

extern "c" fn OSSL_QUIC_server_method() *const SSL_METHOD;
extern "c" fn TLS_server_method() *const SSL_METHOD;
extern "c" fn SSL_CTX_new(m: *const SSL_METHOD) ?*SSL_CTX;
extern "c" fn SSL_CTX_free(ctx: *SSL_CTX) void;
extern "c" fn SSL_CTX_use_certificate_chain_file(ctx: *SSL_CTX, file: [*:0]const u8) c_int;
extern "c" fn SSL_CTX_use_PrivateKey_file(ctx: *SSL_CTX, file: [*:0]const u8, typ: c_int) c_int;
extern "c" fn SSL_CTX_check_private_key(ctx: *const SSL_CTX) c_int;
extern "c" fn SSL_CTX_set_options(ctx: *SSL_CTX, op: u64) u64;
extern "c" fn SSL_CTX_ctrl(ctx: *SSL_CTX, cmd: c_int, larg: c_long, parg: ?*anyopaque) c_long;
extern "c" fn SSL_CTX_callback_ctrl(ctx: *SSL_CTX, cmd: c_int, cb: ?*const fn () callconv(.c) void) c_long;
extern "c" fn SSL_CTX_set_cipher_list(ctx: *SSL_CTX, s: [*:0]const u8) c_int;
extern "c" fn SSL_CTX_set_ciphersuites(ctx: *SSL_CTX, s: [*:0]const u8) c_int;
extern "c" fn SSL_CTX_set_timeout(ctx: *SSL_CTX, t: c_long) c_long;
extern "c" fn SSL_CTX_set_session_id_context(ctx: *SSL_CTX, sid: [*]const u8, len: c_uint) c_int;
extern "c" fn SSL_new(ctx: *SSL_CTX) ?*SSL;
extern "c" fn SSL_free(ssl: *SSL) void;
extern "c" fn SSL_set_fd(ssl: *SSL, fd: c_int) c_int;
extern "c" fn SSL_accept(ssl: *SSL) c_int;
extern "c" fn SSL_read(ssl: *SSL, buf: [*]u8, num: c_int) c_int;
extern "c" fn SSL_write(ssl: *SSL, buf: [*]const u8, num: c_int) c_int;
extern "c" fn SSL_shutdown(ssl: *SSL) c_int;
extern "c" fn SSL_get_error(ssl: *const SSL, ret: c_int) c_int;
extern "c" fn SSL_get_servername(ssl: *const SSL, typ: c_int) ?[*:0]const u8;
extern "c" fn SSL_set_SSL_CTX(ssl: *SSL, ctx: *SSL_CTX) ?*SSL_CTX;
const X509 = opaque {};
const EVP_PKEY = opaque {};
extern "c" fn SSL_CTX_get0_certificate(ctx: *const SSL_CTX) ?*X509;
extern "c" fn SSL_CTX_get0_privatekey(ctx: *const SSL_CTX) ?*EVP_PKEY;
extern "c" fn SSL_use_cert_and_key(ssl: *SSL, cert: *X509, key: *EVP_PKEY, chain: ?*anyopaque, override: c_int) c_int;
extern "c" fn SSL_get_ex_data(ssl: *const SSL, idx: c_int) ?*anyopaque;
extern "c" fn SSL_set_ex_data(ssl: *SSL, idx: c_int, data: ?*anyopaque) c_int;
extern "c" fn SSL_get_version(ssl: *const SSL) [*:0]const u8;
extern "c" fn SSL_session_reused(ssl: *const SSL) c_int;
extern "c" fn ERR_get_error() c_ulong;
extern "c" fn ERR_error_string_n(e: c_ulong, buf: [*]u8, len: usize) void;
extern "c" fn ERR_clear_error() void;

extern "c" fn SSL_CTX_set_alpn_select_cb(ctx: *SSL_CTX, cb: *const fn (*SSL, *[*]const u8, *u8, [*]const u8, c_uint, ?*anyopaque) callconv(.c) c_int, arg: ?*anyopaque) void;
extern "c" fn SSL_get0_alpn_selected(ssl: *const SSL, data: *[*]const u8, len: *c_uint) void;
extern "c" fn SSL_get_SSL_CTX(ssl: *const SSL) *SSL_CTX;

pub fn isH2(ssl: *SSL) bool {
    var data: [*]const u8 = undefined;
    var len: c_uint = 0;
    SSL_get0_alpn_selected(ssl, &data, &len);
    return len == 2 and std.mem.eql(u8, data[0..len], "h2");
}

fn alpn(ssl: *SSL, out: *[*]const u8, outlen: *u8, input: [*]const u8, len: c_uint, arg: ?*anyopaque) callconv(.c) c_int {
    const tbl: *SniTable = @ptrCast(@alignCast(arg.?));
    var h2 = tbl.listen.opts.http2;
    const ctx = SSL_get_SSL_CTX(ssl);
    for (tbl.listen.entries) |e| {
        if (tbl.ctxs[e.server.index] == ctx) h2 = h2 or e.server.http2;
    }
    for (tbl.managed) |managed| {
        if (managed.ctx == ctx) h2 = h2 or managed.server.http2;
    }
    const wanted: []const u8 = if (tbl.listen.opts.quic) "h3" else if (@import("multiplex.zig").enabled and h2) "h2" else "http/1.1";
    // Prefer h2 even if the client lists HTTP/1.1 first, with a normal fallback.
    for ([_][]const u8{ wanted, if (tbl.listen.opts.quic) "h3" else "http/1.1" }) |protocol_name| {
        var i: usize = 0;
        while (i < len) {
            const n = input[i];
            i += 1;
            if (n == 0 or i + n > len) return SSL_TLSEXT_ERR_ALERT_FATAL;
            if (std.mem.eql(u8, input[i .. i + n], protocol_name)) {
                out.* = input + i;
                outlen.* = n;
                return SSL_TLSEXT_ERR_OK;
            }
            i += n;
        }
    }
    return SSL_TLSEXT_ERR_ALERT_FATAL;
}

const SSL_FILETYPE_PEM = 1;
const SSL_CTRL_MODE = 33;
const SSL_CTRL_SET_SESS_CACHE_SIZE = 42;
const SSL_CTRL_SET_SESS_CACHE_MODE = 44;
const SSL_CTRL_SET_TLSEXT_SERVERNAME_CB = 53;
const SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG = 54;
const SSL_CTRL_SET_GROUPS_LIST = 92;
const SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
const SSL_CTRL_SET_MAX_PROTO_VERSION = 124;
const SSL_MODE_ENABLE_PARTIAL_WRITE = 0x1;
const SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER = 0x2;
const SSL_MODE_RELEASE_BUFFERS = 0x10;
const SSL_SESS_CACHE_OFF = 0x0;
const SSL_SESS_CACHE_SERVER = 0x2;
const SSL_OP_NO_TICKET: u64 = 1 << 14;
const SSL_OP_CIPHER_SERVER_PREFERENCE: u64 = 1 << 22;
const SSL_OP_NO_RENEGOTIATION: u64 = 1 << 30;
const TLS1_VERSION = 0x0301;
const TLS1_1_VERSION = 0x0302;
const TLS1_2_VERSION = 0x0303;
const TLS1_3_VERSION = 0x0304;
pub const SSL_ERROR_WANT_READ = 2;
pub const SSL_ERROR_WANT_WRITE = 3;
pub const SSL_ERROR_SYSCALL = 5;
pub const SSL_ERROR_ZERO_RETURN = 6;
const SSL_TLSEXT_ERR_OK = 0;
const SSL_TLSEXT_ERR_ALERT_FATAL = 2;
const SSL_TLSEXT_ERR_NOACK = 3;

/// SNI context shared by every SSL_CTX of one listen socket.
const ManagedContext = struct { server: *const config.Server, certificate: usize, ctx: *SSL_CTX };
pub const SniTable = struct {
    certificates: []const acme.Settings,
    managed: []const ManagedContext,
    listen: *const config.Listen,
    ctxs: []?*SSL_CTX, // indexed by Server.index
    default_ctx: *SSL_CTX,
};

fn lastError(buf: []u8) []const u8 {
    const e = ERR_get_error();
    if (e == 0) return "unknown error";
    ERR_error_string_n(e, buf.ptr, buf.len);
    return std.mem.sliceTo(buf, 0);
}

/// Validate each TLS virtual host even when an ACME certificate is pending.
/// Only managed certificate loading is deferred; all other TLS options and
/// unrelated certificate/key pairs are checked normally.
pub fn validateConfig(gpa: std.mem.Allocator, cfg: *const config.Config, diag: *Diag) !void {
    for (cfg.listens) |listener| {
        if (!listener.opts.ssl) continue;
        for (listener.entries) |entry| {
            const srv = entry.server;
            if (srv.tls.acme_certificates.len == 0) {
                const ctx = try makeContext(gpa, &srv.tls, srv, diag, listener.opts.quic);
                SSL_CTX_free(ctx);
            } else for (srv.tls.acme_certificates) |index| {
                const ac = cfg.acme[index];
                var settings = managedSettings(srv.tls, ac);
                if (!acme.ready(ac)) settings.reject_handshake = true;
                const ctx = try makeContext(gpa, &settings, srv, diag, listener.opts.quic);
                SSL_CTX_free(ctx);
            }
        }
    }
}

fn managedSettings(base: config.Tls, certificate: acme.Settings) config.Tls {
    var settings = base;
    settings.certificate = certificate.certificate;
    settings.certificate_key = certificate.key;
    return settings;
}

/// Create an SSL_CTX for a server from its ssl_* directives.
pub fn makeContext(gpa: std.mem.Allocator, t: *const config.Tls, srv: *const config.Server, diag: *Diag, quic: bool) !*SSL_CTX {
    var ebuf: [256]u8 = undefined;
    const ctx = SSL_CTX_new(if (@import("multiplex.zig").enabled and quic) OSSL_QUIC_server_method() else TLS_server_method()) orelse return error.TlsInit;
    errdefer SSL_CTX_free(ctx);
    if (!t.reject_handshake) {
        const cert = t.certificate orelse {
            diag.add(.emerg, srv.file, srv.line, "no \"ssl_certificate\" is defined for the \"listen ... ssl\" directive", .{});
            return error.TlsConfig;
        };
        const key = t.certificate_key orelse {
            diag.add(.emerg, srv.file, srv.line, "no \"ssl_certificate_key\" is defined for certificate \"{s}\"", .{cert});
            return error.TlsConfig;
        };
        const cz = try gpa.dupeSentinel(u8, cert, 0);
        defer gpa.free(cz);
        const kz = try gpa.dupeSentinel(u8, key, 0);
        defer gpa.free(kz);
        if (SSL_CTX_use_certificate_chain_file(ctx, cz) != 1) {
            diag.add(.emerg, srv.file, srv.line, "cannot load certificate \"{s}\": {s}", .{ cert, lastError(&ebuf) });
            return error.TlsConfig;
        }
        if (SSL_CTX_use_PrivateKey_file(ctx, kz, SSL_FILETYPE_PEM) != 1 or SSL_CTX_check_private_key(ctx) != 1) {
            diag.add(.emerg, srv.file, srv.line, "cannot load certificate key \"{s}\": {s}", .{ key, lastError(&ebuf) });
            return error.TlsConfig;
        }
    }
    // protocols
    var min: c_long = 0;
    var max: c_long = 0;
    for (t.protocols) |p| {
        const v: c_long = if (std.mem.eql(u8, p, "TLSv1")) TLS1_VERSION else if (std.mem.eql(u8, p, "TLSv1.1")) TLS1_1_VERSION else if (std.mem.eql(u8, p, "TLSv1.2")) TLS1_2_VERSION else if (std.mem.eql(u8, p, "TLSv1.3")) TLS1_3_VERSION else continue;
        if (min == 0 or v < min) min = v;
        if (v > max) max = v;
    }
    if (min != 0) {
        _ = SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, min, null);
        _ = SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, max, null);
    }
    var opts: u64 = SSL_OP_NO_RENEGOTIATION;
    if (!t.session_tickets) opts |= SSL_OP_NO_TICKET;
    if (t.prefer_server_ciphers) opts |= SSL_OP_CIPHER_SERVER_PREFERENCE;
    _ = SSL_CTX_set_options(ctx, opts);
    _ = SSL_CTX_ctrl(ctx, SSL_CTRL_MODE, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER | SSL_MODE_RELEASE_BUFFERS, null);
    if (t.ciphers) |cs| {
        const z = try gpa.dupeSentinel(u8, cs, 0);
        defer gpa.free(z);
        if (SSL_CTX_set_cipher_list(ctx, z) != 1) {
            diag.add(.emerg, srv.file, srv.line, "SSL_CTX_set_cipher_list(\"{s}\") failed: {s}", .{ cs, lastError(&ebuf) });
            return error.TlsConfig;
        }
    }
    for (t.conf_commands) |cmd| {
        if (std.ascii.eqlIgnoreCase(cmd[0], "Ciphersuites")) {
            const z = try gpa.dupeSentinel(u8, cmd[1], 0);
            defer gpa.free(z);
            if (SSL_CTX_set_ciphersuites(ctx, z) != 1) {
                diag.add(.emerg, srv.file, srv.line, "invalid Ciphersuites \"{s}\"", .{cmd[1]});
                return error.TlsConfig;
            }
        } else diag.add(.warn, srv.file, srv.line, "ssl_conf_command \"{s}\" is not supported, ignored", .{cmd[0]});
    }
    if (t.ecdh_curve) |curve| {
        if (!std.mem.eql(u8, curve, "auto")) {
            const z = try gpa.dupeSentinel(u8, curve, 0);
            defer gpa.free(z);
            if (SSL_CTX_ctrl(ctx, SSL_CTRL_SET_GROUPS_LIST, 0, @constCast(z.ptr)) != 1) {
                diag.add(.emerg, srv.file, srv.line, "invalid ssl_ecdh_curve \"{s}\"", .{curve});
                return error.TlsConfig;
            }
        }
    }
    // Session cache: nginx's `shared:` zone is cross-worker; OpenSSL's internal cache is
    // per process. Tickets (default on) work across workers because the ticket keys are
    // generated here, before the workers fork.
    const sid = "zhttpd";
    _ = SSL_CTX_set_session_id_context(ctx, sid, sid.len);
    switch (t.session_cache) {
        .off, .none => _ = SSL_CTX_ctrl(ctx, SSL_CTRL_SET_SESS_CACHE_MODE, SSL_SESS_CACHE_OFF, null),
        .builtin => {
            _ = SSL_CTX_ctrl(ctx, SSL_CTRL_SET_SESS_CACHE_MODE, SSL_SESS_CACHE_SERVER, null);
            _ = SSL_CTX_ctrl(ctx, SSL_CTRL_SET_SESS_CACHE_SIZE, @intCast(t.session_cache_size), null);
        },
    }
    _ = SSL_CTX_set_timeout(ctx, @intCast(t.session_timeout_s));
    return ctx;
}

const router = @import("router.zig");
const Regex = @import("../regex.zig").Regex;

fn selectContext(ssl: *SSL, ctx: *SSL_CTX, quic: bool) bool {
    if (!quic) return SSL_set_SSL_CTX(ssl, ctx) != null;
    // OpenSSL 3.5 does not support SSL_set_SSL_CTX on a QUIC SSL object.
    // Install the already-loaded certificate/key/chain on this connection;
    // SSL_use_cert_and_key supports QUIC and takes its own references.
    var chain: ?*anyopaque = null;
    if (SSL_CTX_ctrl(ctx, 115, 0, @ptrCast(&chain)) != 1) return false; // SSL_CTRL_GET_CHAIN_CERTS
    return SSL_use_cert_and_key(ssl, SSL_CTX_get0_certificate(ctx) orelse return false, SSL_CTX_get0_privatekey(ctx) orelse return false, chain, 1) == 1;
}

fn sniCallback(ssl: *SSL, alert: *c_int, arg: ?*anyopaque) callconv(.c) c_int {
    _ = alert;
    const tbl: *SniTable = @ptrCast(@alignCast(arg orelse return SSL_TLSEXT_ERR_OK));
    const name = SSL_get_servername(ssl, 0) orelse {
        // no SNI: default server; reject if it asked for it
        const d = tbl.listen.entries[0].server;
        return if (d.tls.reject_handshake) SSL_TLSEXT_ERR_ALERT_FATAL else SSL_TLSEXT_ERR_OK;
    };
    var caps: Regex.Captures = .{};
    var hb: [256]u8 = undefined;
    const local = tbl.listen.addr;
    const srv = router.selectServer(tbl.listen, local, std.mem.span(name), &caps, &hb);
    if (srv.tls.reject_handshake) return SSL_TLSEXT_ERR_ALERT_FATAL;
    var best: ?*SSL_CTX = null;
    var rank: u8 = 0;
    for (tbl.managed) |managed| {
        if (managed.server != srv) continue;
        const candidate = acme.matchRank(tbl.certificates[managed.certificate].domains, std.mem.span(name));
        if (candidate > rank) {
            rank = candidate;
            best = managed.ctx;
        }
    }
    if (best) |ctx| {
        return if (selectContext(ssl, ctx, tbl.listen.opts.quic)) SSL_TLSEXT_ERR_OK else SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    if (srv.index < tbl.ctxs.len) {
        if (tbl.ctxs[srv.index]) |ctx| if (!selectContext(ssl, ctx, tbl.listen.opts.quic)) return SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    return SSL_TLSEXT_ERR_OK;
}

/// Build SSL contexts for every server on an `ssl` listen socket.
pub fn buildSni(gpa: std.mem.Allocator, cfg: *const config.Config, listen: *const config.Listen, diag: *Diag) !*SniTable {
    const tbl = try gpa.create(SniTable);
    const ctxs = try gpa.alloc(?*SSL_CTX, cfg.servers.len);
    @memset(ctxs, null);
    var default_ctx: ?*SSL_CTX = null;
    var managed: std.ArrayList(ManagedContext) = .empty;
    errdefer {
        // Each alternate context is unique; the first is also in ctxs.
        for (managed.items) |item| if (ctxs[item.server.index] != item.ctx) SSL_CTX_free(item.ctx);
        for (ctxs) |ctx| if (ctx) |value| SSL_CTX_free(value);
        managed.deinit(gpa);
        gpa.free(ctxs);
        gpa.destroy(tbl);
    }
    for (listen.entries) |e| {
        if (ctxs[e.server.index] != null) continue;
        const ctx = try makeContext(gpa, &e.server.tls, e.server, diag, listen.opts.quic);
        ctxs[e.server.index] = ctx;
        for (e.server.tls.acme_certificates, 0..) |index, i| {
            const settings = managedSettings(e.server.tls, cfg.acme[index]);
            const extra = if (i == 0) ctx else try makeContext(gpa, &settings, e.server, diag, listen.opts.quic);
            managed.append(gpa, .{ .server = e.server, .certificate = index, .ctx = extra }) catch |err| {
                if (i != 0) SSL_CTX_free(extra);
                return err;
            };
        }
    }
    const def = listen.defaultFor(listen.addr);
    default_ctx = ctxs[def.index];
    tbl.* = .{ .listen = listen, .ctxs = ctxs, .default_ctx = default_ctx.?, .certificates = cfg.acme, .managed = try managed.toOwnedSlice(gpa) };
    for (ctxs) |maybe| {
        const ctx = maybe orelse continue;
        SSL_CTX_set_alpn_select_cb(ctx, alpn, tbl);
        _ = SSL_CTX_callback_ctrl(ctx, SSL_CTRL_SET_TLSEXT_SERVERNAME_CB, @ptrCast(&sniCallback));
        _ = SSL_CTX_ctrl(ctx, SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG, 0, tbl);
    }
    for (tbl.managed) |item| {
        SSL_CTX_set_alpn_select_cb(item.ctx, alpn, tbl);
        _ = SSL_CTX_callback_ctrl(item.ctx, SSL_CTRL_SET_TLSEXT_SERVERNAME_CB, @ptrCast(&sniCallback));
        _ = SSL_CTX_ctrl(item.ctx, SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG, 0, tbl);
    }
    return tbl;
}

pub fn newConn(tbl: *SniTable, fd: c_int) ?*SSL {
    const ssl = SSL_new(tbl.default_ctx) orelse return null;
    if (SSL_set_fd(ssl, fd) != 1) {
        SSL_free(ssl);
        return null;
    }
    return ssl;
}

pub const IoResult = union(enum) { ok: usize, want_read, want_write, eof, err };

pub fn handshake(ssl: *SSL) IoResult {
    ERR_clear_error();
    const r = SSL_accept(ssl);
    if (r == 1) return .{ .ok = 0 };
    return classify(ssl, r);
}

pub fn read(ssl: *SSL, buf: []u8) IoResult {
    ERR_clear_error();
    const r = SSL_read(ssl, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))));
    if (r > 0) return .{ .ok = @intCast(r) };
    return classify(ssl, r);
}

pub fn write(ssl: *SSL, buf: []const u8) IoResult {
    ERR_clear_error();
    const r = SSL_write(ssl, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))));
    if (r > 0) return .{ .ok = @intCast(r) };
    return classify(ssl, r);
}

fn classify(ssl: *SSL, r: c_int) IoResult {
    return switch (SSL_get_error(ssl, r)) {
        SSL_ERROR_WANT_READ => .want_read,
        SSL_ERROR_WANT_WRITE => .want_write,
        SSL_ERROR_ZERO_RETURN => .eof,
        else => .err,
    };
}

pub fn free(ssl: *SSL) void {
    _ = SSL_shutdown(ssl);
    SSL_free(ssl);
}

pub fn protocol(ssl: *SSL) []const u8 {
    return std.mem.span(SSL_get_version(ssl));
}
