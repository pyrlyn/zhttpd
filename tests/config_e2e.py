#!/usr/bin/env python3
import http.client
from pathlib import Path
import subprocess
import sys
import tempfile
from e2e_common import free_port, running

BINARY = Path(sys.argv[1]).resolve()


def get(port, path='/'):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    try:
        conn.request('GET', path)
        response = conn.getresponse()
        return response.status, response.read()
    finally:
        conn.close()


def main():
    with tempfile.TemporaryDirectory(prefix='zhttpd-config-') as directory:
        root = Path(directory)
        (root / 'index.html').write_text('static adapter')
        port = free_port()
        formats = {
            'nginx': f'events {{}} http {{ access_log off; server {{ listen 127.0.0.1:{port}; root {root}; }} }}',
            'apache': f'ServerRoot "{root}"\nListen 127.0.0.1:{port}\nDocumentRoot "{root}"\n<Directory "{root}">\nRequire all granted\n</Directory>\n',
            'caddy': f'http://localhost:{port} {{\nroot * "{root}"\nfile_server\n}}\n',
            'litespeed': f'virtualhost site {{\nvhRoot {root}\nconfigFile {root}/vhost.conf\n}}\nlistener http {{\naddress 127.0.0.1:{port}\nsecure 0\nmap site *\n}}\n',
        }
        (root / 'vhost.conf').write_text(f'docRoot {root}\nindex {{\nuseServer 0\nindexFiles index.html\n}}\n')
        config = root / 'config.toml'
        for mode, text in formats.items():
            source = root / f'{mode}.conf'; source.write_text(text)
            config.write_text(f'[server]\ncompatibility = "{mode}"\nconfig = "{source.name}"\n')
            command = [BINARY, '-c', config]
            subprocess.run([*command, '-t'], check=True)
            with running(command, port):
                assert get(port) == (200, b'static adapter'), mode
            config.write_text(f'[modules]\n{mode} = false\n[server]\ncompatibility = "{mode}"\nconfig = "{source.name}"\n')
            assert subprocess.run([*command, '-t'], capture_output=True).returncode != 0
        config.write_text(f'''[server]
compatibility = "self"
[http]
listen = "127.0.0.1:{port}"
response = "fallback"
[[http.routes]]
path = "/health"
match = "exact"
response = "healthy"
status = 201
[[http.routes]]
path = "/static"
root = "."
''')
        (root / 'static').write_text('native file')
        with running([BINARY, '-c', config], port):
            assert get(port) == (200, b'fallback')
            assert get(port, '/health') == (201, b'healthy')
            assert get(port, '/health/more') == (200, b'fallback')
            assert get(port, '/static') == (200, b'native file')
        config.write_text(f'[server]\ncompatibility="self"\n[http]\nlisten="127.0.0.1:{port}"\n[[http.routes]]\npath="/"\nmatch="exact"\nresponse="exact root"\n')
        with running([BINARY, '-c', config], port):
            assert get(port) == (200, b'exact root')
            assert get(port, '/elsewhere')[0] == 404
        for text in ('[server]\ncompatibility="invalid"\n', '[http]\nlisten="8080"\n',
                     '[modules]\nhttp=false\n[server]\ncompatibility="self"\n'):
            config.write_text(text)
            assert subprocess.run([BINARY, '-c', config, '-t'], capture_output=True).returncode != 0
    print('PASS: native TOML, nginx, Apache, OpenLiteSpeed, Caddy, module gates and compatibility errors')


if __name__ == '__main__':
    main()
