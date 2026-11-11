#!/usr/bin/env python3
"""Real lego + local CA/DNS: env changes retry only their own certificates."""
import asyncio
import http.server
from pathlib import Path
import shutil
import ssl
import sys
import threading
import time
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from aioquic.asyncio import connect
from aioquic.quic.configuration import QuicConfiguration
from acme_common import DNSProvider, configure, local_ca, peer_cert
from e2e_common import running

binary = Path(sys.argv[1]).resolve()


def atomic(path, text):
    temp = path.with_name(path.name+'.tmp')
    temp.write_text(text); temp.chmod(0o600); temp.replace(path)


async def quic_certificate(port, host):
    cfg = QuicConfiguration(is_client=True, alpn_protocols=['h3'], server_name=host, verify_mode=ssl.CERT_NONE)
    async with connect('127.0.0.1', port, configuration=cfg) as protocol:
        return protocol._quic.tls._peer_certificate.public_bytes(serialization.Encoding.DER)


for mode in (sys.argv[2:] or ('self', 'nginx', 'apache', 'litespeed', 'caddy')):
    with local_ca() as f, http.server.ThreadingHTTPServer(('127.0.0.1', 0), DNSProvider) as second:
        f.ca.challenge_type = 'dns-01'
        f.provider.credentials = 'alice:secret-a0'
        second.credentials = 'bob:secret-b0'
        second.dns = f.dns; second.fail = False; second.failures = 0
        thread = threading.Thread(target=second.serve_forever, daemon=True); thread.start()
        try:
            case = f.root/mode; case.mkdir()
            a_env, b_env, new_env = [case/name for name in ('a.env', 'b.env', 'new.env')]
            log = case/'master.log'
            hold, done = case/'hold', case/'done'
            client = case/'client.py'
            client.write_text(f'#!{sys.executable}\n'+f'''import pathlib, subprocess, sys, time, os
root = pathlib.Path({str(case)!r})
result = subprocess.run([{shutil.which('lego')!r}, *sys.argv[1:]])
if result.returncode == 0 and 'base.test' in sys.argv and (root/'hold').exists():
    (root/'done').write_text(str(os.getpid()))
    while (root/'hold').exists(): time.sleep(.05)
sys.exit(result.returncode)
''')
            client.chmod(0o700)

            def env(path, provider, user, secret):
                atomic(path, f'HTTPREQ_ENDPOINT=http://127.0.0.1:{provider.server_port}\nHTTPREQ_USERNAME={user}\n'
                            f'HTTPREQ_PASSWORD={secret}\nHTTPREQ_POLLING_INTERVAL=1\n')
            env(a_env, f.provider, 'alice', 'secret-a0')
            env(b_env, second, 'bob', 'secret-b0')

            def write(add=False):
                config = configure(case, mode, f.port, f.challenge, f.ca.url,
                                   f.root/'server.pem', f.root/'key.pem',
                                   ['base.test', 'third.test', 'dedicated.test'] if add else ['base.test', 'dedicated.test'])
                server = config.read_text().split('[acme]')[0]
                server = server.replace('[server]\n', '[server]\npid="master.pid"\n')
                if mode == 'self': server += 'http2=true\nhttp3=true\n'
                records = [('base.test', a_env, 30), ('dedicated.test', b_env, 30)]
                if add: records.append(('third.test', new_env, 1))
                for i, (domain, path, renew) in enumerate(records):
                    server += f'''[[acme.certificates]]
name="cert{i}"
domain="{domain}"
email="test@example.test"
directory="{f.ca.url}/directory"
storage="certificates"
client="{client}"
accept_terms=true
challenge="dns-01"
dns_provider="httpreq"
dns_env_file="{path.name}"
dns_resolvers=["127.0.0.1:{f.dns.server_address[1]}"]
dns_propagation_wait_seconds=1
renew_before_days={renew}
check_interval_seconds=3600
operation_timeout_seconds=30
'''
                config.write_text(server)
                return config

            config = write()
            with running([binary, '-c', config], f.port, env=f.env, startup_timeout=40, log_path=log) as proc:
                # A TCP listener alone does not mean startup has written its PID.
                peer_cert(f.port, 'base.test')
                peer_cert(f.port, 'dedicated.test')
                def issued(domain): return f.ca.issued_by.get((domain,), 0)
                def count(text): return log.read_text().count(text)
                def healthy():
                    assert proc.poll() is None
                    assert int((case/'master.pid').read_text()) == proc.pid
                    peer_cert(f.port, 'base.test'); peer_cert(f.port, 'dedicated.test')
                    if mode != 'self': assert peer_cert(f.port, 'other.test') == f.tls_cert.public_bytes(serialization.Encoding.DER)
                def wait(predicate, message, timeout=35):
                    end = time.monotonic()+timeout
                    while time.monotonic() < end:
                        healthy()
                        if predicate(): return
                        time.sleep(.05)
                    raise AssertionError(message)
                def stable(seconds=1.2):
                    end = time.monotonic()+seconds
                    while time.monotonic() < end:
                        healthy(); time.sleep(.05)
                def changed(host, previous):
                    wait(lambda: peer_cert(f.port, host) != previous, f'{host}: env rotation did not refresh TLS')
                    stable(.3)
                    return peer_cert(f.port, host)

                # Initial issuance + the first scheduled renewal, then a one-hour
                # deadline. Own lego writes must not enqueue configuration reloads.
                wait(lambda: issued('base.test') >= 2 and issued('dedicated.test') >= 2, 'initial renewals did not finish')
                stable(1.3)
                assert count('watched files changed') == 0, 'lego output triggered the file watcher'
                a = peer_cert(f.port, 'base.test'); b = peer_cert(f.port, 'dedicated.test')
                b_count = issued('dedicated.test')
                f.provider.credentials = 'alice:secret-a1'
                env(a_env, f.provider, 'alice', 'secret-a1')
                a = changed('base.test', a)
                assert issued('dedicated.test') == b_count and peer_cert(f.port, 'dedicated.test') == b
                if mode == 'self': assert asyncio.run(quic_certificate(f.port, 'base.test')) == a

                # Missing/empty env files fail once and leave current HTTPS live.
                before = count('reload failed')
                atomic(a_env, '')
                wait(lambda: count('reload failed') > before, 'empty env was not rejected')
                stable()
                assert count('reload failed') == before+1
                assert peer_cert(f.port, 'base.test') == a
                target = case/'a-target.env'
                f.provider.credentials = 'alice:secret-a2'
                env(target, f.provider, 'alice', 'secret-a2')
                link = case/'a-link.env'; link.symlink_to(target.name); link.replace(a_env)
                a = changed('base.test', a)
                before = count('reload failed')
                a_env.unlink()
                wait(lambda: count('reload failed') > before, 'missing env was not tracked')
                a_env.symlink_to(target.name)
                a = changed('base.test', a)

                # Bad credentials may fail at the DNS API, without losing TLS.
                # Fixing only the env file must bypass the one-hour retry delay.
                second.credentials = 'bob:secret-b1'
                env(b_env, second, 'bob', 'wrong-b-secret')
                wait(lambda: getattr(second, 'auth_failures', 0) > 0, 'new invalid credentials were not used')
                wait(lambda: 'ACME renewal cert1 failed' in log.read_text(), 'failed renewal was not reaped')
                stable()
                assert peer_cert(f.port, 'dedicated.test') == b
                a_count = issued('base.test')
                env(b_env, second, 'bob', 'secret-b1')
                b = changed('dedicated.test', b)
                assert issued('base.test') == a_count and peer_cert(f.port, 'base.test') == a

                # Rotate credentials again while a completed lego is still held
                # in the child wrapper. No TLS files may be consumed before exit,
                # and the old child's deadline must not suppress the new check.
                hold.touch()
                f.provider.credentials = 'alice:secret-a3'
                env(target, f.provider, 'alice', 'secret-a3')
                wait(done.exists, 'held issuer did not write its certificate')
                old_count = issued('base.test')
                notices = count('reconfiguring')
                f.provider.credentials = 'alice:secret-a4'
                env(target, f.provider, 'alice', 'secret-a4')
                wait(lambda: count('reconfiguring') > notices, 'in-flight credential rotation was not noticed')
                stable()
                assert peer_cert(f.port, 'base.test') == a, 'TLS switched while the writer was still active'
                hold.unlink()
                wait(lambda: issued('base.test') > old_count, 'stale job postponed the new credentials')
                a = x509.load_pem_x509_certificate(f.ca.certificate).public_bytes(serialization.Encoding.DER)
                wait(lambda: peer_cert(f.port, 'base.test') == a, 'latest credential generation was not served')
                stable(1.3)

                # A newly configured certificate with a missing env must recover
                # when that file appears, without touching TOML or native inputs.
                before = count('reload failed')
                write(add=True)
                wait(lambda: count('reload failed') > before, 'missing new env did not reject candidate')
                env(new_env, f.provider, 'alice', 'secret-a4')
                wait(lambda: issued('third.test') == 1, 'creating the missing env did not issue the new certificate')
                third = x509.load_pem_x509_certificate(f.ca.certificate).public_bytes(serialization.Encoding.DER)
                wait(lambda: peer_cert(f.port, 'third.test') == third, 'new SNI certificate never activated')
                write(add=False)
                wait(lambda: peer_cert(f.port, 'third.test') == peer_cert(f.port, 'base.test'), 'certificate removal did not activate')
                stable(.4)
                before = count('reconfiguring')
                atomic(new_env, 'removed-env-secret')
                atomic(case/'certificates'/'certificates'/'third.test.key', 'removed-key-secret')
                stable()
                assert count('reconfiguring') == before, 'removed material is still watched'
                # Nothing new changed: no self-induced retry or reload loop.
                before = (f.ca.issued, count('reconfiguring'))
                stable(1.5)
                assert before == (f.ca.issued, count('reconfiguring'))
                assert not f.dns.records, 'TXT records were not cleaned'
                text = log.read_text()
                for secret in ('secret-a0', 'secret-a1', 'secret-a2', 'secret-a3', 'secret-a4', 'secret-b0', 'secret-b1', 'wrong-b-secret', 'removed-env-secret', 'removed-key-secret'):
                    assert secret not in text, 'credentials leaked into master log'
                print(f'PASS: {mode} DNS env rotation, isolated retries, in-flight update, missing-file recovery and no reload loops', flush=True)
        finally:
            second.shutdown(); thread.join()
