/* Exercise the real datagram adapters, including packet boundaries and bounded
 * receive batches. Linking the codec also compiles both transport paths. */
#include <assert.h>
#include "../src/server/multiplex.c"

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
    for (int mode = 0; mode < 3; ++mode) {
        output.disabled = mode == 1;
        output.fd = mode == 2 ? -1 : tx; /* GSO syscall failure must fall back without losing packets. */
        size_t sent = 0;
        assert(BIO_sendmmsg(bio, msgs, sizeof(msgs[0]), 70, 0, &sent) == 1 && sent == 70);
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
int main(void) {
    output_boundaries(); input_budget();
    puts("PASS: UDP GSO boundaries, mixed peers, short tails, fallback and receive budgets");
    return 0;
}
