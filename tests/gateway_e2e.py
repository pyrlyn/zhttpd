#!/usr/bin/env python3
import contextlib
import http.client
import json
from pathlib import Path
import socketserver
import struct
import sys
import subprocess
import tempfile
import threading
from e2e_common import free_port, running

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'modules/wsgi'))
from server import parameters, record, exact
BINARY=Path(sys.argv[1]).resolve()

class FastCGI(socketserver.StreamRequestHandler):
    def handle(self):
        params=bytearray();body=bytearray()
        try:
            while True:
                version,kind,rid,size,pad,_=struct.unpack('!BBHHBB',exact(self.rfile,8))
                assert version==1 and rid==1
                data=exact(self.rfile,size);exact(self.rfile,pad)
                if kind==4:params.extend(data)
                if kind==5:
                    if not data:break
                    body.extend(data)
            env=parameters(params)
            if env['QUERY_STRING']=='bad':
                self.request.sendall(b'\x02\x06\x00\x01\0\0\0\0');return
            if env['QUERY_STRING']=='large':payload=b'x'*200000
            else:payload=json.dumps({'method':env['REQUEST_METHOD'],'uri':env['REQUEST_URI'],
                  'body':body.decode(),'script':env['SCRIPT_FILENAME'],'proxy':env.get('HTTP_PROXY')}).encode()
            header=b'Status: 201 Created\r\nContent-Type: application/json\r\n\r\n'
            # Split headers across records, interleave stderr, exercise padding.
            record(self.request,6,header[:10]);record(self.request,7,b'diagnostic')
            record(self.request,6,header[10:])
            for i in range(0,len(payload),97):record(self.request,6,payload[i:i+97])
            record(self.request,6);record(self.request,3,b'\0'*8)
        except (EOFError,ConnectionError):pass

@contextlib.contextmanager
def backend():
    with socketserver.ThreadingTCPServer(('127.0.0.1',0),FastCGI) as server:
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:yield server.server_address[1]
        finally:server.shutdown();thread.join()

def request(port,method,path,body=None):
    c=http.client.HTTPConnection('127.0.0.1',port,timeout=10)
    c.request(method,path,body=body,headers={'Proxy':'must-not-be-forwarded'})
    r=c.getresponse();result=r.status,r.read();c.close();return result

with tempfile.TemporaryDirectory(prefix='zhttpd-gateway-') as d:
    conf=Path(d)/'config.toml';port=free_port()
    def configure(mode,up):
        conf.write_text(f'[server]\ncompatibility="self"\n[http]\nlisten="127.0.0.1:{port}"\n[[http.routes]]\npath="/"\n{mode}="127.0.0.1:{up}"\n')
    with backend() as up:
        configure('fastcgi',up)
        with running([BINARY,'-c',conf],port):
            status,body=request(port,'POST','/app.php?test',b'a'*180000)
            data=json.loads(body)
            assert status==201 and data['body']=='a'*180000 and data['uri']=='/app.php?test' and data['proxy'] is None
            assert data['script'].endswith('/app.php')
            assert request(port,'GET','/?large')==(201,b'x'*200000)
            assert request(port,'GET','/?bad')[0]==502
            assert request(port,'HEAD','/')[1]==b''
        source=Path(d)/'nginx.conf'
        source.write_text(f'events {{}} http {{ access_log off; server {{ listen 127.0.0.1:{port}; root /srv/www; location / {{ fastcgi_pass 127.0.0.1:{up}; fastcgi_param SCRIPT_FILENAME /srv/application.php; }} }} }}')
        conf.write_text('[server]\ncompatibility="nginx"\nconfig="nginx.conf"\n')
        with running([BINARY,'-c',conf],port):
            status,body=request(port,'GET','/from-nginx')
            assert status==201 and json.loads(body)['script']=='/srv/application.php'
        conf.write_text('[modules]\nfastcgi=false\n'+conf.read_text())
        assert subprocess.run([BINARY,'-t','-c',conf],capture_output=True).returncode!=0
    up=free_port();configure('wsgi',up)
    with running([sys.executable,ROOT/'modules/wsgi/server.py','--port',up,'--app-dir',ROOT/'examples/wsgi','--app','app:application'],up):
        with running([BINARY,'-c',conf],port):
            status,body=request(port,'POST','/hello?q=yes','body')
            assert status==200 and json.loads(body)=={'method':'POST','path':'/hello','query':'q=yes','body':'body','scheme':'http'}
            assert request(port,'GET','/error')[0]==500
            assert request(port,'GET','/after-error')[0]==200
print('PASS: FastCGI records, large upload/stream, invalid upstream, HEAD; real WSGI example and errors')
