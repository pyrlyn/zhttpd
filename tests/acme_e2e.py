#!/usr/bin/env python3
"""Legacy single-certificate and multi-SAN ACME regression tests."""
import contextlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from acme_common import local_ca, configure, peer_cert
from e2e_common import running

binary=Path(sys.argv[1]).resolve()

def invalid_config(config, expected):
    result = subprocess.run([binary, '-t', '-c', config], capture_output=True)
    assert result.returncode != 0 and expected in result.stderr, result.stderr.decode()

with local_ca() as fixture:
    root=fixture.root;port=fixture.port;challenge=fixture.challenge
    ca=fixture.ca;dns=fixture.dns;provider=fixture.provider;env=fixture.env;tls_cert=fixture.tls_cert
    for mode in ('self', 'nginx', 'apache', 'litespeed', 'caddy'):
        case = root/mode; case.mkdir()
        ca.fail = False
        issued_before = ca.issued
        config = configure(case, mode, port, challenge, ca.url, root/'server.pem', root/'key.pem')
        original = config.read_text()
        # Gates and host selection fail before any ACME requests.
        config.write_text('[modules]\nacme=false\n'+original)
        invalid_config(config, b'acme module is disabled')
        config.write_text(original.replace(f'http_port={challenge}', f'http_port={port}'))
        invalid_config(config, b'challenge port')
        if mode != 'self':
            config.write_text(original.replace('domain="localhost"', 'domain="unmatched.test"'))
            invalid_config(config, b'HTTPS')
            # -t must still validate a different host on the SAME listener.
            manual_key = root/'key.pem'
            good_key = manual_key.read_bytes()
            manual_key.write_text('not a PEM key')
            config.write_text(original)
            invalid_config(config, b'cannot load certificate key')
            manual_key.write_bytes(good_key)
            source = case/('sites.caddy' if mode == 'caddy' else 'server.conf')
            secure_source = source.read_text()
            plain_source = {
                'nginx': lambda t: t.replace(' ssl;', ';'),
                'apache': lambda t: t.replace('SSLEngine on', 'SSLEngine off'),
                'litespeed': lambda t: t.replace('secure 1', 'secure 0'),
                'caddy': lambda t: t.replace('https://', 'http://'),
            }[mode](secure_source)
            source.write_text(plain_source)
            invalid_config(config, b'matching HTTPS virtual host')
            source.write_text(secure_source)
        config.write_text(original)
        subprocess.run([binary,'-t','-c',config],check=True)
        assert ca.issued==issued_before,'config validation must not issue certificates'
        with running([binary,'-c',config],port,env=env):
            first=peer_cert(port)
            if mode != 'self':
                manual = peer_cert(port, 'other.test')
                assert manual == tls_cert.public_bytes(serialization.Encoding.DER)
            for _ in range(150):
                time.sleep(.1)
                if peer_cert(port)!=first:break
            else:raise AssertionError(f'{mode}: renewed certificate not reloaded')
            assert ca.issued>=issued_before+2
            if mode != 'self': assert peer_cert(port, 'other.test') == manual
            ca.fail=True
            stable=peer_cert(port)
            time.sleep(2)
            assert peer_cert(port)==stable,'failed renewal replaced active certificate'
        # Restart with existing credentials works even while CA fails.
        with running([binary,'-c',config],port,env=env): assert peer_cert(port)==stable
        print(f'PASS: {mode} real lego issuance, renewal/reload, failure retention, restart, offline validation, SNI isolation', flush=True)

    # Both challenge types produce one SAN certificate in all five modes.
    for challenge_type, domains in (
        ('http-01', ['localhost', 'www.localhost', 'second.test', 'dedicated.test']),
        ('dns-01', ['example.test', '*.example.test', 'second.test', 'dedicated.test']),
    ):
        ca.challenge_type = challenge_type
        hosts = [d.replace('*.', 'www.') for d in domains]
        for mode in ('self', 'nginx', 'apache', 'litespeed', 'caddy'):
            case = root/(mode+'-'+challenge_type);case.mkdir()
            ca.fail=False;issued_before=ca.issued
            config=configure(case, mode, port, challenge, ca.url, root/'server.pem', root/'key.pem', domains, dns if challenge_type=='dns-01' else None)
            original=config.read_text()
            array='domains='+json.dumps(domains)
            for replacement, expected in (
                ('domains=[]', b'nonempty domains'),
                ('domains=["x.test", "X.test"]', b'duplicate ACME domain'),
                ('domains=["bad.*.test"]', b'invalid ACME DNS domain'),
                ('domains=["x.test", 1]', b'string array element'),
                ('domains=["x.test" "y.test"]', b'comma or closing bracket'),
                ('domains=["x.test"]\ndomain="x.test"', b'mutually exclusive'),
            ):
                config.write_text(original.replace(array,replacement));invalid_config(config,expected)
            if mode!='self':
                config.write_text(original.replace(array,'domains='+json.dumps([d for d in domains if d!='second.test'])))
                invalid_config(config,b'HTTPS' if mode=='caddy' else b'cover every name')
            if challenge_type=='http-01':
                config.write_text(original+'dns_provider="httpreq"\n')
                invalid_config(config,b'DNS settings require dns-01')
            if challenge_type=='dns-01':
                for old,new,expected in (
                    ('challenge="dns-01"','challenge="http-01"',b'wildcard certificates require dns-01'),
                    ('dns_provider="httpreq"','dns_provider="manual"',b'automatic dns_provider'),
                    ('dns_provider="httpreq"','dns_provider=""',b'automatic dns_provider'),
                    ('dns_propagation_wait_seconds=1','dns_propagation_wait_seconds=600',b'shorter than operation timeout'),
                ):
                    config.write_text(original.replace(old,new));invalid_config(config,expected)
            config.write_text(original)
            subprocess.run([binary,'-t','-c',config],check=True)
            assert ca.issued==issued_before
            with running([binary,'-c',config],port,env=env,startup_timeout=20):
                first=peer_cert(port,hosts[0])
                san=x509.load_der_x509_certificate(first).extensions.get_extension_for_class(x509.SubjectAlternativeName).value
                assert set(san.get_values_for_type(x509.DNSName))==set(domains)
                for host in hosts: assert peer_cert(port,host)==first
                if mode!='self': assert peer_cert(port,'other.test')==tls_cert.public_bytes(serialization.Encoding.DER)
                for _ in range(300):
                    time.sleep(.1)
                    renewed=peer_cert(port,hosts[0])
                    if renewed!=first:break
                else:raise AssertionError(f'{mode}/{challenge_type}: renewal not reloaded')
                if challenge_type=='dns-01':
                    # Exercise failure in the DNS provider itself, not only an unavailable CA.
                    provider.fail=True
                    failures_before=provider.failures
                    for _ in range(100):
                        time.sleep(.1)
                        if provider.failures>failures_before:break
                    else:raise AssertionError('DNS provider failure was not exercised')
                    assert peer_cert(port,hosts[0])==renewed
                ca.fail=True
                for host in hosts: assert peer_cert(port,host)==renewed
                time.sleep(2)
                assert peer_cert(port,hosts[0])==renewed
                if mode!='self': assert peer_cert(port,'other.test')==tls_cert.public_bytes(serialization.Encoding.DER)
                if challenge_type=='dns-01':
                    assert dns.presented>0 and dns.presented==dns.cleaned and not dns.records, 'TXT cleanup after issuance and renewal'
            provider.fail=False
            # Reordering a SAN set reuses the same cached certificate offline.
            config.write_text(original.replace(array,'domains='+json.dumps(list(reversed(domains)))))
            with running([binary,'-c',config],port,env=env): assert peer_cert(port,hosts[0])==renewed
            if mode=='self' and challenge_type=='dns-01':
                # A changed set cannot start using the old cached certificate when the CA is down.
                config.write_text(original.replace(array,'domains='+json.dumps(domains+['new.test']))+'operation_timeout_seconds=2\n')
                with subprocess.Popen([binary,'-c',config],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True) as failed:
                    try:
                        _, errors=failed.communicate(timeout=10)
                        assert failed.returncode!=0 and b'issuing initial ACME certificate' in errors, errors.decode()
                    finally:
                        with contextlib.suppress(ProcessLookupError): os.killpg(failed.pid,signal.SIGKILL)
                        failed.wait(timeout=5)
            print(f'PASS: {mode} {challenge_type} multi-domain SAN, wildcard/SNI, renewal, TXT cleanup, offline reordered restart',flush=True)
