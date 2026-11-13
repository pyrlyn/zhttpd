//! Nonblocking TLS. OpenSSL 3.x is the default; AWS-LC is an opt-in build backend.
const std = @import("std");
const build_options = @import("build_options");
const config = @import("../http/config.zig");
const acme = @import("acme");
const Diag = @import("../http/diag.zig").Diag;
const PasswordFile = @import("password_file.zig").PasswordFile;
const builtin = @import("builtin");

pub const enabled = build_options.tls;
const aws_lc = build_options.aws_lc;
pub const backend_name = if (!enabled) "disabled" else if (aws_lc) "AWS-LC" else "OpenSSL";
pub const track_read_ready = builtin.os.tag == .linux;
pub const ReadState = struct { ready: bool = true, eof: bool = false, want_write: bool = false };

pub const SSL_CTX = opaque {};
pub const SSL = opaque {};
const SSL_METHOD = opaque {};
pub const BIO = opaque {};
const BIO_METHOD = opaque {};
extern "c" fn BIO_f_buffer() *const BIO_METHOD;
extern "c" fn BIO_new(method: *const BIO_METHOD) ?*BIO;
extern "c" fn BIO_free(bio: *BIO) c_int;
extern "c" fn BIO_up_ref(bio: *BIO) c_int;
extern "c" fn BIO_push(bio: *BIO, next: *BIO) ?*BIO;
extern "c" fn BIO_pop(bio: *BIO) ?*BIO;
extern "c" fn BIO_ctrl(bio: *BIO, cmd: c_int, arg: c_long, ptr: ?*anyopaque) c_long;
extern "c" fn BIO_test_flags(bio: *const BIO, flags: c_int) c_int;
extern "c" fn SSL_get_wbio(ssl: *const SSL) ?*BIO;
extern "c" fn SSL_set0_wbio(ssl: *SSL, bio: *BIO) void;
const BioCallback = *const fn (*BIO, c_int, ?[*]const u8, usize, c_int, c_long, c_int, ?*usize) callconv(.c) c_long;
extern "c" fn SSL_get_rbio(ssl: *const SSL) ?*BIO;
extern "c" fn SSL_has_pending(ssl: *const SSL) c_int;
extern "c" fn BIO_set_callback_ex(bio: *BIO, cb: ?BioCallback) void;
extern "c" fn BIO_set_callback_arg(bio: *BIO, arg: *anyopaque) void;
extern "c" fn BIO_get_callback_arg(bio: *const BIO) ?*anyopaque;
extern "c" fn BIO_set_flags(bio: *BIO, flags: c_int) void;
extern "c" fn BIO_clear_flags(bio: *BIO, flags: c_int) void;

extern "c" fn TLS_server_method() *const SSL_METHOD;
extern "c" fn SSL_CTX_new(m: *const SSL_METHOD) ?*SSL_CTX;
extern "c" fn SSL_CTX_free(ctx: *SSL_CTX) void;
extern "c" fn SSL_CTX_set_default_passwd_cb(ctx: *SSL_CTX, cb: *const fn ([*]u8, c_int, c_int, ?*anyopaque) callconv(.c) c_int) void;
extern "c" fn SSL_CTX_set_default_passwd_cb_userdata(ctx: *SSL_CTX, userdata: ?*anyopaque) void;
extern "c" fn SSL_CTX_use_certificate_chain_file(ctx: *SSL_CTX, file: [*:0]const u8) c_int;
extern "c" fn SSL_CTX_use_PrivateKey_file(ctx: *SSL_CTX, file: [*:0]const u8, typ: c_int) c_int;
extern "c" fn SSL_CTX_check_private_key(ctx: *const SSL_CTX) c_int;
extern "c" fn SSL_CTX_set_cipher_list(ctx: *SSL_CTX, s: [*:0]const u8) c_int;
extern "c" fn SSL_CTX_set_ciphersuites(ctx: *SSL_CTX, s: [*:0]const u8) c_int;
extern "c" fn SSL_CTX_set_session_id_context(ctx: *SSL_CTX, sid: [*]const u8, len: c_uint) c_int;
extern "c" fn SSL_new(ctx: *SSL_CTX) ?*SSL;
extern "c" fn SSL_free(ssl: *SSL) void;
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
extern "c" fn ERR_clear_error() void;

// Backend-specific ABI and legacy-control adaptation.
const OpenSsl = struct {
    extern "c" fn SSL_set_fd(ssl: *SSL, fd: c_int) c_int;
    extern "c" fn SSL_CTX_set_options(ctx: *SSL_CTX, op: u64) u64;
    extern "c" fn SSL_CTX_ctrl(ctx: *SSL_CTX, cmd: c_int, larg: c_long, parg: ?*anyopaque) c_long;
    extern "c" fn SSL_CTX_callback_ctrl(ctx: *SSL_CTX, cmd: c_int, cb: ?*const fn () callconv(.c) void) c_long;
    extern "c" fn SSL_CTX_set_timeout(ctx: *SSL_CTX, t: c_long) c_long;
    extern "c" fn ERR_get_error() c_ulong;
    extern "c" fn ERR_error_string_n(e: c_ulong, buf: [*]u8, len: usize) void;
};
const AwsLc = struct {
    extern "c" fn zhttpd_aws_prepare_tickets(ctx: *SSL_CTX) c_int;
    extern "c" fn zhttpd_aws_set_fd(ssl: *SSL, fd: c_int) c_int;
    extern "c" fn zhttpd_aws_ctx_options(ctx: *SSL_CTX, op: u64) u64;
    extern "c" fn zhttpd_aws_ctx_ctrl(ctx: *SSL_CTX, cmd: c_int, larg: c_long, parg: ?*anyopaque) c_long;
    extern "c" fn zhttpd_aws_ctx_callback_ctrl(ctx: *SSL_CTX, cmd: c_int, cb: ?*const fn () callconv(.c) void) c_long;
    extern "c" fn zhttpd_aws_ctx_timeout(ctx: *SSL_CTX, t: c_long) c_long;
    extern "c" fn zhttpd_aws_error() c_ulong;
    extern "c" fn zhttpd_aws_error_string(e: c_ulong, buf: [*]u8, len: usize) void;
};
const SSL_CTX_ctrl = if (aws_lc) AwsLc.zhttpd_aws_ctx_ctrl else OpenSsl.SSL_CTX_ctrl;
const SSL_set_fd = if (aws_lc) AwsLc.zhttpd_aws_set_fd else OpenSsl.SSL_set_fd;
const SSL_CTX_callback_ctrl = if (aws_lc) AwsLc.zhttpd_aws_ctx_callback_ctrl else OpenSsl.SSL_CTX_callback_ctrl;
const SSL_CTX_set_options = if (aws_lc) AwsLc.zhttpd_aws_ctx_options else OpenSsl.SSL_CTX_set_options;
const SSL_CTX_set_timeout = if (aws_lc) AwsLc.zhttpd_aws_ctx_timeout else OpenSsl.SSL_CTX_set_timeout;
const ERR_get_error = if (aws_lc) AwsLc.zhttpd_aws_error else OpenSsl.ERR_get_error;
const ERR_error_string_n = if (aws_lc) AwsLc.zhttpd_aws_error_string else OpenSsl.ERR_error_string_n;
extern "c" fn zhttpd_aws_buffer_new(capacity: usize) ?*BIO;
extern "c" fn zhttpd_aws_buffer_cache_clear() void;

pub fn clearWriteBufferCache() void {
    if (enabled and aws_lc) zhttpd_aws_buffer_cache_clear();
}

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
                if (std.mem.eql(u8, protocol_name, "h2")) @import("multiplex.zig").attachTx(ssl);
                return SSL_TLSEXT_ERR_OK;
            }
            i += n;
        }
    }
    return SSL_TLSEXT_ERR_ALERT_FATAL;
}

const SSL_FILETYPE_PEM = 1;
const SSL_CTRL_MODE = 33;
const SSL_CTRL_SET_READ_AHEAD = 41;
const SSL_CTRL_SET_SESS_CACHE_SIZE = 42;
const SSL_CTRL_SET_SESS_CACHE_MODE = 44;
const SSL_CTRL_SET_TLSEXT_SERVERNAME_CB = 53;
const SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG = 54;
const SSL_CTRL_SET_GROUPS_LIST = 92;
const SSL_CTRL_SET_MIN_PROTO_VERSION = 123;
const SSL_CTRL_SET_MAX_PROTO_VERSION = 124;
const SSL_MODE_ENABLE_PARTIAL_WRITE = 0x1;
const SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER = 0x2;
const SSL_MODE_NO_AUTO_CHAIN = 0x8;
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
    // Encryption must be ready before any ACME request, even without a cert yet.
    for (cfg.acme) |ac| if (ac.encrypt_key) {
        var passwords: PasswordFile = .{};
        defer passwords.deinit();
        passwords.read(gpa, ac.password_file orelse return error.TlsConfig) catch |err| {
            diag.add(.emerg, null, 0, "cannot read encryption password for ACME certificate {s}: {s}", .{ ac.name, @errorName(err) });
            return error.TlsConfig;
        };
    };
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
    settings.password_file = certificate.password_file orelse base.password_file;
    return settings;
}

// Configuration loading is unattended, including automatic reload. Never let
// OpenSSL's default PEM callback block the master on an interactive prompt.
pub fn noPassword(_: [*]u8, _: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

pub fn filePassword(buf: [*]u8, size: c_int, writing: c_int, userdata: ?*anyopaque) callconv(.c) c_int {
    if (writing != 0 or size <= 0) return 0;
    const password: *const []const u8 = @ptrCast(@alignCast(userdata orelse return 0));
    if (password.len > @as(usize, @intCast(size))) return 0;
    @memcpy(buf[0..password.len], password.*);
    return @intCast(password.len);
}

/// Create an SSL_CTX for a server from its ssl_* directives.
pub fn makeContext(gpa: std.mem.Allocator, t: *const config.Tls, srv: *const config.Server, diag: *Diag, quic: bool) !*SSL_CTX {
    var ebuf: [256]u8 = undefined;
    const ctx = SSL_CTX_new(TLS_server_method()) orelse return error.TlsInit;
    errdefer SSL_CTX_free(ctx);
    SSL_CTX_set_default_passwd_cb(ctx, noPassword);
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
        var loaded = false;
        if (t.password_file) |path| {
            var passwords: PasswordFile = .{};
            defer passwords.deinit();
            passwords.read(gpa, path) catch |err| {
                diag.add(.emerg, srv.file, srv.line, "cannot read TLS password file \"{s}\": {s}", .{ path, @errorName(err) });
                return error.TlsConfig;
            };
            var password: []const u8 = &.{};
            SSL_CTX_set_default_passwd_cb(ctx, filePassword);
            SSL_CTX_set_default_passwd_cb_userdata(ctx, @ptrCast(&password));
            defer {
                // SSL_CTX outlives this stack frame: retain neither callback data
                // nor passphrases once OpenSSL owns the decrypted private key.
                SSL_CTX_set_default_passwd_cb_userdata(ctx, null);
                SSL_CTX_set_default_passwd_cb(ctx, noPassword);
            }
            for (passwords.lines[0..passwords.count]) |value| {
                password = value;
                ERR_clear_error();
                if (SSL_CTX_use_PrivateKey_file(ctx, kz, SSL_FILETYPE_PEM) == 1) {
                    loaded = true;
                    ERR_clear_error();
                    break;
                }
            }
        } else loaded = SSL_CTX_use_PrivateKey_file(ctx, kz, SSL_FILETYPE_PEM) == 1;
        if (!loaded or SSL_CTX_check_private_key(ctx) != 1) {
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
    // QUIC carries TLS 1.3 only (RFC 9001 §4.2); the zquic transport drives
    // this context through SSL_set_quic_tls_cbs.
    if (quic) {
        min = TLS1_3_VERSION;
        max = TLS1_3_VERSION;
    }
    if (min != 0) {
        _ = SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, min, null);
        _ = SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, max, null);
    }
    var opts: u64 = SSL_OP_NO_RENEGOTIATION;
    if (!t.session_tickets) opts |= SSL_OP_NO_TICKET;
    if (t.prefer_server_ciphers) opts |= SSL_OP_CIPHER_SERVER_PREFERENCE;
    _ = SSL_CTX_set_options(ctx, opts);
    // The configured certificate file already supplies the chain. Like nginx,
    // avoid attempting to reconstruct it from a trust store on every handshake.
    _ = SSL_CTX_ctrl(ctx, SSL_CTRL_MODE, SSL_MODE_ENABLE_PARTIAL_WRITE | SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER | SSL_MODE_NO_AUTO_CHAIN | SSL_MODE_RELEASE_BUFFERS, null);
    // Read the record header and payload in one socket read when available.
    // Keep OpenSSL's default AUTO_RETRY mode: the edge-triggered connection loop
    // drains SSL_read until WANT_READ, including records buffered by read-ahead.
    _ = SSL_CTX_ctrl(ctx, SSL_CTRL_SET_READ_AHEAD, 1, null);
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
    if (aws_lc and t.session_tickets and AwsLc.zhttpd_aws_prepare_tickets(ctx) != 1) return error.TlsInit;
    return ctx;
}

const router = @import("router.zig");
const Regex = @import("../regex.zig").Regex;

fn selectContext(ssl: *SSL, ctx: *SSL_CTX, quic: bool) bool {
    _ = quic;
    return SSL_set_SSL_CTX(ssl, ctx) != null;
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
        const indices = e.server.tls.acme_certificates;
        const first = if (indices.len > 0) managedSettings(e.server.tls, cfg.acme[indices[0]]) else e.server.tls;
        const ctx = try makeContext(gpa, &first, e.server, diag, listen.opts.quic);
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

/// Release a table that was never handed to a worker (failed reload).
pub fn freeSni(gpa: std.mem.Allocator, tbl: *SniTable) void {
    for (tbl.managed) |item| if (tbl.ctxs[item.server.index] != item.ctx) SSL_CTX_free(item.ctx);
    for (tbl.ctxs) |ctx| if (ctx) |value| SSL_CTX_free(value);
    gpa.free(tbl.managed);
    gpa.free(tbl.ctxs);
    gpa.destroy(tbl);
}

pub fn newConn(tbl: *SniTable, fd: c_int) ?*SSL {
    const ssl = SSL_new(tbl.default_ctx) orelse return null;
    if (SSL_set_fd(ssl, fd) != 1) {
        SSL_free(ssl);
        return null;
    }
    return ssl;
}

/// Persistent HTTP/1 connections benefit from tracked reads; handshakes and
/// multiplexed transports retain OpenSSL's ordinary socket BIO path.
pub fn trackReads(ssl: *SSL, read_state: *ReadState) void {
    if (track_read_ready) {
        const bio = SSL_get_rbio(ssl) orelse return;
        BIO_set_callback_arg(bio, read_state);
        BIO_set_callback_ex(bio, socketReadCallback);
    }
}

pub fn hasPending(ssl: *SSL) bool {
    return SSL_has_pending(ssl) != 0;
}

// Linux epoll(7): a short read on a stream socket exhausts read readiness.
// Observe the encrypted socket read, never infer this from SSL_read's decrypted
// byte count. Buffered TLS records must still be drained normally.
fn socketReadCallback(bio: *BIO, operation: c_int, _: ?[*]const u8, requested: usize, _: c_int, _: c_long, result: c_int, processed: ?*usize) callconv(.c) c_long {
    const read_op = 2;
    const return_op = 0x80;
    if (operation & ~@as(c_int, return_op) != read_op) return result;
    const state: *ReadState = @ptrCast(@alignCast(BIO_get_callback_arg(bio) orelse return result));
    if (operation & return_op == 0) {
        if (!state.ready and !state.eof) {
            BIO_clear_flags(bio, 0x0f); // RWS | SHOULD_RETRY
            BIO_set_flags(bio, 0x09); // READ | SHOULD_RETRY
            std.c._errno().* = @backingInt(std.c.E.AGAIN);
            return -1;
        }
    } else if (result > 0) {
        if (processed) |n| if (n.* < requested) {
            state.ready = false;
        };
    } else if (std.c._errno().* == @backingInt(std.c.E.AGAIN)) {
        state.ready = false;
    }
    return result;
}

pub const IoResult = union(enum) { ok: usize, want_read, want_write, eof, err };

/// Batch encrypted records only during a large response. The read BIO stays
/// untouched, and handshake/internal buffering is never wrapped a second time.
pub fn bufferWrites(ssl: *SSL, capacity: usize) ?*BIO {
    const socket = SSL_get_wbio(ssl) orelse return null;
    if (socket != SSL_get_rbio(ssl)) return null;
    const buffer = newWriteBuffer(capacity) orelse return null;
    // SSL_set0_wbio releases its old reference; the chain needs its own.
    if (BIO_up_ref(socket) != 1) {
        _ = BIO_free(buffer);
        return null;
    }
    _ = BIO_push(buffer, socket);
    SSL_set0_wbio(ssl, buffer);
    return buffer;
}

fn newWriteBuffer(capacity: usize) ?*BIO {
    const buffer = (if (aws_lc) zhttpd_aws_buffer_new(capacity) else BIO_new(BIO_f_buffer())) orelse return null;
    var write_only: c_int = 1;
    if (BIO_ctrl(buffer, 117, @intCast(capacity), &write_only) <= 0) { // BIO_C_SET_BUFF_SIZE
        _ = BIO_free(buffer);
        return null;
    }
    return buffer;
}

/// A response is not complete until its ciphertext reached the socket BIO.
pub fn flushWrites(buffer: *BIO) IoResult {
    ERR_clear_error();
    if (BIO_ctrl(buffer, 11, 0, null) > 0) return .{ .ok = 0 }; // BIO_CTRL_FLUSH
    return if (BIO_test_flags(buffer, 8) != 0) .want_write else .err;
}

/// Called only after a successful flush. BIO_pop transfers the chain's socket
/// reference back to SSL; replacing wbio frees the now-detached buffer BIO.
pub fn unbufferWrites(ssl: *SSL, buffer: *BIO) void {
    const socket = BIO_pop(buffer) orelse unreachable;
    SSL_set0_wbio(ssl, socket);
}

pub fn handshake(ssl: *SSL) IoResult {
    // AWS-LC resets its error queue and I/O state on entry to SSL_accept,
    // SSL_read and SSL_write. OpenSSL still requires the caller's clear.
    if (!aws_lc) ERR_clear_error();
    const r = SSL_accept(ssl);
    if (r == 1) return .{ .ok = 0 };
    return classify(ssl, r);
}

pub fn read(ssl: *SSL, buf: []u8) IoResult {
    if (!aws_lc) ERR_clear_error();
    const r = SSL_read(ssl, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))));
    if (r > 0) return .{ .ok = @intCast(r) };
    return classify(ssl, r);
}

pub fn write(ssl: *SSL, buf: []const u8) IoResult {
    if (!aws_lc) ERR_clear_error();
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

test "ciphertext batching preserves bytes through short writes and repeated backpressure" {
    if (!enabled) return error.SkipZigTest;
    defer clearWriteBufferCache();
    const api = struct {
        extern "c" fn BIO_new_bio_pair(*?*BIO, usize, *?*BIO, usize) c_int;
        extern "c" fn BIO_write(*BIO, [*]const u8, c_int) c_int;
        extern "c" fn BIO_read(*BIO, [*]u8, c_int) c_int;
    };
    var socket: ?*BIO = null;
    var peer: ?*BIO = null;
    try std.testing.expectEqual(@as(c_int, 1), api.BIO_new_bio_pair(&socket, 37, &peer, 37));
    defer _ = BIO_free(peer.?);
    defer _ = BIO_free(socket.?);
    const buffer = newWriteBuffer(64 * 1024) orelse return error.OutOfMemory;
    defer _ = BIO_free(buffer);
    _ = BIO_push(buffer, socket.?);
    defer _ = BIO_pop(buffer);

    var expected: [200003]u8 = undefined;
    for (&expected, 0..) |*byte, i| byte.* = @intCast(i % 251);
    var actual: [expected.len]u8 = undefined;
    var sent: usize = 0;
    var received: usize = 0;
    var blocked: usize = 0;
    var flushed = false;
    for (0..20000) |_| {
        if (sent < expected.len) {
            const n = api.BIO_write(buffer, expected[sent..].ptr, @intCast(@min(17011, expected.len - sent)));
            if (n > 0) {
                sent += @intCast(n);
            } else {
                try std.testing.expect(BIO_test_flags(buffer, 8) != 0);
                blocked += 1;
            }
        } else {
            switch (flushWrites(buffer)) {
                .ok => flushed = true,
                .want_write => blocked += 1,
                else => return error.UnexpectedFlushResult,
            }
        }
        if (received < actual.len) {
            const n = api.BIO_read(peer.?, actual[received..].ptr, @intCast(actual.len - received));
            if (n > 0) received += @intCast(n);
        }
        if (flushed and received == expected.len) break;
    }
    try std.testing.expect(flushed);
    try std.testing.expect(blocked > 100);
    try std.testing.expectEqual(expected.len, received);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "TLS operations discard stale errors before nonblocking handshake retries" {
    if (!enabled) return error.SkipZigTest;
    const api = struct {
        extern "c" fn BIO_new_bio_pair(*?*BIO, usize, *?*BIO, usize) c_int;
        extern "c" fn SSL_set_bio(*SSL, *BIO, *BIO) void;
        extern "c" fn SSL_set_accept_state(*SSL) void;
    };
    const ctx = SSL_CTX_new(TLS_server_method()) orelse return error.TlsInit;
    defer SSL_CTX_free(ctx);
    const ssl = SSL_new(ctx) orelse return error.TlsInit;
    defer SSL_free(ssl);
    var socket: ?*BIO = null;
    var peer: ?*BIO = null;
    try std.testing.expectEqual(@as(c_int, 1), api.BIO_new_bio_pair(&socket, 1024, &peer, 1024));
    defer _ = BIO_free(peer.?);
    api.SSL_set_bio(ssl, socket.?, socket.?);
    api.SSL_set_accept_state(ssl);
    var buf: [32]u8 = undefined;
    for (0..3) |operation| {
        // The invalid configuration populates the thread's error queue. The
        // following I/O must classify its own retry, not this unrelated error.
        try std.testing.expectEqual(@as(c_int, 0), SSL_CTX_set_cipher_list(ctx, "not-a-cipher"));
        const result = switch (operation) {
            0 => handshake(ssl),
            1 => read(ssl, &buf),
            else => write(ssl, "hello"),
        };
        try std.testing.expect(result == .want_read);
        try std.testing.expectEqual(@as(c_ulong, 0), ERR_get_error());
    }
}

test {
    _ = @import("password_file.zig");
}
