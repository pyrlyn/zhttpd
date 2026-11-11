#!/usr/bin/env python3
"""Rotate manual certs and keys without touching configs or signalling master."""
import asyncio
from pathlib import Path
import sys
import tempfile
import time
from cryptography.hazmat.primitives import serialization
from acme_common import configure_manual, peer_cert
from e2e_common import free_port, running
from tls_common import pair, pem_cert, pem_key, der, atomic, quic_cert

binary = Path(sys.argv[1]).resolve()


for mode in (sys.argv[2:] or ('self', 'nginx', 'apache', 'litespeed', 'caddy')):
    with tempfile.TemporaryDirectory(prefix='zhttpd-tls-watch-') as directory:
        root = Path(directory); port = free_port()
        cert, key, log = root/'tls.pem', root/'tls.key', root/'master.log'
        a, ka = pair(); b, kb = pair(); c, _ = pair(kb)
        other, other_key = root/'other.pem', root/'other.key'
        atomic(cert, pem_cert(a)); atomic(key, pem_key(ka))
        atomic(other, pem_cert(a)); atomic(other_key, pem_key(ka))
        config = configure_manual(root, mode, port, cert, key, other, other_key)
        with running([binary, '-c', config], port, log_path=log) as proc:
            def count(text): return log.read_text().count(text)
            def healthy():
                assert proc.poll() is None
                assert int((root/'master.pid').read_text()) == proc.pid
                peer_cert(port)
                if mode != 'self': assert peer_cert(port, 'other.test') == der(a)
            def wait(predicate, message):
                until = time.monotonic()+12
                while time.monotonic() < until:
                    healthy()
                    if predicate(): return
                    time.sleep(.05)
                raise AssertionError(message)
            def expect(value): wait(lambda: peer_cert(port) == der(value), 'TLS rotation did not activate')
            def stable(value, seconds=1.2):
                end = time.monotonic()+seconds
                while time.monotonic() < end:
                    healthy(); assert peer_cert(port) == der(value); time.sleep(.05)
            def rejected(edit, retained):
                before = count('reload failed')
                edit()
                wait(lambda: count('reload failed') > before, 'invalid TLS material was not rejected')
                stable(retained)
                assert count('reload failed') == before+1, 'invalid pair retried without a new edit'

            # Cert and key are saved separately, well outside the debounce window.
            rejected(lambda: atomic(cert, pem_cert(b)), a)
            atomic(key, pem_key(kb)); expect(b)
            if mode == 'self': assert asyncio.run(quic_cert(port)) == der(b)

            # Certificate-only renewal with the same key, then a valid key-only
            # re-encoding: both file kinds must participate in the watch graph.
            atomic(cert, pem_cert(c)); expect(c)
            before = count('reload complete')
            atomic(key, pem_key(kb, traditional=True))
            wait(lambda: count('reload complete') > before, 'key-only rotation was not detected')
            stable(c, .3)
            rejected(lambda: atomic(key, b'private-key-test-value-not-for-logs'), c)
            atomic(key, pem_key(kb)); before = count('reload complete')
            wait(lambda: count('reload complete') > before, 'restored key did not recover')
            encrypted = kb.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                         serialization.BestAvailableEncryption(b'private-key-password-test'))
            rejected(lambda: atomic(key, encrypted), c)
            assert 'Enter PEM pass phrase' not in log.read_text(), 'reload requested an interactive password'
            before = count('reload complete')
            atomic(key, pem_key(kb))
            wait(lambda: count('reload complete') > before, 'encrypted-key recovery failed')
            rejected(key.unlink, c)
            atomic(key, pem_key(kb)); before = count('reload complete')
            wait(lambda: count('reload complete') > before, 'recreated key was not watched')
            rejected(lambda: atomic(cert, b'incomplete certificate'), c)
            atomic(cert, pem_cert(b)); expect(b)

            # Atomically replace each path with a symlink. Subsequent changes to
            # the targets must also be detected without touching the config.
            target_cert, target_key = root/'target.pem', root/'target.key'
            atomic(target_cert, pem_cert(a)); atomic(target_key, pem_key(ka))
            for path, target in ((cert, target_cert), (key, target_key)):
                link = path.with_name(path.name+'.link'); link.symlink_to(target.name); link.replace(path)
            expect(a)
            atomic(target_cert, pem_cert(b)); atomic(target_key, pem_key(kb)); expect(b)
            before = count('reload complete')
            atomic(target_cert, pem_cert(b)); atomic(target_key, pem_key(kb))
            stable(b)
            assert count('reload complete') == before, 'unchanged TLS bytes caused reload'
            assert 'private-key-test-value-not-for-logs' not in log.read_text()
            assert 'BEGIN PRIVATE KEY' not in log.read_text()
        if mode != 'self':
            # The format-neutral collector must work without a TOML wrapper too.
            with running([binary, '--compatibility', mode, '-c', root/'server.conf'], port):
                atomic(target_cert, pem_cert(a)); atomic(target_key, pem_key(ka))
                until = time.monotonic()+12
                while peer_cert(port) != der(a):
                    assert time.monotonic() < until, 'direct native TLS files not watched'
                    time.sleep(.05)
        print(f'PASS: {mode} TLS/key rotation, mismatch retention, deletion recovery, symlinks and SNI isolation', flush=True)
