# HTTP/TLS performance verification — 2026-11-11

## Scope and implementation

This integrates the performance work onto `main` at
`ccf520de11eb3115b8f1d7280e1bbbd641adcc65`, including the existing HTTP/2,
HTTP/3, reload, load balancing and Raft integration. The runtime changes are
committed as `7b48a61`. Later integration of CI and documentation does not alter these measured sources. Earlier measurements of
`68b7f82` or intermediate candidates are not measurements of this version.

- Reset request metadata without copying unused header slots; keep frequently
  accessed request/connection fields ahead of large buffers.
- Borrow already normalized request paths. Complex paths still use the existing
  decoder; the request head remains intact while reading the body.
- Cache Last-Modified date formatting by the actual file timestamp. File content
  and metadata validation still follow the configured open-file cache rules.
- Enable OpenSSL read-ahead. On Linux, track encrypted socket read readiness
  after the first persistent HTTP/1 response to avoid redundant EAGAIN reads.
  Buffered records, EOF and SSL_read WANT_WRITE retries remain distinct.
- Queue continuations after responses so other connections get a turn, including
  when pipelined bytes are already buffered and no new OS edge will arrive.
- Start TLS handshakes from readiness events instead of inside multi_accept.
  Remove queued connections before returning them to the connection pool.

The BIO callback uses the exact OpenSSL C ABI, including an `int` result
argument. The short-read rule applies to Linux stream sockets and observes
ciphertext reads, not SSL_read's plaintext count. See
[OpenSSL BIO callbacks](https://docs.openssl.org/3.5/man3/BIO_set_callback/),
[read-ahead](https://docs.openssl.org/3.5/man3/SSL_CTX_set_read_ahead/), and
[epoll readiness and fairness](https://man7.org/linux/man-pages/man7/epoll.7.html).
HTTP/2 and HTTP/3 retain their existing transport scheduling.

Experimental kTLS/SSL_sendfile changes are excluded. A separate experiment
failed TLS 1.3 KeyUpdate with both zhttpd and nginx on the same OpenSSL/kernel;
its isolated throughput improvement is not an accepted result.

## Measurement method

The baseline is the unmodified main commit above, not an earlier optimized
candidate. Baseline and candidate are built with Zig 0.17.1, ReleaseFast and
`-Dtls=true` (HTTP/2 and HTTP/3 codecs disabled for this HTTP/1.1 benchmark).
Full-feature builds are verified separately on macOS and Linux.

The dedicated Lima `zhttpd-bench` VM runs Linux 6.8.0-134 aarch64 with 8 vCPUs
and 4 GiB RAM on an Apple M3 Max. Four server workers use CPUs 0–3; oha uses
CPUs 4–7. nginx 1.30.6, baseline and candidate use the same OpenSSL 3.5.9
installation. Although that library supports kTLS, neither server enables it
in this comparison. oha is version 1.16.0.

All three servers load the same rendered `bench/nginx.conf.in`: TLS 1.3, the
same certificate, static files, keep-alive limits, file-cache settings and
access logging disabled. Identical configuration text does not make the
implementations identical: zhttpd's TLS session cache is per worker, while
nginx uses a shared cache; zhttpd does not implement tcp_nopush.

There are four alternating-order repetitions per scenario. Keep-alive samples
run for 10 seconds after a 2-second warmup. Fresh-connection samples use 12,000
requests at concurrency 64. `oha -w -t 10s` finishes outstanding requests and
applies a timeout. RPS counts successful 2xx responses; p99 is the median of
individual sample p99 values. Host/VM scheduling can still introduce noise.
These measurements do not estimate capacity on dedicated production hardware
or establish performance for HTTP/2, HTTP/3, proxies or Raft workloads.

## Results

All **48 samples** completed without HTTP or load-generator errors. Median p99
improved against both nginx and the saved main baseline in every scenario.
The **1.5x throughput target is not met** in any scenario; the target check exits
with status 1 for both series. These are observed results on this VM, not a
claim of universal performance superiority.

| Workload | Main baseline RPS | Optimized RPS | nginx RPS | Gain over main | Gain over nginx |
|---|---:|---:|---:|---:|---:|
| 612 B, keep-alive, c64 | 673,036 | 739,480 | 561,093 | +9.9% | +31.8% |
| 612 B, keep-alive, c256 | 662,812 | 788,236 | 577,264 | +18.9% | +36.5% |
| 1 MiB, keep-alive, c64 | 9,053 | 9,153 | 8,368 | +1.1% | +9.4% |
| 612 B, new connection, c64 | 20,217 | 21,215 | 20,887 | +4.9% | +1.6% |

| Workload | Main baseline p99 (ms) | Optimized p99 (ms) | nginx p99 (ms) |
|---|---:|---:|---:|
| 612 B, keep-alive, c64 | 0.157 | 0.143 | 0.195 |
| 612 B, keep-alive, c256 | 0.537 | 0.481 | 0.620 |
| 1 MiB, keep-alive, c64 | 10.279 | 9.336 | 10.008 |
| 612 B, new connection, c64 | 9.719 | 8.710 | 9.392 |

The 1.1% large-file gain over main is smaller than the observed run-to-run
spread; do not interpret it as an established throughput improvement. Fresh
connections are close to nginx throughput parity. Small-response throughput
improved by 9.9–18.9% over main in these samples.

Committed evidence includes every oha JSON sample, run order, environment,
configuration, binary hashes and target-check output:

- [Keep-alive report and ranges](evidence/2026-11-11/keepalive/RESULTS.md)
  ([target check](evidence/2026-11-11/keepalive/target-check.txt)).
- [New-connection report and ranges](evidence/2026-11-11/new-connections/RESULTS.md)
  ([target check](evidence/2026-11-11/new-connections/target-check.txt)).
- [Measured source manifest](evidence/2026-11-11/source-manifest.json) and
  [unrounded aggregate metrics](evidence/2026-11-11/metrics.json).

The VM was temporarily expanded from four to eight vCPUs for CPU isolation;
its stopped/four-vCPU state is restored after measurement.

## Reproduction

Build the saved main baseline and candidate in separate directories against
the same OpenSSL installation, preserving the baseline binary. Run from the
candidate checkout on the isolated Linux VM:

```bash
export ZHTTPD_BASELINE=/absolute/baseline/zig-out/bin/zhttpd
export ZHTTPD=/absolute/candidate/zig-out/bin/zhttpd
export NGINX=/absolute/nginx/sbin/nginx
export OHA=/absolute/oha
export OPENSSL_BIN=/absolute/openssl/bin/openssl
export WORKERS=4 SERVER_CPUS=0-3 LOAD_CPUS=4-7
export SERVERS="zhttpd-baseline nginx zhttpd"
DURATION=10 WARMUP=2 REPS=4 SCENARIO_FILTER='^https-.*-ka-' bash bench/run.sh
REPS=4 NOKA_N=12000 SCENARIO_FILTER='^https-small-noka-' bash bench/run.sh
python3 bench/check-target.py bench/results/STAMP 1.5
```

The 1.5x gate requires every scenario to exceed nginx by at least 50%, no
HTTP/client errors or missing samples, and p99 no higher than either nginx or
the saved baseline. A functional test pass does not imply a performance-target
pass. `tests/bench-target.py` checks these rejection conditions.

## Functional verification

- macOS unit tests without TLS and with TLS + HTTP/2/3 enabled; Linux unit
  tests with TLS and with the complete HTTP codec build.
- Final macOS and Linux binaries pass `tests/protocols.py`: HTTP/1.1, HTTP/2,
  HTTP/3, multiplexing, uploads, HEAD/static files, proxying, limits, ACLs,
  virtual hosts, reuse, reload and shutdown.
- Final binaries pass `tests/tls-io.py`: TLS 1.2/1.3 fragmented/coalesced records,
  600 pipelined requests, body draining, HEAD/ranges, slow readers, idle partial
  records, Last-Modified/file freshness, half-close and both KeyUpdate modes.
- Parser metadata reset and continuation-queue removal/reuse have unit coverage.
- Benchmark-gate tests, Zig formatting and shell syntax checks pass. TLS I/O
  and benchmark-gate tests are now included in `zig build test-e2e`.
- The full macOS `test-e2e` run passed: configuration adapters, error pages,
  automatic config/TLS/key/DNS-env reload, load balancing, logs, gateways,
  real-lego ACME issuance/SNI/manual and automatic reload, and WebSockets.
  Transport checks above were repeated after the final handshake scheduling
  change. Full codec builds were tested separately from benchmark binaries.
