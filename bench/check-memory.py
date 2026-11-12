#!/usr/bin/env python3
"""Gate complete Linux memory samples and performance against the saved baseline."""
import argparse
import csv
import json
import math
from pathlib import Path
import re
import statistics
import sys


def positive(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
        raise ValueError(f'invalid positive measurement: {value!r}')
    return value


def check(root, memory_ratio=.9, rps_ratio=.95, p99_ratio=1.1):
    paths = {p.name: p for p in root.iterdir() if p.is_file() and not p.is_symlink()}
    env = (root / 'env.txt').read_text()
    match = re.search(r'\breps=(\d+)\b', env)
    if not match or int(match[1]) < 2:
        raise ValueError('at least two repetitions required')
    reps = int(match[1])
    expected = {line.split('|')[0] for line in (root / 'scenarios.txt').read_text().splitlines() if line}
    with (root / 'runs.csv').open() as stream:
        rows = list(csv.DictReader(stream))
    if not expected or {r['scenario'] for r in rows} != expected:
        raise ValueError('measured scenarios do not match manifest')
    if len({r['file'] for r in rows}) != len(rows):
        raise ValueError('duplicate sample files')
    servers = ('zhttpd', 'nginx', 'zhttpd-baseline')
    if {r['server'] for r in rows} != set(servers):
        raise ValueError('candidate, nginx and saved baseline are all required')
    passed = True
    print('scenario | peak PSS KiB (candidate/nginx/baseline) | RSS ratio | PSS ratio | RPS vs baseline | p99 vs baseline')
    for scenario in sorted(expected):
        values = {}
        processes = set()
        for server in servers:
            selected = [r for r in rows if r['scenario'] == scenario and r['server'] == server]
            if len(selected) != reps or {int(r['rep']) for r in selected} != set(range(1, reps + 1)):
                raise ValueError(f'{scenario}/{server}: missing or duplicate repetitions')
            measurements = []
            for row in selected:
                name = row['file']
                if name not in paths or name + '.err' not in paths:
                    raise ValueError('sample and sidecar must be regular files in results directory')
                data = json.loads(paths[name].read_text())
                codes = data['statusCodeDistribution']
                if any(v for k, v in codes.items() if not k.startswith('2')) or any(data['errorDistribution'].values()):
                    raise ValueError(f'{name}: HTTP/client errors')
                count = positive(sum(codes.values()))
                rate = count / positive(data['summary']['total'])
                p99 = positive(data['latencyPercentiles']['p99'])
                meta = json.loads(paths[name + '.err'].read_text().splitlines()[-1])
                mem = meta['server_memory']
                if (type(mem['samples']) is not int or mem['samples'] < 10 or
                        type(mem['processes']) is not int or mem['processes'] < 2):
                    raise ValueError(f'{name}: insufficient samples or missing workers')
                processes.add(mem['processes'])
                measurements.append({
                    'rps': rate, 'p99': p99,
                    'rss': positive(mem['peak_rss_kib']),
                    'pss': positive(mem['peak_pss_kib']),
                })
            values[server] = {key: statistics.median(m[key] for m in measurements) for key in measurements[0]}
        if len(processes) != 1:
            raise ValueError(f'{scenario}: unequal process counts')
        candidate, nginx, baseline = (values[server] for server in servers)
        rss = candidate['rss'] / nginx['rss']
        pss = candidate['pss'] / nginx['pss']
        rate = candidate['rps'] / baseline['rps']
        tail = candidate['p99'] / baseline['p99']
        ok = (rss <= memory_ratio and pss <= memory_ratio and
              candidate['rss'] <= baseline['rss'] and candidate['pss'] <= baseline['pss'] and
              rate >= rps_ratio and tail <= p99_ratio)
        passed &= ok
        print(f"{'PASS' if ok else 'FAIL'} {scenario} | "
              f"{candidate['pss']:.0f}/{nginx['pss']:.0f}/{baseline['pss']:.0f} | "
              f'{rss:.3f} | {pss:.3f} | {rate:.3f} | {tail:.3f}')
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    parser.add_argument('--memory-ratio', type=float, default=.9)
    parser.add_argument('--rps-ratio', type=float, default=.95)
    parser.add_argument('--p99-ratio', type=float, default=1.1)
    args = parser.parse_args()
    try:
        ratios = [positive(v) for v in (args.memory_ratio, args.rps_ratio, args.p99_ratio)]
        return 0 if check(args.results, *ratios) else 1
    except (ValueError, KeyError, OSError, TypeError, IndexError) as exc:
        print(f'FAIL: {exc}')
        return 1


if __name__ == '__main__':
    sys.exit(main())
