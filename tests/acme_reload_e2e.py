#!/usr/bin/env python3
"""Real lego issuance on reload, with an unchanged master, for all adapters."""
import asyncio
import json
import os
from pathlib import Path
import shutil
import signal
import ssl
import subprocess
import sys
import time

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from aioquic.asyncio import connect
from aioquic.quic.configuration import QuicConfiguration
from acme_common import configure, local_ca, peer_cert
from e2e_common import running

binary = Path(sys.argv[1]).resolve()
automatic = "--auto" in sys.argv[2:]
modes = [arg for arg in sys.argv[2:] if arg != "--auto"]


def names(cert):
    return set(x509.load_der_x509_certificate(cert).extensions.get_extension_for_class(
        x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName))


async def quic_names(port, host):
    config = QuicConfiguration(is_client=True, alpn_protocols=['h3'], server_name=host,
                               verify_mode=ssl.CERT_NONE)
    async with connect('127.0.0.1', port, configuration=config) as protocol:
        return names(protocol._quic.tls._peer_certificate.public_bytes(serialization.Encoding.DER))


for mode in (modes or ('self', 'nginx', 'apache', 'litespeed', 'caddy')):
    for challenge in ('dns-01', 'http-01'):
        with local_ca() as f:
            f.ca.challenge_type = challenge
            case = f.root / mode
            case.mkdir()
            gate, started, fail, failed = [case / name for name in ('gate', 'started', 'fail', 'failed')]
            client = case / 'client.py'
            # Only gate startup or fail before exec. All successful issuance uses
            # the pinned real lego and local CA/DNS servers, including HTTP-01.
            client.write_text(f'#!{sys.executable}\n' + f'''import os, pathlib, sys, time
root = pathlib.Path({str(case)!r})
if (root/'gate').exists() and (root/'gate').read_text() in sys.argv:
    (root/'started').write_text(str(os.getpid()))
    while (root/'gate').exists(): time.sleep(.05)
if (root/'fail').exists() and (not (root/'fail').read_text() or (root/'fail').read_text() in sys.argv):
    (root/'failed').touch()
    sys.exit(42)
os.execv({shutil.which('lego')!r}, ['lego', *sys.argv[1:]])
''')
            client.chmod(0o700)
            env_file = case / 'provider.env'
            env_file.write_text(f'HTTPREQ_ENDPOINT=http://127.0.0.1:{f.provider.server_port}\n'
                                'HTTPREQ_USERNAME=e2e\nHTTPREQ_PASSWORD=secret\nHTTPREQ_POLLING_INTERVAL=1\n')
            env_file.chmod(0o600)
            base = ['base.test', 'dedicated.test']
            extra = ['api.base.test', '*.wild.test'] if challenge == 'dns-01' else ['api.base.test']

            def write(records, timeout=15):
                domains = [d for group in records for d in group if d != 'dedicated.test'] + ['dedicated.test']
                path = configure(case, mode, f.port, f.challenge, f.ca.url,
                                 f.root/'server.pem', f.root/'key.pem', domains)
                server = path.read_text().split('[acme]')[0]
                if mode == 'self': server += 'http2=true\nhttp3=true\n'
                # Keep a stable PID file for the public -s reload interface.
                server = server.replace('[server]\n', f'[server]\npid="master.pid"\nauto_reload={str(automatic).lower()}\n')
                for i, group in enumerate(records):
                    server += f'''[[acme.certificates]]
name="cert{i}"
domains={json.dumps(group)}
email="test@example.test"
directory="{f.ca.url}/directory"
storage="certificates"
client="{client}"
accept_terms=true
challenge="{challenge}"
http_port={f.challenge}
renew_before_days=1
check_interval_seconds=3600
operation_timeout_seconds={timeout}
'''
                    if challenge == 'dns-01':
                        server += f'''dns_provider="httpreq"
dns_env_file="provider.env"
dns_resolvers=["127.0.0.1:{f.dns.server_address[1]}"]
dns_propagation_wait_seconds=1
'''
                path.write_text(server)
                return path

            config = write([base])
            with running([binary, '-c', config], f.port, env=f.env, startup_timeout=35) as proc:
                master = proc.pid

                def healthy():
                    assert proc.poll() is None, 'master exited during reload'
                    assert int((case/'master.pid').read_text()) == master
                    peer_cert(f.port, 'base.test')

                def wait(predicate, message, timeout=30):
                    deadline = time.monotonic() + timeout
                    while time.monotonic() < deadline:
                        healthy()
                        if predicate(): return
                        time.sleep(.05)
                    raise AssertionError(message)

                def reload(records, timeout=15, cli=False):
                    write(records, timeout)
                    if automatic:
                        with config.open("a") as output: output.write(f"\n# requested revision {time.monotonic_ns()}\n")
                        return
                    if cli:
                        subprocess.run([binary, '-c', config, '-s', 'reload'], env=f.env, check=True)
                    else:
                        os.kill(master, signal.SIGHUP)

                def matches(host, expected):
                    return names(peer_cert(f.port, host)) == set(expected)

                # Let the initial no-op renewal finish before gating a new job.
                time.sleep(.5)
                initial = peer_cert(f.port, 'base.test')
                gate.write_text('api.base.test')
                reload([base, extra], cli=True)
                wait(started.exists, 'reload did not start issuance')
                for _ in range(5):
                    healthy()
                    assert peer_cert(f.port, 'api.base.test') == initial
                    time.sleep(.05)
                gate.unlink()
                wait(lambda: matches('api.base.test', extra), 'new SNI certificate never activated')
                assert peer_cert(f.port, 'base.test') == initial
                if mode == 'self':
                    assert asyncio.run(quic_names(f.port, 'api.base.test')) == set(extra)
                if challenge == 'dns-01': assert matches('one.wild.test', extra)
                if mode != 'self':
                    assert peer_cert(f.port, 'other.test') == f.tls_cert.public_bytes(serialization.Encoding.DER)

                # Removing a record removes its SNI context and renewal job;
                # disk certificates remain available for a later re-add.
                issued = f.ca.issued
                cached = sorted((case/'certificates'/'certificates').glob('*.crt'))
                reload([base])
                wait(lambda: matches('api.base.test', base), 'removed certificate is still selected')
                assert all(path.exists() for path in cached)
                if mode == 'self':
                    assert asyncio.run(quic_names(f.port, 'api.base.test')) == set(base)
                reload([base, extra])
                wait(lambda: matches('api.base.test', extra), 'cached certificate was not re-added')
                assert f.ca.issued == issued

                # Both adding and removing SANs changes the managed cache key.
                expanded = base + ['new.base.test']
                reload([expanded, extra])
                wait(lambda: matches('base.test', expanded), 'added SAN did not activate')
                reload([base, extra])
                wait(lambda: matches('base.test', base), 'removed SAN did not activate')

                # A proposal with two missing certificates cannot activate the
                # first one when issuance of the second fails.
                if challenge == 'dns-01':
                    fail.write_text('bad.test')
                    reload([base, ['good.test'], ['bad.test']])
                    wait(failed.exists, 'second issuance did not fail')
                    time.sleep(.3)
                    assert ('good.test',) in f.ca.issued_by
                    assert matches('good.test', base) and matches('api.base.test', extra)
                    fail.unlink()
                    failed.unlink()

                # Failed issuance is atomic, even when the proposal removes an
                # existing record at the same time. A later reload retries it.
                failed_names = base + ['failed.test']
                fail.touch()
                reload([failed_names])
                wait(failed.exists, 'failure fixture did not execute')
                time.sleep(.4)
                assert matches('base.test', base) and matches('api.base.test', extra)
                fail.unlink()
                reload([failed_names])
                wait(lambda: matches('base.test', failed_names), 'retry after failed reload did not activate')

                # Supersede an in-flight issue with a cached configuration. The
                # obsolete child may complete DNS cleanup, but must not apply it.
                started.unlink()
                gate.write_text('stale.test')
                stale = base + ['stale.test']
                reload([stale])
                wait(started.exists, 'obsolete issue was not started')
                reload([base, extra])
                wait(lambda: matches('base.test', base), 'newest reload did not win')
                gate.unlink()
                wait(lambda: tuple(sorted(stale)) in f.ca.issued_by, 'obsolete issuer did not finish')
                time.sleep(.4)
                assert matches('base.test', base) and matches('api.base.test', extra)

                if challenge == 'dns-01':
                    # A timed-out issuer must be reaped and leave the old TLS
                    # generation alive; the next reload must still work.
                    started.unlink()
                    gate.write_text('timeout.test')
                    reload([base + ['timeout.test']], timeout=2)
                    wait(started.exists, 'timeout issuer did not start')
                    child = int(started.read_text())
                    def reaped():
                        try: os.kill(child, 0)
                        except ProcessLookupError: return True
                        return False
                    wait(reaped, 'issuer did not time out', timeout=8)
                    gate.unlink()
                    assert matches('base.test', base) and matches('api.base.test', extra)
                    reload([expanded, extra])
                    wait(lambda: matches('base.test', expanded), 'reload after timeout did not recover')
                # Remove the final managed record and switch to manual TLS.
                path = configure(case, mode, f.port, f.challenge, f.ca.url,
                                 f.root/'server.pem', f.root/'key.pem')
                server = path.read_text().split('[acme]')[0]
                server = server.replace('[server]\n', f'[server]\npid="master.pid"\nauto_reload={str(automatic).lower()}\n')
                cert, key = f.root/'server.pem', f.root/'key.pem'
                if mode == 'self':
                    server += f'[http.tls]\ncertificate="{cert}"\nkey="{key}"\n'
                elif mode == 'nginx':
                    source = case/'server.conf'
                    source.write_text(source.read_text().replace('server_name localhost;',
                        f'server_name localhost; ssl_certificate "{cert}"; ssl_certificate_key "{key}";'))
                elif mode == 'apache':
                    source = case/'server.conf'
                    source.write_text(source.read_text().replace('ServerName localhost',
                        f'ServerName localhost\nSSLCertificateFile "{cert}"\nSSLCertificateKeyFile "{key}"'))
                elif mode == 'litespeed':
                    source = case/'managed.conf'
                    source.write_text(source.read_text()+f'vhssl {{\ncertFile "{cert}"\nkeyFile "{key}"\n}}\n')
                else:
                    source = case/'sites.caddy'
                    source.write_text(source.read_text().replace(f'https://localhost:{f.port} {{',
                        f'https://localhost:{f.port} {{\ntls "{cert}" "{key}"'))
                config.write_text(server)
                if not automatic: os.kill(master, signal.SIGHUP)
                wait(lambda: peer_cert(f.port, 'localhost') == f.tls_cert.public_bytes(serialization.Encoding.DER),
                     'removing all managed certificates did not switch to manual TLS')
                healthy()
                wait(lambda: not f.dns.records, 'DNS challenge records were not cleaned')
                print(f'{mode} {challenge}: {"auto" if automatic else "manual"} reload add/remove/SAN/failure/supersession OK', flush=True)
