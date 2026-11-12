//! OpenSSL 3.5+ bindings for the third-party QUIC TLS API
//! (SSL_set_quic_tls_cbs). The SSL object is an ordinary TLS 1.3 server
//! connection from a TLS_server_method context; OpenSSL hands CRYPTO bytes
//! and traffic secrets to the callbacks and never touches packets.
const std = @import("std");

pub const SSL = opaque {};
pub const SSL_CTX = opaque {};
pub const SSL_CIPHER = opaque {};

pub const Dispatch = extern struct {
    function_id: c_int,
    function: ?*const anyopaque,
};

pub const fn_crypto_send = 2001;
pub const fn_crypto_recv_rcd = 2002;
pub const fn_crypto_release_rcd = 2003;
pub const fn_yield_secret = 2004;
pub const fn_got_transport_params = 2005;
pub const fn_alert = 2006;

/// OpenSSL protection levels.
pub const level_none = 0;
pub const level_early = 1;
pub const level_handshake = 2;
pub const level_application = 3;

pub const ssl_error_want_read = 2;
pub const ssl_error_want_write = 3;
pub const ssl_error_want_x509_lookup = 4;
pub const ssl_error_want_client_hello_cb = 11;
pub const ssl_error_want_retry_verify = 12;

pub extern "c" fn SSL_new(ctx: *SSL_CTX) ?*SSL;
pub extern "c" fn SSL_free(s: *SSL) void;
pub extern "c" fn SSL_set_accept_state(s: *SSL) void;
pub extern "c" fn SSL_set_quic_tls_cbs(s: *SSL, qtdis: [*]const Dispatch, arg: ?*anyopaque) c_int;
pub extern "c" fn SSL_set_quic_tls_transport_params(s: *SSL, params: [*]const u8, len: usize) c_int;
pub extern "c" fn SSL_do_handshake(s: *SSL) c_int;
pub extern "c" fn SSL_read(s: *SSL, buf: ?*anyopaque, num: c_int) c_int;
pub extern "c" fn SSL_get_error(s: *const SSL, ret: c_int) c_int;
pub extern "c" fn SSL_get_current_cipher(s: *const SSL) ?*const SSL_CIPHER;
pub extern "c" fn SSL_get_pending_cipher(s: *const SSL) ?*const SSL_CIPHER;
pub extern "c" fn SSL_CIPHER_get_protocol_id(c: *const SSL_CIPHER) u16;
pub extern "c" fn SSL_get0_alpn_selected(s: *const SSL, data: *?[*]const u8, len: *c_uint) void;
pub extern "c" fn SSL_get_servername(s: *const SSL, ty: c_int) ?[*:0]const u8;
pub extern "c" fn SSL_set_ex_data(s: *SSL, idx: c_int, arg: ?*anyopaque) c_int;
pub extern "c" fn SSL_get_ex_data(s: *const SSL, idx: c_int) ?*anyopaque;
pub extern "c" fn ERR_clear_error() void;
pub extern "c" fn RAND_bytes(buf: [*]u8, num: c_int) c_int;

/// Fills `buf` with cryptographically secure random bytes.
pub fn random(buf: []u8) void {
    if (buf.len == 0) return;
    if (RAND_bytes(buf.ptr, @intCast(buf.len)) != 1) @panic("RAND_bytes failed");
}

/// Cipher suite of the handshake in progress (pending during key changes).
pub fn suiteId(s: *const SSL) ?u16 {
    const c = SSL_get_pending_cipher(s) orelse SSL_get_current_cipher(s) orelse return null;
    return SSL_CIPHER_get_protocol_id(c);
}

pub fn alpn(s: *const SSL) []const u8 {
    var p: ?[*]const u8 = null;
    var n: c_uint = 0;
    SSL_get0_alpn_selected(s, &p, &n);
    return if (p) |ptr| ptr[0..n] else &.{};
}
