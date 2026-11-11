<img src="src/http/assets/icon.svg" width="64" height="64" alt="zhttpd icon">

# zhttpd

An HTTP/1.0 and HTTP/1.1 server written in Zig, with nginx-style configuration,
optional TLS through OpenSSL, and native event loops: kqueue on macOS and epoll
on Linux.

It serves static files, proxies HTTP upstreams, routes virtual hosts, and renders
self-contained branded error pages. nginx configuration compatibility is partial:
read the [compatibility notes](docs/configuration.md#compatibility) before using
an existing configuration. HTTP/2 and HTTP/3 are not implemented in this version.

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

## Documentation

| Guide | Contents |
| --- | --- |
| [Getting started](docs/getting-started.md) | Requirements, HTTP/TLS builds, CLI, reload and shutdown |
| [Configuration](docs/configuration.md) | Paths, static files, proxying, TLS, nginx compatibility |
| [HTTP error pages](docs/error-pages.md) | Default pages, custom responses, branding and verification |
| [Deployment](docs/deployment.md) | Docker, custom config, TLS termination and image tags |
| [Development](docs/development.md) | Source map, tests, smoke checks and benchmarks |

The complete directive table is available from the binary:

```bash
zig-out/bin/zhttpd --directives
```

## Verification

```bash
zig build test
zig build
python3 tests/error-pages.py
```

Benchmark results and methodology are in [bench/RESULTS.md](bench/RESULTS.md)
and [bench/PLAN.md](bench/PLAN.md). Linux benchmarking instructions are in
[bench/lima/README.md](bench/lima/README.md).
