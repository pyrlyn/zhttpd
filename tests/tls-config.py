#!/usr/bin/env python3
"""TLS backend contract: SNI, configured ciphers/groups, and ticket resumption."""
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/zhttpd').resolve()
openssl = os.environ.get('OPENSSL_CLI', os.environ.get('OPENSSL_BIN', 'openssl'))
seen_workers = set()


def context(version, cipher='ECDHE-ECDSA-AES128-GCM-SHA256'):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.minimum_version = ctx.maximum_version = version
    ctx.set_ciphers(cipher)
    return ctx


def exchange(ctx, port, name='allowed.local', session=None):
    with socket.create_connection(('127.0.0.1', port), timeout=3) as raw:
        with ctx.wrap_socket(raw, server_hostname=name, session=session) as client:
            client.sendall(b'GET / HTTP/1.1\r\nHost: allowed.local\r\nConnection: close\r\n\r\n')
            response = bytearray()
            while chunk := client.recv(65536):
                response.extend(chunk)
            assert response.startswith(b'HTTP/1.1 200 '), response
            assert response.endswith(b'backend contract'), response
            headers = response.split(b'\r\n\r\n', 1)[0].split(b'\r\n')
            worker = next(line.split(b':', 1)[1].strip() for line in headers if line.lower().startswith(b'x-worker:'))
            seen_workers.add(bytes(worker))
            return client.cipher()[0], client.session, client.session_reused


with tempfile.TemporaryDirectory(prefix='zhttpd-tls-config-') as tmp:
    root = Path(tmp)
    subprocess.run([openssl, 'req', '-config', os.devnull, '-x509', '-newkey', 'ec',
                    '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-days', '1',
                    '-subj', '/CN=allowed.local', '-keyout', str(root / 'key.pem'),
                    '-out', str(root / 'cert.pem')], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    conf = root / 'nginx.conf'
    for tickets in ('off', 'on'):
        conf.write_text(f'''
worker_processes 4;
pid off;
error_log stderr;
events {{ worker_connections 128; }}
http {{
    access_log off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256;
    ssl_conf_command Ciphersuites TLS_AES_128_GCM_SHA256;
    ssl_ecdh_curve X25519;
    ssl_session_cache builtin:128;
    ssl_session_tickets {tickets};
    server {{
        listen 127.0.0.1:{port} ssl default_server;
        ssl_reject_handshake on;
    }}
    server {{
        listen 127.0.0.1:{port} ssl;
        server_name allowed.local;
        ssl_certificate {root}/cert.pem;
        ssl_certificate_key {root}/key.pem;
        add_header X-Worker $pid;
        return 200 "backend contract";
    }}
}}
''')
        with tempfile.TemporaryFile() as errors:
            server = subprocess.Popen([binary, '-c', conf], stderr=errors)
            try:
                for _ in range(100):
                    if server.poll() is not None:
                        errors.seek(0)
                        raise AssertionError(errors.read().decode())
                    try:
                        socket.create_connection(('127.0.0.1', port), timeout=.1).close()
                        break
                    except OSError:
                        time.sleep(.02)
                for version, expected in ((ssl.TLSVersion.TLSv1_2, 'ECDHE-ECDSA-AES128-GCM-SHA256'),
                                          (ssl.TLSVersion.TLSv1_3, 'TLS_AES_128_GCM_SHA256')):
                    ctx = context(version)
                    cipher, session, reused = exchange(ctx, port)
                    assert cipher == expected and not reused, (cipher, reused)
                    if tickets == 'on':
                        assert session.has_ticket, f'{version}: no ticket issued'
                        _, _, reused = exchange(ctx, port, session=session)
                        assert reused, f'{version}: session did not resume'
                        seen_workers.clear()
                        with ThreadPoolExecutor(max_workers=8) as pool:
                            resumed = list(pool.map(lambda _: exchange(ctx, port, session=session)[2], range(32)))
                        assert all(resumed), f'{version}: only {sum(resumed)}/32 concurrent sessions resumed'
                        assert len(seen_workers) > 1, 'resumption did not exercise multiple workers'
                    elif version == ssl.TLSVersion.TLSv1_2:
                        assert not session.has_ticket, 'ssl_session_tickets off ignored'
                    try:
                        exchange(ctx, port, 'rejected.local')
                    except ssl.SSLError:
                        pass
                    else:
                        raise AssertionError('SNI rejection ignored')
                try:
                    exchange(context(ssl.TLSVersion.TLSv1_2, 'ECDHE-ECDSA-AES256-GCM-SHA384'), port)
                except ssl.SSLError:
                    pass
                else:
                    raise AssertionError('TLS 1.2 cipher restriction ignored')
                for extra in (['-ciphersuites', 'TLS_AES_256_GCM_SHA384'], ['-groups', 'P-256']):
                    rejected = subprocess.run([openssl, 's_client', '-connect', f'127.0.0.1:{port}',
                                               '-servername', 'allowed.local', '-tls1_3', '-brief', *extra],
                                              input=b'', capture_output=True, timeout=5)
                    assert rejected.returncode != 0, f'TLS 1.3 restriction ignored: {extra}'
                print(f'PASS: SNI/cipher/group restrictions, TLS 1.2/1.3, session tickets {tickets}')
            finally:
                server.terminate()
                server.wait(timeout=5)
