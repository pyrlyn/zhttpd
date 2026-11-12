/* UDP segmentation is an output optimization only: each QUIC packet retains
 * its original boundary, peer and source address. Other platforms and sockets
 * without UDP GSO use the ordinary OpenSSL datagram BIO. */
#ifndef ZHTTP_QUIC_OUTPUT_H
#define ZHTTP_QUIC_OUTPUT_H
#include <openssl/bio.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
#ifdef __linux__
#include <linux/udp.h>
#endif

typedef struct quic_output {
    BIO *direct;
    BIO_METHOD *method;
    int fd, disabled;
} quic_output;

#if defined(__linux__) && defined(UDP_SEGMENT)
static int quic_ipv4(const BIO_ADDR *addr, struct sockaddr_in *out) {
    size_t len = sizeof(out->sin_addr);
    memset(out, 0, sizeof(*out));
    if (!addr || BIO_ADDR_family(addr) != AF_INET ||
        !BIO_ADDR_rawaddress(addr, &out->sin_addr, &len)) return 0;
    out->sin_family = AF_INET; out->sin_port = BIO_ADDR_rawport(addr);
    return 1;
}
static int quic_same_addr(const BIO_ADDR *a, const BIO_ADDR *b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    struct sockaddr_in x, y;
    return quic_ipv4(a, &x) && quic_ipv4(b, &y) &&
        x.sin_port == y.sin_port && x.sin_addr.s_addr == y.sin_addr.s_addr;
}
static BIO_MSG *quic_msg(BIO_MSG *msg, size_t stride, size_t i) {
    return (BIO_MSG *)((unsigned char *)msg + stride * i);
}
static int quic_gso_pair(const BIO_MSG *a, const BIO_MSG *b) {
    return !a->flags && !b->flags && a->data_len && b->data_len &&
        a->data_len <= UINT16_MAX && b->data_len <= a->data_len &&
        a->data_len + b->data_len <= 65507 &&
        a->peer && BIO_ADDR_family(a->peer) == AF_INET &&
        (!a->local || BIO_ADDR_family(a->local) == AF_INET) &&
        quic_same_addr(a->peer, b->peer) && quic_same_addr(a->local, b->local);
}
static int quic_sendmmsg(BIO *bio, BIO_MSG *msg, size_t stride, size_t count,
                         uint64_t flags, size_t *processed) {
    quic_output *q = BIO_get_data(bio);
    *processed = 0; BIO_clear_retry_flags(bio);
    while (*processed < count) {
        BIO_MSG *first = quic_msg(msg, stride, *processed);
        struct sockaddr_in peer, local;
        struct iovec vec[64];
        size_t n = 0, bytes = 0;
        if (!q->disabled && !flags && !first->flags && first->data_len &&
            first->data_len <= UINT16_MAX && quic_ipv4(first->peer, &peer) &&
            (!first->local || quic_ipv4(first->local, &local))) {
            while (n < 64 && *processed + n < count) {
                BIO_MSG *p = quic_msg(msg, stride, *processed + n);
                if (p->flags || !p->data_len || p->data_len > first->data_len ||
                    bytes + p->data_len > 65507 || !quic_same_addr(first->peer, p->peer) ||
                    !quic_same_addr(first->local, p->local)) break;
                vec[n++] = (struct iovec){p->data, p->data_len}; bytes += p->data_len;
                if (p->data_len < first->data_len) break;
            }
        }
        if (n > 1) {
            union { struct cmsghdr align; unsigned char data[CMSG_SPACE(sizeof(uint16_t)) + CMSG_SPACE(sizeof(struct in_pktinfo))]; } control;
            memset(&control, 0, sizeof(control));
            struct msghdr hdr = {0};
            hdr.msg_name = &peer; hdr.msg_namelen = sizeof(peer);
            hdr.msg_iov = vec; hdr.msg_iovlen = n;
            hdr.msg_control = control.data; hdr.msg_controllen = CMSG_SPACE(sizeof(uint16_t));
            if (first->local) hdr.msg_controllen += CMSG_SPACE(sizeof(struct in_pktinfo));
            struct cmsghdr *c = CMSG_FIRSTHDR(&hdr);
            c->cmsg_level = IPPROTO_UDP; c->cmsg_type = UDP_SEGMENT; c->cmsg_len = CMSG_LEN(sizeof(uint16_t));
            uint16_t segment = (uint16_t)first->data_len;
            memcpy(CMSG_DATA(c), &segment, sizeof(segment));
            if (first->local) {
                c = CMSG_NXTHDR(&hdr, c);
                c->cmsg_level = IPPROTO_IP; c->cmsg_type = IP_PKTINFO; c->cmsg_len = CMSG_LEN(sizeof(struct in_pktinfo));
                struct in_pktinfo info = {0}; info.ipi_spec_dst = local.sin_addr;
                memcpy(CMSG_DATA(c), &info, sizeof(info));
            }
            ssize_t sent = sendmsg(q->fd, &hdr, MSG_DONTWAIT | MSG_NOSIGNAL);
            if (sent == (ssize_t)bytes) { *processed += n; continue; }
            /* UDP sends are atomic. A rejected GSO batch has sent no packets;
             * retry through the ordinary BIO, including its error/retry rules. */
            if (errno == EINVAL || errno == EIO || errno == ENOPROTOOPT || errno == EOPNOTSUPP)
                q->disabled = 1;
        }
        size_t done = 0;
        size_t plain = q->disabled || flags ? count - *processed : 1;
        /* Unequal short packets cannot use GSO. Keep them together for the
         * ordinary sendmmsg BIO instead of issuing one syscall per packet;
         * stop before the next pair that can start a GSO group. */
        if (!q->disabled && !flags) {
            while (*processed + plain < count) {
                size_t next = *processed + plain;
                if (next + 1 < count && quic_gso_pair(quic_msg(msg, stride, next),
                                                     quic_msg(msg, stride, next + 1))) break;
                ++plain;
            }
        }
        int ok = BIO_sendmmsg(q->direct, first, stride, plain, flags, &done);
        *processed += done;
        if (BIO_should_retry(q->direct)) BIO_set_retry_write(bio);
        if (!ok || !done) return *processed ? 1 : ok;
    }
    return 1;
}
static long quic_output_ctrl(BIO *bio, int cmd, long num, void *ptr) {
    quic_output *q = BIO_get_data(bio);
    return BIO_ctrl(q->direct, cmd, num, ptr);
}
static int quic_output_destroy(BIO *bio) {
    quic_output *q = BIO_get_data(bio);
    if (q) { BIO_free(q->direct); q->direct = NULL; }
    return 1;
}
#endif

static BIO *quic_output_new(quic_output *q, int fd) {
    BIO *direct = BIO_new_dgram(fd, BIO_NOCLOSE);
    if (!direct) return NULL;
#if defined(__linux__) && defined(UDP_SEGMENT)
    q->direct = direct; q->fd = fd;
    q->method = BIO_meth_new(BIO_get_new_index() | BIO_TYPE_SOURCE_SINK, "QUIC UDP GSO");
    if (q->method && BIO_meth_set_sendmmsg(q->method, quic_sendmmsg) &&
        BIO_meth_set_ctrl(q->method, quic_output_ctrl) &&
        BIO_meth_set_destroy(q->method, quic_output_destroy)) {
        BIO *bio = BIO_new(q->method);
        if (bio) { BIO_set_data(bio, q); BIO_set_init(bio, 1); return bio; }
    }
    BIO_meth_free(q->method); q->method = NULL; q->direct = NULL;
#else
    (void)q;
#endif
    return direct;
}
#endif
