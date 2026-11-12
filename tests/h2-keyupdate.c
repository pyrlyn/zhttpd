/* Verify complete HTTP/2 bodies before and after TLS 1.3 KeyUpdate.
 * Python ssl has no KeyUpdate API; protocols.py drives this native client. */
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* Assertions must execute in every build mode: they also perform I/O. */
#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "%s:%d: %s failed\n", __FILE__, __LINE__, #expr); \
    ERR_print_errors_fp(stderr); exit(1); \
} } while (0)
static void write_all(SSL *s, const void *data, size_t len) {
    while (len) { int n = SSL_write(s, data, (int)len); if (n <= 0) { ERR_print_errors_fp(stderr); abort(); } data = (const char *)data + n; len -= (size_t)n; }
}
static void read_all(SSL *s, void *data, size_t len) {
    while (len) { int n = SSL_read(s, data, (int)len); if (n <= 0) { ERR_print_errors_fp(stderr); abort(); } data = (char *)data + n; len -= (size_t)n; }
}
static void frame(SSL *s, unsigned type, unsigned flags, unsigned stream, const void *body, size_t len) {
    unsigned char h[9] = {len >> 16, len >> 8, len, type, flags, stream >> 24, stream >> 16, stream >> 8, stream};
    write_all(s,h,9); if (len) write_all(s,body,len);
}
static void request(SSL *s, unsigned id, const unsigned char *file, size_t size, int update_mode) {
    /* Indexed GET/https; literal :path and :authority, without Huffman. */
    const unsigned char head[] = {0x82, 0x87, 0x04, 6,
        '/', 'l', 'a', 'r', 'g', 'e', 0x01, 9,
        'l', 'o', 'c', 'a', 'l', 'h', 'o', 's', 't'};
    frame(s,1,5,id,head,sizeof(head));
    size_t offset=0; int updated=update_mode < 0;
    for (;;) {
        unsigned char h[9], data[65536]; read_all(s,h,9);
        size_t n=((size_t)h[0]<<16)|((size_t)h[1]<<8)|h[2]; CHECK(n<=sizeof(data));
        unsigned stream=((unsigned)(h[5]&127)<<24)|((unsigned)h[6]<<16)|((unsigned)h[7]<<8)|h[8];
        read_all(s,data,n);
        if (h[3]==4 && !(h[4]&1)) frame(s,4,1,0,NULL,0);
        if (h[3]==6 && !(h[4]&1)) frame(s,6,1,0,data,n);
        CHECK(h[3]!=7 && !(h[3]==3 && stream==id));
        if (h[3]==0 && stream==id) {
            size_t skip=(h[4]&8)?1:0, pad=0;
            if (skip) { CHECK(n>0); pad=data[0]; }
            CHECK(n>=skip+pad && offset+n-skip-pad<=size);
            CHECK(!memcmp(file+offset,data+skip,n-skip-pad)); offset+=n-skip-pad;
            /* The 128 KiB stream window keeps this response active while the
             * peer changes keys. Its buffered old-key records must precede
             * KeyUpdate and the subsequent records using the new key. */
            if (!updated && offset >= 65536) {
                CHECK(SSL_key_update(s,update_mode)==1);
                CHECK(SSL_do_handshake(s)==1); updated=1;
            }
            unsigned char credit[4] = {n >> 24, n >> 16, n >> 8, n};
            if (n) frame(s,8,0,id,credit,sizeof(credit));
        }
        if ((h[3]==0 || h[3]==1) && stream==id && (h[4]&1)) { CHECK(offset==size && updated); return; }
    }
}
int main(int argc, char **argv) {
    CHECK(argc==3); FILE *f=fopen(argv[2],"rb"); CHECK(f); CHECK(!fseek(f,0,SEEK_END));
    long size=ftell(f); CHECK(size>0); rewind(f); unsigned char *file=malloc((size_t)size); CHECK(file);
    CHECK(fread(file,1,(size_t)size,f)==(size_t)size); fclose(f);
    SSL_CTX *ctx=SSL_CTX_new(TLS_client_method()); CHECK(ctx);
    CHECK(SSL_CTX_set_min_proto_version(ctx,TLS1_3_VERSION)); CHECK(SSL_CTX_set_max_proto_version(ctx,TLS1_3_VERSION));
    for (int mode=0;mode<2;++mode) {
        int fd=socket(AF_INET,SOCK_STREAM,0); CHECK(fd>=0); struct timeval timeout={15,0};
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout)); setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
        struct sockaddr_in a={.sin_family=AF_INET,.sin_port=htons((unsigned short)atoi(argv[1])),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
        CHECK(!connect(fd,(struct sockaddr*)&a,sizeof(a)));
        SSL *s=SSL_new(ctx); CHECK(s); CHECK(SSL_set_fd(s,fd)); CHECK(SSL_set_tlsext_host_name(s,"localhost"));
        CHECK(!SSL_set_alpn_protos(s,(const unsigned char*)"\2h2",3)); CHECK(SSL_connect(s)==1);
        const unsigned char *alpn; unsigned len; SSL_get0_alpn_selected(s,&alpn,&len); CHECK(len==2 && !memcmp(alpn,"h2",2));
        write_all(s,"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n",24);
        const unsigned char settings[]={0,4,0,2,0,0}, window[]={0,128,0,0};
        frame(s,4,0,0,settings,6); frame(s,8,0,0,window,4);
        request(s,1,file,(size_t)size,mode);
        request(s,3,file,(size_t)size,-1);
        SSL_shutdown(s); SSL_free(s); close(fd);
    }
    SSL_CTX_free(ctx); free(file); puts("PASS: HTTP/2 large bodies across TLS 1.3 KeyUpdate in both modes");
    return 0;
}
