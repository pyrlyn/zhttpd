# zquic

QUIC v1 server transport (RFC 9000, 9001, 9002) with a small HTTP/3 + QPACK
layer (RFC 9114, 9204), written in Zig. The package does not import zhttpd
code; zhttpd uses it as its HTTP/3 transport through `src/server/h3.zig`.

The TLS 1.3 handshake runs in OpenSSL 3.5+ through its third-party QUIC TLS
API (`SSL_set_quic_tls_cbs`); everything else — packet protection, header
protection, loss recovery, congestion control, flow control, path validation
and HTTP/3 framing — is in this package.

## Build and test

```bash
zig build test -Dopenssl=<prefix>          # unit tests
zig build example -Dopenssl=<prefix>       # zig-out/bin/h3-server
zig build bench-crypto -Dopenssl=<prefix>  # packet protection microbenchmark
```

`<prefix>` is an OpenSSL 3.5+ install with `include/` and `lib/`. Without
`-Dopenssl` the system `ssl`/`crypto` libraries are linked.
`-Dopenssl-aead=false` switches packet AEAD from OpenSSL EVP to Zig `std.crypto`
(slower on aarch64 without the EVP assembly paths).

From the zhttpd root, `zig build test-quic -Dtls=true -Dhttp=true ...` runs the
same tests against the pinned OpenSSL.

Interop check with a third-party client (aioquic):

```bash
zig-out/bin/h3-server --port 8443 --cert cert.pem --key key.pem --size 612 &
python3 tests/h3_client.py 127.0.0.1 8443 --requests 32 --size 612
```

## Layout

| File | Contents |
|---|---|
| `wire.zig` | varints, readers and writers |
| `packet.zig` | long/short headers, packet number encoding |
| `crypto.zig` | initial secrets, key update, AEAD and header protection |
| `tls.zig` | OpenSSL QUIC TLS callback bindings |
| `tp.zig` | transport parameters |
| `ranges.zig` | received packet ranges and ACK frames |
| `recovery.zig` | sent-packet records, RTT, NewReno |
| `stream.zig` | send/receive stream buffers and flow control |
| `conn.zig` | connection state machine, frames, timers, migration |
| `endpoint.zig` | connection IDs, accept, Version Negotiation, Retry, timer heap, send batching |
| `udp.zig` | `recvmmsg`/`sendmmsg` with PKTINFO and GSO on Linux, `recvmsg`/`sendmsg` elsewhere |
| `qpack.zig`, `qpack_tables.zig` | static-table QPACK with Huffman coding |
| `h3.zig` | HTTP/3 sessions, control streams, request API, GOAWAY |

## HTTP/3 API

`h3.Server.init(alloc, ssl_ctx, config, handler)` creates an endpoint; attach a
UDP socket with `udp.Socket.init` and `ep.sink = sock.sink()`. The event loop
calls `sock.receive(ep, batches)`, `ep.updateClock()`, `ep.onTimers()` and
`ep.flush()`, and waits at most `ep.timeoutMs()`. Within one receive round,
`receive` sends the first connection's output as soon as its peer's last
datagram in the batch is processed, so that client starts its next round
while the server works through the other connections' datagrams; the rest
share the caller's `flush`.

`Handler` callbacks get a `*h3.Request`: `request` (headers decoded),
`readable`, `writable` and `aborted`. A request exposes `headers()`, `read()`,
`ended()`, `sendHeaders()`, `writeData()`, `reserveData()`/`commitData()` for
zero-copy body writes, `finish()`, `reset()` and `release()`. Every request
must be released exactly once.

`Server.shutdown()` sends GOAWAY with the largest stream id, accepts requests
already in flight for three PTOs, then refuses new ones and closes each
connection once its requests finish. A client GOAWAY starts the same drain.

## Limits

- Server only; no client role, 0-RTT, server push or DATAGRAM frames.
- QPACK uses the static table only (dynamic table capacity 0).
- Congestion control is NewReno; no pacing.
- Migration is served by the endpoint that owns the connection ID; there is
  no cross-process steering.
