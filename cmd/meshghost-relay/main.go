// Command meshghost-relay is the standalone relay process: it accepts
// relay-protocol connections and forwards state between clients in a room.
// See relay for the implementation and agent_docs/contract.md for
// the wire protocol.
package main

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/cfg"
	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/netx/quicconn"
	"github.com/Tsukino-uwu/MeshGhost/netx/srclimit"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// fileConfig is the shape of the "server" section of an optional JSON config
// file (see -config), mirroring cmd/meshghost's own -- a friendlier
// alternative to flags for whoever's hosting, per packaging/README.md. The
// JSON field name is deliberately end-user-facing: "listen_on" (not "addr")
// reads as an opposite of the client's "connect_to" -- see
// packaging/release/config.json and its README.txt.
type fileConfig struct {
	Addr     *string `json:"listen_on"`
	RoomCode *string `json:"room_code"`
	// OnlyGame restricts this relay to a single game_id. Absent or ""
	// means it hosts any game (the pre-existing posture). See the ADR in
	// agent_docs/architecture.md and relay.Server.OnlyGame.
	OnlyGame   *string `json:"only_game"`
	MaxClients *int    `json:"max_clients"`
	// SendHz is the room-wide state send rate this relay advertises. Absent
	// or 0 means protocol.DefaultSendHz. See the ADR in
	// agent_docs/architecture.md for the send/receive rate-control feature.
	SendHz *int `json:"send_hz"`
	// GhostCollision is the room-wide ghost-collision policy this relay
	// advertises: "enabled" (the default, and what an absent value means) or
	// "disabled". Advisory -- the relay cannot verify an adapter honored it.
	// See the ADR in agent_docs/architecture.md.
	GhostCollision *string `json:"ghost_collision"`
	// ResumeGraceSeconds is how long this relay holds a dropped client's
	// identity -- its player_id, its leases and its in-flight exchanges --
	// waiting for it to reconnect, before telling the room it left. Absent or
	// 0 means protocol.DefaultResumeGrace (20s). Only ever used by a room
	// whose members negotiated resume.v1; a cosmetic room never holds
	// anything. Raising it makes a flaky connection less visible to everyone
	// else and makes a genuinely departed player's keys stay locked longer --
	// see relay.Server.ResumeGrace.
	ResumeGraceSeconds *int `json:"resume_grace_seconds"`
	// Transport is a comma-separated list of transports to serve at once:
	// "tcp", "quic", or both. Absent means "tcp,quic". Clients pick one of
	// them; a room can hold clients on different transports simultaneously,
	// since the relay forwards through the transport.Transport interface and
	// never learns which is which. See the transport ADR in
	// agent_docs/architecture.md. "udp" is refused by name since 2026-09-15
	// (ADR 0065); only the meshghost_devudp build accepts it.
	Transport *string `json:"transport"`
	// QuicAddr is where quic listens. Absent or empty is sharesAddrPort:
	// quic reuses listen_on's port number, so hosting means forwarding one
	// number. (In the dev build quic KEEPS that number even when plain udp is
	// served alongside it -- udp is the one that moves; udp_dev.go.)
	QuicAddr *string `json:"listen_quic"`
	// UDPAddr is where the plain "udp" transport listens, in the dev build.
	// Still decoded in a release so that an old config's `"listen_udp": ""`
	// is not reported as an unknown key; a NON-empty value refuses to start
	// (checkUDPConfig, udp_release.go).
	UDPAddr *string `json:"listen_udp"`
	// TLS is the OBSOLETE switch: until 2026-09-15 it was "off", "auto" or
	// "required", and since then every connection is TLS with nothing to
	// switch (ADR 0066). Still decoded so an old config's key is not reported
	// as unknown, and then judged by checkLegacyTLSKey: a value that asked for
	// plaintext refuses to start -- a security setting is never silently
	// ignored -- and "required" runs with a note to delete the key.
	TLS *string `json:"tls"`
	// QLog turns on quic-go's per-connection qlog trace, written into the
	// directory the QLOGDIR environment variable names. Dev diagnostics;
	// absent or false means no trace and no cost. Until 2026-09-15 the
	// environment variable alone turned it on, silently (B5).
	QLog *bool `json:"qlog"`
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
	addr           *string
	roomCode       *string
	onlyGame       *string
	maxClients     *int
	sendHz         *int
	ghostCollision *string
	resumeGrace    *int
	transport      *string
	quicAddr       *string
	udpAddr        *string
	legacyTLS      *string // the obsolete "tls" key, for checkLegacyTLSKey
	qlog           *bool
}

func applyFileConfig(path string, explicit map[string]bool, t configTargets) {
	// Absolute path, BOM strip and empty-file check all live in
	// cfg.ReadConfigFile, shared with the client. Unlike the client, a MISSING
	// file is silent here: a relay is run deliberately from a console, so
	// there is no player to reassure.
	data, shown, err := cfg.ReadConfigFile(path, "meshghost-relay")
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("meshghost-relay: warning: could not read config file %s: %v", shown, err)
		}
		return
	}
	if data == nil {
		return
	}
	var rc rootConfig
	if err := json.Unmarshal(data, &rc); err != nil {
		if !cfg.ApplyDespiteBadValue(err, shown, "meshghost-relay") {
			return
		}
	}
	// A key that is not a setting is a typo doing nothing -- see
	// cfg.WarnUnknownKeys. Scoped to "server" for the same reason the client
	// scopes to "client": the root object legitimately carries the other
	// binary's section, and in the shipped package it carries both.
	if section := serverSection(data); section != nil {
		// nil: unlike the client's "client" section, nothing but this binary
		// reads "server" -- no mod, no adapter -- so every key in it that is
		// not a setting is a typo.
		cfg.WarnUnknownKeys(section, fileConfig{}, shown, "meshghost-relay", "server", nil)
	}
	if rc.Server == nil {
		log.Printf("meshghost-relay: warning: config file %s has no \"server\" section -- "+
			"every server setting is falling back to its built-in default", shown)
		return
	}
	sc := *rc.Server
	cfg.Override(explicit, "addr", t.addr, sc.Addr)
	cfg.Override(explicit, "room-code", t.roomCode, sc.RoomCode)
	cfg.Override(explicit, "only-game", t.onlyGame, sc.OnlyGame)
	cfg.Override(explicit, "max-clients", t.maxClients, sc.MaxClients)
	cfg.Override(explicit, "send-hz", t.sendHz, sc.SendHz)
	cfg.Override(explicit, "ghost-collision", t.ghostCollision, sc.GhostCollision)
	cfg.Override(explicit, "resume-grace", t.resumeGrace, sc.ResumeGraceSeconds)
	cfg.Override(explicit, "transport", t.transport, sc.Transport)
	cfg.Override(explicit, "listen-quic", t.quicAddr, sc.QuicAddr)
	cfg.Override(explicit, "listen-udp", t.udpAddr, sc.UDPAddr)
	cfg.Override(explicit, "tls", t.legacyTLS, sc.TLS)
	cfg.Override(explicit, "qlog", t.qlog, sc.QLog)
}

// sharesAddrPort is the default for both -listen-quic and -listen-udp: empty
// means "use -addr's port". quic is carried over udp and tcp/udp are separate
// port spaces, so tcp:7777 and quic:7777/udp coexist happily.
//
// This is a NAT decision rather than a tidiness one. Serving quic by default
// (see the transport ADR in agent_docs/architecture.md) would otherwise have
// turned hosting from "forward 7777" into "forward 7777 and 7780", and the
// port-forwarding step is where a host actually gives up. Sharing the number
// makes it "forward 7777, TCP and UDP" -- one rule in most router UIs.
//
// The plain udp transport is the one thing that cannot coexist here, since it
// wants that same udp port. It is opt-in, unencryptable and deliberately last in
// netx.AutoPreference, so it is the one that carries the awkwardness: when both
// are served, UDP moves to FallbackUDPAddr and quic keeps the shared number.
const sharesAddrPort = ""

// servesKind reports whether k is in the resolved transport list.
func servesKind(kinds []netx.Kind, k netx.Kind) bool {
	for _, got := range kinds {
		if got == k {
			return true
		}
	}
	return false
}

// resolveQuicAddr decides where quic listens, given the transports actually
// selected, the main -addr, and whatever -listen-quic was set to.
//
// Sharing -addr's port is the default because it keeps hosting to ONE forwarded
// port number, which is the difference between a friend being able to host and
// not. quic keeps that number even when plain udp is also served: udp is the one
// that moves (see resolveUDPAddr and FallbackUDPAddr).
//
// NOTHING here refuses to start. An operator who names a port explicitly --
// -listen-udp or -listen-quic -- is believed without further checking, on the
// grounds that naming a port is the act of taking responsibility for forwarding
// it. This paragraph described a refusal until 2026-09-07; both functions return
// (string, error) and every return in either one has a nil error.
//
// Extracted from main() on 2026-08-25 so the rule can be tested. It was five
// nested conditions and a log.Fatalf inside a 300-line main, which meant the only
// thing that could exercise it was internal/e2e spawning a real process — and
// e2e cannot easily assert on a refusal, because the refusal is the process
// exiting. As a pure function returning an error it is nine test cases.
func resolveQuicAddr(kinds []netx.Kind, addr, quicAddr string) (string, error) {
	if !servesKind(kinds, netx.QUIC) {
		// Not serving quic: whatever -listen-quic says is irrelevant and is
		// passed through untouched rather than validated. The flag's own help
		// text already says it is ignored unless quic is served.
		return quicAddr, nil
	}
	if quicAddr != sharesAddrPort {
		// Explicitly placed by the operator. Believed without further checking:
		// naming a port is the act of taking responsibility for forwarding it.
		return quicAddr, nil
	}
	return addr, nil
}

// roomCodeFlagHelp is -room-code's help text, at package level so a test can
// assert what it tells the host (the same reason resolveQuicAddr was lifted out
// of main on 2026-08-25).
//
// It names config.json FIRST and says why, which it did not until 2026-09-08
// (review F21). A flag value is the process command line: on Windows any local
// process reads it with `Get-Process -Module`/WMI without elevation, on Linux it
// sits in /proc/<pid>/cmdline world-readable by default, and on both it lands in
// the shell history file of whoever typed it. Nothing about that is remote --
// but a room code is a shared secret whose whole job is that people who do not
// have it cannot join, and the host who typed it on a shared box has no way of
// knowing it leaked. The old text pointed at config.json as merely the friendlier
// spelling; it is also the one that keeps the secret out of an argv every other
// program on the machine can read.
//
// The flag STAYS: it is what dev-scripts and a one-off `-room-code x` test run
// use, and removing it would break every host who scripted their relay.
const roomCodeFlagHelp = "shared secret clients must send to join a room -- " +
	"prefer \"room_code\" in config.json: a value passed here is part of this " +
	"process's command line, which any other local process can read (Get-Process, " +
	"ps, /proc) and which your shell writes to its history file. " +
	"Leave both empty to run open (anyone with the address can join, the " +
	"pre-existing default); see agent_docs/architecture.md's room-code ADR for " +
	"what this does and doesn't defend against (no TLS: the code crosses the " +
	"wire in plaintext)"

func main() {
	addr := flag.String("addr", "127.0.0.1:7777", "address to listen on (tcp, and quic unless -listen-quic says otherwise)")
	loopback := flag.Bool("loopback", false, "dev-only Phase 3 flag: echo each client's own "+
		"state back to it under a synthetic <id>-ghost player_id, so a single client exercises "+
		"a real core->relay->core round trip. Never enable this outside dev/testing.")
	roomCode := flag.String("room-code", "", roomCodeFlagHelp)
	onlyGame := flag.String("only-game", "", "restrict this relay to a single game: a client "+
		"playing anything else is refused at the handshake. Leave empty (the default) to host any "+
		"game, including several at once in different rooms. Valid values are the game_id an "+
		"adapter advertises -- \"emerald\", \"crystal\", \"tevi\", or \"pseudoregalia\" for the four "+
		"shipped "+
		"adapters -- and must match exactly")
	maxClients := flag.Int("max-clients", relay.DefaultMaxClients,
		"max clients this relay accepts in total, across every room it's hosting combined -- "+
			"not per room. Every room member's state is forwarded to every other member of that "+
			"same room, so traffic within a room scales roughly with the square of its size, not "+
			"linearly -- raising this a lot and letting it pile into one room trades your own "+
			"relay's bandwidth/CPU for more seats, not a free lunch")
	introspect := flag.Duration("introspect", 0,
		"if set, periodically log what this relay currently thinks is true: rooms, members and "+
			"their transports, held leases and who holds them, exchanges in flight, and identities "+
			"parked waiting for a reconnect. Off by default. For a cosmetic room this is one line "+
			"and not worth running; it exists because a wedged trade or a key nobody can claim is "+
			"otherwise invisible -- that state is a map in memory, not something the log printed "+
			"once. Deliberately NOT a status port: no listener, nothing new to authenticate. "+
			"Never prints resume tokens or the contents of a trade")
	resumeGrace := flag.Int("resume-grace", 0,
		"seconds to hold a dropped player's identity (its player_id, leases and in-flight "+
			"exchanges) waiting for it to reconnect, before telling the room it left. 0 (the "+
			"default) means 20s. Only used by rooms whose members negotiated resume.v1 -- a "+
			"cosmetic room holds nothing and this changes nothing for it. Higher hides a flaky "+
			"connection better; lower frees a genuinely departed player's keys sooner")
	ghostCollision := flag.String("ghost-collision", protocol.GhostCollisionDisabled,
		"room-wide ghost collision policy advertised to every client: \"disabled\" (the "+
			"default since 2026-09-02, the user's call: no ghost blocks anything, in any game) "+
			"or \"enabled\" (each adapter's own defaults stand). ADVISORY ONLY: both Lua "+
			"adapters read the session_policy message this is sent in (2026-09-11) and make "+
			"their ghosts walk-through on \"disabled\"; the two PC adapters do not read it yet "+
			"and hold anyway, because neither ships ghosts solid. This relay cannot verify that "+
			"a game did either -- nothing it can see distinguishes an adapter that honoured the "+
			"policy from one that ignored it")
	sendHz := flag.Int("send-hz", protocol.DefaultSendHz,
		"how many times per second every player sends their position to this room (a \"15 tick\" "+
			"relay = 15Hz = an update every ~67ms; higher/lower are the same idea in different "+
			"units). A client adopts this rate unless it has its own slower local preference, "+
			"which always wins -- this can only ever make players send MORE often, never override "+
			"someone who deliberately wants to send less. Valid range 10-100; leave this alone "+
			"unless you know you need it -- raising it multiplies every player's bandwidth in both "+
			"directions for a visual gain that's small and diminishing (see README.txt for the "+
			"real numbers), and YOUR machine (the host) carries the worst of it, since traffic "+
			"fans out with the square of room size")
	transportNames := flag.String("transport", "tcp,quic",
		"which transports to serve, comma-separated: tcp, quic, or both. Serving both is "+
			"fine and clients may mix freely within one room -- tcp is readable with netcat for "+
			"debugging, and quic is loss-tolerant, encrypted and spoofing-resistant by default. "+
			"The default serves both so a default client (-transport auto) gets an encrypted "+
			"session without anyone configuring anything -- but note quic needs -listen-quic's "+
			"port forwarded too, not just -addr's. (udp, the plain unencrypted transport, "+
			"stopped being an option on 2026-09-15 and is refused by name)")
	// -listen-udp exists only in the dev build (udp_dev.go); a release
	// registers no such flag and udpAddr stays "" (udp_release.go). ADR 0065.
	udpAddr := udpListenFlag()
	quicAddr := flag.String("listen-quic", sharesAddrPort,
		"address to serve quic on. Empty (the default) means share -addr's port -- quic runs "+
			"over udp and tcp/udp are separate port spaces, so tcp:7777 and quic:7777/udp "+
			"coexist and a host forwards ONE port number for both. Ignored unless quic is in "+
			"-transport")
	// No -tls flag since 2026-09-15: every connection is TLS. The obsolete
	// config key is still read into this so it can be judged (checkLegacyTLSKey).
	legacyTLS := new(string)
	qlog := flag.Bool("qlog", false,
		"write quic-go's qlog trace for every quic connection into the directory the QLOGDIR "+
			"environment variable names (dev diagnostics: packets, losses, congestion window). Off "+
			"by default; the variable alone does nothing")
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file with a \"server\" section "+
			"({\"listen_on\": \"...\", \"listen_quic\": \"...\", \"room_code\": \"...\", "+
			"\"only_game\": \"...\", \"transport\": \"...\", "+
			"\"max_clients\": ..., \"send_hz\": ..., \"resume_grace_seconds\": ...}) -- a friendlier alternative to flags for "+
			"non-developer use. A relative path is tried in the working directory first and then "+
			"beside this executable; the startup log says which was read, or that neither exists. "+
			"A flag passed explicitly on the command line overrides the same field from this file")
	flag.Parse()
	explicit := cfg.ExplicitFlags()

	// Where the config is, decided before the log opens, because the log goes
	// beside it. See resolveConfigPath: a relay started from a directory other
	// than its own used to read no file, say nothing, and come up on loopback.
	located := resolveConfigPath(*configPath, explicit["config"], executableDir)

	// Tee'd with stderr, unlike the client: a relay is normally watched in the
	// window it was launched from, so its log file is a second copy rather than
	// the only one. cfg.OpenLogFile returns just the file (nil on failure) and
	// leaves that composition here, because the two binaries genuinely differ.
	logOut := io.Writer(os.Stderr)
	if f := cfg.OpenLogFile(located.logPath("meshghost-server.log"), "meshghost-relay"); f != nil {
		logOut = io.MultiWriter(os.Stderr, f)
	}
	log.SetOutput(logOut)
	log.Print(located.note)

	targets := configTargets{
		addr:           addr,
		roomCode:       roomCode,
		onlyGame:       onlyGame,
		maxClients:     maxClients,
		sendHz:         sendHz,
		ghostCollision: ghostCollision,
		resumeGrace:    resumeGrace,
		transport:      transportNames,
		quicAddr:       quicAddr,
		udpAddr:        udpAddr,
		legacyTLS:      legacyTLS,
		qlog:           qlog,
	}
	// The flag values BEFORE the file: what every later re-read of the file
	// starts from (reload.go), so a key removed from the file falls back here.
	base := snapshotRelayLive(targets)
	applyFileConfig(located.path, explicit, targets)
	if *qlog {
		quicconn.SetQLog(true)
		log.Printf("meshghost-relay: qlog tracing ON for every quic connection -- traces go to QLOGDIR=%q "+
			"(empty means quic-go writes nothing); this is a dev diagnostic, not for a public relay",
			os.Getenv("QLOGDIR"))
	}

	// The obsolete "tls" key: a value that asked for plaintext is a startup
	// error, never a silently changed meaning.
	if note, err := checkLegacyTLSKey(*legacyTLS); err != nil {
		log.Fatalf("meshghost-relay: %v", err)
	} else if note != "" {
		log.Printf("meshghost-relay: %s", note)
	}

	// This relay's identity: one key pair and certificate, persisted in private/
	// beside the config so a client that connected once recognizes the same
	// relay after a restart (tlsx.LoadOrCreateIdentity; ADR 0066). A folder
	// that holds a broken identity is fatal here, before any listener opens.
	identityDir := located.identityDir()
	identity, fingerprint, err := tlsx.LoadOrCreateIdentity(identityDir, netx.TLSALPN)
	if err != nil {
		log.Fatalf("meshghost-relay: %v", err)
	}

	// Fatal on an unrecognized transport rather than falling back to tcp:
	// netx.Kind's zero value IS tcp, so a lenient parse would quietly hand
	// an operator who asked for quic an unencrypted relay. Same reasoning
	// as cmd/meshghost's own -transport handling, and a deliberate
	// departure from the clamp-and-warn treatment send_hz gets below.
	kinds, err := netx.ParseKinds(*transportNames)
	if err != nil {
		log.Fatalf("meshghost-relay: %v", err)
	}

	// A release refuses a config that still places plain udp (udp_release.go);
	// netx.ParseKinds above already refused it in -transport.
	if err := checkUDPConfig(*udpAddr); err != nil {
		log.Fatalf("%v", err)
	}

	// Resolve where quic listens, now that the transport list is known.
	//
	// Sharing -addr's port is the default because it keeps hosting to one
	// forwarded port number. In the dev build the only thing that can take
	// that udp port away is the plain udp transport: when both are served
	// QUIC KEEPS the shared port and plain udp is what relocates (udp_dev.go's
	// resolveUDPAddr) -- that way the port an operator forwarded is the one
	// quic still advertises. Moving quic instead would surface much later as
	// "quic clients can't connect" with nothing pointing here.
	resolvedUDP, err := resolveUDPListen(kinds, *addr, *udpAddr)
	if err != nil {
		log.Fatalf("meshghost-relay: %v", err)
	}
	*udpAddr = resolvedUDP

	resolvedQuic, err := resolveQuicAddr(kinds, *addr, *quicAddr)
	if err != nil {
		log.Fatalf("meshghost-relay: %v", err)
	}
	*quicAddr = resolvedQuic

	sources := newSourceTable(*maxClients)
	listeners, err := buildListeners(listenerConfig{
		kinds:      kinds,
		addr:       *addr,
		quicAddr:   *quicAddr,
		udpAddr:    *udpAddr,
		identity:   identity,
		maxClients: *maxClients,
		sources:    sources,
	})
	if err != nil {
		log.Fatalf("meshghost-relay: %v", err)
	}

	// Say what the identity is and where it lives, in the log the host
	// actually reads. The fingerprint is what every client remembers this
	// relay by, so it is printed with what keeping it means attached.
	log.Printf("meshghost-relay: tls certificate fingerprint: %s", fingerprint)
	log.Printf("meshghost-relay: this server's identity is kept in %s -- players' clients remember "+
		"the fingerprint above and warn if it changes. Copy that folder into a new install to keep "+
		"this identity; NEVER share it, since whoever has %s can pose as this server (the README "+
		"inside says the same).",
		identityDir, tlsx.KeyFileName)
	if servesKind(kinds, netx.UDP) {
		log.Printf("meshghost-relay: WARNING: the plain udp transport is being served and " +
			"CANNOT be encrypted (Go has no DTLS). A client that chooses udp is unencrypted. " +
			"Drop udp from -transport if that matters.")
	}

	// What a client with transport "auto" is told. Built from the listeners
	// that actually came up, not from the configured list, so a transport
	// that failed to bind is never advertised. Only the port is sent — the
	// host is whatever the client already connected to, which is what makes
	// this work through NAT (this relay may be bound to 0.0.0.0 and have no
	// idea what address reaches it). See protocol.TransportOffer.
	offers := make([]protocol.TransportOffer, 0, len(listeners))
	for _, bl := range listeners {
		addr, ok := bl.ln.Addr().(*net.TCPAddr)
		var port int
		if ok {
			port = addr.Port
		} else if ua, ok := bl.ln.Addr().(*net.UDPAddr); ok {
			port = ua.Port
		} else if _, p, err := net.SplitHostPort(bl.ln.Addr().String()); err == nil {
			if n, err := strconv.Atoi(p); err == nil {
				port = n
			}
		}
		if port == 0 {
			log.Printf("meshghost-relay: warning: could not determine the port for the %s listener (%s) — clients using transport \"auto\" will not be offered it",
				bl.kind, bl.ln.Addr())
			continue
		}
		offers = append(offers, protocol.TransportOffer{Kind: bl.kind.String(), Port: port})
	}

	// Spell out the port forwarding, because "which ports do I open" is the
	// step that actually decides whether anyone can connect, and serving quic
	// by default made it two rules instead of one. Only the host needs this
	// at all -- every client dials outward -- so saying it here, once, is the
	// whole of the NAT story for a user. Protocol is named per line because
	// tcp/7777 and udp/7777 are different forwarding rules on most routers,
	// and quic is udp despite sitting beside a tcp port.
	forwards := make([]string, 0, len(offers))
	for _, o := range offers {
		proto := "udp"
		if o.Kind == netx.TCP.String() {
			proto = "tcp"
		}
		forwards = append(forwards, fmt.Sprintf("%d/%s (%s)", o.Port, proto, o.Kind))
	}
	if len(forwards) > 0 {
		log.Printf("meshghost-relay: to accept players from outside this machine, forward: %s",
			strings.Join(forwards, ", "))
	}

	server := relay.NewServer()
	server.Loopback = *loopback
	// Trimmed for the same reason only_game is, below: hand-typed into
	// config.json, and a trailing space refused every client with nothing
	// but "invalid room code" to show for it (fourth review, B7). The value
	// itself is never lower-cased or otherwise normalized -- a code is a
	// secret, and the client sends it as typed.
	server.RoomCode = strings.TrimSpace(*roomCode)
	*roomCode = server.RoomCode
	server.SourceGuard = sources
	// The room-code proof binds to THIS relay's certificate (ADR 0067): a
	// client's proof names the fingerprint it verified, so it fails against
	// anyone presenting another certificate, whatever they relay.
	server.PakeIdentity = fingerprint
	// Trimmed because this is normally hand-typed into config.json and a
	// stray space would otherwise refuse every client for no visible
	// reason. Deliberately not lower-cased or otherwise normalized -- that
	// would diverge from the exact-equality game_id comparison every other
	// use site (joinOrCreateRoom, the adapters) already relies on.
	server.OnlyGame = strings.TrimSpace(*onlyGame)
	server.Offers = offers
	// The ENFORCED value, so the banner below and tryReserveSlot agree; a
	// configured 0 means the default and used to be printed as 0 (B7).
	server.MaxClients = relay.EffectiveMaxClients(*maxClients)
	server.SendHz = *sendHz
	server.GhostCollision = *ghostCollision
	server.ResumeGrace = time.Duration(*resumeGrace) * time.Second
	if *introspect > 0 {
		go func() {
			ticker := time.NewTicker(*introspect)
			defer ticker.Stop()
			for range ticker.C {
				log.Print(server.Snapshot().String())
			}
		}()
		log.Printf("meshghost-relay: introspection on -- logging relay state every %s", *introspect)
	}
	log.Printf("meshghost-relay: max clients (total, across all rooms): %d", server.MaxClients)
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
		effectiveSendHz, relay.MaxMessagesPerSecondFor(effectiveSendHz))
	// Say what was actually read, the same reason only_game logs its value: a
	// typo here is silently the RESTRICTIVE choice (NormalizeGhostCollision
	// sends anything unrecognized to "disabled"), so a host who fat-fingers
	// this would otherwise see ghosts quietly stop being solid with nothing
	// explaining it.
	switch effectiveCollision := protocol.NormalizeGhostCollision(*ghostCollision); effectiveCollision {
	case protocol.GhostCollisionDisabled:
		if *ghostCollision != protocol.GhostCollisionDisabled {
			log.Printf("meshghost-relay: warning: ghost_collision %q is not a value I recognize, "+
				"reading it as %q -- the safe direction, but probably not what you meant "+
				"(valid: %q, %q)",
				*ghostCollision, protocol.GhostCollisionDisabled,
				protocol.GhostCollisionEnabled, protocol.GhostCollisionDisabled)
		}
		log.Printf("meshghost-relay: ghost collision: DISABLED for every client in every room. " +
			"Advisory -- shipped adapters honor it, but nothing here can verify a game did.")
	default:
		log.Printf("meshghost-relay: ghost collision: enabled -- each game's own defaults stand " +
			"(\"disabled\", the shipped default, turns it off room-wide)")
	}
	if *loopback {
		log.Printf("meshghost-relay: -loopback enabled — dev-only, do not use with real peers")
	}
	log.Print(roomCodeStartupNotice(*roomCode))
	// Echo the configured value back rather than just "restriction on":
	// a typo'd game_id refuses every client with no other visible cause,
	// and this log line is the operator's only way to spot it.
	if server.OnlyGame == "" {
		log.Printf("meshghost-relay: hosting any game (no \"only_game\" set)")
	} else {
		log.Printf("meshghost-relay: restricted to game_id %q -- clients playing any other game will be refused",
			server.OnlyGame)
	}
	// Serve every listener concurrently and block on the first one to fail.
	// Previously this was a single blocking Serve call; the failure
	// behaviour is deliberately unchanged (any listener dying is fatal)
	// rather than trying to limp along on the remaining transports, which
	// would leave some clients able to connect and others not, with only a
	// log line to explain it.
	// config.json stays live from here for room_code, only_game and
	// max_clients (reload.go). The snapshot is taken AFTER main trimmed the
	// code, so the first diff sees what is actually live.
	watchStop := make(chan struct{})
	defer close(watchStop)
	go newRelayConfigWatcher(located.path, explicit, base, snapshotRelayLive(targets), server).run(watchStop)
	log.Print(describeRelayReloadable(located.path))

	serveErr := make(chan error, len(listeners))
	for _, bl := range listeners {
		go func(bl boundListener) {
			serveErr <- fmt.Errorf("%s: %w", bl.kind, server.Serve(bl.ln))
		}(bl)
	}

	// Ctrl+C, and what it used to do: nothing. Before 2026-09-08 this binary
	// imported no os/signal at all and main() ended only via log.Fatalf, so an
	// interrupt killed the process where it stood. On tcp the kernel at least
	// sends a FIN as the sockets are reclaimed; on QUIC -- the SHIPPED DEFAULT
	// transport -- the udp socket simply stops existing, nothing is sent, and
	// every player's client sits there until its own idle timeout expires
	// (~17s, agent_docs/contract.md) with its ghosts aged out at 3s. From the
	// player's side the host "froze", and the log said the relay was fine right
	// up to the last line.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	lns := make([]*trackingListener, 0, len(listeners))
	for _, bl := range listeners {
		lns = append(lns, bl.ln)
	}
	serveFailed, n := awaitShutdown(serveErr, stop, lns, shutdownDrain)
	if serveFailed != nil {
		log.Fatalf("meshghost-relay: serve: %v -- closed %d listener(s) and %d client connection(s) first",
			serveFailed, len(lns), n)
	}
	log.Printf("meshghost-relay: closed %d listener(s) and %d client connection(s) -- goodbye",
		len(lns), n)
}

// awaitShutdown blocks until a listener dies or a signal arrives, then takes
// every listener and client down the same way in both cases, and reports which
// it was: the error a listener died with (nil for a signal) and how many client
// connections were told to go.
//
// Both cases, not one. Until 2026-09-15 a listener's non-temporary Accept error
// was log.Fatalf with nothing else: every player sat on a dead relay until
// their own idle timeout, exactly the failure the Ctrl+C path had been fixed
// on 2026-09-08 (fourth adversarial review, B3). A relay that dies should
// say goodbye the same way a relay that is stopped does.
func awaitShutdown(serveErr <-chan error, stop <-chan os.Signal, lns []*trackingListener, drain time.Duration) (error, int) {
	select {
	case err := <-serveErr:
		return err, shutdown(lns, drain)
	case sig := <-stop:
		// A SECOND Ctrl+C must kill immediately. Restoring the default handler
		// before doing any work is what makes that true: a host whose shutdown
		// is taking longer than they expected can always press it again, and
		// the alternative -- an interrupt landing in a buffered channel nobody
		// reads -- is a relay that appears to ignore Ctrl+C entirely.
		signal.Reset(os.Interrupt, syscall.SIGTERM)
		log.Printf("meshghost-relay: %v -- shutting down", sig)
		return nil, shutdown(lns, drain)
	}
}

// shortRoomCodeLen is the length below which the startup line warns. A guess
// budget of one attempt a second per address (relay.RoomCodeAttemptsPerSecond)
// makes a short code a matter of patience rather than impossibility: eight
// characters is where a printable-ASCII code stops being one an attacker
// with a few addresses can walk through in a session. Reasoned, not
// measured against an attacker.
const shortRoomCodeLen = 8

// roomCodeStartupNotice is the one line the host reads about their room
// code. A function so a test can hold it to its word.
func roomCodeStartupNotice(code string) string {
	switch {
	case code == "":
		return "meshghost-relay: WARNING: no room code configured -- anyone who has this " +
			"relay's address can join any room. Set -room-code (or \"room_code\" in config.json) " +
			"before exposing this relay beyond a friend you directly hand the address to."
	case len(code) < shortRoomCodeLen:
		return fmt.Sprintf("meshghost-relay: room-code auth enabled -- but the code is only %d "+
			"characters. Guesses are limited to about one a second per address, which makes a "+
			"short code slow to break rather than impossible; use %d or more if strangers can "+
			"reach this relay.", len(code), shortRoomCodeLen)
	default:
		return "meshghost-relay: room-code auth enabled"
	}
}

// boundListener is one served transport: which kind, and the listener that
// tracks the connections it hands out so shutdown can reach them.
type boundListener struct {
	kind netx.Kind
	ln   *trackingListener
}

// listenerConfig is what buildListeners needs from the resolved flags.
type listenerConfig struct {
	kinds                   []netx.Kind
	addr, quicAddr, udpAddr string
	// identity is the relay's one certificate, served on tcp and quic
	// alike: tlsx.LoadOrCreateIdentity in the shipped relay, tlsx.ServerConfig
	// in a test. Required.
	identity   *tls.Config
	maxClients int
	// sources is the per-address table (newSourceTable); nil means no
	// per-source bound, which only a test asks for.
	sources *srclimit.Table
}

// newSourceTable is the one per-address table a relay process keeps: the
// connection cap per address for every listener, and the wrong-room-code
// budget the relay consults. In memory, bounded, never logged (ADR 0064).
func newSourceTable(maxClients int) *srclimit.Table {
	return srclimit.New(srclimit.Options{
		MaxOpenPerSource:    relay.MaxOpenConnsPerSourceFor(maxClients),
		AuthBurst:           relay.RoomCodeAttemptBurst,
		AuthRefillPerSecond: relay.RoomCodeAttemptsPerSecond,
	})
}

// buildListeners brings up one listener per selected transport, wrapped the
// way the shipped relay wraps them: the open-connection limiter, then TLS
// (tcp only), then connection tracking. It is a function rather than a block
// of main so a test can drive a hostile client through the SAME stack a
// stranger meets -- before 2026-09-15 every relay test listened raw, and the
// wrapper layers were exactly where three shipped bugs had lived
// (netx/limit.go's story).
//
// All listeners feed the same Server: relay.Serve takes any net.Listener and
// handleConn any net.Conn, so nothing in relay knows or cares which is which
// -- and a single room can hold clients arriving over different transports,
// because Room.Forward sends through the transport.Transport interface.
//
// On error, every listener already opened is closed again.
func buildListeners(c listenerConfig) ([]boundListener, error) {
	if c.identity == nil {
		return nil, errors.New("no relay identity to serve")
	}
	// One certificate for the whole process, on every listener: a
	// per-listener one would give one relay two fingerprints, and a client
	// that moved from tcp to quic would warn about its own relay.
	tlsOpts := netx.TLSOptions{Server: c.identity}

	// Every listener gets the open-connection bound (relay.MaxOpenConnsFor);
	// the log line it prints is rate-limited.
	tlsOpts.MaxOpenConns = relay.MaxOpenConnsFor(c.maxClients)
	// And the per-address half of it, through one table every listener
	// shares, so one address is one source whichever transport it arrives
	// on. The same table is the relay's room-code guard (Server.SourceGuard);
	// the relay only ever hands it a connection and gets back yes or no.
	tlsOpts.Sources = c.sources

	var listeners []boundListener
	for _, k := range c.kinds {
		bind := c.addr
		if k == netx.QUIC {
			bind = c.quicAddr
		}
		if k == netx.UDP {
			bind = c.udpAddr
		}
		ln, err := netx.ListenWithTLS(k, bind, tlsOpts)
		if err != nil {
			for _, bl := range listeners {
				_ = bl.ln.Close()
			}
			return nil, fmt.Errorf("listen %s on %s: %w", k, bind, err)
		}
		// Wrapped so Ctrl+C can reach the connections this listener handed
		// out: closing a listener does NOT close them (quic-go's Listener.Close
		// says so in as many words, and quic is the shipped default), and a
		// client whose relay simply vanishes waits out its own idle timeout.
		listeners = append(listeners, boundListener{kind: k, ln: trackConns(ln)})
		label := k.String()
		if k == netx.TCP {
			label = "tcp, tls"
		}
		log.Print(listeningLine(ln.Addr(), label))
	}
	return listeners, nil
}

// checkLegacyTLSKey judges the obsolete "tls" config key. Empty (absent) is
// nothing. A value that asked for plaintext -- off, auto, or their aliases --
// is an ERROR: the setting meant something about encryption, and a relay that
// silently ran with a different meaning would be exactly the "security
// setting a stale binary ignores" agent_docs/risks.md warns about. A value
// that asked for what is now always true runs, with one line saying to delete
// the key. Unknown words are an error as they always were.
func checkLegacyTLSKey(v string) (note string, err error) {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "":
		return "", nil
	case "required", "on", "true", "yes":
		return "NOTE: the \"tls\" key in config.json is obsolete -- every connection is TLS since " +
			"2026-09-15 and there is nothing to switch. Delete the key.", nil
	case "off", "false", "no", "auto":
		return "", fmt.Errorf("\"tls\": %q in config.json is no longer a choice: every connection is "+
			"TLS since 2026-09-15 and a plaintext mode does not exist. Delete \"tls\" from config.json "+
			"to start (there is no fingerprint to hand out any more either -- clients remember this "+
			"server's identity on their own)", v)
	default:
		return "", fmt.Errorf("\"tls\": %q in config.json is not a value this key ever had, and the key is "+
			"obsolete -- every connection is TLS since 2026-09-15. Delete it", v)
	}
}

// listeningLine is the "listening on" line, and it names the ADDRESS FAMILY
// the socket actually covers. Go binds a wildcard -- "0.0.0.0" included --
// as a dual-stack IPv6 socket wherever the OS allows it (Linux, Windows), so a
// host who wrote 0.0.0.0, firewalled IPv4, and read a line saying 0.0.0.0 had
// an IPv6 side open they never knew about; the transport offers carry only a
// port, so an IPv6 client got quic over IPv6 too (fourth adversarial review,
// B1). The line now says what the operating system reported back, in words.
func listeningLine(addr net.Addr, label string) string {
	return fmt.Sprintf("meshghost-relay: listening on %s (%s)%s", addr, label, familyNote(addr))
}

// familyNote is the address-family clause listeningLine appends: empty for a
// specific address, and for a wildcard which families it reaches.
func familyNote(addr net.Addr) string {
	var ip net.IP
	switch a := addr.(type) {
	case *net.TCPAddr:
		ip = a.IP
	case *net.UDPAddr:
		ip = a.IP
	default:
		return ""
	}
	if ip == nil || !ip.IsUnspecified() {
		return ""
	}
	if ip.To4() != nil {
		return " -- every IPv4 address of this machine"
	}
	return " -- every address of this machine, IPv6 AND IPv4 (a dual-stack wildcard: firewall both families, " +
		"or bind an explicit IPv4 address to serve only that)"
}

// shutdownDrain is how long shutdown keeps the process alive after telling the
// clients to go, before the sockets are reclaimed by exit.
//
// One second, and it is not a round trip being waited for -- nothing is
// expected back. It is the time a goodbye needs to LEAVE: a quic connection's
// CONNECTION_CLOSE is sent 250ms after its stream is closed (netx/quicconn's
// closeLinger, which exists because a goodbye written and then hard-closed went
// missing on quic on 2026-08-17), and exiting inside that window would put the
// relay right back to saying nothing at all. Far under the 3s a ghost is aged
// out at, so a host restarting a relay never costs a player a visible despawn
// they would not have had anyway.
const shutdownDrain = time.Second

// shutdown stops accepting and then tells every connected client to go, in that
// order, and returns how many connections it spoke to.
//
// The order matters: closing the listeners first means a client that reconnects
// during the drain is refused by the OS rather than admitted into a room that is
// about to disappear. Closing the CONNECTIONS is the part that cannot be left
// out -- see trackingListener -- and it is done the way the relay already closes
// a client it wants to say something to (transport.CloseGracefully): half-close
// where the connection can, which puts a FIN behind whatever was last written,
// and a plain Close where it cannot, which for quic is a stream FIN followed by
// CONNECTION_CLOSE. Either way the client learns in one round trip instead of
// waiting out an idle timeout.
func shutdown(lns []*trackingListener, drain time.Duration) int {
	for _, ln := range lns {
		if err := ln.Close(); err != nil {
			log.Printf("meshghost-relay: closing a listener: %v", err)
		}
	}
	n := 0
	for _, ln := range lns {
		n += ln.closeClients()
	}
	if n > 0 && drain > 0 {
		time.Sleep(drain)
	}
	return n
}

// trackingListener remembers the connections a listener has handed out, so that
// shutdown can reach them.
//
// It exists because closing a listener does not close them. quic-go's
// Listener.Close documents it outright ("Already established (accepted)
// connections will be unaffected"), and quic is what a default relay and a
// default client negotiate -- so the transport almost every real session uses is
// exactly the one where closing the listeners tells nobody anything.
// netx/udpconn's own Listener.Close does close its conns; tcp's does not.
type trackingListener struct {
	net.Listener
	mu    sync.Mutex
	conns map[net.Conn]struct{}
}

func trackConns(ln net.Listener) *trackingListener {
	return &trackingListener{Listener: ln, conns: map[net.Conn]struct{}{}}
}

func (t *trackingListener) Accept() (net.Conn, error) {
	c, err := t.Listener.Accept()
	if err != nil {
		return nil, err
	}
	t.mu.Lock()
	t.conns[c] = struct{}{}
	t.mu.Unlock()
	// The wrapper's ONLY job is to forget the connection when it closes, so the
	// map cannot grow for the life of a long-running relay. Everything else it
	// does is forwarding, and that is the dangerous part: a wrapper embedding
	// net.Conn as an INTERFACE hides any method net.Conn does not declare, and
	// this repo has been bitten by that three times (2026-09-05, 2026-09-06,
	// 2026-09-07 -- netx/limit.go's limitedConn carries the story). The three
	// optional methods this codebase type-asserts for are forwarded below;
	// WriteUnreliable gets a separate type so it stays ABSENT on a connection
	// that genuinely has no datagram plane, since transport.SendUnreliable
	// decides by asking whether the method is there.
	tc := &trackedConn{Conn: c, owner: t, key: c}
	if uw, ok := c.(unreliableWriter); ok {
		return &trackedLossyConn{trackedConn: tc, uw: uw}, nil
	}
	return tc, nil
}

func (t *trackingListener) forget(c net.Conn) {
	t.mu.Lock()
	delete(t.conns, c)
	t.mu.Unlock()
}

// closeClients half-closes (or closes) every connection still open on this
// listener and returns how many there were.
//
// SNAPSHOT UNDER THE LOCK, CLOSE OUTSIDE IT, for the reason netx/udpconn's
// Listener.Close spells out at length: closing a connection calls back into
// forget, which wants this same mutex, and holding it across the close is a
// lock-ordering deadlock -- a relay that never finishes shutting down, which is
// a worse failure than the one this whole function exists to fix.
func (t *trackingListener) closeClients() int {
	t.mu.Lock()
	open := make([]net.Conn, 0, len(t.conns))
	for c := range t.conns {
		open = append(open, c)
	}
	t.conns = map[net.Conn]struct{}{}
	t.mu.Unlock()
	// IN PARALLEL, UNDER ONE DEADLINE. A half-close writes -- a TLS
	// close_notify, a quic stream FIN -- and a member whose socket has stalled
	// holds that write for the whole write timeout. Serially, one such member
	// held the goodbye for everyone behind it, up to 10 s each (fourth
	// adversarial review, B6). Now every connection gets the same deadline at
	// once, and a connection that cannot half-close in time is closed hard.
	deadline := time.Now().Add(closeClientsDeadline)
	var wg sync.WaitGroup
	for _, c := range open {
		wg.Add(1)
		go func(c net.Conn) {
			defer wg.Done()
			_ = c.SetDeadline(deadline)
			if cw, ok := c.(interface{ CloseWrite() error }); ok {
				if err := cw.CloseWrite(); err == nil {
					return
				}
			}
			_ = c.Close()
		}(c)
	}
	wg.Wait()
	return len(open)
}

// closeClientsDeadline bounds one client's half-close during shutdown. The
// same second shutdownDrain then waits for the goodbye to leave: a member
// that cannot take a FIN in a second is not going to read a goodbye either.
const closeClientsDeadline = time.Second

// unreliableWriter is the datagram plane as transport discovers it: by type
// assertion on the net.Conn. Declared here for the same reason netx declares
// its own copy -- it is an optional method, not an exported interface.
type unreliableWriter interface {
	WriteUnreliable(p []byte) (int, error)
}

type trackedConn struct {
	net.Conn
	owner *trackingListener
	key   net.Conn // the raw connection, which is what owner's map is keyed by
	once  sync.Once
}

func (c *trackedConn) Close() error {
	err := c.Conn.Close()
	c.once.Do(func() { c.owner.forget(c.key) })
	return err
}

// CloseWrite and TransportName forward for the reason netx/limit.go documents:
// transport.CloseGracefully asserts for CloseWrite and silently degrades to a
// RESET without it (losing the reject the relay just wrote), and relay's
// per-client log line asserts for TransportName and calls everything "tcp"
// without it -- in the very line a remote tester is asked to send back.
func (c *trackedConn) CloseWrite() error {
	cw, ok := c.Conn.(interface{ CloseWrite() error })
	if !ok {
		return errors.New("meshghost-relay: the underlying connection cannot half-close")
	}
	return cw.CloseWrite()
}

func (c *trackedConn) TransportName() string {
	tn, ok := c.Conn.(interface{ TransportName() string })
	if !ok {
		return "tcp"
	}
	return tn.TransportName()
}

// trackedLossyConn is trackedConn for a connection that also has the datagram
// plane (quic, udp). Separate type rather than a method on trackedConn so that
// the method is missing exactly when the underlying connection lacks it: the
// 2026-09-02 incident behind netx/limit.go's limitedLossyConn was every quic
// state silently riding the ordered stream because a wrapper answered the type
// assertion the transport uses to find the datagram path.
type trackedLossyConn struct {
	*trackedConn
	uw unreliableWriter
}

func (c *trackedLossyConn) WriteUnreliable(p []byte) (int, error) { return c.uw.WriteUnreliable(p) }

// locatedConfig is what resolveConfigPath decided: the path applyFileConfig
// reads, whether a file is there, and the one startup line that says so.
type locatedConfig struct {
	path  string
	found bool
	note  string
}

// logPath is where the relay's log goes: beside the config it read, or beside
// the executable when there was none. Never the bare working directory -- a
// service manager's working directory is wherever it happens to be, and a log
// written there is a log nobody finds.
func (l locatedConfig) logPath(name string) string {
	return filepath.Join(l.dir(), name)
}

// identityDir is where the relay's identity lives (tlsx.LoadOrCreateIdentity):
// the private/ folder beside the config, for the same reason the log is there --
// and so that "uninstall" is still "delete the folder", and moving the install
// moves the identity with it (the user's call, ADR 0066).
func (l locatedConfig) identityDir() string {
	return filepath.Join(l.dir(), tlsx.IdentityDirName)
}

// dir is the folder the relay's files go beside: the config's when one was
// read, the executable's otherwise, the working directory as a last resort.
func (l locatedConfig) dir() string {
	if l.found {
		return filepath.Dir(l.path)
	}
	if dir, err := executableDir(); err == nil {
		return dir
	}
	return "."
}

// executableDir is the directory this binary runs from. A variable so a test
// can point it at a temporary directory.
var executableDir = func() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.Dir(exe), nil
}

// resolveConfigPath decides which config.json the relay reads.
//
// An explicit -config is believed as given. Otherwise the flag's default is a
// relative name, and it is tried in the WORKING DIRECTORY first -- what every
// dev-script and every double-click-in-the-package-folder launch relies on --
// and then BESIDE THE EXECUTABLE. That second look is for a relay run as a
// service: systemd's default working directory is /, Windows' service host's is
// system32, and until 2026-09-15 such a relay read no file, said nothing about
// it, and came up on 127.0.0.1:7777 with no room code (fourth adversarial
// review, B2). Whatever is decided, the note names it -- including the two
// places that were looked at when neither had a file -- so a host who edited
// a config.json somewhere else learns that it is not the one being read.
func resolveConfigPath(flagValue string, explicit bool, exeDir func() (string, error)) locatedConfig {
	abs := func(p string) string {
		if a, err := filepath.Abs(p); err == nil {
			return a
		}
		return p
	}
	exists := func(p string) bool {
		fi, err := os.Stat(p)
		return err == nil && !fi.IsDir()
	}
	if explicit {
		if exists(flagValue) {
			return locatedConfig{path: flagValue, found: true,
				note: fmt.Sprintf("meshghost-relay: config read from %s", abs(flagValue))}
		}
		return locatedConfig{path: flagValue, found: false,
			note: fmt.Sprintf("meshghost-relay: no config file at %s (given by -config) -- using flags and "+
				"built-in defaults", abs(flagValue))}
	}
	if exists(flagValue) {
		return locatedConfig{path: flagValue, found: true,
			note: fmt.Sprintf("meshghost-relay: config read from %s", abs(flagValue))}
	}
	if dir, err := exeDir(); err == nil && !filepath.IsAbs(flagValue) {
		beside := filepath.Join(dir, filepath.Base(flagValue))
		if exists(beside) {
			return locatedConfig{path: beside, found: true,
				note: fmt.Sprintf("meshghost-relay: config read from %s (beside the executable; there is none at %s "+
					"in the working directory)", beside, abs(flagValue))}
		}
		return locatedConfig{path: flagValue, found: false,
			note: fmt.Sprintf("meshghost-relay: no config file at %s or %s -- using flags and built-in defaults. "+
				"If you edited a config.json somewhere else, that is not the one being read", abs(flagValue), beside)}
	}
	return locatedConfig{path: flagValue, found: false,
		note: fmt.Sprintf("meshghost-relay: no config file at %s -- using flags and built-in defaults", abs(flagValue))}
}

// serverSection is the raw bytes of the config file's "server" object, or nil
// if there isn't one -- the unknown-key warning has to look at what was WRITTEN
// rather than at what decoded.
func serverSection(data []byte) json.RawMessage {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return nil
	}
	// Case-insensitively, because that is how encoding/json found the section
	// it decoded: a "Server" section was applied and then never checked for
	// typos (fourth adversarial review, B7).
	for k, v := range root {
		if strings.EqualFold(k, "server") {
			return v
		}
	}
	return nil
}
