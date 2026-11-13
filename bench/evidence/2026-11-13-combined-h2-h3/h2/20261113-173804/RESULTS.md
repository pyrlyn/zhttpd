# zhttpd benchmark results

Raw data: `bench/results/20261113-173804/` (oha JSON per run, runs.csv, load.log, nginx.conf).

```
date: Fri Nov 13 17:38:05 EET 2026
host: Linux lima-zhttpd-bench 6.8.0-149-generic #149-Ubuntu SMP PREEMPT_DYNAMIC Fri Oct 23 13:37:55 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux
cpus: 8
memory_total_kib: 3998280
oha: oha 1.16.0
zhttpd: zhttpd version: zhttpd/0.1.0 built with Zig 0.17.1, event backend epoll, TLS OpenSSL, HTTP/2+HTTP/3 enabled 
zhttpd_binary: /home/listepo.guest/zhttpd-perf-60/combo/bin/zhttpd
zhttpd-baseline: /home/listepo.guest/zhttpd-perf-60/baseline/bin/zhttpd
nginx: nginx version: nginx/1.30.6 built by gcc 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)  built with OpenSSL 3.5.9 29 Sep 2026 TLS SNI support enabled configure arguments: --prefix=/home/listepo.guest/zhttpd-perf-h2-h3/nginx --with-cc-opt='-O2 -I/home/listepo.guest/zhttpd-build/openssl-ktls-install/include' --with-ld-opt=-L/home/listepo.guest/zhttpd-build/openssl-ktls-install/lib --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-threads --with-file-aio --with-pcre=../pcre2 --with-zlib=../zlib 
zhttpd_sha256: 20167d9f3ec0305ad6d4dd00056238487bf55b8fe079237efa80c8eba7075b47
nginx_sha256: 29ba2175e0c2978f33dd21116170af43ff007f58c5c34638e609bac791dafdf4
zhttpd-baseline_sha256: 350d2b30c71d2612fc887d1a67289ec56b936e5bc7c044a615e229a1d8b21096
oha_sha256: 90e2c783f84a61fa6cbdf8399025e9a12aa73111ea28962e5d5e62b820a856af
leader: dusty-tuned (5646c1d2a4f4656073430ce55ed39a5c9c2e6749)
duration=10s warmup=2s keepalive-off=12000 requests reps=5 servers=[zhttpd-baseline nginx zhttpd]
workers=1 server_cpus=0 load_cpus=1-7 scenario_filter=all
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
| zhttpd-baseline | 350,403 | 349,100-352,229 | 0.18 | 0.20 | 0.28 | 1.78x | 0/0 | 2.6 |
| nginx | 197,074 | 193,614-208,621 | 0.32 | 0.37 | 0.46 | 1.00x | 0/0 | 2.5 |
| zhttpd | 392,751 | 384,357-394,739 | 0.16 | 0.18 | 0.23 | 1.99x | 0/0 | 2.6 |

### h2-small-ka-c16-p16: 612 B static file, keep-alive, 16 connections, 16 streams per connection

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 364,884 | 358,696-366,834 | 0.68 | 0.76 | 0.90 | 1.83x | 0/0 | 2.6 |
| nginx | 199,132 | 197,760-208,838 | 1.28 | 1.41 | 1.56 | 1.00x | 0/0 | 2.6 |
| zhttpd | 406,095 | 400,406-410,354 | 0.62 | 0.68 | 0.83 | 2.04x | 0/0 | 2.6 |

### h2-large-ka-c4-p16: 1 MiB static file, keep-alive, 4 connections, 16 streams per connection

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 2,576 | 2,523-2,602 | 24.65 | 26.27 | 27.72 | 1.30x | 0/0 | 2.6 |
| nginx | 1,977 | 1,826-1,989 | 33.31 | 41.13 | 43.60 | 1.00x | 0/0 | 2.7 |
| zhttpd | 3,786 | 3,671-3,800 | 16.52 | 18.05 | 19.14 | 1.91x | 0/0 | 2.7 |

## Summary (median RPS)

| scenario | zhttpd-baseline | nginx | zhttpd |
|---|---:|---:|---:|
| h2-small-ka-c4-p16 | 350,403 | 197,074 | 392,751 |
| h2-small-ka-c16-p16 | 364,884 | 199,132 | 406,095 |
| h2-large-ka-c4-p16 | 2,576 | 1,977 | 3,786 |

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

