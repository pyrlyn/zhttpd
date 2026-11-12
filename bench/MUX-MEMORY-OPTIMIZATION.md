# Multiplexed response memory and throughput — 2026-11-12

This follow-up compares runtime `de0d0de` with main `f146b20`. The measured
source package is `6e5868a`; its additional commit only adds a wire regression
test. The target requires successful RPS at least 1.5 times nginx and median
sample p99 no worse than both nginx and the saved main baseline. Memory is
measured separately as process-tree PSS, including master and worker.

## Changes

Large HTTP/2 file responses now borrow the live request's file descriptor and
read directly into the connection's 16 KiB TLS staging buffer after HTTP/2
flow control grants a DATA frame. This removes the intermediate file copy
and large per-stream response allocation. The request advances its file
offset only after the codec acknowledges copied bytes. An outstanding TLS
write continues to reference connection-owned bytes, even if its stream is
cancelled. Cancellation invalidates the borrowed descriptor; truncation
resets the affected stream while siblings continue.

Stream buffers start at 1 KiB each for headers and input, and 2 KiB for output.
They grow within the existing limits: 14 KiB request headers, 64 KiB input,
32,750 bytes ordinary output and 131,000 bytes for large HTTP/3 file output.
The response header limit remains 32,750 bytes. Retained response vectors
cannot move. Failed input/header growth rejects the request; failed body/file
growth can keep using smaller chunks. Failed growth of an incomplete response
header fails the request instead of deadlocking on a full buffer.

Frequently touched URI/authority fields share the beginning of the stream
allocation. Cached capacities survive reuse. The worker-local codec cache
still holds at most 32 streams and at most 1,048,000 output bytes. These bounds
do not imply a fixed limit on all active connection memory.

File staging and its progress acknowledgement use one C bridge call for both
protocols. Linux UDP packets that cannot share a GSO segment are passed to the
ordinary datagram BIO in batches, stopping before the next possible GSO pair.
The native test checks 70 increasing-length packets across two peers, with
at most two ordinary BIO calls and exact packet boundaries and source addresses.

The TLS backend, ciphers, HTTP flow-control windows, response contents and
QUIC congestion control are unchanged. No new dependency, response cache or
kTLS path is introduced.

## Verification

Linux Debug and ReleaseFast and macOS ReleaseFast pass all 76 unit tests and
the protocol suite. Linux and macOS ReleaseFast pass the 193 application/policy
assertions. Linux codec tests also pass AddressSanitizer, UndefinedBehaviorSanitizer
and leak detection. The allocation tests force growth failures; file tests
check offsets, byte accounting, backpressure, truncation and descriptor lifetime.

The wire suite covers HTTP/1.1, HTTP/2 and HTTP/3, uploads, proxies, HEAD,
cancelled streams, slow readers, limits, vhosts, loss/reordering/duplicates,
reload and shutdown. TLS 1.3 KeyUpdate is exercised in both modes during a
1 MiB HTTP/2 response and on a subsequent request, before and after reload.
The added truncation test uses a zero stream window, truncates the file after
receiving its headers, then verifies RST_STREAM without closing its sibling.
It passes on Linux Debug/ReleaseFast and macOS ReleaseFast.

The previous main CI exposed a separate Raft shutdown hang: consensus stopped
while a publisher still waited for an Apply future. Shutdown now stops HTTP
admission and drains active handlers and background work before stopping Raft.
The new regression fails on the old ordering and passes on the new ordering;
it and the mTLS replication test pass ten repetitions with the race detector.
The complete Raft race suite also passes.

## Method

Linux aarch64, kernel 6.8.0-134, Zig 0.17.1 ReleaseFast, OpenSSL 3.5.9,
nghttp2 1.71.0, nghttp3 1.19.0, nginx 1.30.6 and completion-draining oha 1.16.0.
The saved main binary is runtime-equivalent to `f146b20` (its predecessor's
runtime plus documentation). Both zhttpd builds use the same dependencies,
including the previously merged OpenSSL QUIC stream-retirement patch.

One worker is pinned to VM CPU 0; the client uses CPUs 1–7. All three servers
use the same files, certificate and recorded configuration, with 16 streams
per connection. The nginx configuration has no explicit `quic_gso` directive;
zhttpd's existing adapter uses GSO when available. This is a comparison of that
recorded configuration, not every nginx tuning option.

Each sample lasts 10 seconds after 2 seconds of warmup. Four repetitions
alternate server order. Results use medians of per-sample successful RPS,
p99 and peak process-tree PSS. No competing build or load process was observed in the two-second VM
snapshots during measurements. The physical macOS host is shared with other applications
and another VM; the VM process timeline and aggregated host CPU samples are
retained. Host sampling starts during the first server block. These loopback measurements are not production-network guarantees.

## Profile evidence

The same CPU-clock profiler samples large HTTP/2 `memcpy` at 17.43% on the
saved main binary and 11.59% on the candidate. AES-256-GCM still accounts for
36.36% of candidate samples. On short HTTP/3, the OpenSSL QUIC event handler
accounts for about 37.6% inclusive CPU and the application bridge about 22.2%.
Inclusive stacks overlap; these shares must not be added together. They
identify remaining costs, not proof that the 50% target has been reached.

## Exploratory variants

Shorter two-repetition screens are kept separately from the final matrix:

- Replacing Zig's bundled compiler runtime with system libgcc/libc did not
  produce a throughput gain and is not included.
- A 96 KiB HTTP/2 plaintext staging buffer did not give a consistent gain,
  either before or after direct file reads, and is not included.
- Enabling a 4 KiB QPACK dynamic decoder table did not improve the short-response
  screen and is not included.
- Compact buffers alone reduced memory but did not improve large HTTP/2
  throughput. The accepted direct file path addresses both copying and memory.

All 12 jobs of [CI run 43240394218](https://github.com/pyrlyn/zhttpd/actions/runs/43240394218)
passed for the measured runtime. The first attempt had one unrelated ACME challenge-port collision
(`address already in use`). Its failure excerpt is retained with validation
evidence; it is not counted as a passing attempt. The retry of that job passed.

## Results

All 60 measured samples completed without HTTP or load-generator errors.

| Scenario | main RPS | nginx RPS | candidate RPS | vs nginx | 1.5× + p99 gate |
|---|---:|---:|---:|---:|---|
| h2-large-ka-c4-p16 | 2,372 | 1,950 | 2,581 | +32.4% | FAIL |
| h2-small-ka-c4-p16 | 354,565 | 204,852 | 354,507 | +73.1% | PASS |
| h3-large-ka-c4-p16 | 961 | 579 | 973 | +68.0% | FAIL |
| h3-small-ka-c16-p16 | 164,476 | 232,665 | 167,574 | -28.0% | FAIL |
| h3-small-ka-c4-p16 | 164,915 | 242,033 | 165,909 | -31.5% | FAIL |

Median sample p99, milliseconds:

| Scenario | main | nginx | candidate | vs main |
|---|---:|---:|---:|---:|
| h2-large-ka-c4-p16 | 29.9772 | 44.5852 | 27.9720 | -6.7% |
| h2-small-ka-c4-p16 | 0.2430 | 0.4179 | 0.2386 | -1.8% |
| h3-large-ka-c4-p16 | 71.4885 | 234.0802 | 71.8052 | +0.4% |
| h3-small-ka-c16-p16 | 2.7633 | 1.5810 | 2.6209 | -5.2% |
| h3-small-ka-c4-p16 | 0.5996 | 0.3897 | 0.5573 | -7.1% |

Median per-sample peak process-tree PSS, MiB:

| Scenario | main | nginx | candidate | vs main |
|---|---:|---:|---:|---:|
| h2-large-ka-c4-p16 | 13.02 | 15.07 | 10.44 | -19.8% |
| h2-small-ka-c4-p16 | 8.62 | 15.03 | 8.25 | -4.3% |
| h3-large-ka-c4-p16 | 31.60 | 31.87 | 25.70 | -18.7% |
| h3-small-ka-c16-p16 | 14.27 | 21.42 | 13.39 | -6.1% |
| h3-small-ka-c4-p16 | 9.86 | 16.18 | 9.45 | -4.1% |

**The requested target remains unmet:** short HTTP/3 responses remain slower
than nginx, and large HTTP/2 responses do not reach 1.5× nginx throughput.
The primary large-H3 result also has a 0.4% p99 increase against main, so it
fails the strict latency gate despite its throughput lead over nginx.
Memory reductions and passing functional tests do not establish the full target.

Raw samples, memory/CPU sidecars, configurations, source/binary hashes, profiles,
rejected screens and validation logs are in
[the evidence directory](evidence/2026-11-12-mux-memory/).

## Extended large-HTTP/3 latency check

After the primary matrix exposed a 0.4% p99 increase, 12 additional repetitions
per server were declared before starting. The same binaries, CPU affinity,
10-second duration and 2-second warmup were used. Only main and candidate were
compared. All 24 additional samples completed without errors. The original
four samples remain in the primary table and in the pooled 16-sample result.

| Series | main RPS | candidate RPS | main p99 ms | candidate p99 ms | p99 change |
|---|---:|---:|---:|---:|---:|
| additional_12 | 1,019.4 | 1,028.2 | 67.9868 | 67.6781 | -0.45% |
| pooled_16 | 1,015.2 | 1,023.0 | 68.2733 | 68.0815 | -0.28% |

Pooled median-p99 guard: **PASS**.
This does not erase the primary-matrix failure or establish a latency guarantee
on a different host. The overall 50% throughput target remains unmet.
