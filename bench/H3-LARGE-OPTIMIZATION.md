# HTTP/3 and large-response optimization — 2026-11-12

The **suite-wide target is not achieved**. For 1 MiB HTTP/3 responses the
candidate reaches **1.353× nginx RPS (+35.3%)**, with **57.2% lower p99**.
Small HTTP/3 responses improve against the saved main but remain slower than
nginx, with higher p99. This does not justify a general “50% faster” claim.
The performance gate remains failing; the branch is not merged into main.

Acceptance requires at least **1.5× nginx successful RPS**, with median sample
p99 no worse than both nginx and the saved main baseline, in every scenario.
An isolated improvement in the large-response case does not satisfy that
suite-wide requirement.

## Changes

- Linux sends compatible IPv4 QUIC datagrams with UDP segmentation offload.
  Datagram boundaries, peer and source addresses are preserved; unsupported
  sockets and IPv6 use the ordinary OpenSSL datagram BIO.
- Linux receives at most eight datagrams per syscall without reading beyond
  the current event-loop budget. Full-size UDP buffers are shared by listeners
  on the worker thread, allocated lazily and released with the last listener.
- The event loop uses OpenSSL's next QUIC deadline instead of sleeping a fixed
  5 ms. Whole-millisecond waits round down; sub-millisecond deadlines poll
  until serviced. The accept path checks the incoming queue before calling
  OpenSSL, avoiding redundant reactor ticks on an empty queue.
- Small HTTP/3 frame fragments share a stream write. FIN is attached to the
  final payload; an empty FIN still uses the explicit conclude operation.
- The pinned OpenSSL build collects application-released QUIC streams whose
  input is fully consumed and whose output is acknowledged. Unread input and
  data awaiting acknowledgement remain live. The patch and its regression
  test are included in dependency-cache keys and the local build stamp.

## Validation

The final runtime candidate `4676feb` passed 57 unit tests on Linux and macOS
and the full wire-protocol suite on both, using the patched OpenSSL archive. Linux datagram adapter tests
cover mixed peers, source addresses, packet boundaries, short tails, GSO syscall
failure, IPv6 fallback and partial receive budgets. The protocol suite checks
large bodies with small flow-control windows and deterministic packet loss
before and after reload. A relay additionally exercises reordering and late
UDP duplicates for the stream-retirement patch.

The stream-retirement test checks the actual installed OpenSSL archive,
including retention before the final outgoing ACK. The original library is
used as a negative control and fails on the expected stream-retention cases.

## Measurement method

The saved baseline is main commit `12ce969d1653258455c2be756c97a2f6148d0b7b`.
Linux aarch64, Zig 0.17.1 ReleaseFast, OpenSSL 3.5.9, nghttp2 1.71.0,
nghttp3 1.19.0; nginx 1.30.6. The candidate uses the included OpenSSL stream
retirement patch; the saved baseline and nginx retain their original archives.
nginx implements its own QUIC transport and does not use the patched stream map.
kTLS is not enabled. No ngtcp2 transport or buffered TLS-output prototype is
included in the candidate.

All servers use the same configuration, files, certificate and patched oha
1.16.0 load binary described in [PLAN.md](PLAN.md#http2-and-http3). One server
worker is pinned to vCPU 0; the client uses vCPUs 1–7. Each sample follows a
2-second warmup and measures 10 seconds, with four repetitions and alternating
server order. Responses are 612 bytes or 1 MiB; each connection allows 16
concurrent request streams. HTTP/3 includes 4- and 16-connection small cases
and the 4-connection large case. HTTP/2's large case is also checked.

RPS is the median successful-request count divided by elapsed time; p99 is the
median of per-sample p99 values. These are loopback measurements on a shared
physical host, not a packet-loss performance study or dedicated-hardware result.

An intermediate GSO/GC candidate still showed p99 around 6 ms while using
about 0.54 server CPU cores. Its fixed 5 ms polling interval could oversleep a
QUIC pacing deadline; that candidate was superseded by deadline-aware waiting.

A first attempted final series (`20261112-024627`) overlapped another benchmark
on the same vCPU after that workload restarted. It was stopped and is invalid
for performance claims. Subsequent measurement is coordinated sequentially,
with a process timeline retained to check for overlap. Exploratory short runs
are also excluded from acceptance evidence.

## Evidence and results

Runtime commit: `4676feb` (documentation/evidence commits do not change the
measured code). Raw JSON, per-sample CPU sidecars, the exact configuration,
binary hashes, scenario manifests and failing strict-gate output are retained
in [evidence/2026-11-12-h3-large](evidence/2026-11-12-h3-large/).
All table values are medians across four repetitions; all measured requests
completed without HTTP or load-generator errors. `c` is the number of
connections, and `p16` means 16 streams per connection.

| Scenario | Baseline RPS | nginx RPS | Candidate RPS | vs nginx | p99 baseline / nginx / candidate, ms |
|---|---:|---:|---:|---:|---|
| h3-small-c4-p16 | 116,058 | 244,163 | 160,870 | -34.1% | 0.851 / 0.361 / 0.573 |
| h3-small-c16-p16 | 110,255 | 232,565 | 159,515 | -31.4% | 4.703 / 1.526 / 2.928 |
| h3-large-c4-p16 | 513 | 628 | 849 | +35.3% | 133.221 / 186.580 / 79.791 |
| h2-large-c4-p16 | 1,689 | 1,978 | 1,694 | -14.4% | 41.462 / 43.835 / 41.577 |

The HTTP/3 large-response case still needs approximately 10.9% more throughput
at the measured nginx rate to reach the requested 1.5× ratio. Small-response
cases need about 2.19–2.28× the candidate's measured throughput, together with
lower p99. Passing functional tests is not a pass of that performance target.

The HTTP/2 large case does not reach the throughput target. Its recorded p99
is 0.3% above the saved baseline, so the exact no-regression gate also fails;
this report does not claim unchanged p99. The buffered-TLS prototype was not
retained because it did not establish the requested gain.

The final suites are `20261112-031312` (HTTP/3) and `20261112-032041`
(HTTP/2 large). Their process timeline contains 299 snapshots at two-second
intervals with no unexpected benchmark/build processes. Sampling is not proof
that no shorter background activity occurred; the physical host remains shared.
The complete baseline, nginx, candidate and load-client hashes are in `env.txt`.
The candidate archive differs from the baseline archive by the included QUIC
stream-map fix; libcrypto is unchanged. Archive hashes are retained separately.

Default builds without TLS also passed all 57 unit tests after the timer change.
The branch remains available for further work; it was not merged because the
requested performance acceptance conditions did not pass.
