"""Shared local TLS material and QUIC probes for reload E2E tests."""
import datetime
import ssl
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from aioquic.asyncio import connect
from aioquic.quic.configuration import QuicConfiguration


def pair(key=None):
    key = key or ec.generate_private_key(ec.SECP256R1())
    now = datetime.datetime.now(datetime.timezone.utc)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')])
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1))
            .not_valid_after(now+datetime.timedelta(days=2))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]), False)
            .sign(key, hashes.SHA256()))
    return cert, key


def pem_cert(cert): return cert.public_bytes(serialization.Encoding.PEM)
def pem_key(key, traditional=False, password=None):
    return key.private_bytes(serialization.Encoding.PEM,
                             serialization.PrivateFormat.TraditionalOpenSSL if traditional else serialization.PrivateFormat.PKCS8,
                             serialization.BestAvailableEncryption(password) if password else serialization.NoEncryption())
def der(cert): return cert.public_bytes(serialization.Encoding.DER)
def atomic(path, data):
    temp = path.with_name(path.name+'.tmp')
    temp.write_bytes(data); temp.chmod(0o600); temp.replace(path)


async def quic_cert(port):
    config = QuicConfiguration(is_client=True, alpn_protocols=['h3'], server_name='localhost', verify_mode=ssl.CERT_NONE)
    async with connect('127.0.0.1', port, configuration=config) as protocol:
        return der(protocol._quic.tls._peer_certificate)

