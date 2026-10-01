// Command meshghost-relay is the standalone relay process: it accepts relay-protocol connections and forwards state
// between clients in a room. Package relay is the implementation.
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

// fileConfig is the "server" section of the optional JSON config file (see -config), mirroring cmd/meshghost's own.
// "listen_on" rather than "addr" reads as the opposite of the client's "connect_to".
type fileConfig struct {
	Addr     *string `json:"listen_on"`
	RoomCode *string `json:"room_code"`
	// OnlyGame restricts this relay to a single game_id; absent or empty hosts any game.
	OnlyGame   *string `json:"only_game"`
	MaxClients *int    `json:"max_clients"`
	// SendHz is the room-wide state send rate this relay advertises; absent or 0 means protocol.DefaultSendHz.
	SendHz *int `json:"send_hz"`
	// GhostCollision is the room-wide ghost-collision policy this relay advertises, "disabled" (the default) or
	// "enabled". Advisory: the relay cannot verify an adapter honoured it.
	GhostCollision *string `json:"ghost_collision"`
	// ResumeGraceSeconds is how long this relay holds a dropped client's identity (player_id, leases, in-flight
	// exchanges) for a reconnect before telling the room it left; absent or 0 means protocol.DefaultResumeGrace. Only
	// a room that negotiated resume.v1 uses it. Longer hides a flaky connection, and keeps a departed player's keys
	// locked longer.
	ResumeGraceSeconds *int `json:"resume_grace_seconds"`
	// Transport is a comma-separated list of transports to serve at once, "tcp", "quic" or both; absent means
	// "tcp,quic". One room can mix transports, since the relay forwards through transport.Transport. "udp" is refused
	// by name except in the meshghost_devudp build.
	Transport *string `json:"transport"`
	// QuicAddr is where quic listens; absent or empty is sharesAddrPort, listen_on's own port number.
	QuicAddr *string `json:"listen_quic"`
	// UDPAddr is where plain udp listens in the dev build. A release still decodes it so an old config's empty value
	// is not an unknown key; a non-empty one refuses to start (checkUDPConfig).
	UDPAddr *string `json:"listen_udp"`
	// TLS is the obsolete switch: every connection is TLS. Still decoded so an old config's key is judged by
	// checkLegacyTLSKey rather than reported unknown.
	TLS *string `json:"tls"`
	// QLog turns on quic-go's per-connection qlog trace, into the directory QLOGDIR names. Dev diagnostics.
	QLog *bool `json:"qlog"`
}

// rootConfig is the top-level shape of the config file: a "server" section read by this binary, beside the "client"
// section cmd/meshghost reads from the same file.
type rootConfig struct {
	Server *fileConfig `json:"server"`
}

// configTargets are the flag-backed variables applyFileConfig may overwrite, mirroring cmd/meshghost's own: a struct
// keeps each field's name at the call site.
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
	// Unlike the client, a missing file is silent: a relay is run deliberately from a console, with no player to
	// reassure.
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
	// A key that is not a setting is a typo doing nothing; checked within "server" only, as the root also carries
	// the client's section.
	if section := serverSection(data); section != nil {
		// nil: nothing but this binary reads "server", so every unknown key in it is a typo.
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

// sharesAddrPort is the default for -listen-quic and -listen-udp: empty means -addr's port. quic runs over udp, a
// port space apart from tcp, so tcp:7777 and quic on udp:7777 coexist and hosting stays one forwarded number, the step
// where a host actually gives up. Plain udp wants that same udp port, so when both are served udp moves to
// FallbackUDPPort and quic keeps the shared number.
const sharesAddrPort = ""

func servesKind(kinds []netx.Kind, k netx.Kind) bool {
	for _, got := range kinds {
		if got == k {
			return true
		}
	}
	return false
}

// resolveQuicAddr decides where quic listens: by default on -addr's port, which keeps hosting to one forwarded
// number, even when plain udp is served too. It never refuses: every return has a nil error.
func resolveQuicAddr(kinds []netx.Kind, addr, quicAddr string) (string, error) {
	if !servesKind(kinds, netx.QUIC) {
		// Not serving quic: -listen-quic passes through untouched; its help says it is ignored.
		return quicAddr, nil
	}
	if quicAddr != sharesAddrPort {
		// Placed by the operator, and believed: naming a port is taking responsibility for forwarding it.
		return quicAddr, nil
	}
	return addr, nil
}

// roomCodeFlagHelp is -room-code's help text, at package level so a test can assert it. It names config.json first
// and says why: a flag value is the process command line, which any local process reads without elevation (WMI on
// Windows, /proc/<pid>/cmdline on Linux) and which lands in the shell history. The flag stays for scripted relays.
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
	// -listen-udp exists only in the dev build; a release registers no such flag and udpAddr stays empty.
	udpAddr := udpListenFlag()
	quicAddr := flag.String("listen-quic", sharesAddrPort,
		"address to serve quic on. Empty (the default) means share -addr's port -- quic runs "+
			"over udp and tcp/udp are separate port spaces, so tcp:7777 and quic:7777/udp "+
			"coexist and a host forwards ONE port number for both. Ignored unless quic is in "+
			"-transport")
	// No -tls flag: every connection is TLS. The obsolete config key is still read into this, to be judged.
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

	// Decided before the log opens, because the log goes beside the config.
	located := resolveConfigPath(*configPath, explicit["config"], executableDir)

	// Tee'd with stderr, unlike the client: a relay is normally watched in the window it was launched from, so its
	// log file is a second copy.
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
	// The flag values before the file: what every re-read starts from, so a key removed from the file falls back here.
	base := snapshotRelayLive(targets)
	applyFileConfig(located.path, explicit, targets)
	// The listen addresses as the file says them, before they are resolved below, to seed the watcher.
	fileQuicAddr, fileUDPAddr := *quicAddr, *udpAddr
	if *qlog {
		quicconn.SetQLog(true)
		log.Printf("meshghost-relay: qlog tracing ON for every quic connection -- traces go to QLOGDIR=%q "+
			"(empty means quic-go writes nothing); this is a dev diagnostic, not for a public relay",
			os.Getenv("QLOGDIR"))
	}

	if note, err := checkLegacyTLSKey(*legacyTLS); err != nil {
		log.Fatalf("meshghost-relay: %v", err)
	} else if note != "" {
		log.Printf("meshghost-relay: %s", note)
	}

	// One key pair and certificate, persisted beside the config so a client recognizes this relay after a restart. A
	// broken identity is fatal here, before any listener opens.
	identityDir := located.identityDir()
	identity, fingerprint, err := tlsx.LoadOrCreateIdentity(identityDir, netx.TLSALPN)
	if err != nil {
		log.Fatalf("meshghost-relay: %v", err)
	}

	// Fatal rather than falling back: netx.Kind's zero value is tcp, so a lenient parse would hand an operator who
	// asked for quic a different transport.
	kinds, err := netx.ParseKinds(*transportNames)
	if err != nil {
		log.Fatalf("meshghost-relay: %v", err)
	}

	if err := checkUDPConfig(*udpAddr); err != nil {
		log.Fatalf("%v", err)
	}

	// quic keeps the shared port and plain udp relocates, so the port an operator forwarded is the one quic
	// advertises; moving quic would surface much later as clients unable to connect.
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

	// What a client with transport "auto" is told, built from the listeners that came up, so a transport that failed
	// to bind is never offered. Only the port is sent: the client already knows the host, which works through NAT.
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

	// The forwarding decides whether anyone can connect, and only the host needs it. The protocol is named per line:
	// tcp/7777 and udp/7777 are separate rules on most routers, and quic is udp.
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
	// Trimmed, as only_game is: hand-typed into config.json, a trailing space would refuse every client. Never
	// otherwise normalized: a code is a secret, and the client sends it as typed.
	server.RoomCode = strings.TrimSpace(*roomCode)
	*roomCode = server.RoomCode
	server.SourceGuard = sources
	// The room-code proof binds to this relay's certificate: a client's proof names the fingerprint it verified, so
	// it fails against anyone presenting another certificate.
	server.PakeIdentity = fingerprint
	// Trimmed, but not lower-cased: game_id is compared by exact equality everywhere else.
	server.OnlyGame = strings.TrimSpace(*onlyGame)
	server.Offers = offers
	// The enforced value, so the banner below and tryReserveSlot agree: a configured 0 means the default.
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
	// Clamp and warn rather than refuse: a typo in a cosmetic knob must not stop a host booting. The server clamps
	// the same way, so this log is the operator's only view of the rate advertised.
	effectiveSendHz := protocol.ClampSendHz(*sendHz)
	if effectiveSendHz != *sendHz {
		log.Printf("meshghost-relay: warning: send_hz %d is outside the supported %d-%d range, using %d",
			*sendHz, protocol.MinSendHz, protocol.MaxSendHz, effectiveSendHz)
	}
	log.Printf("meshghost-relay: room send rate: %dHz (per-client message cap: %d/sec)",
		effectiveSendHz, relay.MaxMessagesPerSecondFor(effectiveSendHz))
	// Say what was read: anything unrecognized normalizes to "disabled", so a typo would quietly change the policy.
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
	// Echo the value: a typo'd game_id refuses every client with no other visible cause.
	if server.OnlyGame == "" {
		log.Printf("meshghost-relay: hosting any game (no \"only_game\" set)")
	} else {
		log.Printf("meshghost-relay: restricted to game_id %q -- clients playing any other game will be refused",
			server.OnlyGame)
	}
	// config.json stays live from here for room_code, only_game and max_clients. The seed is taken after main
	// trimmed the code, so the first diff sees what is actually live.
	watchStop := make(chan struct{})
	defer close(watchStop)
	go newRelayConfigWatcher(located.path, explicit, base, watcherSeed(targets, fileQuicAddr, fileUDPAddr), server).run(watchStop)
	log.Print(describeRelayReloadable(located.path))

	// Any listener dying is fatal rather than limping on the rest, which would leave some clients able to connect
	// and others not.
	serveErr := make(chan error, len(listeners))
	for _, bl := range listeners {
		go func(bl boundListener) {
			serveErr <- fmt.Errorf("%s: %w", bl.kind, server.Serve(bl.ln))
		}(bl)
	}

	// An interrupt shuts down with a goodbye: a killed process sends nothing on quic, the shipped default, and every
	// client would wait out its idle timeout.
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

// awaitShutdown blocks until a listener dies or a signal arrives, then takes every listener and client down the same
// way in both cases, so a relay that dies says goodbye as one that is stopped does. It returns the listener's error
// (nil for a signal) and how many client connections were told to go.
func awaitShutdown(serveErr <-chan error, stop <-chan os.Signal, lns []*trackingListener, drain time.Duration) (error, int) {
	select {
	case err := <-serveErr:
		return err, shutdown(lns, drain)
	case sig := <-stop:
		// Restoring the default handler first makes a second Ctrl+C kill at once, rather than land in a channel
		// nobody reads.
		signal.Reset(os.Interrupt, syscall.SIGTERM)
		log.Printf("meshghost-relay: %v -- shutting down", sig)
		return nil, shutdown(lns, drain)
	}
}

// shortRoomCodeLen is the length below which the startup line warns: at one guess a second per address
// (relay.RoomCodeAttemptsPerSecond), eight printable-ASCII characters is where a few addresses can no longer walk
// through a code in a session. Reasoned, not measured against an attacker.
const shortRoomCodeLen = 8

// roomCodeStartupNotice is the one line the host reads about their room code, a function so a test can check it.
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

// boundListener is one served transport: its kind, and the listener that tracks the connections it hands out.
type boundListener struct {
	kind netx.Kind
	ln   *trackingListener
}

type listenerConfig struct {
	kinds                   []netx.Kind
	addr, quicAddr, udpAddr string
	// identity is the relay's one certificate, served on tcp and quic alike. Required.
	identity   *tls.Config
	maxClients int
	// sources is the per-address table; nil means no per-source bound, which only a test asks for.
	sources *srclimit.Table
}

// newSourceTable is the one per-address table a relay process keeps: the connection cap per address for every
// listener, and the wrong-room-code budget. In memory, bounded, never logged.
func newSourceTable(maxClients int) *srclimit.Table {
	return srclimit.New(srclimit.Options{
		MaxOpenPerSource:    relay.MaxOpenConnsPerSourceFor(maxClients),
		AuthBurst:           relay.RoomCodeAttemptBurst,
		AuthRefillPerSecond: relay.RoomCodeAttemptsPerSecond,
	})
}

// buildListeners brings up one listener per selected transport, wrapped as the shipped relay wraps them: the
// open-connection limiter, then TLS (tcp only), then connection tracking. A function so a test can drive a hostile
// client through the same stack a stranger meets. All listeners feed one Server, which never learns which transport
// a client came over. On error, every listener already opened is closed again.
func buildListeners(c listenerConfig) ([]boundListener, error) {
	if c.identity == nil {
		return nil, errors.New("no relay identity to serve")
	}
	// One certificate on every listener: one per listener would give a relay two fingerprints, and a client moving
	// from tcp to quic would warn about its own relay.
	tlsOpts := netx.TLSOptions{Server: c.identity}

	tlsOpts.MaxOpenConns = relay.MaxOpenConnsFor(c.maxClients)
	// The per-address half, one table shared by every listener so an address is one source on any transport; the
	// same table is the relay's room-code guard.
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
		// Tracked so shutdown can reach the connections: closing a listener does not close them (quic-go's
		// Listener.Close says so), and a client whose relay vanishes waits out its own idle timeout.
		listeners = append(listeners, boundListener{kind: k, ln: trackConns(ln)})
		label := k.String()
		if k == netx.TCP {
			label = "tcp, tls"
		}
		log.Print(listeningLine(ln.Addr(), label))
	}
	return listeners, nil
}

// checkLegacyTLSKey judges the obsolete "tls" config key. Empty is nothing. A value that asked for plaintext is an
// error, since a security setting is never silently given another meaning; one that asked for what is now always
// true runs with a note to delete the key; an unknown word is an error.
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

// listeningLine is the "listening on" line, naming the address family the socket covers: Go binds a wildcard,
// "0.0.0.0" included, as a dual-stack IPv6 socket where the OS allows it (Linux, Windows), so a host who firewalled
// only IPv4 would have an IPv6 side open.
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

// shutdownDrain is how long shutdown keeps the process alive after telling the clients to go, before exit reclaims
// the sockets. Nothing is expected back: it is the time a goodbye needs to leave. It is well under the core's ghost
// age-out (core.DefaultRemoteStaleAfter), so restarting a relay costs a player no extra despawn.
const shutdownDrain = time.Second

// shutdown stops accepting, then tells every connected client to go, and returns how many connections it spoke to.
// The listeners close first so a client reconnecting during the drain is refused by the OS. Each connection is
// half-closed where it can be, a FIN behind the last write, and closed where not, so a client learns in one round
// trip instead of waiting out an idle timeout.
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

// trackingListener remembers the connections a listener has handed out, so shutdown can reach them: closing a tcp or
// quic-go listener leaves its accepted connections open, and quic is what a default relay and client negotiate.
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
	// The wrapper forgets the connection when it closes. Embedding net.Conn as an interface hides every method
	// net.Conn does not declare, so the optional methods the codebase type-asserts for are forwarded below, and
	// WriteUnreliable gets its own type so it stays absent where there is no datagram plane.
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

// closeClients half-closes (or closes) every connection still open on this listener and returns how many there were.
// It snapshots under the lock and closes outside it: closing calls back into forget, which takes the same mutex.
func (t *trackingListener) closeClients() int {
	t.mu.Lock()
	open := make([]net.Conn, 0, len(t.conns))
	for c := range t.conns {
		open = append(open, c)
	}
	t.conns = map[net.Conn]struct{}{}
	t.mu.Unlock()
	// In parallel under one deadline: a half-close writes, and a stalled member would otherwise hold the goodbye for
	// everyone behind it. One that cannot half-close in time is closed hard.
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

// closeClientsDeadline bounds one client's half-close during shutdown: a member that cannot take a FIN in a second
// will not read a goodbye either.
const closeClientsDeadline = time.Second

// unreliableWriter is the datagram plane as transport discovers it, by type assertion on the net.Conn.
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

// CloseWrite and TransportName forward because transport.CloseGracefully asserts for CloseWrite and degrades to a
// reset without it, losing the reject just written, and relay's per-client log line asserts for TransportName and
// calls everything "tcp" without it.
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

// AcceptedAt forwards so the relay's hello timer counts from accept, not from the handshake, which would hold a
// stranger for two windows. A zero time means no accept time, which the relay reads as the whole window.
func (c *trackedConn) AcceptedAt() time.Time {
	a, ok := c.Conn.(interface{ AcceptedAt() time.Time })
	if !ok {
		return time.Time{}
	}
	return a.AcceptedAt()
}

// MaxPayloadBytes is 0, no datagram bound, when the connection has none, as the relay's sendBudget assumes for a
// stream.
func (c *trackedConn) MaxPayloadBytes() int {
	m, ok := c.Conn.(interface{ MaxPayloadBytes() int })
	if !ok {
		return 0
	}
	return m.MaxPayloadBytes()
}

// trackedLossyConn is trackedConn for a connection that also has the datagram plane (quic, udp): a separate type so
// WriteUnreliable is missing exactly when the underlying connection lacks it, as transport finds the plane by asking.
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

// logPath is where the relay's log goes: beside the config it read, or beside the executable when there was none,
// never a service manager's arbitrary working directory.
func (l locatedConfig) logPath(name string) string {
	return filepath.Join(l.dir(), name)
}

// identityDir is where the relay's identity lives: the private folder beside the config, so uninstalling is still
// deleting the folder, and moving the install moves the identity.
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

// resolveConfigPath decides which config.json the relay reads. An explicit -config is believed as given. Otherwise
// the relative default is tried in the working directory first, then beside the executable, for a relay run as a
// service (systemd's working directory is /, a Windows service's is system32). The note names what was decided, and
// both places looked at when neither had a file.
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

// serverSection is the raw bytes of the config file's "server" object, or nil if there isn't one: the unknown-key
// warning looks at what was written rather than at what decoded.
func serverSection(data []byte) json.RawMessage {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return nil
	}
	// Case-insensitively, as encoding/json matched the section it decoded.
	for k, v := range root {
		if strings.EqualFold(k, "server") {
			return v
		}
	}
	return nil
}
