package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Rename is atomic for readers; Sync on both file and parent makes exported
// configuration and the applied cursor survive a crash in their published order.
func atomicWrite(path string, data []byte) error {
	if old, err := os.ReadFile(path); err == nil && string(old) == string(data) {
		return nil
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".zhttpd-raft-*")
	if err != nil {
		return err
	}
	temp := file.Name()
	defer os.Remove(temp)
	if _, err = file.Write(data); err != nil {
		_ = file.Close()
		return err
	}
	if err = file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	if err = os.Rename(temp, path); err != nil {
		return err
	}
	parent, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer parent.Close()
	return parent.Sync()
}
func readRegular(path string, limit int64) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > limit {
		return nil, errors.New("not a bounded regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if len(data) > int(limit) {
		return nil, errors.New("file too large")
	}
	return data, err
}
func (n *Node) localBatch() (Batch, error) {
	b := Batch{Node: n.cfg.ID, ObservedMS: time.Now().UnixMilli(), Records: map[string]string{}}
	dir, err := os.Open(n.cfg.MetricsInbox)
	if err != nil {
		return b, err
	}
	defer dir.Close()
	entries, err := dir.ReadDir(4097)
	if err != nil && err != io.EOF {
		return b, err
	}
	if len(entries) > 4096 {
		return b, errors.New("metrics inbox has too many entries")
	}
	for _, entry := range entries {
		name := entry.Name()
		m := workerFile.FindStringSubmatch(name)
		if m == nil || m[1] != n.cfg.ID {
			continue
		}
		data, err := readRegular(filepath.Join(n.cfg.MetricsInbox, name), 511)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return b, err
		}
		stamp, err := metricStamp(name, string(data), n.cfg.ID)
		if err != nil {
			return b, err
		}
		if stamp > b.ObservedMS || b.ObservedMS-stamp >= n.cfg.MetricsTTLMS {
			continue
		}
		b.Records[name] = string(data)
	}
	return b, validateBatch(b)
}
func (n *Node) publishLoop() {
	ticker := time.NewTicker(time.Duration(n.cfg.IntervalMS) * time.Millisecond)
	defer ticker.Stop()
	var last string
	for {
		select {
		case <-n.ctx.Done():
			return
		case <-ticker.C:
		}
		b, err := n.localBatch()
		if err != nil {
			log.Printf("metrics input: %v", err)
			continue
		}
		data, _ := json.Marshal(b.Records)
		if string(data) == last {
			continue
		}
		if err = n.postMetrics(b); err == nil {
			last = string(data)
		}
	}
}

type exportCursor struct {
	Cluster string `json:"cluster"`
	Node    string `json:"node"`
	Index   uint64 `json:"index"`
}

func (n *Node) exportState(s State, previous uint64) error {
	if s.Index == 0 || s.Index < previous {
		return nil
	} // Never roll back a newer committed export after snapshot restore.
	// Persist the committed index BEFORE touching its exported files. A crash
	// between file renames must never let an older restored snapshot overwrite
	// a partially exported newer configuration on the next start.
	cursor, _ := json.Marshal(exportCursor{n.cfg.ClusterID, n.cfg.ID, s.Index})
	if err := atomicWrite(filepath.Join(n.cfg.MetricsView, ".applied"), cursor); err != nil {
		return err
	}
	desired := map[string]string{}
	for _, b := range s.Metrics {
		for name, value := range b.Records {
			desired[name] = value
		}
	}
	for name, value := range desired {
		if err := atomicWrite(filepath.Join(n.cfg.MetricsView, name), []byte(value)); err != nil {
			return err
		}
	}
	entries, err := os.ReadDir(n.cfg.MetricsView)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if workerFile.MatchString(entry.Name()) {
			if _, ok := desired[entry.Name()]; !ok {
				if err = os.Remove(filepath.Join(n.cfg.MetricsView, entry.Name())); err != nil && !os.IsNotExist(err) {
					return err
				}
			}
		}
	}
	if doc, ok := s.Documents[n.cfg.ID]; ok && n.cfg.ConfigOutput != "" {
		if err = atomicWrite(n.cfg.ConfigOutput, []byte(doc.TOML)); err != nil {
			return fmt.Errorf("config export: %w", err)
		}
	}
	return nil
}
func (n *Node) exportLoop() {
	var previous uint64
	cursorPath := filepath.Join(n.cfg.MetricsView, ".applied")
	data, err := readRegular(cursorPath, 1024)
	if err == nil {
		var cursor exportCursor
		if e := decodeJSON(strings.NewReader(string(data)), &cursor); e != nil || cursor.Cluster != n.cfg.ClusterID || cursor.Node != n.cfg.ID {
			n.setExportError(errors.New("invalid export cursor or wrong cluster/node"))
			return
		}
		previous = cursor.Index
	} else if !os.IsNotExist(err) {
		n.setExportError(err)
		return
	}
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-n.ctx.Done():
			return
		case <-ticker.C:
		}
		s := n.fsm.copy()
		if s.Index == 0 || s.Index < previous {
			continue
		}
		err = n.exportState(s, previous)
		n.setExportError(err)
		if err == nil {
			previous = s.Index
		}
	}
}
func (n *Node) setExportError(err error) {
	value := ""
	if err != nil {
		value = err.Error()
	}
	n.exportMu.Lock()
	changed := n.exportError != value
	n.exportError = value
	n.exportMu.Unlock()
	if changed && err != nil {
		log.Printf("Raft export: %v", err)
	}
}
