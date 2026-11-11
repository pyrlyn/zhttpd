<img src="src/http/assets/icon.svg" width="64" height="64" alt="zhttpd icon">

# zhttpd

A Zig HTTP/1.0+1.1 server that reads `nginx.conf`. TLS 1.3 via OpenSSL. Event
backends: kqueue (macOS) and epoll (Linux).

## Build

Requires Zig 0.17.1 (see `mise.toml`).

```bash
scripts/fetch-deps.sh          # once: OpenSSL, nginx, pcre2, zlib
scripts/build-nginx.sh         # comparison nginx into tools/nginx
scripts/build-zhttpd.sh        # zig-out/bin/zhttpd (ReleaseFast + TLS)
scripts/gen-certs.sh           # self-signed certs in bench/certs (gitignored)
```

The private key for the bench certificate is generated locally and is not in
the repository. Regenerate it with `scripts/gen-certs.sh` before a TLS run.

## Run

```bash
scripts/smoke.sh               # short smoke vs nginx
zig-out/bin/zhttpd -c path/to/nginx.conf
```

## Default error pages

Built-in 4xx and 5xx pages use the zhttpd identity: a pair of chevrons around a
packet, warm paper, graphite, and lime. The reusable SVG icon lives in
[`src/http/assets/icon.svg`](src/http/assets/icon.svg). CSS, SVG, and favicon
are embedded in the binary; error pages need no JavaScript, fonts, or asset
requests. Layout adapts to mobile screens and supports keyboard navigation.

Configured `error_page` responses still take precedence. `server_tokens off`
hides the version in both the header and page footer. Redirect bodies retain
their nginx-compatible layout. Default error bodies and their Content-Length
intentionally differ from nginx in `scripts/smoke.sh` comparisons.

Verify with `zig build test`, `zig build`, and `python3 tests/error-pages.py`.

## Benchmarks

```bash
bench/run.sh --quick           # short comparison vs nginx and dusty-tuned
bench/run.sh                   # full plan: see bench/PLAN.md
```

Official results are in [bench/RESULTS.md](bench/RESULTS.md). The exact nginx
config is generated from `bench/nginx.conf.in`. Linux epoll runs can use the
dedicated Lima VM described in [bench/lima/README.md](bench/lima/README.md).
