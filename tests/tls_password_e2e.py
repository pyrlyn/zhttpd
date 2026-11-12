#!/usr/bin/env python3
"""Encrypted PEM passwords, safe live rotation, and adapter precedence."""
import asyncio
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from cryptography.hazmat.primitives.asymmetric import rsa
from acme_common import configure_manual, peer_cert
from e2e_common import free_port, running
from tls_common import pair, pem_cert, pem_key, der, atomic, quic_cert

binary = Path(sys.argv[1]).resolve()
# Spaces, # and quotes are literal bytes, not TOML/env-file syntax.
old = b"  #password-test-'old'  "
new = b'password-test-new'
other = b'password-test-other'


def checked(config, valid=True, *args):
    result = subprocess.run([binary, '-t', '-c', config, *args], capture_output=True, timeout=5)
    output = result.stdout + result.stderr
    assert (result.returncode == 0) == valid, output.decode()
    for secret in (old, new, other): assert secret not in output
    assert b'Enter PEM pass phrase' not in output


for mode in (sys.argv[2:] or ('self', 'nginx', 'apache', 'litespeed', 'caddy')):
    with tempfile.TemporaryDirectory(prefix='zhttpd-tls-password-') as directory:
        root = Path(directory); port = free_port()
        cert, key, log = root/'tls.pem', root/'tls.key', root/'master.log'
        password = root/'tls passwords.txt'
        a, ka = pair(); b, kb = pair()
        oc, ok = pair(rsa.generate_private_key(public_exponent=65537, key_size=2048))
        other_cert, other_key = root/'other.pem', root/'other.key'
        atomic(cert, pem_cert(a)); atomic(key, pem_key(ka, password=old))
        atomic(other_cert, pem_cert(oc)); atomic(other_key, pem_key(ok, traditional=True, password=other))
        atomic(password, b'wrong-first\r\n\r\n'+old+b'\r\n'+other)
        config = configure_manual(root, mode, port, cert, key, other_cert, other_key)
        original = config.read_text()
        config.write_text(original+'[tls]\npassword_file="tls passwords.txt"\n')
        checked(config, True, '-T')
        with running([binary, '-c', config], port, log_path=log) as proc:
            def count(text): return log.read_text().count(text)
            def healthy():
                assert proc.poll() is None
                assert int((root/'master.pid').read_text()) == proc.pid
                if mode != 'self': assert peer_cert(port, 'other.test') == der(oc)
            def wait(predicate, message):
                until = time.monotonic()+12
                while time.monotonic() < until:
                    healthy()
                    if predicate(): return
                    time.sleep(.05)
                raise AssertionError(message)
            def stable(expected, seconds=.9):
                until = time.monotonic()+seconds
                while time.monotonic() < until:
                    healthy(); assert peer_cert(port) == der(expected); time.sleep(.05)
            def rejected(edit, expected):
                before = count('reload failed'); edit()
                wait(lambda: count('reload failed') > before, 'invalid password/key was not rejected')
                stable(expected)
                assert count('reload failed') == before+1, 'unchanged failure retried'
            def reloaded(edit):
                before = count('reload complete'); edit()
                wait(lambda: count('reload complete') > before, 'password file change did not reload')
            def passwords(value): return value+b'\n'+other+b'\n'

            stable(a, .1)
            if mode == 'self':
                context = ssl._create_unverified_context(); context.set_alpn_protocols(['h2'])
                with socket.create_connection(('127.0.0.1', port), timeout=3) as raw:
                    with context.wrap_socket(raw, server_hostname='localhost') as tls:
                        assert tls.selected_alpn_protocol() == 'h2'
                assert asyncio.run(quic_cert(port)) == der(a)
            # Save an encrypted key/certificate first. Only fixing the password
            # file may activate the pair; master and unrelated SNI stay alive.
            def replace_pair():
                atomic(cert, pem_cert(b)); atomic(key, pem_key(kb, password=new))
            rejected(replace_pair, a)
            reloaded(lambda: atomic(password, passwords(new)))
            stable(b, .1)
            if mode == 'self': assert asyncio.run(quic_cert(port)) == der(b)

            # Same-size and same-mtime edits must be detected by content.
            def wrong_password():
                meta = password.stat()
                atomic(password, passwords(b'x'*len(new)))
                os.utime(password, ns=(meta.st_atime_ns, meta.st_mtime_ns))
            rejected(wrong_password, b)
            reloaded(lambda: atomic(password, passwords(new)))
            rejected(password.unlink, b)
            reloaded(lambda: atomic(password, passwords(new)))
            for invalid in (b'', b'bad\x00value', b'x'*1024, b'x'*65537):
                rejected(lambda: atomic(password, invalid), b)
                checked(config, False)
                reloaded(lambda: atomic(password, passwords(new)))
            def fifo():
                password.unlink(); os.mkfifo(password, 0o600)
            rejected(fifo, b)
            checked(config, False)  # bounded timeout: never wait for FIFO input
            reloaded(lambda: atomic(password, passwords(new)))

            # Symlink target changes and password-first rotation with overlap.
            target = root/'actual.passwords'
            atomic(target, passwords(old+b'\n'+new))
            def link_password():
                link = root/'password.link'; link.symlink_to(target.name); link.replace(password)
            reloaded(link_password)
            reloaded(lambda: atomic(key, pem_key(kb, traditional=True, password=old)))
            reloaded(lambda: atomic(target, passwords(old)))
            before = count('reload complete')
            atomic(target, passwords(old)); stable(b)
            assert count('reload complete') == before, 'identical password bytes caused reload'
            assert all(secret.decode() not in log.read_text() for secret in (old, new, other))
            assert 'Enter PEM pass phrase' not in log.read_text()

        # Native self setting overrides a common default, including an absent one.
        if mode == 'self':
            config.write_text(original.replace('[http.tls]\n', '[http.tls]\npassword_file="tls passwords.txt"\n')
                              +'[tls]\npassword_file="unused-missing-file"\n')
            checked(config)
            with running([binary, '-c', config], port, log_path=log):
                assert peer_cert(port) == der(b)
                # A newly configured, missing password dependency remains
                # watched after rejection; creating it alone retries the reload.
                before = log.read_text().count('reload failed')
                config.write_text(config.read_text().replace('password_file="tls passwords.txt"',
                                                             'password_file="new.password"'))
                until = time.monotonic()+12
                while log.read_text().count('reload failed') == before:
                    assert time.monotonic() < until, 'missing new password file not rejected'
                    assert peer_cert(port) == der(b); time.sleep(.05)
                before = log.read_text().count('reload complete')
                atomic(root/'new.password', old+b'\n')
                until = time.monotonic()+12
                while log.read_text().count('reload complete') == before:
                    assert time.monotonic() < until, 'new password dependency not watched'
                    assert peer_cert(port) == der(b); time.sleep(.05)
        elif mode == 'nginx':
            # Standard http inheritance and server override also work directly,
            # without TOML; both password files participate in automatic reload.
            second = root/'other.password'; atomic(second, other+b'\n')
            source = root/'server.conf'
            source.write_text(source.read_text().replace('http {', 'http { ssl_password_file "tls passwords.txt";')
                              .replace('server_name other.test;', 'server_name other.test; ssl_password_file other.password;'))
            config.write_text(original+'[tls]\npassword_file="unused-missing-file"\n')
            checked(config)
            with running([binary, '-c', source], port, log_path=log):
                assert peer_cert(port) == der(b)
                assert peer_cert(port, 'other.test') == der(oc)
                before = log.read_text().count('reload complete')
                atomic(second, b'wrong-first\n'+other+b'\n')
                until = time.monotonic()+12
                while log.read_text().count('reload complete') == before:
                    assert time.monotonic() < until, 'native nginx password override not watched'
                    assert peer_cert(port, 'other.test') == der(oc)
                    time.sleep(.05)
                atomic(cert, pem_cert(a)); atomic(key, pem_key(ka, password=new))
                atomic(target, new+b'\n')
                until = time.monotonic()+12
                while peer_cert(port) != der(a):
                    assert time.monotonic() < until, 'native inherited nginx password not watched'
                    time.sleep(.05)
        print(f'PASS: {mode} encrypted PEM, password rotation/recovery, SNI isolation and secret-free diagnostics', flush=True)
