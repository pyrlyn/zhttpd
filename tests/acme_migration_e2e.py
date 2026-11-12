#!/usr/bin/env python3
"""Migrate real cached ACME SNI keys offline; delete only after activation."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from acme_common import configure, local_ca, peer_cert
from e2e_common import free_port, running
from tls_common import atomic

binary = Path(sys.argv[1]).resolve()
suffixes = ('.crt', '.key', '.json', '.issuer.crt', '.pem', '.pfx')

for mode in (sys.argv[2:] or ('self', 'nginx', 'apache', 'litespeed', 'caddy')):
    with local_ca() as f:
        f.ca.challenge_type = 'dns-01'
        case = f.root/mode; case.mkdir()
        first, second = '*.example.test', 'dedicated.test'
        names = ('_.example.test', 'dedicated.test')
        hosts = ('www.example.test', second)
        passwords = (b'migrate-first-secret', b'migrate-second-secret')
        for i, password in enumerate(passwords): atomic(case/f'{i}.pass', password+b'\n')
        env_file = case/'provider.env'
        env_file.write_text(f'HTTPREQ_ENDPOINT=http://127.0.0.1:{f.provider.server_port}\nHTTPREQ_USERNAME=e2e\nHTTPREQ_PASSWORD=secret\n')
        (case/'provider-second.env').write_bytes(env_file.read_bytes())
        client = case/'client.py'
        client.write_text(f'#!{sys.executable}\n'+f'''import os, pathlib, subprocess, sys, time
root=pathlib.Path({str(case)!r})
with (root/'calls').open('a') as log: log.write(sys.argv[sys.argv.index('--cert.name')+1]+'\\n')
if (root/'offline').exists(): sys.exit(71)
status=subprocess.call([{shutil.which('lego')!r}, *sys.argv[1:]])
if (root/'gate').exists() and (root/'gate').read_text() in sys.argv:
    (root/'started').touch()
    while (root/'gate').exists(): time.sleep(.05)
sys.exit(status)
'''); client.chmod(0o700)
        def write(encrypted=False, port=None, protect=False):
            config = configure(case, mode, port or f.port, f.challenge, f.ca.url, f.root/'server.pem', f.root/'key.pem', [first, second])
            base = config.read_text().split('[acme]')[0].replace('[server]\n', '[server]\npid="master.pid"\n')
            if mode == 'self': base += 'http2=true\nhttp3=true\n'
            for i, domain in enumerate((first, second)):
                base += f'''[[acme.certificates]]
name="cert{i}"
domain="{domain}"
email="test@example.test"
accept_terms=true
directory="{f.ca.url}/directory"
client="./client.py"
storage="certificates"
challenge="dns-01"
dns_provider="httpreq"
dns_env_file="{env_file.name if i == 0 else 'provider-second.env'}"
dns_resolvers=["127.0.0.1:{f.dns.server_address[1]}"]
dns_propagation_wait_seconds=1
renew_before_days=1
check_interval_seconds=3600
operation_timeout_seconds=10
'''
                if encrypted: base += f'encrypt_key=true\npassword_file="{i}.pass"\n'
            config.write_text(base)
            if protect and mode != 'self':
                # An unrelated manual host still uses the first legacy pair.
                source = case/('manual.conf' if mode == 'litespeed' else 'sites.caddy' if mode == 'caddy' else 'server.conf')
                source.write_text(source.read_text().replace(str(f.root/'server.pem'), str(legacy/(names[0]+'.crt')))
                                  .replace(str(f.root/'key.pem'), str(legacy/(names[0]+'.key'))))
            return config
        config = write(); log = case/'master.log'
        legacy = case/'certificates'/'certificates'
        encrypted = case/'certificates'/'encrypted'
        def current(i): return encrypted/names[i]/'current'
        def unchanged(saved):
            for path, data in saved.items(): assert path.read_bytes() == data, path
        def no_stage(): return not list(encrypted.glob('*/work-*'))
        with running([binary, '-c', config], f.port, env=f.env, startup_timeout=40, log_path=log) as process:
            certs = [peer_cert(f.port, host) for host in hosts]
            def healthy():
                assert process.poll() is None
                for host, cert in zip(hosts, certs): assert peer_cert(f.port, host) == cert
                assert int((case/'master.pid').read_text()) == process.pid
            def wait(predicate, message):
                until = time.monotonic()+20
                while time.monotonic() < until:
                    if predicate(): return
                    healthy(); time.sleep(.05)
                raise AssertionError(message)
            def count(text): return log.read_text().count(text)
            wait(lambda: (case/'calls').exists() and len((case/'calls').read_text().splitlines()) >= 4,
                 'initial cached checks not run')
            time.sleep(.3)
            for name in names:
                (legacy/(name+'.pem')).write_bytes((legacy/(name+'.crt')).read_bytes()+(legacy/(name+'.key')).read_bytes())
                (legacy/(name+'.pfx')).write_bytes(b'opaque-export-'+name.encode())
            unrelated = legacy/'unrelated.key'; unrelated.write_bytes(b'leave-this-record-alone')
            saved = {legacy/(name+suffix): (legacy/(name+suffix)).read_bytes() for name in names for suffix in suffixes}
            account_files = {p: p.read_bytes() for p in (case/'certificates'/'accounts').rglob('*') if p.is_file()}
            # A partial source is rejected locally, not replaced by CA issuance.
            bad_key = legacy/(names[1]+'.key'); original_key = bad_key.read_bytes()
            with socket.socket() as occupied:
                occupied.bind(('0.0.0.0' if mode == 'caddy' else '127.0.0.1', 0)); occupied.listen()
                blocked_port = occupied.getsockname()[1]
                if mode == 'self':
                    (case/'gate').write_text(names[0])
                    env_file.write_text(env_file.read_text()+'# schedule old plaintext writer\n')
                    wait((case/'started').exists, 'legacy writer did not start')
                before = count('reload failed')
                atomic(case/'0.pass', b'')
                (case/'offline').touch(); issued = f.ca.issued; calls = (case/'calls').read_bytes()
                write(True, blocked_port)
                if mode == 'self':
                    time.sleep(1.3)
                    assert count('reload failed') == before, 'candidate validated while legacy issuer still ran'
                    assert not current(0).exists()
                    (case/'gate').unlink()
                wait(lambda: count('reload failed') > before, 'missing password not rejected')
                assert not current(0).exists() and not current(1).exists()
                before = count('reload failed')
                bad_key.write_bytes(b'incomplete legacy key')
                atomic(case/'0.pass', passwords[0]+b'\n')
                wait(lambda: count('reload failed') > before, 'partial migration did not reject bad key')
                assert current(0).exists() and not current(1).exists()
                assert all(path.exists() for path in saved)
                assert (case/'calls').read_bytes() == calls and f.ca.issued == issued
                if mode == 'self':
                    target = case/'saved.key'; target.write_bytes(original_key)
                    bad_key.unlink(); bad_key.symlink_to(target)
                    before = count('reload failed')
                    wait(lambda: count('reload failed') > before, 'legacy key symlink was not rejected')
                    assert target.read_bytes() == original_key
                    before = count('reload failed')
                    atomic(bad_key, original_key)
                else:
                    before = count('reload failed')
                    bad_key.write_bytes(original_key)
                wait(lambda: count('reload failed') > before and current(1).exists(), 'fixed source not watched or bind failure not exercised')
                unchanged(saved)
                # -t is read-only even with a published-but-not-activated migration.
                result = subprocess.run([binary, '-t', '-c', config], capture_output=True, timeout=5)
                assert result.returncode == 0, result.stderr.decode()
                unchanged(saved)
                # Rolling back to the old reader before cleanup remains possible.
                before = count('reload complete'); write(False)
                wait(lambda: count('reload complete') > before, 'plaintext rollback failed')
                unchanged(saved)
                # Replacement/changed source metadata prevents deleting ANY member.
                changed = legacy/(names[0]+'.json'); original_json = changed.read_bytes()
                changed.write_bytes(original_json+b'\n')
                before = count('reload complete'); write(True, protect=(mode != 'self'))
                wait(lambda: count('reload complete') > before, 'encrypted configuration did not activate')
                wait(lambda: count('cleanup cert0 deferred') > 0, 'unsafe cleanup was not deferred')
                assert all((legacy/(names[0]+s)).exists() for s in suffixes)
                wait(lambda: not (legacy/(names[1]+'.key')).exists(), 'independent migrated record not cleaned')
                assert (case/'calls').read_bytes() == calls and f.ca.issued == issued
                for i, name in enumerate(names):
                    raw = (current(i)/(name+'.key')).read_bytes()
                    assert raw.startswith(b'-----BEGIN ENCRYPTED PRIVATE KEY-----')
                    decoded = serialization.load_pem_private_key(raw, passwords[i])
                    original = serialization.load_pem_private_key(saved[legacy/(name+'.key')], None)
                    assert decoded.private_numbers() == original.private_numbers()
                    assert (current(i)/(name+'.crt')).read_bytes() == saved[legacy/(name+'.crt')]
                    assert (current(i)/(name+'.json')).read_bytes() == saved[legacy/(name+'.json')]
                    assert ((current(i)/(name+'.key')).stat().st_mode & 0o777) == 0o600
                changed.write_bytes(original_json)
                if mode != 'self':
                    before = count('reload complete')
                    # Manual use still protects the old key after metadata repair.
                    wait(lambda: count('reload complete') > before, 'legacy repair did not reload')
                    assert (legacy/(names[0]+'.key')).exists()
                    assert peer_cert(f.port, 'other.test') == certs[0]
                    write(True)
                wait(lambda: not (legacy/(names[0]+'.key')).exists(), 'cleanup did not resume after repaired source/reference removal')
                assert all(not path.exists() for path in saved)
                unchanged(account_files); assert unrelated.read_bytes() == b'leave-this-record-alone'
                assert no_stage()
                assert all(not (current(i)/(name+'.migration.json')).exists() for i, name in enumerate(names))
                assert (case/'calls').read_bytes() == calls and f.ca.issued == issued
                before = count('reload complete'); time.sleep(1.3)
                assert count('reload complete') == before, 'cleanup caused an automatic reload loop'
                assert all(secret.decode() not in log.read_text() for secret in passwords)
        # Stable encrypted files work without the deleted legacy cache or CA.
        with running([binary, '-c', config], f.port, env=f.env, startup_timeout=10):
            for host, cert in zip(hosts, certs): assert peer_cert(f.port, host) == cert
        if mode == 'self':
            # Cold-start migration is also local. A failed bind must leave a
            # durable manifest and all legacy files for a later successful start.
            shutil.rmtree(encrypted)
            for path, data in saved.items(): path.write_bytes(data)
            before_calls = (case/'calls').read_bytes()
            with socket.socket() as occupied:
                occupied.bind(('0.0.0.0' if mode == 'caddy' else '127.0.0.1', 0)); occupied.listen()
                write(True, occupied.getsockname()[1])
                result = subprocess.run([binary, '-t', '-c', config], capture_output=True, timeout=5)
                assert result.returncode == 0 and not encrypted.exists(), '-t mutated the cache'
                result = subprocess.run([binary, '-c', config], capture_output=True, timeout=10, env=f.env)
                assert result.returncode != 0, 'occupied listener unexpectedly started'
                unchanged(saved)
                assert all(current(i).exists() for i in range(2))
            # Simulate stopping after rename but before unlink: the recorded
            # inode/hash lets the next activated generation finish safely.
            held = encrypted/names[0]/'cleanup'; held.mkdir(mode=0o700)
            moved = legacy/(names[0]+'.key'); moved.rename(held/moved.name)
            write(True)
            with running([binary, '-c', config], f.port, env=f.env, startup_timeout=10):
                for host, cert in zip(hosts, certs): assert peer_cert(f.port, host) == cert
                until = time.monotonic()+5
                while any(path.exists() for path in saved):
                    assert time.monotonic() < until, 'interrupted cleanup did not resume'
                    time.sleep(.05)
                assert not held.exists()
                assert (case/'calls').read_bytes() == before_calls, 'cold migration invoked ACME'
            unchanged(account_files)
        print(f'PASS: {mode} offline SNI/wildcard migration, exact key/cert preservation, rollback, changed-cache/reference protection and cleanup after reload', flush=True)
