#!/usr/bin/env python3
"""TLS I/O regression checks; requires a -Dtls=true binary and openssl CLI."""
from pathlib import Path
import hashlib
import http.client
import socket
import os
import select
from email.utils import formatdate
import ssl
import subprocess
import sys
import tempfile
import time


class Client:
    """MemoryBIO lets tests control TLS record boundaries on the TCP stream."""

    def __init__(self, port, version):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ctx.minimum_version = ctx.maximum_version = version
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.incoming, self.outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        self.tls = ctx.wrap_bio(self.incoming, self.outgoing, server_hostname="localhost")
        self.plain = b""
        while True:
            try:
                self.tls.do_handshake()
                self.flush()
                break
            except ssl.SSLWantReadError:
                self.flush()
                self.receive()

    def flush(self):
        wire = self.outgoing.read()
        if wire:
            self.sock.sendall(wire)

    def receive(self):
        data = self.sock.recv(65536)
        assert data, "unexpected TLS EOF"
        self.incoming.write(data)

    def send(self, parts, fragment=False):
        for part in parts:
            assert self.tls.write(part) == len(part)
        wire = self.outgoing.read()
        if fragment:
            # Split TLS headers and ciphertext, not just HTTP request bytes.
            for offset in range(0, len(wire), 7):
                self.sock.sendall(wire[offset:offset + 7])
        else:
            # Several complete TLS records arrive in a single socket write.
            self.sock.sendall(wire)

    def read_more(self):
        while True:
            try:
                data = self.tls.read(65536)
                assert data, "unexpected plaintext EOF"
                self.plain += data
                return
            except ssl.SSLWantReadError:
                self.flush()
                self.receive()

    def response(self, head=False, digest=False):
        while b"\r\n\r\n" not in self.plain:
            self.read_more()
        headers, self.plain = self.plain.split(b"\r\n\r\n", 1)
        lines = headers.split(b"\r\n")
        status = int(lines[0].split()[1])
        fields = dict((name.lower(), value) for name, value in
                      (line.split(b": ", 1) for line in lines[1:]))
        size = 0 if head or status in (204, 304) else int(fields[b"content-length"])
        if digest:
            # Keep the test client bounded for 100 MiB responses, including a
            # pipelined response already decrypted after the file's last byte.
            result = hashlib.sha256()
            left = size
            while left:
                if not self.plain:
                    self.read_more()
                take = min(left, len(self.plain))
                result.update(self.plain[:take])
                self.plain = self.plain[take:]
                left -= take
            return status, fields, result.digest()
        while len(self.plain) < size:
            self.read_more()
        body, self.plain = self.plain[:size], self.plain[size:]
        return status, fields, body

    def close(self):
        self.sock.close()


def request(path="/small", method="GET", extra=b""):
    return f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n".encode() + extra + b"\r\n"


def key_updates(openssl, port, body, large):
    # Python's ssl API has no KeyUpdate method. Exercise the OpenSSL 3 client
    # command interface and verify that requests survive both update modes.
    help_text = subprocess.run([openssl, 's_client', '-help'], capture_output=True, text=True)
    if '-adv' not in help_text.stdout + help_text.stderr:
        print('SKIP: KeyUpdate requires OPENSSL_CLI with s_client -adv (OpenSSL 3.5+)')
        return
    with tempfile.TemporaryFile() as errors:
        client = subprocess.Popen([
            openssl, 's_client', '-quiet', '-no_ign_eof', '-adv', '-tls1_3',
            '-connect', f'127.0.0.1:{port}', '-servername', 'localhost',
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
        try:
            for command, path, expected in (
                (b'', '/large', large),
                (b'{keyup:req}\n', '/small', body),
                (b'{keyup:noreq}\n', '/large', large),
            ):
                client.stdin.write(command + request(path))
                client.stdin.flush()
                received = bytearray()
                deadline = time.monotonic() + 5
                while not received.endswith(expected):
                    timeout = deadline - time.monotonic()
                    assert timeout > 0 and select.select([client.stdout], [], [], timeout)[0], 'KeyUpdate response timed out'
                    data = os.read(client.stdout.fileno(), 65536)
                    if not data:
                        errors.seek(0)
                        raise AssertionError('KeyUpdate client closed before response: ' + errors.read().decode(errors='replace'))
                    received.extend(data)
                assert received.startswith(b'HTTP/1.1 200 '), received
            errors.seek(0)
            assert errors.read().count(b'KEYUPDATE') == 2
            print('PASS: TLS 1.3 KeyUpdate requested/not requested')
        finally:
            client.terminate()
            client.wait(timeout=5)
            client.stdin.close()
            client.stdout.close()


binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zhttpd").resolve()
openssl = os.environ.get('OPENSSL_CLI', os.environ.get('OPENSSL_BIN', 'openssl'))
with tempfile.TemporaryDirectory(prefix="zhttpd-tls-") as tmp:
    root = Path(tmp)
    subprocess.run([
        openssl, "req", "-config", os.devnull, "-x509", "-newkey", "ec", "-pkeyopt",
        "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1",
        "-subj", "/CN=localhost", "-keyout", str(root / "key.pem"),
        "-out", str(root / "cert.pem"),
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    small = b"TLS static response\n"
    large = bytes(range(256)) * 32768
    (root / "small").write_bytes(small)
    (root / "large").write_bytes(large)
    huge_hash = hashlib.sha256()
    block = large[:1024 * 1024]
    with (root / "huge").open('wb') as huge:
        for _ in range(100):
            huge.write(block)
            huge_hash.update(block)
    small_time, large_time = 1600000000, 1700000000
    os.utime(root / "small", (small_time, small_time))
    os.utime(root / "large", (large_time, large_time))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        plain_port = sock.getsockname()[1]
    conf = root / "nginx.conf"
    conf.write_text(f"""
worker_processes 1;
pid off;
error_log stderr;
events {{ worker_connections 128; }}
http {{
    access_log off;
    sendfile on;
    keepalive_requests 10000;
    open_file_cache max=16 inactive=60s;
    server {{
        listen 127.0.0.1:{plain_port};
        listen 127.0.0.1:{port} ssl;
        server_name localhost;
        ssl_certificate {root}/cert.pem;
        ssl_certificate_key {root}/key.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        root {root};
        location /drain {{ return 200 "drained"; }}
        location = /large {{ sendfile_max_chunk 64k; }}
        location = /fresh {{ open_file_cache_valid 0s; }}
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
                raise RuntimeError("TLS server did not start")

            plain = http.client.HTTPConnection('127.0.0.1', plain_port, timeout=5)
            try:
                plain.request('GET', '/huge')
                response = plain.getresponse()
                assert response.status == 200
                result = hashlib.sha256()
                while block := response.read(65536):
                    result.update(block)
                assert result.digest() == huge_hash.digest()
                plain.request('GET', '/small')
                assert plain.getresponse().read() == small
            finally:
                plain.close()
            print('PASS: HTTP sendfile: 100 MiB hash and keep-alive continuation')

            for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
                client = Client(port, version)
                try:
                    client.send([request()[:17], request()[17:]], fragment=True)
                    assert client.response()[2] == small
                    # More than a receive buffer of pipelined requests, each in
                    # its own TLS record: all must drain without another event.
                    client.send([request() for _ in range(600)])
                    for _ in range(600):
                        assert client.response()[2] == small
                    client.send([
                        request("/drain", "POST", b"Content-Length: 9\r\n") + b"abc",
                        b"defghi", request(),
                    ])
                    assert client.response()[2] == b"drained"
                    assert client.response()[2] == small
                    client.send([request(method="HEAD"), request(extra=b"Range: bytes=1-5\r\n")])
                    status, headers, body = client.response(head=True)
                    assert status == 200 and not body
                    assert int(headers[b"content-length"]) == len(small)
                    assert headers[b"last-modified"].decode() == formatdate(small_time, usegmt=True)
                    status, _, body = client.response()
                    assert status == 206 and body == small[1:6]
                    client.send([request("/huge"), request()])
                    status, headers, digest = client.response(digest=True)
                    assert status == 200 and int(headers[b"content-length"]) == 100 * 1024 * 1024
                    assert digest == huge_hash.digest(), '100 MiB response corrupted or truncated'
                    assert client.response()[2] == small
                    # Unaligned range spanning multiple file-read/TLS-record
                    # boundaries, including a short final chunk, then reuse.
                    client.send([request("/large", extra=b"Range: bytes=65531-200003\r\n"), request()])
                    status, _, body = client.response()
                    assert status == 206 and body == large[65531:200004]
                    assert client.response()[2] == small
                    client.send([request("/large"), request()])
                    time.sleep(.1)  # let server writes encounter backpressure
                    _, headers, body = client.response()
                    assert body == large
                    assert headers[b"last-modified"].decode() == formatdate(large_time, usegmt=True)
                    _, headers, body = client.response()
                    assert body == small
                    assert headers[b"last-modified"].decode() == formatdate(small_time, usegmt=True)
                    # Idle record buffers may be released and must be recreated.
                    time.sleep(2.1)
                    client.send([request()])
                    assert client.response()[2] == small
                    # An incomplete encrypted record must survive an idle sweep.
                    client.tls.write(request())
                    wire = client.outgoing.read()
                    client.sock.sendall(wire[:12])
                    time.sleep(2.1)
                    client.sock.sendall(wire[12:])
                    assert client.response()[2] == small
                    # Rewriting an open cached file must remain visible.
                    (root / "small").write_bytes(small.upper())
                    client.send([request()])
                    assert client.response()[2] == small.upper()
                    (root / "small").write_bytes(small)
                    os.utime(root / "small", (small_time, small_time))
                    # Formatting reuse must follow both metadata fields and
                    # preserve conditional responses after revalidation.
                    previous_tag = b'"not-current"'
                    for content, stamp in ((b"abc", small_time),
                                           (b"abcdef", small_time),
                                           (b"abcdef", small_time + 1)):
                        (root / "fresh").write_bytes(content)
                        os.utime(root / "fresh", (stamp, stamp))
                        client.send([request("/fresh", extra=b"If-None-Match: " + previous_tag + b"\r\n")])
                        status, headers, body = client.response()
                        assert status == 200 and body == content
                        tag = f'"{stamp:x}-{len(content):x}"'.encode()
                        assert headers[b"etag"] == tag and tag != previous_tag
                        client.send([request("/fresh", extra=b"If-None-Match: " + tag + b"\r\n")])
                        status, headers, body = client.response()
                        assert status == 304 and not body and headers[b"etag"] == tag
                        previous_tag = tag
                finally:
                    client.close()
                # Data and FIN may share one readiness notification. A short
                # socket read must not hide EOF until the keep-alive timeout.
                for _ in range(10):
                    client = Client(port, version)
                    try:
                        client.send([request()])
                        client.sock.shutdown(socket.SHUT_WR)
                        assert client.response()[2] == small
                        client.sock.settimeout(1)
                        while client.sock.recv(65536):
                            pass
                    finally:
                        client.close()
                for _ in range(5):
                    client = Client(port, version)
                    client.send([request("/large")])
                    client.read_more()
                    client.close()  # abort with a partially sent file buffer
                    client = Client(port, version)
                    try:
                        client.send([request()])
                        assert client.response()[2] == small
                    finally:
                        client.close()
                print(f"PASS: {version.name}: fragmented/coalesced records, pipeline, body drain, HEAD/range, 100 MiB hash, backpressure, idle buffers, file freshness, TCP half-close")
            key_updates(openssl, port, small, large)
        finally:
            proc.terminate()
            proc.wait(timeout=5)
