package main

import (
	"context"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/hashicorp/raft"
	raftboltdb "github.com/hashicorp/raft-boltdb/v2"
	"go.etcd.io/bbolt"
)

// StreamLayer authenticates TLS peers and rejects accidental cross-cluster RPCs.
type streamLayer struct {
	net.Listener
	tls      *tls.Config
	greeting string
}

func (s *streamLayer) Accept() (net.Conn, error) {
	for {
		conn, err := s.Listener.Accept()
		if err != nil {
			return nil, err
		}
		_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
		hello := make([]byte, len(s.greeting))
		_, err = io.ReadFull(conn, hello)
		if err != nil || string(hello) != s.greeting {
			_ = conn.Close()
			continue
		}
		_ = conn.SetDeadline(time.Time{})
		return conn, nil
	}
}
func (s *streamLayer) Dial(address raft.ServerAddress, timeout time.Duration) (net.Conn, error) {
	d := net.Dialer{Timeout: timeout}
	var conn net.Conn
	var err error
	if s.tls != nil {
		conn, err = tls.DialWithDialer(&d, "tcp", string(address), s.tls)
	} else {
		conn, err = d.Dial("tcp", string(address))
	}
	if err != nil {
		return nil, err
	}
	_ = conn.SetWriteDeadline(time.Now().Add(timeout))
	_, err = io.WriteString(conn, s.greeting)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	_ = conn.SetWriteDeadline(time.Time{})
	return conn, nil
}

type Node struct {
	cfg         Config
	raft        *raft.Raft
	fsm         *FSM
	store       *raftboltdb.BoltStore
	transport   *raft.NetworkTransport
	server      *http.Server
	client      *http.Client
	ctx         context.Context
	cancel      context.CancelFunc
	wg          sync.WaitGroup
	membership  sync.Mutex
	exportMu    sync.Mutex
	exportError string
}

func startNode(c Config) (n *Node, err error) {
	n = &Node{cfg: c, fsm: newFSM()}
	n.ctx, n.cancel = context.WithCancel(context.Background())
	created := n
	defer func() {
		if err != nil {
			created.close()
		}
	}()
	for _, dir := range []string{c.DataDir, c.MetricsInbox, c.MetricsView} {
		if err = os.MkdirAll(dir, 0700); err != nil {
			return nil, err
		}
	}
	n.store, err = raftboltdb.New(raftboltdb.Options{Path: filepath.Join(c.DataDir, "raft.db"), BoltOptions: &bbolt.Options{Timeout: time.Second}})
	if err != nil {
		return nil, err
	}
	identity := c.ClusterID + "/" + c.ID
	previous, e := n.store.Get([]byte("zhttpd-identity"))
	if e != nil && !errors.Is(e, raftboltdb.ErrKeyNotFound) {
		return nil, e
	}
	if len(previous) > 0 && string(previous) != identity {
		return nil, errors.New("data directory belongs to another cluster or node")
	}
	if err = n.store.Set([]byte("zhttpd-identity"), []byte(identity)); err != nil {
		return nil, err
	}
	tc, err := c.tlsConfig()
	if err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp", c.RaftAddress)
	if err != nil {
		return nil, err
	}
	if tc != nil {
		listener = tls.NewListener(listener, tc)
	}
	n.transport = raft.NewNetworkTransport(&streamLayer{listener, tc, "ZHTTPD-RAFT/1 " + c.ClusterID + "\n"}, 3, 2*time.Second, os.Stderr)
	snapshots, err := raft.NewFileSnapshotStore(c.DataDir, 3, os.Stderr)
	if err != nil {
		return nil, err
	}
	exists, err := raft.HasExistingState(n.store, n.store, snapshots)
	if err != nil {
		return nil, err
	}
	rc := raft.DefaultConfig()
	rc.LocalID = raft.ServerID(c.ID)
	rc.LogLevel = "WARN"
	rc.SnapshotThreshold = 256
	rc.TrailingLogs = 64
	rc.SnapshotInterval = 20 * time.Second
	n.raft, err = raft.NewRaft(rc, n.fsm, n.store, n.store, snapshots, n.transport)
	if err != nil {
		return nil, err
	}
	if c.Bootstrap && !exists {
		var membership raft.Configuration
		for _, p := range c.Peers {
			membership.Servers = append(membership.Servers, raft.Server{ID: raft.ServerID(p.ID), Address: raft.ServerAddress(p.RaftAddress), Suffrage: raft.Voter})
		}
		if err = n.raft.BootstrapCluster(membership).Error(); err != nil {
			return nil, err
		}
	}
	n.client = &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{TLSClientConfig: tc, MaxIdleConnsPerHost: 2}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	api, err := net.Listen("tcp", c.APIAddress)
	if err != nil {
		return nil, err
	}
	if tc != nil {
		api = tls.NewListener(api, tc)
	}
	n.server = &http.Server{Handler: n.routes(), ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 10 * time.Second, MaxHeaderBytes: 16 * 1024}
	n.wg.Add(3)
	go func() {
		defer n.wg.Done()
		if e := n.server.Serve(api); e != nil && e != http.ErrServerClosed {
			log.Printf("Raft API stopped: %v", e)
			n.cancel()
		}
	}()
	go func() { defer n.wg.Done(); n.publishLoop() }()
	go func() { defer n.wg.Done(); n.exportLoop() }()
	return n, nil
}
func (n *Node) close() {
	n.cancel()
	if n.server != nil {
		_ = n.server.Shutdown(context.Background())
	}
	// Drain application futures while Raft's FSM runner is still alive.
	// Shutdown may leave a committed Apply future queued to that runner without
	// a response. Stop HTTP admission and the publishers before stopping Raft.
	n.wg.Wait()
	if n.raft != nil {
		_ = n.raft.Shutdown().Error()
	}
	if n.transport != nil {
		_ = n.transport.Close()
	}
	if n.client != nil {
		n.client.CloseIdleConnections()
	}
	if n.store != nil {
		_ = n.store.Close()
	}
}
func (n *Node) peer(id string) (Peer, bool) {
	s := n.fsm.copy()
	if p, ok := s.Peers[id]; ok {
		return p, true
	}
	for _, p := range n.cfg.Peers {
		if p.ID == id {
			return p, true
		}
	}
	return Peer{}, false
}
func (n *Node) leaderAPI() string {
	_, id := n.raft.LeaderWithID()
	p, ok := n.peer(string(id))
	if !ok {
		return ""
	}
	scheme := "https"
	if n.cfg.InsecureLoopback {
		scheme = "http"
	}
	return scheme + "://" + p.APIAddress
}
func (n *Node) apply(command Command) error {
	data, err := json.Marshal(command)
	if err != nil {
		return err
	}
	future := n.raft.Apply(data, 2*time.Second)
	if err = future.Error(); err != nil {
		return err
	}
	if result := future.Response(); result != nil {
		if e, ok := result.(error); ok {
			return e
		}
	}
	return nil
}
func reply(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func (n *Node) leader(w http.ResponseWriter) bool {
	if n.raft.State() != raft.Leader || n.raft.VerifyLeader().Error() != nil {
		reply(w, 409, map[string]any{"error": "not leader or no quorum", "leader": n.leaderAPI()})
		return false
	}
	return true
}
func (n *Node) members() (raft.Configuration, uint64, error) {
	f := n.raft.GetConfiguration()
	if err := f.Error(); err != nil {
		return raft.Configuration{}, 0, err
	}
	return f.Configuration(), f.Index(), nil
}
func (n *Node) isMember(id string) bool {
	c, _, err := n.members()
	if err != nil {
		return false
	}
	for _, s := range c.Servers {
		if string(s.ID) == id {
			return true
		}
	}
	return false
}
func (n *Node) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/status", func(w http.ResponseWriter, r *http.Request) {
		_, leader := n.raft.LeaderWithID()
		members, index, _ := n.members()
		n.exportMu.Lock()
		exportErr := n.exportError
		n.exportMu.Unlock()
		reply(w, 200, map[string]any{"id": n.cfg.ID, "role": n.raft.State().String(), "leader_id": leader, "leader": n.leaderAPI(), "applied_index": n.fsm.copy().Index, "membership_index": index, "members": members.Servers, "export_error": exportErr, "stats": n.raft.Stats()})
	})
	mux.HandleFunc("GET /v1/state", func(w http.ResponseWriter, r *http.Request) {
		n.membership.Lock()
		defer n.membership.Unlock()
		if !n.leader(w) {
			return
		}
		if err := n.raft.Barrier(2 * time.Second).Error(); err != nil {
			reply(w, 503, map[string]string{"error": err.Error()})
			return
		}
		reply(w, 200, n.fsm.copy())
	})
	mux.HandleFunc("PUT /v1/config", func(w http.ResponseWriter, r *http.Request) {
		if !n.leader(w) {
			return
		}
		var req struct {
			Node             string `json:"node"`
			TOML             string `json:"toml"`
			ExpectedRevision uint64 `json:"expected_revision"`
		}
		if err := decodeJSON(r.Body, &req); err != nil || !nodeID.MatchString(req.Node) || len(req.TOML) == 0 || len(req.TOML) > maxDocument || !n.isMember(req.Node) {
			reply(w, 400, map[string]string{"error": "invalid config or unknown member"})
			return
		}
		if err := n.apply(Command{Kind: "config", Node: req.Node, TOML: req.TOML, ExpectedRevision: req.ExpectedRevision}); err != nil {
			reply(w, 409, map[string]string{"error": err.Error()})
			return
		}
		reply(w, 200, map[string]any{"revision": req.ExpectedRevision + 1})
	})
	mux.HandleFunc("POST /v1/metrics", func(w http.ResponseWriter, r *http.Request) {
		if !n.leader(w) {
			return
		}
		var b Batch
		if err := decodeJSON(r.Body, &b); err != nil {
			reply(w, 400, map[string]string{"error": "invalid metrics JSON"})
			return
		}
		now := time.Now().UnixMilli()
		if err := validateBatch(b); err != nil || b.ObservedMS > now+1000 || b.ObservedMS < now-n.cfg.MetricsTTLMS || !n.isMember(b.Node) {
			reply(w, 400, map[string]string{"error": "invalid, stale or unknown metrics source"})
			return
		}
		if err := n.apply(Command{Kind: "metrics", Batch: &b}); err != nil {
			reply(w, 503, map[string]string{"error": err.Error()})
			return
		}
		reply(w, 200, map[string]bool{"committed": true})
	})
	mux.HandleFunc("POST /v1/members", n.addMember)
	mux.HandleFunc("DELETE /v1/members/{id}", n.removeMember)
	mux.HandleFunc("POST /v1/snapshot", func(w http.ResponseWriter, r *http.Request) {
		if !n.leader(w) {
			return
		}
		if err := n.raft.Snapshot().Error(); err != nil {
			reply(w, 409, map[string]string{"error": err.Error()})
			return
		}
		reply(w, 200, map[string]bool{"snapshotted": true})
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if r.Header.Get("X-Zhttpd-Cluster") != n.cfg.ClusterID || subtle.ConstantTimeCompare([]byte(token), []byte(n.cfg.token)) != 1 {
			reply(w, 401, map[string]string{"error": "unauthorized"})
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxRequest)
		mux.ServeHTTP(w, r)
	})
}
func (n *Node) addMember(w http.ResponseWriter, r *http.Request) {
	n.membership.Lock()
	defer n.membership.Unlock()
	if !n.leader(w) {
		return
	}
	var p Peer
	if err := decodeJSON(r.Body, &p); err != nil {
		reply(w, 400, map[string]string{"error": "invalid member JSON"})
		return
	}
	if err := n.cfg.validatePeer(p); err != nil {
		reply(w, 400, map[string]string{"error": err.Error()})
		return
	}
	c, index, err := n.members()
	if err != nil {
		reply(w, 503, map[string]string{"error": err.Error()})
		return
	}
	existing := false
	for _, s := range c.Servers {
		if known, ok := n.peer(string(s.ID)); ok {
			if string(s.ID) == p.ID && known.APIAddress != p.APIAddress {
				reply(w, 409, map[string]string{"error": "member API address is immutable; remove before replacing"})
				return
			}
			if string(s.ID) != p.ID && known.APIAddress == p.APIAddress {
				reply(w, 409, map[string]string{"error": "duplicate API address"})
				return
			}
		}
		if string(s.ID) == p.ID {
			existing = true
			if string(s.Address) != p.RaftAddress {
				reply(w, 409, map[string]string{"error": "member address is immutable; remove before replacing"})
				return
			}
		} else if string(s.Address) == p.RaftAddress {
			reply(w, 409, map[string]string{"error": "duplicate Raft address"})
			return
		}
	}
	if !existing && len(c.Servers) >= maxNodes {
		reply(w, 400, map[string]string{"error": "too many members"})
		return
	}
	if err = n.apply(Command{Kind: "peer", Peer: &p}); err == nil {
		err = n.raft.AddVoter(raft.ServerID(p.ID), raft.ServerAddress(p.RaftAddress), index, 2*time.Second).Error()
	}
	if err != nil {
		reply(w, 503, map[string]string{"error": err.Error()})
		return
	}
	reply(w, 200, map[string]bool{"committed": true})
}
func (n *Node) removeMember(w http.ResponseWriter, r *http.Request) {
	n.membership.Lock()
	defer n.membership.Unlock()
	if !n.leader(w) {
		return
	}
	id := r.PathValue("id")
	if !nodeID.MatchString(id) || id == n.cfg.ID {
		reply(w, 400, map[string]string{"error": "invalid member or current leader; elect another leader before removal"})
		return
	}
	c, index, err := n.members()
	if err != nil {
		reply(w, 503, map[string]string{"error": err.Error()})
		return
	}
	exists := false
	for _, s := range c.Servers {
		exists = exists || string(s.ID) == id
	}
	if exists && len(c.Servers) <= 1 {
		reply(w, 400, map[string]string{"error": "cannot remove last voter"})
		return
	}
	if exists {
		err = n.raft.RemoveServer(raft.ServerID(id), index, 2*time.Second).Error()
	}
	if err == nil {
		err = n.apply(Command{Kind: "remove", Node: id})
	}
	if err != nil {
		reply(w, 503, map[string]string{"error": err.Error()})
		return
	}
	reply(w, 200, map[string]bool{"committed": true})
}

func (n *Node) postMetrics(b Batch) error {
	if n.raft.State() == raft.Leader {
		if !n.isMember(b.Node) {
			return errors.New("local node is not a member")
		}
		return n.apply(Command{Kind: "metrics", Batch: &b})
	}
	url := n.leaderAPI()
	if url == "" {
		return errors.New("no leader")
	}
	data, _ := json.Marshal(b)
	r, err := http.NewRequestWithContext(n.ctx, "POST", url+"/v1/metrics", strings.NewReader(string(data)))
	if err != nil {
		return err
	}
	r.Header.Set("Authorization", "Bearer "+n.cfg.token)
	r.Header.Set("X-Zhttpd-Cluster", n.cfg.ClusterID)
	r.Header.Set("Content-Type", "application/json")
	response, err := n.client.Do(r)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	if response.StatusCode != 200 {
		return fmt.Errorf("metrics commit: HTTP %d", response.StatusCode)
	}
	return nil
}
