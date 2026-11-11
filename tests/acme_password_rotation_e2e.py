#!/usr/bin/env python3
"""Per-SNI password changes re-encrypt locally, including with ACME offline."""
import os
import hashlib
import json
import fcntl
from pathlib import Path
import shutil
import signal
import socket
import sys
import time
from cryptography.hazmat.primitives import serialization
from acme_common import configure, local_ca, peer_cert
from e2e_common import running
from tls_common import atomic

binary = Path(sys.argv[1]).resolve()
for mode in (sys.argv[2:] or ('self', 'nginx', 'apache', 'litespeed', 'caddy')):
    with local_ca() as f:
        case = f.root/mode; case.mkdir()
        domains = ('localhost', 'dedicated.test')
        passwords = (b'first-old-secret', b'second-old-secret')
        for i, password in enumerate(passwords): atomic(case/f'{i}.pass', password+b'\n')
        client = case/'client.py'
        client.write_text(f'#!{sys.executable}\n'+f'''import pathlib, subprocess, sys
root = pathlib.Path({str(case)!r})
with (root/'calls').open('a') as out: out.write('called\\n')
if (root/'offline').exists(): sys.exit(71)
sys.exit(subprocess.call([{shutil.which('lego')!r}, *sys.argv[1:]]))
'''); client.chmod(0o700)
        def write(port=None, second_path='1.pass', auto=True, protect=None):
            config = configure(case, mode, port or f.port, f.challenge, f.ca.url,
                               f.root/'server.pem', f.root/'key.pem', domains)
            text = config.read_text().split('[acme]')[0].replace('[server]\n',
                    f'[server]\npid="master.pid"\nauto_reload={str(auto).lower()}\n')
            for i, domain in enumerate(domains):
                text += f'''[[acme.certificates]]
name="cert{i}"
domain="{domain}"
email="test@example.test"
directory="{f.ca.url}/directory"
client="./client.py"
storage="certificates"
accept_terms=true
encrypt_key=true
password_file="{'0.pass' if i == 0 else second_path}"
http_port={f.challenge}
renew_before_days=30
check_interval_seconds=3600
'''
            if protect is not None and mode != 'self':
                for suffix in ('crt', 'key'):
                    alias = case/f'manual.{suffix}'; alias.unlink(missing_ok=True)
                    alias.symlink_to(protect/f'dedicated.test.{suffix}')
                source = case/('manual.conf' if mode == 'litespeed' else 'sites.caddy' if mode == 'caddy' else 'server.conf')
                source.write_text(source.read_text().replace(str(f.root/'server.pem'), str(case/'manual.crt'))
                                  .replace(str(f.root/'key.pem'), str(case/'manual.key')))
                text += '[[tls.certificates]]\nkey="manual.key"\npassword_file="1.pass"\n'
            config.write_text(text)
            return config
        config = write(); log = case/'master.log'
        store = case/'certificates'/'encrypted'
        def keyfile(i): return store/domains[i]/'current'/(domains[i]+'.key')
        def certfile(i): return store/domains[i]/'current'/(domains[i]+'.crt')
        def decoded(i, password):
            return serialization.load_pem_private_key(keyfile(i).read_bytes(), password).private_numbers()
        def no_stage(): return not list(store.glob('*/work-*'))
        with running([binary, '-c', config], f.port, env=f.env, startup_timeout=40, log_path=log) as proc:
            def count(text): return log.read_text().count(text)
            def wait(predicate, message):
                until = time.monotonic()+20
                while time.monotonic() < until:
                    if predicate(): return
                    assert proc.poll() is None
                    for domain in domains: peer_cert(f.port, domain)
                    time.sleep(.05)
                raise AssertionError(message+'\n'+log.read_text())
            wait(lambda: (case/'calls').exists() and len((case/'calls').read_text().splitlines()) >= 4 and no_stage(),
                 'initial checks not completed')
            time.sleep(.5)
            certs = [peer_cert(f.port, domain) for domain in domains]
            pem = [certfile(i).read_bytes() for i in range(2)]
            keys = [decoded(i, passwords[i]) for i in range(2)]
            old_second = keyfile(1).read_bytes()
            old_first = keyfile(0).read_bytes()
            first_generation = keyfile(0).parent.resolve()
            calls = (case/'calls').read_bytes(); issued = f.ca.issued
            (case/'offline').touch(); f.ca.fail = True
            def preserved():
                assert (case/'calls').read_bytes() == calls, 'password change invoked lego'
                assert f.ca.issued == issued
                assert int((case/'master.pid').read_text()) == proc.pid
                assert [peer_cert(f.port, domain) for domain in domains] == certs
                assert [certfile(i).read_bytes() for i in range(2)] == pem
                assert no_stage()
            def decrypts(i, password):
                try: return decoded(i, password) == keys[i]
                except ValueError: return False

            # Even a certificate within its renewal window rotates without CA.
            new = b'first-new-secret'; before = count('reload complete')
            atomic(case/'0.pass', new+b'\n'+passwords[0]+b'\n')
            wait(lambda: count('reload complete') > before and decrypts(0, new), 'local rotation failed')
            wait(lambda: not first_generation.exists(), 'old first generation survived successful activation')
            assert not decrypts(0, passwords[0])
            assert keyfile(1).read_bytes() == old_second
            preserved()
            # Removing fallback passwords must neither re-encrypt nor renew.
            stable = keyfile(0).read_bytes(); before = count('reload complete')
            atomic(case/'0.pass', new+b'\n')
            wait(lambda: count('reload complete') > before, 'fallback removal not reloaded')
            assert keyfile(0).read_bytes() == stable; preserved()

            # Invalid input on another SNI entry rejects the whole candidate.
            next_password = b'first-next-secret'; before = count('reload failed')
            atomic(case/'1.pass', b'wrong-password\n')
            atomic(case/'0.pass', next_password+b'\n'+new+b'\n')
            wait(lambda: count('reload failed') > before, 'invalid SNI password accepted')
            assert keyfile(0).read_bytes() == stable; preserved()

            # Publication can precede a failed bind, but loaded TLS stays alive
            # and both old/new password lines permit recovery of either pair.
            with socket.socket() as occupied:
                occupied.bind(('0.0.0.0' if mode == 'caddy' else '127.0.0.1', 0)); occupied.listen()
                before = count('reload failed'); retained = keyfile(0).parent.resolve()
                write(port=occupied.getsockname()[1])
                atomic(case/'1.pass', passwords[1]+b'\n')
                wait(lambda: count('reload failed') > before and decrypts(0, next_password), 'bind failure not exercised')
                assert retained.exists(), 'old generation removed before activation'
                intermediate = keyfile(0).parent.resolve()
                next_again = b'first-retry-secret'; before = count('reload failed')
                atomic(case/'0.pass', next_again+b'\n'+next_password+b'\n'+new+b'\n')
                wait(lambda: count('reload failed') > before and decrypts(0, next_again), 'second failed rotation not exercised')
                assert retained.exists() and intermediate.exists(), 'prepare removed a rollback generation'
                next_password = next_again
                preserved()
                before = count('reload complete'); write()
                wait(lambda: count('reload complete') > before, 'rotation recovery failed')
                wait(lambda: not retained.exists() and not intermediate.exists(), 'retained generations not cleaned after recovery')
            preserved()
            # A changed per-record password_file path rotates only that key.
            second_new = b'second-new-secret'; stable = keyfile(0).read_bytes()
            second_generation = keyfile(1).parent.resolve()
            atomic(case/'second-new.pass', second_new+b'\n'+passwords[1]+b'\n')
            before = count('reload complete'); write(second_path='second-new.pass', protect=second_generation)
            wait(lambda: count('reload complete') > before and decrypts(1, second_new), 'second SNI rotation failed')
            assert keyfile(0).read_bytes() == stable; preserved()
            if mode != 'self':
                wait(lambda: 'RetiredGenerationInUse' in log.read_text(), 'manual TLS reference not protected')
                assert second_generation.exists()
                assert peer_cert(f.port, 'other.test') == certs[1]
                # A retargeted alias fails reload with the old manual password.
                # Timer retries must still protect the old, actually loaded key.
                before = count('reload failed')
                for suffix in ('crt', 'key'):
                    alias = case/f'manual.{suffix}'; alias.unlink()
                    alias.symlink_to(keyfile(1).parent/f'dedicated.test.{suffix}')
                wait(lambda: count('reload failed') > before, 'invalid alias retarget not rejected')
                time.sleep(3.5)
                assert second_generation.exists(), 'retry deleted an active manual TLS generation'
                before = count('reload complete'); write(second_path='second-new.pass')
                wait(lambda: count('reload complete') > before, 'manual reference removal not activated')
            wait(lambda: not second_generation.exists(), 'old second generation not cleaned')
            for i in range(2): assert keyfile(i).stat().st_mode & 0o777 == 0o600
            before = count('reload complete'); time.sleep(1.5)
            assert count('reload complete') == before, 'rotation reload loop'
            if mode == 'self':
                before = count('reload complete'); write(second_path='second-new.pass', auto=False)
                wait(lambda: count('reload complete') > before, 'auto reload disable failed')
                final = b'manual-trigger-secret'; stable = keyfile(0).read_bytes()
                atomic(case/'0.pass', final+b'\n'+next_password+b'\n')
                time.sleep(1.2); assert keyfile(0).read_bytes() == stable
                before = count('reload complete'); os.kill(proc.pid, signal.SIGHUP)
                wait(lambda: count('reload complete') > before and decrypts(0, final), 'manual reload rotation failed')
                preserved()
            assert all(secret.decode() not in log.read_text() for secret in (*passwords, new, next_password, second_new))
        # Model a crash after the durable retirement rename and one unlink,
        # plus a second SNI journal whose source was changed externally.
        recovery = []
        for i, raw in enumerate((old_first, old_second)):
            folder = store/domains[i]/f'gen-RECOV{i}'; folder.mkdir(mode=0o700)
            entries = []
            for suffix, data in (('.crt', pem[i]), ('.key', raw)):
                path = folder/(domains[i]+suffix); path.write_bytes(data); path.chmod(0o600)
                entries.append(dict(inode=path.stat().st_ino, size=len(data), hash=list(hashlib.sha256(data).digest())))
            (folder/'retirement.json').write_text(json.dumps(dict(version=1, inode=folder.stat().st_ino, files=entries+[None]*3)))
            if i == 0:
                held = folder.with_name('.retired-'+folder.name); folder.rename(held); folder = held
                (folder/(domains[i]+'.crt')).unlink()
                (folder/(domains[i]+'.key')).rename(folder/'.unlink-1')
            else:
                (folder/(domains[i]+'.key')).write_bytes(raw+b'\n')
            recovery.append(folder)
        restart_log = case/'restart.log'
        unknown = store/domains[0]/'gen-KEEP00'; unknown.mkdir()
        (unknown/'unrecognized.data').write_text('retain this file')
        with running([binary, '-c', config], f.port, env=f.env, startup_timeout=10, log_path=restart_log) as proc:
            until = time.monotonic()+10
            while recovery[0].exists() or 'RetiredGenerationChanged' not in restart_log.read_text():
                assert time.monotonic() < until, restart_log.read_text()
                time.sleep(.05)
            assert recovery[1].exists(), 'changed generation was deleted'
            assert (unknown/'unrecognized.data').read_text() == 'retain this file'
            assert [peer_cert(f.port, domain) for domain in domains] == certs
            # File repair and lock release retry without reloading config or
            # restarting workers, even with auto_reload=false in self mode.
            baseline_reloads = restart_log.read_text().count('reload complete')
            active_keys = [keyfile(i).read_bytes() for i in range(2)]
            def retry_wait(predicate, message):
                until = time.monotonic()+40
                while not predicate():
                    assert time.monotonic() < until, message+'\n'+restart_log.read_text()
                    assert proc.poll() is None
                    time.sleep(.05)
            with (store/domains[1]/'lock').open('r+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                (recovery[1]/(domains[1]+'.key')).write_bytes(old_second)
                retry_wait(lambda: 'cleanup cert1 deferred: EncryptionBusy' in restart_log.read_text(), 'busy cleanup not retried')
                assert recovery[1].exists()
                # Clearing another SNI record is independent of this lock.
                (unknown/'unrecognized.data').unlink(); unknown.rmdir()
                retry_wait(lambda: 'cleanup cert0 completed after retry' in restart_log.read_text(), 'independent retry blocked')
                assert recovery[1].exists()
                assert restart_log.read_text().count('cleanup cert1 deferred: EncryptionBusy') == 1, 'same error repeatedly logged'
            until = time.monotonic()+40
            while recovery[1].exists():
                assert time.monotonic() < until, 'repaired retirement did not resume'
                time.sleep(.05)
            retry_wait(lambda: 'cleanup cert1 completed after retry' in restart_log.read_text(), 'retry completion not logged')
            assert restart_log.read_text().count('reload complete') == baseline_reloads, 'cleanup triggered reload'
            assert int((case/'master.pid').read_text()) == proc.pid
            assert [keyfile(i).read_bytes() for i in range(2)] == active_keys
            assert [peer_cert(f.port, domain) for domain in domains] == certs
            # Never traverse a replaced generation directory to delete secrets.
            outside = case/'outside'; outside.mkdir(); (outside/'sentinel').write_text('keep')
            (store/domains[0]/'gen-SYMLNK').symlink_to(outside, target_is_directory=True)
            before = restart_log.read_text().count('reload complete'); os.kill(proc.pid, signal.SIGHUP)
            until = time.monotonic()+10
            while restart_log.read_text().count('reload complete') == before:
                assert time.monotonic() < until
                time.sleep(.05)
            assert (outside/'sentinel').read_text() == 'keep'
            assert [peer_cert(f.port, domain) for domain in domains] == certs
            retry_wait(lambda: 'cleanup cert0 deferred: OpenGenerationDirectory' in restart_log.read_text(), 'symlink cleanup was not deferred')
            before = restart_log.read_text().count('reload complete')
            completed = restart_log.read_text().count('cleanup cert0 completed after retry')
            (store/domains[0]/'gen-SYMLNK').unlink()
            retry_wait(lambda: restart_log.read_text().count('cleanup cert0 completed after retry') > completed, 'symlink repair not retried')
            assert restart_log.read_text().count('reload complete') == before
            assert (outside/'sentinel').read_text() == 'keep'
        print(f'PASS: {mode} offline SNI rotation, activation-gated cleanup, crash recovery and independent automatic retries without reload', flush=True)
