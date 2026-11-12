# HTTP/3 and large-response throughput follow-up — 2026-11-12

Results below apply to the measured runtime commit `e96eb9b`, based on main
`94f5e3d`. The suite-wide target requires at least 1.5× nginx successful RPS
and median sample p99 no worse than both nginx and the saved main baseline
in every scenario. Functional checks alone do not establish that target.

The primary matrix meets the full target only for 1 MiB HTTP/3 responses.
The suite-wide target remains unmet. Short HTTP/2 has a measured 4.9% p99
increase against the main baseline in that matrix; additional fixed-count
controls are reported separately below.

## Changes and bounds

- HTTP/3 file responses larger than the initial 32 KiB output buffer can grow
  that buffer to 131,000 bytes. Growth is lazy, preserves buffered bytes, and
  is forbidden while the codec retains a vector. Allocation failure keeps the
  smaller working buffer. Short responses retain their original allocation.
- The shared stream cache still holds at most 32 entries, with a new
  1,048,000-byte output budget. Enlarged entries reduce the count retained;
  they do not increase that idle output budget. Active large transfers can
  use approximately 96 KiB more per stream. Response header limits are unchanged.
- HTTP/2 large responses batch encrypted TLS records through a 96 KiB output
  BIO. OpenSSL continues to own TLS records, write retries and KeyUpdate.
  The buffer is flushed after each bounded turn and detached when idle.
  The pass budget is selected once per turn: established large-response buffers
  allow 64 passes; small-response turns retain four. A newly created large
  buffer receives the larger budget on the next active turn. Buffer flushing
  is kept outside the short-response path.
  Partial flush progress schedules another turn without an unnecessary wait.
- Once a complete request has buffered response bytes, the codec avoids
  repeatedly calling its application writer until those bytes are consumed.
  Pending request input and incomplete uploads continue to drive the handler.

- HTTP/3 callbacks reuse the stream pointer associated at header start instead
  of repeatedly scanning the connection list. Teardown clears the association
  before recycling a stream, including transport failure while nghttp3 still
  retains its stream. A regression test exercises that exact reuse boundary.

- The internal request bridge copies bounded, validated fields directly instead
  of parsing a printf format for every request. Byte-exact fixed-length/chunked
  cases and the exact header-limit boundary are checked by native tests.

No new TLS or QUIC backend, kTLS, congestion-control bypass or dependency patch
is included. Both servers use OpenSSL 3.5.9; zhttpd retains the previously merged
QUIC stream-retirement patch. The baseline also includes the HTTP/3 partial-write
fix, the merged HTTP/1 HTTPS work and the native HTTP application/policy work. The optional AWS-LC backend is not used
in these HTTP/2 and HTTP/3 comparisons.

## Verification

The integrated runtime passes all 76 unit tests and the protocol suite on
Linux Debug and ReleaseFast, and macOS ReleaseFast. Linux and macOS ReleaseFast
also pass all 193 HTTP application/policy assertions.
The pre-integration candidate passed all 66 unit tests and the full protocol
suite on Linux Debug and ReleaseFast, and macOS ReleaseFast. macOS Debug also
passed its protocol checks before the final main integration.

All 12 jobs of [CI run 43226386999](https://github.com/pyrlyn/zhttpd/actions/runs/43226386999)
passed for the measured runtime, including Linux/macOS build, unit and Raft
checks, AWS-LC TLS and every protocol E2E group.

The native HTTP/2 client changes TLS 1.3 keys in both modes during a 1 MiB body,
with a 128 KiB stream window keeping the response active. It verifies every byte
and a subsequent response, before and after server reload. Existing wire tests
cover cancellation under output backpressure, uploads, proxies, HEAD, vhosts,
limits, loss, reordering, late duplicate UDP packets, reload and shutdown.

Codec tests verify that growth preserves data, retained vectors cannot move,
response header limits do not expand, and enlarged buffers obey the idle-cache
budget. Their assertions remain enabled in ReleaseFast. Linux datagram tests
also retain coverage for GSO boundaries, source addresses, IPv6/failure fallback
and bounded receive batches.

## Method and evidence

Linux aarch64, kernel 6.8.0-134, Zig 0.17.1 ReleaseFast; OpenSSL 3.5.9,
nghttp2 1.71.0, nghttp3 1.19.0; nginx 1.30.6. The existing patched oha 1.16.0
waits for response completion. One server worker is pinned to vCPU 0 and the
load client uses vCPUs 1–7. All servers use the same files, certificate and
configuration. kTLS is disabled. The recorded configuration has no explicit
`quic_gso` directive; zhttpd uses its previously merged automatic UDP batching
adapter when supported. Results apply to this exact nginx configuration;
alternative nginx tuning is outside this matrix.

Each sample measures 10 seconds after a 2-second warmup. Four repetitions
alternate server order. Bodies are 612 bytes or 1 MiB; each connection allows
16 concurrent streams. RPS is the median successful-response count divided by
elapsed time; p99 is the median of the individual sample p99 values.

Raw samples, CPU/memory sidecars, configuration, binary/source hashes,
validation logs and strict-gate output are stored in
[evidence/2026-11-12-h3-throughput](evidence/2026-11-12-h3-throughput/).
Measurements are loopback results on a shared physical host, not a production
network or a claim about performance under packet loss. VM use was coordinated
sequentially; the process timeline records the measurement interval. The
physical macOS host also had active applications and another running VM.
The late HTTP/2 repetitions showed a throughput dip across all three servers;
all samples remain included. A contemporaneous aggregated host-process snapshot is
provided, but it is not a full host timeline or proof of the cause.

## Results

All 60 measured samples completed without HTTP or load-generator errors.

| Scenario | main RPS | nginx RPS | candidate RPS | vs nginx | 1.5× + p99 gate |
|---|---:|---:|---:|---:|---|
| H3 1 MiB, c4 | 829.1 | 602.0 | 1,003.0 | +66.6% | PASS |
| H3 612 B, c16 | 166,216.0 | 251,512.8 | 172,634.5 | -31.4% | FAIL |
| H3 612 B, c4 | 162,416.9 | 243,994.9 | 168,113.3 | -31.1% | FAIL |
| H2 1 MiB, c4 | 1,697.0 | 1,962.2 | 2,320.9 | +18.3% | FAIL |
| H2 612 B, c4 | 348,412.0 | 203,802.4 | 352,357.4 | +72.9% | FAIL |

Median sample p99, milliseconds:

| Scenario | main | nginx | candidate | vs main | vs nginx |
|---|---:|---:|---:|---:|---:|
| H3 1 MiB, c4 | 80.3938 | 158.8707 | 68.4492 | -14.9% | -56.9% |
| H3 612 B, c16 | 2.4741 | 1.3892 | 2.3935 | -3.3% | +72.3% |
| H3 612 B, c4 | 0.5254 | 0.3492 | 0.5153 | -1.9% | +47.6% |
| H2 1 MiB, c4 | 42.2032 | 44.6185 | 30.3221 | -28.2% | -32.0% |
| H2 612 B, c4 | 0.2405 | 0.4299 | 0.2522 | +4.9% | -41.3% |

Median of per-sample peak process-tree PSS, MiB (active workload):

| Scenario | main | nginx | candidate |
|---|---:|---:|---:|
| H3 1 MiB, c4 | 17.71 | 31.87 | 31.32 |
| H3 612 B, c16 | 14.23 | 23.45 | 14.20 |
| H3 612 B, c4 | 9.89 | 16.42 | 9.91 |
| H2 1 MiB, c4 | 12.72 | 15.08 | 13.00 |
| H2 612 B, c4 | 8.64 | 15.04 | 8.63 |

The suite-wide target remains unmet. Short HTTP/3 responses remain slower than nginx, with higher p99; large HTTP/2 responses also miss the 1.5× throughput threshold. A passing large-response case does not establish general HTTP/3 superiority. These are observed medians from four samples, not a guarantee for other machines or workloads.

Larger active HTTP/3 file buffers increase peak memory during large transfers. The unchanged idle output-cache byte budget is not a promise of unchanged total active-process memory.

The earlier full series is preserved under `prior-1f029c9/`, including its 0.3% small-H3 c4 p99 regression against main `44b0fef`. The intermediate `prior-f432058/` series used updated main `94f5e3d` but exposed a 2.4% small-H2 p99 regression. The subsequent `prior-2113509/` H2 series still measured a 1.6% small-response p99 increase after removing printf parsing. The final runtime additionally isolates BIO work and selects the loop budget once per turn. All earlier results remain available.

## Extended short HTTP/2 latency check

After the primary matrix, 12 additional 10-second repetitions per server were
declared in advance and run with the same binaries, affinity and warmup.
Only main and the candidate were compared. Every sample completed without errors.
The pooled result includes the original four samples and all 12 additional samples.

| Series | Samples/server | main p99, ms | candidate p99, ms | vs main | candidate RPS vs main |
|---|---:|---:|---:|---:|---:|
| primary | 4 | 0.240509 | 0.252218 | +4.87% | +1.13% |
| additional | 12 | 0.241329 | 0.238578 | -1.14% | +2.03% |
| pooled | 16 | 0.241045 | 0.239518 | -0.63% | +2.02% |

The additional and pooled median p99 values are below baseline. The primary
matrix and its failing gate remain unchanged; latency variability in that
series remains a limitation. This control does not establish the suite-wide
1.5× nginx target. Raw samples and their individual values are in
[h2-small-control](evidence/2026-11-12-h3-throughput/h2-small-control/).

## Reproduction

Build baseline `94f5e3d` and candidate `e96eb9b` with Zig 0.17.1 and identical
static dependency archives, using `-Doptimize=ReleaseFast -Dtls=true -Dhttp=true`.
The exact archive and executable hashes are in the evidence environment files.
Use the completion-draining oha patch in `bench/oha-http3-drain.patch`. Set
`ZHTTPD_BASELINE`, `ZHTTPD`, `NGINX` and `OHA` to the corresponding binaries, then
run from the candidate checkout:

```sh
export DURATION=10 WARMUP=2 REPS=4 WORKERS=1 STREAMS=16
export SERVER_CPUS=0 LOAD_CPUS=1-7 PORT=29880 TLSPORT=29443
export SERVERS="zhttpd-baseline nginx zhttpd"
HTTP_VERSION=2 SCENARIO_FILTER="small-ka-c4|large" bash bench/run.sh
HTTP_VERSION=3 bash bench/run.sh
python3 bench/check-target.py bench/results/<h3-stamp> 1.5
python3 bench/check-target.py bench/results/<h2-stamp> 1.5
```

The gate exits nonzero when any scenario misses throughput or p99 requirements.

## Rejected diagnostic variants

Short, two-repetition screens informed implementation choices; they are not
acceptance evidence. Removing the second QUIC drive in an event-loop turn and
raising OpenSSL's transmit batch from 32 to 128 packets did not demonstrate a
useful gain. Neither is included. An ngtcp2 prototype improved large transfers
but was slower for short responses, so it is not included either.

An unconditional 128 KiB stream buffer improved large HTTP/3 throughput but
worsened small-response p99 in its screen. The final implementation grows only
for large files and caps the idle cache by bytes. The 96 KiB HTTP/2 ciphertext
buffer with four passes was also slower than the final bounded batching path.

A diagnostic use of nghttp2 stream userdata did not demonstrate a convincing
throughput gain and was discarded. The final small-response change removes
printf parsing from the common request bridge instead.
