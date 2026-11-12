import csv,json,statistics
from pathlib import Path
root=max(Path('bench/results').iterdir(),key=lambda p:p.name)
rows=list(csv.DictReader((root/'runs.csv').open()))
for scenario in sorted({r['scenario'] for r in rows}):
 tails={}
 for server in ['zhttpd-baseline','zhttpd']:
  samples=[r for r in rows if r['server']==server and r['scenario']==scenario]
  assert len(samples)==4
  tails[server]=statistics.median(json.loads((root/r['file']).read_text())['latencyPercentiles']['p99'] for r in samples)
 ratio=tails['zhttpd']/tails['zhttpd-baseline']
 print(f'Baseline p99 check: {scenario} {ratio:.6f}x',flush=True)
 if ratio>1: raise SystemExit(3)
