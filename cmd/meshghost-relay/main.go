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
// exists so a crash is still readable after the console window itself is gone (e.g. if
// someone runs meshghost-server.exe directly instead of through run-server.bat's trailing
// `pause`) -- see packaging/release/README.txt. Falls back to stderr-only, with a warning,
// if the file can't be created (e.g. read-only folder).
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
	Addr *string `json:"listen_on"`
}

// rootConfig is the top-level shape of the config file: a "server" section
// read by this binary, sitting alongside a "client" section (meaningless
// here) read by cmd/meshghost from the same file in the shipped package.
type rootConfig struct {
	Server *fileConfig `json:"server"`
}

func applyFileConfig(path string, explicit map[string]bool, addr *string) {
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
}

func main() {
	addr := flag.String("addr", "127.0.0.1:7777", "address to listen on")
	loopback := flag.Bool("loopback", false, "dev-only Phase 3 flag: echo each client's own "+
		"state back to it under a synthetic <id>-ghost player_id, so a single client exercises "+
		"a real core->relay->core round trip. Never enable this outside dev/testing.")
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file with a \"server\" section "+
			"({\"listen_on\": \"...\"}) -- a friendlier alternative to flags for non-developer "+
			"use; silently ignored if it doesn't exist; -addr passed explicitly on the command "+
			"line overrides the file")
	flag.Parse()

	log.SetOutput(openLogFile("meshghost-server.log"))

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
