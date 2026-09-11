// Command meshghost-relay is the standalone relay process: it accepts
// relay-protocol connections and forwards state between clients in a room.
// See relay for the implementation and agent_docs/contract.md for
// the wire protocol.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/cfg"
	"github.com/Tsukino-uwu/MeshGhost/netx"
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
	// any of "tcp", "udp", "quic". Absent means "tcp,quic". Clients pick one of
	// them; a room can hold clients on different transports simultaneously,
	// since the relay forwards through the transport.Transport interface and
	// never learns which is which. See the transport ADR in
	// agent_docs/architecture.md.
	Transport *string `json:"transport"`
	// QuicAddr is where quic listens. Absent or empty is sharesAddrPort:
	// quic reuses listen_on's port number, so hosting means forwarding one
	// number. quic KEEPS that number even when the plain "udp" transport is
	// served alongside it -- udp is the one that moves, since quic is a default
	// transport and udp is opt-in. See UDPAddr and FallbackUDPAddr.
	QuicAddr *string `json:"listen_quic"`
	// UDPAddr is where the plain "udp" transport listens. Absent or empty is
	// sharesAddrPort, which means listen_on's port -- except when quic is
	// served too, where udp moves to FallbackUDPAddr so quic can keep the
	// shared number. Set it explicitly to place udp yourself.
	UDPAddr *string `json:"listen_udp"`
	// TLS turns on encryption for the tcp transport: "off", "auto" (the
	// built-in default; serves TLS and plaintext on the same port) or
	// "required" (refuse plaintext). quic is always encrypted regardless
	// and plain udp can never be; this key concerns tcp only. Both binaries
	// default to "auto" and a release config ships it (packaging/release/
	// config.json:62), which cmd/meshghost/shippedconfig_test.go pins; "off"
	// stays available so that
	// netcat, a packet capture and cmd/meshghost-netsim keep working
	// while a session is being debugged. See the TLS-over-tcp ADR in
	// agent_docs/architecture.md.
	TLS *string `json:"tls"`
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
	tlsMode        *string
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
		cfg.WarnUnknownKeys(section, fileConfig{}, shown, "meshghost-relay", "server")
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
	cfg.Override(explicit, "tls", t.tlsMode, sc.TLS)
}

// FallbackUDPAddr is where the plain udp transport goes when it cannot share
// -addr's udp port, which happens when quic is also being served -- quic runs
// over udp too, and the two would collide on one number.
//
// **udp is the one that moves, and that is the whole point.** quic is a DEFAULT
// transport (-transport is "tcp,quic"), so a host who never thought about
// transports is serving it; plain udp is opt-in, unencryptable, and last in
// netx.AutoPreference. Making the default transport surrender the shared port to
// an opt-in one had it backwards -- it broke "forward 7777" for the common case
// to accommodate the rare one. Corrected 2026-08-27 after the user pointed out
// that tcp and quic are supposed to share while udp takes the odd port.
//
// 7778 and 7779 are both skipped because packaging/release/README.txt already
// hands those out as local bridge ports (7778 normally, 7779 for a second copy
// on the same machine). Neither would actually collide -- the bridge is TCP and
// this is UDP, which are separate port spaces -- but a reader comparing two
// config files should not have to know that to tell whether something is a typo.
//
// **Only the PORT relocates. The bind interface is always -addr's** -- see
// relocatedUDPAddr. Every paragraph above justifies the port and none of them
// ever addressed the host, and until 2026-09-08 this whole string was returned
// wholesale: a host running `-addr 0.0.0.0:7777 -transport tcp,udp,quic` bound
// udp on loopback, unreachable from anywhere but that machine, while the startup
// banner told them to forward 7780 and the relay advertised udp:7780 to remote
// clients who resolved it against the address they had dialled and failed.
const FallbackUDPPort = "7780"

// FallbackUDPAddr is what the relocation lands on for the DEFAULT -addr
// (127.0.0.1:7777), which is what the -listen-udp help text quotes. It is an
// example of the rule, not the rule: the rule is FallbackUDPPort on -addr's own
// host, and a relay bound to 0.0.0.0 relocates udp to 0.0.0.0:7780.
const FallbackUDPAddr = "127.0.0.1:" + FallbackUDPPort

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

// resolveUDPAddr decides where the plain udp transport listens.
//
// It is the mirror of resolveQuicAddr and carries the actual conflict rule: quic
// keeps -addr's port because it is a default transport, and udp -- opt-in,
// unencryptable, last in netx.AutoPreference -- moves aside when both are served.
//
// Relocating udp silently is safe in a way relocating quic never was: nothing
// picks udp automatically, so the only way to be on it is to have asked for it by
// name, and the startup log prints the port it landed on. A host who did not ask
// for udp is unaffected, and one who did is reading the log they asked for.
func resolveUDPAddr(kinds []netx.Kind, addr, udpAddr string) (string, error) {
	if !servesKind(kinds, netx.UDP) {
		// Not serving udp: -listen-udp is irrelevant and passed through untouched,
		// the same way -listen-quic is when quic is off.
		return udpAddr, nil
	}
	if udpAddr != sharesAddrPort {
		// Explicitly placed by the operator. Believed without further checking:
		// naming a port is the act of taking responsibility for forwarding it.
		return udpAddr, nil
	}
	if servesKind(kinds, netx.QUIC) {
		return relocatedUDPAddr(addr), nil
	}
	return addr, nil
}

// relocatedUDPAddr moves udp off -addr's port and nowhere else: same bind
// interface, FallbackUDPPort instead of the port. This is the shape
// resolveQuicAddr next door has always had -- it returns addr, so it inherits
// whatever interface the operator chose -- and the shape resolveUDPAddr lacked
// until 2026-09-08, when it returned the whole of FallbackUDPAddr and threw the
// operator's bind interface away with the port. A host who typed
// `-addr 0.0.0.0:7777` got a udp listener nobody outside the machine could
// reach, plus a startup banner telling them to forward a port that would never
// carry anything.
//
// An -addr with no port at all (or otherwise unsplittable) keeps the old
// constant. It is not a shape this binary can bind anyway -- netx.ListenWithTLS
// gets the same string and fails -- so this is about not inventing a second
// error path for input that is already about to be refused with its own message.
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

func relocatedUDPAddr(addr string) string {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return FallbackUDPAddr
	}
	return net.JoinHostPort(host, FallbackUDPPort)
}

func main() {
	addr := flag.String("addr", "127.0.0.1:7777", "address to listen on (tcp, and quic unless -listen-quic says otherwise; plain udp moves to -listen-udp's port when quic is also served)")
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
		"which transports to serve, comma-separated: any of tcp, udp, quic. Serving several at "+
			"once is fine and clients may mix freely within one room -- tcp is readable with "+
			"netcat for debugging, udp survives a lossy connection better but CANNOT be "+
			"encrypted (Go has no DTLS), and quic is encrypted and spoofing-resistant by "+
			"default. The default serves tcp and quic so a default client (-transport auto) "+
			"gets an encrypted session without anyone configuring anything -- but note quic "+
			"needs -listen-quic's port forwarded too, not just -addr's")
	udpAddr := flag.String("listen-udp", sharesAddrPort,
		"where the plain udp transport listens. Empty (the default) means -addr's port -- except "+
			"when quic is served too, where udp moves to port "+FallbackUDPPort+" on -addr's own "+
			"interface (so a relay on 0.0.0.0:7777 serves udp on 0.0.0.0:"+FallbackUDPPort+") and "+
			"quic keeps the shared number. quic is a default transport and plain udp is opt-in, so "+
			"udp is the one that takes the odd port. Ignored unless udp is in -transport")
	quicAddr := flag.String("listen-quic", sharesAddrPort,
		"address to serve quic on. Empty (the default) means share -addr's port -- quic runs "+
			"over udp and tcp/udp are separate port spaces, so tcp:7777 and quic:7777/udp "+
			"coexist and a host forwards ONE port number for both. quic KEEPS that port even "+
			"when the plain udp transport is served alongside it: udp is the opt-in one, so udp "+
			"moves to -listen-udp's port instead. Ignored unless quic is in -transport")
	tlsMode := flag.String("tls", tlsx.Auto.String(),
		"encrypt the tcp transport: auto (the default), off, or required. \"auto\" serves TLS "+
			"and plaintext on the SAME port -- a TLS ClientHello and an NDJSON line are told "+
			"apart by their first byte -- so encrypted clients are protected while netcat still "+
			"works for debugging. \"required\" closes any connection that is not encrypted, "+
			"which is the only MeshGhost setting a stale client cannot silently ignore. This "+
			"matters even for quic sessions: every client handshakes over tcp first and that "+
			"handshake carries the room code. The certificate is self-signed, generated in "+
			"memory and never written to disk, so this stops someone READING the network, not "+
			"someone actively impersonating this relay -- unless you hand players the "+
			"fingerprint printed below at startup and they set \"tls_fingerprint\"")
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file with a \"server\" section "+
			"({\"listen_on\": \"...\", \"listen_quic\": \"...\", \"room_code\": \"...\", "+
			"\"only_game\": \"...\", \"transport\": \"...\", "+
			"\"max_clients\": ..., \"send_hz\": ..., \"resume_grace_seconds\": ...}) -- a friendlier alternative to flags for "+
			"non-developer use; "+
			"silently ignored if it doesn't exist; a flag passed explicitly on the command line "+
			"overrides the same field from this file")
	flag.Parse()

	// Tee'd with stderr, unlike the client: a relay is normally watched in the
	// window it was launched from, so its log file is a second copy rather than
	// the only one. cfg.OpenLogFile returns just the file (nil on failure) and
	// leaves that composition here, because the two binaries genuinely differ.
	logOut := io.Writer(os.Stderr)
	if f := cfg.OpenLogFile("meshghost-server.log", "meshghost-relay"); f != nil {
		logOut = io.MultiWriter(os.Stderr, f)
	}
	log.SetOutput(logOut)

	explicit := cfg.ExplicitFlags()
	applyFileConfig(*configPath, explicit, configTargets{
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
		tlsMode:        tlsMode,
	})

	// Fatal on an unrecognized tls mode, same reasoning as the transport
	// list below: tlsx.Off is the zero value, so a lenient parse would hand
	// an operator who asked for "requried" a relay that quietly accepts
	// plaintext.
	tlsChoice, err := tlsx.ParseMode(*tlsMode)
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

	// Resolve where quic listens, now that the transport list is known.
	//
	// Sharing -addr's port is the default because it keeps hosting to one
	// forwarded port number; the only thing that can take that udp port away
	// is the plain udp transport. When both are served QUIC KEEPS the shared
	// port and plain udp is what relocates, to FallbackUDPAddr -- that way the
	// port an operator forwarded is the one quic still advertises. Moving quic
	// instead would surface much later as "quic clients can't connect" with
	// nothing pointing here.
	resolvedUDP, err := resolveUDPAddr(kinds, *addr, *udpAddr)
	if err != nil {
		log.Fatalf("meshghost-relay: %v", err)
	}
	*udpAddr = resolvedUDP

	resolvedQuic, err := resolveQuicAddr(kinds, *addr, *quicAddr)
	if err != nil {
		log.Fatalf("meshghost-relay: %v", err)
	}
	*quicAddr = resolvedQuic

	// One listener per selected transport, all feeding the same Server.
	// relay.Serve takes any net.Listener and handleConn any net.Conn, so
	// nothing in relay knows or cares which is which -- and a
	// single room can hold clients arriving over different transports,
	// because Room.Forward sends through the transport.Transport interface.
	type boundListener struct {
		kind netx.Kind
		ln   *trackingListener
	}
	// One certificate for the whole process, generated once. Per-connection
	// generation would be a free CPU lever for an unauthenticated stranger,
	// and a per-listener one would print two different fingerprints for one
	// relay.
	var tlsOpts netx.TLSOptions
	var fingerprint string
	if tlsChoice != tlsx.Off {
		cfg, fp, err := tlsx.ServerConfig(netx.TLSALPN)
		if err != nil {
			log.Fatalf("meshghost-relay: tls: %v", err)
		}
		tlsOpts = netx.TLSOptions{Mode: tlsChoice, Server: cfg}
		fingerprint = fp
	}

	// Whatever the TLS mode, every listener gets the open-connection bound
	// (relay.MaxOpenConnsFor); the log line it prints is rate-limited.
	tlsOpts.MaxOpenConns = relay.MaxOpenConnsFor(*maxClients)

	var listeners []boundListener
	for _, k := range kinds {
		bind := *addr
		if k == netx.QUIC {
			bind = *quicAddr
		}
		if k == netx.UDP {
			bind = *udpAddr
		}
		ln, err := netx.ListenWithTLS(k, bind, tlsOpts)
		if err != nil {
			log.Fatalf("meshghost-relay: listen %s on %s: %v", k, bind, err)
		}
		// Wrapped so Ctrl+C can reach the connections this listener handed
		// out: closing a listener does NOT close them (quic-go's Listener.Close
		// says so in as many words, and quic is the shipped default), and a
		// client whose relay simply vanishes waits out its own idle timeout.
		listeners = append(listeners, boundListener{kind: k, ln: trackConns(ln)})
		label := k.String()
		if k == netx.TCP && tlsChoice != tlsx.Off {
			label = fmt.Sprintf("%s, tls %s", k, tlsChoice)
		}
		log.Printf("meshghost-relay: listening on %s (%s)", ln.Addr(), label)
	}

	// Say what encryption is and is not doing, in the log the host actually
	// reads, rather than leaving it to a document. The fingerprint is the
	// ONLY thing here that authenticates this relay, and only if a player
	// copies it -- so it is printed with the instruction attached.
	switch tlsChoice {
	case tlsx.Off:
		if *roomCode != "" {
			log.Printf("meshghost-relay: NOTE: tls is off, so the room code crosses the network " +
				"readable on the tcp handshake every client makes -- including clients that then " +
				"move to quic. Set \"tls\": \"required\" in config.json (or -tls required) to " +
				"encrypt it.")
		}
	default:
		log.Printf("meshghost-relay: tls %s on the tcp transport (quic is always encrypted; plain udp never is)", tlsChoice)
		log.Printf("meshghost-relay: tls certificate fingerprint: %s", fingerprint)
		log.Printf("meshghost-relay: this certificate is self-signed and regenerated every " +
			"restart. Encryption alone stops someone READING the traffic, not someone " +
			"impersonating this relay. To close that too, send players the fingerprint above " +
			"by some other means (not through this relay) and have them set \"tls_fingerprint\" " +
			"in their config.json -- they will need the new one after every restart.")
		if servesKind(kinds, netx.UDP) {
			log.Printf("meshghost-relay: WARNING: the plain udp transport is being served and " +
				"CANNOT be encrypted (Go has no DTLS). A client that chooses udp is unencrypted " +
				"no matter what tls says. Drop udp from -transport if that matters.")
		}
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
	server.RoomCode = *roomCode
	// Trimmed because this is normally hand-typed into config.json and a
	// stray space would otherwise refuse every client for no visible
	// reason. Deliberately not lower-cased or otherwise normalized -- that
	// would diverge from the exact-equality game_id comparison every other
	// use site (joinOrCreateRoom, the adapters) already relies on.
	server.OnlyGame = strings.TrimSpace(*onlyGame)
	server.Offers = offers
	server.MaxClients = *maxClients
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
	if *roomCode == "" {
		log.Printf("meshghost-relay: WARNING: no room code configured -- anyone who has this " +
			"relay's address can join any room. Set -room-code (or \"room_code\" in config.json) " +
			"before exposing this relay beyond a friend you directly hand the address to.")
	} else {
		log.Printf("meshghost-relay: room-code auth enabled")
	}
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

	select {
	case err := <-serveErr:
		log.Fatalf("meshghost-relay: serve: %v", err)
	case sig := <-stop:
		// A SECOND Ctrl+C must kill immediately. Restoring the default handler
		// before doing any work is what makes that true: a host whose shutdown
		// is taking longer than they expected can always press it again, and
		// the alternative -- an interrupt landing in a buffered channel nobody
		// reads -- is a relay that appears to ignore Ctrl+C entirely.
		signal.Reset(os.Interrupt, syscall.SIGTERM)
		log.Printf("meshghost-relay: %v -- shutting down", sig)
		lns := make([]*trackingListener, 0, len(listeners))
		for _, bl := range listeners {
			lns = append(lns, bl.ln)
		}
		n := shutdown(lns, shutdownDrain)
		log.Printf("meshghost-relay: closed %d listener(s) and %d client connection(s) -- goodbye",
			len(lns), n)
	}
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
	for _, c := range open {
		if cw, ok := c.(interface{ CloseWrite() error }); ok {
			if err := cw.CloseWrite(); err == nil {
				continue
			}
		}
		_ = c.Close()
	}
	return len(open)
}

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

// serverSection is the raw bytes of the config file's "server" object, or nil
// if there isn't one -- the unknown-key warning has to look at what was WRITTEN
// rather than at what decoded.
func serverSection(data []byte) json.RawMessage {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return nil
	}
	return root["server"]
}
