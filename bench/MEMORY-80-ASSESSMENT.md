# 80% memory reduction target — not met

The requested budget is **zhttpd <= 20% of nginx**, for both summed RSS and
PSS of the master plus worker. The protocol features, request limits, worker
count and existing throughput/p99 regression budgets remain unchanged.

The previous optimization passes its 10% target, but **fails the 80% target in
all 13 scenarios**. Its accepted measurements remain in
[MEMORY-OPTIMIZATION.md](MEMORY-OPTIMIZATION.md). Re-evaluation with
`bench/check-memory.py --memory-ratio .2` is saved in
[evidence/2026-11-12-memory80](evidence/2026-11-12-memory80).

## Remaining footprint

A diagnostic run on the same Linux aarch64 VM used the accepted shared
HTTP/HTTPS configuration, one worker and the same certificates/content.
It captured `/proc/PID/smaps` for each process: at startup, after 64 HTTP
connections, and after another 64 TLS connections. Connections remained open.
These are diagnostic snapshots, not throughput benchmark medians.

| State | nginx RSS / PSS, KiB | Previous optimized RSS / PSS, KiB | ReleaseSmall RSS / PSS, KiB | 80% target RSS / PSS, KiB |
|---|---:|---:|---:|---:|
| Startup | 18428 / 14427 | 10552 / 6435 | 10020 / 5899 | 3686 / 2885 |
| 64 HTTP connections | 18944 / 14502 | 10980 / 6563 | 10256 / 5963 | 3789 / 2900 |
| 64 HTTP + 64 TLS connections | 25844 / 18430 | 17272 / 10442 | 16588 / 9754 | 5169 / 3686 |

ReleaseSmall was built from the same runtime source and patched OpenSSL archive,
with only the Zig optimization mode changed. Its HTTP snapshot saves 6.6% RSS
and 9.1% PSS against the previous optimized binary, far short of the new target.

For that snapshot, mappings of the ReleaseSmall binary alone consume **5512 KiB
RSS / 4320 KiB PSS** across master and worker. That already exceeds the entire
80% budget of **3789 / 2900 KiB**, before libc, heap, stack or request buffers.
The master binary mapping alone is 4324 KiB RSS. This identifies why shrinking
connection pools further cannot meet the target with this resident process
layout. It is not a universal impossibility claim: a different supervisor,
TLS/QUIC implementation or code layout could change the fixed footprint.

The TLS snapshot adds about 3.2 MiB of worker heap RSS. TLS already enables
`SSL_MODE_RELEASE_BUFFERS`; the previous change also frees request storage and
bounds the connection/request pools. Merely enabling that OpenSSL mode again or
reducing pool caps cannot remove the measured fixed cost.

## Experiment and regression

ReleaseSmall passed the protocol suite (HTTP/1.1, HTTP/2, HTTP/3, uploads,
static/HEAD, proxy, limits, ACL, vhosts, connection reuse, reload/shutdown and
QUIC packet loss/reordering/duplicates) and request-storage regression.

The performance experiment compares ReleaseSmall with the previous optimized
ReleaseFast binary, and nginx, using four repetitions of the HTTP small,
HTTPS small and HTTPS 1 MiB scenarios. Its result is recorded below.

| Scenario | RSS / nginx | PSS / nginx | RPS / previous optimized | p99 / previous optimized |
|---|---:|---:|---:|---:|
| `http-small-ka-c64` | 0.542 | 0.412 | 0.620 | 1.453 |
| `https-large-ka-c64` | 0.651 | 0.541 | 0.489 | 1.932 |
| `https-small-ka-c64` | 0.652 | 0.542 | 0.617 | 1.505 |

All three scenarios fail the 80% memory target and the throughput/p99
regression budgets. ReleaseSmall is **not adopted**; ReleaseFast and the
previous proven optimization remain unchanged.

[Raw measurements and gate output](evidence/2026-11-12-memory80/release-small/MEMORY-80-GATE.txt).

## Scope of the conclusion

The 80% acceptance target remains open. Meeting it needs a separately designed
reduction of the fixed process/TLS footprint, followed by the full protocol,
configuration, reload and performance regression suites.
