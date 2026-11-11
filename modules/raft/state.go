package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"github.com/hashicorp/raft"
)

type Document struct {
	Revision uint64 `json:"revision"`
	TOML     string `json:"toml"`
}
type Batch struct {
	Node       string            `json:"node"`
	ObservedMS int64             `json:"observed_ms"`
	Records    map[string]string `json:"records"`
}
type State struct {
	Index     uint64              `json:"index"`
	Documents map[string]Document `json:"documents"`
	Metrics   map[string]Batch    `json:"metrics"`
	Peers     map[string]Peer     `json:"peers"` // Contact registry; Raft itself owns voting membership.
}
type Command struct {
	Kind             string `json:"kind"`
	Node             string `json:"node,omitempty"`
	ExpectedRevision uint64 `json:"expected_revision,omitempty"`
	TOML             string `json:"toml,omitempty"`
	Batch            *Batch `json:"batch,omitempty"`
	Peer             *Peer  `json:"peer,omitempty"`
}
type FSM struct {
	mu    sync.RWMutex
	state State
}

func newFSM() *FSM {
	return &FSM{state: State{Documents: map[string]Document{}, Metrics: map[string]Batch{}, Peers: map[string]Peer{}}}
}
func (f *FSM) copy() State {
	f.mu.RLock()
	defer f.mu.RUnlock()
	s := State{Index: f.state.Index, Documents: map[string]Document{}, Metrics: map[string]Batch{}, Peers: map[string]Peer{}}
	for k, v := range f.state.Documents {
		s.Documents[k] = v
	}
	for k, v := range f.state.Metrics { // Batch maps are immutable after Apply.
		s.Metrics[k] = v
	}
	for k, v := range f.state.Peers {
		s.Peers[k] = v
	}
	return s
}
func (f *FSM) Apply(log *raft.Log) any {
	var command Command
	if err := decodeJSON(strings.NewReader(string(log.Data)), &command); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.state.Index = log.Index
	switch command.Kind {
	case "config":
		if !nodeID.MatchString(command.Node) || len(command.TOML) == 0 || len(command.TOML) > maxDocument {
			return errors.New("invalid config document")
		}
		old := f.state.Documents[command.Node]
		if old.Revision != command.ExpectedRevision {
			return errors.New("configuration revision conflict")
		}
		if len(f.state.Documents) >= maxNodes && old.Revision == 0 {
			return errors.New("too many documents")
		}
		f.state.Documents[command.Node] = Document{old.Revision + 1, command.TOML}
	case "metrics":
		if command.Batch == nil {
			return errors.New("missing metrics batch")
		}
		b := *command.Batch
		if err := validateBatch(b); err != nil {
			return err
		}
		if old, ok := f.state.Metrics[b.Node]; ok && b.ObservedMS <= old.ObservedMS {
			return nil
		}
		if _, ok := f.state.Metrics[b.Node]; !ok && len(f.state.Metrics) >= maxNodes {
			return errors.New("too many metric sources")
		}
		f.state.Metrics[b.Node] = b
	case "peer":
		if command.Peer == nil || !nodeID.MatchString(command.Peer.ID) {
			return errors.New("invalid peer")
		}
		if _, ok := f.state.Peers[command.Peer.ID]; !ok && len(f.state.Peers) >= maxNodes {
			return errors.New("too many contacts")
		}
		f.state.Peers[command.Peer.ID] = *command.Peer
	case "remove":
		delete(f.state.Peers, command.Node)
		delete(f.state.Metrics, command.Node)
		delete(f.state.Documents, command.Node)
	default:
		return errors.New("unknown command")
	}
	return nil
}

type stateSnapshot struct{ state State }

func (f *FSM) Snapshot() (raft.FSMSnapshot, error) { return &stateSnapshot{f.copy()}, nil }
func (s *stateSnapshot) Persist(sink raft.SnapshotSink) error {
	if err := json.NewEncoder(sink).Encode(s.state); err != nil {
		_ = sink.Cancel()
		return err
	}
	return sink.Close()
}
func (*stateSnapshot) Release() {}
func (f *FSM) Restore(r io.ReadCloser) error {
	defer r.Close()
	var s State
	if err := decodeJSON(io.LimitReader(r, 32*1024*1024), &s); err != nil {
		return err
	}
	if s.Documents == nil || s.Metrics == nil || s.Peers == nil || len(s.Documents) > maxNodes || len(s.Metrics) > maxNodes || len(s.Peers) > maxNodes {
		return errors.New("invalid state snapshot")
	}
	for _, b := range s.Metrics {
		if err := validateBatch(b); err != nil {
			return err
		}
	}
	f.mu.Lock()
	f.state = s
	f.mu.Unlock()
	return nil
}

var workerFile = regexp.MustCompile(`^([A-Za-z0-9_-]{1,63})\.([1-9][0-9]*)\.load$`)

func metricStamp(name, record, node string) (int64, error) {
	m := workerFile.FindStringSubmatch(name)
	fields := strings.Fields(record)
	if m == nil || m[1] != node || len(record) > 511 || len(fields) != 9 || fields[0] != "ZLB1" {
		return 0, errors.New("invalid metric record")
	}
	values := map[int]uint64{}
	for _, i := range []int{1, 2, 3, 4, 6, 7, 8} {
		v, err := strconv.ParseUint(fields[i], 10, 64)
		if err != nil {
			return 0, err
		}
		values[i] = v
	}
	cpu, err := strconv.ParseFloat(fields[5], 64)
	if err != nil || math.IsNaN(cpu) || math.IsInf(cpu, 0) || cpu < 0 || cpu > 1024 || values[1] > math.MaxInt64 || values[2] == 0 || values[2] > 256 || values[3] > math.MaxUint32 || values[4] == 0 || values[4] > (1<<50) || values[6] == 0 || values[7] == 0 || values[8] == 0 || values[8] > math.MaxUint32 {
		return 0, errors.New("invalid metric values")
	}
	return int64(values[1]), nil
}
func validateBatch(b Batch) error {
	if !nodeID.MatchString(b.Node) || b.ObservedMS <= 0 || len(b.Records) > 256 {
		return errors.New("invalid metrics batch")
	}
	for name, record := range b.Records {
		stamp, err := metricStamp(name, record, b.Node)
		if err != nil {
			return err
		}
		if stamp > b.ObservedMS {
			return fmt.Errorf("record newer than batch")
		}
	}
	return nil
}
