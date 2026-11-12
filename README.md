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
logging, load balancing and automatic ACME. Unknown settings and invalid module combinations fail.
Legacy `-c nginx.conf` remains supported; other direct formats use `--compatibility`.

- [Native TOML schema, routing, logging and Let's Encrypt](docs/configuration.md)
- [Adapter coverage and log compatibility](docs/compatibility.md)
- [WebSocket SDK/API for Zig, C and C++](docs/websocket-sdk.md)
- [Runnable configuration examples](examples/configs/config.toml)

Load-aware 307 redirects are available through the optional standalone
[`load_balancer` module](docs/load-balancing.md). It exchanges worker metrics
through a shared directory and limits each request to one balancing redirect.
The optional [Raft companion](docs/raft.md) replicates configuration, membership
and metrics with a durable majority-committed log (`zig build raft`).

Independent build modules: `load_balancer`, `http`, `nginx`, `apache`, `litespeed`, `caddy`,
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
Configuration files, include/import dependencies, TLS certificates/private keys,
PEM password files and per-certificate DNS env files are watched by default
(`server.auto_reload = false` disables this). Saves trigger the same reload;
missing certificates are issued before switching workers, while the master and
existing HTTPS service stay running. Invalid or mismatched TLS files keep the
active contexts. DNS env rotation immediately queues the corresponding ACME check;
lego writes do not trigger reload loops. Failed issuance keeps the active configuration.
Encrypted PEM keys use `[tls] password_file` in all five modes, with
`[http.tls] password_file` and nginx `ssl_password_file` overrides. Password files
are reloaded automatically; a wrong or missing password preserves active TLS.
Separate SNI passwords use `[[tls.certificates]]` key/password mappings for manual
keys or `password_file` inside each `[[acme.certificates]]` record. These override
the fallback password source without changing other certificates.
ACME records can enable `encrypt_key = true` with their own `password_file` to
publish encrypted PKCS#8 keys after issuance and renewal. Private staging and an
atomic generation switch preserve the current pair on failure. Password rotation
re-encrypts a cached key locally without calling lego or renewing its certificate,
including when the CA is offline. Per-SNI renewal schedules remain unchanged.
Old encrypted generations are retired only after successful activation, with a
durable cleanup journal for crash recovery. Active manual TLS references retain
their generations; changed or unknown files defer deletion.
Deferred cleanup retries independently per SNI record with bounded backoff,
without reload or CA traffic, including with config auto-reload disabled.
Existing plaintext ACME caches migrate locally without contacting the CA in all
five modes. Their original files are removed only after successful activation;
failed reloads, changed source files and active manual TLS references retain them.
Interrupted cleanup resumes from a persistent migration manifest.
See [password configuration and rotation](docs/configuration.md#зашифрованные-приватные-pem-ключи).
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

The transport feeds existing handlers through bounded memory buffers (64 KiB
request input and 32 KiB response output per stream), without internal sockets.
There are up to 32 concurrent request streams per connection. Stream handlers
count toward `worker_connections`. Ready codec work continues without a polling
delay; idle QUIC timers are serviced at intervals of at most 5 ms. HTTP/2 frames
are batched into TLS records, and QUIC stream I/O shares explicit event ticks.
Each event-loop thread caches at most 32 reusable stream buffers (under 4 MiB
total), and releases that cache when its last modern-protocol session closes.
Request handlers use a separate pool of at most 32 storage blocks per worker;
idle HTTP/1.x keep-alive connections return their request storage to that pool.
The worker also retains at most 64 closed connection records.

On Linux, `listen ... quic reuseport` creates one UDP socket per worker; the
kernel distributes connections by their UDP address/port tuple. Without this
option, or on other platforms, each QUIC listener belongs to the first worker.
Cross-worker QUIC connection migration is not implemented. Current HTTP/2 and
HTTP/3 connections are closed on
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
and exercise atomic/symlink replacement. Encrypted-key tests cover PKCS#8 and
traditional PEM, multiple passwords, SNI, invalid/missing password recovery,
nonblocking FIFO rejection, and native nginx inheritance. Real-lego DNS env tests cover per-certificate
retry isolation, missing files, credentials changed during issuance and loop prevention.
No public certificate is requested. Fixtures use temporary files/ports and
terminate their own process groups on failure.

## Documentation

| Guide | Contents |
| --- | --- |
| [Getting started](docs/getting-started.md) | Builds, CLI, reload and shutdown |
| [Raft cluster](docs/raft.md) | Durable consensus, configuration sync, membership and replicated metrics |
| [Load-aware balancing](docs/load-balancing.md) | Shared metrics, thresholds, 307 redirects and loop prevention |
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

Benchmark results and methodology are in [bench/RESULTS.md](bench/RESULTS.md)
and [bench/PLAN.md](bench/PLAN.md). Linux benchmarking instructions are in
[bench/lima/README.md](bench/lima/README.md).
The measured HTTPS optimization and its unmet 1.5x-nginx target are documented
in [bench/TLS-OPTIMIZATION.md](bench/TLS-OPTIMIZATION.md).
HTTP/2 and HTTP/3 measurements, raw evidence and the remaining target failures
are in [bench/H2-H3-OPTIMIZATION.md](bench/H2-H3-OPTIMIZATION.md).
The memory budget, measurement method and regression gate are described in
[bench/MEMORY-OPTIMIZATION.md](bench/MEMORY-OPTIMIZATION.md).
The stricter 80% target, fixed-footprint profile and rejected ReleaseSmall
experiment are documented in [bench/MEMORY-80-ASSESSMENT.md](bench/MEMORY-80-ASSESSMENT.md).
