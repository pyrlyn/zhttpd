#!/usr/bin/env python3
"""PEP 3333 gateway over FastCGI. Bind only to a trusted local interface."""
import argparse
import importlib
import io
import socketserver
import struct
import sys
import threading
from wsgiref.handlers import BaseCGIHandler

MAX_BODY = 16 * 1024 * 1024
MAX_PARAMS = 128 * 1024

def record(sock, kind, data=b''):
    while True:
        piece, data = data[:65535], data[65535:]
        sock.sendall(struct.pack('!BBHHBB', 1, kind, 1, len(piece), 0, 0) + piece)
        if not data: break

def exact(file, size):
    data = file.read(size)
    if len(data) != size: raise EOFError()
    return data

def parameters(data):
    pos = 0
    def length():
        nonlocal pos
        if pos >= len(data): raise ValueError('short parameter')
        value = data[pos]; pos += 1
        if value & 128:
            if pos + 3 > len(data): raise ValueError('short parameter length')
            value = ((value & 127) << 24) | int.from_bytes(data[pos:pos+3], 'big'); pos += 3
        return value
    result = {}
    while pos < len(data):
        n, v = length(), length()
        if pos+n+v > len(data): raise ValueError('short parameter value')
        name = data[pos:pos+n].decode('latin-1'); pos += n
        value = data[pos:pos+v].decode('latin-1'); pos += v
        result[name] = value
    return result

class Output:
    def __init__(self, sock): self.sock = sock
    def write(self, data):
        if data: record(self.sock, 6, data)
        return len(data)
    def flush(self): pass

class Gateway(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(60)
        env_bytes = bytearray(); body = bytearray(); began = False; params_done = False
        try:
            while True:
                version, kind, rid, size, pad, _ = struct.unpack('!BBHHBB', exact(self.rfile, 8))
                if version != 1 or rid != 1: raise ValueError('unsupported FastCGI request')
                data = exact(self.rfile, size); exact(self.rfile, pad)
                if kind == 1:
                    if began or size != 8 or data[:2] != b'\x00\x01' or data[2] != 0:
                        raise ValueError('expected responder without KEEP_CONN')
                    began = True
                elif kind == 4 and began and not params_done:
                    if data: env_bytes.extend(data)
                    else: params_done = True
                    if len(env_bytes) > MAX_PARAMS: raise ValueError('parameters too large')
                elif kind == 5 and params_done:
                    if not data: break
                    body.extend(data)
                    if len(body) > MAX_BODY: raise ValueError('body too large')
                elif kind == 2: return
                else: raise ValueError('unexpected FastCGI record')
            environ = parameters(env_bytes)
            if int(environ.get('CONTENT_LENGTH', '0')) != len(body): raise ValueError('body length mismatch')
            # CGI encodes bytes in ISO-8859-1 strings, as PEP 3333 requires.
            environ.setdefault('SCRIPT_NAME', '')
            environ.setdefault('PATH_INFO', '')
            environ.setdefault('QUERY_STRING', '')
            handler = BaseCGIHandler(io.BytesIO(body), Output(self.request), sys.stderr,
                                     environ, multithread=True, multiprocess=False)
            handler.run(self.server.application)
            record(self.request, 6)
            record(self.request, 3, b'\0' * 8)
        except (EOFError, ConnectionError, TimeoutError): pass
        except Exception as exc:
            print(f'WSGI gateway: {exc}', file=sys.stderr)
            try:
                record(self.request, 6)
                record(self.request, 3, b'\0\0\0\1\0\0\0\0')
            except OSError: pass

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def __init__(self, address, application):
        self.application = application
        self.slots = threading.BoundedSemaphore(32)
        super().__init__(address, Gateway)
    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request); return
        try: super().process_request(request, address)
        except BaseException:
            self.slots.release(); raise
    def process_request_thread(self, request, address):
        try: super().process_request_thread(request, address)
        finally: self.slots.release()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, help='module:callable')
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=9000)
    parser.add_argument('--app-dir', default='.')
    args = parser.parse_args()
    sys.path.insert(0, args.app_dir)
    module, separator, attr = args.app.partition(':')
    if not separator: parser.error('--app requires module:callable')
    app = getattr(importlib.import_module(module), attr)
    with Server((args.host, args.port), app) as server: server.serve_forever()

if __name__ == '__main__': main()
