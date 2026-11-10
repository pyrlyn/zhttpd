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

## Benchmarks

```bash
bench/run.sh --quick           # short comparison vs nginx and dusty-tuned
bench/run.sh                   # full plan: see bench/PLAN.md
```

Official results are in [bench/RESULTS.md](bench/RESULTS.md). The exact nginx
config is generated from `bench/nginx.conf.in`. Linux epoll runs can use the
dedicated Lima VM described in [bench/lima/README.md](bench/lima/README.md).
