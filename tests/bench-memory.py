#!/usr/bin/env python3
"""Memory acceptance rejects missing/invalid evidence and performance regressions."""
import csv
import json
from pathlib import Path
import subprocess
import sys
import tempfile

GATE = Path(__file__).resolve().parents[1] / 'bench/check-memory.py'
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / 'env.txt').write_text('reps=2\n')
    (root / 'scenarios.txt').write_text('http-small|http|1|64|/small\n')
    rows = []
    for server, memory in [('zhttpd', 800), ('nginx', 1000), ('zhttpd-baseline', 2000)]:
        for rep in (1, 2):
            name = f'{server}.{rep}.json'
            (root / name).write_text(json.dumps({
                'summary': {'total': 1}, 'statusCodeDistribution': {'200': 1000},
                'errorDistribution': {}, 'latencyPercentiles': {'p99': .001},
            }))
            (root / (name + '.err')).write_text(json.dumps({'server_memory': {
                'samples': 20, 'processes': 2, 'peak_rss_kib': memory, 'peak_pss_kib': memory,
            }}))
            rows.append({'scenario': 'http-small', 'server': server, 'rep': rep, 'file': name})
    def write_rows(items):
        with (root / 'runs.csv').open('w') as stream:
            writer = csv.DictWriter(stream, fieldnames=rows[0])
            writer.writeheader()
            writer.writerows(items)
    def check(code):
        result = subprocess.run([sys.executable, str(GATE), str(root)], capture_output=True, text=True)
        assert result.returncode == code, result.stdout + result.stderr
    write_rows(rows)
    check(0)
    meta = root / 'zhttpd.1.json.err'
    original_meta = meta.read_text()
    for key, value in [('peak_rss_kib', 1100), ('peak_pss_kib', 1100),
                       ('peak_pss_kib', float('nan')), ('samples', 0), ('processes', 1), ('processes', 3)]:
        data = json.loads(original_meta)
        data['server_memory'][key] = value
        meta.write_text(json.dumps(data))
        check(1)
    meta.unlink()
    check(1)
    meta.write_text(original_meta)
    sample = root / 'zhttpd.1.json'
    original = sample.read_text()
    for change in ('errors', 'rate', 'tail'):
        data = json.loads(original)
        if change == 'errors': data['errorDistribution'] = {'timeout': 1}
        if change == 'rate': data['summary']['total'] = 2
        if change == 'tail': data['latencyPercentiles']['p99'] = .003
        sample.write_text(json.dumps(data))
        check(1)
    sample.write_text(original)
    write_rows(rows[:-1]); check(1)
    write_rows(rows + [rows[0]]); check(1)
    write_rows([r for r in rows if r['server'] != 'zhttpd-baseline']); check(1)
    escaped = [dict(r) for r in rows]
    escaped[0]['file'] = str(sample)
    write_rows(escaped); check(1)
    write_rows(rows); check(0)
    with (root / 'scenarios.txt').open('a') as stream: stream.write('missing|http|1|64|/small\n')
    check(1)
print('PASS: memory budget, throughput/p99 regression, errors, invalid or missing evidence')
