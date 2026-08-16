// Command meshghost is the desktop core process: it connects to a relay
// and listens for a local adapter over the bridge. See internal/core for
// the implementation and agent_docs/contract.md for the protocol.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"time"

	"meshghost/internal/core"
	"meshghost/internal/netx"
	"meshghost/internal/protocol"
)

// maxLogBytes is the size at which meshghost.log is rotated to meshghost.log.1
// (one generation, then the older one is discarded). A cap is needed because
// the log APPENDS rather than truncating -- see openLogFile -- so without one a
// machine that autostarts the client with every game session would grow it
// forever.
const maxLogBytes = 1 << 20 // 1 MiB

// openLogFile opens (creating, and APPENDING to) meshghost.log next to wherever
// the process's working directory is -- the same cwd config.json is read from, so
// it lands beside the exe in the normal double-click-from-the-package-folder case,
// and beside the mod in the autostarted case (the adapter sets the child's working
// directory; see agent_docs/architecture.md's autostart ADR). This exists so a
// crash is still readable after the console window itself is gone: double-clicking
// an .exe opens a console that closes the instant the process exits, taking any
// error message with it -- see packaging/README.md's "No launcher .bat files"
// section.
//
// It appends rather than truncating, which it did until autostart landed. Once the
// adapter starts the client for you there is usually no console at all, so this file
// is the ONLY thing a remote tester can send back -- and a client that dies and gets
// respawned would truncate away the evidence of why it died, which is exactly the
// report worth having. One rotation at maxLogBytes bounds the growth that buys.
//
// Returns nil, with a warning, if the file can't be opened (e.g. a read-only
// folder) -- the caller still has stderr and, if asked for, a console.
func openLogFile(name string) io.Writer {
	if fi, err := os.Stat(name); err == nil && fi.Size() >= maxLogBytes {
		// Best-effort: a failed rotate must not cost us the log entirely, so
		// the error is deliberately ignored and the append below still runs.
		_ = os.Rename(name, name+".1")
	}
	f, err := os.OpenFile(name, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		log.Printf("meshghost: warning: could not open log file %s: %v (log output will only appear in this window)", name, err)
		return nil
	}
	return f
}

// logRunBanner marks the start of a run in an appending log, so a file holding
// several runs can be read at all -- without it, a respawned client's output runs
// straight into the dead one's with no way to tell where one ended. Everything on
// it is something that has actually been guessed wrong in a support conversation:
// which executable is really running, which folder it thinks it is in (that is the
// folder its config and this log come from), and whether an adapter started it or
// a human did.
func logRunBanner(autostarted bool) {
	exe, err := os.Executable()
	if err != nil {
		exe = "unknown"
	}
	cwd, err := os.Getwd()
	if err != nil {
		cwd = "unknown"
	}
	startedBy := "started manually"
	if autostarted {
		startedBy = "autostarted by a game adapter"
	}
	revision := "unknown"
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, s := range info.Settings {
			if s.Key == "vcs.revision" {
				revision = s.Value
			}
		}
	}
	log.Printf("=== meshghost run start === pid %d, %s, protocol v%d, build %s, %s/%s",
		os.Getpid(), startedBy, protocol.Version, revision, runtime.GOOS, runtime.GOARCH)
	log.Printf("meshghost: executable %s", exe)
	log.Printf("meshghost: working directory %s (config and this log are read/written here)", cwd)
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
	Relay       *string `json:"connect_to"`
	Bridge      *string `json:"local_game_bridge"`
	Game        *string `json:"game"`
	Room        *string `json:"room"`
	Name        *string `json:"name"`
	Interp      *string `json:"interp"`
	MinSend     *string `json:"min_send"`
	RoomCode    *string `json:"room_code"`
	GameVersion *string `json:"game_version"`
	// MaxReceiveHzPerPlayer is the highest rate, per OTHER player, at which
	// this client wants the relay to forward their state to it. Absent or 0
	// means uncapped (the pre-existing behavior). Per-peer, not a total —
	// see core.Core.MaxReceiveHz and the ADR in agent_docs/architecture.md.
	MaxReceiveHzPerPlayer *int `json:"max_receive_hz_per_player"`
	// Transport is what this client moves to AFTER connecting, not how it
	// connects: the handshake is always tcp and no setting changes that.
	// "tcp" stays put; "udp" (the shipped default) and "quic" upgrade if the
	// relay serves them; "auto" takes the best on offer.
	//
	// Because the relay is asked what it serves during that tcp handshake,
	// connect_to only ever needs the tcp port -- a client never has to be
	// told where quic lives, and asking for a transport the relay does not
	// serve degrades to a working tcp session rather than a timeout. See
	// packaging/release/README.txt and the transport discovery ADR in
	// agent_docs/architecture.md.
	Transport *string `json:"transport"`
	// ShowConsole opens a console window for a client that an adapter started
	// with no window. Absent or false is the point of autostart -- MeshGhost
	// should feel like part of launching the game, not a third thing to run --
	// so this is for someone who wants to watch it work. See consoleWriter.
	ShowConsole *bool `json:"show_console"`
}

// rootConfig is the top-level shape of the config file: a "client" section
// read by this binary, sitting alongside a "server" section (meaningless
// here) read by cmd/meshghost-relay from the same file in the shipped
// package -- see packaging/release/config.json.
type rootConfig struct {
	Client *fileConfig `json:"client"`
}

// configTargets are the flag-backed variables applyFileConfig may overwrite
// — one *string/*time.Duration per fileConfig field. Grouped into a struct
// (rather than applyFileConfig's old flat list of positional pointer
// params) since that list was already at five and room-code/game-version
// support would have pushed it to seven; a struct keeps each field's name
// at the call site instead of relying on positional order.
type configTargets struct {
	relayAddr    *string
	bridgeAddr   *string
	gameID       *string
	room         *string
	name         *string
	interp       *time.Duration
	minSend      *time.Duration
	roomCode     *string
	gameVersion  *string
	maxReceiveHz *int
	transport    *string
	showConsole  *bool
}

// applyFileConfig loads path (leaving every flag alone if it doesn't exist, so
// existing flag-only usage is unaffected -- but SAYING SO in the log, which it
// did not do before autostart made this file a player's only feedback channel)
// and overwrites any flag that was NOT explicitly passed on the command line
// with the file's "client" section. CLI flags always win over the file, matching normal
// config-layering convention (most-specific/most-explicit source wins).
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
// error it would otherwise produce. Mirrored in cmd/meshghost-relay/main.go,
// the same way applyFileConfig itself is.
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

func applyFileConfig(path string, explicit map[string]bool, t configTargets) {
	// Absolute, always: with the client autostarted there is no console showing
	// which folder it was launched from, and "I edited config.json and nothing
	// changed" is nearly always a different config.json than the one being read
	// -- a relative path in the log answers that question with another question.
	shown := path
	if abs, err := filepath.Abs(path); err == nil {
		shown = abs
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("meshghost: warning: could not read config file %s: %v", shown, err)
			return
		}
		// Missing was silent until autostart landed. Silence is fine when a
		// developer passes flags on purpose, and actively misleading for a
		// player whose only feedback channel is this file: every setting they
		// typed is being ignored and there was nothing anywhere saying so.
		log.Printf("meshghost: no config file at %s -- using built-in defaults "+
			"(connect_to 127.0.0.1:7777). If you edited a config.json somewhere else, "+
			"that is not the one being read.", shown)
		return
	}
	log.Printf("meshghost: config loaded from %s", shown)
	data = stripBOM(data, shown, "meshghost")
	if data == nil {
		return
	}
	var rc rootConfig
	if err := json.Unmarshal(data, &rc); err != nil {
		log.Printf("meshghost: warning: could not parse config file %s: %v -- every setting in it "+
			"is being IGNORED and built-in defaults used instead", shown, err)
		return
	}
	if rc.Client == nil {
		log.Printf("meshghost: warning: config file %s has no \"client\" section -- "+
			"every client setting is falling back to its built-in default", shown)
		return
	}
	fc := *rc.Client
	if fc.Relay != nil && !explicit["relay"] {
		*t.relayAddr = *fc.Relay
	}
	if fc.Bridge != nil && !explicit["bridge"] {
		*t.bridgeAddr = *fc.Bridge
	}
	if fc.Game != nil && !explicit["game"] {
		*t.gameID = *fc.Game
	}
	if fc.Room != nil && !explicit["room"] {
		*t.room = *fc.Room
	}
	if fc.Name != nil && !explicit["name"] {
		*t.name = *fc.Name
	}
	if fc.Interp != nil && !explicit["interp"] {
		d, err := time.ParseDuration(*fc.Interp)
		if err != nil {
			log.Printf("meshghost: warning: config file %s has an invalid interp value %q: %v", shown, *fc.Interp, err)
		} else {
			*t.interp = d
		}
	}
	if fc.MinSend != nil && !explicit["min-send"] {
		d, err := time.ParseDuration(*fc.MinSend)
		if err != nil {
			log.Printf("meshghost: warning: config file %s has an invalid min_send value %q: %v", shown, *fc.MinSend, err)
		} else {
			*t.minSend = d
		}
	}
	if fc.RoomCode != nil && !explicit["room-code"] {
		*t.roomCode = *fc.RoomCode
	}
	if fc.GameVersion != nil && !explicit["game-version"] {
		*t.gameVersion = *fc.GameVersion
	}
	if fc.MaxReceiveHzPerPlayer != nil && !explicit["max-receive-hz-per-player"] {
		*t.maxReceiveHz = *fc.MaxReceiveHzPerPlayer
	}
	if fc.Transport != nil && !explicit["transport"] {
		*t.transport = *fc.Transport
	}
	if fc.ShowConsole != nil && !explicit["show-console"] {
		*t.showConsole = *fc.ShowConsole
	}
}

// connectRelayWithRetry keeps calling Core.ConnectRelayOnAdapterHello until
// it succeeds or is permanently refused, so meshghost.exe doesn't require
// the relay to already be running when the caller uses an explicit -game
// (dev-scripts, fakeadapter-style tooling — the default, -game unset,
// already tolerates this for free the same way, since a real adapter's own
// bridge-reconnect loop drives retries there). Routed through
// ConnectRelayOnAdapterHello specifically, not Core.ConnectRelay directly:
// that function already serializes on Core.relayConnectMu and checks
// "already connected," which matters here because a real adapter can also
// connect over the bridge and send its own hello for the same game_id
// while this loop is still waiting for the relay to come up — without
// going through the same entry point, both could race to dial
// independently. ConnectRelayOnAdapterHello's own internal logging (with
// dedup) already covers "could not connect yet" and "permanently
// refused," so this loop doesn't log anything of its own beyond the final
// Fatalf. Added after the user asked whether client/server had to be
// started in a specific order — they shouldn't have to be.
//
// Takes no gameVersion parameter: c.GameVersion is already set from the
// -game-version flag/config before this is called (see main below), and
// ConnectRelayOnAdapterHello reads it from there directly — passing it
// again here would have been a dead argument (found in a review pass;
// this used to take one and thread it through unused).
func connectRelayWithRetry(c *core.Core, gameID string) {
	const (
		initialBackoff = 1 * time.Second
		maxBackoff     = 15 * time.Second
	)
	backoff := initialBackoff
	for {
		err := c.ConnectRelayOnAdapterHello(gameID, "", nil)
		if err == nil {
			return
		}
		if core.IsPermanentRejectErr(err) {
			log.Fatalf("meshghost: %v", err)
		}
		time.Sleep(backoff)
		if backoff < maxBackoff {
			backoff *= 2
			if backoff > maxBackoff {
				backoff = maxBackoff
			}
		}
	}
}

// parentPollInterval is how often watchParentPID checks whether the process that
// spawned this one is still alive. Two seconds matches the adapters' own bridge
// reconnect interval: it is fast enough that a restarted game finds the port free,
// and cheap enough to be invisible (one process-handle open per tick).
const parentPollInterval = 2 * time.Second

// watchParentPID exits this process once pid does, so an autostarted client dies
// with the game that started it.
//
// Without it, the worst failure mode of autostart is an ORPHAN: a client with no
// console, spawned by a game that has since crashed, still holding the bridge
// port -- so the next launch cannot listen and the player sees nothing, with no
// window anywhere to explain why. A crashed game never gets to clean up after
// itself, so the child has to do it.
//
// Note this is about the process, not about peers seeing you leave: when a game
// dies its bridge socket closes, and the core already drops the relay connection
// on that (internal/core.Core.handleBridgeConn), so a real leave is sent either
// way. What survives is the empty core process, and that is what this reaps.
//
// pid <= 0 means "not asked for" and returns immediately -- the guard lives here
// rather than at the call site so it is covered by the same test.
//
// gone and poll are parameters rather than direct calls to parentGone and
// parentPollInterval so a test can drive this without a real process to kill.
func watchParentPID(pid int, gone func(int) bool, poll time.Duration, onGone func()) {
	if pid <= 0 {
		return
	}
	for {
		if gone(pid) {
			onGone()
			return
		}
		time.Sleep(poll)
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
	minSend := flag.Duration("min-send", 0,
		"a FLOOR on how slowly you send your position to the relay -- leave this unset (0) to "+
			"just adopt whatever rate the relay advertises (see -send-hz on the relay side; "+
			"defaults to 20Hz/50ms if the relay doesn't advertise one at all). Setting this only "+
			"ever makes you send SLOWER than the room, never faster: it's for a poor connection "+
			"that wants to opt out of a fast room, not a way to exceed what the relay allows. "+
			"e.g. 100ms means 'send at most 10 times/sec even if this room runs faster'")
	roomCode := flag.String("room-code", "", "shared secret to send the relay for room-code auth "+
		"-- only needed if the relay you're connecting to has one configured; leave empty for a "+
		"relay running open (the default)")
	gameVersion := flag.String("game-version", "", "override the game/DLC version advertised to "+
		"the relay, instead of whatever the adapter itself reports over its bridge Hello -- for "+
		"dev/testing scripts with no real adapter attached")
	maxReceiveHz := flag.Int("max-receive-hz-per-player", core.DefaultMaxReceiveHz,
		"the highest rate, per OTHER player, at which you want the relay to forward their "+
			"position to you -- leave at 0 (uncapped, the default) unless you're on a metered or "+
			"weak connection. This is PER PLAYER, not a total: setting 5 in a room of 8 is up to "+
			"35 updates/sec inbound, not 5. Only affects your own download and nobody else's view "+
			"of you. Valid range 10-100 if set; values below ~10 will look stuttery unless you "+
			"also raise -interp")
	transportName := flag.String("transport", netx.UDP.String(),
		"which transport to move to AFTER connecting. The handshake is always tcp and this "+
			"cannot be changed -- so you never need to know which port a transport is on, and a "+
			"preference the relay does not serve degrades to a working tcp session instead of a "+
			"timeout. tcp: stay on tcp (reliable, and the only one readable with netcat while "+
			"debugging). udp (the default): upgrade if the relay serves it -- better on a lossy "+
			"connection, but CANNOT be encrypted (Go has no DTLS), so your room code crosses the "+
			"wire in the clear. quic: same loss behaviour as udp but encrypted and hard to spoof. "+
			"auto: take the best on offer, preferring quic, and never udp unless it is all there "+
			"is")
	exitWithPID := flag.Int("exit-with-pid", 0,
		"exit when the process with this pid does -- set by a game adapter that starts this "+
			"client for you, so a crashed game can't leave an invisible orphan holding the bridge "+
			"port. 0 (the default) means don't watch anything. Deliberately not a config.json "+
			"setting: it's a per-launch fact from whoever spawned us, not something a player configures")
	showConsole := flag.Bool("show-console", false,
		"open a console window and mirror the log to it. Only meaningful when a game adapter "+
			"started this client (it spawns us with no window on purpose); a client you ran "+
			"yourself already has the terminal you ran it from. For \"is it actually running?\" -- "+
			"the log file answers the same question either way. Ignored on non-Windows")
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file with a \"client\" section "+
			"(connect_to/local_game_bridge/game/room/name/interp/min_send/room_code/game_version/"+
			"max_receive_hz_per_player/transport/show_console) -- a friendlier alternative to flags for non-developer use; "+
			"a warning is logged if it doesn't exist; any flag explicitly passed on the command line "+
			"overrides the same field from this file")
	flag.Parse()

	// Log into a buffer until the destination is known, then replay. show_console
	// lives in the config file (that is where a player can reach it), so the
	// console can't be opened until the file has been read -- and the file's own
	// messages, "this is the config I loaded" above all, are exactly the ones
	// someone who turned the console ON is looking for. Buffering is what keeps
	// them from landing before the window they belong in exists.
	var earlyLog bytes.Buffer
	log.SetOutput(&earlyLog)

	explicit := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { explicit[f.Name] = true })
	applyFileConfig(*configPath, explicit, configTargets{
		relayAddr:    relayAddr,
		bridgeAddr:   bridgeAddr,
		gameID:       gameID,
		room:         room,
		name:         name,
		interp:       interp,
		minSend:      minSend,
		roomCode:     roomCode,
		gameVersion:  gameVersion,
		maxReceiveHz: maxReceiveHz,
		transport:    transportName,
		showConsole:  showConsole,
	})

	// stderr stays in the list unconditionally: when this client was run from a
	// terminal that IS the live output, and when it was spawned with no window
	// the writes simply go nowhere. openLogFile returns nil if the file could not
	// be opened, which is survivable rather than fatal -- losing the log is worth
	// saying loudly, but not worth refusing to play over.
	writers := []io.Writer{os.Stderr}
	if f := openLogFile("meshghost.log"); f != nil {
		writers = append(writers, f)
	}
	if *showConsole {
		if w := consoleWriter(); w != nil {
			writers = append(writers, w)
		}
	}
	out := io.MultiWriter(writers...)
	log.SetOutput(out)

	logRunBanner(*exitWithPID != 0)
	_, _ = io.Copy(out, &earlyLog)

	// Fatal on a bad value rather than clamping to tcp, deliberately
	// departing from how send_hz and interp are handled: a typo in those
	// costs a little smoothness, whereas silently falling back here would
	// hand someone who asked for quic an unencrypted connection and never
	// mention it. netx.Kind's zero value being tcp is exactly what makes a
	// lenient parse dangerous.
	transportKind, err := netx.ParseKind(*transportName)
	if err != nil {
		log.Fatalf("meshghost: %v", err)
	}

	c := core.New()
	c.Transport = transportKind
	c.InterpolationDelay = *interp
	c.MinSendInterval = *minSend
	c.MaxReceiveHz = *maxReceiveHz
	c.RelayAddr = *relayAddr
	c.Room = *room
	c.DisplayName = *name
	c.RoomCode = *roomCode
	c.GameVersion = *gameVersion
	c.DialTimeout = 5 * time.Second
	c.OnRelayConnected = func(gameID string) {
		log.Printf("meshghost: connected to relay %s as %s in room %q (game %q)", *relayAddr, c.PlayerID(), *room, gameID)
	}

	if *exitWithPID != 0 {
		log.Printf("meshghost: watching pid %d -- will exit when it does", *exitWithPID)
		go watchParentPID(*exitWithPID, parentGone, parentPollInterval, func() {
			log.Printf("meshghost: pid %d is gone -- exiting so nothing is left holding %s",
				*exitWithPID, *bridgeAddr)
			os.Exit(0)
		})
	}

	if *gameID != "" {
		// Backgrounded, not blocking: the bridge listener below starts
		// immediately regardless of whether the relay is reachable yet —
		// see connectRelayWithRetry's doc comment.
		go connectRelayWithRetry(c, *gameID)
	} else {
		log.Printf("meshghost: no game set -- waiting for a game to connect and say hello...")
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
