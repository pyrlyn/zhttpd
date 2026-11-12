# HTTP/2 and HTTP/3 optimization — 2026-11-11/12

The **suite-wide target is not achieved**: at least 1.5× nginx throughput with
median p99 no worse than nginx and the saved main baseline in every scenario.
The single-worker HTTP/2 small-response cases pass: **+66.8% to +70.0% RPS**,
with p99 **31.3% to 38.2% lower** than nginx. HTTP/2's 1 MiB case and HTTP/3
remain below the requested throughput target. These results do not support a
general claim that zhttpd is 50% faster than nginx.

## Reproduction and evidence

- Runtime change: `342d4ac14fcb63d4fbea54459a5405b03e83a36e`.
- Saved baseline: `133b623a81441a5ec948f85c47ffe150d940d392`, built separately
  with the same Zig, optimization mode, OpenSSL and HTTP codec libraries.
- Linux aarch64, dedicated `zhttpd-bench` Lima VM, 8 vCPUs, 4 GiB RAM, epoll.
  The macOS host is shared; the results are local loopback measurements, not
  an Internet-latency or packet-loss study.
- zhttpd: Zig 0.17.1, ReleaseFast, `-Dtls=true -Dhttp=true`; OpenSSL 3.5.9,
  nghttp2 1.71.0 and nghttp3 1.19.0. kTLS is not enabled.
- nginx 1.30.6: GCC 13.3.0, `-O2`, the same OpenSSL 3.5.9, HTTP/2 and HTTP/3
  modules, threads and file AIO built in. Exact configure flags are in each
  result directory's `env.txt`.
- oha 1.16.0, Rust 1.99.1, `--features http3 --locked`, with the checked-in
  [driver-drain patch](oha-http3-drain.patch). The same executable loads all
  servers. It waits for request tasks to finish, then stops waiting for the
  peer's connection shutdown; request generation and latency accounting are
  unchanged. Binary SHA-256 values are recorded, including the load generator.
- Same generated files, ECDSA certificate and rendered nginx configuration for
  all servers. Access logging off; file cache, sendfile and reuseport enabled;
  TLS 1.3; 16 concurrent streams per connection.
- Each sample: 2-second successful warmup, 10-second measured load, four
  repetitions with alternating server order. All recorded samples must have
  zero HTTP/load errors. The harness also bounds the whole load process.
- Capacity layout: one server worker pinned to vCPU 0, client pinned to 1–7;
  includes the original main baseline. Scaling layout: four workers pinned to
  0–3, client to 4–7; compares nginx and the candidate.
- RPS is the median of successful requests divided by elapsed time per run.
  Latency is the median of the per-run p99 values, not a pooled percentile.
  The `.json.err` sidecars record client and server CPU usage in core units.

Run commands and the pinned load-client build are in [PLAN.md](PLAN.md#http2-and-http3).
Raw JSON, configurations, manifests, CPU sidecars and strict gate output are
retained under [evidence/2026-11-11-h2-h3](evidence/2026-11-11-h2-h3/).
The `target.txt` files retain failing cases; no scenario is discarded for
missing the requested ratio.

## Results

Small responses are 612 bytes; large responses are 1 MiB. `c` is the number
of connections and `p` is the number of concurrent streams per connection.
All values below are medians across four repetitions. The original invalid
four-worker HTTP/2 run is excluded from these tables and retained separately.

### One worker: HTTP/2

| Scenario | Baseline RPS | nginx RPS | zhttpd RPS | vs nginx | vs baseline | p99 baseline / nginx / zhttpd, ms |
|---|---:|---:|---:|---:|---:|---|
| h2-small-ka-c4-p16 | 52,038 | 201,023 | 335,325 | +66.8% | +544.4% | 2.120 / 0.445 / 0.275 |
| h2-small-ka-c16-p16 | 47,123 | 199,796 | 339,626 | +70.0% | +620.7% | 7.298 / 1.577 / 1.084 |
| h2-large-ka-c4-p16 | 337 | 1,883 | 1,643 | -12.8% | +387.6% | 224.901 / 45.213 / 43.378 |

### One worker: HTTP/3

| Scenario | Baseline RPS | nginx RPS | zhttpd RPS | vs nginx | vs baseline | p99 baseline / nginx / zhttpd, ms |
|---|---:|---:|---:|---:|---:|---|
| h3-small-ka-c4-p16 | 28,841 | 228,084 | 106,290 | -53.4% | +268.5% | 2.977 / 0.474 / 0.881 |
| h3-small-ka-c16-p16 | 17,141 | 216,022 | 103,229 | -52.2% | +502.2% | 17.279 / 1.603 / 4.723 |
| h3-large-ka-c4-p16 | 354 | 547 | 473 | -13.5% | +33.9% | 201.610 / 281.233 / 140.431 |

### Four workers: HTTP/2

| Scenario | Baseline RPS | nginx RPS | zhttpd RPS | vs nginx | vs baseline | p99 baseline / nginx / zhttpd, ms |
|---|---:|---:|---:|---:|---:|---|
| h2-small-ka-c4-p16 | — | 167,233 | 179,322 | +7.2% | — | — / 1.573 / 1.149 |
| h2-small-ka-c16-p16 | — | 287,548 | 350,503 | +21.9% | — | — / 4.058 / 2.855 |
| h2-large-ka-c4-p16 | — | 3,625 | 3,406 | -6.0% | — | — / 45.407 / 54.835 |

### Four workers: HTTP/3

| Scenario | Baseline RPS | nginx RPS | zhttpd RPS | vs nginx | vs baseline | p99 baseline / nginx / zhttpd, ms |
|---|---:|---:|---:|---:|---:|---|
| h3-small-ka-c4-p16 | — | 345,876 | 196,450 | -43.2% | — | — / 0.282 / 0.649 |
| h3-small-ka-c16-p16 | — | 612,901 | 321,680 | -47.5% | — | — / 0.747 / 1.909 |
| h3-large-ka-c4-p16 | — | 1,327 | 1,005 | -24.3% | — | — / 119.766 / 83.881 |

## Interpretation and limits

The capacity runs improve throughput and p99 against the saved main baseline
in every measured scenario. The HTTP/2 small-response cases also clear the
stricter nginx target. HTTP/3 small-response p99 is still worse than nginx,
despite improving substantially against the original main. The four-worker
HTTP/2 large-response p99 is also worse than nginx. Large responses remain below the requested throughput ratio for both protocols.

The single-worker client uses at most about 1.7 CPU cores with seven available;
the candidate server uses about one core. These measurements do not appear
load-generator CPU bound. Four-worker results are less stable: client usage can
approach its four-core allocation, connection-to-worker hashing affects
utilization, and other VMs are active on the shared host. A resource snapshot
is retained in `evidence/2026-11-11-h2-h3/environment/`. Affinity inside the guest
does not reserve physical host cores. Treat scaling results as local observations,
not evidence of universal four-core capacity or a production latency guarantee.

The first four-worker HTTP/2 run produced nginx HTTP/2/cancellation errors in
the small/c4 case at approximately the configured one-million-request limit
per connection. It fails the zero-error gate and is retained as
`scaling-h2-invalid-request-limit`. The repeated suite raises
`keepalive_requests` to one billion for both servers; the earlier capacity and
HTTP/3 suites retain the one-million setting recorded in their configurations.
All 120 samples in the four final tables contain no HTTP/load errors.

The remaining performance target requires further work in QUIC and large-response
throughput, followed by a repeat on a quiet, isolated host. Functional correctness
and improvement against main do not satisfy the full +50% acceptance condition.

## Changes

The codecs now feed the existing request engine through bounded memory buffers
instead of creating and polling an internal socketpair for every stream. Routing,
ACLs, body limits, proxy handling and access accounting continue through that
engine. Ready work is continued promptly; a separate deferred-free link keeps
nested codec/request teardown safe during event-loop traversal.

HTTP/2 batches frames into TLS records. Large DATA frames bypass an intermediate
codec copy, and static-file reads go directly into the transport output buffer.
TLS retry bytes remain owned by the session, so canceling a stream cannot
invalidate a pending `SSL_write`. Header comparison uses known literal lengths;
response header parsing reuses lengths already found by the parser.

Stream buffers are bounded and shared through a cache of at most 32 entries per
event-loop thread, under 4 MiB. The cache is released when the last session closes.
Request input is capped at 64 KiB and response output at 32 KiB minus 18 bytes,
aligning two large DATA payloads with two 16 KiB TLS records. Reusing a request
handler no longer copies an unused 8 KiB FastCGI buffer.

On Linux, QUIC `reuseport` creates a socket for each worker. Obsolete master
sockets are closed before forking a new generation, preventing new workers from
retaining abandoned UDP receive queues. Shared sockets retain one owner.
Cross-worker connection migration remains unsupported.

QUIC uses explicit OpenSSL event processing, batches established short-header
traffic, and reuses address objects. Long-header packets are processed while
their originating address context is current. Completed unknown unidirectional
streams are reclaimed. Client GOAWAY is handled with response drainage and
`H3_NO_ERROR` connection closure; no application I/O is attempted after transport
shutdown starts.

## Verification

The added wire checks cover concurrent peers with distinct source addresses,
worker distribution before/after reload, repeated GREASE streams, HTTP/3 GOAWAY
and complete large responses, and HTTP/2 cancellation while TCP output is
backpressured. Existing checks cover uploads, proxying, malformed headers,
ACLs, vhosts, HEAD, file contents, stream reuse and shutdown.

Linux protocol checks passed with and without QUIC reuseport, including a run
with allocator perturbation. TLS 1.2/1.3 record fragmentation, pipelining, slow
readers, file freshness and TLS 1.3 KeyUpdate tests passed. macOS unit tests with and without TLS/HTTP codecs and
final protocol tests passed. The full macOS module E2E suite also passed on the
transport changes; the final file-copy refinement was subsequently exercised by
the final macOS/Linux protocol tests, including large-file backpressure.

The full suite covers native/nginx/Apache/OpenLiteSpeed/Caddy configuration,
automatic reload, certificate/key and DNS env-file rotation, load balancing,
logging, gateway handling, real ACME issuance/reload/SNI isolation, and all
WebSocket SDK examples. Functional success is separate from the performance
acceptance gate, which still fails overall.

After measurement, main's encrypted-ACME lifecycle and benchmark-path validation
changes (`bcd752b`) were integrated in `b240708`. The reload conflict was resolved
by preserving both pre-fork socket closure and ACME-lock release in child workers.
The integrated source passed Linux/macOS unit and protocol tests, macOS tests
without TLS, Linux TLS/key rotation tests in all five configuration modes, and
the native-mode HTTP-01 encrypted-ACME E2E including superseded issuance during
reload. The tables above measure `342d4ac`; they were not rerun after this
startup/reload integration and must not be presented as measurements of a different
binary hash.
