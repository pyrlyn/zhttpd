/* HTTP/2 codec. Each request uses bounded memory buffers to the existing
 * Zig request engine; nghttp2 owns HPACK and flow control. HTTP/3 runs on the
 * Zig zquic transport (src/server/h3.zig).
 */
#include <nghttp2/nghttp2.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <ctype.h>

int zhttp_tx_attached(SSL *ssl); /* tls_tx.c */
int zhttp_tx_ready(SSL *ssl);
void zhttp_tx_prepare_write(SSL *ssl);
int zhttp_tx_seal_frame(SSL *ssl, const uint8_t *head, size_t hn, const uint8_t *data, size_t n);

#define STREAMS 32
#define INPUT_CAP (64 * 1024)
#define INPUT_INITIAL_CAP 1024
#define HEAD_INITIAL_CAP 1024
#define OUTPUT_INITIAL_CAP 2048
#define H2_OUTPUT_CAP (16 * 1024)
/* Two DATA payloads plus their 9-byte frame headers fill two TLS records. */
#define OUTPUT_CAP (2 * (H2_OUTPUT_CAP - 9))
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
    void *request;
    int started, request_end, chunked, eof, submitted, closed, read_fin, write_fin;
    char *headers;
    size_t headers_len, header_count, headers_cap;
    uint8_t *input, *output;
    size_t input_len, input_pos, input_cap, output_len, output_pos, output_cap, credit, offered;
    /* Borrowed from the live Zig request; never closed by the codec. */
    int file_active, file_offer, file_fd;
    uint64_t file_offset, file_left;
    size_t file_sent;
    /* Read-only window of the borrowed file, sealed straight into TLS records. */
    uint8_t *map;
    uint64_t map_off;
    size_t map_len;
    char method[32], authority[1024], content_length[32], path[8193];
};
struct session {
    session *next;
    SSL *ssl;
    nghttp2_session *h2;
    uint8_t *h2_output;
    size_t h2_output_len, h2_output_pos;
    int h2_write_blocked;
    /* tx: records are sealed by tls_tx.c, which batches socket writes.
     * h2_large selects the larger per-turn budget for that path. */
    int tx, h2_large;
    BIO *h2_buffer;
    stream *streams;
    unsigned nstreams;
    void *user;
    open_request open;
    drive_request drive;
    close_request close;
    struct sockaddr_storage peer, local;
    int activity;
};
/* One bounded cache per event-loop thread, shared across its connections.
 * Release it when the final session closes; idle connections cannot retain a
 * separate cache each. Active stream buffers still follow STREAMS limits. */
static _Thread_local stream *stream_cache;
static _Thread_local unsigned cached_streams, active_sessions;
static _Thread_local size_t cached_output_bytes;

#define MAP_WINDOW ((size_t)4 << 20)
static void unmap_file(stream *p) {
#ifdef __linux__
    if (p->map) munmap(p->map, p->map_len);
#endif
    p->map = NULL; p->map_len = 0;
}
/* The mapping outlives a close of the descriptor, so ownership of the window
 * stays with the stream. NULL selects the pread path. */
static const uint8_t *map_file(stream *p, size_t n) {
#ifdef __linux__
    uint64_t at = p->file_offset;
    if (p->map && at >= p->map_off && at + n <= p->map_off + p->map_len)
        return p->map + (at - p->map_off);
    unmap_file(p);
    static size_t page;
    if (!page) page = (size_t)sysconf(_SC_PAGESIZE);
    uint64_t start = at & ~(uint64_t)(page - 1);
    uint64_t want = at - start + p->file_left;
    size_t len = want < MAP_WINDOW ? (size_t)want : MAP_WINDOW;
    if (at - start + n > len) return NULL;
    void *m = mmap(NULL, len, PROT_READ, MAP_SHARED | MAP_POPULATE, p->file_fd, (off_t)start);
    if (m == MAP_FAILED) return NULL;
    p->map = m; p->map_off = start; p->map_len = len;
    return p->map + (at - start);
#else
    (void)p; (void)n;
    return NULL;
#endif
}
static void free_stream(stream *p) {
    unmap_file(p);
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
static stream *new_stream(session *s, int64_t id) {
    if (s->nstreams >= STREAMS) return NULL;
    stream *p;
    char *headers = NULL; uint8_t *input = NULL, *output = NULL;
    size_t output_cap = OUTPUT_INITIAL_CAP, input_cap = INPUT_INITIAL_CAP, headers_cap = HEAD_INITIAL_CAP;
    if (stream_cache) {
        p = stream_cache; stream_cache = p->next; --cached_streams;
        headers = p->headers; input = p->input; output = p->output;
        output_cap = p->output_cap; cached_output_bytes -= output_cap;
        input_cap = p->input_cap;
        headers_cap = p->headers_cap;
    } else p = malloc(sizeof(*p));
    if (!p) return NULL;
    /* Field strings are length checked and terminated by copy_field. Reset
     * their empty markers, not 9 KiB of unused URI/authority capacity. */
    memset(p, 0, offsetof(stream, method));
    p->headers = headers; p->input = input; p->output = output; p->output_cap = output_cap;
    p->input_cap = input_cap;
    p->headers_cap = headers_cap;
    p->method[0] = p->path[0] = p->authority[0] = p->content_length[0] = 0;
    if (!p->headers) {
        p->headers = malloc(headers_cap);
        p->input = malloc(input_cap);
        p->output = malloc(output_cap + 1);
        if (!p->headers || !p->input || !p->output) {
            free_stream(p); return NULL;
        }
    }
    p->owner = s; p->id = id;
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
        unmap_file(p);
        if (p->headers && cached_streams < STREAMS && p->output_cap <= OUTPUT_CACHE_CAP - cached_output_bytes) {
            p->next = stream_cache; stream_cache = p; ++cached_streams;
            cached_output_bytes += p->output_cap;
        } else free_stream(p);
        --s->nstreams;
    }
}
static int reserve_input(stream *p, size_t needed) {
    if (needed > INPUT_CAP) return -1;
    /* GET requests only need the bounded header bridge. Grow for request
     * bodies, retaining the same receive limit and flow-control budget.
     * No external consumer keeps a pointer into the input buffer. */
    if (needed > p->input_cap) {
        size_t capacity = p->input_cap;
        while (capacity < needed) capacity *= 2;
        uint8_t *larger = realloc(p->input, capacity);
        if (!larger) return -1;
        p->input = larger; p->input_cap = capacity;
    }
    return 0;
}
static int append(stream *p, const void *data, size_t len) {
    if (len > INPUT_CAP - p->input_len || reserve_input(p, p->input_len + len)) return -1;
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
    if (p->headers_len + nn + vn + 4 > p->headers_cap) {
        char *larger = realloc(p->headers, HEAD_CAP);
        if (!larger) return -1;
        p->headers = larger; p->headers_cap = HEAD_CAP;
    }
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
    if (reserve_input(p, n + p->headers_len + 2)) return -1;
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
    p->request = s->open(s->user, p, (struct sockaddr *)&s->peer, (struct sockaddr *)&s->local, 2);
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
    if (len > p->output_cap - p->output_len && p->output_cap < OUTPUT_CAP && !p->offered) {
        uint8_t *larger = realloc(p->output, OUTPUT_CAP + 1);
        if (larger) { p->output = larger; p->output_cap = OUTPUT_CAP; }
        /* An incomplete header cannot drain through the codec. Failing its
         * growth must close the request instead of waiting on a full buffer. */
        else if (!p->submitted) return -2;
    }
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
    /* Never relocate a vector retained by the codec, and leave small
     * responses at the original allocation size. Allocation failure simply
     * retains the smaller, correct path. */
    if (remaining > p->output_cap - p->output_len && !p->offered && p->output_cap < OUTPUT_CAP) {
        uint8_t *larger = realloc(p->output, OUTPUT_CAP + 1);
        if (larger) { p->output = larger; p->output_cap = OUTPUT_CAP; }
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
    if (p->file_active) {
        /* Timeout/cancellation can close the application's descriptor while
         * a DATA frame is deferred. Never read it after ownership returns. */
        if (p->file_left && !p->closed && p->owner->h2)
            nghttp2_submit_rst_stream(p->owner->h2, 0, (int32_t)p->id, NGHTTP2_INTERNAL_ERROR);
        p->file_active = 0; p->file_fd = -1;
    }
    unmap_file(p);
    p->request = NULL; p->eof = 1; p->owner->activity = 1;
}
/* -1 waits for flow control, -2 reports an I/O error. Positive values
 * acknowledge bytes copied into codec-owned storage. The application retains
 * the descriptor until all of those bytes have been reported. */
ssize_t zhttp_stream_file(void *ptr, int fd, uint64_t offset, uint64_t remaining) {
    stream *p = ptr;
    if (p->closed || p->eof) return -2;
    if (p->file_active) {
        size_t n = p->file_sent; p->file_sent = 0;
        if (!p->file_left && !p->offered) p->file_active = 0;
        return n ? (ssize_t)n : -1;
    }
    if (remaining <= OUTPUT_CAP) {
        uint8_t *buf;
        ssize_t capacity = zhttp_stream_writable(p, &buf, remaining);
        if (capacity <= 0) return capacity ? -2 : -1;
        size_t len = remaining < (uint64_t)capacity ? (size_t)remaining : (size_t)capacity;
        ssize_t n;
        do { n = pread(fd, buf, len, (off_t)offset); } while (n < 0 && errno == EINTR);
        if (n <= 0) return -2;
        zhttp_stream_commit(p, (size_t)n);
        return n;
    }
    p->file_active = 1; p->file_fd = fd;
    p->file_offset = offset; p->file_left = remaining;
    return -1;
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
    if (!n && p->file_active && p->file_left) {
        n = p->file_left < len ? (size_t)p->file_left : len;
        if (n > H2_OUTPUT_CAP - 9) n = H2_OUTPUT_CAP - 9;
        *flags |= NGHTTP2_DATA_FLAG_NO_COPY;
        p->offered = n; p->file_offer = 1;
        return (nghttp2_ssize)n;
    }
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
static int hop_header(const char *name, size_t len) {
    return eq_literal(name, len, "connection") || eq_literal(name, len, "keep-alive") ||
        eq_literal(name, len, "transfer-encoding") || eq_literal(name, len, "upgrade") ||
        eq_literal(name, len, "proxy-connection") || eq_literal(name, len, "trailer");
}
/* The Zig stream connection emits HTTP/1.0 framing: no chunked response body.
 * Libraries copy these header fields before this scratch buffer is reused. */
static int response_headers(stream *p) {
    size_t scan = p->output_len < OUTPUT_CAP ? p->output_len : OUTPUT_CAP;
    uint8_t *lim = p->output + scan;
    /* One memchr per line; the block ends at the first empty CRLF line.
     * Names are lowercased in place, which is idempotent if incomplete. */
    uint8_t *nl = memchr(p->output, '\n', scan);
    if (!nl) return p->output_len >= OUTPUT_CAP ? -1 : 0;
    if (nl - p->output < 13 || nl[-1] != '\r' || memcmp(p->output, "HTTP/1.", 7)) return -1;
    char status[4]; memcpy(status, p->output + 9, 3); status[3] = 0;
    /* Informational headers are discarded (Expect is stripped), not parsed. */
    int info = status[0] == '1';
    nghttp2_nv n2[100]; size_t count = 1;
    n2[0] = (nghttp2_nv){(uint8_t *)":status", (uint8_t *)status, 7, 3, 0};
    for (;;) {
        uint8_t *line = nl + 1;
        if (lim - line < 2) return p->output_len >= OUTPUT_CAP ? -1 : 0;
        if (line[0] == '\r' && line[1] == '\n') { nl = line + 1; break; }
        nl = memchr(line, '\n', (size_t)(lim - line));
        if (!nl) return p->output_len >= OUTPUT_CAP ? -1 : 0;
        if (nl[-1] != '\r') return -1;
        if (info) continue;
        uint8_t *v = memchr(line, ':', (size_t)(nl - 1 - line)); if (!v) return -1;
        size_t name_len = (size_t)(v - line);
        ++v; while (v < nl - 1 && (*v == ' ' || *v == '\t')) ++v;
        size_t value_len = (size_t)(nl - 1 - v);
        for (size_t i = 0; i < name_len; ++i) if (line[i] >= 'A' && line[i] <= 'Z') line[i] += 'a' - 'A';
        if (hop_header((const char *)line, name_len)) continue;
        if (count == 100) return -1;
        n2[count] = (nghttp2_nv){line, v, name_len, value_len, 0};
        ++count;
    }
    size_t head = (size_t)(nl + 1 - p->output);
    if (info) {
        memmove(p->output, nl + 1, p->output_len - head); p->output_len -= head;
        return response_headers(p);
    }
    nghttp2_data_provider2 dr = {{.ptr = p}, h2_read};
    if (nghttp2_submit_response2(p->owner->h2, (int32_t)p->id, n2, count, &dr)) return -1;
    p->submitted = 1;
    memmove(p->output, nl + 1, p->output_len - head); p->output_len -= head;
    return 0;
}
static int pump_backend(stream *p) {
    if (!p->started || p->closed) return 0;
    if (p->output_pos == p->output_len && !p->offered) p->output_pos = p->output_len = 0;
    /* A completed request cannot consume more input. Let the codec drain its
     * retained response bytes before revisiting the application writer. */
    if (p->request && (!p->file_active || p->file_sent || !p->request_end || p->input_pos < p->input_len) &&
        (!p->output_len || !p->request_end || p->input_pos < p->input_len || !p->submitted))
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
    if (p->submitted) nghttp2_session_resume_data(p->owner->h2, (int32_t)p->id);
    return 0;
}

static int h2_begin(nghttp2_session *h, const nghttp2_frame *f, void *user) {
    (void)h;
    if (f->headers.cat != NGHTTP2_HCAT_REQUEST) return 0;
    session *s = user;
    if (s->nstreams >= STREAMS || !new_stream(s, f->hd.stream_id)) return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
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
    if (p->file_offer && p->file_fd < 0) return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
    if (s->h2_write_blocked || H2_OUTPUT_CAP - s->h2_output_len < n + 9)
        return NGHTTP2_ERR_WOULDBLOCK;
    /* With every earlier byte already handed to SSL_write, a file DATA frame
     * becomes one record sealed from the page cache: no pread, no plaintext copy. */
    int direct = p->file_offer && s->tx && !s->h2_output_len && zhttp_tx_ready(s->ssl);
    const uint8_t *src = direct ? map_file(p, n) : NULL;
    if (src) {
        int r = zhttp_tx_seal_frame(s->ssl, head, 9, src, n);
        if (!r) return NGHTTP2_ERR_WOULDBLOCK;
        if (r < 0) { unmap_file(p); return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE; }
        s->h2_large = 1;
        p->file_offset += n; p->file_left -= n; p->file_sent += n;
        p->file_offer = 0; p->offered = 0; s->activity = 1;
        if (!p->file_left) unmap_file(p);
        return 0;
    }
    /* Large responses otherwise issue one socket write per TLS record.
     * Buffer ciphertext below SSL, so KeyUpdate and record retry ownership
     * remain with OpenSSL. Small-only connections allocate no extra buffer. */
    if (s->tx) s->h2_large = 1;
    else if (!s->h2_buffer) {
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
    uint8_t *body_out = s->h2_output + s->h2_output_len + 9;
    if (p->file_offer) {
        size_t done = 0;
        while (done < n) {
            ssize_t r = pread(p->file_fd, body_out + done, n - done, (off_t)(p->file_offset + done));
            if (r < 0 && errno == EINTR) continue;
            if (r <= 0) return NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE;
            done += (size_t)r;
        }
        p->file_offset += n; p->file_left -= n; p->file_sent += n;
        p->file_offer = 0;
        if (!p->file_left) unmap_file(p);
    } else memcpy(body_out, p->output + p->output_pos - n, n);
    s->h2_output_len += n + 9; s->activity = 1; p->offered = 0;
    return 0;
}
static int flush_h2(session *s) {
    if (s->tx && s->h2_output_pos < s->h2_output_len) zhttp_tx_prepare_write(s->ssl);
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
    s->tx = zhttp_tx_attached(ssl);
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
/* Sealed records wait in the write BIO's batch until the end of the turn. */
static __attribute__((noinline)) int finish_tx_h2(session *s, int activity) {
    BIO *b = SSL_get_wbio(s->ssl);
    size_t pending = (size_t)BIO_wpending(b);
    if (pending) {
        ERR_clear_error();
        if (BIO_flush(b) <= 0 && !BIO_should_retry(b)) return 0;
        size_t remaining = (size_t)BIO_wpending(b);
        activity |= remaining < pending;
        pending = remaining;
    }
    if (!pending && !s->nstreams && !s->h2_output_len && !s->h2_write_blocked) s->h2_large = 0;
    return pending || s->h2_output_len || nghttp2_session_want_read(s->h2) || nghttp2_session_want_write(s->h2) ? 1 + activity : 0;
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
    const int passes = s->h2_buffer || s->h2_large ? 64 : 4;
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
    if (s->tx) return finish_tx_h2(s, activity);
    if (s->h2_buffer) return finish_buffered_h2(s, activity);
    return s->h2_output_len || nghttp2_session_want_read(s->h2) || nghttp2_session_want_write(s->h2) ? 1 + activity : 0;
}
static void free_session(session *s) {
    nghttp2_session_del(s->h2);
    s->h2 = NULL;
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
