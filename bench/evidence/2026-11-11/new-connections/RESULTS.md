# zhttpd benchmark results

Raw data: `bench/results/20261111-223817/` (oha JSON per run, runs.csv, load.log, nginx.conf).

```
date: Wed Nov 11 22:38:17 EET 2026
host: Linux lima-zhttpd-bench 6.8.0-134-generic #134-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun 26 18:28:11 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux
cpus: 8
oha: oha 1.16.0
zhttpd: zhttpd version: zhttpd/0.1.0 built with Zig 0.17.1, event backend epoll, TLS OpenSSL, HTTP/2+HTTP/3 disabled
zhttpd_binary: /home/listepo.guest/zhttpd-finalize-performance/candidate/zig-out/bin/zhttpd
zhttpd-baseline: /home/listepo.guest/zhttpd-finalize-performance/baseline/zig-out/bin/zhttpd
nginx: nginx version: nginx/1.30.6 built by gcc 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)  built with OpenSSL 3.5.9 29 Sep 2026 TLS SNI support enabled configure arguments: --prefix=/home/listepo.guest/zhttpd-tools/nginx-ktls --with-cc-opt='-O2 -I/home/listepo.guest/zhttpd-build/openssl-ktls-install/include' --with-ld-opt=-L/home/listepo.guest/zhttpd-build/openssl-ktls-install/lib --with-http_ssl_module --with-http_v2_module --with-threads --with-file-aio --with-pcre=/home/listepo.guest/zhttpd-build/pcre2-10.49 --with-zlib=/home/listepo.guest/zhttpd-build/zlib-1.3.1
zhttpd_sha256: f98611e90d6d6d7b7e75024cc4bcd51ebba24a8a757ee5d378158196599d0b53
nginx_sha256: ebeedac95f94ffa8bc16eb5935f3659036d6a9f728e0f60e11fe3277c4a5059f
zhttpd-baseline_sha256: 4bd56ec864ec5f6bd242de1e3ff5df737550fecd4548879e899ba2988ec3f2ca
leader: dusty-tuned (5646c1d2a4f4656073430ce55ed39a5c9c2e6749)
duration=10s warmup=2s keepalive-off=12000 requests reps=4 servers=[zhttpd-baseline nginx zhttpd]
workers=4 server_cpus=0-3 load_cpus=4-7 scenario_filter=^https-small-noka-
```

RPS = median over repetitions of successful (2xx) requests per second; [min-max] across repetitions.
Latency = median of per-run percentiles (ms). `load` = median 1-min load average around the runs
(the Mac is shared; high load means noisy numbers). `vs nginx` compares median RPS.

## HTTPS (TLS 1.3)

### https-small-noka-c64: 612 B static file, new connection per request, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 20,217 | 20,087-20,454 | 2.50 | 6.03 | 9.72 | 0.97x | 0/0 | 7.5 |
| nginx | 20,887 | 20,776-21,231 | 2.39 | 5.99 | 9.39 | 1.00x | 0/0 | 7.5 |
| zhttpd | 21,215 | 21,005-21,404 | 2.43 | 5.77 | 8.71 | 1.02x | 0/0 | 7.5 |

## Handshake-heavy (HTTPS, keep-alive off)

### https-small-noka-c64: 612 B static file, new connection per request, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd-baseline | 20,217 | 20,087-20,454 | 2.50 | 6.03 | 9.72 | 0.97x | 0/0 | 7.5 |
| nginx | 20,887 | 20,776-21,231 | 2.39 | 5.99 | 9.39 | 1.00x | 0/0 | 7.5 |
| zhttpd | 21,215 | 21,005-21,404 | 2.43 | 5.77 | 8.71 | 1.02x | 0/0 | 7.5 |

## Summary (median RPS)

| scenario | zhttpd-baseline | nginx | zhttpd |
|---|---:|---:|---:|
| https-small-noka-c64 | 20,217 | 20,887 | 21,215 |

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
