#!/usr/bin/env python3
"""Real pinned lego against a local ACME CA; never contacts Let's Encrypt."""
import base64
import contextlib
import datetime
import hashlib
import http.client
import http.server
import ipaddress
import json
import os
from pathlib import Path
import signal
import socket
import socketserver
import struct
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from e2e_common import free_port, running


def unb64(s): return base64.urlsafe_b64decode(s+'='*(-len(s)%4))
def b64(data): return base64.urlsafe_b64encode(data).rstrip(b'=').decode()

class DNSProvider(http.server.BaseHTTPRequestHandler):
    """Real lego httpreq API. Keep every TXT value, including apex + wildcard."""
    def log_message(self, *_): pass
    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        credentials=getattr(self.server, 'credentials', 'e2e:secret').encode()
        assert self.headers.get('Authorization') == 'Basic ' + base64.b64encode(credentials).decode()
        allowed=getattr(self.server, 'allowed', None)
        if allowed is not None: assert data['fqdn'] in allowed, data
        if not hasattr(self.server, 'seen'): self.server.seen=set()
        if self.path=='/present': self.server.seen.add(data['fqdn'])
        if self.path == '/present' and self.server.fail:
            self.server.failures += 1
            self.send_response(500); self.send_header('Content-Length', '0'); self.end_headers(); return
        key = (data['fqdn'], data['value'])
        with self.server.dns.lock:
            if self.path == '/present':
                self.server.dns.records.add(key)
                self.server.dns.presented += 1
            elif self.path == '/cleanup':
                if key in self.server.dns.records:
                    self.server.dns.records.remove(key)
                    self.server.dns.cleaned += 1
            else: raise AssertionError(self.path)
        self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()


class DNS(socketserver.BaseRequestHandler):
    """Small loopback DNS authority: TXT answers and empty CNAME responses."""
    def handle(self):
        wire, sock = self.request
        i = 12; labels = []
        while wire[i]:
            size = wire[i]; i += 1
            labels.append(wire[i:i+size].decode()); i += size
        fqdn = '.'.join(labels) + '.'
        qtype = struct.unpack('!H', wire[i+1:i+3])[0]
        question = wire[12:i+5]
        with self.server.lock:
            values = sorted(value for name, value in self.server.records if name == fqdn) if qtype == 16 else []
        answers = b''
        for value in values:
            data = value.encode()
            answers += b'\xc0\x0c' + struct.pack('!HHIH', 16, 1, 0, len(data)+1) + bytes([len(data)]) + data
        sock.sendto(wire[:2] + struct.pack('!HHHHH', 0x8580, 1, len(values), 0, 0) + question + answers, self.client_address)


def txt_values(address, fqdn):
    question = b''.join(bytes([len(label)]) + label.encode() for label in fqdn.rstrip('.').split('.')) + b'\0' + struct.pack('!HH', 16, 1)
    wire = struct.pack('!HHHHHH', 123, 0x100, 1, 0, 0, 0) + question
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(3); sock.sendto(wire, address); response, _ = sock.recvfrom(4096)
    assert response[:2] == wire[:2]
    count = struct.unpack('!H', response[6:8])[0]
    i = 12 + len(question); values = []
    for _ in range(count):
        size = struct.unpack('!H', response[i+10:i+12])[0]
        values.append(response[i+13:i+12+size].decode()); i += 12 + size
    return values


class CA(http.server.BaseHTTPRequestHandler):
    def log_message(self,*_): pass
    def reply(self,value=None,status=200,location=None,kind='application/json'):
        body=value if isinstance(value,bytes) else json.dumps(value).encode() if value is not None else b''
        self.send_response(status)
        self.send_header('Replay-Nonce',b64(os.urandom(24)))
        self.send_header('Content-Type',kind)
        self.send_header('Content-Length',str(len(body)))
        if location:self.send_header('Location',self.server.url+location)
        self.end_headers();self.wfile.write(body)
    def do_HEAD(self): self.reply(status=200)
    def do_GET(self):
        if self.path=='/directory': self.reply({k:self.server.url+v for k,v in {'newNonce':'/nonce','newAccount':'/account','newOrder':'/new-order'}.items()})
        else:self.reply({},404)
    def do_POST(self):
        wire=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        protected=json.loads(unb64(wire['protected']))
        data=json.loads(unb64(wire['payload'])) if wire['payload'] else {}
        if self.path=='/account':
            self.server.jwk=protected.get('jwk',self.server.jwk)
            self.reply({'status':'valid','contact':['mailto:test@example.test'],'orders':self.server.url+'/orders'},201,'/account/1')
        elif self.path=='/new-order':
            if self.server.fail:
                self.reply({'type':'urn:ietf:params:acme:error:serverInternal','detail':'test failure'},500);return
            self.server.domains=[v["value"] for v in data["identifiers"]]
            self.server.authorized=set();self.server.finalized=False
            self.reply(self.order(),201,'/order/1')
        elif self.path=='/order/1':self.reply(self.order())
        elif self.path.startswith('/auth/'):
            index = int(self.path.rsplit('/', 1)[1])
            domain = self.server.domains[index]
            status = 'valid' if index in self.server.authorized else 'pending'
            self.reply({'identifier': {'type': 'dns', 'value': domain.removeprefix('*.')},
                        'wildcard': domain.startswith('*.'), 'status': status,
                        'challenges': [self.challenge(index, status)]})
        elif self.path.startswith('/challenge/'):
            index = int(self.path.rsplit('/', 1)[1])
            token = self.challenge(index, 'pending')['token']
            jwk = self.server.jwk
            canonical = {k:jwk[k] for k in ('crv','kty','x','y')}
            expected = token + '.' + b64(hashlib.sha256(json.dumps(canonical,separators=(',',':'),sort_keys=True).encode()).digest())
            domain = self.server.domains[index]
            if self.server.challenge_type == 'dns-01':
                value = b64(hashlib.sha256(expected.encode()).digest())
                assert value in txt_values(self.server.dns.server_address, '_acme-challenge.' + domain.removeprefix('*.') + '.')
            else:
                with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{self.server.challenge_port}/.well-known/acme-challenge/{token}',headers={'Host': domain}),timeout=5) as response:
                    assert response.read().decode()==expected
            self.server.authorized.add(index)
            self.reply(self.challenge(index, 'valid'))
        elif self.path=='/finalize/1':
            assert len(self.server.authorized) == len(self.server.domains)
            csr=x509.load_der_x509_csr(unb64(data['csr']))
            assert csr.is_signature_valid
            san = csr.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
            assert set(san.get_values_for_type(x509.DNSName)) == set(self.server.domains)
            now=datetime.datetime.now(datetime.timezone.utc)
            cert=(x509.CertificateBuilder().subject_name(csr.subject).issuer_name(self.server.ca.subject)
                  .public_key(csr.public_key()).serial_number(x509.random_serial_number())
                  .not_valid_before(now-datetime.timedelta(minutes=1)).not_valid_after(now+datetime.timedelta(days=5))
                  .add_extension(san,critical=False)
                  .sign(self.server.key,hashes.SHA256()))
            self.server.certificate=cert.public_bytes(serialization.Encoding.PEM)+self.server.ca.public_bytes(serialization.Encoding.PEM)
            self.server.issued+=1;self.server.finalized=True
            names=tuple(sorted(self.server.domains))
            self.server.issued_by[names]=self.server.issued_by.get(names,0)+1
            self.reply(self.order())
        elif self.path=='/cert/1':self.reply(self.server.certificate,kind='application/pem-certificate-chain')
        else:self.reply({},404)
    def challenge(self, index, status):
        return {'type': self.server.challenge_type, 'url': self.server.url + f'/challenge/{index}',
                'status': status, 'token': f'local-test-token-{self.server.issued}-{index}'}
    def order(self):
        result={'status':'valid' if self.server.finalized else 'ready' if len(self.server.authorized) == len(self.server.domains) else 'pending',
                'identifiers':[{'type':'dns','value':d} for d in self.server.domains], 'authorizations':[self.server.url+f'/auth/{i}' for i in range(len(self.server.domains))],
                'finalize':self.server.url+'/finalize/1'}
        if self.server.finalized:result['certificate']=self.server.url+'/cert/1'
        return result

def peer_cert(port, host="localhost"):
    context=ssl._create_unverified_context()
    with socket.create_connection(('127.0.0.1',port),timeout=3) as raw:
        with context.wrap_socket(raw,server_hostname=host) as sock:
            cert=sock.getpeercert(binary_form=True)
            sock.sendall(f'GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n'.encode())
            data=b''
            while chunk:=sock.recv(65536):data+=chunk
            assert b'certificate-test' in data
            return cert

def configure(root, mode, port, challenge, directory, manual_cert, manual_key, domains=None, dns=None):
    """All external modes use a managed host and an unrelated manual TLS host."""
    (root/'index.html').write_text('certificate-test')
    if mode == 'self':
        server = f'[server]\ncompatibility="self"\n[http]\nlisten="127.0.0.1:{port}"\nresponse="certificate-test"\n'
    else:
        source = root/'server.conf'
        server = f'[server]\ncompatibility="{mode}"\nconfig="server.conf"\n'
        if mode == 'nginx':
            source.write_text(f'events {{}} http {{ access_log off; server {{ listen 127.0.0.1:{port} ssl; server_name localhost; root "{root}"; }} server {{ listen 127.0.0.1:{port} ssl; server_name other.test; root "{root}"; ssl_certificate "{manual_cert}"; ssl_certificate_key "{manual_key}"; }} }}')
        elif mode == 'apache':
            source.write_text(f'Listen 127.0.0.1:{port}\n<VirtualHost *:{port}>\nServerName localhost\nSSLEngine on\nDocumentRoot "{root}"\n</VirtualHost>\n<VirtualHost *:{port}>\nServerName other.test\nSSLEngine on\nDocumentRoot "{root}"\nSSLCertificateFile "{manual_cert}"\nSSLCertificateKeyFile "{manual_key}"\n</VirtualHost>\n')
        elif mode == 'litespeed':
            (root/'managed.conf').write_text(f'docRoot "{root}"\n')
            (root/'manual.conf').write_text(f'docRoot "{root}"\nvhssl {{\ncertFile "{manual_cert}"\nkeyFile "{manual_key}"\n}}\n')
            source.write_text(f'virtualhost managed {{\nvhRoot "{root}"\nconfigFile managed.conf\n}}\nvirtualhost manual {{\nvhRoot "{root}"\nconfigFile manual.conf\n}}\nlistener https {{\naddress 127.0.0.1:{port}\nsecure 1\nmap managed localhost\nmap manual other.test\n}}\n')
        else:
            source.write_text('import sites.caddy\n')
            (root/'sites.caddy').write_text(f'https://localhost:{port} {{\nrespond "certificate-test"\n}}\nhttps://other.test:{port} {{\ntls "{manual_cert}" "{manual_key}"\nrespond "certificate-test"\n}}\n')
    config = root/'config.toml'
    config.write_text(server+f'''[acme]
domain="localhost"
email="test@example.test"
directory="{directory}/directory"
storage="certificates"
accept_terms=true
http_port={challenge}
renew_before_days=30
check_interval_seconds=1
''')
    if domains:
        if mode != 'self':
            source = root/('sites.caddy' if mode == 'caddy' else 'server.conf')
            text = source.read_text()
            if mode == 'nginx': text = text.replace('server_name localhost;', 'server_name ' + ' '.join(domains[:-1]) + ';')
            elif mode == 'apache': text = text.replace('ServerName localhost', 'ServerName ' + domains[0] + '\nServerAlias ' + ' '.join(domains[1:-1]))
            elif mode == 'litespeed': text = text.replace('map managed localhost', 'map managed ' + ','.join(domains[:-1]))
            else: text = text.replace(f'https://localhost:{port}', ', '.join(f'https://{domain}:{port}' for domain in domains[:-1]))
            # A second managed vhost tests certificate assignment across SNI entries.
            if mode == 'nginx':
                text = text[:-1] + f' server {{ listen 127.0.0.1:{port} ssl; server_name dedicated.test; root "{root}"; }} }}'
            elif mode == 'apache':
                text += f'<VirtualHost *:{port}>\nServerName dedicated.test\nSSLEngine on\nDocumentRoot "{root}"\n</VirtualHost>\n'
            elif mode == 'litespeed':
                text = text.replace('map manual other.test', 'map managed dedicated.test\nmap manual other.test')
            else:
                text += f'https://dedicated.test:{port} {{\nrespond "certificate-test"\n}}\n'
            source.write_text(text)
        text = config.read_text().replace('domain="localhost"', 'domains=' + json.dumps(domains))
        if dns:
            # Deterministic local fixture: wait instead of discovering public authoritative DNS.
            # The CA still verifies the actual TXT record over UDP before signing the CSR.
            text += f'challenge="dns-01"\ndns_provider="httpreq"\ndns_resolvers=["127.0.0.1:{dns.server_address[1]}"]\ndns_propagation_wait_seconds=1\n'
            text = text.replace(f'http_port={challenge}', f'http_port={port}')
        config.write_text(text)
    return config



@contextlib.contextmanager
def local_ca():
    with tempfile.TemporaryDirectory(prefix='zhttpd-acme-') as d:
        root=Path(d);port=free_port();challenge=free_port()
        with http.server.ThreadingHTTPServer(('127.0.0.1',0),CA) as ca, socketserver.ThreadingUDPServer(('127.0.0.1',0),DNS) as dns, http.server.ThreadingHTTPServer(('127.0.0.1',0),DNSProvider) as provider:
            ca.url=f'https://127.0.0.1:{ca.server_port}';ca.challenge_port=challenge
            ca.jwk={};ca.authorized=set();ca.finalized=False;ca.fail=False;ca.issued=0;ca.issued_by={}
            ca.domains=['localhost'];ca.challenge_type='http-01';ca.dns=dns
            dns.records=set();dns.lock=threading.Lock();dns.presented=0;dns.cleaned=0;provider.dns=dns;provider.fail=False;provider.failures=0
            dns_thread=threading.Thread(target=dns.serve_forever,daemon=True);dns_thread.start()
            provider_thread=threading.Thread(target=provider.serve_forever,daemon=True);provider_thread.start()
            ca.key=ec.generate_private_key(ec.SECP256R1())
            now=datetime.datetime.now(datetime.timezone.utc)
            name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'Local E2E CA')])
            ca.ca=(x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(ca.key.public_key())
                   .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(days=1))
                   .not_valid_after(now+datetime.timedelta(days=30)).add_extension(x509.BasicConstraints(ca=True,path_length=None),True)
                   .sign(ca.key,hashes.SHA256()))
            (root/'ca.pem').write_bytes(ca.ca.public_bytes(serialization.Encoding.PEM))
            tls_key=ec.generate_private_key(ec.SECP256R1())
            tls_cert=(x509.CertificateBuilder().subject_name(name).issuer_name(ca.ca.subject).public_key(tls_key.public_key())
                      .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(days=1))
                      .not_valid_after(now+datetime.timedelta(days=3))
                      .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]),False)
                      .sign(ca.key,hashes.SHA256()))
            (root/'server.pem').write_bytes(tls_cert.public_bytes(serialization.Encoding.PEM))
            (root/'key.pem').write_bytes(tls_key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
            tls_context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls_context.load_cert_chain(root/'server.pem',root/'key.pem')
            ca.socket=tls_context.wrap_socket(ca.socket,server_side=True)
            env={**os.environ,'LEGO_CA_CERTIFICATES':str(root/'ca.pem'), 'HTTPREQ_ENDPOINT':f'http://127.0.0.1:{provider.server_port}', 'HTTPREQ_USERNAME':'e2e', 'HTTPREQ_PASSWORD':'secret'}
            thread=threading.Thread(target=ca.serve_forever,daemon=True);thread.start()
            try:
                from types import SimpleNamespace
                yield SimpleNamespace(root=root, port=port, challenge=challenge, ca=ca, dns=dns,
                                      provider=provider, env=env, tls_cert=tls_cert)
            finally:
                ca.shutdown();thread.join()
                provider.shutdown();provider_thread.join()
                dns.shutdown();dns_thread.join()
