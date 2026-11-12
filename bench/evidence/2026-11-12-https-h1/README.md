# HTTPS HTTP/1.1 benchmark evidence

These are all 90 raw samples from the isolated six-repeat run on 2026-11-12.
`env.txt` records binary hashes, toolchain, worker count and CPU affinity;
`nginx.conf` is the exact shared configuration. `gate.txt` and `acceptance.json`
contain the strict median successful-RPS and p99 comparison.

The measured candidate corresponds to the HTTP/1.1 implementation saved in
commit `68f0b57`, before integration with the newer HTTP/2, HTTP/3 and ACME code.
These measurements do **not** constitute a new benchmark of the integration
commits. Integration is covered by build, unit, TLS I/O and CI protocol checks.

`monitor-summary.json` summarizes the retained local process/memory traces.
The full host process trace is intentionally not published because it lists
unrelated local applications. TLS wire probes use only generated test certificates.
