# HTTP/3 throughput evidence — 2026-11-12

Measured runtime: `e96eb9b`. Main baseline: `94f5e3d`.

- `h2/`: primary four-repetition matrix, run `20261112-152253`.
- `h3/`: primary four-repetition matrix, run `20261112-152752`.
- `metrics.json`: medians from all 60 primary samples.
- `h2-small-control/`: 12 additional fixed-count comparisons, run `20261112-153852`, and pooled summaries including the original four comparisons.
- `environment/`: exact source/library/binary/input hashes, commands and process audit. The host snapshot is aggregated to omit application identities.
- `validation/`: Linux Debug/ReleaseFast, macOS ReleaseFast and the successful 12-job CI result for the measured runtime.
- `prior-1f029c9/`, `prior-f432058/`, `prior-2113509/`: superseded measurements, including the failing p99 results that motivated further changes.
- `diagnostics/`: exploratory profiles and variant screens; these do not replace final acceptance measurements.

Both primary `target-gate.txt` files have exit code 1. The suite-wide target remains unmet. Only the primary 1 MiB HTTP/3 scenario passes all three conditions: 1.5× nginx successful RPS, p99 no worse than nginx and p99 no worse than main. Extended HTTP/2 controls are explicitly separate from this gate.

The source commits and the existing benchmark scripts reproduce inputs. Historical commands contain their original absolute paths; adapt those paths when rebuilding. Private certificate keys and executable binaries are not included.
