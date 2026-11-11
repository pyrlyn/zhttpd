#include "zhttpd_websocket.h"
#include <signal.h>
static void stopped(int sig) { (void)sig; zws_stop(); }
static void echo(void *context, zws_peer *peer, const unsigned char *data, size_t size, int binary) {
    (void)context;
    if (zws_send(peer, data, size, binary) != 0) zws_close(peer, 1011);
}
int main(int argc, char **argv) {
    signal(SIGINT, stopped); signal(SIGTERM, stopped);
    zws_callbacks callbacks = {NULL, echo};
    return zws_server_run(argc > 1 ? argv[1] : "127.0.0.1:8080", &callbacks) == 0 ? 0 : 1;
}
