#!/usr/bin/env python3
"""Assert records and reopening, not just successful config parsing."""
import http.client
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from e2e_common import free_port, running

binary = Path(sys.argv[1]).resolve()

def request(port, target='/probe'):
    client = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    client.request('GET', target, headers={'User-Agent': 'quote"slash\\test'})
    r = client.getresponse(); r.read(); client.close()
    return r.status

def wait_text(path):
    for _ in range(100):
        if path.exists() and path.stat().st_size:
            return path.read_text()
        time.sleep(.02)
    raise AssertionError(f'no records in {path}')

with tempfile.TemporaryDirectory(prefix='zhttpd-logging-') as d:
    root = Path(d); port = free_port(); log = root/'access.log'; err = root/'errors.log'
    (root/'probe').write_text('hello')
    config = root/'config.toml'
    for mode in ('self', 'nginx', 'apache', 'litespeed', 'caddy'):
        if log.exists(): log.unlink()
        if err.exists(): err.unlink()
        source = root/'server.conf'
        if mode == 'self':
            config.write_text(f'''[server]
compatibility = "self"
[http]
listen = "127.0.0.1:{port}"
root = "."
[logging]
access = "access.log"
format = "json"
error = "errors.log"
level = "error"
''')
        else:
            config.write_text(f'[server]\ncompatibility="{mode}"\nconfig="server.conf"\n')
            if mode == 'nginx':
                source.write_text(f'events {{}} http {{ log_format test escape=json \'{{"uri":"$request_uri","agent":"$http_user_agent","status":$status}}\'; server {{ listen 127.0.0.1:{port}; root "{root}"; access_log "{log}" test; error_log "{err}" error; }} }}')
            elif mode == 'apache':
                source.write_text(f'Listen 127.0.0.1:{port}\nDocumentRoot "{root}"\nLogFormat "%h %>s %{{User-Agent}}i" test\nCustomLog "{log}" test\nErrorLog "{err}"\nLogLevel error\n')
            elif mode == 'caddy':
                source.write_text(f'http://localhost:{port} {{\nroot * "{root}"\nfile_server\nlog {{\noutput file "{log}"\nformat json\n}}\n}}\n')
            else:
                (root/'vhost.conf').write_text(f'docRoot "{root}"\naccesslog "{log}" {{\nuseServer 0\nlogFormat "%h %>s %{{User-Agent}}i"\n}}\nerrorlog "{err}" {{\nlogLevel ERROR\n}}\n')
                source.write_text(f'virtualhost site {{\nvhRoot "{root}"\nconfigFile "{root}/vhost.conf"\n}}\nlistener http {{\naddress 127.0.0.1:{port}\nmap site *\n}}\n')
        with running([binary, '-c', config], port) as process:
            assert request(port) == 200, mode
            text = wait_text(log)
            if mode in ('self', 'caddy', 'nginx'):
                record = json.loads(text.splitlines()[-1])
                assert record['uri'] == '/probe' and record['status'] == 200, (mode,record)
                if mode == 'nginx': assert record['agent'] == 'quote"slash\\test', record
            else:
                assert '127.0.0.1 200 quote\\x22slash\\x5Ctest' in text, (mode,text)
            rotated = root/'rotated.log'
            log.replace(rotated)
            os.kill(process.pid, signal.SIGUSR1)
            for _ in range(100):
                request(port)
                # Reopening creates an empty file; a racing request may still
                # use the old descriptor. Keep sending until a record arrives.
                if log.exists() and log.stat().st_size: break
                time.sleep(.03)
            wait_text(log)
            assert request(port, '/missing') == 404
            if mode != 'caddy': assert '/missing' in wait_text(err), (mode, err.read_text())
        # Module switch applies to imported settings as well.
        config.write_text('[modules]\nlogging=false\n'+config.read_text().split('[logging]')[0])
        log.unlink()
        with running([binary, '-c', config], port):
            request(port)
        assert not log.exists(), mode
print('PASS: five logging adapters, JSON/percent escaping, scoped error logs, USR1 reopen, module switch')
