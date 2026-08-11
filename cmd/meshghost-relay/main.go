// Command meshghost-relay is the standalone relay process: it accepts
// relay-protocol connections and forwards state between clients in a room.
// See internal/relay for the implementation and agent_docs/contract.md for
// the wire protocol.
package main

import (
	"encoding/json"
	"flag"
	"log"
	"net"
	"os"

	"meshghost/internal/relay"
)

// fileConfig is the shape of an optional JSON config file (see -config),
// mirroring cmd/meshghost's own -- a friendlier alternative to flags for
// whoever's hosting, per packaging/README.md.
type fileConfig struct {
	Addr *string `json:"addr"`
}

func applyFileConfig(path string, explicit map[string]bool, addr *string) {
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("meshghost-relay: warning: could not read config file %s: %v", path, err)
		}
		return
	}
	var fc fileConfig
	if err := json.Unmarshal(data, &fc); err != nil {
		log.Printf("meshghost-relay: warning: could not parse config file %s: %v", path, err)
		return
	}
	if fc.Addr != nil && !explicit["addr"] {
		*addr = *fc.Addr
	}
}

func main() {
	addr := flag.String("addr", "127.0.0.1:7777", "address to listen on")
	loopback := flag.Bool("loopback", false, "dev-only Phase 3 flag: echo each client's own "+
		"state back to it under a synthetic <id>-ghost player_id, so a single client exercises "+
		"a real core->relay->core round trip. Never enable this outside dev/testing.")
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file ({\"addr\": \"...\"}) -- a friendlier alternative "+
			"to flags for non-developer use; silently ignored if it doesn't exist; -addr passed "+
			"explicitly on the command line overrides the file")
	flag.Parse()

	explicit := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { explicit[f.Name] = true })
	applyFileConfig(*configPath, explicit, addr)

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
