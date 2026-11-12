/* Regression for the pinned OpenSSL QUIC stream-map retention fix.
 * Build against OpenSSL's internal headers and the installed static archives.
 */
#include <stdio.h>
#include <string.h>
#include "internal/quic_stream_map.h"

static int check_case(int recv_state, int send_state, int deleted, int stop_acked,
                      int expect_collected) {
    QUIC_STREAM_MAP map;
    QUIC_STREAM *stream;
    size_t written;
    int collected;
    memset(&map, 0, sizeof(map));
    if (!ossl_quic_stream_map_init(&map, NULL, NULL, NULL, NULL, 1)) return 0;
    stream = ossl_quic_stream_map_alloc(&map, 0,
        QUIC_STREAM_INITIATOR_CLIENT | QUIC_STREAM_DIR_BIDI);
    if (stream == NULL) { ossl_quic_stream_map_cleanup(&map); return 0; }
    stream->recv_state = recv_state;
    stream->send_state = send_state;
    stream->deleted = deleted;
    stream->acked_stop_sending = stop_acked;
    stream->send_final_size = 1;
    if (send_state == QUIC_SSTREAM_STATE_DATA_SENT) {
        stream->sstream = ossl_quic_sstream_new(8192);
        if (stream->sstream == NULL ||
            !ossl_quic_sstream_append(stream->sstream, (const unsigned char *)"x", 1, &written)) {
            ossl_quic_stream_map_cleanup(&map); return 0;
        }
        ossl_quic_sstream_fin(stream->sstream);
        if (!ossl_quic_sstream_mark_transmitted(stream->sstream, 0, 0) ||
            !ossl_quic_sstream_mark_transmitted_fin(stream->sstream, 1)) {
            ossl_quic_stream_map_cleanup(&map); return 0;
        }
    }
    ossl_quic_stream_map_update_state(&map, stream);
    ossl_quic_stream_map_gc(&map);
    collected = ossl_quic_stream_map_get_by_id(&map, 0) == NULL;
    if (!collected && send_state == QUIC_SSTREAM_STATE_DATA_SENT) {
        /* Only the later ACK may retire a deleted, fully read stream. */
        if (!ossl_quic_sstream_mark_acked(stream->sstream, 0, 0) ||
            !ossl_quic_sstream_mark_acked_fin(stream->sstream)) {
            ossl_quic_stream_map_cleanup(&map); return 0;
        }
        ossl_quic_stream_map_update_state(&map, stream);
        ossl_quic_stream_map_gc(&map);
        if (ossl_quic_stream_map_get_by_id(&map, 0) != NULL) {
            fputs("stream retained after final ACK\n", stderr);
            ossl_quic_stream_map_cleanup(&map); return 0;
        }
    }
    ossl_quic_stream_map_cleanup(&map);
    if (collected != expect_collected) {
        fprintf(stderr, "GC mismatch: recv=%d send=%d deleted=%d stop_acked=%d collected=%d\n",
                recv_state, send_state, deleted, stop_acked, collected);
        return 0;
    }
    return 1;
}

int main(void) {
    int ok = 1;
    /* Fully consumed FIN/reset: application release plus peer's ACK is enough. */
    ok &= check_case(QUIC_RSTREAM_STATE_DATA_READ, QUIC_SSTREAM_STATE_DATA_RECVD, 1, 0, 1);
    ok &= check_case(QUIC_RSTREAM_STATE_RESET_READ, QUIC_SSTREAM_STATE_RESET_RECVD, 1, 0, 1);
    /* Application ownership, unread input and unacknowledged output must survive. */
    ok &= check_case(QUIC_RSTREAM_STATE_DATA_READ, QUIC_SSTREAM_STATE_DATA_RECVD, 0, 0, 0);
    ok &= check_case(QUIC_RSTREAM_STATE_DATA_RECVD, QUIC_SSTREAM_STATE_DATA_RECVD, 1, 0, 0);
    ok &= check_case(QUIC_RSTREAM_STATE_SIZE_KNOWN, QUIC_SSTREAM_STATE_DATA_RECVD, 1, 0, 0);
    ok &= check_case(QUIC_RSTREAM_STATE_DATA_READ, QUIC_SSTREAM_STATE_DATA_SENT, 1, 0, 0);
    /* The existing STOP_SENDING acknowledgement path remains valid. */
    ok &= check_case(QUIC_RSTREAM_STATE_RESET_RECVD, QUIC_SSTREAM_STATE_RESET_RECVD, 1, 1, 1);
    if (ok) puts("PASS: QUIC stream GC retains unread/unacknowledged data and releases drained streams");
    return ok ? 0 : 1;
}
