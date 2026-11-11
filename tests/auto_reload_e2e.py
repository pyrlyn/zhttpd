#!/usr/bin/env python3
"""Configuration watcher contract: all adapters, dependencies and failed edits."""
import http.client
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from e2e_common import free_port, running

binary = Path(sys.argv[1]).resolve()


def get(port, host='localhost'):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
    try:
        conn.request('GET', '/', headers={'Host': host})
        response = conn.getresponse()
        assert response.status == 200, response.status
        return response.read().decode()
    finally:
        conn.close()


def atomic(path, text):
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(text)
    temp.replace(path)


for mode in (sys.argv[2:] or ('self', 'nginx', 'apache', 'litespeed', 'caddy')):
    with tempfile.TemporaryDirectory(prefix='zhttpd-watch-') as directory:
        root = Path(directory)
        port = free_port()
        for color in ('blue', 'gold'):
            (root/color).mkdir()
            (root/color/'index.html').write_text(color)
        config, native, leaf = (root/name for name in ('config.toml', 'server.conf', 'leaf.conf'))
        log = root/'master.log'

        def wrapper(enabled=True, color='blue'):
            head = f'[server]\ncompatibility="{mode}"\npid="master.pid"\nauto_reload={str(enabled).lower()}\n'
            return head + (f'[http]\nlisten="127.0.0.1:{port}"\nresponse="{color}"\n' if mode == 'self' else 'config="server.conf"\n')

        def top(include='leaf.conf'):
            if mode == 'nginx': return f'events {{}} http {{ access_log off; server {{ listen 127.0.0.1:{port}; include {include}; }} }}'
            if mode == 'apache': return f'ServerRoot "{root}"\nListen 127.0.0.1:{port}\nInclude {include}\n'
            if mode == 'litespeed': return f'virtualhost site {{\nvhRoot "{root}"\nconfigFile {include}\n}}\nlistener http {{\naddress 127.0.0.1:{port}\nsecure 0\nmap site *\n}}\n'
            return f'import {include}\n'

        def fragment(color, host='localhost'):
            if mode == 'nginx': return f'root "{root/color}";\n'
            if mode == 'apache': return f'DocumentRoot "{root/color}"\n'
            if mode == 'litespeed': return f'docRoot "{root/color}"\n'
            return f'http://{host}:{port} {{\nroot * "{root/color}"\nfile_server\n}}\n'

        config.write_text(wrapper())
        if mode != 'self':
            native.write_text(top())
            leaf.write_text(fragment('blue'))
        current = config if mode == 'self' else leaf
        render = (lambda color: wrapper(color=color)) if mode == 'self' else fragment
        with running([binary, '-c', config, '--strict'], port, log_path=log) as proc:
            def count(needle): return log.read_text().count(needle)
            def healthy():
                assert proc.poll() is None
                assert int((root/'master.pid').read_text()) == proc.pid
            def wait(predicate, message):
                until = time.monotonic()+10
                while time.monotonic() < until:
                    healthy()
                    if predicate(): return
                    time.sleep(.05)
                raise AssertionError(message)
            def expect(color, host='localhost'):
                wait(lambda: get(port, host) == color, f'{mode}: expected {color} for {host}')
            def stable(color, seconds=1.3):
                end = time.monotonic()+seconds
                while time.monotonic() < end:
                    healthy()
                    assert get(port) == color
                    time.sleep(.05)

            expect('blue')
            # Same length, preserved mtime: content changes must still be found.
            delayed = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
            delayed.connect()
            time.sleep(.1)  # accepted by the old worker, but no first request yet
            before = current.stat()
            current.write_text(render('gold'))
            os.utime(current, ns=(before.st_atime_ns, before.st_mtime_ns))
            expect('gold')
            try:
                delayed.request('GET', '/', headers={'Host': 'localhost'})
                reply = delayed.getresponse()
                assert reply.status == 200 and reply.read() == b'blue'
            finally:
                delayed.close()
            completed = count('reload complete')
            atomic(current, current.read_text())
            stable('gold')
            assert count('reload complete') == completed, 'unchanged content reloaded'

            # One debounced attempt after a burst of editor writes.
            for i in range(3):
                current.write_text(render('blue') + f'\n# edit {i}\n')
                time.sleep(.1)
            expect('blue')
            stable('blue', .7)
            assert count('reload complete') == completed+1, 'save burst caused repeated reloads'

            # Rejected content is acknowledged once; repairing only that file
            # recovers automatically. Unlink/recreate and atomic rename work too.
            failures = count('reload failed')
            current.write_text('[broken' if mode == 'self' else 'BrokenDirective {\n')
            wait(lambda: count('reload failed') > failures, 'invalid edit was not detected')
            stable('blue')
            assert count('reload failed') == failures+1, 'invalid file caused a retry loop'
            atomic(current, render('gold'))
            expect('gold')
            failures = count('reload failed')
            current.unlink()
            wait(lambda: count('reload failed') > failures, 'deleted file was not detected')
            stable('gold', .3)
            current.write_text(render('blue'))
            expect('blue')

            if mode != 'self':
                # A new dependency that failed to open must remain watched.
                failures = count('reload failed')
                atomic(native, top('new.conf'))
                wait(lambda: count('reload failed') > failures, 'missing new include did not fail')
                (root/'new.conf').write_text(fragment('gold'))
                expect('gold')
                completed = count('reload complete')
                leaf.write_text(fragment('gold'))
                stable('gold')
                assert count('reload complete') == completed, 'removed dependency is still watched'
                # The wrapper itself is watched, not just the adapter files.
                atomic(config, wrapper()+'\n# wrapper edit\n')
                wait(lambda: count('reload complete') > completed, 'TOML wrapper was not watched')
                # A symlink swap to another configuration source is visible.
                (root/'target.conf').write_text(fragment('blue'))
                link = root/'new-link.conf'
                link.symlink_to('target.conf')
                link.replace(root/'new.conf')
                expect('blue')

            # Opt-out applies when the new generation commits. Enabling again
            # requires the still-supported explicit reload while it is disabled.
            completed = count('reload complete')
            atomic(config, wrapper(enabled=False))
            wait(lambda: count('reload complete') > completed, 'opt-out was not applied')
            atomic(config, wrapper(enabled=True, color='gold'))
            if mode != 'self': (root/'target.conf').write_text(fragment('gold'))
            stable('blue')
            subprocess.run([binary, '-c', config, '-s', 'reload'], check=True)
            expect('gold')
            if mode == 'self': atomic(config, wrapper(color='blue'))
            else: (root/'target.conf').write_text(fragment('blue'))
            expect('blue')
            print(f'PASS: {mode} automatic reload, debounce, invalid/missing recovery, atomic saves and opt-out', flush=True)

        if mode == 'self': continue
        # Direct native -c files also watch their dependencies without TOML.
        native.write_text(top())
        leaf.write_text(fragment('blue'))
        with running([binary, '--compatibility', mode, '-c', native], port):
            atomic(leaf, fragment('gold'))
            until = time.monotonic()+10
            while get(port) != 'gold':
                assert time.monotonic() < until, f'{mode}: direct native config was not watched'
                time.sleep(.05)
        print(f'PASS: {mode} direct native file auto reload', flush=True)

        if mode == 'litespeed': continue  # native OLS uses explicit configFile paths
        # Adding/removing a matching file (including an initially empty glob)
        # changes the graph even when no existing source file is edited.
        sites = root/'sites'; sites.mkdir()
        native.write_text(top() + ('IncludeOptional sites/*.conf\n' if mode == 'apache' else 'import sites/*.conf\n' if mode == 'caddy' else ''))
        if mode == 'nginx': native.write_text(top().replace('include leaf.conf;', 'include leaf.conf; include sites/*.conf;'))
        leaf.write_text(fragment('blue'))
        with running([binary, '-c', config], port):
            def await_body(expected):
                until = time.monotonic()+10
                while get(port, 'dynamic.test') != expected:
                    assert time.monotonic() < until, f'{mode}: glob membership was not watched'
                    time.sleep(.05)
            await_body('blue')
            added = sites/'dynamic.conf'
            added.write_text(fragment('gold', 'dynamic.test'))
            await_body('gold')
            added.unlink()
            await_body('blue')
        print(f'PASS: {mode} empty glob, added and deleted include/import', flush=True)
