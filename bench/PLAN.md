# zhttpd benchmark plan

Compare the Zig HTTP/1.0+1.1 server (`zhttpd`) to nginx on the **same** `nginx.conf`,
the same static files, and the same load tool (`oha`, built under `~/Grok`, no brew).
nginx is always the reference. The HttpArena leader for the protocol under test is
also run where we have a binary; HTTP/1.1 first.

## Platforms

| Platform | Event backend | Where |
|---|---|---|
| macOS (this Mac, M3 Max) | kqueue | host, `~/Grok/zig-http-server` |
| Linux aarch64 | epoll (`reuseport`) | dedicated Lima VM `zhttpd-bench` only |

`io_uring` is **not** used. nginx 1.30.6 (the version already built from `deps/`) has
no `aio uring` / liburing support, and zhttpd’s readiness loop is kqueue/epoll only.
A new event backend plus a newer nginx would be a separate change. Apache is later.

The Linux VM is created from `bench/lima/zhttpd-bench.yaml`. It must not replace or
reconfigure Lima `default`, `infra-test`, Colima, or the `tc-prod-*` VMs.

## Shared nginx.conf

Template: `bench/nginx.conf.in`. Rendered by `bench/run.sh` to `bench/nginx.conf`
(and copied into the result directory). Both zhttpd and nginx load that file.
zhttpd accepts unknown or unimplemented directives with a warning (`zhttpd -t`).

Fair nginx tuning in the template:

- `worker_processes auto`, `worker_rlimit_nofile 65535`
- `worker_connections 16384`, `multi_accept on`, `accept_mutex off`
- `use kqueue` on macOS, rewritten to `use epoll` on Linux
- `listen ... reuseport backlog=4096` on HTTP and HTTPS
- `sendfile on`, `tcp_nopush on`, `tcp_nodelay on`
- `keepalive_timeout 65`, `keepalive_requests 1000000`
- `open_file_cache` (max=10000)
- `access_log off`, `server_tokens off`
- TLS 1.3 only, `ssl_session_cache shared:SSL:50m`, `ssl_session_timeout 1h`,
  `ssl_session_tickets on`, `http2 off`

zhttpd applies the same directives it implements (including TLS settings from
`ssl_*` and `reuseport`). `tcp_nopush`, `accept_mutex`, and `http2` are ignored
with a warning (HTTP/2 is not implemented; “off” is already the behaviour).

## Load tool, files, certs

- oha 1.16.0 at `tools/oha/bin/oha` (Darwin) or `tools/linux/oha` (Linux VM).
- Static files generated deterministically in `bench/www/static/`: 612 B HTML,
  64 KiB and 1 MiB random binaries (seed 42).
- Self-signed ECDSA P-256 cert in `bench/certs/` (gitignored). HTTPS uses
  `--insecure`. HTTP/2 is disabled on both servers (nginx `http2 off`, dusty
  ALPN `http/1.1` only).

## Scenarios

ABBA ordering: odd repetitions run zhttpd → nginx → leader, even ones reverse.
Default: `DURATION=10` `WARMUP=2` `REPS=2`. Keep-alive-off runs are request-count
bound (`NOKA_N=12000`) so macOS’s ~16k ephemeral ports (49152–65535, TIME_WAIT
= 2×MSL = 30 s) are not exhausted mid-run. Machine 1-minute load average is
recorded around every sample.

Full set (HTTP first, then HTTPS):

- HTTP small file, keep-alive, 16 / 64 / 256 / 1024 connections
- HTTP 64 KiB and 1 MiB, keep-alive, 64 connections
- HTTP small file, keep-alive off (handshake/connect heavy), 64 connections
- HTTP `/baseline11` (tiny dynamic `return 200 "3"`), keep-alive, 256 connections
- HTTPS small file, keep-alive, 64 and 256 connections
- HTTPS 1 MiB, keep-alive, 64 connections
- HTTPS small file, keep-alive off (TLS handshake-heavy), 64 connections

`--quick` is a smoke subset: 3 s, 1 rep, c64 only, both protocols, plus the
handshake-heavy case.

## Competitors

`bench/leaders.toml` names the HttpArena leader per protocol:

- HTTP/1.1: `dusty-tuned` (active, cloned under `bench/competitors/`)
- HTTP/2: `h2o` (stub — zhttpd has no HTTP/2 yet)
- HTTP/3: `bun` (stub — zhttpd has no HTTP/3 yet)

dusty-tuned is not nginx-compatible; it is run with an **equivalent setup**
(same files, same ports, same cert, same oha command), not the same config file.
See `bench/NOTES.md` for the exact differences.

## Metrics and report

Per run: successful (2xx) RPS, p50/p90/p99 latency, non-2xx and error counts,
load average. The report prints separate HTTP and HTTPS tables, plus a
handshake-heavy section, and a summary. Output: `bench/results/<stamp>/`
(oha JSON, `runs.csv`, `load.log`, exact `nginx.conf`, `RESULTS.md`) and a
copy at `bench/RESULTS.md`.

## How to run

```bash
# from ~/Grok/zig-http-server, after zhttpd / nginx / oha / certs exist
bench/run.sh --quick          # smoke
bench/run.sh                  # full plan on this machine
SERVERS="zhttpd nginx" bench/run.sh
DURATION=15 REPS=3 bench/run.sh

# Linux (after the VM exists — see bench/lima/README.md)
limactl start zhttpd-bench    # never start/stop default, infra-test, Colima, tc-prod-*
limactl shell zhttpd-bench -- bash /Users/listepo/Grok/zig-http-server/bench/lima/setup-vm.sh
limactl shell zhttpd-bench -- bash /Users/listepo/Grok/zig-http-server/bench/run.sh
```

Do not publish a run whose `load.log` shows a colliding leftover server, bind
failures, or a 1-minute load average that is dominated by unrelated work without
saying so in the report.
