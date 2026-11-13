# HTTP/3 on the zquic transport — 2026-11-13

This report compares runtime `de3180b` (branch `quic-zig-quic-transport`) with
main `a539d24` and nginx 1.30.6. The target requires successful RPS at least
1.6 times nginx in every HTTP/3 scenario, and median sample p99 no worse than
both nginx and the saved main baseline.

## Changes

HTTP/3 no longer uses OpenSSL's QUIC stack or nghttp3. A new package,
`modules/quic` (`zquic`), implements the QUIC v1 server transport (RFC 9000,
9001, 9002) and a small HTTP/3 + QPACK layer (RFC 9114, 9204) in Zig. It does
not import zhttpd code and builds and tests on its own.

- **TLS:** OpenSSL 3.5+ still runs the TLS 1.3 handshake through its
  third-party QUIC TLS callbacks (`SSL_set_quic_tls_cbs`). Packet protection,
  header protection, key update and AEAD record handling are done in the
  package, using OpenSSL EVP AEAD by default.
- **Transport:** loss recovery and NewReno, flow control, connection IDs,
  Retry and Version Negotiation, path validation and migration, idle and
  drain timers, and GOAWAY drain.
- **UDP I/O:** `recvmmsg`/`sendmmsg` with PKTINFO and GSO on Linux, and
  `recvmsg`/`sendmsg` elsewhere.
- **QPACK:** static table only (dynamic capacity 0), with Huffman coding.
  Huffman-decoded request literals are memoized per connection.

`src/server/h3.zig` connects zquic requests to the existing engine `Conn`: a
request becomes HTTP/1.1 request text, and the engine's response head is parsed
back into QPACK fields. Bodies move without that conversion, and file bodies
are written zero-copy into the stream's send ring
(`reserveData`/`commitData`). Request header values are checked for CR, LF and
NUL; the path is checked for control characters and spaces. The block-compare
scanners used for this live in `src/http/request.zig` and are shared with the
HTTP/1.1 parser.

The receive loop sends one connection's output early in each receive round,
once its peer's last datagram in the batch is processed. That client can start
its next round while the server works through the other connections'
datagrams. The rest share the end-of-round flush. This was the largest single
gain at four connections (see *Exploratory variants*).

The HTTP/2 path (`multiplex.c`, `conn.zig`), TLS backend, ciphers, response
contents and server configuration are unchanged. No kTLS path or response
cache is introduced. The OpenSSL QUIC patch and nghttp3 are no longer needed
for HTTP/3; nghttp2 remains for HTTP/2.

## Verification

- On `de3180b`, `zig build test` in `modules/quic` passes on its own, with 23 tests (wire, packet, crypto
  vectors from RFC 9001 Appendix A, ranges, recovery, streams, QPACK, HTTP/3).
  zhttpd's unit tests pass.
- **Interop:** aioquic completes requests against the example `h3-server`,
  and oha drives it at 612 B and 1 MiB with zero errors.
- **Protocol suite:** passes on Linux Debug and Linux ReleaseFast. It covers
  HTTP/1.1, HTTP/2 and HTTP/3, multiplexing, uploads, static files and HEAD,
  proxying, limits, ACL, vhosts, connection reuse, loss, reordering and
  duplicates, migration, reload and shutdown, plus TLS 1.3 KeyUpdate in both
  modes.

macOS ReleaseFast has not been run yet. The host's Python has no `aioquic` or
`h2` (the protocol suite imports both), and installing them needs a download
approval that is still pending. nghttp2 1.71.0 for the macOS build was
downloaded with approval, verified by sha256 and built into
`deps/http-install`.

## Method

Linux aarch64 (Lima VM `zhttpd-bench`), Zig 0.17.1 ReleaseFast, OpenSSL 3.5.9,
nghttp2 1.71.0, nginx 1.30.6 and completion-draining oha 1.16.0. The main
baseline is built from main `a539d24` (its `src/` and `build.zig` tree hashes
match) with the same toolchain and dependencies. It serves HTTP/3 through
OpenSSL QUIC and nghttp3.

One worker is pinned to VM CPU 0, and the client uses CPUs 1–7. All three
servers use the same files, certificate and recorded configuration, with 16
streams per connection. Each sample lasts 10 seconds after 2 seconds of warmup.
Four repetitions alternate server order. Results use medians of per-sample
successful RPS, p99 and peak process-tree PSS.

Measurements ran under the shared bench lock (`flock ~/zhttpd-bench.lock`), so
no other session's build or measurement overlapped them. The physical macOS
host is shared with other applications. These loopback measurements are not
production-network guarantees.

Comparisons between code variants used paired A/B runs in alternating order:
both builds were built from `git archive` of each revision and measured with
the bench's oha flags. The VM exposes no hardware PMU, so instruction counts
were not available. CPU-clock profiles (`perf record`) and syscall tracepoint
counts (`perf stat`) were used instead.

## Profile evidence

CPU-clock profiles were taken on `de3180b` with the bench configuration,
999 Hz for 6 seconds. At four connections, the largest single symbol is the
kernel's `__wake_up_sync_key` (12.2%), which wakes the client on loopback sends.

| Cost | c4 share |
|---|---:|
| Engine `Conn.sendRaw` | 7.4% |
| Engine `Conn.drive` | 7.2% |
| `memcpy` | 5.4% |
| AES-256-GCM | 4.1% |

Before the per-connection memo, QPACK Huffman decoding was 4.8%; the memo
lookup is now 0.55%. At 16 connections the order is the same.

Over four seconds at four connections (429,888 RPS), the worker made:

- 1.71 M `pread64`, one per request (612-byte file)
- 101 k `recvmmsg` and 101 k `epoll_pwait`, one each per loop iteration
- 127 k `sendmmsg`, including the early flushes

That is about 1.19 syscalls per request.

The largest remaining userland cost is the HTTP/1.1 bridge into the engine
(`drive`, `sendRaw` and response head parsing). These are self-time shares
from flat profiles; call-graph totals were not used.

## Exploratory variants

These are shorter paired A/B screens. They are separate from the final matrix,
and the ratios are candidate/reference.

- **Early flush per receive round:**
  - Flushing after every datagram gave c4 ×1.12.
  - Flushing each connection after its peer's last datagram, with no cap,
    gave c16 ×0.950.
  - Flushing on every peer change gave c4 ×1.11 and c16 ×0.856.

  At 16 connections, the extra small `sendmmsg` batches cost more than the
  latency they save.
  - Accepted: at most one early flush per round, for the connection whose peer
    has no later datagram in the batch. This gave c4 ×1.10 and c16 ×1.02,
    measured under host load around 12.
- **Userland trims, each neutral within noise:**
  - vectorized header validation (×1.002)
  - block-compare head scanning (×0.999)
  - a single `contentType` lookup per file response
  - inline pseudo-header name compares

  The c4 scenario is latency-bound: zhttpd used about 91% of its CPU and each
  oha thread about 55%. Shorter per-request work just turns into more loop
  iterations with smaller batches. These trims are kept because they reduce
  CPU per request without changing behaviour.
- **Rejected:** rewriting the response head writer to use
  `writeParts` instead of `print` raised `memcpy` from 6% to 7% of samples
  and was reverted.
- **Bench flag:** oha's `-t 10s` (used by the bench for every server) costs
  about 2% RPS compared with no timeout. It applies equally to all servers
  and was kept.

## Results

All 36 measured samples completed without HTTP or load-generator errors.
`python3 bench/check-target.py bench/results/20261113-124029 1.6` passes all
three scenarios.

| Scenario | main RPS | nginx RPS | zquic RPS | vs nginx | 1.6× + p99 gate |
|---|---:|---:|---:|---:|---|
| h3-large-ka-c4-p16 | 961 | 556 | 2,076 | 3.735× | PASS |
| h3-small-ka-c16-p16 | 165,542 | 237,052 | 533,617 | 2.251× | PASS |
| h3-small-ka-c4-p16 | 164,500 | 247,685 | 440,692 | 1.779× | PASS |

Median sample p99, milliseconds:

| Scenario | main | nginx | zquic | vs nginx | vs main |
|---|---:|---:|---:|---:|---:|
| h3-large-ka-c4-p16 | 72.4375 | 226.2091 | 43.6390 | -80.7% | -39.8% |
| h3-small-ka-c16-p16 | 2.7915 | 1.6080 | 0.7731 | -51.9% | -72.3% |
| h3-small-ka-c4-p16 | 0.6467 | 0.4151 | 0.2431 | -41.4% | -62.4% |

Median per-sample peak process-tree PSS, MiB:

| Scenario | main | nginx | zquic | vs main |
|---|---:|---:|---:|---:|
| h3-large-ka-c4-p16 | 26.97 | 31.95 | 14.80 | -45.1% |
| h3-small-ka-c16-p16 | 13.44 | 21.89 | 9.43 | -29.8% |
| h3-small-ka-c4-p16 | 9.46 | 16.28 | 8.21 | -13.2% |

Median server CPU, cores:

| Scenario | main | nginx | zquic |
|---|---:|---:|---:|
| h3-large-ka-c4-p16 | 1.00 | 0.99 | 0.99 |
| h3-small-ka-c16-p16 | 0.97 | 0.97 | 0.92 |
| h3-small-ka-c4-p16 | 0.98 | 0.96 | 0.91 |

**The target is met:** every HTTP/3 scenario reaches at least 1.6× nginx
successful RPS, with median p99 below both nginx and main. Short responses at
four connections have the smallest margin (1.779×). An earlier full matrix
started at 00:53, before `0ecba24` and the early flush, measured 1.578× there
and failed. That matrix is kept under `exploratory/`. Memory is lower than main in all three scenarios.
Server CPU is similar for all three servers; at small responses zquic uses
slightly less (0.91 against 0.96–0.98 cores) because it is more latency-bound.
These loopback results on one VM are not production-network guarantees.

Raw samples, memory/CPU sidecars, configurations, source/binary hashes, profiles,
exploratory screens and validation logs are in
[the evidence directory](evidence/2026-11-13-zquic-h3/).
