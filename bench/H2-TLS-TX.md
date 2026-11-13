# HTTP/2 userspace TLS record sealing — 2026-11-13

This report compares the working tree of branch `perf/h2-userspace-tls-tx`
(based on main `a539d24`) with main `a539d24` and nginx 1.30.6. The target
requires successful RPS at least 1.6 times nginx in every HTTP/2 scenario,
and median sample p99 no worse than both nginx and the saved main baseline.
HTTP/3 is handled separately by the zquic transport (pyrlyn/zhttpd#5); its
independent re-check is summarised at the end.

## Changes

**TLS 1.3 write BIO (`src/server/tls_tx.c`).** HTTP/2 connections replace
their socket BIO with a BIO that accepts OpenSSL's kTLS hand-off
(`SSL_OP_ENABLE_KTLS`, `BIO_set_ktls`) in userspace. OpenSSL still runs the
handshake, alerts, KeyUpdate and all reading. Once the write traffic keys are
installed, OpenSSL passes plaintext records to the BIO, which seals them
(AES-128-GCM, AES-256-GCM or ChaCha20-Poly1305 with OpenSSL EVP) into a
per-connection batch of up to six records. The batch is sent with one `send`
at the end of the connection's drive turn instead of one write per record.
Batches come from a small per-thread pool (at most four) and return to it
once drained. Anything OpenSSL encrypts itself is passed through behind
records that are already queued, so byte order is preserved.

**File DATA frames sealed from the page cache.** When a large static file's
DATA frame is due and nothing is queued ahead of it in OpenSSL, the frame
header and body are sealed directly from a read-only `mmap` window of the
borrowed descriptor (up to 4 MiB, `MAP_POPULATE`) into the batch: one record
per frame, as before. This removes the `pread` copy into the staging buffer
and the copy from that buffer into OpenSSL's record buffer. The mapping
belongs to the stream and is unmapped when the file completes, the request
finishes or the stream is recycled. Otherwise the existing `pread` path is
used: before keys are installed, while a KeyUpdate or control record is
pending, after close_notify, or if `mmap` fails.

A file that is truncated while it is mapped raises `SIGBUS` on access. A
guarded `sigsetjmp` around the sealing call abandons that record before the
batch length or sequence number advances, and the stream is reset with
`INTERNAL_ERROR` while its siblings continue. Any other `SIGBUS` goes to the
previous handler. **Limitation:** if the file is truncated to a length within
the last mapped page, the bytes past the new end read as zeros instead of
faulting. The `pread` path would reset the stream in that case.

**OpenSSL 3.5 read-layer fallback.** `SSL_OP_ENABLE_KTLS` also makes OpenSSL
try the kTLS method for the *read* keys. When the BIO refuses it, OpenSSL
falls back to the default method but passes it an empty "previous" BIO. With
`read_ahead` on, the records that follow the peer's Finished or KeyUpdate in
the same read are lost, and the peer then sees `bad_record_mac`. The existing
KeyUpdate wire test caught this. The option is now set only around write-key
changes: it is cleared as soon as the BIO receives write keys, and set again
just before an `SSL_write` that sends a pending KeyUpdate (OpenSSL sends it
only from `ssl3_write_bytes`). Connections that negotiated a reduced maximum
fragment length keep the plain socket BIO, because OpenSSL refuses kTLS for
them before reaching the BIO. A refused or failed key install switches the
BIO to pass-through rather than sealing with retired keys. A flush that would
block reports success while sealing, because sealed records are already
queued in order. Otherwise OpenSSL would silently fall back to software
encryption mid-connection.

**Response head conversion (`response_headers`).** The engine's HTTP/1.x
response head is converted to header fields in a single bounded pass with one
`memchr` per line, instead of a per-byte compare for the blank line plus
`strstr`/`strchr` on a NUL-terminated copy. Only the active protocol's field
array is filled. Informational (1xx) heads are still skipped without parsing.

The TLS backend, ciphers, HTTP/2 flow-control windows, response contents and
server configuration are unchanged. No kernel kTLS, response cache or new
dependency is introduced.

## Verification

Linux aarch64 ReleaseFast:

- **Unit tests:** all 76 pass.
- **Native codec test (`quic-io-test`):** passes. It covers file ownership,
  backpressure and stream lifetime.
- **Protocol suite:** passes. It covers HTTP/1.1, HTTP/2 and HTTP/3,
  multiplexing, uploads, static files and HEAD, proxying, limits, ACL, vhosts,
  connection reuse, loss, reordering and duplicates, reload and shutdown.
  - TLS 1.3 KeyUpdate (both modes, during a 1 MiB HTTP/2 response and on the
    next request, before and after reload): passes. It failed before the
    read-layer fix above.
  - The HTTP/2 truncation test (zero window, truncate after headers, expect
    RST_STREAM with the sibling intact): passes. It now exercises the guarded
    `SIGBUS` path.
- **Application/policy assertions:** all 193 pass.

macOS: `tls_tx.c` compiles with `-Wall -Wextra -Werror` against OpenSSL 3.6.4
headers, and its non-Linux branch is a set of stubs. **Not run:** the full
macOS build and suites (the host has no nghttp3 headers for the `multiplex.c`
build), Linux Debug, and sanitizer builds.

## Method

Linux aarch64 (Lima VM `zhttpd-bench`, kernel 6.8.0-149), Zig 0.17.1
ReleaseFast, OpenSSL 3.5.9, nghttp2 1.71.0, nghttp3 1.19.0, nginx 1.30.6 and
completion-draining oha 1.16.0. The main baseline is built from `a539d24`
with the same toolchain and dependencies. Binary hashes are in the evidence
directory.

One worker is pinned to VM CPU 0, and the client uses CPUs 1–7. All three
servers use the same files, certificate and recorded configuration, with 16
streams per connection and `ssl_protocols TLSv1.3`. **Neither server uses
kernel kTLS.** nginx's `ssl_conf_command Options KTLS` is not enabled, and
zhttpd's record sealing is its own code, not a kernel or configuration
feature. Each sample lasts 10 seconds after 2 seconds of warmup. Five
repetitions alternate server order. Results use medians of per-sample
successful RPS and p99. All runs held the shared bench lock
(`flock ~/zhttpd-bench.lock`).

Single runs on this VM swing by about 5–10% (nginx measured 195–219 k RPS on
small responses across the day). An earlier three-repetition matrix showed
small-response p99 above baseline. A paired five-repetition A/B of baseline
against the stage-1/2 candidate then measured the candidate at +1.4% / +1.7%
RPS with equal or lower p99 (`ab-small/`), so that earlier result was noise.

## Profile evidence

CPU-clock profiles were taken with the bench configuration at 4,999 Hz for
8 seconds.

On the 1 MiB response at four connections:

| Cost | main | this branch |
|---|---:|---:|
| AES-256-GCM | 40.0% | 58.3% |
| `memcpy` | 12.4% | — |
| `pread` copy-out (`__arch_copy_to_user`) | 7.3% | — |
| `send` copy-in (`__arch_copy_from_user`) | 6.4% | 9.1% |

Sealing from the mapped file removes the `pread` copy-out and the userspace
`memcpy` of the record body. What remains is mostly encryption and the
socket copy (`profiles/large-c4-*.txt`).

On small responses at four connections, `response_headers` fell from 7.8% to
3.4% of samples, and `strstr`/`strchr` (2.9%) disappeared. The remaining
largest costs are `Conn.drive` (10%), the loopback wake-up (7%), `memcpy` (5%)
and AES-GCM (3.6%) (`profiles/small-c4-*.txt`).

## Results

All 45 samples of the final matrix completed without HTTP or load-generator
errors. `python3 bench/check-target.py
bench/evidence/2026-11-13-h2-tls-tx/final/20261113-133625 1.6` passes all
three scenarios.

Successful RPS (median):

| Scenario | main RPS | nginx RPS | zhttpd RPS | vs nginx | vs main |
|---|---:|---:|---:|---:|---:|
| h2-large-ka-c4-p16 | 2,715 | 2,085 | 4,029 | 1.932× | +48.4% |
| h2-small-ka-c16-p16 | 379,602 | 217,741 | 411,634 | 1.890× | +8.4% |
| h2-small-ka-c4-p16 | 361,167 | 219,046 | 401,458 | 1.833× | +11.2% |

Median sample p99:

| Scenario | p99 vs nginx | p99 vs main |
|---|---:|---:|
| h2-large-ka-c4-p16 | 0.414× | 0.663× |
| h2-small-ka-c16-p16 | 0.536× | 0.950× |
| h2-small-ka-c4-p16 | 0.551× | 0.937× |

Peak process-tree PSS during a 12-second h2-large load, two runs each:
zhttpd 10.35–10.41 MiB against main 10.71 MiB, at 4,040 against 2,710 RPS.

**The HTTP/2 target is met:** every scenario reaches at least 1.6× nginx
successful RPS, with median p99 below both nginx and main. Before this change
the same matrix measured 1.31× on h2-large.

## HTTP/3 (pyrlyn/zhttpd#5), re-checked independently

The zquic branch was built from `git archive` of `5075467` and measured with
the same method, five repetitions (`bench/results/20261113-135624` in the VM):

| Scenario | vs nginx | p99 vs nginx | p99 vs main |
|---|---:|---:|---:|
| h3-large-ka-c4-p16 | 3.454× | 0.224× | 0.563× |
| h3-small-ka-c16-p16 | 2.200× | 0.577× | 0.281× |
| h3-small-ka-c4-p16 | 2.034× | 0.555× | 0.383× |

**This branch and #5 have not been measured together.** #5 rewrites
`multiplex.c` (it removes the OpenSSL QUIC/nghttp3 path) and also changes
`build.zig`, `multiplex.zig` and `tls.zig`. Combining them needs a rebase and
a fresh HTTP/2 and HTTP/3 matrix. These loopback results on one VM are not
production-network guarantees.

Raw samples, configurations, binary hashes and profiles are in
[the evidence directory](evidence/2026-11-13-h2-tls-tx/).
