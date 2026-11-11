#!/usr/bin/env python3
"""Fail unless every measured scenario reaches the requested nginx RPS ratio.

Usage: python3 bench/check-target.py bench/results/STAMP [ratio, default 1.5]
Requires complete repetitions, zero errors, and median p99 no worse than nginx.
CSV sample names must refer to regular files directly in the results directory.
"""
import csv
import json
import math
import os
from pathlib import Path
import re
import statistics
import sys

# The operator selects the working directory; CSV data may only select files
# already present there, never supply paths for filesystem reads.
os.chdir(sys.argv[1])  # NOSONAR(S8707) - the local CLI operator explicitly selects this directory.
root = Path('.')
sample_paths = {p.name: p for p in root.iterdir() if not p.is_symlink() and p.is_file()}
target = float(sys.argv[2]) if len(sys.argv) > 2 else 1.5
if not target > 0:
    raise SystemExit("ratio must be positive")
match = re.search(r"\breps=(\d+)\b", (root / "env.txt").read_text())
if match is None:
    raise SystemExit("env.txt is missing the expected repetition count")
reps = int(match[1])
rows = list(csv.DictReader((root / "runs.csv").open()))
scenarios = sorted({row["scenario"] for row in rows})
manifest = root / 'scenarios.txt'
if manifest.exists():
    expected = {line.split('|')[0] for line in manifest.read_text().splitlines() if line}
    if set(scenarios) != expected:
        raise SystemExit('FAIL: measured scenarios do not match scenarios.txt')
passed = bool(scenarios) and reps > 0
for scenario in scenarios:
    rps = {}
    p99 = {}
    try:
        servers = ['zhttpd', 'nginx']
        if any(r['server'] == 'zhttpd-baseline' for r in rows):
            servers.append('zhttpd-baseline')
        for server in servers:
            samples = [r for r in rows if r["scenario"] == scenario and r["server"] == server]
            if {int(r["rep"]) for r in samples} != set(range(1, reps + 1)) or len(samples) != reps:
                raise ValueError(f"{server}: missing or duplicate repetitions")
            rates = []
            tails = []
            for row in samples:
                sample = sample_paths.get(row["file"])
                if sample is None:
                    raise ValueError(f"{server}: sample must be a regular file in the results directory: {row['file']!r}")
                data = json.loads(sample.read_text())
                codes = data["statusCodeDistribution"]
                if any(v for k, v in codes.items() if not k.startswith("2")) or any(data["errorDistribution"].values()):
                    raise ValueError(f"{server}: HTTP or load-generator errors")
                count = sum(codes.values())
                elapsed = data["summary"]["total"]
                if count <= 0 or not math.isfinite(elapsed) or elapsed <= 0:
                    raise ValueError(f"{server}: empty sample")
                rates.append(count / elapsed)
                tail = data['latencyPercentiles']['p99']
                if not math.isfinite(tail) or not tail > 0:
                    raise ValueError(f"{server}: invalid p99")
                tails.append(tail)
            rps[server] = statistics.median(rates)
            p99[server] = statistics.median(tails)
        ratio = rps["zhttpd"] / rps["nginx"]
        tail_ratio = p99['zhttpd'] / p99['nginx']
        baseline_tail_ratio = p99['zhttpd'] / p99.get('zhttpd-baseline', p99['nginx'])
        ok = ratio >= target and tail_ratio <= 1.0 and baseline_tail_ratio <= 1.0
        print(f"{'PASS' if ok else 'FAIL'} {scenario}: RPS {ratio:.3f}x (required {target:.3f}x), p99 {tail_ratio:.3f}x nginx, {baseline_tail_ratio:.3f}x baseline (required <=1.000x)")
        passed &= ok
    except (ValueError, KeyError, OSError) as exc:
        print(f"FAIL {scenario}: {exc}")
        passed = False
sys.exit(0 if passed else 1)
