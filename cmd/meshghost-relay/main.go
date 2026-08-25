// Command meshghost-relay is the standalone relay process: it accepts
// relay-protocol connections and forwards state between clients in a room.
// See relay for the implementation and agent_docs/contract.md for
// the wire protocol.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
	// QuicAddr is where quic listens. Absent or empty is quicSharesAddrPort:
	// quic reuses listen_on's port number, so hosting means forwarding one
	// number. It must be set to a different port only when the plain "udp"
	// transport is served too, since quic is itself carried over udp and the
	// two would collide; the relay refuses to start rather than guess.
	QuicAddr *string `json:"listen_quic"`
	// TLS turns on encryption for the tcp transport: "off", "auto" (the
	// built-in default; serves TLS and plaintext on the same port) or
	// "required" (refuse plaintext). quic is always encrypted regardless
	// and plain udp can never be; this key concerns tcp only. A release
	// config ships "required"; "off" stays available so that
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
	tlsMode        *string
}

func applyFileConfig(path string, explicit map[string]bool, t configTargets) {
	// Absolute, mirroring the client (cmd/meshghost/main.go): "I edited config.json
	// and nothing changed" is nearly always a different config.json than the one
	// being read, and a relative path in the log answers that with another question.
	shown := path
	if abs, err := filepath.Abs(path); err == nil {
		shown = abs
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("meshghost-relay: warning: could not read config file %s: %v", shown, err)
		}
		return
	}
	data = cfg.StripBOM(data, shown, "meshghost-relay")
	if data == nil {
		return
	}
	// An empty file is "nothing configured", not a broken config. Without this,
	// json.Unmarshal returns "unexpected end of JSON input" and the warning below
	// tells the operator every setting is being IGNORED -- which reads like a
	// broken install and is not true, since there was nothing in it to ignore.
	// Reachable in the ordinary way on Windows: `-config nul` is how a dev script
	// says "no config", and os.ReadFile("nul") succeeds with zero bytes rather
	// than failing os.IsNotExist.
	if len(bytes.TrimSpace(data)) == 0 {
		return
	}
	var rc rootConfig
	if err := json.Unmarshal(data, &rc); err != nil {
		if !cfg.ApplyDespiteBadValue(err, shown, "meshghost-relay") {
			return
		}
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
	cfg.Override(explicit, "tls", t.tlsMode, sc.TLS)
}

// FallbackQuicAddr is where quic goes when it cannot share -addr's port,
// which happens only when the plain udp transport is also being served and
// has taken that udp port first.
//
// 7778 and 7779 are both skipped because packaging/release/README.txt
// already hands those out as local bridge ports (7778 normally, 7779 for a
// second copy on the same machine). Neither would actually collide -- the
// bridge is TCP and this is UDP, which are separate port spaces -- but a
// reader comparing two config files should not have to know that to tell
// whether something is a typo.
const FallbackQuicAddr = "127.0.0.1:7780"

// quicSharesAddrPort is the -listen-quic default: empty means "use -addr's
// port". quic is carried over udp and tcp/udp are separate port spaces, so
// tcp:7777 and quic:7777/udp coexist happily.
//
// This is a NAT decision rather than a tidiness one. Serving quic by default
// (see the transport ADR in agent_docs/architecture.md) would otherwise have
// turned hosting from "forward 7777" into "forward 7777 and 7780", and the
// port-forwarding step is where a host actually gives up. Sharing the number
// makes it "forward 7777, TCP and UDP" -- one rule in most router UIs.
//
// The plain udp transport is the one thing that cannot coexist here, since
// it takes -addr's udp port itself. It is opt-in, unencryptable and
// deliberately last in netx.AutoPreference, so it is the right one to carry
// the awkwardness: asking for udp and quic together requires naming a port
// for quic, and the startup error says so.
const quicSharesAddrPort = ""

func main() {
	addr := flag.String("addr", "127.0.0.1:7777", "address to listen on (tcp and udp; quic uses -listen-quic)")
	loopback := flag.Bool("loopback", false, "dev-only Phase 3 flag: echo each client's own "+
		"state back to it under a synthetic <id>-ghost player_id, so a single client exercises "+
		"a real core->relay->core round trip. Never enable this outside dev/testing.")
	roomCode := flag.String("room-code", "", "shared secret clients must send to join a room -- "+
		"leave empty to run open (anyone with the address can join, the pre-existing default); "+
		"see agent_docs/architecture.md's room-code ADR for what this does and doesn't defend "+
		"against (no TLS: the code crosses the wire in plaintext)")
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
	ghostCollision := flag.String("ghost-collision", "",
		"room-wide ghost collision policy advertised to every client: \"enabled\" "+
			"(each adapter's own defaults stand) or \"disabled\" (no ghost blocks "+
			"anything, in any game). Empty means enabled. Advisory: shipped adapters "+
			"honor it, but this relay cannot verify that they did")
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
	transportNames := flag.String("transport", "tcp,quic",
		"which transports to serve, comma-separated: any of tcp, udp, quic. Serving several at "+
			"once is fine and clients may mix freely within one room -- tcp is readable with "+
			"netcat for debugging, udp survives a lossy connection better but CANNOT be "+
			"encrypted (Go has no DTLS), and quic is encrypted and spoofing-resistant by "+
			"default. The default serves tcp and quic so a default client (-transport auto) "+
			"gets an encrypted session without anyone configuring anything -- but note quic "+
			"needs -listen-quic's port forwarded too, not just -addr's")
	quicAddr := flag.String("listen-quic", quicSharesAddrPort,
		"address to serve quic on. Empty (the default) means share -addr's port -- quic runs "+
			"over udp and tcp/udp are separate port spaces, so tcp:7777 and quic:7777/udp "+
			"coexist and a host forwards ONE port number for both. Only the plain udp transport "+
			"cannot share it, since udp takes -addr's udp port itself; serving udp and quic "+
			"together therefore needs a port named here (e.g. "+FallbackQuicAddr+"). Ignored "+
			"unless quic is in -transport")
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
	// is the plain udp transport. Refused rather than silently relocated: a
	// relay that quietly moved quic somewhere else would advertise a port the
	// host never forwarded, and the failure would surface much later as
	// "quic clients can't connect" with nothing pointing here.
	servesUDP, servesQUIC := false, false
	for _, k := range kinds {
		switch k {
		case netx.UDP:
			servesUDP = true
		case netx.QUIC:
			servesQUIC = true
		}
	}
	if servesQUIC && *quicAddr == quicSharesAddrPort {
		if servesUDP {
			log.Fatalf("meshghost-relay: serving both udp and quic needs a port for quic: udp has "+
				"already taken %s's udp port, and quic runs over udp too. Pass -listen-quic "+
				"(e.g. %s), or drop udp from -transport -- it cannot be encrypted and nothing "+
				"picks it automatically.", *addr, FallbackQuicAddr)
		}
		*quicAddr = *addr
	}

	// One listener per selected transport, all feeding the same Server.
	// relay.Serve takes any net.Listener and handleConn any net.Conn, so
	// nothing in relay knows or cares which is which -- and a
	// single room can hold clients arriving over different transports,
	// because Room.Forward sends through the transport.Transport interface.
	type boundListener struct {
		kind netx.Kind
		ln   net.Listener
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

	var listeners []boundListener
	for _, k := range kinds {
		bind := *addr
		if k == netx.QUIC {
			bind = *quicAddr
		}
		ln, err := netx.ListenWithTLS(k, bind, tlsOpts)
		if err != nil {
			log.Fatalf("meshghost-relay: listen %s on %s: %v", k, bind, err)
		}
		listeners = append(listeners, boundListener{kind: k, ln: ln})
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
		if servesUDP {
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
			"(set server.ghost_collision to \"disabled\" to turn it off room-wide)")
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
	log.Fatalf("meshghost-relay: serve: %v", <-serveErr)
}
