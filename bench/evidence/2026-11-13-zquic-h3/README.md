# Evidence map

Candidate: `de3180b` (branch `quic-zig-quic-transport`). Baseline: main `a539d24`,
built from an identical `src/` + `build.zig` tree (see `environment/source-commit.txt`).

- `final/20261113-124029`: four-repetition HTTP/3 matrix (baseline, nginx, candidate);
  raw oha JSON, CPU/memory `.err` sidecars, `runs.csv`, `load.log`, `nginx.conf`, `RESULTS.md`.
- `summary.json`: medians of successful RPS, p99, peak process-tree PSS and server CPU, with the
  1.6× + p99 gate per scenario (same rules as `bench/check-target.py`).
- `environment/`: kernel and VM shape, binary hashes, source commits.
- `profiles/`: flat CPU-clock profiles at c4 and c16 and syscall counts at c4 on `de3180b`;
  one c4 profile from before the Huffman memo, kept for comparison.
- `exploratory/`: the failing full matrix of 00:53 (c4 1.578× nginx, before the early flush) and
  an earlier two-repetition screen. Paired A/B ratios in the report come from shorter scratch runs
  that are not part of the final matrix.
- `validation/`: Linux Debug and ReleaseFast protocol-suite logs, and the example `h3-server`
  under aioquic and oha. macOS ReleaseFast was not run (see the report).

Every measurement ran under `flock ~/zhttpd-bench.lock`, so no other session's build or bench overlapped it.
