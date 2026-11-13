/* Userspace TLS 1.3 record protection for HTTP/2 output.
 *
 * OpenSSL's kTLS record layer hands application-level write keys to the
 * write BIO (BIO_CTRL_SET_KTLS) and then passes plaintext records straight
 * from the caller's buffer. This BIO accepts those keys instead of the
 * kernel: it seals each record directly into a pooled batch buffer and
 * writes batches to the socket. That removes OpenSSL's plaintext copy into
 * its record buffer and the copy into a separate buffering BIO.
 *
 * OpenSSL still owns the handshake, the read direction, alerts, session
 * tickets and KeyUpdate. A TX KeyUpdate installs new keys through the same
 * control. Read keys are always refused, so decryption stays in OpenSSL and
 * the kernel never sees a TLS ULP. Unsupported ciphers, TLS 1.2 or a failed
 * flush make OpenSSL fall back to its ordinary record layer; this BIO then
 * forwards ciphertext unchanged, behind any bytes it still holds.
 */
#include <openssl/ssl.h>
#include <openssl/bio.h>
#include <openssl/evp.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__linux__) && !defined(OPENSSL_NO_KTLS)
#include <linux/tls.h>
#include <sys/socket.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Internal OpenSSL controls (crypto/bio/bio_local.h), stable across 3.x. */
#define TX_CTRL_SET_KTLS 72
#define TX_CTRL_SET_CTRL_MSG 74
#define TX_CTRL_CLEAR_CTRL_MSG 75
#define TX_CTRL_ZEROCOPY_SENDFILE 90

#define RECORD_PLAIN_MAX 16384
#define RECORD_OVERHEAD (5 + 1 + 16)
/* Six full records per write: the batch size measured for the previous
 * buffering BIO, without its extra copy. */
#define BATCH_CAP (6 * (RECORD_PLAIN_MAX + RECORD_OVERHEAD))
#define POOL_MAX 4

/* Mirrors OpenSSL's ktls_crypto_info_t union prefix for Linux. */
typedef union {
    struct tls_crypto_info info;
    struct tls12_crypto_info_aes_gcm_128 gcm128;
    struct tls12_crypto_info_aes_gcm_256 gcm256;
    struct tls12_crypto_info_chacha20_poly1305 chacha;
} crypto_info;

typedef struct tx {
    SSL *ssl;
    int fd, sealing, eof;
    unsigned char record_type; /* one-shot control record type, 0 = data */
    EVP_CIPHER_CTX *aead;
    uint8_t iv[12];
    uint64_t seq;
    uint8_t *batch;
    size_t pos, len;
} tx;

static int tx_type = -1;
static _Thread_local uint8_t *pool[POOL_MAX];
static _Thread_local unsigned pooled;

static uint8_t *take_batch(void) {
    return pooled ? pool[--pooled] : malloc(BATCH_CAP);
}
static void give_batch(tx *t) {
    if (!t->batch) return;
    if (pooled < POOL_MAX) pool[pooled++] = t->batch;
    else free(t->batch);
    t->batch = NULL; t->pos = t->len = 0;
}

/* Write held bytes. 1 = empty, 0 = would block, -1 = error. */
static int drain(BIO *b, tx *t) {
    while (t->pos < t->len) {
        ssize_t n = send(t->fd, t->batch + t->pos, t->len - t->pos, MSG_NOSIGNAL);
        if (n > 0) { t->pos += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            BIO_set_retry_write(b);
            return 0;
        }
        return -1;
    }
    give_batch(t);
    return 1;
}

/* Make room for n bytes at the end of the batch. */
static int reserve(BIO *b, tx *t, size_t n) {
    if (!t->batch) {
        if (!(t->batch = take_batch())) return -1;
        t->pos = t->len = 0;
    }
    if (BATCH_CAP - t->len >= n) return 1;
    int r = drain(b, t);
    if (r < 0) return -1;
    if (r > 0) {
        if (!(t->batch = take_batch())) return -1;
        t->pos = t->len = 0;
        return 1;
    }
    if (t->pos) {
        memmove(t->batch, t->batch + t->pos, t->len - t->pos);
        t->len -= t->pos; t->pos = 0;
    }
    return BATCH_CAP - t->len >= n ? 1 : 0;
}

static int seal2(tx *t, const uint8_t *head, size_t hn, const uint8_t *in, size_t n, uint8_t type) {
    uint8_t *out = t->batch + t->len, nonce[12];
    size_t body = hn + n + 1 + 16;
    out[0] = SSL3_RT_APPLICATION_DATA; out[1] = 3; out[2] = 3;
    out[3] = (uint8_t)(body >> 8); out[4] = (uint8_t)body;
    memcpy(nonce, t->iv, 12);
    for (int i = 0; i < 8; ++i) nonce[4 + i] ^= (uint8_t)(t->seq >> (56 - 8 * i));
    int l = 0;
    if (EVP_EncryptInit_ex(t->aead, NULL, NULL, NULL, nonce) != 1 ||
        EVP_EncryptUpdate(t->aead, NULL, &l, out, 5) != 1) return 0;
    if (hn && EVP_EncryptUpdate(t->aead, out + 5, &l, head, (int)hn) != 1) return 0;
    out += hn;
    if (n && EVP_EncryptUpdate(t->aead, out + 5, &l, in, (int)n) != 1) return 0;
    if (EVP_EncryptUpdate(t->aead, out + 5 + n, &l, &type, 1) != 1 ||
        EVP_EncryptFinal_ex(t->aead, out + 6 + n, &l) != 1 ||
        EVP_CIPHER_CTX_ctrl(t->aead, EVP_CTRL_AEAD_GET_TAG, 16, out + 6 + n) != 1) return 0;
    ++t->seq;
    t->len += 5 + body;
    return 1;
}

static int tx_write(BIO *b, const char *data, int size) {
    tx *t = BIO_get_data(b);
    BIO_clear_retry_flags(b);
    if (size < 0) return -1;
    size_t n = (size_t)size;
    if (t->sealing) {
        /* OpenSSL passes exactly one record and retries it unchanged. */
        if (n > RECORD_PLAIN_MAX) return -1;
        int r = reserve(b, t, n + RECORD_OVERHEAD);
        if (r <= 0) return -1;
        uint8_t type = t->record_type ? t->record_type : SSL3_RT_APPLICATION_DATA;
        if (!seal2(t, NULL, 0, (const uint8_t *)data, n, type)) return -1;
        t->record_type = 0;
        return size;
    }
    /* Ciphertext from OpenSSL's own record layer (handshake or fallback)
     * must follow any sealed bytes that are still held. */
    if (t->batch) {
        int r = drain(b, t);
        if (r < 0) return -1;
        if (r == 0) {
            if (t->pos) {
                memmove(t->batch, t->batch + t->pos, t->len - t->pos);
                t->len -= t->pos; t->pos = 0;
            }
            if (BATCH_CAP - t->len < n) return -1; /* retry flag already set */
            BIO_clear_retry_flags(b);
            memcpy(t->batch + t->len, data, n); t->len += n;
            return size;
        }
    }
    for (;;) {
        ssize_t w = send(t->fd, data, n, MSG_NOSIGNAL);
        if (w >= 0) return (int)w;
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) BIO_set_retry_write(b);
        return -1;
    }
}

static int tx_read(BIO *b, char *out, int size) {
    tx *t = BIO_get_data(b);
    BIO_clear_retry_flags(b);
    if (size <= 0) return 0;
    for (;;) {
        ssize_t n = read(t->fd, out, (size_t)size);
        if (n > 0) return (int)n;
        if (n == 0) { t->eof = 1; return 0; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) BIO_set_retry_read(b);
        return -1;
    }
}

static int set_keys(tx *t, const crypto_info *ci) {
    const EVP_CIPHER *cipher; const uint8_t *key; uint8_t iv[12]; const uint8_t *seq;
    /* A refusal makes OpenSSL encrypt in software from now on: pass its
     * ciphertext through instead of sealing it again with retired keys. */
    t->sealing = 0;
    if (ci->info.version != TLS_1_3_VERSION) return 0;
    switch (ci->info.cipher_type) {
    case TLS_CIPHER_AES_GCM_128:
        cipher = EVP_aes_128_gcm(); key = ci->gcm128.key; seq = ci->gcm128.rec_seq;
        memcpy(iv, ci->gcm128.salt, 4); memcpy(iv + 4, ci->gcm128.iv, 8);
        break;
    case TLS_CIPHER_AES_GCM_256:
        cipher = EVP_aes_256_gcm(); key = ci->gcm256.key; seq = ci->gcm256.rec_seq;
        memcpy(iv, ci->gcm256.salt, 4); memcpy(iv + 4, ci->gcm256.iv, 8);
        break;
    case TLS_CIPHER_CHACHA20_POLY1305:
        cipher = EVP_chacha20_poly1305(); key = ci->chacha.key; seq = ci->chacha.rec_seq;
        memcpy(iv, ci->chacha.iv, 12);
        break;
    default:
        return 0;
    }
    if (!t->aead && !(t->aead = EVP_CIPHER_CTX_new())) return 0;
    if (EVP_EncryptInit_ex(t->aead, cipher, NULL, key, NULL) != 1) return 0;
    memcpy(t->iv, iv, 12);
    t->seq = 0;
    for (int i = 0; i < 8; ++i) t->seq = t->seq << 8 | seq[i];
    t->sealing = 1; t->record_type = 0;
    return 1;
}

static long tx_ctrl(BIO *b, int cmd, long num, void *ptr) {
    tx *t = BIO_get_data(b);
    switch (cmd) {
    case BIO_CTRL_FLUSH: {
        BIO_clear_retry_flags(b);
        if (!t->batch) return 1;
        int r = drain(b, t);
        /* OpenSSL flushes before a key change and before a control record,
         * and silently falls back to software encryption if that fails.
         * Sealed records are already queued in order, so a full socket
         * does not stop either: report success and keep the bytes. */
        if (r == 0 && t->sealing) { BIO_clear_retry_flags(b); return 1; }
        return r > 0 ? 1 : r == 0 ? 0 : -1;
    }
    case BIO_CTRL_WPENDING: return t->batch ? (long)(t->len - t->pos) : 0;
    case BIO_CTRL_PENDING: return 0;
    case BIO_CTRL_EOF: return t->eof;
    case BIO_C_GET_FD:
        if (ptr) *(int *)ptr = t->fd;
        return t->fd;
    case BIO_CTRL_GET_CLOSE: return BIO_NOCLOSE;
    case BIO_CTRL_SET_CLOSE: case BIO_CTRL_DUP: return 1;
    case TX_CTRL_SET_KTLS: {
        /* num is 1 for the write direction. OpenSSL flushed us first.
         * SSL_OP_ENABLE_KTLS also makes OpenSSL try the kTLS method for the
         * read direction. When that is refused, OpenSSL 3.5 retries the
         * default method without the bytes the old read layer had read
         * ahead, so records following the peer's Finished or KeyUpdate are
         * lost (bad_record_mac). Keep the option only around write-key
         * changes: zhttp_tx_prepare_write sets it again for a KeyUpdate. */
        SSL_clear_options(t->ssl, SSL_OP_ENABLE_KTLS);
        if (num != 1 || !ptr) return 0;
        return set_keys(t, ptr);
    }
    case BIO_CTRL_GET_KTLS_SEND: return t->sealing;
    case BIO_CTRL_GET_KTLS_RECV: return 0;
    case TX_CTRL_SET_CTRL_MSG: t->record_type = (unsigned char)num; return 1;
    case TX_CTRL_CLEAR_CTRL_MSG: t->record_type = 0; return 1;
    case TX_CTRL_ZEROCOPY_SENDFILE: return 0;
    default: return 0;
    }
}

static int tx_create(BIO *b) { BIO_set_init(b, 0); BIO_set_data(b, NULL); return 1; }
static int tx_destroy(BIO *b) {
    tx *t = BIO_get_data(b);
    if (t) {
        give_batch(t);
        EVP_CIPHER_CTX_free(t->aead);
        free(t);
    }
    BIO_set_data(b, NULL);
    return 1;
}

static BIO_METHOD *tx_meth;
static pthread_once_t tx_once = PTHREAD_ONCE_INIT;
static void init_method(void) {
    int index = BIO_get_new_index();
    if (index < 0) return;
    int type = index | BIO_TYPE_SOURCE_SINK | BIO_TYPE_DESCRIPTOR;
    BIO_METHOD *m = BIO_meth_new(type, "zhttpd tls tx");
    if (!m || !BIO_meth_set_write(m, tx_write) || !BIO_meth_set_read(m, tx_read) ||
        !BIO_meth_set_ctrl(m, tx_ctrl) || !BIO_meth_set_create(m, tx_create) ||
        !BIO_meth_set_destroy(m, tx_destroy)) {
        BIO_meth_free(m); return;
    }
    tx_type = type; tx_meth = m;
}
static BIO_METHOD *method(void) {
    /* Worker threads attach connections concurrently. */
    pthread_once(&tx_once, init_method);
    return tx_meth;
}

/* Called from ALPN selection, before any application keys exist. */
int zhttp_tx_attach(SSL *ssl) {
    int fd = SSL_get_fd(ssl);
    BIO *old = SSL_get_wbio(ssl);
    if (fd < 0 || !old || old != SSL_get_rbio(ssl) || BIO_method_type(old) != BIO_TYPE_SOCKET) return 0;
    /* OpenSSL refuses kTLS for a reduced record size before it reaches the
     * BIO, which would leave SSL_OP_ENABLE_KTLS set for the read keys. */
    SSL_SESSION *session = SSL_get_session(ssl);
    if (!session || SSL_SESSION_get_max_fragment_length(session) != TLSEXT_max_fragment_length_DISABLED) return 0;
    BIO_METHOD *m = method();
    if (!m) return 0;
    tx *t = calloc(1, sizeof(*t));
    BIO *b = t ? BIO_new(m) : NULL;
    if (!b) { free(t); return 0; }
    t->fd = fd; t->ssl = ssl;
    BIO_set_data(b, t); BIO_set_init(b, 1);
    SSL_set_bio(ssl, b, b);
    SSL_set_options(ssl, SSL_OP_ENABLE_KTLS);
    return 1;
}

int zhttp_tx_attached(SSL *ssl);
/* Before SSL_write: OpenSSL sends a pending KeyUpdate from it and then
 * installs new write keys, which must reach this BIO (see SET_KTLS). */
void zhttp_tx_prepare_write(SSL *ssl) {
    if (SSL_get_key_update_type(ssl) != SSL_KEY_UPDATE_NONE && zhttp_tx_attached(ssl))
        SSL_set_options(ssl, SSL_OP_ENABLE_KTLS);
}

/* A file mapping can lose its pages when the file is truncated. Only the
 * sealing call below reads mapped bytes; a SIGBUS raised there abandons that
 * record before the batch length or sequence number advance. Any other
 * SIGBUS is passed to the previous disposition. */
static struct sigaction previous_bus;
static _Thread_local sigjmp_buf *bus_guard;
static void on_bus(int sig, siginfo_t *info, void *ctx) {
    sigjmp_buf *guard = bus_guard;
    if (guard) { bus_guard = NULL; siglongjmp(*guard, 1); }
    if (previous_bus.sa_flags & SA_SIGINFO) {
        if (previous_bus.sa_sigaction) { previous_bus.sa_sigaction(sig, info, ctx); return; }
    } else if (previous_bus.sa_handler != SIG_DFL && previous_bus.sa_handler != SIG_IGN) {
        previous_bus.sa_handler(sig); return;
    }
    signal(SIGBUS, SIG_DFL);
    raise(SIGBUS);
}
static int bus_ready;
static pthread_once_t bus_once = PTHREAD_ONCE_INIT;
static void init_bus(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = on_bus;
    /* NODEFER: siglongjmp leaves the handler without restoring a mask. */
    sa.sa_flags = SA_SIGINFO | SA_NODEFER | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    bus_ready = sigaction(SIGBUS, &sa, &previous_bus) == 0;
}

/* Ready for zhttp_tx_seal_frame: sealing, no control record selected and no
 * KeyUpdate waiting to be sent ahead of application data (RFC 8446 4.6.3). */
int zhttp_tx_ready(SSL *ssl) {
    BIO *b = SSL_get_wbio(ssl);
    if (!b || tx_type < 0 || BIO_method_type(b) != tx_type) return 0;
    tx *t = BIO_get_data(b);
    if (!t || !t->sealing || t->record_type || SSL_get_key_update_type(ssl) != SSL_KEY_UPDATE_NONE
        || (SSL_get_shutdown(ssl) & SSL_SENT_SHUTDOWN)) return 0;
    pthread_once(&bus_once, init_bus);
    return bus_ready;
}

/* Seal head||data as one application-data record without copying data.
 * 1 sealed, 0 would block, -1 error, -2 the source mapping faulted. The
 * caller must have nothing queued in OpenSSL (no pending SSL_write). */
int zhttp_tx_seal_frame(SSL *ssl, const uint8_t *head, size_t hn, const uint8_t *data, size_t n) {
    BIO *b = SSL_get_wbio(ssl);
    tx *t = BIO_get_data(b);
    BIO_clear_retry_flags(b);
    if (hn + n > RECORD_PLAIN_MAX) return -1;
    int r = reserve(b, t, hn + n + RECORD_OVERHEAD);
    if (r <= 0) return r;
    sigjmp_buf guard;
    if (sigsetjmp(guard, 0)) return -2;
    bus_guard = &guard;
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
    r = seal2(t, head, hn, data, n, SSL3_RT_APPLICATION_DATA);
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
    bus_guard = NULL;
    return r ? 1 : -1;
}

/* True when this BIO is the connection's write BIO. Nothing may be pushed
 * above it: records must arrive one per write while sealing. */
int zhttp_tx_attached(SSL *ssl) {
    BIO *b = SSL_get_wbio(ssl);
    return b && tx_type >= 0 && BIO_method_type(b) == tx_type;
}
#else
int zhttp_tx_attach(SSL *ssl) { (void)ssl; return 0; }
int zhttp_tx_attached(SSL *ssl) { (void)ssl; return 0; }
int zhttp_tx_ready(SSL *ssl) { (void)ssl; return 0; }
void zhttp_tx_prepare_write(SSL *ssl) { (void)ssl; }
int zhttp_tx_seal_frame(SSL *ssl, const uint8_t *head, size_t hn, const uint8_t *data, size_t n) {
    (void)ssl; (void)head; (void)hn; (void)data; (void)n; return -1;
}
#endif
