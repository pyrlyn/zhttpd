package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/hashicorp/raft"
)

func tlsMaterial(t *testing.T, dir string) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test-cluster"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}}
	cert, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certPath, keyPath := filepath.Join(dir, "tls.crt"), filepath.Join(dir, "tls.key")
	if err = os.WriteFile(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert}), 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}), 0600); err != nil {
		t.Fatal(err)
	}
	return certPath, keyPath
}
func freeAddress(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := l.Addr().String()
	_ = l.Close()
	return address
}
func TestMutualTLSAPIAndClusterIsolation(t *testing.T) {
	dir := t.TempDir()
	cert, key := tlsMaterial(t, dir)
	c := Config{ID: "a", ClusterID: "tls-cluster", RaftAddress: freeAddress(t), APIAddress: freeAddress(t), DataDir: filepath.Join(dir, "data"), MetricsInbox: filepath.Join(dir, "in"), MetricsView: filepath.Join(dir, "out"), Bootstrap: true, IntervalMS: 100, MetricsTTLMS: 5000, token: "test-token-with-at-least-32-characters"}
	c.TLS.CA = cert
	c.TLS.Certificate = cert
	c.TLS.Key = key
	c.Peers = []Peer{{c.ID, c.RaftAddress, c.APIAddress}}
	n, err := startNode(c)
	if err != nil {
		t.Fatal(err)
	}
	defer n.close()
	tc, err := c.tlsConfig()
	if err != nil {
		t.Fatal(err)
	}
	transport := &http.Transport{TLSClientConfig: tc}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 2 * time.Second}
	request, err := http.NewRequest("GET", "https://"+c.APIAddress+"/v1/status", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+c.token)
	request.Header.Set("X-Zhttpd-Cluster", c.ClusterID)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatal(response.Status)
	}
	request.Header.Set("X-Zhttpd-Cluster", "another-cluster")
	response, err = client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != 401 {
		t.Fatal("cross-cluster API accepted")
	}
	noCert := tc.Clone()
	noCert.Certificates = nil
	unauthTransport := &http.Transport{TLSClientConfig: noCert}
	defer unauthTransport.CloseIdleConnections()
	unauth := &http.Client{Transport: unauthTransport, Timeout: 2 * time.Second}
	if response, err = unauth.Do(request); err == nil {
		_ = response.Body.Close()
		t.Fatal("API accepted a client without certificate")
	}
	// Match the greeting size so rejection does not depend on a timeout.
	wrongCluster := streamLayer{tls: tc, greeting: "ZHTTPD-RAFT/1 xxx-cluster\n"}
	conn, err := wrongCluster.Dial(raft.ServerAddress(c.RaftAddress), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	var buffer [1]byte
	if _, err = conn.Read(buffer[:]); err != io.EOF {
		t.Fatalf("wrong cluster should close connection: %v", err)
	}
}
