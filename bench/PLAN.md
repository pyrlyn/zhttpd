# zhttpd benchmark plan

Compare the Zig HTTP/1.0+1.1 server (`zhttpd`) to nginx on the **same** `nginx.conf`,
the same static files, and the same load tool (`oha`, built under `~/Grok`, no brew).
nginx is always the reference. The HttpArena leader for the protocol under test is
also run where we have a binary; HTTP/1.1 first.

## Platforms

| Platform | Event backend | Where |
|---|---|---|
| macOS (this Mac, M3 Max) | kqueue | host, `~/Grok/zig-http-server` |
| Linux aarch64 | epoll (`reuseport`) | Lima `zhttpd-bench`; TLS continuation uses isolated `zhttpd-tls-perf` |

`io_uring` is **not** used. nginx 1.30.6 (the version already built from `deps/`) has
no `aio uring` / liburing support, and zhttpd’s readiness loop is kqueue/epoll only.
A new event backend plus a newer nginx would be a separate change. Apache is later.

The Linux VM is created from `bench/lima/zhttpd-bench.yaml`. It must not replace or
reconfigure Lima `default`, `infra-test`, Colima, or the `tc-prod-*` VMs.

The TLS continuation also uses `zhttpd-tls-perf`: the same pinned Ubuntu 24.04
image/kernel, 12 vCPUs. Initial series used 4 GiB RAM; the full 15-second series
uses 12 GiB after OHA exceeded the smaller guest's memory at c256. All compared
servers use the same guest allocation within a series; `env.txt` records RAM.
Four server workers are pinned to CPUs 0–3 and
oha to CPUs 4–11. This supplies more load-generator capacity and avoids sharing
the original VM with concurrent protocol benchmark tasks. Compare servers
within one series; do not divide RPS from different VM/client CPU arrangements.

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

Both servers apply `sendfile_max_chunk` to large responses, including TLS. The
default is 2 MiB per event-loop turn; `0` disables this budget. The budget must
be identical for both servers, and latency checks include the 100 MiB case.

## Load tool, files, certs

- oha 1.16.0 at `tools/oha/bin/oha` (Darwin) or `tools/linux/oha` (Linux VM).
- Static files generated deterministically in `bench/www/static/`: 612 B HTML,
  64 KiB, 1 MiB and 100 MiB random binaries (seed 42).
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
- HTTPS 1 MiB and 100 MiB, keep-alive, 64 connections
- HTTPS small file, keep-alive off, 64 connections (session resumption is enabled
  by the default config; this is not a full-handshake-only measurement)

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

# Focus on HTTPS (same configuration, files and load settings for every server).
SCENARIO_FILTER='^https-' SERVERS="zhttpd nginx" bench/run.sh

# Include a saved ReleaseFast binary built before the optimization.
ZHTTPD_BASELINE=/absolute/path/to/baseline/zhttpd \
  SERVERS="zhttpd-baseline nginx zhttpd" SCENARIO_FILTER='^https-' bench/run.sh

# Linux: measure server CPU throughput without competing with the load client.
# Both servers get the same one-worker config and CPU 0; oha gets CPUs 1-3.
WORKERS=1 SERVER_CPUS=0 LOAD_CPUS=1-3 \
  SERVERS="zhttpd nginx" SCENARIO_FILTER='^https-' bench/run.sh

# Four server CPUs and eight separate client CPUs in the TLS VM.
WORKERS=4 SERVER_CPUS=0-3 LOAD_CPUS=4-11 DURATION=10 WARMUP=5 REPS=4 \
  ZHTTPD_BASELINE=/absolute/path/to/saved/baseline \
  SERVERS="zhttpd-baseline nginx zhttpd" SCENARIO_FILTER='^https-' bench/run.sh

# Full handshakes: disable resumption identically for every compared server.
# oha --disable-keepalive alone still reuses TLS sessions. Keep cipher/group,
# certificate and all other settings unchanged; archive the rendered config.
mkdir -p .run
sed -e 's/ssl_session_cache shared:SSL:50m;/ssl_session_cache off;/' \
    -e 's/ssl_session_tickets on;/ssl_session_tickets off;/' \
    bench/nginx.conf.in > .run/full-handshake.conf.in
CONF_TEMPLATE="$PWD/.run/full-handshake.conf.in" \
  WORKERS=1 SERVER_CPUS=0 LOAD_CPUS=1-7 REPS=4 \
  SERVERS="zhttpd nginx" SCENARIO_FILTER='^https-small-noka' bench/run.sh

# Final acceptance matrix: all five HTTPS scenarios, including full handshakes.
# Use a guest with enough RAM for OHA (12 GiB in the recorded final series).
CONF_TEMPLATE="$PWD/.run/full-handshake.conf.in" \
  WORKERS=4 SERVER_CPUS=0-3 LOAD_CPUS=4-11 DURATION=15 WARMUP=3 REPS=6 \
  ZHTTPD=/absolute/path/to/final/zhttpd \
  ZHTTPD_BASELINE=/absolute/path/to/saved/baseline \
  SERVERS="zhttpd-baseline nginx zhttpd" SCENARIO_FILTER='^https-' bench/run.sh

# An explicit acceptance gate: every measured scenario must reach >=1.5x nginx,
# with median p99 no worse than nginx AND the saved zhttpd baseline (if supplied),
# all repetitions/scenarios present, and no HTTP/client errors. Exits 1 on failure.
python3 bench/check-target.py bench/results/STAMP 1.5

# Linux (after the VM exists — see bench/lima/README.md)
limactl start zhttpd-bench    # never start/stop default, infra-test, Colima, tc-prod-*
limactl shell zhttpd-bench -- bash /Users/listepo/Grok/zig-http-server/bench/lima/setup-vm.sh
limactl shell zhttpd-bench -- bash /Users/listepo/Grok/zig-http-server/bench/run.sh
```

Do not publish a run whose `load.log` shows a colliding leftover server, bind
failures, or a 1-minute load average that is dominated by unrelated work without
saying so in the report.

Timed samples now use oha `-w -t 10s`: in-flight requests finish after the
deadline, with a timeout, instead of being counted as deadline-abort errors.
Keep-alive throughput, resumed TLS sessions, and full TLS handshakes are separate metrics;
passing one scenario does not establish a blanket performance guarantee.

Use `CONF_TEMPLATE=/absolute/path/to/template.conf.in` to compare another shared
configuration. The result directory retains the rendered configuration, binary
SHA-256 hashes, and scenario manifest. Compare different configurations as
separate series, not selected samples from different configurations.
