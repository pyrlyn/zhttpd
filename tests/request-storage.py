#!/usr/bin/env python3
"""Exercise request-storage reuse across idle, partial, pipelined and blocked I/O."""
from pathlib import Path
import socket
import sys
import tempfile

from e2e_common import free_port, running

BINARY = Path(sys.argv[1]).resolve()


class Client:
    def __init__(self, port):
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=5)
        self.buffer = b''

    def send(self, data):
        self.sock.sendall(data)

    def response(self):
        while b'\r\n\r\n' not in self.buffer:
            self.read()
        head, self.buffer = self.buffer.split(b'\r\n\r\n', 1)
        assert head.startswith(b'HTTP/1.1 200 '), head
        fields = dict(line.lower().split(b':', 1) for line in head.split(b'\r\n')[1:])
        size = int(fields[b'content-length'])
        while len(self.buffer) < size:
            self.read()
        body, self.buffer = self.buffer[:size], self.buffer[size:]
        return body

    def read(self):
        data = self.sock.recv(65536)
        assert data, 'unexpected EOF'
        self.buffer += data

    def close(self):
        self.sock.close()


def request(value):
    return b'GET /echo?' + value + b' HTTP/1.1\r\nHost: localhost\r\n\r\n'


with tempfile.TemporaryDirectory(prefix='zhttpd-request-storage-') as tmp:
    root = Path(tmp)
    large = bytes(range(256)) * (4 * 1024 * 1024 // 256)
    (root / 'large').write_bytes(large)
    port = free_port()
    config = root / 'nginx.conf'
    config.write_text(f'''worker_processes 1;
error_log stderr error;
pid {root}/server.pid;
events {{ worker_connections 512; }}
http {{ access_log off; sendfile off; keepalive_timeout 30;
server {{ listen 127.0.0.1:{port}; root {root};
location = /echo {{ return 200 "$request_uri"; }}
}} }}''')
    with running([BINARY, '-c', config], port):
        clients = []
        try:
            # Exceed both pool caps, then keep requests incomplete concurrently.
            clients = [Client(port) for _ in range(80)]
            for index, client in enumerate(clients):
                client.send(request(str(index).encode()))
                assert client.response() == f'/echo?{index}'.encode()
                client.send(f'GET /echo?partial-{index} HTTP/1.1\r\nHo'.encode())
            busy = Client(port)
            clients.append(busy)
            for index in range(100):
                busy.send(request(b'pool-churn'))
                assert busy.response() == b'/echo?pool-churn'
            for index, client in enumerate(clients[:-1]):
                client.send(b'st: localhost\r\n\r\n')
                assert client.response() == f'/echo?partial-{index}'.encode()

            # The second request's partial head must survive the first response.
            first = clients[0]
            first.send(request(b'first') + b'GET /echo?second HTTP/1.1\r\nHost:')
            assert first.response() == b'/echo?first'
            busy.send(request(b'overwrite'))
            assert busy.response() == b'/echo?overwrite'
            first.send(b' localhost\r\n\r\n')
            assert first.response() == b'/echo?second'

            # Preserve original header and URI limits after repeated reuse.
            value = b'x' * 7000
            first.send(request(value))
            assert first.response() == b'/echo?' + value
            first.send(b'GET /echo?headers HTTP/1.1\r\nHost: localhost\r\nX-Large: ' + b'y' * 12000 + b'\r\n\r\n')
            assert first.response() == b'/echo?headers'

            # Drain a body larger than the read buffer, then parse a pipeline.
            first.send(b'POST /echo?body HTTP/1.1\r\nHost: localhost\r\nContent-Length: 40000\r\n\r\n' + b'b' * 40000 + request(b'after-body'))
            assert first.response() == b'/echo?body'
            assert first.response() == b'/echo?after-body'

            # A blocked response must retain its buffers while other clients reuse theirs.
            first.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
            first.send(b'GET /large HTTP/1.1\r\nHost: localhost\r\n\r\n')
            for _ in range(100):
                busy.send(request(b'during-large'))
                assert busy.response() == b'/echo?during-large'
            assert first.response() == large
            first.send(request(b'after-large'))
            assert first.response() == b'/echo?after-large'
        finally:
            for client in clients:
                client.close()
print('PASS: pooled request storage, partial/pipelined headers, original limits, body drain, backpressure')
