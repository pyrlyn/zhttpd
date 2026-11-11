#include "zhttpd_websocket.hpp"
#include <csignal>
int main(int argc, char **argv) {
    std::signal(SIGINT, [](int) { zhttpd::stop(); });
    std::signal(SIGTERM, [](int) { zhttpd::stop(); });
    return zhttpd::serve(argc > 1 ? argv[1] : "127.0.0.1:8080", [](zhttpd::Peer peer, std::string_view data, bool binary) {
        if (!peer.send(data, binary)) peer.close(1011);
    }) == 0 ? 0 : 1;
}
