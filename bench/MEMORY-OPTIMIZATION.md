# Memory comparison with nginx

The acceptance budget is **at least 10% below nginx** for both the sum of RSS
and the sum of PSS across the master and workers. Each reported value is the
median of the per-run sampled peaks. Linux `/proc/PID/smaps_rollup` is sampled
at 50 ms intervals during the same oha load used for throughput measurements.
PSS accounts for shared pages proportionally; summed RSS counts them in each
process. This is process resident memory; it excludes kernel socket buffers and
filesystem cache not mapped into those processes. A sampled peak can miss a transient shorter than 50 ms.

Each server restarts once per repetition, with scenarios executed in manifest
order. Later scenarios therefore include memory retained after earlier traffic.
In particular, the HTTP/1.x HTTPS baseline follows the 1024-connection HTTP
scenario; its footprint is not a fresh-process HTTPS measurement. All three
servers receive the same sequence, with reversed server order on even repeats.

The gate also requires all scenarios and repetitions, identical process counts,
zero HTTP/client errors, and no memory increase against the saved baseline.
Its performance regression budgets are no more than 5% lower median successful
RPS and no more than 10% higher median p99 against that baseline. These noise
budgets are explicit; passing them does not assert identical latency.

## Measured result

All 13 listed keep-alive scenarios pass the memory and performance regression
gate on Linux aarch64. Four repetitions per server; HTTP/1.1 uses 5 s
samples with 1 s warmup, HTTP/2 and HTTP/3 use 10 s with 2 s warmup.
Baseline commit: `12ce969d1653258455c2be756c97a2f6148d0b7b`.

RSS is **13.7–42.4% lower** than nginx; PSS is **17.8–55.0% lower**.
The largest throughput reduction against baseline is 0.8%; the largest p99
increase is 1.8%. Both remain inside the predefined regression budgets.

| Scenario | RSS KiB: zhttpd / nginx | PSS KiB: zhttpd / nginx | RPS / baseline | p99 / baseline |
|---|---:|---:|---:|---:|
| `http-small-ka-c64` | 10916 / 18948 | 6498 / 14452 | 1.012 | 1.008 |
| `http-small-ka-c256` | 11040 / 19040 | 6622 / 14552 | 1.319 | 1.018 |
| `http-small-ka-c1024` | 11508 / 19436 | 7090 / 14948 | 1.104 | 0.923 |
| `http-large-ka-c64` | 11508 / 19306 | 7090 / 14818 | 0.993 | 1.007 |
| `https-small-ka-c64` | 17730 / 26210 | 10866 / 18764 | 1.022 | 0.966 |
| `https-small-ka-c256` | 28664 / 37030 | 21800 / 29578 | 1.058 | 0.942 |
| `https-large-ka-c64` | 28290 / 36982 | 21426 / 29530 | 0.992 | 0.985 |
| `h2-small-ka-c4-p16` | 15262 / 22804 | 8196 / 15364 | 1.008 | 0.976 |
| `h2-small-ka-c16-p16` | 16576 / 23488 | 9516 / 16052 | 1.043 | 0.880 |
| `h2-large-ka-c4-p16` | 20334 / 23574 | 13272 / 16140 | 1.003 | 0.996 |
| `h3-small-ka-c4-p16` | 16594 / 24188 | 9410 / 16692 | 1.294 | 0.600 |
| `h3-small-ka-c16-p16` | 21182 / 29504 | 14009 / 22008 | 1.426 | 0.600 |
| `h3-large-ka-c4-p16` | 24766 / 40146 | 17580 / 32645 | 1.013 | 0.988 |

The table reports medians of sampled per-run peaks; all HTTP responses were
successful and client error counts were zero. The comparison covers these
workloads and one worker per server; it does not establish a universal
memory bound for other configurations, worker counts or fresh-connection loads.

Earlier HTTP/1.1 and HTTP/2 measurements overlapped a separate task on the
same VM and were excluded. The accepted series used exclusive VM access.
Raw samples, binary hashes, configurations and gate output:
[HTTP/1.1](evidence/2026-11-12-memory/h1/MEMORY-GATE.txt),
[HTTP/2](evidence/2026-11-12-memory/h2/MEMORY-GATE.txt),
[HTTP/3](evidence/2026-11-12-memory/h3/MEMORY-GATE.txt).

## Implementation

- Request buffers, parser state, routing context and upstream state are borrowed
  from a worker pool. They are returned after the response and access log finish,
  when no pipelined bytes remain, or on connection close. Incomplete headers,
  bodies, blocked responses and WebSocket sessions retain their storage.
- Each worker retains at most 32 request-storage blocks and 64 closed connection
  records. Excess request blocks are unmapped; request body allocations are
  freed when their storage is released. Idle connections keep transport state.
- The file-cache bucket directory is allocated at startup; each four-entry
  bucket is allocated only on first insertion. Lookup failure to allocate falls
  back to an uncached descriptor. Capacity, validation, expiry and request limits
  are unchanged.
- The pinned OpenSSL 3.5.9 build carries a small QUIC stream-map patch. A deleted
  stream with a fully consumed FIN/reset can be reclaimed once its send side
  has been acknowledged. Previously, the receive-drained condition was always
  false, retaining completed stream records until connection teardown. Unread
  input, unacknowledged output and application-owned streams remain protected.
  `scripts/build-openssl.sh` invalidates unpatched cached installs and checks the
  installed archive with `tests/quic-stream-gc.c`. Manual builds using an external
  OpenSSL prefix must supply this fix too; the Zig changes alone do not fix QUIC
  retention inside an unpatched OpenSSL library.

## Reproduction

Build the baseline and candidate with the same Zig version, ReleaseFast options
and dependency versions. The candidate uses the QUIC GC patch described above;
the saved baseline uses the original OpenSSL archive. Use the same nginx
configuration and load tool for all three binaries. On Linux, run from the candidate checkout:

```bash
ZHTTPD=/absolute/candidate/zhttpd \
ZHTTPD_BASELINE=/absolute/baseline/zhttpd \
NGINX=/absolute/nginx OHA=/absolute/oha \
SERVERS='zhttpd-baseline nginx zhttpd' WORKERS=1 \
SERVER_CPUS=0 LOAD_CPUS=1-7 DURATION=5 WARMUP=1 REPS=4 \
SCENARIO_FILTER='^(http-small-ka-c(64|256|1024)|http-large-ka-c64|https-small-ka-c(64|256)|https-large-ka-c64)[|]' \
bash bench/run.sh
python3 bench/check-memory.py bench/results/STAMP
```

Use `HTTP_VERSION=2` or `HTTP_VERSION=3`, `DURATION=10 WARMUP=2`, and no
`SCENARIO_FILTER` for the modern protocol suites. HTTP/3 requires the patched oha described in `PLAN.md`.
The memory gate requires a saved baseline and at least two repetitions; it fails
on missing, nonfinite or incomplete memory measurements and unsafe sample paths.
`tests/bench-memory.py` tests the gate. `tests/request-storage.py` covers storage
reuse across concurrent partial requests, pipelines, uploads and backpressure.
Both are part of `zig build test-e2e`.

## Regression coverage

- Linux: all 61 Zig unit tests passed with TLS/HTTP enabled. ReleaseSafe wire
  tests ran with `MALLOC_PERTURB_=165`: request-storage reuse, HTTP/1.1, HTTP/2,
  HTTP/3, uploads, HEAD, static files, proxy, limits, ACL, vhosts, reuseport,
  reload/shutdown, and QUIC packet loss/reordering/late duplicates.
- TLS 1.2/1.3 tests cover fragmented/coalesced records, pipelines, body draining,
  range/HEAD, backpressure, idle buffers, file freshness, TCP half-close and
  TLS 1.3 KeyUpdate. Configuration adapters, automatic reload, load balancing,
  logging, FastCGI/WSGI and WebSocket contracts also passed.
- macOS: unit tests (50 executed plus cached groups), a ReleaseSafe TLS/HTTP
  build, the full wire protocol suite including packet faults, and request-storage
  tests passed. The real `scripts/build-openssl.sh` build, installed-archive test
  and subsequent cache hit passed.
- The C stream-map regression fails against original OpenSSL and passes against
  the patched archive. It checks application ownership, unread receive state,
  unacknowledged send state, collection after the final ACK, consumed FIN/reset,
  and the existing acknowledged STOP_SENDING path.
- Both benchmark acceptance scripts' negative fixtures passed. Shell syntax,
  Python syntax, Zig formatting and `git diff --check` passed.

Validation logs are kept alongside the raw benchmark evidence in
[`evidence/2026-11-12-memory`](evidence/2026-11-12-memory/README.md).
