package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/hashicorp/raft"
)

func applyTest(t *testing.T, f *FSM, index uint64, c Command) any {
	t.Helper()
	data, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	return f.Apply(&raft.Log{Index: index, Data: data})
}
func TestRevisionAndSnapshot(t *testing.T) {
	f := newFSM()
	if e := applyTest(t, f, 1, Command{Kind: "config", Node: "a", TOML: "[server]\n"}); e != nil {
		t.Fatal(e)
	}
	if e := applyTest(t, f, 2, Command{Kind: "config", Node: "a", TOML: "stale"}); e == nil {
		t.Fatal("stale write succeeded")
	}
	b := Batch{Node: "a", ObservedMS: 1000, Records: map[string]string{"a.42.load": "ZLB1 900 1 20 4096 0.5 100 8192 2\n"}}
	if e := applyTest(t, f, 3, Command{Kind: "metrics", Batch: &b}); e != nil {
		t.Fatal(e)
	}
	snap, err := f.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	sink := &memorySink{}
	if err = snap.Persist(sink); err != nil {
		t.Fatal(err)
	}
	restored := newFSM()
	if err = restored.Restore(io.NopCloser(bytes.NewReader(sink.Bytes()))); err != nil {
		t.Fatal(err)
	}
	state := restored.copy()
	if state.Index != 3 || state.Documents["a"].Revision != 1 || state.Documents["a"].TOML != "[server]\n" || state.Metrics["a"].Records["a.42.load"] != b.Records["a.42.load"] {
		t.Fatalf("bad restored state: %+v", state)
	}
	b.ObservedMS = 999
	b.Records = map[string]string{}
	if e := applyTest(t, restored, 4, Command{Kind: "metrics", Batch: &b}); e != nil {
		t.Fatal(e)
	}
	if len(restored.copy().Metrics["a"].Records) != 1 {
		t.Fatal("out-of-order batch replaced newer metrics")
	}
}

type memorySink struct{ bytes.Buffer }

func (*memorySink) ID() string    { return "test" }
func (*memorySink) Cancel() error { return nil }
func (*memorySink) Close() error  { return nil }
func TestMetricsValidation(t *testing.T) {
	for _, record := range []string{"ZLB1 900 1 1 4096 NaN 100 8192 2", "ZLB1 900 0 1 4096 0 100 8192 2", "ZLB1 900 1 1 4096 0 0 8192 2", "ZLB1 900 1 -1 4096 0 100 8192 2", "ZLB1 900 1 1 4096 0 100 8192 2 extra"} {
		if _, err := metricStamp("a.1.load", record, "a"); err == nil {
			t.Fatalf("accepted invalid record %q", record)
		}
	}
	good := "ZLB1 900 1 1 4096 0 100 8192 2"
	for _, name := range []string{"../a.1.load", "b.1.load", "a.0.load", "a.1.load.tmp"} {
		if _, err := metricStamp(name, good, "a"); err == nil {
			t.Fatalf("accepted invalid name %s", name)
		}
	}
	if err := validateBatch(Batch{Node: "a", ObservedMS: 899, Records: map[string]string{"a.1.load": good}}); err == nil {
		t.Fatal("future record accepted")
	}
}
func TestExportOnlyCommittedStateAndNoRollback(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{ID: "a", ClusterID: "test", MetricsView: dir, ConfigOutput: filepath.Join(dir, "server.toml")}
	n := &Node{cfg: cfg}
	s := newFSM().copy()
	s.Index = 8
	s.Documents["a"] = Document{Revision: 1, TOML: "committed"}
	s.Metrics["a"] = Batch{Node: "a", Records: map[string]string{"a.1.load": "original timestamp"}}
	if err := n.exportState(s, 0); err != nil {
		t.Fatal(err)
	}
	s.Index = 7
	s.Documents["a"] = Document{Revision: 0, TOML: "older snapshot"}
	if err := n.exportState(s, 8); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(cfg.ConfigOutput)
	if err != nil || string(data) != "committed" {
		t.Fatalf("rolled back export: %s %v", data, err)
	}
	data, err = os.ReadFile(filepath.Join(dir, "a.1.load"))
	if err != nil || string(data) != "original timestamp" {
		t.Fatal("metric timestamp changed")
	}
}
func TestProductionRequiresTLSAndDistinctMetricsDirectories(t *testing.T) {
	c := Config{ID: "a", ClusterID: "test", RaftAddress: "127.0.0.1:9001", APIAddress: "127.0.0.1:9002", DataDir: "data", MetricsInbox: "in", MetricsView: "out", TokenFile: "token", IntervalMS: 1000, MetricsTTLMS: 5000, Peers: []Peer{{"a", "127.0.0.1:9001", "127.0.0.1:9002"}}}
	if err := c.validate(); err == nil {
		t.Fatal("production allowed without TLS")
	}
	c.InsecureLoopback = true
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	c.RaftAddress = "0.0.0.0:9001"
	if err := c.validate(); err == nil {
		t.Fatal("plaintext wildcard bind accepted")
	}
	c.RaftAddress = "127.0.0.1:9001"
	c.MetricsView = c.MetricsInbox
	if err := c.validate(); err == nil {
		t.Fatal("uncommitted metric directory is readable as committed")
	}
}

func TestExportCursorPrecedesPartialFileUpdates(t *testing.T) {
	dir := t.TempDir()
	n := &Node{cfg: Config{ID: "a", ClusterID: "test", MetricsView: dir, ConfigOutput: filepath.Join(dir, "missing", "server.toml")}}
	s := newFSM().copy()
	s.Index = 12
	s.Documents["a"] = Document{Revision: 2, TOML: "new committed configuration"}
	if err := n.exportState(s, 10); err == nil {
		t.Fatal("expected config export failure")
	}
	data, err := os.ReadFile(filepath.Join(dir, ".applied"))
	if err != nil {
		t.Fatal(err)
	}
	var cursor exportCursor
	if err = json.Unmarshal(data, &cursor); err != nil {
		t.Fatal(err)
	}
	if cursor.Index != 12 {
		t.Fatal("crash could replay an older snapshot over partially updated files")
	}
}
