# zhttpd benchmark results

Raw data: `bench/results/20261112-032358/` (oha JSON per run, runs.csv, load.log, nginx.conf).

```
date: Thu Nov 12 03:23:58 UTC 2026
host: Linux lima-zhttpd-tls-perf 6.8.0-134-generic #134-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun 26 18:28:11 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux
cpus: 12
memory_total_kib: 12220168
oha: oha 1.16.0
zhttpd: zhttpd version: zhttpd/0.1.0 built with Zig 0.17.1, event backend epoll, TLS AWS-LC 
zhttpd_binary: /home/listepo.guest/zhttpd-perf-50/iteration4-etag/bin/zhttpd
zhttpd-baseline: /home/listepo.guest/zhttpd-perf-50/aws-lc-pooled-partial/bin/zhttpd
nginx: nginx version: nginx/1.30.6 built by gcc 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)  built with OpenSSL 3.5.9 29 Sep 2026 TLS SNI support enabled configure arguments: --prefix=/home/listepo.guest/zhttpd-tools/nginx-ktls --with-cc-opt='-O2 -I/home/listepo.guest/zhttpd-build/openssl-ktls-install/include' --with-ld-opt=-L/home/listepo.guest/zhttpd-build/openssl-ktls-install/lib --with-http_ssl_module --with-http_v2_module --with-threads --with-file-aio --with-pcre=/home/listepo.guest/zhttpd-build/pcre2-10.49 --with-zlib=/home/listepo.guest/zhttpd-build/zlib-1.3.1 
zhttpd_sha256: 71cd276274950a17db742c7d881d8ea765a20d9c31d630a8f51bb8d6cd00daee
nginx_sha256: ebeedac95f94ffa8bc16eb5935f3659036d6a9f728e0f60e11fe3277c4a5059f
zhttpd-baseline_sha256: e76de71d9afe6ee2b4ce74366616d5e43be014e5bd8bbcdd620c2821dff7a279
leader: dusty-tuned (5646c1d2a4f4656073430ce55ed39a5c9c2e6749)
duration=15s warmup=3s keepalive-off=12000 requests reps=6 servers=[zhttpd-baseline nginx zhttpd]
workers=4 server_cpus=0-3 load_cpus=4-11 scenario_filter=^https-
```

RPS = median over repetitions of successful (2xx) requests per second; [min-max] across repetitions.
Latency = median of per-run percentiles (ms). `load` = median 1-min load average around the runs
(the Mac is shared; high load means noisy numbers). `vs nginx` compares median RPS.

## HTTPS (TLS 1.3)

### https-small-ka-c64: 612 B static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 639,976 | 632,407-656,659 | 0.09 | 0.15 | 0.22 | 1.62x | 0/0 | 7.0 |
| nginx | 394,629 | 387,300-423,492 | 0.16 | 0.22 | 0.29 | 1.00x | 0/0 | 7.5 |
| zhttpd | 662,954 | 642,883-669,915 | 0.09 | 0.14 | 0.21 | 1.68x | 0/0 | 7.0 |

### https-small-ka-c256: 612 B static file, keep-alive, 256 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 730,055 | 724,043-736,626 | 0.34 | 0.45 | 0.58 | 1.83x | 0/0 | 7.1 |
| nginx | 398,511 | 393,710-400,498 | 0.63 | 0.78 | 0.91 | 1.00x | 0/0 | 6.9 |
| zhttpd | 762,323 | 752,506-764,012 | 0.33 | 0.43 | 0.57 | 1.91x | 0/0 | 7.1 |

### https-large-ka-c64: 1 MiB static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 12,183 | 12,016-12,204 | 5.35 | 6.88 | 7.40 | 1.55x | 0/0 | 7.3 |
| nginx | 7,835 | 7,780-7,928 | 7.80 | 11.16 | 11.81 | 1.00x | 0/0 | 6.7 |
| zhttpd | 13,284 | 13,150-13,360 | 4.63 | 6.24 | 6.88 | 1.70x | 0/0 | 7.5 |

### https-huge-ka-c64: 100 MiB static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 106 | 105-107 | 471.59 | 1095.01 | 1809.44 | 1.46x | 0/0 | 7.4 |
| nginx | 73 | 72-74 | 657.94 | 1559.59 | 2695.80 | 1.00x | 0/0 | 6.8 |
| zhttpd | 122 | 120-124 | 484.85 | 659.14 | 677.83 | 1.68x | 0/0 | 7.6 |

### https-small-noka-c64: 612 B static file, new connection per request, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 37,196 | 36,337-37,630 | 1.41 | 2.74 | 4.46 | 1.96x | 0/0 | 7.4 |
| nginx | 19,000 | 18,740-19,276 | 3.00 | 5.93 | 9.30 | 1.00x | 0/0 | 6.8 |
| zhttpd | 39,864 | 39,167-40,452 | 1.32 | 2.47 | 3.69 | 2.10x | 0/0 | 7.6 |

## Handshake-heavy (HTTPS, keep-alive off)

### https-small-noka-c64: 612 B static file, new connection per request, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 37,196 | 36,337-37,630 | 1.41 | 2.74 | 4.46 | 1.96x | 0/0 | 7.4 |
| nginx | 19,000 | 18,740-19,276 | 3.00 | 5.93 | 9.30 | 1.00x | 0/0 | 6.8 |
| zhttpd | 39,864 | 39,167-40,452 | 1.32 | 2.47 | 3.69 | 2.10x | 0/0 | 7.6 |

## Summary (median RPS)

| scenario | zhttpd-baseline | nginx | zhttpd |
|---|---:|---:|---:|
| https-small-ka-c64 | 639,976 | 394,629 | 662,954 |
| https-small-ka-c256 | 730,055 | 398,511 | 762,323 |
| https-large-ka-c64 | 12,183 | 7,835 | 13,284 |
| https-huge-ka-c64 | 106 | 73 | 122 |
| https-small-noka-c64 | 37,196 | 19,000 | 39,864 |

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
| HTTP/2 | `http2 off` (zhttpd ignores the directive: not implemented) | ALPN does not offer `h2` |
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

