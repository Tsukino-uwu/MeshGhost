// Command meshghost-relay is the standalone relay process: it accepts
// relay-protocol connections and forwards state between clients in a room.
// See internal/relay for the implementation and agent_docs/contract.md for
// the wire protocol.
package main

import (
	"flag"
	"log"
	"net"

	"meshghost/internal/relay"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:7777", "address to listen on")
	loopback := flag.Bool("loopback", false, "dev-only Phase 3 flag: echo each client's own "+
		"state back to it under a synthetic <id>-ghost player_id, so a single client exercises "+
		"a real core->relay->core round trip. Never enable this outside dev/testing.")
	flag.Parse()

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("meshghost-relay: listen on %s: %v", *addr, err)
	}
	log.Printf("meshghost-relay: listening on %s", ln.Addr())

	server := relay.NewServer()
	server.Loopback = *loopback
	if *loopback {
		log.Printf("meshghost-relay: -loopback enabled — dev-only, do not use with real peers")
	}
	if err := server.Serve(ln); err != nil {
		log.Fatalf("meshghost-relay: serve: %v", err)
	}
}
