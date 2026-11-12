# zhttpd benchmark results

Raw data: `bench/results/20261112-152752/` (oha JSON per run, runs.csv, load.log, nginx.conf).

```
date: Thu Nov 12 15:27:52 EET 2026
host: Linux lima-zhttpd-bench 6.8.0-134-generic #134-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun 26 18:28:11 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux
cpus: 8
memory_total_kib: 3998344
oha: oha 1.16.0
zhttpd: zhttpd version: zhttpd/0.1.0 built with Zig 0.17.1, event backend epoll, TLS OpenSSL, HTTP/2+HTTP/3 enabled 
zhttpd_binary: /home/listepo.guest/zhttpd-perf-h3-throughput/candidate/zig-out/bin/zhttpd
zhttpd-baseline: /home/listepo.guest/zhttpd-perf-h3-throughput/baseline/bin/zhttpd
nginx: nginx version: nginx/1.30.6 built by gcc 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)  built with OpenSSL 3.5.9 29 Sep 2026 TLS SNI support enabled configure arguments: --prefix=/home/listepo.guest/zhttpd-perf-h2-h3/nginx --with-cc-opt='-O2 -I/home/listepo.guest/zhttpd-build/openssl-ktls-install/include' --with-ld-opt=-L/home/listepo.guest/zhttpd-build/openssl-ktls-install/lib --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-threads --with-file-aio --with-pcre=../pcre2 --with-zlib=../zlib 
zhttpd_sha256: f1f5b4b6b7b2369d8e5ef6a0787088a6627cd017ed447f03e1763b7a2b132255
nginx_sha256: 29ba2175e0c2978f33dd21116170af43ff007f58c5c34638e609bac791dafdf4
zhttpd-baseline_sha256: 3e4fdaf981c5c9b699bc60dd71c73baf1d6a4afcd7ccc25d6303d0b543b13ad5
oha_sha256: 90e2c783f84a61fa6cbdf8399025e9a12aa73111ea28962e5d5e62b820a856af
leader: dusty-tuned (5646c1d2a4f4656073430ce55ed39a5c9c2e6749)
duration=10s warmup=2s keepalive-off=12000 requests reps=4 servers=[zhttpd-baseline nginx zhttpd]
workers=1 server_cpus=0 load_cpus=1-7 scenario_filter=all
http_version=3 streams_per_connection=16
```

RPS = median over repetitions of successful (2xx) requests per second; [min-max] across repetitions.
Latency = median of per-run percentiles (ms). `load` = median 1-min load average around the runs
(load average is contextual, not CPU utilization). Per-run `.err` sidecars record CPU usage.
`vs nginx` compares median RPS; use `check-target.py` to enforce throughput, p99 and errors.

## HTTP/3 (QUIC / TLS 1.3)

### h3-small-ka-c4-p16: 612 B static file, keep-alive, 4 connections, 16 streams per connection

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 162,417 | 161,779-164,549 | 0.39 | 0.42 | 0.53 | 0.67x | 0/0 | 2.2 |
| nginx | 243,995 | 243,178-246,537 | 0.26 | 0.28 | 0.35 | 1.00x | 0/0 | 2.2 |
| zhttpd | 168,113 | 162,931-169,700 | 0.37 | 0.40 | 0.52 | 0.69x | 0/0 | 2.2 |

### h3-small-ka-c16-p16: 612 B static file, keep-alive, 16 connections, 16 streams per connection

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 166,216 | 165,105-167,596 | 1.74 | 1.99 | 2.47 | 0.66x | 0/0 | 2.3 |
| nginx | 251,513 | 232,209-253,446 | 0.99 | 1.09 | 1.39 | 1.00x | 0/0 | 2.3 |
| zhttpd | 172,635 | 170,338-173,286 | 1.65 | 1.93 | 2.39 | 0.69x | 0/0 | 2.2 |

### h3-large-ka-c4-p16: 1 MiB static file, keep-alive, 4 connections, 16 streams per connection

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 829 | 827-854 | 76.74 | 78.95 | 80.39 | 1.38x | 0/0 | 2.3 |
| nginx | 602 | 591-664 | 102.26 | 126.89 | 158.87 | 1.00x | 0/0 | 2.3 |
| zhttpd | 1,003 | 979-1,017 | 63.51 | 65.69 | 68.45 | 1.67x | 0/0 | 2.2 |

## Summary (median RPS)

| scenario | zhttpd-baseline | nginx | zhttpd |
|---|---:|---:|---:|
| h3-small-ka-c4-p16 | 162,417 | 243,995 | 168,113 |
| h3-small-ka-c16-p16 | 166,216 | 251,513 | 172,635 |
| h3-large-ka-c4-p16 | 829 | 602 | 1,003 |

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

