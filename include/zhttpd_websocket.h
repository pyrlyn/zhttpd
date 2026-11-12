#ifndef ZHTTPD_WEBSOCKET_H
#define ZHTTPD_WEBSOCKET_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct zws_peer zws_peer;
/* peer and data are borrowed for this callback only. zws_send copies data.
   Callbacks run on the server thread. Maximum message: 65536 bytes.
   No compression/extensions; unmasked client frames are rejected. */
typedef void (*zws_message_fn)(void *context, zws_peer *peer,
                             const unsigned char *data, size_t size, int binary);
typedef struct { void *context; zws_message_fn on_message; } zws_callbacks;
/* Blocking; one active server per process. Numeric IP:port address.
   NULL callbacks selects echo. Return 0 on stop, -1 on startup error. */
int zws_server_run(const char *address, const zws_callbacks *callbacks);
int zws_send(zws_peer *, const unsigned char *, size_t, int binary);
void zws_close(zws_peer *, uint16_t code);
/* Call on the server thread or in a signal handler. */
void zws_stop(void);
#ifdef __cplusplus
}
#endif
#endif
