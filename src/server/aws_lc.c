/* AWS-LC's public, typed API replaces OpenSSL's legacy SSL_CTX_ctrl macros.
 * Keep OpenSSL numeric constants out of calls into AWS-LC. */
#include <openssl/ssl.h>
#include <openssl/mem.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if !defined(OPENSSL_IS_AWSLC)
#error "-Dtls-backend=aws_lc requires AWS-LC headers and libraries"
#endif

long zhttpd_aws_ctx_ctrl(SSL_CTX *ctx, int cmd, long arg, void *ptr) {
    switch (cmd) {
    case 33: /* RELEASE_BUFFERS and AUTO_RETRY are always enabled in AWS-LC. */
        return SSL_CTX_set_mode(ctx,
            (arg & 1 ? SSL_MODE_ENABLE_PARTIAL_WRITE : 0) |
            (arg & 2 ? SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER : 0) |
            (arg & 8 ? SSL_MODE_NO_AUTO_CHAIN : 0));
    case 41: return SSL_CTX_set_read_ahead(ctx, arg != 0);
    case 42: return SSL_CTX_sess_set_cache_size(ctx, (unsigned long)arg);
    case 44: return SSL_CTX_set_session_cache_mode(ctx,
        arg == 2 ? SSL_SESS_CACHE_SERVER : SSL_SESS_CACHE_OFF);
    case 54: return SSL_CTX_set_tlsext_servername_arg(ctx, ptr);
    case 92: return SSL_CTX_set1_groups_list(ctx, ptr);
    case 123: return SSL_CTX_set_min_proto_version(ctx, (uint16_t)arg);
    case 124: return SSL_CTX_set_max_proto_version(ctx, (uint16_t)arg);
    default: return 0;
    }
}

long zhttpd_aws_ctx_callback_ctrl(SSL_CTX *ctx, int cmd, void (*cb)(void)) {
    if (cmd != 53) return 0;
    return SSL_CTX_set_tlsext_servername_callback(ctx, (int (*)(SSL *, int *, void *))cb);
}

uint64_t zhttpd_aws_ctx_options(SSL_CTX *ctx, uint64_t options) {
    uint32_t translated = SSL_OP_NO_RENEGOTIATION;
    if (options & (UINT64_C(1) << 14)) translated |= SSL_OP_NO_TICKET;
    if (options & (UINT64_C(1) << 22)) translated |= SSL_OP_CIPHER_SERVER_PREFERENCE;
    return SSL_CTX_set_options(ctx, translated);
}

long zhttpd_aws_ctx_timeout(SSL_CTX *ctx, long seconds) {
    return SSL_CTX_set_timeout(ctx, (uint32_t)seconds);
}

unsigned long zhttpd_aws_error(void) { return ERR_get_error(); }
void zhttpd_aws_error_string(unsigned long code, char *buffer, size_t length) {
    ERR_error_string_n((uint32_t)code, buffer, length);
}

int zhttpd_aws_set_fd(SSL *ssl, int fd) {
    /* On POSIX, sockets are descriptors. AWS-LC's socket BIO queries and clears
     * SO_ERROR before every read/write. The fd BIO uses the same nonblocking
     * read/write calls and retry flags, and lets those calls report errors.
     * Conn remains the descriptor owner, as with SSL_set_fd. */
    BIO *bio = BIO_new_fd(fd, BIO_NOCLOSE);
    if (!bio) return 0;
    SSL_set_bio(ssl, bio, bio);
    return 1;
}

int zhttpd_aws_prepare_tickets(SSL_CTX *ctx) {
    /* AWS-LC initializes its default ticket keys lazily. Prime them before
     * worker fork so initial resumption works across workers. Keep the
     * library's automatic rotation enabled; never replace it with fixed keys. */
    unsigned char material[48];
    int result = SSL_CTX_get_tlsext_ticket_keys(ctx, material, sizeof(material));
    OPENSSL_cleanse(material, sizeof(material));
    return result;
}

/* AWS-LC has no BIO_f_buffer. This bounded, write-only filter batches TLS
 * ciphertext while preserving short writes, EAGAIN and explicit final flush.
 * It never reads from or takes ownership of the socket outside the BIO chain. */
struct write_buffer {
    size_t first, end, capacity, allocation_capacity;
    _Alignas(16) unsigned char bytes[];
};
static _Thread_local struct write_buffer *idle_buffer;

void zhttpd_aws_buffer_cache_clear(void) {
    free(idle_buffer);
    idle_buffer = NULL;
}

static int buffer_create(BIO *bio) {
    BIO_set_init(bio, 1);
    return 1;
}

static int buffer_destroy(BIO *bio) {
    struct write_buffer *state = BIO_get_data(bio);
    // Bound retained storage independently of connection count and body size.
    if (state && state->allocation_capacity <= 192 * 1024 &&
        (!idle_buffer || idle_buffer->allocation_capacity < state->allocation_capacity)) {
        free(idle_buffer);
        idle_buffer = state;
    } else {
        free(state);
    }
    BIO_set_data(bio, NULL);
    BIO_set_init(bio, 0);
    return 1;
}

static int buffer_drain(BIO *bio) {
    struct write_buffer *state = BIO_get_data(bio);
    BIO *next = BIO_next(bio);
    BIO_clear_retry_flags(bio);
    if (!next) return -1;
    while (state->first < state->end) {
        int n = BIO_write(next, state->bytes + state->first,
                          (int)(state->end - state->first));
        if (n <= 0) {
            BIO_copy_next_retry(bio);
            return n;
        }
        state->first += (size_t)n;
    }
    state->first = state->end = 0;
    return 1;
}

static int buffer_write(BIO *bio, const char *data, int length) {
    struct write_buffer *state = BIO_get_data(bio);
    int consumed = 0;
    BIO_clear_retry_flags(bio);
    while (consumed < length) {
        if (state->end == state->capacity) {
            int result = buffer_drain(bio);
            if (result <= 0) return consumed ? consumed : result;
        }
        size_t n = (size_t)(length - consumed);
        if (n > state->capacity - state->end) n = state->capacity - state->end;
        memcpy(state->bytes + state->end, data + consumed, n);
        state->end += n;
        consumed += (int)n;
    }
    return consumed;
}

static long buffer_ctrl(BIO *bio, int cmd, long arg, void *ptr) {
    struct write_buffer *state = BIO_get_data(bio);
    switch (cmd) {
    case BIO_CTRL_FLUSH: {
        int result = buffer_drain(bio);
        if (result <= 0) return result;
        result = BIO_flush(BIO_next(bio));
        BIO_copy_next_retry(bio);
        return result;
    }
    case BIO_C_SET_BUFF_SIZE:
        return arg > 0 && (size_t)arg == state->capacity && ptr && *(int *)ptr == 1;
    case BIO_CTRL_WPENDING: return (long)(state->end - state->first);
    case BIO_CTRL_PENDING: return 0;
    case BIO_CTRL_PUSH:
    case BIO_CTRL_POP: return 1;
    default:
        return BIO_next(bio) ? BIO_ctrl(BIO_next(bio), cmd, arg, ptr) : 0;
    }
}

static pthread_once_t buffer_once = PTHREAD_ONCE_INIT;
static BIO_METHOD *buffer_method;

static void buffer_method_init(void) {
    BIO_METHOD *method = BIO_meth_new(BIO_TYPE_FILTER, "zhttpd ciphertext buffer");
    if (!method) return;
    if (!BIO_meth_set_create(method, buffer_create) ||
        !BIO_meth_set_destroy(method, buffer_destroy) ||
        !BIO_meth_set_write(method, buffer_write) ||
        !BIO_meth_set_ctrl(method, buffer_ctrl)) {
        BIO_meth_free(method);
        return;
    }
    buffer_method = method; /* One immutable method for the process lifetime. */
}

BIO *zhttpd_aws_buffer_new(size_t capacity) {
    if (!capacity || capacity > INT_MAX - sizeof(struct write_buffer)) return NULL;
    if (pthread_once(&buffer_once, buffer_method_init) != 0) return NULL;
    if (!buffer_method) return NULL;
    BIO *bio = BIO_new(buffer_method);
    if (!bio) return NULL;
    /* Only ciphertext lives here. Like AWS-LC's own record buffers, use malloc
     * without clearing the entire capacity on allocation and release. Every
     * byte in [first, end) is initialized by buffer_write before it is sent. */
    struct write_buffer *state;
    if (idle_buffer && idle_buffer->allocation_capacity >= capacity) {
        state = idle_buffer;
        idle_buffer = NULL;
    } else {
        state = malloc(sizeof(*state) + capacity);
        if (state) state->allocation_capacity = capacity;
    }
    if (!state) {
        BIO_free(bio);
        return NULL;
    }
    state->first = state->end = 0;
    state->capacity = capacity;
    BIO_set_data(bio, state);
    return bio;
}
