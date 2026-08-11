// Command meshghost is the desktop core process: it connects to a relay
// and listens for a local adapter over the bridge. See internal/core for
// the implementation and agent_docs/contract.md for the protocol.
package main

import (
	"flag"
	"log"
	"net"
	"time"

	"meshghost/internal/core"
)

func main() {
	relayAddr := flag.String("relay", "127.0.0.1:7777", "relay address to connect to")
	bridgeAddr := flag.String("bridge", "127.0.0.1:7778", "address to listen on for the adapter bridge")
	gameID := flag.String("game", "", "game_id to advertise to the relay (required)")
	room := flag.String("room", "default", "room name to join")
	name := flag.String("name", "player", "display name to advertise to the relay")
	interp := flag.Duration("interp", core.DefaultInterpolationDelay,
		"interpolation delay for remote ghosts (e.g. 200ms) — how far behind the most recent "+
			"samples remotes are rendered, to smooth over network jitter")
	flag.Parse()

	if *gameID == "" {
		log.Fatal("meshghost: -game is required (e.g. -game=emerald)")
	}

	c := core.New()
	c.InterpolationDelay = *interp
	if err := c.ConnectRelay(*relayAddr, *gameID, *room, *name, 5*time.Second); err != nil {
		log.Fatalf("meshghost: %v", err)
	}
	log.Printf("meshghost: connected to relay %s as %s in room %q", *relayAddr, c.PlayerID(), *room)

	ln, err := net.Listen("tcp", *bridgeAddr)
	if err != nil {
		log.Fatalf("meshghost: listen on bridge address %s: %v", *bridgeAddr, err)
	}
	log.Printf("meshghost: bridge listening on %s", ln.Addr())

	if err := c.ServeBridge(ln); err != nil {
		log.Fatalf("meshghost: serve bridge: %v", err)
	}
}
