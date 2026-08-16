// Command meshghost-relay is the standalone relay process: it accepts
// relay-protocol connections and forwards state between clients in a room.
// See internal/relay for the implementation and agent_docs/contract.md for
// the wire protocol.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"meshghost/internal/netx"
	"meshghost/internal/protocol"
	"meshghost/internal/relay"
)

// maxLogBytes is the size at which meshghost-server.log is rotated to
// meshghost-server.log.1. Mirrors cmd/meshghost's own cap, for the same reason:
// the log appends rather than truncating, so something has to bound it.
const maxLogBytes = 1 << 20 // 1 MiB

// openLogFile opens (creating, and APPENDING to) meshghost-server.log next to wherever
// the process's working directory is -- the same cwd config.json is read from, so it lands
// beside the exe in the normal double-click-from-the-package-folder case. This exists so a
// crash is still readable after the console window itself is gone: double-clicking an .exe
// opens a console that closes the instant the process exits, taking any error message with
// it -- see packaging/README.md's "No launcher .bat files" section.
//
// It appends, where it used to truncate on every run (os.Create). Brought in line with the
// client 2026-08-16, after the client's appending log was the ONLY reason a Proton bug
// report could be diagnosed remotely: six runs in one file, each with its own banner. A
// relay that erases its own history every restart cannot answer "what happened before it
// died", which is the question a host is asking when they go looking.
//
// Falls back to stderr-only, with a warning, if the file can't be opened (e.g. read-only
// folder).
func openLogFile(name string) io.Writer {
	if fi, err := os.Stat(name); err == nil && fi.Size() >= maxLogBytes {
		// Best-effort: a failed rotate must not cost the log entirely.
		_ = os.Rename(name, name+".1")
	}
	f, err := os.OpenFile(name, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		log.Printf("meshghost-relay: warning: could not open log file %s: %v (log output will only appear in this window)", name, err)
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
	// Transport is a comma-separated list of transports to serve at once:
	// any of "tcp", "udp", "quic". Absent means "tcp". Clients pick one of
	// them; a room can hold clients on different transports simultaneously,
	// since the relay forwards through the transport.Transport interface and
	// never learns which is which. See the transport ADR in
	// agent_docs/architecture.md.
	Transport *string `json:"transport"`
	// QuicAddr is where quic listens, and it must differ from listen_on's
	// port: quic is carried over udp, so it cannot share a port with the
	// plain "udp" transport. Absent means DefaultQuicAddr.
	QuicAddr *string `json:"listen_quic"`
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
	onlyGame   *string
	maxClients *int
	sendHz     *int
	transport  *string
	quicAddr   *string
}

// stripBOM removes a leading UTF-8 byte-order mark from a config file's
// contents, and refuses a UTF-16 one outright (returning nil) with a message
// naming the actual fix. Both cases exist because config.json is a file a
// non-developer edits by hand on Windows: a BOM is three bytes some editors
// (Notepad's "UTF-8 with BOM" save option, PowerShell 5.1's `Out-File
// -Encoding utf8`) put before the opening brace, and encoding/json refuses
// them -- so a file that looks completely correct to whoever edited it gets
// discarded whole, silently taking every setting in it along with it,
// room_code included. Found while testing the only_game setting. The BOM is
// stripped rather than warned about (the file is valid UTF-8 either way, and
// the offending bytes are invisible in an editor); UTF-16 can't be salvaged
// this cheaply, so it gets an actionable warning instead of the cryptic JSON
// error it would otherwise produce. Mirrored in cmd/meshghost/main.go, the
// same way applyFileConfig itself is.
func stripBOM(data []byte, path, prog string) []byte {
	data = bytes.TrimPrefix(data, []byte{0xEF, 0xBB, 0xBF})
	if bytes.HasPrefix(data, []byte{0xFF, 0xFE}) || bytes.HasPrefix(data, []byte{0xFE, 0xFF}) {
		log.Printf("%s: warning: config file %s looks like it was saved as UTF-16 (\"Unicode\" in "+
			"Notepad's save-as list) -- re-save it as UTF-8. Every setting in it is being IGNORED "+
			"and built-in defaults used instead.", prog, path)
		return nil
	}
	return data
}

// applyDespiteBadValue decides whether a json.Unmarshal error is survivable, and
// logs the right thing either way. Mirrored from cmd/meshghost/main.go, the same
// way stripBOM and applyFileConfig are -- see that copy for the full story.
//
// The short version: encoding/json does not abort on a type mismatch, it skips
// that one value and keeps decoding, so throwing the result away over `err != nil`
// cost a user every OTHER setting in their file. Found live 2026-08-16 on the
// client. The relay has no bool settings, but "max_clients": "8" is the same
// mistake, and it would silently take room_code and only_game with it -- a host
// who believes they set a room code, running wide open.
func applyDespiteBadValue(err error, path, prog string) bool {
	var typeErr *json.UnmarshalTypeError
	if !errors.As(err, &typeErr) {
		log.Printf("%s: warning: could not parse config file %s: %v -- every setting in it "+
			"is being IGNORED and built-in defaults used instead", prog, path, err)
		return false
	}

	key := typeErr.Field
	if i := strings.LastIndex(key, "."); i >= 0 {
		key = key[i+1:]
	}
	wanted := typeErr.Type.String()
	switch wanted {
	case "bool":
		wanted = "true or false, without quotes"
	case "int":
		wanted = "a plain number, without quotes"
	}
	log.Printf("%s: warning: config file %s: \"%s\" was given a %s, but it needs %s. That ONE "+
		"setting is being ignored -- everything else in the file still applies. (Quotes make a "+
		"value text: \"%s\": 8, not \"%s\": \"8\".)",
		prog, path, key, typeErr.Value, wanted, key, key)
	return true
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
	data = stripBOM(data, shown, "meshghost-relay")
	if data == nil {
		return
	}
	var rc rootConfig
	if err := json.Unmarshal(data, &rc); err != nil {
		if !applyDespiteBadValue(err, shown, "meshghost-relay") {
			return
		}
	}
	if rc.Server == nil {
		log.Printf("meshghost-relay: warning: config file %s has no \"server\" section -- "+
			"every server setting is falling back to its built-in default", shown)
		return
	}
	if rc.Server.Addr != nil && !explicit["addr"] {
		*t.addr = *rc.Server.Addr
	}
	if rc.Server.RoomCode != nil && !explicit["room-code"] {
		*t.roomCode = *rc.Server.RoomCode
	}
	if rc.Server.OnlyGame != nil && !explicit["only-game"] {
		*t.onlyGame = *rc.Server.OnlyGame
	}
	if rc.Server.MaxClients != nil && !explicit["max-clients"] {
		*t.maxClients = *rc.Server.MaxClients
	}
	if rc.Server.SendHz != nil && !explicit["send-hz"] {
		*t.sendHz = *rc.Server.SendHz
	}
	if rc.Server.Transport != nil && !explicit["transport"] {
		*t.transport = *rc.Server.Transport
	}
	if rc.Server.QuicAddr != nil && !explicit["listen-quic"] {
		*t.quicAddr = *rc.Server.QuicAddr
	}
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
		"adapter advertises -- \"emerald\", \"tevi\", or \"pseudoregalia\" for the three shipped "+
		"adapters -- and must match exactly")
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
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file with a \"server\" section "+
			"({\"listen_on\": \"...\", \"listen_quic\": \"...\", \"room_code\": \"...\", "+
			"\"only_game\": \"...\", \"transport\": \"...\", "+
			"\"max_clients\": ..., \"send_hz\": ...}) -- a friendlier alternative to flags for "+
			"non-developer use; "+
			"silently ignored if it doesn't exist; a flag passed explicitly on the command line "+
			"overrides the same field from this file")
	flag.Parse()

	log.SetOutput(openLogFile("meshghost-server.log"))

	explicit := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { explicit[f.Name] = true })
	applyFileConfig(*configPath, explicit, configTargets{
		addr:       addr,
		roomCode:   roomCode,
		onlyGame:   onlyGame,
		maxClients: maxClients,
		sendHz:     sendHz,
		transport:  transportNames,
		quicAddr:   quicAddr,
	})

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
	// nothing in internal/relay knows or cares which is which -- and a
	// single room can hold clients arriving over different transports,
	// because Room.Forward sends through the transport.Transport interface.
	type boundListener struct {
		kind netx.Kind
		ln   net.Listener
	}
	var listeners []boundListener
	for _, k := range kinds {
		bind := *addr
		if k == netx.QUIC {
			bind = *quicAddr
		}
		ln, err := netx.Listen(k, bind)
		if err != nil {
			log.Fatalf("meshghost-relay: listen %s on %s: %v", k, bind, err)
		}
		listeners = append(listeners, boundListener{kind: k, ln: ln})
		log.Printf("meshghost-relay: listening on %s (%s)", ln.Addr(), k)
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
