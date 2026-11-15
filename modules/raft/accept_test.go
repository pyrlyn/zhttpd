package main

import (
	"net"
	"testing"
	"time"

	"github.com/hashicorp/raft"
)

// The transport accepts serially, so peers that connect and stay silent must
// not delay a legitimate one, and closing the listener must end Accept.
func TestSilentConnectionsDoNotStallAccept(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	s := &streamLayer{Listener: l, greeting: "ZHTTPD-RAFT/1 c\n"}
	type result struct {
		conn net.Conn
		err  error
	}
	accepted := make(chan result, 2)
	accept := func() {
		conn, err := s.Accept()
		accepted <- result{conn, err}
	}
	go accept()
	for range 3 {
		idle, err := net.Dial("tcp", l.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer idle.Close()
	}
	peer, err := s.Dial(raft.ServerAddress(l.Addr().String()), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	select {
	case r := <-accepted:
		if r.err != nil {
			t.Fatal(r.err)
		}
		_ = r.conn.Close()
	case <-time.After(time.Second):
		t.Fatal("silent connections delayed the next peer")
	}
	go accept()
	_ = l.Close()
	select {
	case r := <-accepted:
		if r.err == nil {
			t.Fatal("Accept succeeded on a closed listener")
		}
	case <-time.After(time.Second):
		t.Fatal("Accept did not return after the listener closed")
	}
}
