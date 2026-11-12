# Memory acceptance evidence — 2026-11-12

Baseline: `12ce969d1653258455c2be756c97a2f6148d0b7b`.
Candidate: source fingerprints in `SOURCE-SHA256.txt`, plus the OpenSSL patch
at `deps/patches/openssl-quic-stream-gc.patch`.

The binaries use Zig 0.17.1 ReleaseFast with TLS, HTTP/2 and HTTP/3 enabled.
The saved baseline uses original OpenSSL 3.5.9; the candidate uses the same
version with the stream-GC patch. nginx 1.30.6 also reports OpenSSL 3.5.9.
Each suite's `env.txt` records binary SHA-256 values, build information,
load-tool version, timing, CPU affinity and repetitions. The Linux aarch64
Lima VM has 8 CPUs and 4 GiB RAM. One master and one worker are measured for
all servers; the server uses CPU 0 and oha uses CPUs 1–7.

Each suite directory contains the rendered shared configuration, scenario
manifest, all oha JSON samples and memory/CPU sidecars, execution order,
load snapshots, throughput report and memory/regression gate output.
The `.json.err` files end with the measurement metadata. Configuration paths
refer to the original guest workspace; no private keys are included.

An earlier HTTP/1.1 and HTTP/2 series overlapped another task's benchmark on
the same VM. Those series were discarded from acceptance evidence and rerun
with exclusive use of the VM. The accepted HTTP/3 series began after the
other task stopped its load. Measurements from different suites have separate
server lifetimes; scenario order within each suite is preserved.

See `../../MEMORY-OPTIMIZATION.md` for the precise budget and its scope.
