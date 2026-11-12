/* Exercise the real datagram adapters, including packet boundaries and bounded
 * receive batches. Linking the codec also compiles both transport paths. */
#include <assert.h>
#include <stdlib.h>
#include <openssl/bio.h>
static int fail_growth;
static void *codec_realloc(void *ptr, size_t size) {
    return fail_growth ? NULL : realloc(ptr, size);
}
static size_t plain_calls, plain_max;
static int record_sendmmsg(BIO *bio, BIO_MSG *msg, size_t stride, size_t count,
                           uint64_t flags, size_t *processed) {
    ++plain_calls;
    if (count > plain_max) plain_max = count;
    return BIO_sendmmsg(bio, msg, stride, count, flags, processed);
}
#define realloc codec_realloc
#define BIO_sendmmsg record_sendmmsg
#include "../src/server/multiplex.c"
#undef realloc
#undef BIO_sendmmsg

static int udp_socket(struct sockaddr_in *addr) {
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
    assert(fd >= 0);
    *addr = (struct sockaddr_in){.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    assert(bind(fd, (struct sockaddr *)addr, sizeof(*addr)) == 0);
    socklen_t n = sizeof(*addr);
    assert(getsockname(fd, (struct sockaddr *)addr, &n) == 0);
    return fd;
}
static BIO_ADDR *bio_peer(struct sockaddr_in addr) {
    BIO_ADDR *out = BIO_ADDR_new();
    assert(out && BIO_ADDR_rawmake(out, AF_INET, &addr.sin_addr, sizeof(addr.sin_addr), addr.sin_port));
    return out;
}
static void output_boundaries(void) {
    struct sockaddr_in a, b, source;
    int rx_a = udp_socket(&a), rx_b = udp_socket(&b), tx = udp_socket(&source);
    BIO_ADDR *peer_a = bio_peer(a), *peer_b = bio_peer(b), *local = bio_peer(source);
    quic_output output = {0};
    BIO *bio = quic_output_new(&output, tx); assert(bio);
    assert(BIO_dgram_set_local_addr_enable(bio, 1));
    unsigned char data[70][1400]; BIO_MSG msgs[70];
    for (unsigned i = 0; i < 70; ++i) {
        memset(data[i], (int)i, sizeof(data[i]));
        msgs[i] = (BIO_MSG){.data = data[i], .data_len = i == 30 || i == 69 ? 27 : sizeof(data[i]),
            .peer = i < 31 ? peer_a : peer_b, .local = local};
    }
    for (int mode = 0; mode < 4; ++mode) {
        if (mode == 3) for (unsigned i = 0; i < 70; ++i) msgs[i].data_len = 100 + 13 * i;
        output.disabled = mode == 1;
        output.fd = mode == 2 ? -1 : tx; /* GSO syscall failure must fall back without losing packets. */
        size_t sent = 0;
        plain_calls = plain_max = 0;
        assert(BIO_sendmmsg(bio, msgs, sizeof(msgs[0]), 70, 0, &sent) == 1 && sent == 70);
        if (mode == 3) assert(plain_calls <= 2 && plain_max >= 64);
        for (unsigned i = 0; i < 70; ++i) {
            unsigned char got[1600]; struct sockaddr_in peer; socklen_t len = sizeof(peer);
            ssize_t n = recvfrom(i < 31 ? rx_a : rx_b, got, sizeof(got), 0, (struct sockaddr *)&peer, &len);
            assert(n == (ssize_t)msgs[i].data_len && !memcmp(got, data[i], (size_t)n));
            assert(peer.sin_addr.s_addr == source.sin_addr.s_addr && peer.sin_port == source.sin_port);
        }
    }
    BIO_free(bio); BIO_meth_free(output.method);
    BIO_ADDR_free(peer_a); BIO_ADDR_free(peer_b); BIO_ADDR_free(local);
    close(tx); close(rx_a); close(rx_b);
}
static void output_ipv6_fallback(void) {
    struct sockaddr_in6 peer = {.sin6_family = AF_INET6, .sin6_addr = IN6ADDR_LOOPBACK_INIT};
    int rx = socket(AF_INET6, SOCK_DGRAM | SOCK_NONBLOCK, 0);
    int tx = socket(AF_INET6, SOCK_DGRAM | SOCK_NONBLOCK, 0);
    assert(rx >= 0 && tx >= 0);
    assert(bind(rx, (struct sockaddr *)&peer, sizeof(peer)) == 0);
    socklen_t len = sizeof(peer);
    assert(getsockname(rx, (struct sockaddr *)&peer, &len) == 0);
    BIO_ADDR *addr = BIO_ADDR_new();
    assert(addr && BIO_ADDR_rawmake(addr, AF_INET6, &peer.sin6_addr, sizeof(peer.sin6_addr), peer.sin6_port));
    quic_output output = {0};
    BIO *bio = quic_output_new(&output, tx); assert(bio);
    unsigned char data[3][1400]; BIO_MSG msgs[3];
    for (unsigned i = 0; i < 3; ++i) {
        memset(data[i], (int)i + 1, sizeof(data[i]));
        msgs[i] = (BIO_MSG){.data = data[i], .data_len = sizeof(data[i]), .peer = addr};
    }
    size_t sent = 0;
    assert(BIO_sendmmsg(bio, msgs, sizeof(msgs[0]), 3, 0, &sent) == 1 && sent == 3);
    for (unsigned i = 0; i < 3; ++i) {
        unsigned char got[1401];
        assert(recv(rx, got, sizeof(got), 0) == sizeof(data[i]));
        assert(!memcmp(got, data[i], sizeof(data[i])));
    }
    BIO_free(bio); BIO_meth_free(output.method); BIO_ADDR_free(addr);
    close(rx); close(tx);
}
static void input_budget(void) {
    struct sockaddr_in addr, source;
    int rx = udp_socket(&addr), tx = udp_socket(&source);
    for (unsigned i = 0; i < 131; ++i)
        assert(sendto(tx, &i, sizeof(i), 0, (struct sockaddr *)&addr, sizeof(addr)) == sizeof(i));
    unsigned received = 0;
    /* A short first turn must not consume and then discard packets beyond its budget. */
    for (unsigned budget = 5; received < 131; budget = 128) {
        unsigned index = 0, count = 0;
        for (unsigned i = 0; i < budget; ++i) {
            unsigned char *data; struct msghdr msg;
            ssize_t n = quic_recv(rx, budget - i, &index, &count, &data, &msg);
            if (n < 0) break;
            unsigned value; memcpy(&value, data, sizeof(value));
            assert(n == sizeof(value) && value == received++);
        }
        assert(index == count);
        assert(received == 5 || received == 131);
    }
    close(tx); close(rx);
    free(quic_input); quic_input = NULL;
}
static void output_growth_and_cache(void) {
    session s = {0};
    stream *p = new_stream(&s, 0, NULL); assert(p);
    uint8_t *buf, *original = p->output;
    memset(p->output, 0x5a, 100); p->output_len = 100;
    assert(zhttp_stream_writable(p, &buf, 612) == OUTPUT_INITIAL_CAP - 100);
    assert(p->output == original && p->output_cap == OUTPUT_INITIAL_CAP);
    p->offered = 100;
    assert(zhttp_stream_writable(p, &buf, 1024 * 1024) == OUTPUT_INITIAL_CAP - 100);
    assert(p->output == original); /* a retained vector must never move */
    p->offered = 0;
    assert(zhttp_stream_writable(p, &buf, 1024 * 1024) == FILE_OUTPUT_CAP - 100);
    assert(p->output_cap == FILE_OUTPUT_CAP && p->output_len == 100);
    for (unsigned i = 0; i < 100; ++i) assert(p->output[i] == 0x5a);
    assert(buf == p->output + 100);
    /* Growing the body buffer must not relax the response header limit. */
    memset(p->output, 'x', OUTPUT_CAP + 4);
    memcpy(p->output + OUTPUT_CAP, "\r\n\r\n", 4); p->output_len = OUTPUT_CAP + 4;
    assert(response_headers(p) == -1);
    for (int i = 1; i < 16; ++i) {
        p = new_stream(&s, 4 * i, NULL); assert(p);
        assert(zhttp_stream_writable(p, &buf, 1024 * 1024) == FILE_OUTPUT_CAP);
    }
    for (p = s.streams; p; p = p->next) p->closed = 1;
    sweep(&s);
    assert(!s.streams && s.nstreams == 0);
    assert(cached_output_bytes <= OUTPUT_CACHE_CAP);
    assert(cached_streams == OUTPUT_CACHE_CAP / FILE_OUTPUT_CAP);
    size_t cached = cached_output_bytes;
    p = new_stream(&s, 0, NULL); assert(p);
    assert(p->output_cap == FILE_OUTPUT_CAP && p->output_len == 0);
    assert(cached_output_bytes == cached - p->output_cap);
    p->closed = 1; sweep(&s);
    while (stream_cache) {
        p = stream_cache; stream_cache = p->next; free_stream(p);
    }
    cached_streams = 0; cached_output_bytes = 0;
}
static void *capture_bridge(void *user, void *p, const struct sockaddr *peer,
                            const struct sockaddr *local, int version) {
    (void)peer; (void)local; assert(version == 2); ++*(unsigned *)user; return p;
}
static void request_body_growth(void) {
    session s = {0};
    stream *p = new_stream(&s, 1, NULL); assert(p);
    assert(p->input_cap == INPUT_INITIAL_CAP);
    uint8_t data[8192]; memset(data, 0x5a, sizeof(data));
    for (unsigned i = 0; i < INPUT_CAP / sizeof(data); ++i)
        assert(append(p, data, sizeof(data)) == 0);
    assert(p->input_len == INPUT_CAP && p->input_cap == INPUT_CAP);
    assert(append(p, data, 1) == -1);
    for (unsigned i = 0; i < INPUT_CAP; ++i) assert(p->input[i] == 0x5a);
    p->closed = 1; sweep(&s);
    p = new_stream(&s, 3, NULL); assert(p);
    assert(p->input_cap == INPUT_CAP && p->input_len == 0);
    assert(append(p, data, sizeof(data)) == 0);
    free_stream(p);
}
static void allocation_failure(void) {
    session s = {0};
    stream *p = new_stream(&s, 1, NULL); assert(p);
    uint8_t data[4096]; memset(data, 'x', sizeof(data));
    assert(append(p, data, INPUT_INITIAL_CAP) == 0);
    uint8_t *input = p->input, *output = p->output, *space;
    fail_growth = 1;
    assert(append(p, data, 1) == -1);
    assert(p->input == input && p->input_len == INPUT_INITIAL_CAP);
    assert(!memcmp(input, data, INPUT_INITIAL_CAP));
    assert(header(p, (const uint8_t *)"x-large", 7, data, sizeof(data)) == -1);
    assert(p->headers_len == 0 && p->headers_cap == HEAD_INITIAL_CAP);
    /* An incomplete response header cannot drain, so fail instead of hang. */
    assert(zhttp_stream_write(p, data, sizeof(data)) == -2);
    assert(p->output == output && p->output_len == 0);
    /* Body/file producers can continue in smaller chunks after allocation
     * failure; retained nghttp3 vectors must still never move. */
    assert(zhttp_stream_writable(p, &space, 1024 * 1024) == OUTPUT_INITIAL_CAP);
    assert(space == output);
    p->submitted = 1;
    assert(zhttp_stream_write(p, data, sizeof(data)) == OUTPUT_INITIAL_CAP);
    assert(zhttp_stream_write(p, data, 1) == -1);
    assert(!memcmp(output, data, OUTPUT_INITIAL_CAP));
    fail_growth = 0;
    p->offered = OUTPUT_INITIAL_CAP;
    assert(zhttp_stream_write(p, data, 1) == -1 && p->output == output);
    free_stream(p);
}
static void h2_file_lifetime(void) {
    session s = {0};
    nghttp2_session_callbacks *cb;
    assert(nghttp2_session_callbacks_new(&cb) == 0);
    assert(nghttp2_session_server_new(&s.h2, cb, NULL) == 0);
    nghttp2_session_callbacks_del(cb);
    s.h2_output = malloc(H2_OUTPUT_CAP); assert(s.h2_output);
    s.h2_buffer = BIO_new(BIO_s_mem()); assert(s.h2_buffer);
    stream *p = new_stream(&s, 1, NULL); assert(p);
    FILE *file = tmpfile(); assert(file);
    uint8_t data[65536 + 17];
    for (size_t i = 0; i < sizeof(data); ++i) data[i] = (uint8_t)(i * 31);
    assert(fwrite(data, 1, sizeof(data), file) == sizeof(data) && fflush(file) == 0);
    int fd = fileno(file);
    assert(zhttp_stream_file(p, fd, 17, 65536) == -1);
    size_t reported = 0;
    nghttp2_data_source source = {.ptr = p}; nghttp2_frame frame = {0};
    uint8_t head[9] = {0};
    while (reported < 65536) {
        uint32_t flags = 0;
        nghttp2_ssize n = h2_read(s.h2, 1, NULL, H2_OUTPUT_CAP, &flags, &source, &s);
        assert(n > 0 && (flags & NGHTTP2_DATA_FLAG_NO_COPY));
        s.h2_write_blocked = 1;
        assert(h2_send_data(s.h2, &frame, head, (size_t)n, &source, &s) == NGHTTP2_ERR_WOULDBLOCK);
        assert(p->file_sent == 0 && p->file_offset == 17 + reported);
        s.h2_write_blocked = 0;
        assert(h2_send_data(s.h2, &frame, head, (size_t)n, &source, &s) == 0);
        assert(s.h2_output_len == (size_t)n + 9);
        assert(!memcmp(s.h2_output + 9, data + 17 + reported, (size_t)n));
        assert(zhttp_stream_file(p, fd, 17 + reported, 65536 - reported) == n);
        reported += (size_t)n;
        s.h2_output_len = 0; /* simulate a completed TLS flush */
    }
    assert(!p->file_active && p->output_cap == OUTPUT_INITIAL_CAP);
    /* A file truncated while serving it resets its stream. Cancellation
     * invalidates the borrowed descriptor even if a DATA offer is pending. */
    assert(zhttp_stream_file(p, fd, sizeof(data), 65536) == -1);
    uint32_t flags = 0;
    size_t n = (size_t)h2_read(s.h2, 1, NULL, H2_OUTPUT_CAP, &flags, &source, &s);
    assert(h2_send_data(s.h2, &frame, head, n, &source, &s) == NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE);
    assert(p->file_sent == 0 && s.h2_output_len == 0);
    zhttp_stream_finish(p);
    assert(!p->file_active && p->file_fd == -1);
    fclose(file);
    assert(h2_send_data(s.h2, &frame, head, n, &source, &s) == NGHTTP2_ERR_TEMPORAL_CALLBACK_FAILURE);
    free_stream(p); BIO_free(s.h2_buffer); free(s.h2_output); nghttp2_session_del(s.h2);
}
static void request_bridge_format_and_limit(void) {
    unsigned opened = 0; session s = {.open = capture_bridge, .user = &opened};
    stream *p = new_stream(&s, 1, NULL); assert(p);
    strcpy(p->method, "POST"); strcpy(p->path, "/path?q=x"); strcpy(p->authority, "example.test");
    strcpy(p->content_length, "123");
    const char extra[] = "x-test: value\r\n";
    memcpy(p->headers, extra, sizeof(extra) - 1); p->headers_len = sizeof(extra) - 1;
    const char expected[] = "POST /path?q=x HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\nContent-Length: 123\r\nx-test: value\r\n\r\n";
    assert(start_request(p) == 0 && opened == 1);
    assert(p->input_len == sizeof(expected) - 1 && !memcmp(p->input, expected, sizeof(expected) - 1));
    p->started = 0; p->request = NULL; p->content_length[0] = 0; p->headers_len = 0;
    const char chunked[] = "POST /path?q=x HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n";
    assert(start_request(p) == 0 && opened == 2);
    assert(p->input_len == sizeof(chunked) - 1 && !memcmp(p->input, chunked, sizeof(chunked) - 1));
    p->started = 0; p->request = NULL;
    uint8_t large_header[2048]; memset(large_header, 'x', sizeof(large_header));
    assert(header(p, (const uint8_t *)"x-large", 7, large_header, sizeof(large_header)) == 0);
    assert(p->headers_cap == HEAD_CAP);
    assert(!memcmp(p->headers + 9, large_header, sizeof(large_header)));
    p->headers_len = HEAD_CAP - (sizeof(chunked) - 1);
    memset(p->headers, 'x', p->headers_len);
    assert(start_request(p) == 0 && opened == 3 && p->input_len == HEAD_CAP);
    p->started = 0; p->request = NULL; ++p->headers_len;
    assert(start_request(p) == -1 && opened == 3);
    free_stream(p);
}
static void h3_stream_association_lifetime(void) {
    session *s = calloc(1, sizeof(*s)); assert(s); ++active_sessions;
    nghttp3_callbacks cb = {0}; nghttp3_settings settings; nghttp3_settings_default(&settings);
    assert(nghttp3_conn_server_new(&s->h3, &cb, &settings, NULL, s) == 0);
    stream *p = new_stream(s, 0, NULL); assert(p);
    assert(nghttp3_conn_read_stream(s->h3, 0, NULL, 0, 0) == 0);
    assert(h3_headers_begin(s->h3, 0, s, NULL) == 0);
    assert(nghttp3_conn_get_stream_user_data(s->h3, 0) == p);
    /* Simulate transport teardown while nghttp3 still owns its stream. */
    p->closed = 1; sweep(s);
    assert(nghttp3_conn_get_stream_user_data(s->h3, 0) == NULL);
    stream *reused = new_stream(s, 4, NULL); assert(reused == p);
    reused->offered = 7;
    assert(h3_acked(s->h3, 0, 1, s, nghttp3_conn_get_stream_user_data(s->h3, 0)) == 0);
    assert(reused->offered == 7); /* an old stream cannot mutate the new owner */
    free_session(s);
    assert(!stream_cache && !cached_streams && !cached_output_bytes && !active_sessions);
}
int main(void) {
    output_boundaries(); output_ipv6_fallback(); input_budget(); output_growth_and_cache(); request_body_growth(); allocation_failure(); h2_file_lifetime(); request_bridge_format_and_limit(); h3_stream_association_lifetime();
    puts("PASS: datagram batching/boundaries, input/output growth, allocation failure, bounded cache, HTTP/2 file ownership/backpressure, request limits and stream lifetime");
    return 0;
}
