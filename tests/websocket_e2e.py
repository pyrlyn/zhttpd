#!/usr/bin/env python3
"""The same wire-level contract for native server and all three SDK examples."""
import base64
import concurrent.futures
import hashlib
import os
from pathlib import Path
import socket
import struct
import sys
import tempfile
from e2e_common import free_port, running

class Client:
    def __init__(self, port, extra=b''):
        self.socket = socket.create_connection(('127.0.0.1',port), timeout=4)
        self.file = self.socket.makefile('rb')
        key = base64.b64encode(os.urandom(16))
        self.socket.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '+key+b'\r\n\r\n'+extra)
        assert self.file.readline().startswith(b'HTTP/1.1 101')
        headers={}
        while True:
            line=self.file.readline()
            if line == b'\r\n': break
            k,v=line.split(b':',1);headers[k.lower()]=v.strip()
        assert headers[b'sec-websocket-accept']==base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
    @staticmethod
    def frame(op,data=b'',fin=True):
        mask=os.urandom(4); size=len(data)
        length=bytes([size|128]) if size<126 else b'\xfe'+struct.pack('!H',size) if size<=65535 else b'\xff'+struct.pack('!Q',size)
        return bytes([(128 if fin else 0)|op])+length+mask+bytes(x^mask[i%4] for i,x in enumerate(data))
    def send(self,op,data=b'',fin=True): self.socket.sendall(self.frame(op,data,fin))
    def read(self):
        head=self.file.read(2); assert len(head)==2
        assert head[0]&128 and not head[1]&128
        size=head[1]&127
        if size==126:size=struct.unpack('!H',self.file.read(2))[0]
        if size==127:size=struct.unpack('!Q',self.file.read(8))[0]
        data=self.file.read(size);assert len(data)==size
        return head[0]&15,data
    def close(self): self.file.close();self.socket.close()

def contract(port):
    c=Client(port,Client.frame(1,b'pipelined'))
    try:
        assert c.read()==(1,b'pipelined')
        for op,body in ((1,'Привет'.encode()),(2,os.urandom(65536)),(1,b'')):
            c.send(op,body);assert c.read()==(op,body)
        c.send(1,b'frag',False);c.send(9,b'ping');assert c.read()==(10,b'ping')
        c.send(0,b'mented');assert c.read()==(1,b'fragmented')
        c.send(8,struct.pack('!H',1000));assert c.read()==(8,struct.pack('!H',1000))
    finally:c.close()
    for packet,code in ((b'\x81\x01x',1002),(Client.frame(1,b'\xff'),1007),(Client.frame(0,b'orphan'),1002)):
        c=Client(port)
        try:
            c.socket.sendall(packet)
            op,payload=c.read();assert op==8 and struct.unpack('!H',payload[:2])[0]==code
        finally:c.close()
    def parallel(i):
        c=Client(port)
        try:
            msg=str(i).encode();c.send(1,msg);assert c.read()==(1,msg)
        finally:c.close()
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:list(pool.map(parallel,range(24)))

for argument in sys.argv[1:]:
    binary=Path(argument).resolve();port=free_port()
    with tempfile.TemporaryDirectory(prefix='zhttpd-ws-') as d:
        if binary.name=='zhttpd':
            config=Path(d)/'config.toml'
            config.write_text(f'[server]\ncompatibility="self"\n[http]\nlisten="127.0.0.1:{port}"\n[[http.routes]]\npath="/"\nwebsocket=true\n')
            command=[binary,'-c',config]
        else:command=[binary,f'127.0.0.1:{port}']
        with running(command,port):contract(port)
    print(f'PASS: WebSocket shared contract: {binary.name}')
