# zhttpd benchmark results

These are the historical 2026-11-10 runs. The integrated HTTP/TLS optimization,
comparison against the saved main baseline, p99 checks and committed raw
evidence are documented in [TLS-OPTIMIZATION.md](TLS-OPTIMIZATION.md).

Two official runs of the same plan (`DURATION=10` `REPS=2`, ABBA, ReleaseFast, shared `nginx.conf`, oha 1.16.0, HttpArena `dusty-tuned` at `5646c1d2`). nginx is the reference. HTTP/2 and HTTP/3 leaders are stubs.

| Platform | Event backend | CPUs | Raw data | Exact nginx.conf |
|---|---|---:|---|---|
| Linux aarch64, Lima `zhttpd-bench` (Ubuntu 24.04, 4 GiB) | epoll + `reuseport` | 4 | `bench/results/20261110-090437-linux/` | `bench/results/20261110-090437-linux/nginx.conf` |
| macOS, Apple M3 Max | kqueue + `reuseport` | 16 | `bench/results/20261110-102246/` | `bench/results/20261110-102246/nginx.conf` (also `bench/nginx.conf`) |

**Prefer the Linux tables** for ranking: the 4-CPU VM was otherwise idle and the `[min-max]` spreads are small. The Mac run is the same suite but the host load was 7–35 (other VMs and desktop jobs) and the 1-minute load average lags, so Mac “vs nginx” ratios are not a stable ranking.

How to run: `bench/run.sh --quick` or `bench/run.sh` from `~/Grok/zig-http-server` (see `bench/PLAN.md`). Linux: `bench/lima/README.md` (`zhttpd-bench` only; do not touch `default`, `infra-test`, Colima, or `tc-prod-*`).

`aborted due to deadline` is oha closing keep-alive connections at the end of a timed run, not a server failure. Keep-alive-off / handshake runs completed with 0 such errors.

## Findings (Linux)

- Small-file HTTP keep-alive: zhttpd is about **1.18× nginx** at 64 and 256 connections (341k and 371k RPS vs 289k and 314k), and still slightly ahead at 1024 connections (314k vs 300k). dusty-tuned is behind on static files (0.50–0.69× nginx) except on the tiny dynamic `/baseline11` probe, where it ties zhttpd (~409k vs 407k vs nginx 389k).
- 1 MiB HTTP: zhttpd and nginx are tied at **11.5k RPS**; dusty is 7.0k (0.60×).
- New-connection HTTP: all three are close; zhttpd 93k, nginx 91k, dusty 68k.
- HTTPS keep-alive, small file: zhttpd **256k / 268k** (c64 / c256) vs nginx 226k / 261k vs dusty 220k / 248k.
- Handshake-heavy (HTTPS, keep-alive off): essentially a tie — nginx 10.05k, zhttpd 9.77k, dusty 9.72k.

io_uring was not used (nginx 1.30.6 has no `aio uring`; zhttpd has no io_uring backend). Apache is later.


# Linux (epoll) — official comparison

Raw data: `bench/results/20261110-090437-linux/` (oha JSON per run, runs.csv, load.log, nginx.conf).

```
date: Tue Nov 10 09:04:37 UTC 2026
host: Linux lima-zhttpd-bench 6.8.0-134-generic #134-Ubuntu SMP PREEMPT_DYNAMIC Fri Jun 26 18:28:11 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux
cpus: 4
oha: oha 1.16.0
zhttpd: zhttpd version: zhttpd/0.1.0 built with Zig 0.17.1, event backend epoll, TLS OpenSSL 
nginx: nginx version: nginx/1.30.6 built by gcc 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)  built with OpenSSL 3.5.9 29 Sep 2026 TLS SNI support enabled configure arguments: --prefix=/home/listepo.guest/zhttpd-tools/nginx --with-cc-opt='-O2 -I/home/listepo.guest/zhttpd-build/openssl-install/include' --with-ld-opt=-L/home/listepo.guest/zhttpd-build/openssl-install/lib --with-http_ssl_module --with-http_v2_module --with-threads --with-file-aio --with-pcre=/home/listepo.guest/zhttpd-build/pcre2-10.49 --with-zlib=/home/listepo.guest/zhttpd-build/zlib-1.3.1 
leader: dusty-tuned (5646c1d2a4f4656073430ce55ed39a5c9c2e6749)
duration=10s warmup=2s keepalive-off=12000 requests reps=2 servers=[zhttpd nginx dusty-tuned]
```

RPS = median over repetitions of successful (2xx) requests per second; [min-max] across repetitions.
Latency = median of per-run percentiles (ms). `load` = median 1-min load average around the runs
Load is the VM 1-minute average (4 vCPU). Spreads are tight; `vs nginx` compares median RPS.

## HTTP (plain)

### http-small-ka-c16: 612 B static file, keep-alive, 16 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 291,770 | 291,354-292,185 | 0.05 | 0.09 | 0.15 | 1.22x | 0/32 (aborted due to deadline x16) | 4.3 |
| nginx | 238,586 | 207,114-270,058 | 0.04 | 0.11 | 0.54 | 1.00x | 0/29 (aborted due to deadline x16) | 5.4 |
| dusty-tuned | 143,595 | 142,734-144,455 | 0.09 | 0.16 | 0.32 | 0.60x | 0/31 (aborted due to deadline x16) | 5.7 |

### http-small-ka-c64: 612 B static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 341,479 | 336,980-345,978 | 0.12 | 0.39 | 1.14 | 1.18x | 0/112 (aborted due to deadline x57) | 4.9 |
| nginx | 288,812 | 287,389-290,235 | 0.13 | 0.48 | 1.38 | 1.00x | 0/127 (aborted due to deadline x63) | 5.8 |
| dusty-tuned | 200,262 | 199,270-201,254 | 0.25 | 0.46 | 2.52 | 0.69x | 0/108 (aborted due to deadline x59) | 5.9 |

### http-small-ka-c256: 612 B static file, keep-alive, 256 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 370,575 | 364,674-376,477 | 0.51 | 1.48 | 3.18 | 1.18x | 0/475 (aborted due to deadline x253) | 5.4 |
| nginx | 313,859 | 307,697-320,020 | 0.54 | 1.89 | 3.84 | 1.00x | 0/449 (aborted due to deadline x195) | 6.1 |
| dusty-tuned | 213,316 | 211,035-215,598 | 1.01 | 2.11 | 4.10 | 0.68x | 0/480 (aborted due to deadline x226) | 6.3 |

### http-small-ka-c1024: 612 B static file, keep-alive, 1024 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 314,469 | 307,477-321,462 | 3.17 | 5.86 | 8.47 | 1.05x | 0/1671 (aborted due to deadline x818) | 5.8 |
| nginx | 299,628 | 294,012-305,243 | 3.22 | 6.16 | 9.42 | 1.00x | 0/1724 (aborted due to deadline x792) | 6.4 |
| dusty-tuned | 149,538 | 149,241-149,836 | 6.25 | 10.97 | 16.20 | 0.50x | 0/1865 (aborted due to deadline x919) | 6.7 |

### http-medium-ka-c64: 64 KiB static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 140,906 | 139,526-142,286 | 0.38 | 0.90 | 1.67 | 1.13x | 0/113 (aborted due to deadline x57) | 6.2 |
| nginx | 125,071 | 107,791-142,351 | 0.37 | 1.01 | 2.87 | 1.00x | 0/106 (aborted due to deadline x59) | 6.7 |
| dusty-tuned | 79,870 | 79,855-79,884 | 0.64 | 1.37 | 3.44 | 0.64x | 0/121 (aborted due to deadline x58) | 6.9 |

### http-large-ka-c64: 1 MiB static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 11,513 | 11,204-11,821 | 5.10 | 9.33 | 12.38 | 1.00x | 0/121 (aborted due to deadline x58) | 6.5 |
| nginx | 11,506 | 10,934-12,079 | 5.01 | 9.44 | 13.54 | 1.00x | 0/120 (aborted due to deadline x64) | 6.7 |
| dusty-tuned | 6,955 | 6,898-7,011 | 8.78 | 14.59 | 20.39 | 0.60x | 0/128 (aborted due to deadline x64) | 7.2 |

### http-small-noka-c64: 612 B static file, new connection per request, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 92,935 | 91,429-94,441 | 0.50 | 1.43 | 2.89 | 1.02x | 0/0 | 6.6 |
| nginx | 90,671 | 87,998-93,345 | 0.54 | 1.40 | 2.49 | 1.00x | 0/0 | 6.7 |
| dusty-tuned | 67,777 | 65,755-69,798 | 0.87 | 1.52 | 2.35 | 0.75x | 0/0 | 7.3 |

### http-baseline-ka-c256: tiny dynamic answer (`return 200 "3"` / dusty handler), keep-alive, 256 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 406,732 | 405,335-408,129 | 0.39 | 1.45 | 3.32 | 1.04x | 0/423 (aborted due to deadline x197) | 3.3 |
| nginx | 389,233 | 387,849-390,617 | 0.42 | 1.48 | 3.45 | 1.00x | 0/478 (aborted due to deadline x228) | 3.5 |
| dusty-tuned | 408,779 | 401,072-416,485 | 0.37 | 1.46 | 3.29 | 1.05x | 0/463 (aborted due to deadline x243) | 3.6 |

## HTTPS (TLS 1.3)

### https-small-ka-c64: 612 B static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 256,397 | 254,194-258,601 | 0.19 | 0.52 | 1.11 | 1.13x | 0/122 (aborted due to deadline x58) | 4.1 |
| nginx | 226,166 | 224,705-227,627 | 0.15 | 0.63 | 1.95 | 1.00x | 0/128 (aborted due to deadline x64) | 4.3 |
| dusty-tuned | 220,068 | 219,864-220,272 | 0.24 | 0.42 | 1.79 | 0.97x | 0/118 (aborted due to deadline x60) | 4.3 |

### https-small-ka-c256: 612 B static file, keep-alive, 256 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 267,535 | 266,027-269,043 | 0.73 | 2.11 | 3.93 | 1.02x | 0/499 (aborted due to deadline x250) | 4.8 |
| nginx | 261,309 | 258,984-263,635 | 0.58 | 2.39 | 4.59 | 1.00x | 0/465 (aborted due to deadline x248) | 4.9 |
| dusty-tuned | 247,740 | 239,728-255,753 | 0.87 | 1.75 | 3.73 | 0.95x | 0/503 (aborted due to deadline x250) | 4.9 |

### https-large-ka-c64: 1 MiB static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 4,391 | 4,386-4,397 | 14.18 | 23.16 | 31.39 | 1.07x | 0/128 (aborted due to deadline x64) | 5.4 |
| nginx | 4,102 | 4,102-4,103 | 14.58 | 24.18 | 32.85 | 1.00x | 0/128 (aborted due to deadline x64) | 5.4 |
| dusty-tuned | 3,002 | 2,995-3,009 | 19.58 | 33.08 | 48.03 | 0.73x | 0/128 (aborted due to deadline x64) | 5.3 |

### https-small-noka-c64: 612 B static file, new connection per request, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 9,766 | 9,643-9,890 | 5.43 | 13.03 | 22.90 | 0.97x | 0/0 | 5.6 |
| nginx | 10,052 | 9,993-10,111 | 5.54 | 12.06 | 19.18 | 1.00x | 0/0 | 5.7 |
| dusty-tuned | 9,715 | 9,540-9,889 | 6.18 | 8.76 | 13.01 | 0.97x | 0/0 | 5.6 |

## Handshake-heavy (HTTPS, keep-alive off)

### https-small-noka-c64: 612 B static file, new connection per request, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 9,766 | 9,643-9,890 | 5.43 | 13.03 | 22.90 | 0.97x | 0/0 | 5.6 |
| nginx | 10,052 | 9,993-10,111 | 5.54 | 12.06 | 19.18 | 1.00x | 0/0 | 5.7 |
| dusty-tuned | 9,715 | 9,540-9,889 | 6.18 | 8.76 | 13.01 | 0.97x | 0/0 | 5.6 |

## Summary (median RPS)

| scenario | zhttpd | nginx | dusty-tuned |
|---|---:|---:|---:|
| http-small-ka-c16 | 291,770 | 238,586 | 143,595 |
| http-small-ka-c64 | 341,479 | 288,812 | 200,262 |
| http-small-ka-c256 | 370,575 | 313,859 | 213,316 |
| http-small-ka-c1024 | 314,469 | 299,628 | 149,538 |
| http-medium-ka-c64 | 140,906 | 125,071 | 79,870 |
| http-large-ka-c64 | 11,513 | 11,506 | 6,955 |
| http-small-noka-c64 | 92,935 | 90,671 | 67,777 |
| http-baseline-ka-c256 | 406,732 | 389,233 | 408,779 |
| https-small-ka-c64 | 256,397 | 226,166 | 220,068 |
| https-small-ka-c256 | 267,535 | 261,309 | 247,740 |
| https-large-ka-c64 | 4,391 | 4,102 | 3,002 |
| https-small-noka-c64 | 9,766 | 10,052 | 9,715 |

# macOS (kqueue) — same plan, noisier host

Raw data: `bench/results/20261110-102246/` (oha JSON per run, runs.csv, load.log, nginx.conf).

```
date: Tue Nov 10 10:22:46 EET 2026
host: Darwin Ivans-MacBook-Pro.local 27.0.0 Darwin Kernel Version 27.0.0: Tue Aug 11 21:05:42 PDT 2026; root:xnu-13432.1.9~1/RELEASE_ARM64_T6031 arm64
cpus: 16
model: Apple M3 Max / 64 GiB
oha: oha 1.16.0
zhttpd: zhttpd version: zhttpd/0.1.0 built with Zig 0.17.1, event backend kqueue, TLS OpenSSL 
nginx: nginx version: nginx/1.30.6 built by clang 21.0.0 (clang-2100.4.1.1) built with OpenSSL 3.5.9 29 Sep 2026 TLS SNI support enabled configure arguments: --prefix=/Users/listepo/Grok/zig-http-server/tools/nginx --with-cc-opt='-O2 -I/Users/listepo/Grok/zig-http-server/deps/openssl-install/include' --with-ld-opt=-L/Users/listepo/Grok/zig-http-server/deps/openssl-install/lib --with-http_ssl_module --with-http_v2_module --with-threads --with-pcre=/Users/listepo/Grok/zig-http-server/deps/pcre2-10.49 --with-zlib=/Users/listepo/Grok/zig-http-server/deps/zlib-1.3.1 
leader: dusty-tuned (5646c1d2a4f4656073430ce55ed39a5c9c2e6749)
duration=10s warmup=2s keepalive-off=12000 requests reps=2 servers=[zhttpd nginx dusty-tuned]
```

RPS = median over repetitions of successful (2xx) requests per second; [min-max] across repetitions.
Latency = median of per-run percentiles (ms). `load` = median 1-min load average around the runs
(the Mac is shared; high load means noisy numbers). `vs nginx` compares median RPS.

## Caveats (this Mac run)

The host was busy and shared: 1-minute load average around samples ranged from about 7 to 35
(other Lima VMs, desktop apps, and unrelated Java/Zig jobs). That average **lags**, so a
number recorded at the start of nginx or zhttpd may still reflect the previous server.
ABBA + two repetitions shrink bias but do not remove it — look at the `[min-max]` columns
before treating a “vs nginx” ratio as a ranking. A quieter rerun (or the Linux VM, once
it has results) is the better comparison.

`aborted due to deadline` is oha closing keep-alive connections at the end of a timed
run, not a server failure. Keep-alive-off runs completed with 0 such errors.

## HTTP (plain)

### http-small-ka-c16: 612 B static file, keep-alive, 16 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 43,871 | 23,539-64,203 | 0.39 | 0.68 | 1.53 | 1.15x | 0/26 (aborted due to deadline x13) | 13.1 |
| nginx | 38,161 | 23,261-53,062 | 0.49 | 0.62 | 0.87 | 1.00x | 0/31 (aborted due to deadline x16) | 18.4 |
| dusty-tuned | 12,427 | 10,355-14,500 | 1.02 | 2.41 | 5.13 | 0.33x | 0/32 (aborted due to deadline x16) | 16.2 |

### http-small-ka-c64: 612 B static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 54,910 | 40,085-69,735 | 1.05 | 1.54 | 4.14 | 1.42x | 0/111 (aborted due to deadline x49) | 13.4 |
| nginx | 38,660 | 26,034-51,286 | 1.82 | 2.26 | 2.75 | 1.00x | 0/126 (aborted due to deadline x64) | 16.7 |
| dusty-tuned | 16,393 | 10,865-21,922 | 2.84 | 8.59 | 27.47 | 0.42x | 0/127 (aborted due to deadline x64) | 17.8 |

### http-small-ka-c256: 612 B static file, keep-alive, 256 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 50,930 | 34,469-67,392 | 5.47 | 7.26 | 15.74 | 1.22x | 0/474 (aborted due to deadline x220) | 14.4 |
| nginx | 41,762 | 28,813-54,710 | 6.99 | 8.76 | 10.90 | 1.00x | 0/508 (aborted due to deadline x253) | 15.2 |
| dusty-tuned | 10,010 | 2,345-17,676 | 38.28 | 146.86 | 324.02 | 0.24x | 0/509 (aborted due to deadline x254) | 20.7 |

### http-small-ka-c1024: 612 B static file, keep-alive, 1024 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 54,330 | 37,321-71,339 | 20.95 | 25.19 | 34.66 | 1.39x | 0/2134 (aborted due to deadline x1019; connection error x39) | 17.0 |
| nginx | 39,006 | 24,109-53,903 | 29.21 | 38.86 | 47.95 | 1.00x | 0/2101 (aborted due to deadline x1023; connection error x55) | 13.8 |
| dusty-tuned | 6,849 | 4,675-9,024 | 143.35 | 318.20 | 556.09 | 0.18x | 0/2787 (aborted due to deadline x1024; connection error x434) | 28.7 |

### http-medium-ka-c64: 64 KiB static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 25,776 | 18,787-32,766 | 2.71 | 3.26 | 3.76 | 0.88x | 0/128 (aborted due to deadline x64) | 18.3 |
| nginx | 29,412 | 26,529-32,296 | 2.05 | 3.01 | 3.59 | 1.00x | 0/127 (aborted due to deadline x63) | 12.9 |
| dusty-tuned | 8,804 | 4,336-13,271 | 6.88 | 19.88 | 44.83 | 0.30x | 0/128 (aborted due to deadline x64) | 35.2 |

### http-large-ka-c64: 1 MiB static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 3,763 | 2,746-4,780 | 17.65 | 23.36 | 27.68 | 1.00x | 0/128 (aborted due to deadline x64) | 17.0 |
| nginx | 3,747 | 2,895-4,599 | 16.90 | 24.94 | 29.61 | 1.00x | 0/128 (aborted due to deadline x64) | 12.2 |
| dusty-tuned | 968 | 797-1,140 | 61.82 | 92.93 | 158.46 | 0.26x | 0/128 (aborted due to deadline x64) | 34.8 |

### http-small-noka-c64: 612 B static file, new connection per request, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 8,249 | 6,790-9,708 | 7.94 | 8.58 | 12.89 | 0.74x | 0/0 | 16.1 |
| nginx | 11,091 | 7,391-14,792 | 6.19 | 7.68 | 10.70 | 1.00x | 0/0 | 11.9 |
| dusty-tuned | 6,641 | 3,362-9,920 | 10.23 | 22.51 | 47.24 | 0.60x | 0/0 | 35.1 |

### http-baseline-ka-c256: tiny dynamic answer (`return 200 "3"` / dusty handler), keep-alive, 256 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 58,204 | 44,851-71,558 | 4.23 | 6.16 | 7.49 | 1.16x | 0/510 (aborted due to deadline x255) | 11.2 |
| nginx | 49,985 | 29,737-70,232 | 6.27 | 7.32 | 9.46 | 1.00x | 0/509 (aborted due to deadline x254) | 8.2 |
| dusty-tuned | 64,727 | 63,447-66,006 | 3.90 | 4.20 | 4.90 | 1.29x | 0/510 (aborted due to deadline x254) | 22.5 |

## HTTPS (TLS 1.3)

### https-small-ka-c64: 612 B static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 50,666 | 38,322-63,010 | 1.30 | 1.58 | 1.98 | 1.01x | 0/109 (aborted due to deadline x48) | 11.2 |
| nginx | 50,118 | 37,268-62,967 | 1.32 | 1.67 | 2.10 | 1.00x | 0/126 (aborted due to deadline x63) | 8.0 |
| dusty-tuned | 16,644 | 15,869-17,418 | 2.74 | 7.57 | 18.69 | 0.33x | 0/128 (aborted due to deadline x64) | 22.8 |

### https-small-ka-c256: 612 B static file, keep-alive, 256 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 54,455 | 41,320-67,589 | 4.86 | 5.84 | 7.29 | 1.29x | 0/504 (aborted due to deadline x255) | 11.2 |
| nginx | 42,291 | 26,914-57,668 | 6.88 | 8.07 | 9.23 | 1.00x | 0/510 (aborted due to deadline x255) | 7.8 |
| dusty-tuned | 13,491 | 12,041-14,941 | 9.65 | 48.61 | 121.85 | 0.32x | 0/511 (aborted due to deadline x256) | 24.8 |

### https-large-ka-c64: 1 MiB static file, keep-alive, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 1,303 | 960-1,646 | 55.11 | 61.79 | 88.67 | 1.74x | 0/128 (aborted due to deadline x64) | 11.0 |
| nginx | 750 | 554-945 | 85.69 | 118.20 | 126.72 | 1.00x | 0/128 (aborted due to deadline x64) | 7.8 |
| dusty-tuned | 1,175 | 1,152-1,198 | 54.29 | 57.14 | 62.76 | 1.57x | 0/128 (aborted due to deadline x64) | 25.8 |

### https-small-noka-c64: 612 B static file, new connection per request, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 6,446 | 5,658-7,234 | 9.18 | 13.56 | 21.41 | 1.74x | 0/0 | 11.6 |
| nginx | 3,711 | 2,760-4,663 | 18.30 | 19.53 | 25.28 | 1.00x | 0/0 | 7.9 |
| dusty-tuned | 8,011 | 7,501-8,520 | 7.37 | 10.02 | 22.85 | 2.16x | 0/0 | 25.5 |

## Handshake-heavy (HTTPS, keep-alive off)

### https-small-noka-c64: 612 B static file, new connection per request, 64 connections

| server | RPS (median) | [min-max] | p50 ms | p90 ms | p99 ms | vs nginx | non-2xx/errors | load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zhttpd | 6,446 | 5,658-7,234 | 9.18 | 13.56 | 21.41 | 1.74x | 0/0 | 11.6 |
| nginx | 3,711 | 2,760-4,663 | 18.30 | 19.53 | 25.28 | 1.00x | 0/0 | 7.9 |
| dusty-tuned | 8,011 | 7,501-8,520 | 7.37 | 10.02 | 22.85 | 2.16x | 0/0 | 25.5 |

## Summary (median RPS)

| scenario | zhttpd | nginx | dusty-tuned |
|---|---:|---:|---:|
| http-small-ka-c16 | 43,871 | 38,161 | 12,427 |
| http-small-ka-c64 | 54,910 | 38,660 | 16,393 |
| http-small-ka-c256 | 50,930 | 41,762 | 10,010 |
| http-small-ka-c1024 | 54,330 | 39,006 | 6,849 |
| http-medium-ka-c64 | 25,776 | 29,412 | 8,804 |
| http-large-ka-c64 | 3,763 | 3,747 | 968 |
| http-small-noka-c64 | 8,249 | 11,091 | 6,641 |
| http-baseline-ka-c256 | 58,204 | 49,985 | 64,727 |
| https-small-ka-c64 | 50,666 | 50,118 | 16,644 |
| https-small-ka-c256 | 54,455 | 42,291 | 13,491 |
| https-large-ka-c64 | 1,303 | 750 | 1,175 |
| https-small-noka-c64 | 6,446 | 3,711 | 8,011 |

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
