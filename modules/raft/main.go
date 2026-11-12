// zhttpd-raft is an optional per-instance consensus companion. HTTP workers
// publish locally; only committed metrics and configuration reach their view.
package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	path := flag.String("config", "raft.json", "local agent configuration")
	flag.Parse()
	c, err := loadConfig(*path)
	if err != nil {
		log.Fatal(err)
	}
	n, err := startNode(c)
	if err != nil {
		log.Fatal(err)
	}
	defer n.close()
	log.Printf("zhttpd-raft node=%s cluster=%s raft=%s api=%s", c.ID, c.ClusterID, c.RaftAddress, c.APIAddress)
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)
	select {
	case <-signals:
	case <-n.ctx.Done():
	}
}
