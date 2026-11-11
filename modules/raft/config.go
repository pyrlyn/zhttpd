package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const maxNodes = 32
const maxDocument = 64 * 1024
const maxRequest = 1024 * 1024

var nodeID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,63}$`)

type Peer struct {
	ID          string `json:"id"`
	RaftAddress string `json:"raft_address"`
	APIAddress  string `json:"api_address"`
}
type Config struct {
	ID               string `json:"id"`
	ClusterID        string `json:"cluster_id"`
	RaftAddress      string `json:"raft_address"`
	APIAddress       string `json:"api_address"`
	DataDir          string `json:"data_dir"`
	MetricsInbox     string `json:"metrics_inbox"`
	MetricsView      string `json:"metrics_view"`
	ConfigOutput     string `json:"config_output"`
	TokenFile        string `json:"token_file"`
	Peers            []Peer `json:"peers"`
	Bootstrap        bool   `json:"bootstrap"`
	InsecureLoopback bool   `json:"insecure_loopback"`
	IntervalMS       int    `json:"interval_ms"`
	MetricsTTLMS     int64  `json:"metrics_ttl_ms"`
	TLS              struct {
		CA          string `json:"ca"`
		Certificate string `json:"certificate"`
		Key         string `json:"key"`
	} `json:"tls"`
	token string
}

func decodeJSON(r io.Reader, out any) error {
	d := json.NewDecoder(r)
	d.DisallowUnknownFields()
	if err := d.Decode(out); err != nil {
		return err
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		return errors.New("expected exactly one JSON value")
	}
	return nil
}
func loadConfig(path string) (Config, error) {
	var c Config
	data, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if len(data) > maxRequest {
		return c, errors.New("agent config too large")
	}
	if err = decodeJSON(strings.NewReader(string(data)), &c); err != nil {
		return c, err
	}
	base, err := filepath.Abs(filepath.Dir(path))
	if err != nil {
		return c, err
	}
	for _, p := range []*string{&c.DataDir, &c.MetricsInbox, &c.MetricsView, &c.ConfigOutput, &c.TokenFile, &c.TLS.CA, &c.TLS.Certificate, &c.TLS.Key} {
		if *p != "" {
			if !filepath.IsAbs(*p) {
				*p = filepath.Join(base, *p)
			}
			*p = filepath.Clean(*p)
		}
	}
	if c.IntervalMS == 0 {
		c.IntervalMS = 1000
	}
	if c.MetricsTTLMS == 0 {
		c.MetricsTTLMS = 5000
	}
	if err = c.validate(); err != nil {
		return c, err
	}
	token, err := os.ReadFile(c.TokenFile)
	if err != nil {
		return c, err
	}
	c.token = strings.TrimSpace(string(token))
	if len(c.token) < 32 || len(c.token) > 256 || strings.ContainsAny(c.token, "\r\n") {
		return c, errors.New("token_file must contain a 32..256 character secret")
	}
	return c, nil
}
func (c Config) validatePeer(p Peer) error {
	if !nodeID.MatchString(p.ID) {
		return errors.New("invalid peer ID")
	}
	for _, address := range []string{p.RaftAddress, p.APIAddress} {
		host, port, err := net.SplitHostPort(address)
		if err != nil || host == "" || port == "" {
			return fmt.Errorf("invalid address %q", address)
		}
		n, err := net.LookupPort("tcp", port)
		if err != nil || n <= 0 || n > 65535 {
			return errors.New("invalid port")
		}
		if c.InsecureLoopback {
			ip := net.ParseIP(host)
			if ip == nil || !ip.IsLoopback() {
				return errors.New("insecure_loopback requires literal loopback IP addresses")
			}
		}
	}
	if p.RaftAddress == p.APIAddress {
		return errors.New("Raft and API need separate ports")
	}
	return nil
}
func (c Config) validate() error {
	if !nodeID.MatchString(c.ID) || !nodeID.MatchString(c.ClusterID) {
		return errors.New("invalid id or cluster_id")
	}
	if err := c.validatePeer(Peer{c.ID, c.RaftAddress, c.APIAddress}); err != nil {
		return err
	}
	if c.DataDir == "" || c.MetricsInbox == "" || c.MetricsView == "" || c.TokenFile == "" {
		return errors.New("data_dir, metrics_inbox, metrics_view and token_file are required")
	}
	if c.MetricsInbox == c.MetricsView || c.DataDir == c.MetricsInbox || c.DataDir == c.MetricsView {
		return errors.New("data_dir, metrics_inbox and metrics_view must be different directories")
	}
	if c.IntervalMS < 100 || c.IntervalMS > 60000 || c.MetricsTTLMS < 3000 || c.MetricsTTLMS > 300000 || c.MetricsTTLMS < int64(c.IntervalMS)*3 {
		return errors.New("invalid metrics timing")
	}
	if len(c.Peers) == 0 || len(c.Peers) > maxNodes {
		return errors.New("peers must contain 1..32 initial contacts")
	}
	ids, addresses := map[string]bool{}, map[string]bool{}
	found := false
	for _, p := range c.Peers {
		if err := c.validatePeer(p); err != nil {
			return err
		}
		if ids[p.ID] || addresses[p.RaftAddress] || addresses[p.APIAddress] {
			return errors.New("duplicate peer ID or address")
		}
		ids[p.ID] = true
		addresses[p.RaftAddress] = true
		addresses[p.APIAddress] = true
		if p.ID == c.ID {
			if p.RaftAddress != c.RaftAddress || p.APIAddress != c.APIAddress {
				return errors.New("local addresses differ from peer list")
			}
			found = true
		}
	}
	if c.Bootstrap && !found {
		return errors.New("bootstrap membership must include local node")
	}
	if !c.InsecureLoopback && (c.TLS.CA == "" || c.TLS.Certificate == "" || c.TLS.Key == "") {
		return errors.New("mutual TLS is required outside explicit loopback development mode")
	}
	if c.InsecureLoopback && (c.TLS.CA != "" || c.TLS.Certificate != "" || c.TLS.Key != "") {
		return errors.New("choose TLS or insecure_loopback")
	}
	return nil
}
func (c Config) tlsConfig() (*tls.Config, error) {
	if c.InsecureLoopback {
		return nil, nil
	}
	cert, err := tls.LoadX509KeyPair(c.TLS.Certificate, c.TLS.Key)
	if err != nil {
		return nil, err
	}
	pem, err := os.ReadFile(c.TLS.CA)
	if err != nil {
		return nil, err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pem) {
		return nil, errors.New("invalid TLS CA")
	}
	return &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{cert}, RootCAs: roots, ClientCAs: roots, ClientAuth: tls.RequireAndVerifyClientCert}, nil
}
