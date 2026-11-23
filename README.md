<h1><img src="src/http/assets/icon.svg" width="32" height="32" alt="" align="absmiddle"> zhttpd</h1>

A Zig HTTP/1.0, HTTP/1.1, HTTP/2 and HTTP/3 server with native TOML settings and nginx, Apache, OpenLiteSpeed and Caddy adapters.
TLS uses OpenSSL 3.5+. HTTP/2 uses nghttp2; QUIC v1 and HTTP/3/QPACK come from the
in-tree Zig package [`modules/quic`](modules/quic/README.md) (zquic), whose TLS 1.3
handshake runs through OpenSSL's QUIC TLS callbacks.
Event backends: kqueue (macOS) and epoll (Linux).
The HTTP/1.1-only build also supports the optional AWS-LC TLS backend.

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

## Configuration

The default configuration is `config.toml`, with mandatory
`[server] compatibility = "self" | "nginx" | "apache" | "litespeed" | "caddy"`.
Legacy `-c nginx.conf` remains supported. Details:

- [Native TOML configuration](docs/configuration.md)
- [HTTP/2 and HTTP/3](docs/http2-http3.md)
- [Tests](docs/testing.md)
- [nginx configuration](docs/nginx-configuration.md)
- [HTTP application API](docs/http-application.md)
- [Load-aware balancing](docs/load-balancing.md) and [Raft cluster](docs/raft.md)

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
| [HTTP/2 and HTTP/3](docs/http2-http3.md) | Listeners, ALPN, QUIC and Alt-Svc |
| [Tests](docs/testing.md) | Unit, wire and Python e2e tests |

## Benchmarks

```bash
bench/run.sh --quick           # short comparison vs nginx and dusty-tuned
bench/run.sh                   # full plan: see bench/PLAN.md
```

Benchmark results and methodology are in [bench/RESULTS.md](bench/RESULTS.md)
and [bench/PLAN.md](bench/PLAN.md). Linux benchmarking instructions are in
[bench/lima/README.md](bench/lima/README.md).
The pre-integration AWS-LC HTTP/1.1 candidate passed the 1.5x-nginx throughput
and p99 gates in the documented Linux/ARM64 matrix. These measurements have not
been repeated for the integrated HTTP/2–3/ACME tree. Build options and limitations are
in [bench/TLS-OPTIMIZATION.md](bench/TLS-OPTIMIZATION.md).
HTTP/2 and HTTP/3 measurements, raw evidence and the remaining target failures
are in [bench/H2-H3-OPTIMIZATION.md](bench/H2-H3-OPTIMIZATION.md).
The memory budget, measurement method and regression gate are described in
[bench/MEMORY-OPTIMIZATION.md](bench/MEMORY-OPTIMIZATION.md).
The stricter 80% target, fixed-footprint profile and rejected ReleaseSmall
experiment are documented in [bench/MEMORY-80-ASSESSMENT.md](bench/MEMORY-80-ASSESSMENT.md).
The [HTTP/3 and large-response follow-up](bench/H3-LARGE-OPTIMIZATION.md)
records subsequent changes and the still-failing 50% target.

The [bounded buffering follow-up](bench/H3-THROUGHPUT-OPTIMIZATION.md) records
large-response batching, HTTP/3 callback caching, active-memory costs and the
remaining suite-wide throughput/latency target failures.

The [multiplexed memory follow-up](bench/MUX-MEMORY-OPTIMIZATION.md) records
direct HTTP/2 file reads, compact stream buffers, memory measurements and
the remaining throughput targets.
