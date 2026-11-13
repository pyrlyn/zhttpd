/* Exercise the HTTP/2 request bridge: buffer growth and caching, allocation
 * failure, file ownership under backpressure and request conversion limits. */
#include <assert.h>
#include <stdlib.h>
static int fail_growth;
static void *codec_realloc(void *ptr, size_t size) {
    return fail_growth ? NULL : realloc(ptr, size);
}
#define realloc codec_realloc
#include "../src/server/multiplex.c"
#undef realloc

static void output_growth_and_cache(void) {
    session s = {0};
    stream *p = new_stream(&s, 0); assert(p);
    uint8_t *buf, *original = p->output;
    memset(p->output, 0x5a, 100); p->output_len = 100;
    assert(zhttp_stream_writable(p, &buf, 612) == OUTPUT_INITIAL_CAP - 100);
    assert(p->output == original && p->output_cap == OUTPUT_INITIAL_CAP);
    p->offered = 100;
    assert(zhttp_stream_writable(p, &buf, 1024 * 1024) == OUTPUT_INITIAL_CAP - 100);
    assert(p->output == original); /* a retained vector must never move */
    p->offered = 0;
    assert(zhttp_stream_writable(p, &buf, 1024 * 1024) == OUTPUT_CAP - 100);
    assert(p->output_cap == OUTPUT_CAP && p->output_len == 100);
    for (unsigned i = 0; i < 100; ++i) assert(p->output[i] == 0x5a);
    assert(buf == p->output + 100);
    /* A full buffer without a complete response head fails instead of hanging. */
    memset(p->output, 'x', OUTPUT_CAP); p->output_len = OUTPUT_CAP;
    assert(response_headers(p) == -1);
    for (int i = 1; i < 16; ++i) {
        p = new_stream(&s, 4 * i); assert(p);
        assert(zhttp_stream_writable(p, &buf, 1024 * 1024) == OUTPUT_CAP);
    }
    for (p = s.streams; p; p = p->next) p->closed = 1;
    sweep(&s);
    assert(!s.streams && s.nstreams == 0);
    assert(cached_output_bytes <= OUTPUT_CACHE_CAP);
    assert(cached_streams == 16);
    size_t cached = cached_output_bytes;
    p = new_stream(&s, 0); assert(p);
    assert(p->output_cap == OUTPUT_CAP && p->output_len == 0);
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
    stream *p = new_stream(&s, 1); assert(p);
    assert(p->input_cap == INPUT_INITIAL_CAP);
    uint8_t data[8192]; memset(data, 0x5a, sizeof(data));
    for (unsigned i = 0; i < INPUT_CAP / sizeof(data); ++i)
        assert(append(p, data, sizeof(data)) == 0);
    assert(p->input_len == INPUT_CAP && p->input_cap == INPUT_CAP);
    assert(append(p, data, 1) == -1);
    for (unsigned i = 0; i < INPUT_CAP; ++i) assert(p->input[i] == 0x5a);
    p->closed = 1; sweep(&s);
    p = new_stream(&s, 3); assert(p);
    assert(p->input_cap == INPUT_CAP && p->input_len == 0);
    assert(append(p, data, sizeof(data)) == 0);
    free_stream(p);
}
static void allocation_failure(void) {
    session s = {0};
    stream *p = new_stream(&s, 1); assert(p);
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
     * failure; retained nghttp2 vectors must still never move. */
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
    stream *p = new_stream(&s, 1); assert(p);
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
    stream *p = new_stream(&s, 1); assert(p);
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
int main(void) {
    output_growth_and_cache(); request_body_growth(); allocation_failure(); h2_file_lifetime(); request_bridge_format_and_limit();
    puts("PASS: input/output growth, allocation failure, bounded cache, HTTP/2 file ownership/backpressure and request limits");
    return 0;
}
