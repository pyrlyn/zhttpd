#!/usr/bin/env python3
"""Real lego: private staging, encrypted SNI generations and safe publication."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from acme_common import configure, local_ca, peer_cert
from e2e_common import running
from tls_common import atomic

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=Path)
parser.add_argument('modes', nargs='*')
parser.add_argument('--challenge', choices=['http-01', 'dns-01'])
args = parser.parse_args(); binary = args.binary.resolve()
pa, pb, rotated = b'encryption-first-secret', b'encryption-second-secret', b'encryption-rotated-secret'

for mode in (args.modes or ('self', 'nginx', 'apache', 'litespeed', 'caddy')):
    for challenge in ([args.challenge] if args.challenge else ('http-01', 'dns-01')):
        with local_ca() as f:
            f.ca.challenge_type = challenge
            case = f.root/mode; case.mkdir()
            first = 'localhost' if challenge == 'http-01' else '*.example.test'
            host = first.replace('*.', 'www.')
            cert_name = first.replace('*.', '_.')
            pw = case/'first.pass'; pw2 = case/'second.pass'
            atomic(pw, pa+b'\n'); atomic(pw2, pb+b'\n')
            log = case/'master.log'; gate = case/'gate'; started = case/'started'
            client = case/'client.py'
            client.write_text(f'#!{sys.executable}\n'+f'''import pathlib, subprocess, sys, time
root = pathlib.Path({str(case)!r})
status = subprocess.call([{shutil.which('lego')!r}, *sys.argv[1:]])
if status == 0 and (root/'corrupt').exists():
    path = pathlib.Path(sys.argv[sys.argv.index('--path')+1])/'certificates'/(sys.argv[sys.argv.index('--cert.name')+1]+'.key')
    path.write_bytes((root/'replacement.key').read_bytes())
if status == 0 and (root/'gate').exists() and (root/'gate').read_text() == sys.argv[sys.argv.index('--cert.name')+1]:
    (root/'started').touch()
    while (root/'gate').exists(): time.sleep(.05)
sys.exit(status)
'''); client.chmod(0o700)
            check_interval = 3600
            def write(renew=1, add=False, timeout=30, check=False):
                global check_interval
                if check: check_interval -= 1
                domains = [first, 'third.test', 'dedicated.test'] if add else [first, 'dedicated.test']
                config = configure(case, mode, f.port, f.challenge, f.ca.url, f.root/'server.pem', f.root/'key.pem', domains)
                text = config.read_text().split('[acme]')[0].replace('[server]\n', '[server]\npid="master.pid"\n')
                if mode == 'self': text += 'http2=true\nhttp3=true\n'
                records = [('first', first, pw.name, renew), ('second', 'dedicated.test', pw2.name, 1)]
                if add: records.append(('third', 'third.test', 'third.pass', 1))
                for name, domain, password, days in records:
                    text += f'''[[acme.certificates]]
name="{name}"
domain="{domain}"
email="test@example.test"
directory="{f.ca.url}/directory"
client="./client.py"
storage="certificates"
accept_terms=true
encrypt_key=true
password_file="{password}"
challenge="{challenge}"
http_port={f.challenge}
renew_before_days={days}
check_interval_seconds={check_interval if name == 'first' else 3600}
operation_timeout_seconds={timeout}
'''
                    if challenge == 'dns-01': text += f'dns_provider="httpreq"\ndns_resolvers=["127.0.0.1:{f.dns.server_address[1]}"]\ndns_propagation_wait_seconds=1\n'
                config.write_text(text)
                return config
            config = write()
            def checked(ok, expected=b''):
                r = subprocess.run([binary, '-t', '-c', config], capture_output=True, timeout=5)
                assert (r.returncode == 0) == ok, r.stderr.decode()
                assert expected in r.stderr
            original = config.read_text()
            config.write_text(original.replace('password_file="first.pass"\n', ''))
            checked(False, b'encrypt_key requires'); config.write_text(original)
            saved = pw.read_bytes(); pw.unlink()
            checked(False, b'cannot read encryption password'); atomic(pw, saved)
            checked(True); assert f.ca.issued == 0
            store = case/'certificates'/'encrypted'
            current = store/cert_name/'current'; current2 = store/'dedicated.test'/'current'
            def disk(path, name, password):
                raw = (path/(name+'.key')).read_bytes()
                assert raw.startswith(b'-----BEGIN ENCRYPTED PRIVATE KEY-----')
                key = serialization.load_pem_private_key(raw, password)
                cert = x509.load_pem_x509_certificate((path/(name+'.crt')).read_bytes())
                assert key.public_key().public_numbers() == cert.public_key().public_numbers()
                assert ((path/(name+'.key')).stat().st_mode & 0o777) == 0o600
                assert (path.resolve().stat().st_mode & 0o777) == 0o700
                return raw, cert.public_bytes(serialization.Encoding.DER)
            def no_staging(): return not list(store.glob('*/work-*'))
            if mode == 'self' and challenge == 'http-01':
                stale = store/cert_name/'work-stale'; stale.mkdir(parents=True, mode=0o700)
                (stale/'leftover.key').write_text('crashed-client-plaintext')
                outside = case/'keep'; outside.mkdir(); (outside/'marker').touch()
                (stale/'external-link').symlink_to(outside)
            with running([binary, '-c', config], f.port, env=f.env, startup_timeout=40, log_path=log) as proc:
                def count(text): return log.read_text().count(text)
                def healthy():
                    assert proc.poll() is None
                    peer_cert(f.port, host)
                    assert int((case/'master.pid').read_text()) == proc.pid
                    assert peer_cert(f.port, 'dedicated.test') == second_cert
                def wait(predicate, message):
                    until = time.monotonic()+30
                    while time.monotonic() < until:
                        if predicate(): return
                        healthy(); time.sleep(.1)
                    raise AssertionError(message)
                first_cert = peer_cert(f.port, host)
                second_cert = peer_cert(f.port, 'dedicated.test')
                wait(no_staging, 'initial cached checks did not finish')
                if mode == 'self' and challenge == 'http-01':
                    assert not stale.exists() and (outside/'marker').exists()
                first_raw, first_disk = disk(current, cert_name, pa)
                second_raw, second_disk = disk(current2, 'dedicated.test', pb)
                assert (first_disk, second_disk) == (first_cert, second_cert)
                assert not list((case/'certificates').glob('certificates/*.key'))
                # A renewal policy change queues the first job. Password-only
                # changes are handled locally without invoking lego.
                write(renew=30); atomic(pw, pa+b'\nextra-password\n')
                wait(lambda: peer_cert(f.port, host) != first_cert, 'renewed encrypted certificate not reloaded')
                wait(no_staging, 'renewal left plaintext staging')
                renewed = peer_cert(f.port, host); disk(current, cert_name, pa)
                assert disk(current2, 'dedicated.test', pb)[0] == second_raw

                # Re-encrypt an unchanged key with the first passphrase. Keep
                # the old one on a second line until the new generation commits.
                write(renew=1); issued = f.ca.issued
                atomic(pw, rotated+b'\n'+pa+b'\n')
                def new_password_works():
                    try: disk(current, cert_name, rotated)
                    except ValueError: return False
                    return True
                wait(new_password_works, 'password rotation did not re-encrypt cached key')
                wait(no_staging, 're-encryption left staging files')
                assert f.ca.issued == issued and peer_cert(f.port, host) == renewed
                before = count('reconfiguring')
                atomic(pw, rotated+b'\n')
                wait(lambda: count('reconfiguring') > before, 'password-only reload not detected')
                wait(no_staging, 'no-op renewal did not finish')
                time.sleep(1.3)  # Let the config reload and its scheduled no-op finish.
                before = count('reload complete'); time.sleep(1.3)
                assert count('reload complete') == before, 'no-op encryption caused a reload loop'

                # Hold a real successful renewal before child exit. Corrupt the
                # password while held: old generation and HTTPS must survive.
                old_target = os.readlink(current); old_disk = disk(current, cert_name, rotated)
                gate.write_text(cert_name); started.unlink(missing_ok=True)
                write(renew=30); atomic(pw, rotated+b'\nextra-again\n')
                wait(started.exists, 'post-lego gate not reached')
                assert os.readlink(current) == old_target and peer_cert(f.port, host) == renewed
                assert list(store.glob('*/work-*/certificates/*.key')), 'staged key was not exercised'
                atomic(pw, b'')
                before = count('encrypted ACME publication'); gate.unlink()
                wait(lambda: count('encrypted ACME publication') > before, 'invalid final password did not reject publication')
                wait(no_staging, 'failed encryption left staging')
                assert os.readlink(current) == old_target
                assert disk(current, cert_name, rotated) == old_disk
                assert peer_cert(f.port, host) == renewed
                atomic(pw, rotated+b'\nrecovery\n')
                write(renew=30, check=True)
                wait(lambda: peer_cert(f.port, host) != renewed, 'fixed password did not retry renewal')
                wait(no_staging, 'recovered renewal left staging')
                stable = peer_cert(f.port, host)

                if mode == 'self' and challenge == 'http-01':
                    # A valid PEM with the wrong key must fail before replacing
                    # either published file, even though lego itself succeeded.
                    old_target = os.readlink(current)
                    (case/'replacement.key').write_bytes((f.root/'key.pem').read_bytes())
                    (case/'corrupt').touch(); before = count('encrypted ACME publication')
                    atomic(pw, rotated+b'\npair-failure\n')
                    write(renew=30, check=True)
                    wait(lambda: count('encrypted ACME publication') > before, 'mismatched issued key not rejected')
                    wait(no_staging, 'mismatched pair left staging')
                    assert os.readlink(current) == old_target and peer_cert(f.port, host) == stable
                    assert 'IssuedKeyMismatch' in log.read_text()
                    (case/'corrupt').unlink()
                    write(renew=1); atomic(pw, rotated+b'\nvalid-again\n')
                    before = count('reconfiguring')
                    wait(lambda: count('reconfiguring') > before, 'repair reload not observed')
                    time.sleep(1)
                    wait(no_staging, 'repair check did not finish')

                    # Cancel a pending third certificate after lego writes its
                    # plaintext key. An intervening worker generation must not
                    # inherit the staging lock and block a later retry.
                    atomic(case/'third.pass', b'third-encryption-secret\n')
                    gate.write_text('third.test'); started.unlink(missing_ok=True)
                    write(add=True)
                    wait(started.exists, 'pending encrypted issuance not gated')
                    assert not (store/'third.test'/'current').exists()
                    before = count('reload complete'); write()
                    wait(lambda: count('reload complete') > before, 'replacement config did not supersede issuance')
                    gate.unlink(); wait(no_staging, 'cancelled issuance left plaintext staging')
                    assert not (store/'third.test'/'current').exists(), 'cancelled issuance published a generation'
                    (case/'third.pass').unlink()

                # Add a managed SNI certificate through automatic reload. The
                # missing password prevents CA traffic; its creation alone retries.
                issued = f.ca.issued; before = count('reload failed')
                write(add=True)
                wait(lambda: count('reload failed') > before, 'missing new password did not reject config')
                assert f.ca.issued == issued
                atomic(case/'third.pass', b'third-encryption-secret\n')
                third_current = store/'third.test'/'current'
                def third_active():
                    if not third_current.exists(): return False
                    try: return peer_cert(f.port, 'third.test') != stable
                    except (AssertionError, OSError): return False
                wait(third_active, 'added SNI encryption did not activate')
                wait(no_staging, 'added certificate left staging')
                assert disk(third_current, 'third.test', b'third-encryption-secret')[1] == peer_cert(f.port, 'third.test')
                write(); before = count('reload complete')
                wait(lambda: count('reload complete') > before, 'removed encrypted certificate not reloaded')
                # Failed CA checks preserve both encrypted files and active TLS.
                f.ca.fail = True; before = count('ACME renewal first failed')
                write(renew=30, timeout=3); atomic(pw, rotated+b'\nca-failure\n')
                wait(lambda: count('ACME renewal first failed') > before, 'CA failure not exercised')
                wait(no_staging, 'failed CA left staging')
                assert peer_cert(f.port, host) == stable
                checked(True)
                assert all(s.decode() not in log.read_text() for s in (pa, pb, rotated))
            assert no_staging()
            # Encrypted generations can restart offline; account data persists
            # outside ephemeral lego staging directories.
            with running([binary, '-c', config], f.port, env=f.env, startup_timeout=10):
                assert peer_cert(f.port, host) == stable
                assert peer_cert(f.port, 'dedicated.test') == second_cert
            assert no_staging()
            print(f'PASS: {mode} {challenge} encrypted issuance/renewal, SNI isolation, re-encryption, atomic failure retention, reload addition and offline restart', flush=True)
