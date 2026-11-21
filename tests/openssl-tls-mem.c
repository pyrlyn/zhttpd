/* Checks the installed OpenSSL archive for zhttpd's TLS memory patches:
 * deps/patches/openssl-tls13-free-key-shares.patch (a TLS 1.3 server drops
 * both key shares once the handshake secret is derived) and
 * deps/patches/openssl-single-pipeline.patch (SSL_MAX_PIPELINES is 1). */
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <stdio.h>
#include <string.h>

#if SSL_MAX_PIPELINES != 1
#error "openssl-single-pipeline.patch is not applied"
#endif

static EVP_PKEY *key;
static X509 *cert;

static int fail(const char *what) {
    fprintf(stderr, "openssl-tls-mem: %s\n", what);
    ERR_print_errors_fp(stderr);
    return 0;
}

static int make_cert(void) {
    key = EVP_EC_gen("P-256");
    cert = X509_new();
    if (key == NULL || cert == NULL) return 0;
    ASN1_INTEGER_set(X509_get_serialNumber(cert), 1);
    X509_gmtime_adj(X509_getm_notBefore(cert), 0);
    X509_gmtime_adj(X509_getm_notAfter(cert), 3600);
    X509_NAME_add_entry_by_txt(X509_get_subject_name(cert), "CN", MBSTRING_ASC,
        (const unsigned char *)"localhost", -1, -1, 0);
    X509_set_issuer_name(cert, X509_get_subject_name(cert));
    return X509_set_pubkey(cert, key) && X509_sign(cert, key, EVP_sha256()) > 0;
}

static void pump(BIO *from, BIO *to) {
    char buf[16384];
    int n;
    while ((n = BIO_read(from, buf, sizeof buf)) > 0) BIO_write(to, buf, n);
}

/* Move app data larger than one record each way, read in small pieces. */
static int transfer(SSL *from, BIO *from_w, SSL *to, BIO *to_r) {
    static unsigned char out[65536], in[65536];
    size_t got = 0;
    for (size_t i = 0; i < sizeof out; i++) out[i] = (unsigned char)(i * 31);
    if (SSL_write(from, out, sizeof out) != (int)sizeof out) return 0;
    pump(from_w, to_r);
    while (got < sizeof in) {
        int n = SSL_read(to, in + got, 1000);
        if (n <= 0) return 0;
        got += (size_t)n;
    }
    return memcmp(in, out, sizeof out) == 0;
}

static int run(const char *name, int version, const char *client_groups,
    const char *server_groups, const char *want_group) {
    SSL_CTX *sctx = SSL_CTX_new(TLS_server_method());
    SSL_CTX *cctx = SSL_CTX_new(TLS_client_method());
    SSL *s = NULL, *c = NULL;
    BIO *sr, *sw, *cr, *cw;
    EVP_PKEY *tmp = NULL;
    int ok = 0;
    char msg[160];

    if (sctx == NULL || cctx == NULL) goto done;
    SSL_CTX_set_mode(sctx, SSL_MODE_RELEASE_BUFFERS);
    if (!SSL_CTX_use_certificate(sctx, cert) || !SSL_CTX_use_PrivateKey(sctx, key)
        || !SSL_CTX_set_min_proto_version(sctx, TLS1_2_VERSION)
        || !SSL_CTX_set_min_proto_version(cctx, TLS1_2_VERSION)
        || !SSL_CTX_set_max_proto_version(sctx, version)
        || (client_groups && !SSL_CTX_set1_groups_list(cctx, client_groups))
        || (server_groups && !SSL_CTX_set1_groups_list(sctx, server_groups)))
        goto done;
    /* The library must reject pipelines it no longer has room for. */
    if (SSL_CTX_set_max_pipelines(sctx, 2)) {
        fail("SSL_CTX_set_max_pipelines(2) succeeded: libssl built with SSL_MAX_PIPELINES > 1");
        goto done;
    }
    s = SSL_new(sctx);
    c = SSL_new(cctx);
    sr = BIO_new(BIO_s_mem()); sw = BIO_new(BIO_s_mem());
    cr = BIO_new(BIO_s_mem()); cw = BIO_new(BIO_s_mem());
    if (s == NULL || c == NULL || !sr || !sw || !cr || !cw) goto done;
    SSL_set_bio(s, sr, sw);
    SSL_set_bio(c, cr, cw);
    SSL_set_accept_state(s);
    SSL_set_connect_state(c);
    for (int i = 0; i < 20 && !(SSL_is_init_finished(s) && SSL_is_init_finished(c)); i++) {
        SSL_do_handshake(c); pump(cw, sr);
        SSL_do_handshake(s); pump(sw, cr);
    }
    snprintf(msg, sizeof msg, "%s: handshake failed", name);
    if (!SSL_is_init_finished(s) || !SSL_is_init_finished(c)) { fail(msg); goto done; }
    snprintf(msg, sizeof msg, "%s: negotiated %s", name, SSL_get_version(s));
    if (SSL_version(s) != version) { fail(msg); goto done; }
    snprintf(msg, sizeof msg, "%s: negotiated %s, want %s", name,
        SSL_group_to_name(s, SSL_get_negotiated_group(s)), want_group);
    if (strcmp(SSL_group_to_name(s, SSL_get_negotiated_group(s)), want_group) != 0) {
        fail(msg);
        goto done;
    }
    if (version == TLS1_3_VERSION) {
        snprintf(msg, sizeof msg, "%s: server kept the peer key share", name);
        if (SSL_get_peer_tmp_key(s, &tmp)) { fail(msg); goto done; }
        snprintf(msg, sizeof msg, "%s: server kept its own key share", name);
        if (SSL_get_tmp_key(s, &tmp)) { fail(msg); goto done; }
    }
    snprintf(msg, sizeof msg, "%s: application data mismatch", name);
    if (!transfer(c, cw, s, sr) || !transfer(s, sw, c, cr)) { fail(msg); goto done; }
    ok = 1;
done:
    EVP_PKEY_free(tmp);
    SSL_free(s);
    SSL_free(c);
    SSL_CTX_free(sctx);
    SSL_CTX_free(cctx);
    return ok;
}

int main(void) {
    if (!make_cert()) return fail("certificate"), 1;
    int ok = run("ML-KEM hybrid", TLS1_3_VERSION, NULL, NULL, "X25519MLKEM768")
        && run("X25519", TLS1_3_VERSION, "X25519", NULL, "x25519")
        /* The client's only key share is X25519; the server asks again. */
        && run("HelloRetryRequest", TLS1_3_VERSION, "X25519:P-256", "P-256", "secp256r1")
        && run("TLS 1.2 ECDHE", TLS1_2_VERSION, NULL, NULL, "x25519");
    X509_free(cert);
    EVP_PKEY_free(key);
    if (ok)
        printf("PASS: TLS 1.3 server releases key shares; one record pipeline\n");
    return ok ? 0 : 1;
}
