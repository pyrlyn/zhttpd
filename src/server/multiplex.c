/* HTTP/2 and HTTP/3 codecs. Each request uses bounded memory buffers
 * to the existing Zig request engine. No internal socket or listener is needed.
 * OpenSSL owns QUIC retransmission/congestion control; nghttp owns HPACK/QPACK.
 */
#ifdef __APPLE__
#define __APPLE_USE_RFC_3542
#endif
#include <nghttp2/nghttp2.h>
#include <nghttp3/nghttp3.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/rand.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>
#include "quic_output.h"

#define STREAMS 32
#define INPUT_CAP (64 * 1024)
#define H2_OUTPUT_CAP (16 * 1024)
/* Two DATA payloads plus their 9-byte frame headers fill two TLS records. */
#define OUTPUT_CAP (2 * (H2_OUTPUT_CAP - 9))
#define FILE_OUTPUT_CAP (8 * (H2_OUTPUT_CAP - 9))
#define OUTPUT_CACHE_CAP (STREAMS * OUTPUT_CAP)
#define HEAD_CAP (14 * 1024)
typedef void *(*open_request)(void *, void *, const struct sockaddr *, const struct sockaddr *, int);
typedef void (*drive_request)(void *);
typedef void (*close_request)(void *);
typedef struct session session;
typedef struct stream stream;
struct stream {
    stream *next;
    session *owner;
    int64_t id;
    SSL *quic;
    void *request;
    int started, request_end, chunked, eof, submitted, closed, read_fin, write_fin;
    char *headers;
    size_t headers_len, header_count;
    uint8_t *input, *output;
    size_t input_len, input_pos, output_len, output_pos, output_cap, credit, offered;
    char method[32], path[8193], authority[1024], content_length[32];
};
struct session {
    session *next;
    SSL *ssl;
    nghttp2_session *h2;
    nghttp3_conn *h3;
    uint8_t *h2_output;
    size_t h2_output_len, h2_output_pos;
    int h2_write_blocked;
    BIO *h2_buffer;
    stream *streams;
    unsigned nstreams;
    uint64_t completed_bidi;
    void *user;
    open_request open;
    drive_request drive;
    close_request close;
    struct sockaddr_storage peer, local;
    int activity, shutting_down;
};
typedef struct listener {
    SSL *ssl;
    session *sessions;
    void *user;
    open_request open;
    drive_request drive;
    close_request close;
    int fd;
    unsigned limit, admitted;
    struct sockaddr_storage peer, local, bound;
    BIO_ADDR *peer_addr, *local_addr;
    quic_output output;
} listener;
typedef struct peer_info {
    struct sockaddr_storage peer, local;
    listener *owner;
} peer_info;
static int peer_index = -1;
/* One bounded cache per event-loop thread, shared across its connections.
 * Release it when the final session closes; idle connections cannot retain a
 * separate cache each. Active stream buffers still follow STREAMS limits. */
static _Thread_local stream *stream_cache;
static _Thread_local unsigned cached_streams, active_sessions;
static _Thread_local size_t cached_output_bytes;
#ifdef __linux__
static _Thread_local unsigned quic_listeners;
#endif

static void free_stream(stream *p) {
    free(p->headers); free(p->input); free(p->output); free(p);
}

static int ssl_wait(SSL *ssl, int r) {
    int e = SSL_get_error(ssl, r);
    return e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE;
}
static stream *lookup(session *s, int64_t id) {
    for (stream *p = s->streams; p; p = p->next) if (p->id == id) return p;
    return NULL;
}
static stream *h3_stream(void *user, int64_t id, void *stream_user) {
    return stream_user ? stream_user : lookup(user, id);
}
static stream *new_stream(session *s, int64_t id, SSL *quic) {
    if (s->nstreams >= STREAMS + 6) return NULL;
    /* Account for each accepted byte immediately. All-or-nothing QUIC writes
     * retain a buffer address across WANT_WRITE, but drive_h3 batches small
     * vectors on its stack and can be entered through different event paths. */
    if (quic) SSL_set_mode(quic, SSL_MODE_ENABLE_PARTIAL_WRITE);
    int request_stream = !quic || (id & 3) == 0;
    stream *p;
    char *headers = NULL; uint8_t *input = NULL, *output = NULL;
    size_t output_cap = OUTPUT_CAP;
    if (request_stream && stream_cache) {
        p = stream_cache; stream_cache = p->next; --cached_streams;
        headers = p->headers; input = p->input; output = p->output;
        output_cap = p->output_cap; cached_output_bytes -= output_cap;
    } else p = malloc(sizeof(*p));
    if (!p) return NULL;
    /* Field strings are length checked and terminated by copy_field. Reset
     * their empty markers, not 9 KiB of unused URI/authority capacity. */
    memset(p, 0, offsetof(stream, method));
    p->headers = headers; p->input = input; p->output = output; p->output_cap = output_cap;
    p->method[0] = p->path[0] = p->authority[0] = p->content_length[0] = 0;
    // Control/QPACK streams carry no HTTP request and need no bridge buffers.
    if (request_stream && !p->headers) {
        p->headers = malloc(HEAD_CAP);
        p->input = malloc(INPUT_CAP);
        p->output = malloc(OUTPUT_CAP + 1);
        if (!p->headers || !p->input || !p->output) {
            free_stream(p); return NULL;
        }
    }
    p->owner = s; p->id = id; p->quic = quic;
    p->next = s->streams; s->streams = p; ++s->nstreams;
    return p;
}
static void sweep(session *s) {
    stream **pp = &s->streams;
    while (*pp) {
        stream *p = *pp;
        if (!p->closed) { pp = &p->next; continue; }
        *pp = p->next;
        if (p->request) s->close(p->request);
        if (s->h3 && (p->id & 3) == 0) {
            /* A reset/write failure may leave the nghttp3 stream alive. Drop
             * its association before this object can enter the reuse cache. */
            nghttp3_conn_set_stream_user_data(s->h3, p->id, NULL);
            ++s->completed_bidi;
            nghttp3_conn_set_max_client_streams_bidi(s->h3, STREAMS + s->completed_bidi);
        }
        SSL_free(p->quic);
        if (p->headers && cached_streams < STREAMS && p->output_cap <= OUTPUT_CACHE_CAP - cached_output_bytes) {
            p->next = stream_cache; stream_cache = p; ++cached_streams;
            cached_output_bytes += p->output_cap;
        } else free_stream(p);
        --s->nstreams;
    }
}
static int append(stream *p, const void *data, size_t len) {
    if (len > INPUT_CAP - p->input_len) return -1;
    memcpy(p->input + p->input_len, data, len); p->input_len += len;
    return 0;
}
#define eq_literal(p, n, s) ((n) == sizeof(s) - 1 && !__builtin_memcmp((p), (s), sizeof(s) - 1))
static int copy_field(char *dst, size_t cap, const uint8_t *v, size_t n) {
    if (n >= cap || *dst) return -1;
    memcpy(dst, v, n); dst[n] = 0; return 0;
}
static int header(stream *p, const uint8_t *name, size_t nn, const uint8_t *value, size_t vn) {
    if (!p || !p->headers || p->started || ++p->header_count > 96 || nn + vn + p->headers_len > HEAD_CAP - 1024) return -1;
    /* Never allow protocol conversion to introduce an HTTP/1 request line/header. */
    for (size_t i = 0; i < vn; ++i) if (value[i] == 0 || value[i] == '\r' || value[i] == '\n') return -1;
    if (eq_literal(name, nn, ":method")) return copy_field(p->method, sizeof(p->method), value, vn);
    if (eq_literal(name, nn, ":path")) {
        for (size_t i = 0; i < vn; ++i) if (value[i] <= 32 || value[i] == 127) return -1;
        return copy_field(p->path, sizeof(p->path), value, vn);
    }
    if (eq_literal(name, nn, ":authority")) return copy_field(p->authority, sizeof(p->authority), value, vn);
    if (eq_literal(name, nn, ":scheme")) return eq_literal(value, vn, "https") ? 0 : -1;
    if (!nn || name[0] == ':' || eq_literal(name, nn, "connection") || eq_literal(name, nn, "transfer-encoding") ||
        eq_literal(name, nn, "upgrade") || eq_literal(name, nn, "keep-alive") || eq_literal(name, nn, "proxy-connection")) return -1;
    if (eq_literal(name, nn, "host")) {
        if (*p->authority) return (strlen(p->authority) == vn && !memcmp(value, p->authority, vn)) ? 0 : -1;
        return copy_field(p->authority, sizeof(p->authority), value, vn);
    }
    if (eq_literal(name, nn, "te")) return eq_literal(value, vn, "trailers") ? 0 : -1;
    if (eq_literal(name, nn, "content-length")) return copy_field(p->content_length, sizeof(p->content_length), value, vn);
    if (eq_literal(name, nn, "expect")) return 0;
    memcpy(p->headers + p->headers_len, name, nn); p->headers_len += nn;
    memcpy(p->headers + p->headers_len, ": ", 2); p->headers_len += 2;
    memcpy(p->headers + p->headers_len, value, vn); p->headers_len += vn;
    memcpy(p->headers + p->headers_len, "\r\n", 2); p->headers_len += 2;
    return 0;
}
static uint8_t *request_part(uint8_t *out, const void *data, size_t n) {
    memcpy(out, data, n); return out + n;
}
static int start_request(stream *p) {
    if (!p || p->started || !*p->method || !*p->path || !*p->authority) return -1;
    p->chunked = !*p->content_length;
    const char *framing = p->chunked ? "Transfer-Encoding: chunked\r\n" : "Content-Length: ";
    size_t method_len = strlen(p->method), path_len = strlen(p->path), authority_len = strlen(p->authority);
    size_t framing_len = p->chunked ? sizeof("Transfer-Encoding: chunked\r\n") - 1 : sizeof("Content-Length: ") - 1;
    size_t content_len = p->chunked ? 0 : strlen(p->content_length);
    size_t n = method_len + 1 + path_len + sizeof(" HTTP/1.1\r\nHost: ") - 1 + authority_len +
        sizeof("\r\nConnection: close\r\n") - 1 + framing_len + (p->chunked ? 0 : content_len + 2);
    /* Field arrays are bounded and terminated by header(). Preflight the same
     * bridge limit before copying, without a printf parser for every request. */
    if (n + p->headers_len + 2 > HEAD_CAP || n + p->headers_len + 2 > INPUT_CAP) return -1;
    uint8_t *out = request_part(p->input, p->method, method_len);
    out = request_part(out, " ", 1);
    out = request_part(out, p->path, path_len);
    out = request_part(out, " HTTP/1.1\r\nHost: ", sizeof(" HTTP/1.1\r\nHost: ") - 1);
    out = request_part(out, p->authority, authority_len);
    out = request_part(out, "\r\nConnection: close\r\n", sizeof("\r\nConnection: close\r\n") - 1);
    out = request_part(out, framing, framing_len);
    if (!p->chunked) {
        out = request_part(out, p->content_length, content_len);
        out = request_part(out, "\r\n", 2);
    }
    out = request_part(out, p->headers, p->headers_len);
    out = request_part(out, "\r\n", 2);
    p->input_len = (size_t)(out - p->input);
    session *s = p->owner;
    p->request = s->open(s->user, p, (struct sockaddr *)&s->peer, (struct sockaddr *)&s->local, s->h3 ? 3 : 2);
    if (!p->request) return -1;
    p->started = 1;
    return 0;
}

/* -1 means backpressure; -2 means a closed stream. Buffers remain owned by the
 * codec until stream teardown. The Zig request is detached before pool reuse. */
ssize_t zhttp_stream_read(void *ptr, uint8_t *buf, size_t len) {
    stream *p = ptr;
    if (p->closed) return -2;
    size_t n = p->input_len - p->input_pos;
    if (!n) return p->request_end ? 0 : -1;
    if (n > len) n = len;
    memcpy(buf, p->input + p->input_pos, n); p->input_pos += n;
    p->owner->activity = 1;
    return (ssize_t)n;
}
ssize_t zhttp_stream_write(void *ptr, const uint8_t *buf, size_t len) {
    stream *p = ptr;
    if (p->closed || p->eof) return -2;
    size_t n = p->output_cap - p->output_len;
    if (!n) return -1;
    if (n > len) n = len;
    memcpy(p->output + p->output_len, buf, n); p->output_len += n;
    p->owner->activity = 1;
    return (ssize_t)n;
}
ssize_t zhttp_stream_writable(void *ptr, uint8_t **buf, uint64_t remaining) {
    stream *p = ptr;
    if (p->closed || p->eof) return -1;
    /* Batch large QUIC file reads. Never relocate a vector retained by the
     * codec, and leave small responses at the original allocation size.
     * Allocation failure simply retains the smaller, correct path. */
    if (!p->owner->h2 && remaining > OUTPUT_CAP && !p->offered && p->output_cap < FILE_OUTPUT_CAP) {
        uint8_t *larger = realloc(p->output, FILE_OUTPUT_CAP + 1);
        if (larger) { p->output = larger; p->output_cap = FILE_OUTPUT_CAP; }
    }
    *buf = p->output + p->output_len;
    return (ssize_t)(p->output_cap - p->output_len);
}
void zhttp_stream_commit(void *ptr, size_t n) {
    stream *p = ptr;
    p->output_len += n; p->owner->activity = 1;
}
void zhttp_stream_finish(void *ptr) {
    stream *p = ptr;
    p->request = NULL; p->eof = 1; p->owner->activity = 1;
}
static int body(stream *p, const uint8_t *data, size_t n) {
    if (!p || !p->started || p->request_end) return -1;
    if (!n) return 0;
    if (p->chunked) {
        char b[32]; int k = snprintf(b, sizeof(b), "%zx\r\n", n);
        if (append(p, b, (size_t)k) || append(p, data, n) || append(p, "\r\n", 2)) return -1;
    } else if (append(p, data, n)) return -1;
    p->credit += n;
    return 0;
}
static int end_request(stream *p) {
    if (!p || p->request_end) return 0;
    p->request_end = 1;
    return p->chunked ? append(p, "0\r\n\r\n", 5) : 0;
}
static nghttp2_ssize h2_read(nghttp2_session *h, int32_t id, uint8_t *buf, size_t len,
                           uint32_t *flags, nghttp2_data_source *source, void *user) {
    (void)h; (void)id; (void)user;
    stream *p = source->ptr;
    size_t n = p->output_len - p->output_pos;
    if (n > len) n = len;
    if (!n && !p->eof) return NGHTTP2_ERR_DEFERRED;
    if (n > H2_OUTPUT_CAP / 2) {
        if (n > H2_OUTPUT_CAP - 9) n = H2_OUTPUT_CAP - 9;
        *flags |= NGHTTP2_DATA_FLAG_NO_COPY;
        p->offered = n;
    } else memcpy(buf, p->output + p->output_pos, n);
    p->output_pos += n;
    if (p->eof && p->output_pos == p->output_len) *flags |= NGHTTP2_DATA_FLAG_EOF;
    return (nghttp2_ssize)n;
}
static nghttp3_ssize h3_read(nghttp3_conn *h, int64_t id, nghttp3_vec *vec, size_t nvec,
                           uint32_t *flags, void *user, void *stream_user) {
    (void)h; (void)nvec;
    stream *p = h3_stream(user, id, stream_user);
    if (!p) return NGHTTP3_ERR_CALLBACK_FAILURE;
    size_t n = p->output_len - p->output_pos;
    if (!n && !p->eof) return NGHTTP3_ERR_WOULDBLOCK;
    vec[0].base = p->output + p->output_pos; vec[0].len = n;
    p->output_pos += n; p->offered += n;
    if (p->eof) *flags |= NGHTTP3_DATA_FLAG_EOF;
    return n ? 1 : 0;
}
static int h3_acked(nghttp3_conn *h, int64_t id, uint64_t n, void *user, void *su) {
    (void)h;
    stream *p = h3_stream(user, id, su);
    if (p) { if (n > p->offered) return NGHTTP3_ERR_CALLBACK_FAILURE; p->offered -= (size_t)n; }
    return 0;
}
static int hop_header(const char *name, size_t len) {
    return eq_literal(name, len, "connection") || eq_literal(name, len, "keep-alive") ||
        eq_literal(name, len, "transfer-encoding") || eq_literal(name, len, "upgrade") ||
        eq_literal(name, len, "proxy-connection") || eq_literal(name, len, "trailer");
}
/* The Zig stream connection emits HTTP/1.0 framing: no chunked response body.
 * Libraries copy these header fields before this scratch buffer is reused. */
static int response_headers(stream *p) {
    uint8_t *end = NULL;
    for (size_t i = 3; i < p->output_len && i < OUTPUT_CAP; ++i)
        if (!memcmp(p->output + i - 3, "\r\n\r\n", 4)) { end = p->output + i + 1; break; }
    if (!end) return p->output_len >= OUTPUT_CAP ? -1 : 0;
    p->output[p->output_len] = 0;
    size_t head = (size_t)(end - p->output);
    if (head < 16 || memcmp(p->output, "HTTP/1.", 7)) return -1;
    char status[4]; memcpy(status, p->output + 9, 3); status[3] = 0;
    if (status[0] == '1') { /* discard informational headers (Expect is stripped) */
        memmove(p->output, end, p->output_len - head); p->output_len -= head;
        return response_headers(p);
    }
    nghttp2_nv n2[100]; nghttp3_nv n3[100]; size_t count = 1;
    n2[0] = (nghttp2_nv){(uint8_t *)":status", (uint8_t *)status, 7, 3, 0};
    n3[0] = (nghttp3_nv){(uint8_t *)":status", (uint8_t *)status, 7, 3, 0};
    char *line = strstr((char *)p->output, "\r\n");
    if (!line) return -1;
    line += 2;
    while ((uint8_t *)line < end - 2) {
        char *nl = strstr(line, "\r\n");
        if (!nl) return -1;
        *nl = 0;
        char *v = strchr(line, ':'); if (!v) return -1;
        size_t name_len = (size_t)(v - line);
        *v++ = 0; while (*v == ' ' || *v == '\t') ++v;
        size_t value_len = (size_t)(nl - v);
        for (char *c = line; *c; ++c) if (*c >= 'A' && *c <= 'Z') *c += 'a' - 'A';
        if (!hop_header(line, name_len)) {
            if (count == 100) return -1;
            n2[count] = (nghttp2_nv){(uint8_t *)line, (uint8_t *)v, name_len, value_len, 0};
            n3[count] = (nghttp3_nv){(uint8_t *)line, (uint8_t *)v, name_len, value_len, 0};
            ++count;
        }
        line = nl + 2;
    }
    int rv;
    if (p->owner->h2) {
        nghttp2_data_provider2 dr = {{.ptr = p}, h2_read};
        rv = nghttp2_submit_response2(p->owner->h2, (int32_t)p->id, n2, count, &dr);
    } else {
        nghttp3_data_reader dr = {h3_read};
        rv = nghttp3_conn_submit_response(p->owner->h3, p->id, n3, count, &dr);
    }
    if (rv) return -1;
    p->submitted = 1;
    memmove(p->output, end, p->output_len - head); p->output_len -= head;
    return 0;
}
static int pump_backend(stream *p) {
    if (!p->started || p->closed) return 0;
    if (p->output_pos == p->output_len && !p->offered) p->output_pos = p->output_len = 0;
    /* A completed request cannot consume more input. Let the codec drain its
     * retained response bytes before revisiting the application writer. */
    if (p->request && (!p->output_len || !p->request_end || p->input_pos < p->input_len || !p->submitted))
        p->owner->drive(p->request);
    /* An early response can finish before the client body; discard buffered
     * input while returning its flow-control credit to the connection. */
    if (!p->request && p->eof) p->input_pos = p->input_len;
    if (p->input_pos == p->input_len) {
        p->input_pos = p->input_len = 0;
        if (p->owner->h2 && p->credit) {
            if (nghttp2_session_consume(p->owner->h2, (int32_t)p->id, p->credit)) return -1;
        }
        p->credit = 0;
    }
    if (!p->submitted && response_headers(p)) return -1;
    if (p->eof && !p->submitted) return -1;
    if (p->submitted) {
        if (p->owner->h2) nghttp2_session_resume_data(p->owner->h2, (int32_t)p->id);
        else nghttp3_conn_resume_stream(p->owner->h3, p->id);
    }
    return 0;
}

static int h2_begin(nghttp2_session *h, const nghttp2_frame *f, void *user) {
    (void)h;
    if (f->headers.cat != NGHTTP2_HCAT_REQUEST) return 0;
    session *s = user;
    if (s->nstreams >= STREAMS || !new_stream(s, f->hd.stream_id, NULL)) return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    return 0;
}
static int h2_header(nghttp2_session *h, const nghttp2_frame *f, const uint8_t *n, size_t nn,
                     const uint8_t *v, size_t vn, uint8_t flags, void *user) {
    (void)h; (void)flags;
    if (f->headers.cat != NGHTTP2_HCAT_REQUEST) return 0; /* trailers already validated by nghttp2 */
    return header(lookup(user, f->hd.stream_id), n, nn, v, vn) ? NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE : 0;
}
static int h2_invalid_header(nghttp2_session *h, const nghttp2_frame *f, const uint8_t *n, size_t nn,
                             const uint8_t *v, size_t vn, uint8_t flags, void *user) {
    (void)h; (void)f; (void)n; (void)nn; (void)v; (void)vn; (void)flags; (void)user;
    return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
}
static int h2_frame(nghttp2_session *h, const nghttp2_frame *f, void *user) {
    stream *p = lookup(user, f->hd.stream_id);
    if (!p) return 0;
    int rv = 0;
    if (f->hd.type == NGHTTP2_HEADERS && f->headers.cat == NGHTTP2_HCAT_REQUEST) rv = start_request(p);
    if ((f->hd.type == NGHTTP2_HEADERS || f->hd.type == NGHTTP2_DATA) && (f->hd.flags & NGHTTP2_FLAG_END_STREAM)) rv |= end_request(p);
    if (rv) nghttp2_submit_rst_stream(h, 0, (int32_t)p->id, NGHTTP2_INTERNAL_ERROR);
    return 0;
}
static int h2_data(nghttp2_session *h, uint8_t flags, int32_t id, const uint8_t *data, size_t n, void *user) {
    (void)h; (void)flags;
    return body(lookup(user, id), data, n) ? NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE : 0;
}
static int h2_close(nghttp2_session *h, int32_t id, uint32_t error, void *user) {
    (void)h; (void)error;
    stream *p = lookup(user, id); if (p) p->closed = 1;
    return 0;
}
static nghttp2_ssize h2_send(nghttp2_session *h, const uint8_t *data, size_t n, int flags, void *user) {
    (void)h; (void)flags;
    session *s = user;
    /* Keep an outstanding SSL_write retry's bytes and length unchanged. */
    if (s->h2_write_blocked) return NGHTTP2_ERR_WOULDBLOCK;
    size_t available = H2_OUTPUT_CAP - s->h2_output_len;
    if (!available) return NGHTTP2_ERR_WOULDBLOCK;
    if (n > available) n = available;
    memcpy(s->h2_output + s->h2_output_len, data, n);
    s->h2_output_len += n; s->activity = 1;
    return (nghttp2_ssize)n;
}
static int h2_send_data(nghttp2_session *h, nghttp2_frame *frame, const uint8_t *head,
                        size_t n, nghttp2_data_source *source, void *user) {
    (void)h;
    session *s = user; stream *p = source->ptr;
    if (frame->data.padlen || n != p->offered) return NGHTTP2_ERR_CALLBACK_FAILURE;
    if (s->h2_write_blocked || H2_OUTPUT_CAP - s->h2_output_len < n + 9)
        return NGHTTP2_ERR_WOULDBLOCK;
    /* Large responses otherwise issue one socket write per TLS record.
     * Buffer ciphertext below SSL, so KeyUpdate and record retry ownership
     * remain with OpenSSL. Small-only connections allocate no extra buffer. */
    if (!s->h2_buffer) {
        BIO *buffer = BIO_new(BIO_f_buffer());
        if (!buffer) return NGHTTP2_ERR_CALLBACK_FAILURE;
        if (!BIO_set_write_buffer_size(buffer, 96 * 1024)) {
            BIO_free(buffer); return NGHTTP2_ERR_CALLBACK_FAILURE;
        }
        BIO *socket = SSL_get_wbio(s->ssl);
        if (!BIO_up_ref(socket)) { BIO_free(buffer); return NGHTTP2_ERR_CALLBACK_FAILURE; }
        BIO_push(buffer, socket);
        SSL_set0_wbio(s->ssl, buffer); s->h2_buffer = buffer;
    }
    /* Copy straight into the session-owned TLS batch. Keeping the retry bytes
     * independent of the stream also makes cancellation during WANT_WRITE safe. */
    memcpy(s->h2_output + s->h2_output_len, head, 9);
    memcpy(s->h2_output + s->h2_output_len + 9, p->output + p->output_pos - n, n);
    s->h2_output_len += n + 9; s->activity = 1; p->offered = 0;
    return 0;
}
static int flush_h2(session *s) {
    while (s->h2_output_pos < s->h2_output_len) {
        ERR_clear_error();
        int r = SSL_write(s->ssl, s->h2_output + s->h2_output_pos,
                          (int)(s->h2_output_len - s->h2_output_pos));
        if (r <= 0) {
            s->h2_write_blocked = 1;
            return ssl_wait(s->ssl, r) ? 0 : -1;
        }
        s->h2_write_blocked = 0;
        s->h2_output_pos += (size_t)r; s->activity = 1;
    }
    s->h2_output_pos = s->h2_output_len = 0;
    return 0;
}
void *zhttp_h2_new(SSL *ssl, void *user, open_request open, drive_request drive, close_request close,
                   const struct sockaddr *peer, const struct sockaddr *local) {
    session *s = calloc(1, sizeof(*s)); if (!s) return NULL;
    s->ssl = ssl; s->user = user; s->open = open; s->drive = drive; s->close = close;
    memcpy(&s->peer, peer, peer->sa_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6));
    memcpy(&s->local, local, local->sa_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6));
    nghttp2_session_callbacks *cb = NULL; nghttp2_option *opt = NULL;
    s->h2_output = malloc(H2_OUTPUT_CAP);
    if (!s->h2_output) goto fail;
    if (nghttp2_session_callbacks_new(&cb) || nghttp2_option_new(&opt)) goto fail;
    nghttp2_session_callbacks_set_on_begin_headers_callback(cb, h2_begin);
    nghttp2_session_callbacks_set_on_header_callback(cb, h2_header);
    nghttp2_session_callbacks_set_on_invalid_header_callback(cb, h2_invalid_header);
    nghttp2_session_callbacks_set_on_frame_recv_callback(cb, h2_frame);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cb, h2_data);
    nghttp2_session_callbacks_set_on_stream_close_callback(cb, h2_close);
    nghttp2_session_callbacks_set_send_callback2(cb, h2_send);
    nghttp2_session_callbacks_set_send_data_callback(cb, h2_send_data);
    nghttp2_option_set_no_auto_window_update(opt, 1);
    if (nghttp2_session_server_new2(&s->h2, cb, s, opt)) goto fail;
    nghttp2_settings_entry settings[] = {{NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, STREAMS},
        {NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, 8192}, {NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, HEAD_CAP}};
    if (nghttp2_submit_settings(s->h2, 0, settings, 3)) goto fail;
    nghttp2_session_callbacks_del(cb); nghttp2_option_del(opt);
    ++active_sessions;
    return s;
fail:
    nghttp2_session_callbacks_del(cb); nghttp2_option_del(opt); nghttp2_session_del(s->h2);
    free(s->h2_output); free(s); return NULL;
}
/* Keep large-response BIO bookkeeping out of the small-response hot path. */
static __attribute__((noinline)) int finish_buffered_h2(session *s, int activity) {
    size_t pending = BIO_wpending(s->h2_buffer);
    if (pending) {
        int r = BIO_flush(s->h2_buffer);
        if (r <= 0 && !BIO_should_retry(s->h2_buffer)) return 0;
        size_t remaining = BIO_wpending(s->h2_buffer);
        activity |= remaining < pending;
        pending = remaining;
    }
    if (!pending && !s->nstreams && !s->h2_output_len && !s->h2_write_blocked) {
        /* Do not retain a large-response buffer on an idle keepalive socket. */
        BIO *socket = BIO_pop(s->h2_buffer);
        SSL_set0_wbio(s->ssl, socket); s->h2_buffer = NULL;
    }
    return pending || s->h2_output_len || nghttp2_session_want_read(s->h2) || nghttp2_session_want_write(s->h2) ? 1 + activity : 0;
}
int zhttp_h2_drive(void *ptr) {
    session *s = ptr; uint8_t buf[16384]; s->activity = 0;
    /* Bound work per tick so a busy connection cannot starve other clients. */
    for (int i = 0; i < 32; ++i) {
        ERR_clear_error(); int n = SSL_read(s->ssl, buf, sizeof(buf));
        if (n <= 0) { if (!ssl_wait(s->ssl, n)) return 0; break; }
        s->activity = 1;
        if (nghttp2_session_mem_recv2(s->h2, buf, (size_t)n) < 0) return 0;
    }
    int activity = s->activity;
    /* Select the budget once. A newly buffered connection gets the larger
     * budget on its next active turn; short responses keep the fixed loop. */
    const int passes = s->h2_buffer ? 64 : 4;
    for (int pass = 0; pass < passes; ++pass) {
        s->activity = 0;
        if (flush_h2(s)) return 0;
        for (stream *p = s->streams; p; p = p->next)
            if (pump_backend(p)) nghttp2_submit_rst_stream(s->h2, 0, (int32_t)p->id, NGHTTP2_INTERNAL_ERROR);
        if (nghttp2_session_send(s->h2) || flush_h2(s)) return 0;
        sweep(s);
        activity |= s->activity;
        if (!s->activity) break;
    }
    if (s->h2_buffer) return finish_buffered_h2(s, activity);
    return s->h2_output_len || nghttp2_session_want_read(s->h2) || nghttp2_session_want_write(s->h2) ? 1 + activity : 0;
}
static void free_session(session *s) {
    nghttp2_session_del(s->h2); nghttp3_conn_del(s->h3);
    s->h2 = NULL; s->h3 = NULL;
    for (stream *p = s->streams; p; p = p->next) p->closed = 1;
    sweep(s); free(s->h2_output); free(s);
    if (--active_sessions == 0) {
        while (stream_cache) {
            stream *p = stream_cache; stream_cache = p->next; free_stream(p);
        }
        cached_streams = 0; cached_output_bytes = 0;
    }
}
void zhttp_h2_free(void *ptr) { if (ptr) free_session(ptr); }

static int h3_headers_begin(nghttp3_conn *h, int64_t id, void *user, void *su) {
    stream *p = h3_stream(user, id, su);
    /* sweep clears this association before it can recycle the object. Keep
     * the pointer instead of searching the list for every header/data
     * callback. Streams reset before headers still use the lookup fallback. */
    return !p || nghttp3_conn_set_stream_user_data(h, id, p) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}
static int h3_header(nghttp3_conn *h, int64_t id, int32_t token, nghttp3_rcbuf *n, nghttp3_rcbuf *v,
                     uint8_t flags, void *user, void *su) {
    (void)h; (void)token; (void)flags;
    nghttp3_vec name = nghttp3_rcbuf_get_buf(n), value = nghttp3_rcbuf_get_buf(v);
    return header(h3_stream(user, id, su), name.base, name.len, value.base, value.len) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}
static int h3_headers_done(nghttp3_conn *h, int64_t id, int fin, void *user, void *su) {
    (void)h; (void)fin;
    return start_request(h3_stream(user, id, su)) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}
static int h3_data(nghttp3_conn *h, int64_t id, const uint8_t *data, size_t n, void *user, void *su) {
    (void)h;
    return body(h3_stream(user, id, su), data, n) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}
static int h3_end(nghttp3_conn *h, int64_t id, void *user, void *su) {
    (void)h;
    return end_request(h3_stream(user, id, su)) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}
static int h3_reset(nghttp3_conn *h, int64_t id, uint64_t code, void *user, void *su) {
    (void)h;
    stream *p = h3_stream(user, id, su);
    if (p) { SSL_STREAM_RESET_ARGS args = {code}; SSL_stream_reset(p->quic, &args, sizeof(args)); }
    return 0;
}
static void h3_rand(uint8_t *dest, size_t n) { if (RAND_bytes(dest, (int)n) != 1) abort(); }
static int h3_shutdown(nghttp3_conn *h, int64_t id, void *user) {
    (void)id;
    ((session *)user)->shutting_down = 1;
    /* Reply with GOAWAY while existing requests continue to drain. Clients
     * waiting for graceful HTTP/3 shutdown must not wait for QUIC idle expiry. */
    return nghttp3_conn_shutdown(h) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}
static int init_h3(session *s) {
    nghttp3_callbacks cb = {0};
    cb.begin_headers = h3_headers_begin; cb.recv_header = h3_header; cb.end_headers = h3_headers_done;
    cb.recv_data = h3_data; cb.end_stream = h3_end; cb.acked_stream_data = h3_acked;
    cb.stop_sending = h3_reset; cb.reset_stream = h3_reset; cb.rand = h3_rand;
    cb.shutdown = h3_shutdown;
    nghttp3_settings settings; nghttp3_settings_default(&settings);
    settings.max_field_section_size = HEAD_CAP;
    settings.qpack_max_dtable_capacity = 0; settings.qpack_blocked_streams = 0;
    if (nghttp3_conn_server_new(&s->h3, &cb, &settings, NULL, s)) return -1;
    nghttp3_conn_set_max_client_streams_bidi(s->h3, STREAMS);
    nghttp3_conn_set_max_concurrent_streams(s->h3, STREAMS);
    int64_t ids[3];
    for (int i = 0; i < 3; ++i) {
        SSL *q = SSL_new_stream(s->ssl, SSL_STREAM_FLAG_UNI | SSL_STREAM_FLAG_NO_BLOCK);
        if (!q) return -1;
        ids[i] = (int64_t)SSL_get_stream_id(q);
        if (!new_stream(s, ids[i], q)) { SSL_free(q); return -1; }
    }
    return nghttp3_conn_bind_control_stream(s->h3, ids[0]) || nghttp3_conn_bind_qpack_streams(s->h3, ids[1], ids[2]) ? -1 : 0;
}
static int drain_h3(session *s) {
    /* Continue only transport shutdown once it starts. Application reads then
     * fail with PROTOCOL_IS_SHUTDOWN; treating that as a stream reset would
     * prematurely stop HTTP/3 control streams while responses are draining. */
    SSL_SHUTDOWN_EX_ARGS args = {0};
    args.quic_error_code = NGHTTP3_H3_NO_ERROR;
    ERR_clear_error();
    int r = SSL_shutdown_ex(s->ssl, 0, &args, sizeof(args));
    return r == 1 || (r < 0 && !ssl_wait(s->ssl, r)) ? -1 : 0;
}
static int drive_h3(session *s) {
    if (s->shutting_down == 2) return drain_h3(s);
    SSL_CONN_CLOSE_INFO info;
    if (SSL_get_conn_close_info(s->ssl, &info, sizeof(info))) return -1;
    if (!s->h3) {
        ERR_clear_error(); int r = SSL_accept(s->ssl);
        if (r != 1) return ssl_wait(s->ssl, r) ? 0 : -1;
        if (init_h3(s)) return -1;
    }
    SSL *q;
    while ((q = SSL_accept_stream(s->ssl, SSL_ACCEPT_STREAM_NO_BLOCK))) {
        if (!new_stream(s, (int64_t)SSL_get_stream_id(q), q)) { SSL_free(q); return -1; }
    }
    for (stream *p = s->streams; p; p = p->next) {
        if (p->read_fin || (p->id & 3) == 3) continue;
        for (int i = 0; i < 4 && p->input_len < INPUT_CAP - 32 * 1024; ++i) {
            uint8_t buf[8192]; size_t n = 0; ERR_clear_error();
            int r = SSL_read_ex(p->quic, buf, sizeof(buf), &n);
            int fin = !r && SSL_get_error(p->quic, r) == SSL_ERROR_ZERO_RETURN;
            if (!r && !fin) {
                if (ssl_wait(p->quic, r)) break;
                nghttp3_conn_shutdown_stream_read(s->h3, p->id);
                nghttp3_conn_close_stream(s->h3, p->id, NGHTTP3_H3_REQUEST_CANCELLED);
                p->closed = 1; break;
            }
            if (nghttp3_conn_read_stream(s->h3, p->id, buf, n, fin) < 0) return -1;
            if (n || fin) s->activity = 1;
            if (fin) {
                p->read_fin = 1;
                /* Unknown client unidirectional streams (including GREASE)
                 * have no response half to wait for before releasing them. */
                if ((p->id & 3) == 2) {
                    nghttp3_conn_close_stream(s->h3, p->id, NGHTTP3_H3_NO_ERROR);
                    p->closed = 1;
                }
                break;
            }
        }
    }
    for (stream *p = s->streams; p; p = p->next)
        if (pump_backend(p)) return -1;
    for (int i = 0; i < 128; ++i) {
        nghttp3_vec vec[8]; int64_t id; int fin;
        nghttp3_ssize nv = nghttp3_conn_writev_stream(s->h3, &id, &fin, vec, 8);
        if (nv < 0) return -1;
        if (id < 0) break;
        stream *p = lookup(s, id); if (!p) return -1;
        /* Combine small frame headers and bodies into one QUIC stream write.
         * Large vectors stay in their existing buffer; no extra body copy. */
        uint8_t batch[2048]; const uint8_t *data = nv ? vec[0].base : batch;
        size_t len = nv ? vec[0].len : 0;
        nghttp3_ssize used = nv ? 1 : 0;
        if (nv > 1 && len <= sizeof(batch) && vec[1].len <= sizeof(batch) - len) {
            memcpy(batch, data, len); data = batch;
            while (used < nv && vec[used].len <= sizeof(batch) - len) {
                memcpy(batch + len, vec[used].base, vec[used].len);
                len += vec[used++].len;
            }
        }
        int conclude = fin && used == nv;
        size_t n = 0;
        if (len) {
            ERR_clear_error();
            int r = SSL_write_ex2(p->quic, data, len, conclude ? SSL_WRITE_FLAG_CONCLUDE : 0, &n);
            if (!r) {
                if (ssl_wait(p->quic, r)) { nghttp3_conn_block_stream(s->h3, id); continue; }
                nghttp3_conn_shutdown_stream_write(s->h3, id); p->closed = 1; continue;
            }
        }
        if (nghttp3_conn_add_write_offset(s->h3, id, n)) return -1;
        if (n) s->activity = 1;
        /* SSL_write_ex2 copies into OpenSSL's retransmission buffer. The
         * nghttp3 buffers can be released independently of packet ACKs. */
        if (nghttp3_conn_add_ack_offset(s->h3, id, n)) return -1;
        if (conclude && n == len) {
            /* A zero-byte SSL_write_ex2 reports WANT_WRITE even when FIN was
             * queued. Use the explicit API for a FIN without payload. */
            if (!len && !SSL_stream_conclude(p->quic, 0)) return -1;
            p->write_fin = 1;
        }
    }
    for (stream *p = s->streams; p; p = p->next) {
        if (p->read_fin && p->write_fin) {
            nghttp3_conn_close_stream(s->h3, p->id, NGHTTP3_H3_NO_ERROR); p->closed = 1;
        } else nghttp3_conn_unblock_stream(s->h3, p->id);
    }
    sweep(s);
    if (s->shutting_down) {
        for (stream *p = s->streams; p; p = p->next)
            if ((p->id & 3) == 0) return 0;
        /* Unlike RAPID shutdown, this waits for buffered response bytes to be
         * acknowledged before sending CONNECTION_CLOSE with H3_NO_ERROR. */
        s->shutting_down = 2;
        return drain_h3(s);
    }
    return 0;
}
/* OpenSSL 3.5 has no public QUIC peer-address getter. Process long-header
 * datagrams while their address context is current, so the new-connection
 * callback captures the originating peer. Established short-header traffic
 * shares a bounded event-processing batch. Only this code reads the UDP fd. */
static void peer_free(void *parent, void *ptr, CRYPTO_EX_DATA *ad, int idx, long argl, void *argp) {
    (void)parent; (void)ad; (void)idx; (void)argl; (void)argp;
    peer_info *p = ptr; if (p) { --p->owner->admitted; free(p); }
}
static int pending(SSL_CTX *ctx, SSL *ssl, void *arg) {
    (void)ctx; listener *l = arg;
    if (l->admitted >= l->limit) return 0;
    peer_info *p = malloc(sizeof(*p)); if (!p) return 0;
    p->peer = l->peer; p->local = l->local; p->owner = l;
    if (!SSL_set_ex_data(ssl, peer_index, p)) { free(p); return 0; }
    ++l->admitted;
    return 1;
}
static int bio_addr(BIO_ADDR *b, const struct sockaddr_storage *s) {
    int r;
    if (s->ss_family == AF_INET) {
        const struct sockaddr_in *a = (const void *)s;
        r = BIO_ADDR_rawmake(b, AF_INET, &a->sin_addr, sizeof(a->sin_addr), a->sin_port);
    } else {
        const struct sockaddr_in6 *a = (const void *)s;
        r = BIO_ADDR_rawmake(b, AF_INET6, &a->sin6_addr, sizeof(a->sin6_addr), a->sin6_port);
    }
    return r;
}
void *zhttp_h3_new(SSL_CTX *ctx, int fd, void *user, open_request open, drive_request drive,
                   close_request close, unsigned limit) {
    listener *l = calloc(1, sizeof(*l)); if (!l) return NULL;
    l->fd = fd; l->user = user; l->open = open; l->drive = drive; l->close = close; l->limit = limit;
    socklen_t len = sizeof(l->bound);
    if (getsockname(fd, (struct sockaddr *)&l->bound, &len)) goto fail;
    l->peer_addr = BIO_ADDR_new(); l->local_addr = BIO_ADDR_new();
    if (!l->peer_addr || !l->local_addr) goto fail;
    if (peer_index < 0) peer_index = SSL_get_ex_new_index(0, NULL, NULL, NULL, peer_free);
    if (peer_index < 0) goto fail;
    l->ssl = SSL_new_listener(ctx, 0); if (!l->ssl) goto fail;
    SSL_CTX_set_new_pending_conn_cb(ctx, pending, l);
    BIO *rd = BIO_new(BIO_s_dgram_mem()), *wr = quic_output_new(&l->output, fd);
    if (!rd || !wr) { BIO_free(rd); BIO_free(wr); goto fail; }
    SSL_set0_rbio(l->ssl, rd); SSL_set0_wbio(l->ssl, wr);
    if (!SSL_set_blocking_mode(l->ssl, 0) || !SSL_listen(l->ssl)) goto fail;
    SSL_set_generic_value_uint(l->ssl, SSL_VALUE_QUIC_MAX_PENDING_CONNS, limit);
    int one = 1;
#ifdef IP_PKTINFO
    setsockopt(fd, IPPROTO_IP, IP_PKTINFO, &one, sizeof(one));
#elif defined(IP_RECVDSTADDR)
    setsockopt(fd, IPPROTO_IP, IP_RECVDSTADDR, &one, sizeof(one));
#endif
    setsockopt(fd, IPPROTO_IPV6, IPV6_RECVPKTINFO, &one, sizeof(one));
#ifdef __linux__
    ++quic_listeners;
#endif
    return l;
fail:
    SSL_free(l->ssl); BIO_meth_free(l->output.method); BIO_ADDR_free(l->peer_addr); BIO_ADDR_free(l->local_addr); free(l); return NULL;
}
#ifdef __linux__
/* Shared by listeners on this event-loop thread; every batch is consumed
 * before another listener is driven. Keep full-size UDP buffers so valid
 * datagrams are not rejected solely because batching is enabled. */
typedef struct {
    uint8_t data[8][65536], control[8][256];
    struct sockaddr_storage peer[8];
    struct iovec vec[8];
    struct mmsghdr msg[8];
} quic_input_batch;
/* Allocate only for QUIC traffic, not for every TLS worker/thread. */
static _Thread_local quic_input_batch *quic_input;
static ssize_t quic_recv(int fd, unsigned remaining, unsigned *index, unsigned *count,
                          uint8_t **buf, struct msghdr *msg) {
    if (!quic_input) {
        quic_input = malloc(sizeof(*quic_input));
        if (!quic_input) return -1;
    }
    if (*index == *count) {
        memset(quic_input->msg, 0, sizeof(quic_input->msg));
        for (unsigned k = 0; k < 8; ++k) {
            struct msghdr *m = &quic_input->msg[k].msg_hdr;
            quic_input->vec[k] = (struct iovec){quic_input->data[k], sizeof(quic_input->data[k])};
            m->msg_iov = &quic_input->vec[k]; m->msg_iovlen = 1;
            m->msg_name = &quic_input->peer[k]; m->msg_namelen = sizeof(quic_input->peer[k]);
            m->msg_control = quic_input->control[k]; m->msg_controllen = sizeof(quic_input->control[k]);
        }
        int n = recvmmsg(fd, quic_input->msg, remaining < 8 ? remaining : 8, MSG_DONTWAIT, NULL);
        if (n <= 0) return -1;
        *index = 0; *count = (unsigned)n;
    }
    unsigned k = (*index)++;
    *buf = quic_input->data[k]; *msg = quic_input->msg[k].msg_hdr;
    return (ssize_t)quic_input->msg[k].msg_len;
}
#endif
int zhttp_h3_drive(void *ptr) {
    listener *l = ptr;
    int activity = 0;
#ifdef __linux__
    unsigned packet_index = 0, packet_count = 0;
#endif
    for (int i = 0; i < 128; ++i) {
#ifdef __linux__
        uint8_t *buf; struct msghdr msg;
        ssize_t n = quic_recv(l->fd, (unsigned)(128 - i), &packet_index, &packet_count, &buf, &msg);
        if (n < 0) break;
        l->peer = *(struct sockaddr_storage *)msg.msg_name;
#else
        uint8_t buf[65536], control[256]; struct iovec iov = {buf, sizeof(buf)};
        struct msghdr msg = {0};
        msg.msg_name = &l->peer; msg.msg_namelen = sizeof(l->peer);
        msg.msg_iov = &iov; msg.msg_iovlen = 1; msg.msg_control = control; msg.msg_controllen = sizeof(control);
        ssize_t n = recvmsg(l->fd, &msg, 0); if (n < 0) break;
#endif
        activity = 1;
        if (msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) continue;
        l->local = l->bound;
        for (struct cmsghdr *ch = CMSG_FIRSTHDR(&msg); ch; ch = CMSG_NXTHDR(&msg, ch)) {
#ifdef IP_PKTINFO
            if (ch->cmsg_level == IPPROTO_IP && ch->cmsg_type == IP_PKTINFO)
                ((struct sockaddr_in *)&l->local)->sin_addr = ((struct in_pktinfo *)CMSG_DATA(ch))->ipi_addr;
#elif defined(IP_RECVDSTADDR)
            if (ch->cmsg_level == IPPROTO_IP && ch->cmsg_type == IP_RECVDSTADDR)
                memcpy(&((struct sockaddr_in *)&l->local)->sin_addr, CMSG_DATA(ch), sizeof(struct in_addr));
#endif
            if (ch->cmsg_level == IPPROTO_IPV6 && ch->cmsg_type == IPV6_PKTINFO)
                ((struct sockaddr_in6 *)&l->local)->sin6_addr = ((struct in6_pktinfo *)CMSG_DATA(ch))->ipi6_addr;
        }
        if (bio_addr(l->peer_addr, &l->peer) && bio_addr(l->local_addr, &l->local)) {
            SSL_inject_net_dgram(l->ssl, buf, (size_t)n, l->peer_addr, l->local_addr);
            /* A new connection can only start with a long-header packet.
             * Process it before changing the callback's peer/local context;
             * established short-header packets can share one event tick. */
            if (n && (buf[0] & 0x80)) SSL_handle_events(l->ssl);
        }
    }
    SSL_handle_events(l->ssl);
    SSL *q;
    /* Calling accept on an empty queue runs two additional reactor ticks in
     * OpenSSL 3.5. Explicit event handling above already refreshed this queue. */
    while (SSL_get_accept_connection_queue_len(l->ssl) &&
           (q = SSL_accept_connection(l->ssl, SSL_ACCEPT_CONNECTION_NO_BLOCK))) {
        peer_info *pi = SSL_get_ex_data(q, peer_index);
        session *s = pi ? calloc(1, sizeof(*s)) : NULL;
        if (!s) { SSL_free(q); continue; }
        ++active_sessions;
        s->ssl = q; s->open = l->open; s->drive = l->drive; s->close = l->close;
        s->user = l->user; s->peer = pi->peer; s->local = pi->local;
        SSL_set_default_stream_mode(q, SSL_DEFAULT_STREAM_MODE_NONE);
        SSL_set_incoming_stream_policy(q, SSL_INCOMING_STREAM_POLICY_ACCEPT, 0);
        /* Drive QUIC once after the bounded application batch, rather than
         * once per stream read/write. Streams inherit this mode. */
        if (!SSL_set_event_handling_mode(q, SSL_VALUE_EVENT_HANDLING_MODE_EXPLICIT)) {
            free_session(s); SSL_free(q); continue;
        }
        s->next = l->sessions; l->sessions = s;
    }
    session **pp = &l->sessions;
    while (*pp) {
        session *s = *pp;
        s->activity = 0;
        if (drive_h3(s)) {
            *pp = s->next; SSL_shutdown_ex(s->ssl, SSL_SHUTDOWN_FLAG_RAPID, NULL, 0);
            SSL *ssl = s->ssl; free_session(s); SSL_free(ssl);
        } else { activity |= s->activity; pp = &s->next; }
    }
    SSL_handle_events(l->ssl);
    return activity;
}
int zhttp_h3_wait_ms(void *ptr) {
    listener *l = ptr;
    struct timeval timeout; int infinite = 0;
    if (!SSL_get_event_timeout(l->ssl, &timeout, &infinite) || infinite || timeout.tv_sec > 0)
        return 5;
    /* Polling backends accept whole milliseconds. Round down so QUIC pacing
     * and ACK timers are never delayed by the generic 5 ms modern-I/O poll.
     * Sub-millisecond deadlines briefly poll without sleeping. */
    if (timeout.tv_sec < 0 || timeout.tv_usec < 0) return 0;
    return timeout.tv_usec >= 5000 ? 5 : (int)(timeout.tv_usec / 1000);
}

void zhttp_h3_free(void *ptr) {
    if (!ptr) return;
    listener *l = ptr;
    while (l->sessions) {
        session *s = l->sessions; l->sessions = s->next;
        SSL *ssl = s->ssl; free_session(s); SSL_free(ssl);
    }
    SSL_free(l->ssl); BIO_meth_free(l->output.method); BIO_ADDR_free(l->peer_addr); BIO_ADDR_free(l->local_addr); free(l);
#ifdef __linux__
    if (!--quic_listeners) { free(quic_input); quic_input = NULL; }
#endif
}
