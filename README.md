<img src="src/http/assets/icon.svg" width="64" height="64" alt="zhttpd icon">

# zhttpd

A Zig HTTP/1.0, HTTP/1.1, HTTP/2 and HTTP/3 server with native TOML settings and nginx, Apache, OpenLiteSpeed and Caddy adapters.
TLS and QUIC use OpenSSL 3.5+, with nghttp2/nghttp3 for framing and HPACK/QPACK.
Event backends: kqueue (macOS) and epoll (Linux).

## Build

All tool versions and dependency preparation are managed by **mise**. C libraries
are built from checksum-verified sources by mise tasks; Python E2E dependencies
are hash-locked. A platform SDK/system headers and basic shell utilities are
required on macOS/Linux.

```bash
mise trust
mise install
mise run build                # ReleaseFast + OpenSSL + HTTP/2 + HTTP/3
mise exec -- zig-out/bin/zhttpd -c config.toml
```

`mise run build:minimal` builds HTTP/1.x without TLS libraries. `mise run deps`
prepares all dependencies. Reference nginx is optional: `mise run deps:nginx`.

## Quick start

Run from the repository root with Zig 0.17.1 installed:

```bash
zig build -Doptimize=ReleaseFast
mkdir -p .run/local/html .run/local/logs
printf '<h1>Hello from zhttpd</h1>\n' > .run/local/html/index.html
zig-out/bin/zhttpd -t -p "$PWD/.run/local/" -c "$PWD/docs/examples/nginx.conf"
zig-out/bin/zhttpd -p "$PWD/.run/local/" -c "$PWD/docs/examples/nginx.conf"
```

Open [localhost:8080](http://localhost:8080/). Request `/missing` to see the
branded 404 page or `/health` for a plain-text health check. The process stays
in the foreground; press Ctrl+C to stop it. This build uses plain HTTP.

## Configuration and modules

The default configuration is `config.toml`, with mandatory
`[server] compatibility = "self" | "nginx" | "apache" | "litespeed" | "caddy"`.
`[modules]` enables or disables HTTP, adapters, WebSocket, FastCGI, WSGI,
logging and automatic ACME. Unknown settings and invalid module combinations fail.
Legacy `-c nginx.conf` remains supported; other direct formats use `--compatibility`.

- [Native TOML schema, routing, logging and Let's Encrypt](docs/configuration.md)
- [Adapter coverage and log compatibility](docs/compatibility.md)
- [WebSocket SDK/API for Zig, C and C++](docs/websocket-sdk.md)
- [Runnable configuration examples](examples/configs/config.toml)

Independent build modules: `http`, `nginx`, `apache`, `litespeed`, `caddy`,
`settings`, `expression`, `logging`, `websocket`, `websocket_sdk`, `fastcgi`,
`wsgi`, `acme`. Adapters depend on HTTP; HTTP does not import their parsers.
The `zhttpd` facade preserves the earlier `conf` and `server` names. Adapters
produce `*http.config.Config` and retain source strings until `destroy`.

WebSocket supports RFC 6455 HTTP/1.1 upgrades and callback-based applications.
FastCGI forwards to TCP responders; WSGI uses an isolated Python gateway.
ACME uses mise-pinned lego, with multi-domain HTTP-01 / DNS-01 issuance, wildcard certificates, periodic renewal and
certificate reload in all five compatibility modes. Separate SNI certificates
use `[[acme.certificates]]`, each with its own DNS provider and credential file.
Domains, SANs and certificate records can be added or removed through reload.
Configuration files, include/import dependencies, TLS certificates/private keys
and per-certificate DNS env files are watched by default
(`server.auto_reload = false` disables this). Saves trigger the same reload;
missing certificates are issued before switching workers, while the master and
existing HTTPS service stay running. Invalid or mismatched TLS files keep the
active contexts. DNS env rotation immediately queues the corresponding ACME check;
lego writes do not trigger reload loops. Failed issuance keeps the active configuration.
Production CA issuance is opt-in through `[acme]`.

## HTTP/2 and HTTP/3

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

The transport shares existing handlers through nonblocking socketpairs, one
per request stream, with bounded buffering and flow control. There are up to
32 concurrent request streams per connection. Stream handlers count toward
`worker_connections`; each also needs a codec-side file descriptor. The worker
services codec buffers and QUIC timers at intervals of at most 5 ms.

Each QUIC listen socket is owned by the first worker (including when
`reuseport` is present). Current HTTP/2 and HTTP/3 connections are closed on
reload/graceful shutdown; clients reconnect to the new generation. Request
trailers are validated by the codecs but are not exposed to handlers. Server
push and extended CONNECT are not implemented. QUIC address validation uses
OpenSSL's default retry policy; `quic_retry` remains an ignored directive.

## Tests

```bash
mise run test                 # all independent module + fixture unit tests
mise run test:e2e             # complete wire suite, builds required dependencies
mise run examples             # shared WebSocket examples in Zig, C and C++
```

The E2E suite starts actual binaries and tests HTTP/1.1 fallback, h2 and aioquic
HTTP/3 clients, multiplexing, cancellation, malformed requests, static/HEAD,
large uploads, proxy, ACLs, limits, vhosts, reload and shutdown. It also tests
all config adapters and module gates, log contents/escaping/USR1 reopening,
all three WebSocket SDK examples with the same contract, FastCGI framing and a
real WSGI app. ACME tests run the real pinned lego client against a local HTTPS
CA in every compatibility mode, check multi-domain HTTP-01 and wildcard DNS-01
with a local DNS provider/UDP server, issue and renew SAN certificates, verify
TXT cleanup, failure retention and isolation of unrelated SNI certificates.
Independent certificate tests use different DNS providers/credential files,
check exact/wildcard SNI priority, HTTP/2 and HTTP/3 handshakes, independent
renewal after provider failure, and configuration reordering during renewal.
Reload tests cover adding/removing records and SANs, cached re-addition, atomic
failure, superseded issuance, timeouts, and removal of the final managed certificate
in all five modes with both HTTP-01 and DNS-01, both manually and through file watching.
Watcher tests cover debounced saves, same-size/mtime edits, symlink swaps,
missing/invalid dependency recovery, glob membership changes, direct native configs
and accepted connections awaiting their first request during reload. TLS material
tests rotate certs and keys separately, retain working contexts on invalid files,
and exercise atomic/symlink replacement. Real-lego DNS env tests cover per-certificate
retry isolation, missing files, credentials changed during issuance and loop prevention.
No public certificate is requested. Fixtures use temporary files/ports and
terminate their own process groups on failure.

## Documentation

| Guide | Contents |
| --- | --- |
| [Getting started](docs/getting-started.md) | Builds, CLI, reload and shutdown |
| [Native configuration](docs/configuration.md) | TOML, modules, routing, logging and ACME |
| [nginx configuration](docs/nginx-configuration.md) | Legacy paths, static files, proxying and TLS |
| [Adapter compatibility](docs/compatibility.md) | nginx, Apache, OpenLiteSpeed and Caddy coverage |
| [HTTP error pages](docs/error-pages.md) | Branded defaults and custom responses |
| [Deployment](docs/deployment.md) | Docker and image publishing |
| [Development](docs/development.md) | Source map, unit and wire tests |
| [WebSocket SDK](docs/websocket-sdk.md) | Zig, C and C++ applications |

## Benchmarks

```bash
bench/run.sh --quick           # short comparison vs nginx and dusty-tuned
bench/run.sh                   # full plan: see bench/PLAN.md
```

Official results are in [bench/RESULTS.md](bench/RESULTS.md). The exact nginx
config is generated from `bench/nginx.conf.in`. Linux epoll runs can use the
dedicated Lima VM described in [bench/lima/README.md](bench/lima/README.md).
