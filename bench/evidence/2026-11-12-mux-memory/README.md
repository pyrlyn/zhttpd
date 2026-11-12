# Evidence map

Runtime: de0d0de; source package with added wire test: 6e5868a.
Baseline: main f146b20 (runtime-equivalent saved e96eb9b binary).

- `final/20261112-164808`: four-repetition HTTP/2 matrix.
- `final/20261112-165308`: four-repetition HTTP/3 matrix.
- `control/20261112-170227`: 12 additional large-H3 repetitions per server;
  original four are included in the pooled result in `control-summary.json`.
- `summary.json`: primary medians and strict target result. Original failures
  remain failures, including the primary +0.4% large-H3 p99 increase.
- `profiles/`: baseline and candidate CPU-clock profiles (499 Hz, 10 s load).
- `environment/`: primary source/binary hashes and two-second VM process
  snapshots; aggregate host CPU samples start during the first server block.
- `control-environment/`: additional latency series metadata and process audit.
- `validation/`: Linux/macOS tests, sanitizer output, Raft before/after proof,
  previous-main shutdown failure and branch CI status. The first ACME attempt
  failed on an occupied temporary port; its isolated retry passed.

Exploratory screens are separate from the primary matrix:

| Directory | Variant |
|---|---|
| `20261112-162007` | system libgcc/libc, H2 |
| `20261112-162123` | system libgcc/libc, H3 |
| `20261112-162244` | 96 KiB plaintext batch and 16 KiB initial input, H2 |
| `20261112-162400` | same, H3 |
| `20261112-162534` | 4 KiB QPACK table, H3 |
| `20261112-163101` | compact buffers, H2 |
| `20261112-163218` | compact buffers, H3 |
| `20261112-163722` | direct H2 files and UDP ordinary batching, H2 |
| `20261112-163839` | same, H3 |
| `20261112-164142` | direct files plus 96 KiB plaintext batching, H2 |
| `20261112-164258` | same, H3 |
