#!/usr/bin/env python3
"""Run one bounded load sample; record CPU and Linux process-tree RSS/PSS.

Called by run.sh: measure.py TIMEOUT SERVER_PID LOAD_COMMAND [ARG ...].
Memory includes the master and every worker, sampled every 50 ms. PSS counts
shared pages proportionally; RSS also remains available for comparison.
"""
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import sys
import time


def process_tree(pid):
    result = [pid]
    for child in Path(f'/proc/{pid}/task/{pid}/children').read_text().split():
        result.extend(process_tree(int(child)))
    return result


def server_cpu(pid):
    if not Path('/proc').is_dir():
        return None
    total = 0
    for process in process_tree(pid):
        fields = Path(f'/proc/{process}/stat').read_text().rsplit(')', 1)[1].split()
        total += int(fields[11]) + int(fields[12])
    return total / os.sysconf('SC_CLK_TCK')


def server_memory(pids):
    totals = {'rss_kib': 0, 'pss_kib': 0}
    for pid in pids:
        fields = {}
        for line in Path(f'/proc/{pid}/smaps_rollup').read_text().splitlines():
            key, _, value = line.partition(':')
            if key in ('Rss', 'Pss'):
                fields[key] = int(value.split()[0])
        if set(fields) != {'Rss', 'Pss'} or fields['Pss'] <= 0:
            raise ValueError(f'invalid smaps_rollup for {pid}')
        totals['rss_kib'] += fields['Rss']
        totals['pss_kib'] += fields['Pss']
    return totals


def main():
    timeout, pid = float(sys.argv[1]), int(sys.argv[2])
    linux = sys.platform == 'linux'
    pids = process_tree(pid) if linux else []
    before = server_cpu(pid)
    started = time.monotonic()
    samples = []
    with subprocess.Popen(sys.argv[3:]) as process:
        try:
            while process.poll() is None:
                if time.monotonic() - started >= timeout:
                    raise subprocess.TimeoutExpired(process.args, timeout)
                if linux:
                    if process_tree(pid) != pids:
                        raise ValueError('server process tree changed during sample')
                    samples.append(server_memory(pids))
                try:
                    process.wait(timeout=.05)
                except subprocess.TimeoutExpired:
                    pass
        except BaseException:
            process.kill()
            process.wait()
            raise
    elapsed = time.monotonic() - started
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    after = server_cpu(pid)
    memory = None
    if samples:
        memory = {'samples': len(samples), 'processes': len(pids), 'interval_ms': 50}
        for key in ('rss_kib', 'pss_kib'):
            memory['peak_' + key] = max(s[key] for s in samples)
            memory['median_' + key] = statistics.median(s[key] for s in samples)
    print(json.dumps({
        'elapsed': elapsed,
        'client_cpu_cores': (usage.ru_utime + usage.ru_stime) / elapsed,
        'server_cpu_cores': (after - before) / elapsed if before is not None else None,
        'server_memory': memory,
    }), file=sys.stderr)
    return process.returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        print(f'load measurement failed: {exc}', file=sys.stderr)
        sys.exit(1)
