# HTTPS/TLS optimization — 2026-11-12

The **1.5x nginx throughput without worse p99** target **passes all five HTTPS
scenarios in the final six-repeat series**. This is a measured HTTP/1.1 result
on Linux/ARM64, four workers, using the optional AWS-LC build. It is not a
guarantee for other machines, protocols or workload mixes. OpenSSL remains the
default backend; the comparison nginx uses OpenSSL, with the same config text.

## Measurement scope after integration

The published [raw evidence](evidence/2026-11-12-https-h1/README.md) belongs to
candidate commit `68f0b57`, before merging the newer HTTP/2, HTTP/3 and ACME code.
The integration commits receive functional validation, but have not repeated
this performance series. The figures below must not be attributed to a different
binary. Older exploratory run links refer to locally retained, untracked results.

## Final acceptance — all five scenarios pass

[20261112-032358](evidence/2026-11-12-https-h1/RESULTS.md) contains all 90 samples:
six repetitions, three servers, five scenarios. Keep-alive samples run for
15 seconds after a 3-second warmup; full-handshake samples use 12,000 requests.
Four server CPUs (0–3), eight client CPUs (4–11), 12 GiB guest RAM. Resumption
is disabled identically for every server. The baseline is the saved AWS-LC
1.73.0 binary from before this iteration, not a selected intermediate build.

The [strict gate](evidence/2026-11-12-https-h1/gate.txt) requires median successful
RPS >=1.5x nginx, median per-run p99 <= nginx AND the saved baseline, complete
repetitions and zero HTTP/client errors. All conditions pass, without rounding
or dropping samples. All requests in the 90 samples succeeded.

| Workload | Previous RPS | nginx RPS | Final RPS | Gain vs nginx | p99 final / nginx / previous, ms |
|---|---:|---:|---:|---:|---:|
| 612 B, c64 | 639,976 | 394,629 | 662,954 | +68.0% | 0.210900 / 0.285503 / 0.215876 |
| 612 B, c256 | 730,055 | 398,511 | 762,323 | +91.3% | 0.567494 / 0.906196 / 0.578444 |
| 1 MiB, c64 | 12,183 | 7,835 | 13,284 | +69.5% | 6.877 / 11.810 / 7.399 |
| 100 MiB, c64 | 105.88 | 72.75 | 122.17 | +67.9% | 677.831 / 2695.802 / 1809.438 |
| Full TLS handshake, c64 | 37,196 | 19,000 | 39,864 | +109.8% | 3.692 / 9.295 / 4.459 |

100 MiB p99 is 74.9% below nginx and 62.5% below the previous build.
Small-response p99 is 2.3% and 1.9% below the previous build at c64/c256;
those margins are smaller and run-to-run variation remains. This pass concerns
the declared medians, not every individual repetition or every future run.
The [acceptance data](evidence/2026-11-12-https-h1/acceptance.json) includes ranges.

The [process monitor](evidence/2026-11-12-https-h1/host-monitor.jsonl) records 225
samples with no competing benchmark/build jobs in the other benchmark VM.
Normal host applications and infrastructure VMs remain active. In 1,254
[memory samples](evidence/2026-11-12-https-h1/memory.jsonl), available RAM stays
above 7.92 GiB and OHA's peak RSS is 2.98 GiB. Instrumented profiling and
functional tests ran separately from the performance series.

Final binary SHA-256:
`71cd276274950a17db742c7d881d8ea765a20d9c31d630a8f51bb8d6cd00daee`.
Shared rendered config SHA-256:
`27ecdbe2b948f055519143b6f578e617bc00c78f29b8d13069e85f7742b5f159`.
The result directory also retains source hashes, functional/upstream test logs,
and wire probes. Earlier failures and incomplete runs are documented below;
none are omitted from the investigation or used as acceptance evidence.

## Quiet repeat and 100 MiB fairness correction

The repeat [20261112-000537](results/20261112-000537/RESULTS.md) ran after the
other benchmark had stopped. Normal host apps and infrastructure VMs remained
active; this is not a dedicated idle host. Four server CPUs (0–3), eight client
CPUs (4–11), four 15-second repetitions and 3-second warmup. All servers used
the same full-handshake config (session cache and tickets off). All requests
succeeded. Baseline is the saved OpenSSL binary; candidate is the previous
AWS-LC 1.73.0 build before the fairness change.

| Workload | Baseline RPS | nginx RPS | Candidate RPS | vs nginx | p99 candidate / nginx / baseline, ms |
|---|---:|---:|---:|---:|---:|
| 1 MiB, c64 | 7,623 | 6,940 | 10,100 | 1.455x | 11.206 / 13.631 / 12.741 |
| 100 MiB, c64 | 75.03 | 70.43 | 100.67 | 1.429x | 1698.321 / 2989.931 / 2578.916 |
| Full TLS handshake, c64 | 17,003 | 18,015 | 35,334 | 1.961x | 4.467 / 11.004 / 12.008 |

The earlier p99 regression did not reproduce. The two file scenarios still
fail the throughput target. Full handshakes pass both throughput and p99.

Source inspection found that zhttpd could drain an entire writable file in one
turn, whereas nginx bounds its send chain using `sendfile_max_chunk`, including
TLS. zhttpd now supports the directive with nginx's 2 MiB default and posts an
explicit continuation when its budget expires. `0` disables the budget. Reads
are bounded before SSL_write, preserving retry lengths and plaintext contents.

Screening [20261112-001341](results/20261112-001341/RESULTS.md) directly compares
the previous candidate with this change, same four-worker setup, three
8-second repetitions. All requests succeeded.

| Workload | Previous RPS | nginx RPS | Budgeted RPS | vs nginx | p99 budgeted / nginx / previous, ms |
|---|---:|---:|---:|---:|---:|
| 1 MiB, c64 | 10,740 | 7,163 | 10,845 | 1.514x | 8.470 / 12.215 / 9.319 |
| 100 MiB, c64 | 99.45 | 73.24 | 102.48 | 1.399x | 805.815 / 2584.887 / 1738.576 |

100 MiB p99 improves 53.7% against the previous candidate, but its RPS gate
still fails. Guest CPU sampling shows all four server workers saturated while
the eight-CPU client uses approximately 4.3–5.2 CPUs: no measured evidence
supports blaming a saturated load generator for the remaining gap.

Rejected follow-ups: adaptive 256 KiB buffers for files >=8 MiB
([20261112-002139](results/20261112-002139/RESULTS.md)) gave only 1.314x nginx;
explicit `-Dcpu=apple_m3` ([20261112-002655](results/20261112-002655/RESULTS.md))
regressed both throughput and p99 against the budgeted build. Neither is
retained. These early screens used 96 KiB plaintext/ciphertext buffers.

## AWS-LC 5.14.0 screening

[20261112-003503](results/20261112-003503/RESULTS.md) compares the budgeted
AWS-LC 1.73.0 build against 5.14.0 with Linux Apple CPU recognition: four workers,
three 8-second repetitions, identical full-handshake config. 1 MiB reaches
1.613x nginx and 100 MiB reaches 1.462x. p99 is respectively 0.652x and 0.276x
nginx, and 0.928x and 0.936x the 1.73.0 baseline. All requests succeed.
An instrumented 100 MiB run confirms `aesv8_gcm_8x_enc_256` executes (39.96% CPU);
kernel/user copies account for 21.17%, and userspace memcpy for 7.09%.

Switching to the system compiler runtime
([20261112-004138](results/20261112-004138/RESULTS.md)) reaches only 1.488x nginx
and worsens p99 by 14.6% against the preceding candidate: rejected.
Removing ciphertext buffering while retaining 96 KiB file reads
([20261112-004529](results/20261112-004529/RESULTS.md)) also reduces throughput:
100 MiB falls from 105 to 92 RPS, and 1 MiB from 10,799 to 9,181 RPS. Rejected.

A `tcp_nopush` implementation using scoped TCP_CORK/TCP_NOPUSH
([20261112-005018](results/20261112-005018/RESULTS.md), four repetitions) also
reported 100 MiB median 100 vs 105 RPS and 1 MiB 10,867 vs 11,100 RPS.
A subsequently inspected process start time shows that another task began
benchmarking in the shared VM during this series. It is **not a clean comparison**
and cannot establish a performance regression. The experiment passed functional
tests on Linux/macOS but was reverted for lack of isolated performance evidence.
The directive remains ignored; do not claim full nginx configuration parity.

The attempted full series `20261112-010748` was interrupted after the process
monitor detected a restarted HTTP/3 benchmark in the other VM. It is incomplete
and marked `INVALID.txt`; no acceptance claim uses it. Subsequent runs wait for
pending benchmark scripts as well as active servers/clients/compilers and stop
the owned benchmark process group if competing work appears during a sample.

## Aligned reads and separate buffer sizes

The aligned-read change yields before a send-budget boundary would split a
staged read. This avoids letting the response header offset every later read
from a page boundary. A diagnostic trace of one 100 MiB response changes from
1,101 pread calls (50 short non-final reads, 1,079 unaligned offsets) to 1,067
calls (zero short non-final reads or unaligned offsets), with exactly
104,857,600 file bytes read in each case. Small configured budgets still make
progress; final reads and unaligned range requests retain their semantics.

Four 10-second repetitions in
[20261112-014532](results/20261112-014532/RESULTS.md) compare aligned 96 KiB
staging against the preceding build. 1 MiB reaches 1.609x nginx, 100 MiB only
1.464x. The 100 MiB p99 is 0.977x the preceding build; the syscall reduction
alone does not establish a throughput improvement.

Using 128 KiB for both buffers
([20261112-015317](results/20261112-015317/RESULTS.md)) reaches 1.654x nginx at
1 MiB and 1.489x at 100 MiB, but 1 MiB p99 increases 6.2% against aligned
96 KiB. It does not pass the combined gate.

Separating plaintext reads (128 KiB) from ciphertext batching (192 KiB),
[20261112-020123](results/20261112-020123/RESULTS.md), reaches 1.690x nginx
at 1 MiB and 1.510x at 100 MiB. The 100 MiB p99 is 0.286x nginx and 0.944x
the 128/128 build. The 1 MiB p99 is 0.650x nginx but 1.033x that intermediate
build: this screen also does not establish the overall target. Final acceptance
compares every scenario against nginx and the saved pre-iteration binary,
not selected intermediate experiments.

The first full 15-second series with this build (`20261112-021139`) is invalid:
the 4 GiB guest's OOM killer terminated OHA at c256 (about 3.4 GiB client RSS).
No server failure was observed. The owned guest was increased to 12 GiB,
keeping the same 12 vCPUs, server config and binaries for the full repeat.
Memory sampling accompanies that repeat; incomplete/OOM samples are not used
for acceptance.

## Full repeat with client memory headroom

[20261112-022120](results/20261112-022120/RESULTS.md) completed all 60 samples:
four workers, four 15-second repetitions, 3-second warmup, unchanged binaries
and config, now in the 12 GiB guest. The saved pre-iteration AWS-LC 1.73.0
binary (`e76de71d…`) is the baseline. Every request succeeded.

| Workload | Previous RPS | nginx RPS | Candidate RPS | vs nginx | p99 candidate / nginx / previous, ms |
|---|---:|---:|---:|---:|---:|
| 612 B, c64 | 639,703 | 394,539 | 627,812 | 1.591x | 0.219332 / 0.297623 / 0.212728 |
| 612 B, c256 | 725,474 | 401,119 | 708,222 | 1.766x | 0.589769 / 0.904629 / 0.588933 |
| 1 MiB, c64 | 12,177 | 7,875 | 13,129 | 1.667x | 6.731 / 10.391 / 7.063 |
| 100 MiB, c64 | 106.23 | 72.95 | 122.05 | 1.673x | 680.742 / 2654.670 / 1975.925 |
| Full TLS handshake, c64 | 37,471 | 18,835 | 39,894 | 2.118x | 3.817 / 10.486 / 4.460 |

The 100 MiB scenario passes: +67.3% throughput, p99 74.4% below nginx and
65.5% below the previous build. The full gate still fails: small-response p99
is 3.10% higher at c64 and 0.14% higher at c256 than the previous build.
These small differences are not rounded down to declare a pass.

The process monitor records 150 samples with no competing benchmark/build
jobs in the other benchmark VM. Normal host applications and infrastructure
VMs remain active. In 805 memory samples, available guest RAM stays above
8.33 GiB and OHA's peak RSS is 2.55 GiB. Raw process and memory logs accompany
the results. These observations establish client memory headroom, not a
dedicated physical host or a guarantee for other hardware.

A subsequent small-response profile attributes 0.56% CPU to `ERR_clear_error`.
The pinned AWS-LC source already resets errors in `SSL_do_handshake`,
`ssl_read_impl` and `SSL_write`; zhttpd was redundantly clearing before those
calls. The follow-up removes only the redundant AWS-LC clears. OpenSSL and
explicit BIO flushing retain their clears. A regression test seeds unrelated
errors before handshake/read/write and requires WANT_READ with an empty error
queue; it passes before and after the AWS-LC change and with the unchanged
OpenSSL error-clearing path.

The small-response follow-up
[20261112-024040](results/20261112-024040/RESULTS.md) reaches 1.690x nginx at
c64 and 1.846x at c256. p99 is still 1.001x and 1.023x the pre-iteration
baseline: the redundant-clear removal alone does not pass the gate.

Replacing the general formatter with direct, NUL-terminated concatenation in
`mapUri` preserves root/alias path bytes and ownership while avoiding format
processing for each lookup. In
[20261112-031053](results/20261112-031053/RESULTS.md), c256 reaches 1.903x nginx
with p99 0.992x baseline; c64 reaches 1.647x but p99 is 1.045x baseline.
This is another failed combined gate, not an acceptance result.

An eight-sample diagnostic records per-worker connection counts and CPU ticks.
At c64, a baseline sample has [7, 23, 11, 23] connections per worker and p99
0.236 ms, versus 0.208–0.213 ms in its other samples. The new build ranges
0.206–0.219 ms. All workers are near CPU saturation. This demonstrates
run-to-run distribution variation, without proving that every remaining tail
difference is noise. Instrumented samples are excluded from acceptance.

The final follow-up also caches one formatted ETag per worker, keyed by both
file timestamp and size. It does not cache response contents or change
open-file-cache validation. Unit cases cover independent timestamp/size changes
and signed timestamp extremes. HTTP/TLS checks revalidate changed files and
assert both ETag bytes and 200/304 conditional responses. The full repeat uses
six repetitions, declared before running, to reduce dependence on four random
connection distributions.

## Historical measurements

Each table compares servers within one complete series, using one rendered
nginx.conf. RPS and p99 are medians of four alternating-order repetitions.
The gate requires successful RPS >=1.5x nginx, p99 <= nginx AND the saved
zhttpd baseline, complete repetitions, and zero HTTP/client errors.

**Earlier full-handshake configuration, AWS-LC 1.73.0, one worker:**
[20261111-221749](results/20261111-221749/RESULTS.md).
All compared servers disable both session cache and tickets; cipher/group and
all other TLS settings stay unchanged. Server CPU 0, client CPUs 1–7, four
12,000-request repetitions at c64. All requests succeeded.

| Server | Successful RPS | p99 ms |
|---|---:|---:|
| Saved OpenSSL baseline | 4,865 | 14.227 |
| nginx | 4,893 | 14.302 |
| AWS-LC 1.73.0 build | 9,762 | 11.273 |

**PASS:** throughput +99.5% vs nginx; p99 21.2% below nginx and 20.8% below
baseline. The [wire probe](results/20261111-221749/tls-wire-full.json) verifies that tickets-off connections perform
full TLS 1.3 handshakes, rather than resuming a previous session.

**Earlier full-handshake configuration, AWS-LC 1.73.0, four workers:**
[20261111-221121](results/20261111-221121/RESULTS.md).
Same retained binary, server CPUs 0–3, client CPUs 4–11; four 10-second
keep-alive repetitions with 3-second warmup. Resumption is disabled for every
server in this series, including the keep-alive scenarios.

| Workload | Baseline RPS | nginx RPS | zhttpd RPS | vs nginx | p99 zhttpd / nginx / baseline, ms |
|---|---:|---:|---:|---:|---:|
| 612 B, c64 | 358,759 | 303,515 | 307,275 | 1.012x | 1.051 / 0.663 / 0.686 |
| 612 B, c256 | 377,945 | 357,033 | 536,712 | 1.503x | 2.414 / 2.295 / 4.361 |
| 1 MiB, c64 | 6,331 | 6,127 | 8,796 | 1.436x | 21.227 / 18.094 / 24.360 |
| Full TLS handshake, c64 | 13,626 | 14,965 | 22,414 | 1.498x | 13.568 / 12.499 / 15.271 |

All 48 samples completed without HTTP/client errors, but **every scenario fails
the combined throughput/p99 gate**. In particular, 1 MiB p99 is 12.9% below the
saved baseline but 17.3% above nginx. The full-handshake rate is just below 1.5x;
it is not rounded up into a pass, and its p99 also fails against nginx.

During this series the host also ran another VM using roughly 5.5 CPU cores,
another using about 0.6 core, and unrelated native apps. nginx c64 throughput
ranged from 207,470 to 341,426 RPS. This is an environment limitation and a
reason to repeat on reserved hardware, not a reason to waive failed results.
Per-guest CPU affinity cannot reserve physical host cores. Further four-worker
acceptance needs a stable dedicated Linux CPU/memory budget; changing crypto or
scheduling code solely to chase these noisy samples is not justified evidence.

**Earlier resumption-enabled configuration, AWS-LC 1.73.0, one worker:**
[20261111-215234](results/20261111-215234/RESULTS.md).
Server CPU 0, client CPUs 1–7; 10-second keep-alive samples, 3-second warmup.

| Workload | Baseline RPS | nginx RPS | zhttpd RPS | vs nginx | p99 zhttpd / nginx / baseline, ms |
|---|---:|---:|---:|---:|---:|
| 612 B, c64 | 149,839 | 122,732 | 178,955 | 1.458x | 0.497 / 0.714 / 0.597 |
| 612 B, c256 | 132,842 | 112,579 | 169,123 | 1.502x | 1.966 / 2.973 / 2.536 |
| 1 MiB, c64 | 2,120 | 1,904 | 3,027 | 1.590x | 23.233 / 37.061 / 34.235 |
| New connections, resumption enabled, c64 | 5,165 | 5,228 | 9,783 | 1.871x | 10.760 / 13.307 / 13.432 |

All 48 samples completed without HTTP/client errors. All latency checks pass;
the c64 small-response throughput check fails. Candidate small-response RPS
ranges from 158,530 to 187,003, so the medians are not a hardware capacity guarantee.
Candidate SHA-256: `e76de71d9afe6ee2b4ce74366616d5e43be014e5bd8bbcdd620c2821dff7a279`.

**Four-worker series before bounded buffer reuse:**
[20261111-213452](results/20261111-213452/RESULTS.md).
Server CPUs 0–3, client CPUs 4–11; 10-second samples, 5-second warmup.
This candidate used a local inline ciphertext copy; the retained build uses
ordinary memcpy and additionally reuses one spare buffer per worker.

| Workload | Baseline RPS | nginx RPS | zhttpd RPS | vs nginx | p99 zhttpd / nginx / baseline, ms |
|---|---:|---:|---:|---:|---:|
| 612 B, c64 | 488,642 | 373,392 | 563,950 | 1.510x | 0.327 / 0.434 / 0.305 |
| 612 B, c256 | 523,297 | 409,204 | 651,392 | 1.592x | 1.345 / 1.129 / 0.879 |
| 1 MiB, c64 | 7,840 | 7,339 | 10,224 | 1.393x | 10.994 / 13.496 / 12.181 |
| New connections, resumption enabled, c64 | 18,394 | 19,850 | 32,826 | 1.654x | 3.593 / 9.152 / 10.719 |

The resumption-enabled row passes every condition. Large-file p99 passes, but throughput
fails. Small-response p99 fails against the baseline at both concurrency levels,
and against nginx at c256. A one-worker result must not be presented as proof of
four-worker scaling or absence of four-worker small-response tail regressions.

The earlier large-file latency correction was measured with **default OpenSSL**:
[20261111-224857](results/20261111-224857/RESULTS.md), four workers, four 10-second
repetitions, 64 KiB plaintext/ciphertext batching. RPS: zhttpd 10,425,
nginx 8,378, baseline 8,838. p99: 8.443 / 10.686 / 12.917 ms respectively.
This is +24.4% throughput, with p99 21.0% below nginx and 34.6% below baseline.
It predates the current buffer sizes; it isolates the latency fix from the
later TLS backend change.

## Retained implementation

- Large HTTPS file responses use bounded 128 KiB file-read and 192 KiB ciphertext
  buffers, with aligned staged reads and a configurable 2 MiB default send
  budget per event-loop turn. TLS record sizes and encryption are unchanged. Backpressure retains
  pending bytes; a response finishes only after the ciphertext buffer flushes.
  The filter is removed before the next response. Allocation failure falls back
  to the original 16 KiB path. Plain HTTP keeps its sendfile path.
- In the AWS-LC build, buffer reuse retains at most one plaintext and one ciphertext spare per worker,
  at most 320 KiB of requested buffer capacity, independently of the number of
  idle connections. Concurrent large responses
  each own their active buffers. No response-content cache was added; files
  are still read and validated through the existing file-cache rules.
- Optional AWS-LC 5.14.0 uses public APIs through a typed C adapter. Its POSIX FD
  BIO avoids the socket BIO's SO_ERROR query before each read/write. The adapter
  implements the bounded output filter because AWS-LC does not supply BIO_f_buffer.
- Certificate chains come from the configured certificate file, as with nginx;
  NO_AUTO_CHAIN avoids rebuilding them on each handshake. Partial writes and
  the backend's normal buffer-release behavior remain enabled.
- Ticket keys are initialized before workers fork. A regression test requires
  resumption across distinct worker PIDs. Automatic key rotation remains enabled;
  in this AWS-LC release it runs after 48 hours per worker. After rotation, some
  cross-worker tickets can fall back to full handshakes. No fixed ticket keys or
  crypto-algorithm downgrades are used to improve the benchmark.
- Prior changes remain: encrypted-read readiness tracking on Linux after the
  first keep-alive response, deferred handshake work, a fair posted-continuation
  queue, hot-field layout, metadata-only request reset, read-ahead, borrowed
  normalized paths, and Last-Modified formatting cache. Later changes add
  direct root/alias path concatenation, a bounded ETag formatting cache, and
  removal of redundant error clears for AWS-LC's synchronous TLS operations.

An earlier 100-request, 1 MiB [syscall trace](results/20261111-221121/pooled-allocation-trace.txt) dropped from 6,400 pread calls and about
6,500 writes before batching to 1,101 pread calls and 1,107 writes (including
the readiness probe) with 96 KiB batching. The FD BIO eliminates getsockopt
calls in that trace. Bounded reuse reduced brk calls from 205 to 7. Instrumented
runs are diagnostic; they are not the throughput measurements above.

## Build and comparison conditions

```bash
bash scripts/build-aws-lc.sh
zig build -Doptimize=ReleaseFast -Dtls=true -Dtls-backend=aws_lc \
  -Dopenssl="$PWD/deps/aws-lc-install"
```

OpenSSL is still the default. Omit `-Dtls-backend=aws_lc` and use the OpenSSL
installation prefix to switch back. AWS-LC is pinned to commit
`7821a7544c6dce1bb5fc927aa273d4ee7a536988`. The build script applies only the
versioned Linux Apple CPU-detection patch and rejects any other tracked changes.
The patch reads the MIDR implementer only when Linux reports CPUID support;
instruction capabilities remain independently gated by HWCAP. Released AES-GCM
assembly and algorithms are unchanged. This enables the existing 8x AES-GCM
path on Apple Silicon Linux guests, matching upstream's macOS CPU selection.
The implementer value is defined by [Linux](https://github.com/torvalds/linux/blob/master/tools/arch/arm64/include/asm/cputype.h).
The upstream [5.14.0 release](https://github.com/aws/aws-lc/releases/tag/v5.14.0)
is pinned; no unmerged upstream crypto patch is included. This backend covers this branch's HTTP/1.1 server;
it does not supply OpenSSL's QUIC/provider APIs for other branches.

- Zig 0.17.1 ReleaseFast, nginx 1.30.6 with OpenSSL 3.5.9, oha 1.16.0.
  The optional candidate changes TLS implementation; it does **not** use the
  same TLS library as nginx. Default OpenSSL comparisons use the same library.
- Linux 6.8.0-134 aarch64. The final-series VM `zhttpd-tls-perf` has 12 vCPUs and
  12 GiB RAM on a shared M3 Max host; earlier screens used 4 GiB. Earlier OpenSSL diagnostics used
  `zhttpd-bench` with 8 vCPUs. Another task later used that VM, so subsequent
  measurements moved to the isolated guest. Other host VMs/apps remain active;
  guest CPU affinity does not reserve physical host cores.
- Historical OpenSSL baseline: commit `68b7f82` plus the prior read-ahead, path-borrowing and
  Last-Modified-formatting changes, linked against OpenSSL 3.5.9.
  Baseline SHA-256: `1563443b812dedcf65e33f4c8fb72d5b84ff69de321dd8794eb1a7ee77393e89`.
  The final acceptance baseline is the previous AWS-LC 1.73.0 candidate,
  SHA-256 `e76de71d9afe6ee2b4ce74366616d5e43be014e5bd8bbcdd620c2821dff7a279`.
- Same certificate, TLS 1.3, file cache, keep-alive limits, HTTP/1.1, files,
  and disabled access logs. Wire probing confirms AES-256-GCM and
  X25519MLKEM768 for both TLS backends with this oha binary. kTLS is disabled.
- Config text is identical within each series, but pre-existing compatibility
  gaps remain: nginx's shared TLS session cache is process-local in zhttpd,
  and tcp_nopush is ignored. Identical config does not mean complete nginx parity.
- New-connection samples use 12,000 requests at c64, with keep-alive disabled.
  With tickets enabled, oha reuses sessions: these are NOT full-handshake-only
  measurements. A 10-connection wire probe found one full handshake followed
  by nine resumed handshakes for each server. With session cache and tickets
  disabled identically for all servers, all ten handshakes were full, with
  unchanged cipher and key-exchange group. Full-handshake results are separate.
  Keep-alive samples use oha's wait-for-completion option and a 10-second timeout.
  Each result directory includes the config, binary hashes, environment,
  scenario manifest and individual JSON samples. UTC timestamps from the new
  VM and EET timestamps from the old VM are not directly chronological.

## Rejected experiments and limits

- Increasing both large-response buffers to 256 KiB reduced throughput in two
  diagnostic series (`212017`, `212826`); not retained.
- Disabling partial TLS writes, a local inline copy, and using the system
  compiler runtime did not establish an overall improvement; not retained.
  Reducing AWS-LC read-ahead to 512 bytes after the first response gave no
  consistent c64 gain (154,658 vs 155,359 RPS in `220438`); not retained.
  Runtime experiment `220130` overlapped a build at its end and is not an
  acceptance measurement.
- A per-connection 64 KiB write budget worsened large-file throughput/p99 in
  the earlier iteration; not retained.
- kTLS/sendfile showed isolated throughput gains, but the TLS 1.3 KeyUpdate
  regression test failed on both zhttpd and nginx with that kernel/OpenSSL
  combination. All kTLS implementation experiments were removed.
- The [large-response CPU profile](results/20261111-221121/large-profile.txt) attributes about 46% to AES-GCM, 17% to
  kernel/user copying and 7% to userspace memcpy. This explains where further
  profiling should focus; it is not proof of a hard performance ceiling.

## Verification

Final unit checks passed with TLS disabled and with both TLS backends on
macOS, and with both TLS backends on Linux. Both backends passed the following
functional checks on both systems. Linux rebuild SHA-256 matches the measured
candidate exactly. Shellcheck, the gate regression tests, error-page tests, and
git diff --check passed.

Functional checks cover both TLS 1.2 and 1.3: fragmented encrypted headers and
records, 600 pipelined requests, body draining, HEAD/ranges, unaligned large
ranges, 8 MiB slow-reader responses, exact SHA-256 checks of 100 MiB HTTP/TLS
responses followed by keep-alive/pipelined requests, interrupted transfers, idle partial records,
file changes, ETag invalidation by timestamp/size with conditional 200/304
responses, TCP half-close, and both TLS 1.3 KeyUpdate modes. Configuration
checks cover SNI rejection, allowed/disallowed ciphers and groups, ticket
resumption on/off, and resumption across workers. The output-BIO unit test forces
repeated short writes and EAGAIN through a 37-byte peer buffer and checks exact
byte preservation. Buffer-lifetime tests check ownership, fallback and leaks.

Reproduce with [PLAN.md](PLAN.md). Run
`python3 bench/check-target.py bench/results/STAMP 1.5` for each complete series.
Raw directories are local gitignored artifacts. The work remains in
`/Users/listepo/apps/_worktrees/zhttpd-perf-nginx-50`, branch `codex/perf-nginx-50`.

The AWS-LC 5.14.0 Linux CPU-detection patch also passes 510 upstream tests
covering AEAD, AES/GCM, ECDSA/ECDH and bignum operations (one test is disabled
upstream). The final wire probe covers nginx, the OpenSSL baseline, the previous
AWS-LC 1.73.0 build and the new build: AES-256-GCM/X25519MLKEM768 throughout,
0/10 resumptions with tickets/cache off and 9/10 with resumption enabled.
