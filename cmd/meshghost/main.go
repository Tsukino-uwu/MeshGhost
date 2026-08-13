// Command meshghost is the desktop core process: it connects to a relay
// and listens for a local adapter over the bridge. See internal/core for
// the implementation and agent_docs/contract.md for the protocol.
package main

import (
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"time"

	"meshghost/internal/core"
)

// openLogFile creates (truncating any previous run's contents) meshghost.log next to
// wherever the process's working directory is -- the same cwd config.json is read from,
// so it lands beside the exe in the normal double-click-from-the-package-folder case. This
// exists so a crash is still readable after the console window itself is gone: double-clicking
// an .exe opens a console that closes the instant the process exits, taking any error message
// with it -- see packaging/README.md's "No launcher .bat files" section. Falls back to
// stderr-only, with a warning, if the file can't be created (e.g. read-only folder).
func openLogFile(name string) io.Writer {
	f, err := os.Create(name)
	if err != nil {
		log.Printf("meshghost: warning: could not create log file %s: %v (log output will only appear in this window)", name, err)
		return os.Stderr
	}
	return io.MultiWriter(os.Stderr, f)
}

// fileConfig is the shape of the "client" section of an optional JSON config
// file (see -config) -- a friendlier alternative to CLI flags for a
// non-developer player, per packaging/README.md. Pointer fields distinguish
// "absent from the file" from "present with a zero value", so a config file
// only ever overrides what it actually mentions. The JSON field names are
// deliberately end-user-facing and differ from the flag names below:
// "connect_to" (not "relay") is the address you connect out to, and
// "local_game_bridge" (not "bridge") makes clear that socket never leaves
// the machine -- see packaging/release/config.json and its README.txt.
type fileConfig struct {
	Relay  *string `json:"connect_to"`
	Bridge *string `json:"local_game_bridge"`
	Game   *string `json:"game"`
	Room   *string `json:"room"`
	Name   *string `json:"name"`
	Interp *string `json:"interp"`
}

// rootConfig is the top-level shape of the config file: a "client" section
// read by this binary, sitting alongside a "server" section (meaningless
// here) read by cmd/meshghost-relay from the same file in the shipped
// package -- see packaging/release/config.json.
type rootConfig struct {
	Client *fileConfig `json:"client"`
}

// applyFileConfig loads path (if it exists -- silently doing nothing if not,
// so existing flag-only usage is unaffected) and overwrites any flag that
// was NOT explicitly passed on the command line with the file's "client"
// section. CLI flags always win over the file, matching normal
// config-layering convention (most-specific/most-explicit source wins).
func applyFileConfig(path string, explicit map[string]bool, relayAddr, bridgeAddr, gameID, room, name *string, interp *time.Duration) {
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("meshghost: warning: could not read config file %s: %v", path, err)
		}
		return
	}
	var rc rootConfig
	if err := json.Unmarshal(data, &rc); err != nil {
		log.Printf("meshghost: warning: could not parse config file %s: %v", path, err)
		return
	}
	if rc.Client == nil {
		log.Printf("meshghost: warning: config file %s has no \"client\" section", path)
		return
	}
	fc := *rc.Client
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
	gameID := flag.String("game", "", "game_id to advertise to the relay -- optional now that a "+
		"real adapter's own Hello declares it (internal/bridge.Hello); set this to connect at "+
		"startup instead of waiting for one, e.g. for dev/testing scripts with no adapter attached")
	room := flag.String("room", "default", "room name to join")
	name := flag.String("name", "player", "display name to advertise to the relay")
	interp := flag.Duration("interp", core.DefaultInterpolationDelay,
		"interpolation delay for remote ghosts (e.g. 200ms) — how far behind the most recent "+
			"samples remotes are rendered, to smooth over network jitter")
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file with a \"client\" section "+
			"(connect_to/local_game_bridge/game/room/name/interp) -- a friendlier alternative to "+
			"flags for non-developer use; silently ignored if it doesn't exist; any flag explicitly "+
			"passed on the command line overrides the same field from this file")
	flag.Parse()

	log.SetOutput(openLogFile("meshghost.log"))

	explicit := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { explicit[f.Name] = true })
	applyFileConfig(*configPath, explicit, relayAddr, bridgeAddr, gameID, room, name, interp)

	c := core.New()
	c.InterpolationDelay = *interp
	c.RelayAddr = *relayAddr
	c.Room = *room
	c.DisplayName = *name
	c.DialTimeout = 5 * time.Second

	if *gameID != "" {
		if err := c.ConnectRelay(*relayAddr, *gameID, *room, *name, c.DialTimeout); err != nil {
			log.Fatalf("meshghost: %v", err)
		}
		log.Printf("meshghost: connected to relay %s as %s in room %q", *relayAddr, c.PlayerID(), *room)
	} else {
		log.Printf("meshghost: no game set -- waiting for a game to connect and say hello...")
		c.OnRelayConnected = func(gameID string) {
			log.Printf("meshghost: connected to relay %s as %s in room %q (game %q)", *relayAddr, c.PlayerID(), *room, gameID)
		}
	}

	ln, err := net.Listen("tcp", *bridgeAddr)
	if err != nil {
		log.Fatalf("meshghost: listen on bridge address %s: %v", *bridgeAddr, err)
	}
	log.Printf("meshghost: bridge listening on %s", ln.Addr())

	if err := c.ServeBridge(ln); err != nil {
		log.Fatalf("meshghost: serve bridge: %v", err)
	}
}
