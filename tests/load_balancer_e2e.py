#!/usr/bin/env python3
"""Real workers, shared metrics, 307 uploads, loop prevention and backend loss."""
import base64
import http.client
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit
from e2e_common import free_port, running

BINARY = Path(sys.argv[1]).resolve()


class Echo(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        result = dict(method=self.command, path=self.path,
                      body=base64.b64encode(body).decode())
        self.calls.append(result)
        data = json.dumps(result).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_PUT = do_PATCH = do_DELETE = do_POST

    def log_message(self, *_):
        pass


def request(port, target='/', method='GET', body=None, headers=None):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
    try:
        conn.request(method, target, body, headers or {})
        response = conn.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        conn.close()


def eventually(predicate, label, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError(label)


def eventually_stable(predicate, label, duration=.4, timeout=10):
    since = None

    def stable():
        nonlocal since
        if not predicate():
            since = None
            return False
        if since is None:
            since = time.monotonic()
        return time.monotonic() - since >= duration

    eventually(stable, label, timeout)


def hold(port, count):
    return [socket.create_connection(('127.0.0.1', port), timeout=3) for _ in range(count)]


def close_all(sockets):
    for sock in sockets:
        sock.close()
    sockets.clear()


def main():
    with tempfile.TemporaryDirectory(prefix='zhttpd-lb-') as directory:
        root = Path(directory)
        backend = root / 'metrics'
        backend.mkdir()
        a, b, upstream = free_port(), free_port(), free_port()
        echo = http.server.ThreadingHTTPServer(('127.0.0.1', upstream), Echo)
        thread = threading.Thread(target=echo.serve_forever, daemon=True)
        thread.start()
        held_a, held_b = [], []
        try:
            for node, port, capacity in [('a', a, 8), ('b', b, 32)]:
                (root / f'{node}.toml').write_text(f'''[server]
compatibility = "self"
[http]
listen = "127.0.0.1:{port}"
[[http.routes]]
path = "/"
proxy = "http://127.0.0.1:{upstream}"
[load_balancer]
enabled = true
node_id = "{node}"
backend = "metrics"
node_ids = ["a", "b"]
node_urls = ["http://127.0.0.1:{a}", "http://127.0.0.1:{b}"]
interval_ms = 100
ttl_ms = 3000
max_connections = {capacity}
memory_limit_mb = 4096
cpu_capacity = 2
''')
            ca = [BINARY, '-c', root / 'a.toml', '-g', 'worker_processes 2;']
            cb = [BINARY, '-c', root / 'b.toml']
            for command in (ca, cb):
                subprocess.run([*command, '-t'], check=True, capture_output=True)
            invalid = subprocess.run([BINARY, '-c', root / 'a.toml', '-g',
                'worker_processes 257;', '-t'], capture_output=True)
            assert invalid.returncode != 0 and b'at most 256 workers' in invalid.stderr
            with running(ca, a) as master_a, running(cb, b):
                eventually(lambda: len(list(backend.glob('a.*.load'))) == 2 and
                           len(list(backend.glob('b.*.load'))) == 1, 'worker metrics missing')
                assert request(a)[0] == 200
                held_a = hold(a, 12)
                eventually(lambda: request(a)[0] == 307, 'A did not shed load')
                # Both worker records contribute to the instance total.
                records = [p.read_text().split() for p in backend.glob('a.*.load')]
                assert len(records) == 2 and sum(int(r[3]) for r in records) >= 12
                assert all(int(r[4]) > 0 and float(r[5]) >= 0 for r in records)
                target = '/echo%2Fraw?x=%26&x=2'
                body = b'POST body\x00\xff\r\n'
                status, headers, _ = request(a, target, 'POST', body)
                assert status == 307 and headers['Cache-Control'] == 'no-store'
                location = headers['Location']
                assert location == f'http://127.0.0.1:{b}{target}&__zhttpd_lb=1', location
                # A real redirect-following client must replay the original method/body.
                before = len(Echo.calls)
                result = subprocess.run(['curl', '--silent', '--show-error', '--fail',
                    '--location', '--max-redirs', '2', '--write-out', '\n%{num_redirects}', '--data-binary', '@-',
                    f'http://127.0.0.1:{a}{target}'], input=body, capture_output=True, check=True)
                response_body, redirects = result.stdout.rsplit(b'\n', 1)
                assert redirects == b'1', result.stdout
                assert json.loads(response_body) == dict(method='POST', path=target,
                    body=base64.b64encode(body).decode())
                assert len(Echo.calls) == before + 1
                for method in ('PUT', 'PATCH', 'DELETE'):
                    status, headers, _ = request(a, target, method, body)
                    assert status == 307
                    redirected = urlsplit(headers['Location'])
                    status, _, data = request(b, redirected.path + '?' + redirected.query, method, body)
                    assert status == 200 and json.loads(data)['method'] == method
                    assert json.loads(data)['body'] == base64.b64encode(body).decode()
                # Expect uploads receive a final 307 without sending their body.
                with socket.create_connection(('127.0.0.1', a), timeout=3) as sock:
                    sock.sendall(b'POST /echo HTTP/1.1\r\nHost: test\r\nContent-Length: 999999\r\nExpect: 100-continue\r\n\r\n')
                    assert sock.recv(4096).startswith(b'HTTP/1.1 307 ')
                # Reverse the load while the client is between redirect hops.
                close_all(held_a)
                held_b = hold(b, 40)
                eventually(lambda: request(b)[0] == 307, 'B did not shed load to A')
                redirected = urlsplit(location)
                status, _, data = request(b, redirected.path + '?' + redirected.query, 'POST', body)
                assert status == 200 and json.loads(data)['path'] == target
                # No healthy destination: serve locally even when all nodes are busy.
                held_a = hold(a, 12)
                eventually_stable(lambda: request(a)[0] == request(b)[0] == 200, 'all-overloaded fallback failed')
                close_all(held_b)
                eventually(lambda: request(a)[0] == 307, 'peer recovery failed')
                # Suspend B's worker: its stale heartbeat must expire.
                peer_record = next(backend.glob('b.*.load'))
                peer_pid = int(peer_record.name.split('.')[1])
                # Stopping just the worker exercises stale records without mutating them.
                os.kill(peer_pid, signal.SIGSTOP)
                stopped = time.monotonic()
                try:
                    eventually_stable(lambda: time.monotonic() - stopped >= 3.1 and request(a)[0] == 200,
                                      'stale peer remained eligible', timeout=10)
                finally:
                    os.kill(peer_pid, signal.SIGCONT)
                eventually(lambda: request(a)[0] == 307, 'peer did not recover after pause')
                # Missing shared storage invalidates cached decisions and recovers.
                moved = root / 'offline'
                backend.rename(moved)
                eventually_stable(lambda: request(a)[0] == 200, 'backend failure did not fall back')
                moved.rename(backend)
                eventually(lambda: request(a)[0] == 307, 'backend recovery failed')
                # Reload safely starts a new set of collectors and retires old files.
                old = set(p.name for p in backend.glob('a.*.load'))
                close_all(held_a)
                os.kill(master_a.pid, signal.SIGHUP)
                eventually(lambda: len(list(backend.glob('a.*.load'))) == 2 and
                           not old.intersection(p.name for p in backend.glob('a.*.load')),
                           'reload retained old worker records')
                assert request(a)[0] == 200
            eventually(lambda: not list(backend.glob('*.load')), 'shutdown left metrics files')
        finally:
            close_all(held_a)
            close_all(held_b)
            echo.shutdown()
            echo.server_close()
    print('PASS: aggregate metrics, 307 method/body, one-hop limit, stale peers, backend failure, reload and cleanup')


if __name__ == '__main__':
    main()
