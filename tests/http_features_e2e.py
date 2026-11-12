#!/usr/bin/env python3
"""Native API and TOML policies over real HTTP, using only Python's stdlib."""
import base64
import gzip
import hashlib
import hmac
import http.client
import json
import os
import ssl
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from e2e_common import free_port, running

BINARY, APP = (Path(p).resolve() for p in sys.argv[1:3])
SECRET = b'0123456789abcdef0123456789abcdef'
checks = 0
secure_port = None


def request(port, path='/', method='GET', body=None, headers=None):
    conn = (http.client.HTTPSConnection('127.0.0.1', port, timeout=4, context=ssl._create_unverified_context()) if port == secure_port else http.client.HTTPConnection('127.0.0.1', port, timeout=4))
    try:
        conn.request(method, path, body=body, headers=headers or {})
        res = conn.getresponse()
        return res.status, res.getheaders(), res.read()
    finally:
        conn.close()


def connect(port):
    sock = socket.create_connection(('127.0.0.1', port), timeout=3)
    return ssl._create_unverified_context().wrap_socket(sock, server_hostname='localhost') if port == secure_port else sock


def expect(port, path='/', method='GET', body=None, headers=None, status=200):
    global checks
    result = request(port, path, method, body, headers)
    assert result[0] == status, (path, method, result)
    checks += 1
    return result


def token(header=None, secret=SECRET, **overrides):
    payload = dict(iss='issuer', aud='app', sub='alice', exp=int(time.time()) + 60, scope='read write')
    payload.update(overrides)
    enc = lambda value: base64.urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).rstrip(b'=')
    data = enc(header or {'alg': 'HS256', 'typ': 'JWT'}) + b'.' + enc(payload)
    return (data + b'.' + base64.urlsafe_b64encode(hmac.digest(secret, data, 'sha256')).rstrip(b'=')).decode()


def native():
    port = free_port()
    with running([APP, f'127.0.0.1:{port}'], port):
        for method in ('POST', 'PUT', 'DELETE', 'PATCH'):
            _, headers, body = expect(port, '/json', method, '{"value":42}', {'Content-Type': 'application/json'})
            assert json.loads(body) == {'value': 42}
            assert dict(headers)['X-Middleware-After'] == 'after'
        expect(port, '/json', 'GET', status=405)
        expect(port, '*', 'OPTIONS', status=204)
        _, _, body = expect(port, '/json', 'POST', 'invalid', {'Content-Type': 'application/json'}, 400)
        assert json.loads(body)['error']['status'] == 400
        expect(port, '/json', 'POST', '{}', status=415)
        _, _, body = expect(port, '/query?x=a%2Bb&x=a+b&empty')
        assert [v['value'] for v in json.loads(body)] == ['a+b', 'a b', '']
        expect(port, '/query?x=%ZZ', status=400)
        _, _, body = expect(port, '/form', 'POST', 'a=1&a=2', {'Content-Type': 'application/x-www-form-urlencoded'})
        assert len(json.loads(body)) == 2
        upload = b'--xyz\r\nContent-Disposition: form-data; name="f"; filename="a.bin"\r\nContent-Type: application/octet-stream\r\n\r\nhello\r\n--xyz--\r\n'
        _, _, body = expect(port, '/form', 'POST', upload, {'Content-Type': 'multipart/form-data; boundary="xyz"'})
        assert json.loads(body)[0]['filename'] == 'a.bin'
        quoted = upload.replace(b'a.bin', b'a;b.bin')
        assert json.loads(expect(port, '/form', 'POST', quoted, {'Content-Type': 'multipart/form-data; boundary=xyz'})[2])[0]['filename'] == 'a;b.bin'
        expect(port, '/form', 'POST', upload[:-10], {'Content-Type': 'multipart/form-data; boundary=xyz'}, 400)
        _, headers, body = expect(port, '/cookies', headers={'Cookie': 'sid=abc; other=1'})
        cookies = [v for k, v in headers if k.lower() == 'set-cookie']
        assert len(cookies) == 2 and all('Secure; HttpOnly' in v and 'SameSite=Lax' in v for v in cookies)
        assert 'Max-Age=0' in cookies[1] and json.loads(body)['cookie'] == 'abc'
        _, _, body = expect(port, '/fail', status=500)
        assert json.loads(body) == {'error': {'status': 500, 'message': 'Internal Server Error'}}
        expect(port, '/missing', status=404)
        expect(port, '/items', 'POST', b'one', status=400)
        key = {'Idempotency-Key': 'test-operation'}
        first = expect(port, '/items', 'POST', b'one', key, 201)
        again = expect(port, '/items', 'POST', b'one', key, 201)
        assert first[2] == again[2] and dict(again[1])['Idempotency-Replayed'] == 'true'
        assert int(dict(again[1])['X-Middleware-Calls']) == int(dict(first[1])['X-Middleware-Calls']) + 1
        assert [k for k, v in again[1]].count('X-Middleware-After') == 1
        expect(port, '/items', 'POST', b'two', key, 409)
        assert json.loads(expect(port, '/items')[2])['writes'] == 1
        large = json.dumps({'text': 'hello ' * 1000})
        result = expect(port, '/json', 'POST', large, {'Content-Type': 'application/json', 'Accept-Encoding': 'gzip'})
        assert dict(result[1])['Content-Encoding'] == 'gzip'
        assert json.loads(gzip.decompress(result[2])) == json.loads(large)
        result = expect(port, '/json', 'POST', large, {'Content-Type': 'application/json', 'Accept-Encoding': 'gzip;q=0, *;q=1'})
        assert 'Content-Encoding' not in dict(result[1])
        expect(port, '/json', 'POST', b'a' * (1024 * 1024 + 1), {'Content-Type': 'application/json'}, 413)
        # Reserve capacity before effects; entries cannot be silently evicted to execute again.
        for i in range(127):
            expect(port, '/items', 'POST', b'one', {'Idempotency-Key': str(i)}, 201)
        expect(port, '/items', 'POST', b'one', {'Idempotency-Key': 'overflow'}, 503)
        assert json.loads(expect(port, '/items')[2])['writes'] == 128


def configured():
    global secure_port
    with tempfile.TemporaryDirectory(prefix='zhttpd-features-') as directory:
        root = Path(directory)
        (root / 'secret').write_bytes(SECRET + b'\n')
        (root / 'large.txt').write_bytes(b'hello ' * 1000)
        port = free_port()
        config = root / 'config.toml'
        config.write_text(f'''[server]
compatibility = "self"
auto_reload = true
[http]
listen = "127.0.0.1:{port}"
root = "."
json_errors = true
gzip = true
max_body_size = 32
header_timeout_ms = 150
body_timeout_ms = 150
health_path = "/health"
[[http.routes]]
path = "/method"
match = "exact"
methods = ["GET"]
response = "get"
[[http.routes]]
path = "/method"
match = "exact"
methods = ["POST", "PUT", "DELETE", "PATCH"]
response = "write"
[[http.routes]]
path = "/private"
response = "secret"
jwt_secret_file = "secret"
jwt_issuer = "issuer"
jwt_audience = "app"
jwt_scope = "read"
[[http.routes]]
path = "/cors"
response = "cors"
methods = ["GET", "POST"]
cors_origins = ["https://app.example"]
cors_credentials = true
[[http.routes]]
path = "/rate"
response = "ok"
rate_limit = 1
rate_burst = 2
[[http.routes]]
path = "/discard"
response = "ok"
''')
        if os.environ.get('HTTP_FEATURES_TLS') == '1':
            openssl = os.environ.get('OPENSSL_CLI', 'openssl')
            subprocess.run([openssl, 'req', '-config', os.devnull, '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-days', '1', '-subj', '/CN=localhost', '-keyout', str(root / 'key.pem'), '-out', str(root / 'cert.pem')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            config.write_text(config.read_text().replace('[[http.routes]]', '[http.tls]\ncertificate="cert.pem"\nkey="key.pem"\n[[http.routes]]', 1))
            secure_port = port
        with running([BINARY, '-c', config], port):
            assert json.loads(expect(port, '/health')[2]) == {'status': 'ok'}
            expect(port, '/health', 'POST', status=405)
            assert expect(port, '/method')[2] == b'get'
            for method in ('POST', 'PUT', 'DELETE', 'PATCH'):
                assert expect(port, '/method', method)[2] == b'write'
            assert not expect(port, '/method', 'HEAD')[2]
            _, headers, _ = expect(port, '/method', 'OPTIONS', status=405)
            assert set(dict(headers)['Allow'].split(', ')) == {'GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'PATCH'}
            expect(port, '/private', status=401)
            expect(port, '/private', headers={'Authorization': 'Bearer ' + token()})
            for invalid in (token(exp=1), token(nbf=int(time.time()) + 100), token(iss='wrong'), token(aud='wrong'), token(sub=''), token(header={'alg': 'none'}), token(header={'alg': 'HS512'}), token(header={'alg': 'HS256', 'crit': ['unknown']}), token()[:-3] + 'xxx'):
                expect(port, '/private', headers={'Authorization': 'Bearer ' + invalid}, status=401)
            expect(port, '/private', headers={'Authorization': 'Bearer ' + token(scope='reader')}, status=403)
            _, headers, _ = expect(port, '/cors', 'OPTIONS', headers={'Origin': 'https://app.example', 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'content-type, authorization'}, status=204)
            assert dict(headers)['Access-Control-Allow-Credentials'] == 'true'
            expect(port, '/cors', headers={'Origin': 'https://evil.example'}, status=403)
            expect(port, '/cors', 'OPTIONS', headers={'Origin': 'https://app.example', 'Access-Control-Request-Method': 'DELETE'}, status=403)
            expect(port, '/rate'); expect(port, '/rate')
            _, headers, _ = expect(port, '/rate', status=429)
            assert dict(headers)['Retry-After'] == '1'
            time.sleep(1.05)
            expect(port, '/rate')
            _, headers, data = expect(port, '/large.txt', headers={'Accept-Encoding': 'gzip'})
            assert dict(headers)['Content-Encoding'] == 'gzip' and gzip.decompress(data) == b'hello ' * 1000
            compressed_etag = dict(headers)['ETag']
            assert compressed_etag.startswith('W/')
            expect(port, '/large.txt', headers={'Accept-Encoding': 'gzip', 'If-None-Match': compressed_etag}, status=304)
            _, headers, data = expect(port, '/large.txt', 'HEAD', headers={'Accept-Encoding': 'gzip'})
            assert not data and dict(headers)['Content-Encoding'] == 'gzip'
            _, headers, data = expect(port, '/large.txt')
            etag = dict(headers)['ETag']
            assert dict(headers)['Vary'] == 'Accept-Encoding' and etag == compressed_etag
            expect(port, '/large.txt', headers={'If-None-Match': etag}, status=304)
            expect(port, '/large.txt', 'PUT', status=405)
            expect(port, '/large.txt', headers={'Range': 'bytes=0-4'}, status=206)
            expect(port, '/missing', status=404)
            expect(port, '/discard', 'POST', b'a' * 33, status=413)
            with connect(port) as sock:
                sock.sendall(b'POST /discard HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n21\r\n' + b'a' * 33 + b'\r\n0\r\n\r\n')
                result = sock.recv(65536)
                assert b' 413 ' in result, result
            with connect(port) as sock:
                sock.sendall(b'GET / HTTP/1.1\r\nHost:')
                assert sock.recv(1024) == b''
            # A secret-file-only edit reloads the verifier; invalid rotation keeps the last working policy.
            new_secret = b'abcdef0123456789abcdef012345678901'
            (root / 'secret').write_bytes(new_secret + b'\n')
            deadline = time.monotonic() + 8
            while request(port, '/private', headers={'Authorization': 'Bearer ' + token(secret=new_secret)})[0] != 200:
                assert time.monotonic() < deadline, 'JWT secret did not reload'
                time.sleep(.05)
            expect(port, '/private', headers={'Authorization': 'Bearer ' + token()}, status=401)
            (root / 'secret').write_text('short\n')
            time.sleep(.4)
            expect(port, '/private', headers={'Authorization': 'Bearer ' + token(secret=new_secret)})
        # Invalid combinations must fail configuration validation.
        config.write_text(f'[server]\ncompatibility="self"\n[http]\nlisten="127.0.0.1:{port}"\ncors_origins=["*"]\ncors_credentials=true\n')
        assert subprocess.run([BINARY, '-t', '-c', config], capture_output=True).returncode != 0


native()
configured()
print(f'PASS: {checks} HTTP assertions; native API, methods, parsing, cookies, middleware, JWT, CORS, rate, gzip, cache, health, limits, timeout, idempotency')
