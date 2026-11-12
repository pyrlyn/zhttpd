#!/usr/bin/env python3
"""Independent real-lego certificates, DNS providers and SNI in every adapter."""
import asyncio
import contextlib
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from acme_common import DNSProvider, configure, local_ca, peer_cert
from e2e_common import running
from aioquic.asyncio import connect
from aioquic.quic.configuration import QuicConfiguration

binary = Path(sys.argv[1]).resolve()


def wait_for(predicate, message, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError(message)


def check_san(cert, names):
    san = x509.load_der_x509_certificate(cert).extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    assert set(san.get_values_for_type(x509.DNSName)) == set(names)


def tls_handshake(port, host, alpn=None):
    context = ssl._create_unverified_context()
    if alpn: context.set_alpn_protocols(alpn)
    with socket.create_connection(('127.0.0.1', port), timeout=3) as raw:
        with context.wrap_socket(raw, server_hostname=host) as sock:
            return sock.getpeercert(binary_form=True), sock.selected_alpn_protocol()


async def quic_certificate(port, host, cafile):
    configuration = QuicConfiguration(is_client=True, alpn_protocols=['h3'], server_name=host,
                                      verify_mode=ssl.CERT_REQUIRED, cafile=str(cafile))
    async with connect('127.0.0.1', port, configuration=configuration) as protocol:
        # aioquic is pinned in the test lock; expose the handshake's leaf for comparison.
        return protocol._quic.tls._peer_certificate.public_bytes(serialization.Encoding.DER)


for mode in (sys.argv[2:] or ('self', 'nginx', 'apache', 'litespeed', 'caddy')):
    with local_ca() as f, http.server.ThreadingHTTPServer(('127.0.0.1', 0), DNSProvider) as second:
        f.ca.challenge_type = 'dns-01'
        f.provider.credentials = 'alice:token-a'
        f.provider.allowed = {'_acme-challenge.example.test.'}
        second.credentials = 'bob:token-b'
        second.allowed = {'_acme-challenge.api.example.test.', '_acme-challenge.second.test.', '_acme-challenge.dedicated.test.'}
        second.dns = f.dns
        second.fail = False
        second.failures = 0
        thread = threading.Thread(target=second.serve_forever, daemon=True)
        thread.start()
        try:
            # The second certificate uses a different lego provider (exec), not httpreq.
            updater = f.root/'dns-update.py'
            updater.write_text(f'#!{sys.executable}\n' + '''import base64, json, os, sys, urllib.request
assert len(sys.argv) == 4 and sys.argv[1] in ('present', 'cleanup')
body = json.dumps({'fqdn': sys.argv[2], 'value': sys.argv[3]}).encode()
credentials = base64.b64encode(os.environ['TEST_DNS_CREDENTIALS'].encode()).decode()
request = urllib.request.Request(os.environ['TEST_DNS_ENDPOINT']+'/'+sys.argv[1], data=body,
                                 headers={'Content-Type': 'application/json', 'Authorization': 'Basic '+credentials})
with urllib.request.urlopen(request, timeout=3) as response: assert response.status == 200
''')
            updater.chmod(0o700)
            wild_names = ['example.test', '*.example.test']
            apps_names = ['api.example.test', 'second.test', 'dedicated.test']
            assert not f.dns.records, f'previous case left TXT records: {f.dns.records}'
            case = f.root/mode
            case.mkdir()
            f.ca.fail = False
            f.provider.fail = False
            second.fail = False
            f.provider.seen = set()
            second.seen = set()
            config = configure(case, mode, f.port, f.challenge, f.ca.url, f.root/'server.pem', f.root/'key.pem',
                               ['example.test', '*.example.test', 'second.test', 'dedicated.test'], f.dns)
            server = config.read_text().split('[acme]')[0]
            if mode == 'self': server += 'http2=true\nhttp3=true\n'
            elif mode == 'nginx':
                source = case/'server.conf'
                source.write_text(source.read_text().replace('http {', 'http { http2 on;'))
            elif mode == 'apache':
                source = case/'server.conf'
                source.write_text('Protocols h2 http/1.1\n'+source.read_text())
            first_env = case/'a provider.env'
            first_env.write_text(f'HTTPREQ_ENDPOINT=http://127.0.0.1:{f.provider.server_port}\nHTTPREQ_USERNAME=alice\nHTTPREQ_PASSWORD=token-a\nHTTPREQ_POLLING_INTERVAL=1\n')
            second_env = case/'b.env'
            second_env.write_text(f'EXEC_PATH={updater}\nEXEC_SEQUENCE_INTERVAL=0\nEXEC_POLLING_INTERVAL=1\nTEST_DNS_ENDPOINT=http://127.0.0.1:{second.server_port}\nTEST_DNS_CREDENTIALS=bob:token-b\nHTTPREQ_ENDPOINT=http://127.0.0.1:1\n')
            first_env.chmod(0o600)
            second_env.chmod(0o600)

            def record(name, domains, provider, env_file):
                return f'''[[acme.certificates]]
    name="{name}"
    domains={json.dumps(domains)}
    email="test@example.test"
    accept_terms=true
    directory="{f.ca.url}/directory"
    storage="certificates"
    challenge="dns-01"
    dns_provider="{provider}"
    dns_env_file="{env_file}"
    dns_resolvers=["127.0.0.1:{f.dns.server_address[1]}"]
    dns_propagation_wait_seconds=1
    check_interval_seconds=1
    operation_timeout_seconds=30
    '''

            wildcard = record('wild', wild_names, 'httpreq', first_env.name)
            apps = record('apps', apps_names, 'exec', second_env.name)
            original = server + wildcard + apps
            for text, expected in (
                (server+'[acme]\ndomain="legacy.test"\n'+wildcard+apps, b'use either'),
                (original.replace('name="apps"', 'name="wild"'), b'duplicate ACME certificate name'),
                (original.replace('name="wild"\n', ''), b'requires a name'),
                (original.replace(json.dumps(apps_names), json.dumps(apps_names+['EXAMPLE.TEST'])), b'belongs to multiple'),
                (original.replace('dns_env_file="b.env"', 'dns_env_file="missing.env"'), b'cannot read nonempty dns_env_file'),
                (original.replace('dns_provider="exec"', 'dns_provider="manual"'), b'automatic dns_provider'),
                ('[modules]\nacme=false\n'+original, b'acme module is disabled'),
            ):
                config.write_text(text)
                result = subprocess.run([binary, '-t', '-c', config], capture_output=True)
                assert result.returncode != 0 and expected in result.stderr, result.stderr.decode()
            config.write_text(original)
            issued_before = f.ca.issued
            subprocess.run([binary, '-t', '-c', config], check=True)
            assert f.ca.issued == issued_before
            with running([binary, '-c', config], f.port, env=f.env, startup_timeout=40) as process:
                first_wild = peer_cert(f.port, 'example.test')
                first_apps = peer_cert(f.port, 'second.test')
                assert first_wild != first_apps
                check_san(first_wild, wild_names)
                check_san(first_apps, apps_names)
                assert peer_cert(f.port, 'www.example.test') == first_wild
                assert peer_cert(f.port, 'api.example.test') == first_apps, 'exact SAN must win over earlier wildcard'
                assert peer_cert(f.port, 'dedicated.test') == first_apps
                assert tls_handshake(f.port, None)[0] == first_wild, 'no-SNI uses default certificate'
                if mode == 'self':
                    assert asyncio.run(quic_certificate(f.port, 'example.test', f.root/'ca.pem')) == first_wild
                    assert asyncio.run(quic_certificate(f.port, 'api.example.test', f.root/'ca.pem')) == first_apps
                for host in ('example.test', 'api.example.test'):
                    assert tls_handshake(f.port, host, ['h2', 'http/1.1'])[1] == 'h2'
                if mode != 'self':
                    manual = f.tls_cert.public_bytes(serialization.Encoding.DER)
                    assert peer_cert(f.port, 'other.test') == manual
                # Validate available certificates even if a different managed one is absent.
                cert_files = [path for path in (case/'certificates'/'certificates').glob('*.crt') if not path.name.endswith('.issuer.crt')]
                assert len(cert_files) == 2
                saved = {path: path.read_bytes() for path in cert_files}
                cert_files[0].unlink()
                cert_files[1].write_text('broken cached certificate')
                try:
                    result = subprocess.run([binary, '-t', '-c', config], capture_output=True)
                    assert result.returncode != 0 and b'cannot load certificate' in result.stderr
                finally:
                    for path, data in saved.items(): path.write_bytes(data)
                wait_for(lambda: peer_cert(f.port, 'example.test') != first_wild and peer_cert(f.port, 'second.test') != first_apps,
                         f'{mode}: independent certificates did not renew')
                assert f.provider.seen == f.provider.allowed and second.seen == second.allowed
                # Failure of the first provider must not block renewal of the second certificate.
                failures_before = f.provider.failures
                f.provider.fail = True
                wait_for(lambda: f.provider.failures > failures_before, 'first provider failure not exercised')
                stable_wild = peer_cert(f.port, 'example.test')
                before_apps = peer_cert(f.port, 'second.test')
                wait_for(lambda: peer_cert(f.port, 'second.test') != before_apps, 'failed first job starved second certificate')
                assert peer_cert(f.port, 'example.test') == stable_wild
                # Reorder configuration while renewals run. Jobs must retain their certificate identity.
                config.write_text(server + apps + wildcard)
                os.kill(process.pid, signal.SIGHUP)
                before_apps = peer_cert(f.port, 'second.test')
                wait_for(lambda: peer_cert(f.port, 'second.test') != before_apps, 'renewal stopped after reordered reload')
                assert peer_cert(f.port, 'api.example.test') == peer_cert(f.port, 'second.test')
                assert peer_cert(f.port, 'example.test') == stable_wild
                if mode != 'self': assert peer_cert(f.port, 'other.test') == manual
                second.fail = True
                failures_before = second.failures
                wait_for(lambda: second.failures > failures_before, 'second provider failure not exercised')
                stable_apps = peer_cert(f.port, 'second.test')
                wait_for(lambda: not f.dns.records, f'TXT records leaked after provider failure: {f.dns.records}')
            # All cached certificates remain usable when both DNS providers are down.
            with running([binary, '-c', config], f.port, env=f.env):
                assert peer_cert(f.port, 'example.test') == stable_wild
                assert peer_cert(f.port, 'second.test') == stable_apps
            print(f'PASS: {mode} independent SNI certificates, httpreq/exec provider isolation, exact/wildcard priority, renewal, failure isolation, reordered reload, offline restart', flush=True)
        finally:
            second.shutdown()
            thread.join()
