# HTTP/2 and HTTP/3


```nginx
http {
    http2 on;
    server {
        listen 8443 ssl;        # HTTP/1.1 and HTTP/2 over TCP, selected by ALPN
        listen 8443 quic;       # HTTP/3 over UDP on the same port
        server_name localhost;
        ssl_certificate cert.pem;
        ssl_certificate_key key.pem;
        add_header Alt-Svc 'h3=":8443"; ma=86400' always;
        location / { return 200 "$server_protocol\n"; }
    }
}
```

`http2` defaults to `off`; `http3` defaults to `on` for QUIC listeners.
Both inherit from `http` into `server`. Legacy `listen ... ssl http2` is also
accepted. HTTP/2 requires TLS; h2c/Upgrade is not implemented. QUIC requires
TLS 1.3. Use `Alt-Svc` as above to advertise HTTP/3 to browsers; UDP must be
reachable. Protocol settings fail configuration validation when the binary
was built without their dependencies.

The default `zig build` remains an HTTP/1.x build without external libraries.
For a manual modern-protocol build:

```bash
mise exec -- zig build -Dtls=true -Dhttp=true \
  -Dopenssl="$PWD/deps/openssl-install" -Dhttp-deps="$PWD/deps/http-install"
```

The transport feeds existing handlers through bounded memory buffers, without
internal sockets. HTTP/2 uses 64 KiB request input and 32 KiB response output per
stream, with up to 32 concurrent request streams per connection. HTTP/3 request
bodies are read straight from QUIC stream buffers; response bodies and file
ranges (via `pread`) are written straight into them, bounded by a 64 KiB send
buffer per stream and up to 128 concurrent request streams per connection.
Stream handlers count toward `worker_connections`. Ready codec work continues
without a polling delay; the event wait ends at the next QUIC timer. HTTP/2 frames
are batched into TLS records. Large HTTP/2 responses also batch encrypted
records in a 96 KiB buffer, flushed each bounded turn and released once idle.
Each event-loop thread caches at most 32 reusable stream buffers (under 4 MiB
total), with an additional 1 MiB output-byte budget so enlarged buffers reduce
the number retained. It releases the cache when its last modern-protocol session
closes.
Request handlers use a separate pool of at most 32 storage blocks per worker;
idle HTTP/1.x keep-alive connections return their request storage to that pool.
The worker also retains at most 64 closed connection records.

On Linux, zquic receives UDP datagrams in `recvmmsg` batches, keeping each
packet's destination address (`IP_PKTINFO`), and sends coalesced packets with
UDP GSO via `sendmmsg`, falling back to one datagram per send when the path does
not support GSO. Other platforms use `recvmsg`/`sendmsg`. Packet protection,
loss recovery (RFC 9002, NewReno), flow control and path validation run in Zig;
OpenSSL only performs the TLS 1.3 handshake. Streams are released once the
application is done and the peer has acknowledged all outgoing data.

On Linux, `listen ... quic reuseport` creates one UDP socket per worker; the
kernel distributes connections by their UDP address/port tuple. Without this
option, or on other platforms, each QUIC listener belongs to the first worker.
Connection migration is validated and served by the worker that owns the
connection; cross-worker migration (nginx `quic_bpf`) is not implemented. Current HTTP/2 and
HTTP/3 connections are closed on
reload/graceful shutdown; clients reconnect to the new generation. Request
trailers are validated by the codecs but are not exposed to handlers. Server
push and extended CONNECT are not implemented. QUIC address validation relies on
the RFC 9000 anti-amplification limit; `quic_retry` remains an ignored directive.
