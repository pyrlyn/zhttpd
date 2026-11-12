#!/usr/bin/env python3
"""The performance gate must never accept missing data or a p99 regression."""
import csv
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

gate = Path(__file__).resolve().parents[1] / 'bench/check-target.py'
with tempfile.TemporaryDirectory(prefix='zhttpd-gate-') as tmp:
    root = Path(tmp)
    (root / 'env.txt').write_text('reps=2\n')
    scenario = 'https-small-ka-c64'
    (root / 'scenarios.txt').write_text(scenario + '|https|1|64|/static/small.html\n')
    rows = []
    for server, count, p99 in [('zhttpd', 6000, .001), ('nginx', 4000, .002), ('zhttpd-baseline', 5000, .0015)]:
        for rep in (1, 2):
            name = f'{server}.{rep}.json'
            (root / name).write_text(json.dumps({
                'summary': {'total': 10}, 'statusCodeDistribution': {'200': count},
                'errorDistribution': {}, 'latencyPercentiles': {'p99': p99},
            }))
            rows.append({'scenario': scenario, 'server': server, 'rep': rep, 'file': name})

    def write_rows(items):
        with (root / 'runs.csv').open('w') as out:
            writer = csv.DictWriter(out, fieldnames=rows[0].keys())
            writer.writeheader()
            writer.writerows(items)

    def check(expected):
        result = subprocess.run([sys.executable, str(gate), str(root)], capture_output=True, text=True)
        assert result.returncode == expected, result.stdout + result.stderr

    write_rows(rows)
    check(0)
    with tempfile.TemporaryDirectory(prefix='zhttpd-gate-external-') as external_dir:
        external = Path(external_dir) / 'sample.json'
        external.write_text((root / rows[0]['file']).read_text())
        link = root / 'linked.json'
        link.symlink_to(external)
        for name in (str(external), os.path.relpath(external, root), link.name):
            escaped = [dict(row) for row in rows]
            escaped[0]['file'] = name
            write_rows(escaped)
            check(1)
        link.unlink()
    write_rows(rows)
    check(0)
    sample = root / 'zhttpd.1.json'
    original = sample.read_text()
    for tail in (.004, .0025, float('inf')):
        data = json.loads(original)
        data['latencyPercentiles']['p99'] = tail
        sample.write_text(json.dumps(data))
        check(1)  # includes a regression only against baseline, not nginx
    data = json.loads(original)
    data['errorDistribution'] = {'timeout': 1}
    sample.write_text(json.dumps(data))
    check(1)
    data = json.loads(original)
    data['statusCodeDistribution']['200'] = 5000
    sample.write_text(json.dumps(data))
    check(1)
    sample.write_text(original)
    write_rows(rows[:-1])
    check(1)
    write_rows(rows)
    with (root / 'scenarios.txt').open('a') as out:
        out.write('https-large-ka-c64|https|1|64|/static/large.bin\n')
    check(1)
print('PASS: throughput, p99 vs nginx/baseline, errors, missing repetitions/scenarios, sample path confinement')
