/* HTTP/2 and HTTP/3 codecs. Each request uses a bounded, nonblocking socketpair
 * to the existing Zig request engine. No public loopback listener is involved.
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
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>

#define STREAMS 32
#define INPUT_CAP (128 * 1024)
#define OUTPUT_CAP (32 * 1024)
#define HEAD_CAP (14 * 1024)
/* On success the callback owns fd. On failure the caller closes it. */
typedef int (*open_request)(void *, int, const struct sockaddr *, const struct sockaddr *, int);
typedef struct session session;
typedef struct stream stream;
struct stream {
    stream *next;
    session *owner;
    int64_t id;
    SSL *quic;
    int fd, started, request_end, chunked, eof, submitted, closed, read_fin, write_fin;
    char method[32], path[8193], authority[1024], content_length[32];
    char *headers;
    size_t headers_len, header_count;
    uint8_t *input, *output;
    size_t input_len, input_pos, output_len, output_pos, credit, offered;
};
struct session {
    session *next;
    SSL *ssl;
    nghttp2_session *h2;
    nghttp3_conn *h3;
    stream *streams;
    unsigned nstreams;
    uint64_t completed_bidi;
    void *user;
    open_request open;
    struct sockaddr_storage peer, local;
    int activity;
};
typedef struct listener {
    SSL *ssl;
    session *sessions;
    void *user;
    open_request open;
    int fd;
    unsigned limit, admitted;
    struct sockaddr_storage peer, local;
} listener;
typedef struct peer_info {
    struct sockaddr_storage peer, local;
    listener *owner;
} peer_info;
static int peer_index = -1;

static int wouldblock(void) { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR; }
static int ssl_wait(SSL *ssl, int r) {
    int e = SSL_get_error(ssl, r);
    return e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE;
}
static stream *lookup(session *s, int64_t id) {
    for (stream *p = s->streams; p; p = p->next) if (p->id == id) return p;
    return NULL;
}
static stream *new_stream(session *s, int64_t id, SSL *quic) {
    if (s->nstreams >= STREAMS + 6) return NULL;
    stream *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    // Control/QPACK streams carry no HTTP request and need no bridge buffers.
    if (!quic || (id & 3) == 0) {
        p->headers = malloc(HEAD_CAP);
        p->input = malloc(INPUT_CAP);
        p->output = malloc(OUTPUT_CAP + 1);
        if (!p->headers || !p->input || !p->output) {
            free(p->headers); free(p->input); free(p->output); free(p); return NULL;
        }
    }
    p->owner = s; p->id = id; p->quic = quic; p->fd = -1;
    p->next = s->streams; s->streams = p; ++s->nstreams;
    return p;
}
static void sweep(session *s) {
    stream **pp = &s->streams;
    while (*pp) {
        stream *p = *pp;
        if (!p->closed) { pp = &p->next; continue; }
        *pp = p->next;
        if (p->fd >= 0) close(p->fd);
        if (s->h3 && (p->id & 3) == 0) {
            ++s->completed_bidi;
            nghttp3_conn_set_max_client_streams_bidi(s->h3, STREAMS + s->completed_bidi);
        }
        SSL_free(p->quic);
        free(p->headers); free(p->input); free(p->output);
        free(p); --s->nstreams;
    }
}
static int append(stream *p, const void *data, size_t len) {
    if (len > INPUT_CAP - p->input_len) return -1;
    memcpy(p->input + p->input_len, data, len); p->input_len += len;
    return 0;
}
static int eq(const uint8_t *p, size_t n, const char *s) { return strlen(s) == n && !memcmp(p, s, n); }
static int copy_field(char *dst, size_t cap, const uint8_t *v, size_t n) {
    if (n >= cap || *dst) return -1;
    memcpy(dst, v, n); dst[n] = 0; return 0;
}
static int header(stream *p, const uint8_t *name, size_t nn, const uint8_t *value, size_t vn) {
    if (!p || !p->headers || p->started || ++p->header_count > 96 || nn + vn + p->headers_len > HEAD_CAP - 1024) return -1;
    /* Never allow protocol conversion to introduce an HTTP/1 request line/header. */
    for (size_t i = 0; i < vn; ++i) if (value[i] == 0 || value[i] == '\r' || value[i] == '\n') return -1;
    if (eq(name, nn, ":method")) return copy_field(p->method, sizeof(p->method), value, vn);
    if (eq(name, nn, ":path")) {
        for (size_t i = 0; i < vn; ++i) if (value[i] <= 32 || value[i] == 127) return -1;
        return copy_field(p->path, sizeof(p->path), value, vn);
    }
    if (eq(name, nn, ":authority")) return copy_field(p->authority, sizeof(p->authority), value, vn);
    if (eq(name, nn, ":scheme")) return eq(value, vn, "https") ? 0 : -1;
    if (!nn || name[0] == ':' || eq(name, nn, "connection") || eq(name, nn, "transfer-encoding") ||
        eq(name, nn, "upgrade") || eq(name, nn, "keep-alive") || eq(name, nn, "proxy-connection")) return -1;
    if (eq(name, nn, "host")) {
        if (*p->authority) return eq(value, vn, p->authority) ? 0 : -1;
        return copy_field(p->authority, sizeof(p->authority), value, vn);
    }
    if (eq(name, nn, "te")) return eq(value, vn, "trailers") ? 0 : -1;
    if (eq(name, nn, "content-length")) return copy_field(p->content_length, sizeof(p->content_length), value, vn);
    if (eq(name, nn, "expect")) return 0;
    memcpy(p->headers + p->headers_len, name, nn); p->headers_len += nn;
    memcpy(p->headers + p->headers_len, ": ", 2); p->headers_len += 2;
    memcpy(p->headers + p->headers_len, value, vn); p->headers_len += vn;
    memcpy(p->headers + p->headers_len, "\r\n", 2); p->headers_len += 2;
    return 0;
}
static int start_request(stream *p) {
    if (!p || p->started || !*p->method || !*p->path || !*p->authority) return -1;
    p->chunked = !*p->content_length;
    int n = snprintf((char *)p->input, INPUT_CAP,
        "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n%s: %s\r\n",
        p->method, p->path, p->authority,
        p->chunked ? "Transfer-Encoding" : "Content-Length", p->chunked ? "chunked" : p->content_length);
    if (n < 0 || (size_t)n + p->headers_len + 2 > HEAD_CAP) return -1;
    p->input_len = (size_t)n;
    if (append(p, p->headers, p->headers_len) || append(p, "\r\n", 2)) return -1;
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds)) return -1;
    for (int i = 0; i < 2; ++i) {
        if (fcntl(fds[i], F_SETFL, O_NONBLOCK) < 0 || fcntl(fds[i], F_SETFD, FD_CLOEXEC) < 0) {
            close(fds[0]); close(fds[1]); return -1;
        }
#ifdef SO_NOSIGPIPE
        int one = 1; setsockopt(fds[i], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
    }
    session *s = p->owner;
    if (!s->open(s->user, fds[1], (struct sockaddr *)&s->peer, (struct sockaddr *)&s->local, s->h3 ? 3 : 2)) {
        close(fds[0]); close(fds[1]); return -1;
    }
    p->fd = fds[0]; p->started = 1;
    return 0;
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
    memcpy(buf, p->output + p->output_pos, n); p->output_pos += n;
    if (p->eof && p->output_pos == p->output_len) *flags |= NGHTTP2_DATA_FLAG_EOF;
    return (nghttp2_ssize)n;
}
static nghttp3_ssize h3_read(nghttp3_conn *h, int64_t id, nghttp3_vec *vec, size_t nvec,
                           uint32_t *flags, void *user, void *stream_user) {
    (void)h; (void)nvec; (void)stream_user;
    stream *p = lookup(user, id);
    if (!p) return NGHTTP3_ERR_CALLBACK_FAILURE;
    size_t n = p->output_len - p->output_pos;
    if (!n && !p->eof) return NGHTTP3_ERR_WOULDBLOCK;
    vec[0].base = p->output + p->output_pos; vec[0].len = n;
    p->output_pos += n; p->offered += n;
    if (p->eof) *flags |= NGHTTP3_DATA_FLAG_EOF;
    return n ? 1 : 0;
}
static int h3_acked(nghttp3_conn *h, int64_t id, uint64_t n, void *user, void *su) {
    (void)h; (void)su;
    stream *p = lookup(user, id);
    if (p) { if (n > p->offered) return NGHTTP3_ERR_CALLBACK_FAILURE; p->offered -= (size_t)n; }
    return 0;
}
static int hop_header(const char *name) {
    return !strcmp(name, "connection") || !strcmp(name, "keep-alive") || !strcmp(name, "transfer-encoding") ||
        !strcmp(name, "upgrade") || !strcmp(name, "proxy-connection") || !strcmp(name, "trailer");
}
/* The Zig stream connection emits HTTP/1.0 framing: no chunked response body.
 * Libraries copy these header fields before this scratch buffer is reused. */
static int response_headers(stream *p) {
    uint8_t *end = NULL;
    for (size_t i = 3; i < p->output_len; ++i)
        if (!memcmp(p->output + i - 3, "\r\n\r\n", 4)) { end = p->output + i + 1; break; }
    if (!end) return p->output_len == OUTPUT_CAP ? -1 : 0;
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
        *v++ = 0; while (*v == ' ' || *v == '\t') ++v;
        for (char *c = line; *c; ++c) *c = (char)tolower((unsigned char)*c);
        if (!hop_header(line)) {
            if (count == 100) return -1;
            n2[count] = (nghttp2_nv){(uint8_t *)line, (uint8_t *)v, strlen(line), strlen(v), 0};
            n3[count] = (nghttp3_nv){(uint8_t *)line, (uint8_t *)v, strlen(line), strlen(v), 0};
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
    while (p->input_pos < p->input_len) {
        ssize_t n = write(p->fd, p->input + p->input_pos, p->input_len - p->input_pos);
        if (n > 0) p->input_pos += (size_t)n;
        else if (n < 0 && wouldblock()) break;
        else { p->input_pos = p->input_len; break; } /* an early error response may close its read side */
    }
    if (p->input_pos == p->input_len) {
        p->input_pos = p->input_len = 0;
        if (p->owner->h2 && p->credit) {
            if (nghttp2_session_consume(p->owner->h2, (int32_t)p->id, p->credit)) return -1;
        }
        p->credit = 0;
    }
    if (p->output_pos == p->output_len && !p->offered) p->output_pos = p->output_len = 0;
    if (p->eof || p->output_len == OUTPUT_CAP) return 0;
    ssize_t n = read(p->fd, p->output + p->output_len, OUTPUT_CAP - p->output_len);
    if (n > 0) p->output_len += (size_t)n;
    else if (n == 0) p->eof = 1;
    else if (!wouldblock()) return -1;
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
    session *s = user; ERR_clear_error();
    int r = SSL_write(s->ssl, data, (int)n);
    if (r > 0) { s->activity = 1; return r; }
    return ssl_wait(s->ssl, r) ? NGHTTP2_ERR_WOULDBLOCK : NGHTTP2_ERR_CALLBACK_FAILURE;
}
void *zhttp_h2_new(SSL *ssl, void *user, open_request open, const struct sockaddr *peer, const struct sockaddr *local) {
    session *s = calloc(1, sizeof(*s)); if (!s) return NULL;
    s->ssl = ssl; s->user = user; s->open = open;
    memcpy(&s->peer, peer, peer->sa_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6));
    memcpy(&s->local, local, local->sa_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6));
    nghttp2_session_callbacks *cb = NULL; nghttp2_option *opt = NULL;
    if (nghttp2_session_callbacks_new(&cb) || nghttp2_option_new(&opt)) goto fail;
    nghttp2_session_callbacks_set_on_begin_headers_callback(cb, h2_begin);
    nghttp2_session_callbacks_set_on_header_callback(cb, h2_header);
    nghttp2_session_callbacks_set_on_invalid_header_callback(cb, h2_invalid_header);
    nghttp2_session_callbacks_set_on_frame_recv_callback(cb, h2_frame);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cb, h2_data);
    nghttp2_session_callbacks_set_on_stream_close_callback(cb, h2_close);
    nghttp2_session_callbacks_set_send_callback2(cb, h2_send);
    nghttp2_option_set_no_auto_window_update(opt, 1);
    if (nghttp2_session_server_new2(&s->h2, cb, s, opt)) goto fail;
    nghttp2_settings_entry settings[] = {{NGHTTP2_SETTINGS_MAX_CONCURRENT_STREAMS, STREAMS},
        {NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, 8192}, {NGHTTP2_SETTINGS_MAX_HEADER_LIST_SIZE, HEAD_CAP}};
    if (nghttp2_submit_settings(s->h2, 0, settings, 3)) goto fail;
    nghttp2_session_callbacks_del(cb); nghttp2_option_del(opt);
    return s;
fail:
    nghttp2_session_callbacks_del(cb); nghttp2_option_del(opt); nghttp2_session_del(s->h2); free(s); return NULL;
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
    for (stream *p = s->streams; p; p = p->next)
        if (pump_backend(p)) nghttp2_submit_rst_stream(s->h2, 0, (int32_t)p->id, NGHTTP2_INTERNAL_ERROR);
    int r = nghttp2_session_send(s->h2);
    sweep(s);
    return r == 0 && (nghttp2_session_want_read(s->h2) || nghttp2_session_want_write(s->h2)) ? 1 + s->activity : 0;
}
static void free_session(session *s) {
    nghttp2_session_del(s->h2); nghttp3_conn_del(s->h3);
    s->h2 = NULL; s->h3 = NULL;
    for (stream *p = s->streams; p; p = p->next) p->closed = 1;
    sweep(s); free(s);
}
void zhttp_h2_free(void *ptr) { if (ptr) free_session(ptr); }

static int h3_header(nghttp3_conn *h, int64_t id, int32_t token, nghttp3_rcbuf *n, nghttp3_rcbuf *v,
                     uint8_t flags, void *user, void *su) {
    (void)h; (void)token; (void)flags; (void)su;
    nghttp3_vec name = nghttp3_rcbuf_get_buf(n), value = nghttp3_rcbuf_get_buf(v);
    return header(lookup(user, id), name.base, name.len, value.base, value.len) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}
static int h3_headers_done(nghttp3_conn *h, int64_t id, int fin, void *user, void *su) {
    (void)h; (void)fin; (void)su;
    return start_request(lookup(user, id)) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}
static int h3_data(nghttp3_conn *h, int64_t id, const uint8_t *data, size_t n, void *user, void *su) {
    (void)h; (void)su;
    return body(lookup(user, id), data, n) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}
static int h3_end(nghttp3_conn *h, int64_t id, void *user, void *su) {
    (void)h; (void)su;
    return end_request(lookup(user, id)) ? NGHTTP3_ERR_CALLBACK_FAILURE : 0;
}
static int h3_reset(nghttp3_conn *h, int64_t id, uint64_t code, void *user, void *su) {
    (void)h; (void)su;
    stream *p = lookup(user, id);
    if (p) { SSL_STREAM_RESET_ARGS args = {code}; SSL_stream_reset(p->quic, &args, sizeof(args)); }
    return 0;
}
static void h3_rand(uint8_t *dest, size_t n) { if (RAND_bytes(dest, (int)n) != 1) abort(); }
static int init_h3(session *s) {
    nghttp3_callbacks cb = {0};
    cb.recv_header = h3_header; cb.end_headers = h3_headers_done;
    cb.recv_data = h3_data; cb.end_stream = h3_end; cb.acked_stream_data = h3_acked;
    cb.stop_sending = h3_reset; cb.reset_stream = h3_reset; cb.rand = h3_rand;
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
static int drive_h3(session *s) {
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
        if (pump_backend(p)) return -1;
        if (p->read_fin || !(SSL_get_stream_type(p->quic) & SSL_STREAM_TYPE_READ)) continue;
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
            if (fin) { p->read_fin = 1; break; }
        }
    }
    for (int i = 0; i < 128; ++i) {
        nghttp3_vec vec[1]; int64_t id; int fin;
        nghttp3_ssize nv = nghttp3_conn_writev_stream(s->h3, &id, &fin, vec, 1);
        if (nv < 0) return -1;
        if (id < 0) break;
        stream *p = lookup(s, id); if (!p) return -1;
        size_t n = 0;
        if (nv && vec[0].len) {
            ERR_clear_error(); int r = SSL_write_ex(p->quic, vec[0].base, vec[0].len, &n);
            if (!r) {
                if (ssl_wait(p->quic, r)) { nghttp3_conn_block_stream(s->h3, id); continue; }
                nghttp3_conn_shutdown_stream_write(s->h3, id); p->closed = 1; continue;
            }
        }
        if (nghttp3_conn_add_write_offset(s->h3, id, n)) return -1;
        /* SSL_write_ex copies into OpenSSL's retransmission buffer. The nghttp3
         * buffers can be released immediately, independently of packet ACKs. */
        if (nghttp3_conn_add_ack_offset(s->h3, id, n)) return -1;
        if (fin && (!nv || n == vec[0].len)) {
            if (!SSL_stream_conclude(p->quic, 0)) return -1;
            p->write_fin = 1;
        }
    }
    for (stream *p = s->streams; p; p = p->next) {
        if (p->read_fin && p->write_fin) {
            nghttp3_conn_close_stream(s->h3, p->id, NGHTTP3_H3_NO_ERROR); p->closed = 1;
        } else nghttp3_conn_unblock_stream(s->h3, p->id);
    }
    sweep(s);
    return 0;
}
/* Inject one datagram at a time, processing it before the next receive. OpenSSL
 * 3.5 has no public QUIC peer-address getter. Its new-connection callback saves
 * the originating datagram's address, rather than attributing clients to UDP fd.
 * Read BIO is empty; only this function reads the real UDP socket. */
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
static BIO_ADDR *bio_addr(const struct sockaddr_storage *s) {
    BIO_ADDR *b = BIO_ADDR_new(); if (!b) return NULL;
    int r;
    if (s->ss_family == AF_INET) {
        const struct sockaddr_in *a = (const void *)s;
        r = BIO_ADDR_rawmake(b, AF_INET, &a->sin_addr, sizeof(a->sin_addr), a->sin_port);
    } else {
        const struct sockaddr_in6 *a = (const void *)s;
        r = BIO_ADDR_rawmake(b, AF_INET6, &a->sin6_addr, sizeof(a->sin6_addr), a->sin6_port);
    }
    if (!r) { BIO_ADDR_free(b); return NULL; } return b;
}
void *zhttp_h3_new(SSL_CTX *ctx, int fd, void *user, open_request open, unsigned limit) {
    listener *l = calloc(1, sizeof(*l)); if (!l) return NULL;
    l->fd = fd; l->user = user; l->open = open; l->limit = limit;
    if (peer_index < 0) peer_index = SSL_get_ex_new_index(0, NULL, NULL, NULL, peer_free);
    if (peer_index < 0) goto fail;
    l->ssl = SSL_new_listener(ctx, 0); if (!l->ssl) goto fail;
    SSL_CTX_set_new_pending_conn_cb(ctx, pending, l);
    BIO *rd = BIO_new(BIO_s_dgram_mem()), *wr = BIO_new_dgram(fd, BIO_NOCLOSE);
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
    return l;
fail:
    SSL_free(l->ssl); free(l); return NULL;
}
void zhttp_h3_drive(void *ptr) {
    listener *l = ptr;
    for (int i = 0; i < 128; ++i) {
        uint8_t buf[65536], control[256]; struct iovec iov = {buf, sizeof(buf)};
        struct msghdr msg = {0};
        msg.msg_name = &l->peer; msg.msg_namelen = sizeof(l->peer);
        msg.msg_iov = &iov; msg.msg_iovlen = 1; msg.msg_control = control; msg.msg_controllen = sizeof(control);
        ssize_t n = recvmsg(l->fd, &msg, 0); if (n < 0) break;
        if (msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC)) continue;
        socklen_t len = sizeof(l->local); if (getsockname(l->fd, (struct sockaddr *)&l->local, &len)) continue;
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
        BIO_ADDR *peer = bio_addr(&l->peer), *local = bio_addr(&l->local);
        if (peer && local) { SSL_inject_net_dgram(l->ssl, buf, (size_t)n, peer, local); SSL_handle_events(l->ssl); }
        BIO_ADDR_free(peer); BIO_ADDR_free(local);
    }
    SSL_handle_events(l->ssl);
    SSL *q;
    while ((q = SSL_accept_connection(l->ssl, SSL_ACCEPT_CONNECTION_NO_BLOCK))) {
        peer_info *pi = SSL_get_ex_data(q, peer_index);
        session *s = pi ? calloc(1, sizeof(*s)) : NULL;
        if (!s) { SSL_free(q); continue; }
        s->ssl = q; s->open = l->open; s->user = l->user; s->peer = pi->peer; s->local = pi->local;
        SSL_set_default_stream_mode(q, SSL_DEFAULT_STREAM_MODE_NONE);
        SSL_set_incoming_stream_policy(q, SSL_INCOMING_STREAM_POLICY_ACCEPT, 0);
        s->next = l->sessions; l->sessions = s;
    }
    session **pp = &l->sessions;
    while (*pp) {
        session *s = *pp;
        if (drive_h3(s)) {
            *pp = s->next; SSL_shutdown_ex(s->ssl, SSL_SHUTDOWN_FLAG_RAPID, NULL, 0);
            SSL *ssl = s->ssl; free_session(s); SSL_free(ssl);
        } else pp = &s->next;
    }
}
void zhttp_h3_free(void *ptr) {
    if (!ptr) return;
    listener *l = ptr;
    while (l->sessions) {
        session *s = l->sessions; l->sessions = s->next;
        SSL *ssl = s->ssl; free_session(s); SSL_free(ssl);
    }
    SSL_free(l->ssl); free(l);
}
