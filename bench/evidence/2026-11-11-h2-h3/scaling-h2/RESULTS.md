# zhttpd benchmark results

Raw data: `bench/results/scaling-h2/` (oha JSON per run, runs.csv, load.log, nginx.conf).

```
date: Thu Nov 12 00:11:24 EET 2026
host: Linux lima-zhttpd-bench 6.8.0-134-generic #134-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun 26 18:28:11 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux
cpus: 8
oha: oha 1.16.0
zhttpd: zhttpd version: zhttpd/0.1.0 built with Zig 0.17.1, event backend epoll, TLS OpenSSL, HTTP/2+HTTP/3 enabled
zhttpd_binary: /home/listepo.guest/zhttpd-perf-h2-h3/candidate/zig-out/bin/zhttpd
zhttpd-baseline: /home/listepo.guest/zhttpd-perf-h2-h3/baseline/zig-out/bin/zhttpd
nginx: nginx version: nginx/1.30.6 built by gcc 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)  built with OpenSSL 3.5.9 29 Sep 2026 TLS SNI support enabled configure arguments: --prefix=/home/listepo.guest/zhttpd-perf-h2-h3/nginx --with-cc-opt='-O2 -I/home/listepo.guest/zhttpd-build/openssl-ktls-install/include' --with-ld-opt=-L/home/listepo.guest/zhttpd-build/openssl-ktls-install/lib --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-threads --with-file-aio --with-pcre=../pcre2 --with-zlib=../zlib
zhttpd_sha256: 5b074cc3308ee8a429f4cf2da710f883aeb687733a030ef229e67a6a21f6e71b
nginx_sha256: 29ba2175e0c2978f33dd21116170af43ff007f58c5c34638e609bac791dafdf4
zhttpd-baseline_sha256: 28e936a040569255652ae7bde004370806f86577d0dc0b314cf56f3a03b9cd05
oha_sha256: 90e2c783f84a61fa6cbdf8399025e9a12aa73111ea28962e5d5e62b820a856af
leader: dusty-tuned (5646c1d2a4f4656073430ce55ed39a5c9c2e6749)
duration=10s warmup=2s keepalive-off=12000 requests reps=4 servers=[nginx zhttpd]
workers=4 server_cpus=0-3 load_cpus=4-7 scenario_filter=all
http_version=2 streams_per_connection=16
layout=scaling
source_revision=342d4ac
baseline_revision=133b623
oha_source=v1.16.0+c156bf3d442f5150fb1ad73e8c5144bd882ac4cd+bench/oha-http3-drain.patch
zhttpd_build=Zig 0.17.1 ReleaseFast -Dtls=true -Dhttp=true OpenSSL 3.5.9 nghttp2 1.71.0 nghttp3 1.19.0
repeat_reason=initial scaling-h2 reached nginx keepalive_requests limit and produced HTTP2 errors; this run raises limit on both servers
```

RPS = median over repetitions of successful (2xx) requests per second; [min-max] across repetitions.
Latency = median of per-run percentiles (ms). `load` = median 1-min load average around the runs
(load average is contextual, not CPU utilization). Per-run `.err` sidecars record CPU usage.
`vs nginx` compares median RPS; use `check-target.py` to enforce throughput, p99 and errors.

## HTTP/2 (TLS 1.3)

### h2-small-ka-c4-p16: 612 B static file, keep-alive, 4 connections, 16 streams per connection

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| nginx | 167,233 | 98,984-194,050 | 0.31 | 0.63 | 1.57 | 1.00x | 0/0 | 4.2 |
| zhttpd | 179,322 | 150,817-188,153 | 0.32 | 0.52 | 1.15 | 1.07x | 0/0 | 4.0 |

### h2-small-ka-c16-p16: 612 B static file, keep-alive, 16 connections, 16 streams per connection

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| nginx | 287,548 | 220,084-358,584 | 0.67 | 1.56 | 4.06 | 1.00x | 0/0 | 4.2 |
| zhttpd | 350,503 | 329,768-368,129 | 0.59 | 1.23 | 2.86 | 1.22x | 0/0 | 3.9 |

### h2-large-ka-c4-p16: 1 MiB static file, keep-alive, 4 connections, 16 streams per connection

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| nginx | 3,625 | 2,836-4,304 | 11.72 | 30.78 | 45.41 | 1.00x | 0/0 | 4.5 |
| zhttpd | 3,406 | 2,800-4,446 | 14.26 | 29.94 | 54.84 | 0.94x | 0/0 | 4.2 |

## Summary (median RPS)

| scenario | nginx | zhttpd |
|---|---:|---:|
| h2-small-ka-c4-p16 | 167,233 | 179,322 |
| h2-small-ka-c16-p16 | 287,548 | 350,503 |
| h2-large-ka-c4-p16 | 3,625 | 3,406 |

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
