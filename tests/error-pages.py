#!/usr/bin/env python3
"""Exercise default error pages through HTTP: python3 tests/error-pages.py [binary]."""
import http.client
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zhttpd").resolve()
with tempfile.TemporaryDirectory(prefix="zhttpd-errors-") as tmp:
    root = Path(tmp)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    (root / "custom.html").write_text("<h1>My custom error</h1>\n")
    codes = (400, 403, 404, 405, 413, 429, 500, 502, 503, 504, 507)
    locations = "\n".join(f"location /{code} {{ return {code}; }}" for code in codes)
    conf = root / "nginx.conf"
    conf.write_text(f"""
worker_processes 1;
pid off;
error_log stderr;
events {{ worker_connections 64; }}
http {{
    access_log off;
    server {{
        listen 127.0.0.1:{port};
        root {root};
        server_tokens off;
        {locations}
        location /version {{ server_tokens on; return 404; }}
        location /custom {{ error_page 404 /custom.html; return 404; }}
        location = /custom.html {{ internal; }}
        location /redirect {{ return 302 /404; }}
        location /empty {{ return 204; }}
        location /unchanged {{ return 304; }}
    }}
}}
""")
    with (root / "server.log").open("w+") as log:
        proc = subprocess.Popen([str(binary), "-c", str(conf)], stdout=log, stderr=log)
        try:
            for _ in range(100):
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.1):
                        break
                except OSError:
                    if proc.poll() is not None:
                        log.seek(0)
                        raise RuntimeError(log.read())
                    time.sleep(.05)
            else:
                raise RuntimeError("Server did not start")

            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)

            def request(path, method="GET"):
                conn.request(method, path)
                res = conn.getresponse()
                return res.status, dict(res.getheaders()), res.read()

            for code in codes:
                status, headers, body = request(f"/{code}")
                assert status == code
                assert headers["Content-Type"] == "text/html"
                assert int(headers["Content-Length"]) == len(body)
                assert body.startswith(b"<!doctype html>")
                assert body.endswith(b"</body></html>\n")
                assert f"<title>{code} ".encode() in body
                assert b"data:image/svg+xml;base64," in body
                assert headers["Server"] == "zhttpd" and b"zhttpd/" not in body
                head_status, head_headers, head_body = request(f"/{code}", "HEAD")
                assert head_status == code and not head_body
                assert head_headers["Content-Length"] == headers["Content-Length"]

            status, headers, body = request("/version")
            assert status == 404 and headers["Server"].startswith("zhttpd/")
            assert headers["Server"].encode() in body
            status, headers, body = request("/custom")
            assert status == 404 and body == (root / "custom.html").read_bytes()
            status, headers, body = request("/custom", "HEAD")
            assert status == 404 and not body
            assert int(headers["Content-Length"]) == (root / "custom.html").stat().st_size
            status, headers, body = request("/redirect")
            assert status == 302 and headers["Location"].endswith("/404")
            assert body.startswith(b"<html>\r\n")
            for path, expected in (("/empty", 204), ("/unchanged", 304)):
                status, headers, body = request(path)
                assert status == expected and not body
            conn.close()
            print("PASS: error GET/HEAD, exact lengths, tokens, custom pages, redirects, 204/304")
        finally:
            proc.terminate()
            proc.wait(timeout=5)
