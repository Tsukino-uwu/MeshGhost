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

	"meshghost/internal/protocol"
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
	// SendHz is the room-wide state send rate this relay advertises. Absent
	// or 0 means protocol.DefaultSendHz. See the ADR in
	// agent_docs/architecture.md for the send/receive rate-control feature.
	SendHz *int `json:"send_hz"`
}

// rootConfig is the top-level shape of the config file: a "server" section
// read by this binary, sitting alongside a "client" section (meaningless
// here) read by cmd/meshghost from the same file in the shipped package.
type rootConfig struct {
	Server *fileConfig `json:"server"`
}

// configTargets are the flag-backed variables applyFileConfig may overwrite
// — mirrors cmd/meshghost's own configTargets struct. Converted from a flat
// positional-pointer list to this struct once send_hz became the 4th knob,
// the same trigger cmd/meshghost's own struct cites (a struct keeps each
// field's name at the call site instead of relying on positional order).
type configTargets struct {
	addr       *string
	roomCode   *string
	maxClients *int
	sendHz     *int
}

func applyFileConfig(path string, explicit map[string]bool, t configTargets) {
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
		*t.addr = *rc.Server.Addr
	}
	if rc.Server.RoomCode != nil && !explicit["room-code"] {
		*t.roomCode = *rc.Server.RoomCode
	}
	if rc.Server.MaxClients != nil && !explicit["max-clients"] {
		*t.maxClients = *rc.Server.MaxClients
	}
	if rc.Server.SendHz != nil && !explicit["send-hz"] {
		*t.sendHz = *rc.Server.SendHz
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
	sendHz := flag.Int("send-hz", protocol.DefaultSendHz,
		"how many times per second every player sends their position to this room (a \"20 tick\" "+
			"relay = 20Hz = an update every 50ms; higher/lower are the same idea in different "+
			"units). A client adopts this rate unless it has its own slower local preference, "+
			"which always wins -- this can only ever make players send MORE often, never override "+
			"someone who deliberately wants to send less. Valid range 10-100; leave this alone "+
			"unless you know you need it -- raising it multiplies every player's bandwidth in both "+
			"directions for a visual gain that's small and diminishing (see README.txt for the "+
			"real numbers), and YOUR machine (the host) carries the worst of it, since traffic "+
			"fans out with the square of room size")
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file with a \"server\" section "+
			"({\"listen_on\": \"...\", \"room_code\": \"...\", \"max_clients\": ..., "+
			"\"send_hz\": ...}) -- a friendlier alternative to flags for non-developer use; "+
			"silently ignored if it doesn't exist; a flag passed explicitly on the command line "+
			"overrides the same field from this file")
	flag.Parse()

	log.SetOutput(openLogFile("meshghost-server.log"))

	explicit := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { explicit[f.Name] = true })
	applyFileConfig(*configPath, explicit, configTargets{
		addr:       addr,
		roomCode:   roomCode,
		maxClients: maxClients,
		sendHz:     sendHz,
	})

	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("meshghost-relay: listen on %s: %v", *addr, err)
	}
	log.Printf("meshghost-relay: listening on %s", ln.Addr())

	server := relay.NewServer()
	server.Loopback = *loopback
	server.RoomCode = *roomCode
	server.MaxClients = *maxClients
	server.SendHz = *sendHz
	log.Printf("meshghost-relay: max clients (total, across all rooms): %d", *maxClients)
	// Clamp and warn rather than refuse to start -- a typo in a cosmetic
	// tuning knob must not stop a host booting (see the ADR in
	// agent_docs/architecture.md). effectiveSendHz never differs from
	// *sendHz for a client of this same binary (Server.SendHz is clamped at
	// the identical use site, resolveSendHz), so logging it here is the
	// operator's only way to see what actually got advertised.
	effectiveSendHz := protocol.ClampSendHz(*sendHz)
	if effectiveSendHz != *sendHz {
		log.Printf("meshghost-relay: warning: send_hz %d is outside the supported %d-%d range, using %d",
			*sendHz, protocol.MinSendHz, protocol.MaxSendHz, effectiveSendHz)
	}
	log.Printf("meshghost-relay: room send rate: %dHz (per-client message cap: %d/sec)",
		effectiveSendHz, max(effectiveSendHz*relay.RateLimitHeadroomMultiple, relay.MaxMessagesPerSecond))
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
