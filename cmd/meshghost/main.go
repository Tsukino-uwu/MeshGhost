// Command meshghost is the desktop core process: it connects to a relay
// and listens for a local adapter over the bridge. See internal/core for
// the implementation and agent_docs/contract.md for the protocol.
package main

import (
	"encoding/json"
	"flag"
	"log"
	"net"
	"os"
	"time"

	"meshghost/internal/core"
)

// fileConfig is the shape of an optional JSON config file (see -config) --
// a friendlier alternative to CLI flags for a non-developer player, per
// packaging/README.md. Pointer fields distinguish "absent from the file"
// from "present with a zero value", so a config file only ever overrides
// what it actually mentions.
type fileConfig struct {
	Relay  *string `json:"relay"`
	Bridge *string `json:"bridge"`
	Game   *string `json:"game"`
	Room   *string `json:"room"`
	Name   *string `json:"name"`
	Interp *string `json:"interp"`
}

// applyFileConfig loads path (if it exists -- silently doing nothing if not,
// so existing flag-only usage is unaffected) and overwrites any flag that
// was NOT explicitly passed on the command line with the file's value.
// CLI flags always win over the file, matching normal config-layering
// convention (most-specific/most-explicit source wins).
func applyFileConfig(path string, explicit map[string]bool, relayAddr, bridgeAddr, gameID, room, name *string, interp *time.Duration) {
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("meshghost: warning: could not read config file %s: %v", path, err)
		}
		return
	}
	var fc fileConfig
	if err := json.Unmarshal(data, &fc); err != nil {
		log.Printf("meshghost: warning: could not parse config file %s: %v", path, err)
		return
	}
	if fc.Relay != nil && !explicit["relay"] {
		*relayAddr = *fc.Relay
	}
	if fc.Bridge != nil && !explicit["bridge"] {
		*bridgeAddr = *fc.Bridge
	}
	if fc.Game != nil && !explicit["game"] {
		*gameID = *fc.Game
	}
	if fc.Room != nil && !explicit["room"] {
		*room = *fc.Room
	}
	if fc.Name != nil && !explicit["name"] {
		*name = *fc.Name
	}
	if fc.Interp != nil && !explicit["interp"] {
		d, err := time.ParseDuration(*fc.Interp)
		if err != nil {
			log.Printf("meshghost: warning: config file %s has an invalid interp value %q: %v", path, *fc.Interp, err)
		} else {
			*interp = d
		}
	}
}

func main() {
	relayAddr := flag.String("relay", "127.0.0.1:7777", "relay address to connect to")
	bridgeAddr := flag.String("bridge", "127.0.0.1:7778", "address to listen on for the adapter bridge")
	gameID := flag.String("game", "", "game_id to advertise to the relay (required)")
	room := flag.String("room", "default", "room name to join")
	name := flag.String("name", "player", "display name to advertise to the relay")
	interp := flag.Duration("interp", core.DefaultInterpolationDelay,
		"interpolation delay for remote ghosts (e.g. 200ms) — how far behind the most recent "+
			"samples remotes are rendered, to smooth over network jitter")
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file (relay/bridge/game/room/name/interp) -- a friendlier "+
			"alternative to flags for non-developer use; silently ignored if it doesn't exist; any "+
			"flag explicitly passed on the command line overrides the same field from this file")
	flag.Parse()

	explicit := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { explicit[f.Name] = true })
	applyFileConfig(*configPath, explicit, relayAddr, bridgeAddr, gameID, room, name, interp)

	if *gameID == "" {
		log.Fatal("meshghost: -game is required (e.g. -game=emerald), or set \"game\" in the config file")
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
