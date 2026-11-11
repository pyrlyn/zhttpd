#!/usr/bin/env python3
"""Per-key and per-ACME password sources; cached TLS, no public CA traffic."""
import asyncio
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from acme_common import configure, configure_manual, peer_cert
from e2e_common import free_port, running
from tls_common import pair, pem_cert, pem_key, der, atomic, quic_cert

binary = Path(sys.argv[1]).resolve()
pa, pb, rotated = b'sni-first-secret', b'sni-second-secret', b'sni-rotated-secret'


def checked(config, expected=None):
    result = subprocess.run([binary, '-t', '-T', '-c', config], capture_output=True, timeout=5)
    output = result.stdout+result.stderr
    assert all(secret not in output for secret in (pa, pb, rotated))
    if expected:
        assert result.returncode != 0 and expected in output, output.decode()
    else:
        assert result.returncode == 0, output.decode()


for mode in (sys.argv[2:] or ('self', 'nginx', 'apache', 'litespeed', 'caddy')):
    for managed in (False, True):
        with tempfile.TemporaryDirectory(prefix='zhttpd-sni-password-') as directory:
            root = Path(directory); port = free_port()
            log = root/'master.log'; pwa, pwb = root/'a.pass', root/'b.pass'
            cert_a, ka = pair(); cert_b, kb = pair(); cert_new, kn = pair()
            atomic(pwa, pa+b'\n'); atomic(pwb, pb+b'\n')
            manual_cert, manual_key = root/'manual.crt', root/'manual.key'
            atomic(manual_cert, pem_cert(cert_b)); atomic(manual_key, pem_key(kb))
            if managed:
                storage = root/'cache'/'certificates'; storage.mkdir(parents=True)
                ca, keya = storage/'localhost.crt', storage/'localhost.key'
                cb, keyb = storage/'dedicated.test.crt', storage/'dedicated.test.key'
                config = configure(root, mode, port, free_port(), '', manual_cert, manual_key,
                                   ['localhost', 'dedicated.test'])
                base = config.read_text().split('[acme]')[0]
                base = base.replace('[server]\n', '[server]\npid="master.pid"\n')
                if mode == 'self': base += 'http2=true\nhttp3=true\n'
                # A cached-certificate renewal fixture records scheduled checks.
                # Issuance itself is covered by the real-lego ACME E2E suite.
                client = root/'cached-client.py'
                client.write_text(f'#!{sys.executable}\nimport sys\nfrom pathlib import Path\n'
                                  f'with Path({str(root/"checks")!r}).open("a") as f: f.write(sys.argv[sys.argv.index("--cert.name")+1]+"\\n")\n')
                client.chmod(0o700)
                def record(domain, name, password):
                    return f'''[[acme.certificates]]
name="{name}"
domain="{domain}"
email="test@example.test"
accept_terms=true
client="./{client.name}"
storage="cache"
http_port={free_port()}
check_interval_seconds=3600
password_file="{password}"
'''
                first = record('localhost', 'first', 'a.pass')
                second = record('dedicated.test', 'second', 'b.pass')
                host_b = 'dedicated.test'
            else:
                ca, keya, cb, keyb = root/'a.crt', root/'a.key', root/'b.crt', root/'b.key'
                config = configure_manual(root, mode, port, ca, keya, cb, keyb)
                base = config.read_text()
                first = '[[tls.certificates]]\nkey="a.key"\npassword_file="a.pass"\n'
                second = '' if mode == 'self' else '[[tls.certificates]]\nkey="b.key"\npassword_file="b.pass"\n'
                host_b = None if mode == 'self' else 'other.test'
            atomic(ca, pem_cert(cert_a)); atomic(keya, pem_key(ka, password=pa))
            atomic(cb, pem_cert(cert_b)); atomic(keyb, pem_key(kb, password=pb))
            # Common fallback cannot decrypt either key: explicit records must win.
            atomic(root/'fallback.pass', b'fallback-only\n')
            base += '[tls]\npassword_file="fallback.pass"\n'
            original = base+first+second
            config.write_text(original)
            checked(config)
            if not managed:
                for extra, error in (
                    ('[[tls.certificates]]\nkey="./a.key"\npassword_file="b.pass"\n', b'duplicate TLS password mapping'),
                    ('[[tls.certificates]]\nkey="unknown.key"\npassword_file="b.pass"\n', b'matching manual key'),
                    ('[[tls.certificates]]\nkey="b.key"\n', b'requires nonempty'),
                ):
                    config.write_text(original+extra); checked(config, error)
                config.write_text(original)
            else:
                config.write_text(original.replace('password_file="a.pass"', 'password_file=""'))
                checked(config, b'must not be empty'); config.write_text(original)
            with running([binary, '-c', config], port, log_path=log) as process:
                expected = cert_a
                def count(text): return log.read_text().count(text)
                def healthy():
                    assert process.poll() is None
                    assert peer_cert(port) == der(expected)
                    assert int((root/'master.pid').read_text()) == process.pid
                    if host_b: assert peer_cert(port, host_b) == der(cert_b)
                def wait(predicate, message):
                    end = time.monotonic()+12
                    while time.monotonic() < end:
                        if predicate(): return
                        healthy(); time.sleep(.05)
                    raise AssertionError(message)
                def stable(seconds=.8):
                    end = time.monotonic()+seconds
                    while time.monotonic() < end: healthy(); time.sleep(.05)
                def reload(edit):
                    before = count('reload complete'); edit()
                    wait(lambda: count('reload complete') > before, 'reload did not activate')
                def reject(edit):
                    before = count('reload failed'); edit()
                    wait(lambda: count('reload failed') > before, 'bad password was not rejected')
                    stable(); assert count('reload failed') == before+1
                healthy()
                if managed:
                    wait(lambda: (root/'checks').exists() and len((root/'checks').read_text().splitlines()) == 2,
                         'initial cached ACME checks not run')
                    initial_checks = (root/'checks').read_text()
                if mode == 'self': assert asyncio.run(quic_cert(port)) == der(expected)
                reject(lambda: atomic(pwa, pb+b'\n'))
                reload(lambda: atomic(pwa, pa+b'\n'))
                # Rotate only the first key, then recover using only its password.
                def new_pair():
                    atomic(ca, pem_cert(cert_new)); atomic(keya, pem_key(kn, password=rotated))
                reject(new_pair)
                before = count('reload complete'); atomic(pwa, rotated+b'\n')
                wait(lambda: count('reload complete') > before, 'per-certificate password recovery failed')
                expected = cert_new; healthy()
                if mode == 'self': assert asyncio.run(quic_cert(port)) == der(expected)
                if host_b:
                    reject(pwb.unlink)
                    reload(lambda: atomic(pwb, pb+b'\n'))
                    reload(lambda: atomic(pwb, b'wrong-first\n'+pb+b'\n'))
                # Reorder records: password ownership follows the key/certificate.
                if second: reload(lambda: config.write_text(base+second+first))
                # A newly referenced missing password is watched after rejection.
                reject(lambda: config.write_text((base+second+first).replace('password_file="a.pass"',
                                                                            'password_file="new.pass"')))
                reload(lambda: atomic(root/'new.pass', rotated+b'\n'))
                # Removed dependencies stop triggering reloads.
                before = count('reload complete'); failures = count('reload failed')
                atomic(pwa, b'unused-old-file\n'); stable(1.2)
                assert count('reload complete') == before and count('reload failed') == failures
                # Removing the override restores the ordinary global fallback.
                atomic(root/'fallback.pass', rotated+b'\n')
                current = config.read_text()
                fallback = current.replace('password_file="new.pass"\n', '') if managed else current.replace(
                    '[[tls.certificates]]\nkey="a.key"\npassword_file="new.pass"\n', '')
                reload(lambda: config.write_text(fallback)); healthy()
                if managed:
                    assert (root/'checks').read_text() == initial_checks, 'password reload reset ACME deadlines'
                assert all(secret.decode() not in log.read_text() for secret in (pa, pb, rotated))
            print(f'PASS: {mode} {"ACME" if managed else "manual"} per-certificate passwords, isolation, reorder, fallback and automatic recovery', flush=True)
