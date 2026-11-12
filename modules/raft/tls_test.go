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

func TestMutualTLSReplication(t *testing.T) {
	dir := t.TempDir()
	cert, key := tlsMaterial(t, dir)
	peers := make([]Peer, 3)
	for i, id := range []string{"a", "b", "c"} {
		peers[i] = Peer{id, freeAddress(t), freeAddress(t)}
	}
	var nodes []*Node
	defer func() {
		for _, n := range nodes {
			n.close()
		}
	}()
	for _, p := range peers {
		local := filepath.Join(dir, p.ID)
		c := Config{ID: p.ID, ClusterID: "tls-replication", RaftAddress: p.RaftAddress,
			APIAddress: p.APIAddress, DataDir: filepath.Join(local, "data"),
			MetricsInbox: filepath.Join(local, "in"), MetricsView: filepath.Join(local, "out"),
			Peers: peers, Bootstrap: true, IntervalMS: 100, MetricsTTLMS: 5000,
			token: "test-token-with-at-least-32-characters"}
		c.TLS.CA, c.TLS.Certificate, c.TLS.Key = cert, cert, key
		n, err := startNode(c)
		if err != nil {
			t.Fatal(err)
		}
		nodes = append(nodes, n)
	}
	deadline := time.Now().Add(12 * time.Second)
	var leader *Node
	for time.Now().Before(deadline) && leader == nil {
		for _, n := range nodes {
			if n.raft.State() == raft.Leader && n.raft.VerifyLeader().Error() == nil {
				leader = n
				break
			}
		}
		if leader == nil {
			time.Sleep(20 * time.Millisecond)
		}
	}
	if leader == nil {
		t.Fatal("mTLS cluster did not elect a leader")
	}
	if err := leader.apply(Command{Kind: "config", Node: "a", TOML: "committed over mTLS"}); err != nil {
		t.Fatal(err)
	}
	for time.Now().Before(deadline) {
		applied := 0
		for _, n := range nodes {
			if n.fsm.copy().Documents["a"].TOML == "committed over mTLS" {
				applied++
			}
		}
		if applied == len(nodes) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("committed document did not replicate to all mTLS peers")
}

func TestShutdownDrainsPublisher(t *testing.T) {
	dir := t.TempDir()
	c := Config{ID: "a", ClusterID: "shutdown", RaftAddress: freeAddress(t), APIAddress: freeAddress(t),
		DataDir: filepath.Join(dir, "data"), MetricsInbox: filepath.Join(dir, "in"), MetricsView: filepath.Join(dir, "out"),
		Bootstrap: true, InsecureLoopback: true, IntervalMS: 60000, MetricsTTLMS: 5000,
		token: "test-token-with-at-least-32-characters"}
	c.Peers = []Peer{{c.ID, c.RaftAddress, c.APIAddress}}
	n, err := startNode(c)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for n.raft.State() != raft.Leader && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if n.raft.State() != raft.Leader {
		n.close()
		t.Fatal("single node did not become leader")
	}
	// Model a publisher already working when cancellation arrives. The
	// consensus engine must keep serving its final write until it returns.
	resume := make(chan struct{})
	result := make(chan error, 1)
	n.wg.Add(1)
	go func() {
		defer n.wg.Done()
		<-n.ctx.Done()
		<-resume
		result <- n.apply(Command{Kind: "config", Node: "a", TOML: "drained during shutdown"})
	}()
	closed := make(chan struct{})
	go func() { n.close(); close(closed) }()
	<-n.ctx.Done()
	// Give close time to reach the drain. Previously it stopped Raft here.
	time.Sleep(100 * time.Millisecond)
	close(resume)
	select {
	case err = <-result:
		if err != nil {
			t.Errorf("publisher lost its consensus engine: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("publisher hung during shutdown")
	}
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("node did not finish shutdown")
	}
	if n.fsm.copy().Documents["a"].TOML != "drained during shutdown" {
		t.Fatal("publisher's final write was not applied")
	}
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
