#pragma once
#include "zhttpd_websocket.h"
#include <functional>
#include <string_view>
namespace zhttpd {
class Peer {
    zws_peer *value_;
public:
    explicit Peer(zws_peer *p) : value_(p) {}
    bool send(std::string_view data, bool binary = false) const {
        return zws_send(value_, reinterpret_cast<const unsigned char *>(data.data()), data.size(), binary) == 0;
    }
    void close(uint16_t code = 1000) const { zws_close(value_, code); }
};
using MessageHandler = std::function<void(Peer, std::string_view, bool)>;
inline int serve(const char *address, MessageHandler handler) {
    zws_callbacks callbacks{&handler, [](void *ctx, zws_peer *peer, const unsigned char *data, size_t size, int binary) {
        try { (*static_cast<MessageHandler *>(ctx))(Peer(peer), {reinterpret_cast<const char *>(data), size}, binary != 0); }
        catch (...) { zws_close(peer, 1011); }
    }};
    return zws_server_run(address, &callbacks);
}
inline void stop() { zws_stop(); }
}
