# zhttpd benchmark results

Raw data: `bench/results/20261112-163101/` (oha JSON per run, runs.csv, load.log, nginx.conf).

```
date: Thu Nov 12 16:31:01 EET 2026
host: Linux lima-zhttpd-bench 6.8.0-134-generic #134-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun 26 18:28:11 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux
cpus: 8
memory_total_kib: 3998344
oha: oha 1.16.0
zhttpd: zhttpd version: zhttpd/0.1.0 built with Zig 0.17.1, event backend epoll, TLS OpenSSL, HTTP/2+HTTP/3 enabled 
zhttpd_binary: /home/listepo.guest/zhttpd-perf-mux-memory/candidate/zig-out/bin/zhttpd
zhttpd-baseline: /home/listepo.guest/zhttpd-perf-mux-memory/baseline/bin/zhttpd
nginx: nginx version: nginx/1.30.6 built by gcc 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)  built with OpenSSL 3.5.9 29 Sep 2026 TLS SNI support enabled configure arguments: --prefix=/home/listepo.guest/zhttpd-perf-h2-h3/nginx --with-cc-opt='-O2 -I/home/listepo.guest/zhttpd-build/openssl-ktls-install/include' --with-ld-opt=-L/home/listepo.guest/zhttpd-build/openssl-ktls-install/lib --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-threads --with-file-aio --with-pcre=../pcre2 --with-zlib=../zlib 
zhttpd_sha256: 6e833351845887f3ad367670c1777d24ef2d1a0799e42b0a2c59d6e0ecd880f8
nginx_sha256: 29ba2175e0c2978f33dd21116170af43ff007f58c5c34638e609bac791dafdf4
zhttpd-baseline_sha256: f1f5b4b6b7b2369d8e5ef6a0787088a6627cd017ed447f03e1763b7a2b132255
oha_sha256: 90e2c783f84a61fa6cbdf8399025e9a12aa73111ea28962e5d5e62b820a856af
leader: dusty-tuned (5646c1d2a4f4656073430ce55ed39a5c9c2e6749)
duration=5s warmup=1s keepalive-off=12000 requests reps=2 servers=[zhttpd-baseline nginx zhttpd]
workers=1 server_cpus=0 load_cpus=1-7 scenario_filter=small-ka-c4|large
http_version=2 streams_per_connection=16
```

RPS = median over repetitions of successful (2xx) requests per second; [min-max] across repetitions.
Latency = median of per-run percentiles (ms). `load` = median 1-min load average around the runs
(load average is contextual, not CPU utilization). Per-run `.err` sidecars record CPU usage.
`vs nginx` compares median RPS; use `check-target.py` to enforce throughput, p99 and errors.

## HTTP/2 (TLS 1.3)

### h2-small-ka-c4-p16: 612 B static file, keep-alive, 4 connections, 16 streams per connection

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 351,044 | 350,713-351,375 | 0.18 | 0.20 | 0.26 | 1.84x | 0/0 | 1.7 |
| nginx | 191,243 | 189,861-192,625 | 0.33 | 0.38 | 0.47 | 1.00x | 0/0 | 1.9 |
| zhttpd | 346,752 | 346,031-347,473 | 0.18 | 0.20 | 0.26 | 1.81x | 0/0 | 1.9 |

### h2-large-ka-c4-p16: 1 MiB static file, keep-alive, 4 connections, 16 streams per connection

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 2,277 | 2,266-2,288 | 27.89 | 29.32 | 33.33 | 1.23x | 0/0 | 1.8 |
| nginx | 1,846 | 1,812-1,881 | 35.65 | 43.72 | 46.38 | 1.00x | 0/0 | 1.9 |
| zhttpd | 2,204 | 2,111-2,297 | 28.16 | 30.28 | 43.94 | 1.19x | 0/0 | 1.9 |

## Summary (median RPS)

| scenario | zhttpd-baseline | nginx | zhttpd |
|---|---:|---:|---:|
| h2-small-ka-c4-p16 | 351,044 | 191,243 | 346,752 |
| h2-large-ka-c4-p16 | 2,277 | 1,846 | 2,204 |

## Notes and competitor differences

## How to run

See `bench/PLAN.md`. The exact nginx.conf for a published run is stored in that
run’s result directory and at `bench/nginx.conf` (rendered from `bench/nginx.conf.in`).

## dusty-tuned (HttpArena HTTP/1.1 leader)

Source: HttpArena `frameworks/dusty-tuned` at commit
`5646c1d2a4f4656073430ce55ed39a5c9c2e6749`, upstream [dusty](https://github.com/lalinsky/dusty)
on the zio runtime, built `zig build --release=fast`. “tuned” means json.zig and
no request or keep-alive timeouts.

It is **not** an nginx-compatible server. The bench runs it with an equivalent
setup, not `nginx.conf`.

| Topic | zhttpd / nginx | dusty-tuned in this bench |
|---|---|---|
| Config | shared `bench/nginx.conf` | no config file; routes hard-coded |
| Bind | from `listen` (48080 / 48443) | `PORT` / `TLS_PORT` env (our patch) |
| Static files | `root bench/www` + `try_files` | `STATIC_DIR` mounted at `/static` (our patch); also advertises precompressed `.br`/`.gzip` variants |
| TLS certs | `ssl_certificate` / `ssl_certificate_key` | `TLS_CERT` / `TLS_KEY` (already in upstream) |
| TLS settings | `ssl_protocols TLSv1.3`, session cache + tickets from the same directives | dusty’s own TLS stack, ALPN `http/1.1` only; no nginx `ssl_session_cache` |
| HTTP/2 and HTTP/3 | default HTTP/1.1 suite: `http2 off`; dedicated suites enable HTTP/2 or QUIC on both servers | HTTP/1.1 only; excluded from the HTTP/2 and HTTP/3 suites |
| Processes | `worker_processes auto` (16 on this Mac), `reuseport` | one process, zio executors `.auto` |
| Timeouts | `keepalive_timeout 65` | none (the “tuned” variant) |
| Dynamic `/baseline11` | nginx `return 200 "3"` (zhttpd implements `return`) | dusty handler (same body) |

Build wrapper: `bench/competitors/build-dusty.sh`. The patch is
`bench/competitors/dusty-tuned.patch` and only adds the three environment
overrides; defaults stay 8080/8081 and `/data/static`.

### Known pitfalls

- macOS has ~16k ephemeral ports and a 30 s TIME_WAIT. A keep-alive-off run
  that is time-bounded will burn the pool and fail with
  `Can't assign requested address (os error 49)`. The harness therefore uses a
  fixed request count and waits for TIME_WAIT to drain.
- The first published `--quick` run (20261110-100440) still hit this on dusty
  HTTPS (and partly on HTTP noka) because dusty ran last, after earlier noka
  samples. Later runs wait harder between samples.
- dusty logged `error.SocketUnconnected` on some connections during that run.
- Run `20261110-100920` is invalid (leftover zhttpd held the ports). Ignore it.

## io_uring

Not used. nginx 1.30.6 has no io_uring support; zhttpd has no io_uring backend.
Linux comparisons use epoll + `reuseport`.

## Apache

Deferred (“Apache later”). No Apache binary or scenario is wired up.

