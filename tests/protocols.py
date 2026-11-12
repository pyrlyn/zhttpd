#!/usr/bin/env python3
"""Wire integration tests. Run with aioquic and h2 installed (see README)."""
import asyncio
import http.server
import os
from pathlib import Path
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

import h2.config
import h2.connection
import h2.events
import h2.settings
from aioquic.asyncio import connect, QuicConnectionProtocol
from aioquic.h3.connection import H3Connection, FrameType, encode_frame
from aioquic.buffer import encode_uint_var
from aioquic.h3.events import HeadersReceived, DataReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.connection import QuicConnection
from aioquic.quic.events import ConnectionTerminated

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ.get('ZHTTPD', ROOT / 'zig-out/bin/zhttpd')).resolve()
LARGE = bytes(range(256)) * 4096
UPLOAD = b'upload-body-' * 16000
REUSEPORT = sys.platform == 'linux' and os.environ.get('QUIC_REUSEPORT', '1') == '1'


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_response(200)
        self.send_header('Transfer-Encoding', 'chunked')
        self.end_headers()
        for chunk in (b'chunk-one', b'chunk-two'):
            self.wfile.write(f'{len(chunk):x}\r\n'.encode() + chunk + b'\r\n')
        self.wfile.write(b'0\r\n\r\n')

    def log_message(self, *_):
        pass


def headers(path, method='GET', data=b'', length=True, host='localhost'):
    result = [(b':method', method.encode()), (b':scheme', b'https'),
              (b':authority', host.encode()), (b':path', path.encode())]
    if data and length:
        result.append((b'content-length', str(len(data)).encode()))
    return result


def check(results, protocol):
    expected = [(200, f'{protocol} https 127.0.0.1'.encode()), (200, LARGE),
                (200, UPLOAD), (200, b'chunk-onechunk-two'), (200, b''),
                (404, None), (403, None), (413, None), (200, b'virtual-host'),
                (200, UPLOAD), (404, b'')]
    assert len(results) == len(expected)
    for i, ((status, body), (want_status, want_body)) in enumerate(zip(results, expected)):
        assert status == want_status, (i, status, want_status)
        if want_body is not None:
            assert body == want_body, (i, len(body), len(want_body), body[:100])
        elif status >= 400:
            assert body.startswith(b'<!doctype html>'), (protocol, status, body[:100])
            assert body.endswith(b'</body></html>\n'), (protocol, status, len(body))
            assert f'<title>{status} '.encode() in body
            assert b'data:image/svg+xml;base64,' in body


def requests():
    return [('/', 'GET', b'', True, 'localhost'), ('/large', 'GET', b'', True, 'localhost'),
            ('/proxy', 'POST', UPLOAD, True, 'localhost'), ('/proxy', 'GET', b'', True, 'localhost'),
            ('/large', 'HEAD', b'', True, 'localhost'), ('/missing', 'GET', b'', True, 'localhost'),
            ('/denied', 'GET', b'', True, 'localhost'), ('/limited', 'POST', UPLOAD, True, 'localhost'),
            ('/', 'GET', b'', True, 'other.local'), ('/proxy', 'POST', UPLOAD, False, 'localhost'),
            ('/missing', 'HEAD', b'', True, 'localhost')]


def h2_exchange(port):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(['h2', 'http/1.1'])
    with ctx.wrap_socket(socket.create_connection(('127.0.0.1', port), timeout=8), server_hostname='localhost') as sock:
        assert sock.selected_alpn_protocol() == 'h2'
        h = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=True))
        h.initiate_connection()
        results, pending, done = {}, {}, set()
        for path, method, body, length, host in requests():
            sid = h.get_next_available_stream_id()
            h.send_headers(sid, headers(path, method, body, length, host), end_stream=not body)
            results[sid] = [0, bytearray()]
            if body:
                pending[sid] = memoryview(body)
        # A canceled stream must not affect its siblings.
        cancel = h.get_next_available_stream_id()
        h.send_headers(cancel, headers('/large'), end_stream=True)
        h.reset_stream(cancel)
        while len(done) != len(results):
            for sid in list(pending):
                try:
                    window = h.local_flow_control_window(sid)
                except h2.exceptions.StreamClosedError:
                    del pending[sid]
                    continue
                n = min(len(pending[sid]), window, h.max_outbound_frame_size)
                if n > 0:
                    h.send_data(sid, pending[sid][:n].tobytes(), end_stream=n == len(pending[sid]))
                    pending[sid] = pending[sid][n:]
                    if not pending[sid]:
                        del pending[sid]
            sock.sendall(h.data_to_send())
            data = sock.recv(65536)
            assert data, 'HTTP/2 connection closed early'
            for event in h.receive_data(data):
                if isinstance(event, h2.events.ResponseReceived):
                    results[event.stream_id][0] = int(dict(event.headers)[b':status'])
                    assert b'connection' not in dict(event.headers)
                    assert b'transfer-encoding' not in dict(event.headers)
                elif isinstance(event, h2.events.DataReceived):
                    if event.stream_id in results:
                        results[event.stream_id][1].extend(event.data)
                    h.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                elif isinstance(event, h2.events.StreamEnded):
                    done.add(event.stream_id)
                elif isinstance(event, h2.events.StreamReset) and event.stream_id != cancel:
                    raise AssertionError(event)
                elif isinstance(event, h2.events.ConnectionTerminated):
                    raise AssertionError(event)
        check(list(results.values()), 'HTTP/2.0')
        # Reuse the same connection after all streams were recycled.
        sid = h.get_next_available_stream_id()
        h.send_headers(sid, headers('/'), end_stream=True)
        sock.sendall(h.data_to_send())
        while True:
            events = h.receive_data(sock.recv(65536))
            if any(isinstance(e, h2.events.StreamEnded) and e.stream_id == sid for e in events):
                break


def h2_backpressure(port):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(['h2'])
    with ctx.wrap_socket(socket.create_connection(('127.0.0.1', port), timeout=15), server_hostname='localhost') as sock:
        h = h2.connection.H2Connection()
        h.initiate_connection()
        h.update_settings({h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: 2 * len(LARGE)})
        h.increment_flow_control_window(32 * len(LARGE))
        bodies = {}
        for _ in range(16):
            sid = h.get_next_available_stream_id()
            h.send_headers(sid, headers('/large'), end_stream=True)
            bodies[sid] = bytearray()
        sock.sendall(h.data_to_send())
        # Allow output to fill the TCP send queue, then cancel one response
        # while the codec retains a pending SSL_write retry and sibling bodies.
        time.sleep(.2)
        h.reset_stream(1)
        del bodies[1]
        sock.sendall(h.data_to_send())
        done = set()
        while len(done) < len(bodies):
            data = sock.recv(65536)
            assert data, 'backpressured HTTP/2 connection closed'
            for event in h.receive_data(data):
                if isinstance(event, h2.events.DataReceived):
                    if event.stream_id in bodies:
                        bodies[event.stream_id].extend(event.data)
                    h.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                elif isinstance(event, h2.events.StreamEnded) and event.stream_id in bodies:
                    done.add(event.stream_id)
                elif isinstance(event, (h2.events.StreamReset, h2.events.ConnectionTerminated)):
                    raise AssertionError(event)
            pending = h.data_to_send()
            if pending:
                sock.sendall(pending)
        assert all(body == LARGE for body in bodies.values())


def h2_invalid_streams(port):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(['h2'])
    with ctx.wrap_socket(socket.create_connection(('127.0.0.1', port), timeout=5), server_hostname='localhost') as sock:
        h = h2.connection.H2Connection(config=h2.config.H2Configuration(
            client_side=True, validate_outbound_headers=False, normalize_outbound_headers=False))
        h.initiate_connection()
        h.send_headers(1, headers('/proxy', 'POST') + [(b'content-length', b'100')])
        h.send_data(1, b'short', end_stream=True)
        h.send_headers(3, headers('/') + [(b'x-test', b'injected\r\nheader')], end_stream=True)
        h.send_headers(5, headers('/'), end_stream=True)
        sock.sendall(h.data_to_send())
        resets, survivor = set(), False
        while resets != {1, 3} or not survivor:
            data = sock.recv(65536)
            assert data, 'malformed stream closed the healthy HTTP/2 connection'
            for e in h.receive_data(data):
                if isinstance(e, h2.events.StreamReset):
                    resets.add(e.stream_id)
                elif isinstance(e, h2.events.StreamEnded):
                    assert e.stream_id == 5, e
                    survivor = True
                elif isinstance(e, h2.events.ConnectionTerminated):
                    raise AssertionError(e)
            sock.sendall(h.data_to_send())


class ClientH3Connection(H3Connection):
    # aioquic 1.7.2 applies Content-Length to HEAD response bodies as well.
    # RFC 9110 allows HEAD's Content-Length to describe the corresponding GET.
    # Keep validation for every other request; check() asserts HEAD has no body.
    def __init__(self, quic):
        super().__init__(quic)
        self.head_streams = set()

    def _check_content_length(self, stream):
        if stream.stream_id not in self.head_streams:
            super()._check_content_length(stream)


class H3Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = ClientH3Connection(self._quic)
        self.results, self.waiters = {}, {}
        self.terminated = asyncio.Event()
        self.close_code = None

    def quic_event_received(self, event):
        if isinstance(event, ConnectionTerminated):
            self.close_code = event.error_code
            self.terminated.set()
            for f in self.waiters.values():
                if not f.done():
                    f.set_exception(AssertionError(event))
        for e in self.http.handle_event(event):
            if isinstance(e, HeadersReceived):
                hs = dict(e.headers)
                self.results[e.stream_id][0] = int(hs[b':status'])
                assert b'connection' not in hs and b'transfer-encoding' not in hs
            elif isinstance(e, DataReceived):
                self.results[e.stream_id][1].extend(e.data)
            if isinstance(e, (HeadersReceived, DataReceived)) and e.stream_ended:
                self.waiters[e.stream_id].set_result(self.results[e.stream_id])

    def request(self, path, method='GET', data=b'', length=True, host='localhost'):
        sid = self._quic.get_next_available_stream_id()
        self.results[sid] = [0, bytearray()]
        self.waiters[sid] = asyncio.get_running_loop().create_future()
        if method == "HEAD":
            self.http.head_streams.add(sid)
        self.http.send_headers(sid, headers(path, method, data, length, host), end_stream=not data)
        if data:
            self.http.send_data(sid, data, end_stream=True)
        self.transmit()
        return self.waiters[sid]


async def h3_exchange(port):
    cfg = QuicConfiguration(is_client=True, alpn_protocols=['h3'], verify_mode=ssl.CERT_NONE)
    async with connect('127.0.0.1', port, configuration=cfg, create_protocol=H3Client) as client:
        results = await asyncio.wait_for(asyncio.gather(*(client.request(*r) for r in requests())), 20)
        check(results, 'HTTP/3.0')
        # Exercise stream reclamation and QPACK state across >32 total requests.
        for _ in range(40):
            # Finished unknown unidirectional streams must not consume the
            # session's bounded stream slots forever (RFC 9114 GREASE).
            sid = client._quic.get_next_available_stream_id(is_unidirectional=True)
            client._quic.send_stream_data(sid, encode_uint_var(0x21) + b'ignored', end_stream=True)
            status, body = await asyncio.wait_for(client.request('/'), 5)
            assert status == 200 and body == b'HTTP/3.0 https 127.0.0.1'
        # A GOAWAY initiates graceful transport shutdown after the response has
        # drained. Quinn/h3 clients wait for CONNECTION_CLOSE, not just GOAWAY.
        future = client.request('/large')
        await asyncio.sleep(.01)
        client._quic.send_stream_data(client.http._local_control_stream_id,
                                     encode_frame(FrameType.GOAWAY, encode_uint_var(0)))
        client.transmit()
        status, body = await asyncio.wait_for(future, 10)
        assert status == 200 and body == LARGE
        await asyncio.wait_for(client.terminated.wait(), 5)
        assert client.close_code == 0x100, client.close_code


async def h3_loss_and_reordering(port):
    """Completed stream GC must preserve retransmissions and tolerate late duplicates."""
    loop = asyncio.get_running_loop()

    class Relay(asyncio.DatagramProtocol):
        def __init__(self):
            self.client = None
            self.count = self.dropped = self.delayed = self.duplicated = 0

        def connection_made(self, transport):
            self.transport = transport

        def forward(self, data, target):
            if not self.transport.is_closing():
                self.transport.sendto(data, target)

        def datagram_received(self, data, addr):
            if addr == ('127.0.0.1', port):
                target = self.client
            else:
                self.client = addr
                target = ('127.0.0.1', port)
            if target is None:
                return
            self.count += 1
            if self.count % 113 == 0:
                self.dropped += 1
                return
            if self.count % 97 == 0:
                self.delayed += 1
                loop.call_later(.02, self.forward, data, target)
            else:
                self.forward(data, target)
            if self.count % 71 == 0:
                self.duplicated += 1
                loop.call_later(.1, self.forward, data, target)

    transport, relay = await loop.create_datagram_endpoint(Relay, local_addr=('127.0.0.1', 0))
    try:
        await h3_exchange(transport.get_extra_info('sockname')[1])
        assert relay.dropped and relay.delayed and relay.duplicated
    finally:
        transport.close()


async def h3_loss_backpressure(port):
    class LossyClient(H3Client):
        discard = False
        packets = 0
        dropped = 0

        def datagram_received(self, data, addr):
            if self.discard:
                self.packets += 1
                if self.packets % 19 == 0:
                    self.dropped += 1
                    return
            super().datagram_received(data, addr)

    # Small initial windows force partial writes and stream unblocking; dropped
    # packets require QUIC retransmission after the application reused buffers.
    cfg = QuicConfiguration(is_client=True, alpn_protocols=['h3'],
                            verify_mode=ssl.CERT_NONE, max_data=8192,
                            max_stream_data=2048)
    async with connect('127.0.0.1', port, configuration=cfg, create_protocol=LossyClient) as client:
        client.discard = True
        results = await asyncio.wait_for(asyncio.gather(
            client.request('/large'), client.request('/large'),
            client.request('/large', 'HEAD')), 30)
        assert results[0] == [200, LARGE] and results[1] == [200, LARGE]
        assert results[2] == [200, b'']
        assert client.dropped > 0
        status, body = await asyncio.wait_for(client.request('/'), 5)
        assert status == 200 and body == b'HTTP/3.0 https 127.0.0.1'


async def h3_workers(port):
    async def one():
        cfg = QuicConfiguration(is_client=True, alpn_protocols=['h3'], verify_mode=ssl.CERT_NONE)
        async with connect('127.0.0.1', port, configuration=cfg, create_protocol=H3Client) as client:
            status, body = await asyncio.wait_for(client.request('/worker'), 5)
            assert status == 200 and body.isdigit()
            return bytes(body)
    # Independent source ports exercise the kernel's reuseport distribution.
    pids = set()
    for _ in range(8):
        pids.update(await asyncio.gather(*(one() for _ in range(8))))
    assert len(pids) == (2 if REUSEPORT else 1), pids


async def h3_peer_addresses(port):
    async def one(ip):
        cfg = QuicConfiguration(is_client=True, alpn_protocols=['h3'], verify_mode=ssl.CERT_NONE)
        transport, client = await asyncio.get_running_loop().create_datagram_endpoint(
            lambda: H3Client(QuicConnection(configuration=cfg)), local_addr=(ip, 0))
        source_port = transport.get_extra_info('sockname')[1]
        try:
            client.connect(('127.0.0.1', port))
            await asyncio.wait_for(client.wait_connected(), 5)
            for _ in range(8):
                status, body = await asyncio.wait_for(client.request('/peer'), 5)
                assert status == 200 and body == f'{ip} {source_port} 127.0.0.1'.encode(), body
        finally:
            client.close()
            await client.wait_closed()
            transport.close()
    # Different peers interleave handshakes and application packets on one UDP
    # listener; callback identity must remain attached to the original client.
    await asyncio.gather(*(one(f'127.0.0.{1 + i % 2}') for i in range(16)))


def h1_exchange(port, host="localhost", offer_h2=False):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(['h2', 'http/1.1'] if offer_h2 else ['http/1.1'])
    with ctx.wrap_socket(socket.create_connection(('127.0.0.1', port), timeout=5), server_hostname=host) as sock:
        assert sock.selected_alpn_protocol() == 'http/1.1'
        sock.sendall(f'GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
        response = bytearray()
        while data := sock.recv(65536):
            response.extend(data)
        assert response.endswith(b'h1-only' if host == 'h1.local' else b'HTTP/1.1 https 127.0.0.1'), response


def run():
    with tempfile.TemporaryDirectory(prefix='zhttpd-protocols-') as temp:
        temp = Path(temp)
        cert, key = temp / 'cert.pem', temp / 'key.pem'
        subprocess.run([os.environ.get('OPENSSL_BIN', str(ROOT / 'deps/openssl-install/bin/openssl')), 'req', '-config', '/dev/null', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=localhost', '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
        (temp / 'large').write_bytes(LARGE)
        with socket.socket() as reserve:
            reserve.bind(('127.0.0.1', 0))
            port = reserve.getsockname()[1]
        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        thread.start()
        cfg = temp / 'nginx.conf'
        config_text = f'''worker_processes 2;
pid {temp}/server.pid;
error_log stderr notice;
events {{ worker_connections 256; }}
http {{
    access_log off;
    http2 on;
    server {{
        listen 127.0.0.1:{port} ssl;
        listen 127.0.0.1:{port} quic{' reuseport' if REUSEPORT else ''};
        server_name localhost;
        ssl_certificate {cert};
        ssl_certificate_key {key};
        root {temp};
        sendfile on;
        location = / {{ return 200 "$server_protocol $scheme $remote_addr"; }}
        location = /worker {{ return 200 "$pid"; }}
        location = /peer {{ return 200 "$remote_addr $remote_port $server_addr"; }}
        location /proxy {{ proxy_pass http://127.0.0.1:{upstream.server_port}; }}
        location /limited {{ client_max_body_size 10; return 200 accepted; }}
        location /denied {{ deny 127.0.0.1; }}
    }}
    server {{
        listen 127.0.0.1:{port} ssl;
        listen 127.0.0.1:{port} quic{' reuseport' if REUSEPORT else ''};
        server_name other.local;
        ssl_certificate {cert};
        ssl_certificate_key {key};
        return 200 virtual-host;
    }}
    server {{
        listen 127.0.0.1:{port} ssl;
        server_name h1.local;
        http2 off;
        ssl_certificate {cert};
        ssl_certificate_key {key};
        return 200 h1-only;
    }}
}}
'''
        cfg.write_text(config_text)
        command = [str(BINARY), '-p', str(temp) + '/', '-c', str(cfg)]
        subprocess.run(command + ['-t'], check=True)
        for invalid in (
            config_text.replace('http2 on;', 'http2 on; http3 off;'),
            config_text.replace('http2 on;', 'http2 on; ssl_protocols TLSv1.2;'),
            config_text.replace(f'listen 127.0.0.1:{port} ssl;', f'listen 127.0.0.1:{port} http2;'),
        ):
            cfg.write_text(invalid)
            result = subprocess.run(command + ['-t'], capture_output=True)
            assert result.returncode != 0, 'invalid protocol configuration accepted'
        cfg.write_text(config_text)
        log = (temp / 'server.log').open('w+')
        proc = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True)
        try:
            for _ in range(100):
                if proc.poll() is not None:
                    raise AssertionError('server exited')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.02)
            h1_exchange(port)
            h1_exchange(port, "h1.local", offer_h2=True)
            h2_exchange(port)
            h2_backpressure(port)
            h2_invalid_streams(port)
            asyncio.run(h3_exchange(port))
            asyncio.run(h3_loss_backpressure(port))
            asyncio.run(h3_loss_and_reordering(port))
            asyncio.run(h3_workers(port))
            if sys.platform == 'linux':
                asyncio.run(h3_peer_addresses(port))
            # Two independent QUIC clients exercise connection demultiplexing.
            async def parallel():
                await asyncio.gather(h3_exchange(port), h3_exchange(port))
            asyncio.run(parallel())
            proc.send_signal(signal.SIGHUP)
            time.sleep(.2)
            h1_exchange(port)
            h1_exchange(port, "h1.local", offer_h2=True)
            h2_exchange(port)
            h2_invalid_streams(port)
            asyncio.run(h3_exchange(port))
            asyncio.run(h3_loss_backpressure(port))
            asyncio.run(h3_workers(port))
            proc.send_signal(signal.SIGQUIT)
            proc.wait(timeout=10)
            assert proc.returncode == 0
            print('PASS: HTTP/1.1, HTTP/2, HTTP/3, multiplexing, uploads, static/HEAD, proxy, limits, ACL, vhosts, reuse, loss/reordering/duplicates, reload, shutdown')
        except BaseException:
            log.flush(); log.seek(0); print(log.read())
            raise
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.wait(timeout=10)
            log.close()
            upstream.shutdown(); upstream.server_close()


if __name__ == '__main__':
    run()
