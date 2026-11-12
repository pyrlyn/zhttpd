# zhttpd benchmark results

Raw data: `bench/results/20261112-032814/` (oha JSON per run, runs.csv, load.log, nginx.conf).

```
date: Thu Nov 12 03:28:15 EET 2026
host: Linux lima-zhttpd-bench 6.8.0-134-generic #134-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun 26 18:28:11 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux
cpus: 8
oha: oha 1.16.0
zhttpd: zhttpd version: zhttpd/0.1.0 built with Zig 0.17.1, event backend epoll, TLS OpenSSL, HTTP/2+HTTP/3 enabled 
zhttpd_binary: /home/listepo.guest/zhttpd-memory-nginx-10/candidate/.run/gc/bin/zhttpd
zhttpd-baseline: /home/listepo.guest/zhttpd-memory-nginx-10/baseline/zig-out/bin/zhttpd
nginx: nginx version: nginx/1.30.6 built by gcc 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)  built with OpenSSL 3.5.9 29 Sep 2026 TLS SNI support enabled configure arguments: --prefix=/home/listepo.guest/zhttpd-perf-h2-h3/nginx --with-cc-opt='-O2 -I/home/listepo.guest/zhttpd-build/openssl-ktls-install/include' --with-ld-opt=-L/home/listepo.guest/zhttpd-build/openssl-ktls-install/lib --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-threads --with-file-aio --with-pcre=../pcre2 --with-zlib=../zlib 
zhttpd_sha256: f15b68383b21cf1e333e896e9750c76eb44321d42e826a65c3245c6df034988a
nginx_sha256: 29ba2175e0c2978f33dd21116170af43ff007f58c5c34638e609bac791dafdf4
zhttpd-baseline_sha256: 671f9794200a2e274e989a1b0af079c91d598ff22aa87e7f0853f4920f266962
oha_sha256: 99a790eb8c3e0feaca974bd6b32f0f8d4426a0c5b289f39e833e5b2c7529cd39
leader: dusty-tuned (5646c1d2a4f4656073430ce55ed39a5c9c2e6749)
duration=5s warmup=1s keepalive-off=12000 requests reps=4 servers=[zhttpd-baseline nginx zhttpd]
workers=1 server_cpus=0 load_cpus=1-7 scenario_filter=^(http-small-ka-c(64|256|1024)|http-large-ka-c64|https-small-ka-c(64|256)|https-large-ka-c64)[|]
http_version=1.1 streams_per_connection=16
```

RPS = median over repetitions of successful (2xx) requests per second; [min-max] across repetitions.
Latency = median of per-run percentiles (ms). `load` = median 1-min load average around the runs
(load average is contextual, not CPU utilization). Per-run `.err` sidecars record CPU usage.
`vs nginx` compares median RPS; use `check-target.py` to enforce throughput, p99 and errors.

## HTTP (plain)

### http-small-ka-c64: 612 B static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 276,828 | 254,507-287,195 | 0.22 | 0.29 | 0.40 | 1.65x | 0/0 | 2.3 |
| nginx | 168,203 | 165,944-175,940 | 0.37 | 0.43 | 0.50 | 1.00x | 0/0 | 2.3 |
| zhttpd | 280,220 | 264,396-295,960 | 0.21 | 0.29 | 0.41 | 1.67x | 0/0 | 2.4 |

### http-small-ka-c256: 612 B static file, keep-alive, 256 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 206,438 | 194,277-286,000 | 1.20 | 1.57 | 1.88 | 1.24x | 0/0 | 2.4 |
| nginx | 166,563 | 163,026-171,826 | 1.50 | 1.69 | 1.96 | 1.00x | 0/0 | 2.3 |
| zhttpd | 272,204 | 209,440-290,157 | 0.81 | 1.37 | 1.91 | 1.63x | 0/0 | 2.4 |

### http-small-ka-c1024: 612 B static file, keep-alive, 1024 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 165,173 | 153,482-182,799 | 5.84 | 7.37 | 8.14 | 1.09x | 0/0 | 2.4 |
| nginx | 152,136 | 150,631-157,915 | 6.49 | 7.40 | 8.74 | 1.00x | 0/0 | 2.2 |
| zhttpd | 182,322 | 152,286-211,323 | 5.39 | 6.81 | 7.51 | 1.20x | 0/0 | 2.3 |

### http-large-ka-c64: 1 MiB static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 21,233 | 20,076-21,587 | 2.86 | 3.78 | 4.15 | 1.04x | 0/0 | 2.5 |
| nginx | 20,354 | 20,178-21,215 | 3.14 | 3.72 | 4.28 | 1.00x | 0/0 | 2.3 |
| zhttpd | 21,093 | 19,815-21,453 | 2.88 | 3.82 | 4.18 | 1.04x | 0/0 | 2.4 |

## HTTPS (TLS 1.3)

### https-small-ka-c64: 612 B static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 188,427 | 180,919-191,489 | 0.32 | 0.40 | 0.49 | 1.44x | 0/0 | 2.5 |
| nginx | 130,641 | 123,604-135,252 | 0.47 | 0.54 | 0.68 | 1.00x | 0/0 | 2.5 |
| zhttpd | 192,629 | 188,697-194,790 | 0.32 | 0.39 | 0.48 | 1.47x | 0/0 | 2.5 |

### https-small-ka-c256: 612 B static file, keep-alive, 256 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 159,402 | 154,861-164,393 | 1.52 | 1.81 | 2.39 | 1.37x | 0/0 | 2.4 |
| nginx | 116,558 | 115,817-119,763 | 2.11 | 2.42 | 2.98 | 1.00x | 0/0 | 2.4 |
| zhttpd | 168,709 | 160,611-171,512 | 1.45 | 1.70 | 2.25 | 1.45x | 0/0 | 2.4 |

### https-large-ka-c64: 1 MiB static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 2,293 | 2,214-2,315 | 27.25 | 29.92 | 32.83 | 1.12x | 0/0 | 2.3 |
| nginx | 2,038 | 1,920-2,053 | 30.91 | 32.90 | 35.32 | 1.00x | 0/0 | 2.3 |
| zhttpd | 2,274 | 2,237-2,350 | 27.45 | 29.83 | 32.32 | 1.12x | 0/0 | 2.4 |

## Summary (median RPS)

| scenario | zhttpd-baseline | nginx | zhttpd |
|---|---:|---:|---:|
| http-small-ka-c64 | 276,828 | 168,203 | 280,220 |
| http-small-ka-c256 | 206,438 | 166,563 | 272,204 |
| http-small-ka-c1024 | 165,173 | 152,136 | 182,322 |
| http-large-ka-c64 | 21,233 | 20,354 | 21,093 |
| https-small-ka-c64 | 188,427 | 130,641 | 192,629 |
| https-small-ka-c256 | 159,402 | 116,558 | 168,709 |
| https-large-ka-c64 | 2,293 | 2,038 | 2,274 |

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

