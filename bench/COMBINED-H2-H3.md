# Combined HTTP/2 + HTTP/3 target check — 2026-11-13

This report measures main `56ec652`, which contains both:
- pyrlyn/zhttpd#6: HTTP/2 userspace TLS record sealing ([H2-TLS-TX.md](H2-TLS-TX.md)).
- pyrlyn/zhttpd#5: HTTP/3 over the native zquic transport ([ZQUIC-H3.md](ZQUIC-H3.md)).

Each PR was measured on its own before; this is the first measurement with both in one binary.

The target: in every HTTP/2 and HTTP/3 scenario,
- successful RPS is at least 1.6 times nginx;
- median sample p99 is no worse than nginx;
- median sample p99 is no worse than the saved main baseline (`a539d24`, before either PR).

**The target is met in all six scenarios.**

## What was measured

The binary was built from a local rebase of #6 onto #5's head `5075467`. When conflicts were resolved, `multiplex.c` became HTTP/2-only, as #5 made it. Concretely:
- the single-pass `response_headers` keeps only the nghttp2 path;
- the stream sweep unmaps the file window without any nghttp3 cleanup;
- `tls_tx.c` is linked into #5's `h2-codec-test`.

The QUIC session's merge of main into #5 (`875f411`) produced the identical tree, as does main `56ec652` after #5 merged: `git diff` against the measured tree is empty.

## Verification

Results on Linux aarch64 ReleaseFast for the measured tree:

| Suite | Result |
|---|---|
| Build steps | 42/42 succeeded |
| Unit tests, including zquic transport | 101/101 pass |
| HTTP/2 codec test | passes |
| HTTP/2 large bodies across TLS 1.3 KeyUpdate, both modes | passes |
| HTTP/1.1, HTTP/2 and HTTP/3 protocol suite | passes |
| Application/policy assertions | 193 pass |

The protocol suite includes migration, loss, reordering, reload and shutdown.

The QUIC session reran the suites on `875f411` in Debug and ReleaseFast. PR #5's CI passed on `875f411` except for the macOS job, which was cancelled when the PR merged.

## Method

Same as [H2-TLS-TX.md](H2-TLS-TX.md):

- **Machine:** Lima VM `zhttpd-bench`, kernel 6.8.0-149.
- **Toolchain:** Zig 0.17.1, OpenSSL 3.5.9, nghttp2 1.71.0, nginx 1.30.6, completion-draining oha 1.16.0.
- **Pinning:** one worker on CPU 0; client on CPUs 1–7.
- **Configuration:**
  - 16 streams per connection, TLS 1.3 only.
  - Kernel kTLS is off for both servers.
  - nginx serves HTTP/3 with `listen … quic reuseport`.
- **Sampling:** 10-second samples after 2 s of warmup, five repetitions with alternating server order. Results are medians of per-sample successful RPS and p99.
- **Lock:** all runs held the shared bench lock.

All 90 samples (45 per protocol) completed with only 2xx responses and no load-generator errors. Binary hashes are in `environment/`.

## Results

`python3 bench/check-target.py <dir> 1.6` passes all six scenarios.

Successful RPS (median):

| Scenario | main `a539d24` | nginx | zhttpd `56ec652` | vs nginx | vs main |
|---|---:|---:|---:|---:|---:|
| h2-large-ka-c4-p16 | 2,576 | 1,977 | 3,786 | **1.915×** | +47.0% |
| h2-small-ka-c16-p16 | 364,884 | 199,132 | 406,095 | **2.039×** | +11.3% |
| h2-small-ka-c4-p16 | 350,403 | 197,074 | 392,751 | **1.993×** | +12.1% |
| h3-large-ka-c4-p16 | 1,023 | 649 | 2,172 | **3.347×** | +112.3% |
| h3-small-ka-c16-p16 | 170,433 | 235,019 | 541,379 | **2.304×** | +217.6% |
| h3-small-ka-c4-p16 | 168,345 | 248,209 | 479,907 | **1.933×** | +185.1% |

Median sample p99:

| Scenario | p99 vs nginx | p99 vs main |
|---|---:|---:|
| h2-large-ka-c4-p16 | 0.439× | 0.690× |
| h2-small-ka-c16-p16 | 0.534× | 0.924× |
| h2-small-ka-c4-p16 | 0.496× | 0.825× |
| h3-large-ka-c4-p16 | 0.239× | 0.587× |
| h3-small-ka-c16-p16 | 0.495× | 0.281× |
| h3-small-ka-c4-p16 | 0.607× | 0.412× |

Median peak process-tree PSS, in MiB:

| Scenario | main | nginx | zhttpd |
|---|---:|---:|---:|
| h2-large-ka-c4-p16 | 10.5 | 15.8 | 10.9 |
| h2-small-ka-c16-p16 | 9.2 | 15.7 | 9.3 |
| h2-small-ka-c4-p16 | 8.2 | 15.0 | 8.3 |
| h3-large-ka-c4-p16 | 28.1 | 31.8 | 14.9 |
| h3-small-ka-c16-p16 | 13.4 | 22.1 | 9.5 |
| h3-small-ka-c4-p16 | 9.4 | 16.2 | 8.2 |

Combining the PRs did not cost either protocol its separate gain:
- HTTP/2 is within single-run noise of the HTTP/2-only matrix (1.83–1.93×; this VM swings about 5–10% between runs).
- HTTP/3 is within noise of the zquic-only re-check (2.03–3.45×).

## Limits

These are loopback results from one VM with a single pinned worker. They are not a production-network guarantee.

**Not run** on the combined tree:
- macOS suites (the macOS CI job on `875f411` was cancelled);
- sanitizer builds;
- Linux Debug, except the QUIC session's run.

Raw samples, configurations and binary hashes are in [the evidence directory](evidence/2026-11-13-combined-h2-h3/).
