// Command meshghost-relay is the standalone relay process: it accepts
// relay-protocol connections and forwards state between clients in a room.
// See internal/relay for the implementation and agent_docs/contract.md for
// the wire protocol.
package main

import (
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"os"

	"meshghost/internal/relay"
)

// openLogFile creates (truncating any previous run's contents) meshghost-server.log next
// to wherever the process's working directory is -- the same cwd config.json is read from,
// so it lands beside the exe in the normal double-click-from-the-package-folder case. This
// exists so a crash is still readable after the console window itself is gone: double-clicking
// an .exe opens a console that closes the instant the process exits, taking any error message
// with it -- see packaging/README.md's "No launcher .bat files" section. Falls back to
// stderr-only, with a warning, if the file can't be created (e.g. read-only folder).
func openLogFile(name string) io.Writer {
	f, err := os.Create(name)
	if err != nil {
		log.Printf("meshghost-relay: warning: could not create log file %s: %v (log output will only appear in this window)", name, err)
		return os.Stderr
	}
	return io.MultiWriter(os.Stderr, f)
}

// fileConfig is the shape of the "server" section of an optional JSON config
// file (see -config), mirroring cmd/meshghost's own -- a friendlier
// alternative to flags for whoever's hosting, per packaging/README.md. The
// JSON field name is deliberately end-user-facing: "listen_on" (not "addr")
// reads as an opposite of the client's "connect_to" -- see
// packaging/release/config.json and its README.txt.
type fileConfig struct {
	Addr       *string `json:"listen_on"`
	RoomCode   *string `json:"room_code"`
	MaxClients *int    `json:"max_clients"`
}

// rootConfig is the top-level shape of the config file: a "server" section
// read by this binary, sitting alongside a "client" section (meaningless
// here) read by cmd/meshghost from the same file in the shipped package.
type rootConfig struct {
	Server *fileConfig `json:"server"`
}

func applyFileConfig(path string, explicit map[string]bool, addr, roomCode *string, maxClients *int) {
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("meshghost-relay: warning: could not read config file %s: %v", path, err)
		}
		return
	}
	var rc rootConfig
	if err := json.Unmarshal(data, &rc); err != nil {
		log.Printf("meshghost-relay: warning: could not parse config file %s: %v", path, err)
		return
	}
	if rc.Server == nil {
		log.Printf("meshghost-relay: warning: config file %s has no \"server\" section", path)
		return
	}
	if rc.Server.Addr != nil && !explicit["addr"] {
		*addr = *rc.Server.Addr
	}
	if rc.Server.RoomCode != nil && !explicit["room-code"] {
		*roomCode = *rc.Server.RoomCode
	}
	if rc.Server.MaxClients != nil && !explicit["max-clients"] {
		*maxClients = *rc.Server.MaxClients
	}
}

func main() {
	addr := flag.String("addr", "127.0.0.1:7777", "address to listen on")
	loopback := flag.Bool("loopback", false, "dev-only Phase 3 flag: echo each client's own "+
		"state back to it under a synthetic <id>-ghost player_id, so a single client exercises "+
		"a real core->relay->core round trip. Never enable this outside dev/testing.")
	roomCode := flag.String("room-code", "", "shared secret clients must send to join a room -- "+
		"leave empty to run open (anyone with the address can join, the pre-existing default); "+
		"see agent_docs/architecture.md's room-code ADR for what this does and doesn't defend "+
		"against (no TLS: the code crosses the wire in plaintext)")
	maxClients := flag.Int("max-clients", relay.DefaultMaxClients,
		"max clients this relay accepts in total, across every room it's hosting combined -- "+
			"not per room. Every room member's state is forwarded to every other member of that "+
			"same room, so traffic within a room scales roughly with the square of its size, not "+
			"linearly -- raising this a lot and letting it pile into one room trades your own "+
			"relay's bandwidth/CPU for more seats, not a free lunch")
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file with a \"server\" section "+
			"({\"listen_on\": \"...\", \"room_code\": \"...\", \"max_clients\": ...}) -- "+
			"a friendlier alternative to flags for non-developer use; silently ignored if it "+
			"doesn't exist; a flag passed explicitly on the command line overrides the same "+
			"field from this file")
	flag.Parse()

	log.SetOutput(openLogFile("meshghost-server.log"))

	explicit := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { explicit[f.Name] = true })
	applyFileConfig(*configPath, explicit, addr, roomCode, maxClients)

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("meshghost-relay: listen on %s: %v", *addr, err)
	}
	log.Printf("meshghost-relay: listening on %s", ln.Addr())

	server := relay.NewServer()
	server.Loopback = *loopback
	server.RoomCode = *roomCode
	server.MaxClients = *maxClients
	log.Printf("meshghost-relay: max clients (total, across all rooms): %d", *maxClients)
	if *loopback {
		log.Printf("meshghost-relay: -loopback enabled — dev-only, do not use with real peers")
	}
	if *roomCode == "" {
		log.Printf("meshghost-relay: WARNING: no room code configured -- anyone who has this " +
			"relay's address can join any room. Set -room-code (or \"room_code\" in config.json) " +
			"before exposing this relay beyond a friend you directly hand the address to.")
	} else {
		log.Printf("meshghost-relay: room-code auth enabled")
	}
	if err := server.Serve(ln); err != nil {
		log.Fatalf("meshghost-relay: serve: %v", err)
	}
}
