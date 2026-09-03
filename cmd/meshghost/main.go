// Command meshghost is the desktop core process: it connects to a relay
// and listens for a local adapter over the bridge. See core for
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
	"strings"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/core"
	"github.com/Tsukino-uwu/MeshGhost/internal/cfg"
	"github.com/Tsukino-uwu/MeshGhost/internal/hotkey"
	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

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
	Relay     *string `json:"connect_to"`
	Bridge    *string `json:"local_game_bridge"`
	Game      *string `json:"game"`
	Room      *string `json:"room"`
	Name      *string `json:"name"`
	NameColor *string `json:"name_color"`
	Interp    *string `json:"interp"`
	// LocalInterp is the render delay for a LOCAL ghost -- a replay or a
	// chaser -- which is a different number for a different job than Interp;
	// see core.DefaultLocalGhostDelay.
	LocalInterp *string `json:"local_interp"`
	MinSend     *string `json:"min_send"`
	// Keepalive is how often an UNCHANGED state is re-sent (core.IdleKeepalive).
	// "0" disables change suppression and sends every frame.
	Keepalive *string `json:"keepalive"`
	// Extrapolate is the opt-in prediction window (core.Core.Extrapolate).
	// Absent or "0" holds the newest sample, which is the shipped behaviour.
	Extrapolate *string `json:"extrapolate"`
	// Curve is "linear" (default) or "catmull-rom" -- see core.CurveMode.
	Curve *string `json:"curve"`
	// Predict is "linear" (default) or "accelerated" -- see core.PredictMode.
	Predict *string `json:"predict"`
	// Stats is how often to log the one-line summary, e.g. "10s". Absent or "0"
	// disables it. In the FILE as well as on the flag because the client a player
	// actually runs is usually started by their game, which passes no flags -- so
	// without this there is no way to turn the numbers on in the session that has
	// the problem.
	Stats       *string `json:"stats"`
	RoomCode    *string `json:"room_code"`
	GameVersion *string `json:"game_version"`
	// MaxReceiveHzPerPlayer is the highest rate, per OTHER player, at which
	// this client wants the relay to forward their state to it. Absent or 0
	// means uncapped (the pre-existing behavior). Per-peer, not a total —
	// see core.Core.MaxReceiveHz and the ADR in agent_docs/architecture.md.
	MaxReceiveHzPerPlayer *int `json:"max_receive_hz_per_player"`
	// GhostCollision is this player's OWN ghost-collision preference, and it
	// only ever works in the restrictive direction: "disabled" turns ghost
	// collision off for this player whatever the room is set to, while
	// "enabled" (or absent, the default) accepts whatever the host chose. A
	// host can take collision away; a host cannot force it onto someone who
	// does not want it. See core.Core.GhostCollision and the ADR in
	// agent_docs/architecture.md.
	GhostCollision *string `json:"ghost_collision"`
	// Features turns on capabilities beyond the cosmetic ghost overlay --
	// the event plane, leases, escrow, late-join snapshots, session
	// resumption, clock sync (see protocol's Feature* constants and
	// agent_docs/beyond-cosmetic.md). Absent or empty, the default, means
	// cosmetic only.
	//
	// **A room's capability set has to match EXACTLY across everyone in it**,
	// so this is not a per-player preference like the ones above: everybody
	// sharing a room needs the same list, and a client whose list differs is
	// refused at the handshake with a clear reason rather than admitted into
	// a room where half the arbitration silently does not work.
	Features *[]string `json:"features"`
	// Transport is what this client moves to AFTER connecting, not how it
	// connects: the handshake is always tcp and no setting changes that.
	// "tcp" stays put; "udp" and "quic" upgrade if the
	// relay serves them; "auto" takes the best on offer.
	//
	// Because the relay is asked what it serves during that tcp handshake,
	// connect_to only ever needs the tcp port -- a client never has to be
	// told where quic lives, and asking for a transport the relay does not
	// serve degrades to a working tcp session rather than a timeout. See
	// packaging/release/README.txt and the transport discovery ADR in
	// agent_docs/architecture.md.
	Transport *string `json:"transport"`
	// TLS encrypts this client's tcp legs: "off", "auto" (the built-in
	// default) or "required". It applies to the discovery handshake as well
	// as the session, which is why it matters even when "transport" is
	// quic -- that handshake is always tcp and it carries the room code.
	//
	// "auto" falls back to plaintext, with a warning in the log, if the
	// relay cannot handshake; "required" refuses to send anything at all
	// to a relay that is not encrypted. See the TLS-over-tcp ADR in
	// agent_docs/architecture.md.
	TLS *string `json:"tls"`
	// TLSFingerprint optionally pins the relay's certificate: the
	// SHA-256 the relay prints in its own log at startup, given to you by
	// the host through some other channel. Absent or empty means the
	// session is encrypted but the relay is not authenticated -- exactly
	// what quic already gives today (docs/security.md). The relay
	// regenerates its certificate on every restart, so a pin has to be
	// re-copied after the host restarts it.
	TLSFingerprint *string `json:"tls_fingerprint"`
	// ShowConsole opens a console window for a client that an adapter started
	// with no window. Absent or false is the point of autostart -- MeshGhost
	// should feel like part of launching the game, not a third thing to run --
	// so this is for someone who wants to watch it work. See consoleWriter.
	ShowConsole *bool `json:"show_console"`
	// Offline plays alone deliberately: no relay is dialled, no room is
	// joined, and the retry loop that logs "cannot connect yet" never starts.
	// Recording, replays and chasers all still work -- they never needed a
	// relay. Ships as false; someone who plays with replays and no room turns
	// it on and gets a quiet console.
	Offline *bool `json:"offline"`
	// Replay is the recording block (ADR 0047): record_on_launch writes the
	// whole session to the replay/ folder beside this file; save_last is how
	// many seconds the save-last hotkey keeps. Nested so the player's file
	// reads as one topic, one line: {"record_on_launch": false, "save_last": "30s"}.
	Replay *replayFileConfig `json:"replay"`
	// Hotkeys binds the mid-play replay actions to system-wide chords the
	// client itself registers (ADR 0048): they work in every game with the
	// game focused, and no adapter has to implement a key. One line in the
	// player's file; an empty value leaves that action unbound.
	Hotkeys *hotkeyFileConfig `json:"hotkeys"`
	// Chaser is the pack of your own past following you (ADR 0047): count
	// ghosts, the first `delay` behind and each further `spacing` behind the
	// one before. Cosmetic whatever ghost_collision says; contact is the
	// adapter-facing hook no shipped adapter honours yet.
	Chaser *chaserFileConfig `json:"chaser"`
}

type chaserFileConfig struct {
	Enabled *bool   `json:"enabled"`
	Count   *int    `json:"count"`
	Delay   *string `json:"delay"`
	Spacing *string `json:"spacing"`
	Name    *string `json:"name"`
	Color   *string `json:"color"`
	Contact *bool   `json:"contact"`
	// SpawnDelay: a chaser appears only once you have been moving for this
	// long, so none spawns on top of you while you stand at the start.
	// Absent or "0s" means the chaser's own delay.
	SpawnDelay *string `json:"spawn_delay"`
}

type hotkeyFileConfig struct {
	RecordToggle      *string `json:"record_toggle"`
	SaveLast          *string `json:"save_last"`
	ReplayLast        *string `json:"replay_last"`
	ReplayRestart     *string `json:"replay_restart"`
	ReplayRewind      *string `json:"replay_rewind"`
	ReplayFastForward *string `json:"replay_fast_forward"`
}

type replayFileConfig struct {
	RecordOnLaunch *bool   `json:"record_on_launch"`
	SaveLast       *string `json:"save_last"`
	// StartDelay is how long after you are in the game a replay ghost starts,
	// for files whose own header says 0s.
	StartDelay *string `json:"start_delay"`
	// Seek is how far one rewind or fast-forward key press moves a replay.
	Seek *string `json:"seek"`
	// SplitTimes shows "+1.2s" on a replay ghost's nametag: how far behind
	// (or ahead of) it you are. Off unless asked for.
	SplitTimes *bool `json:"split_times"`
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
	relayAddr      *string
	bridgeAddr     *string
	gameID         *string
	room           *string
	name           *string
	nameColor      *string
	interp         *time.Duration
	localInterp    *time.Duration
	minSend        *time.Duration
	keepalive      *time.Duration
	extrapolate    *time.Duration
	curve          *string
	predict        *string
	stats          *time.Duration
	roomCode       *string
	gameVersion    *string
	maxReceiveHz   *int
	ghostCollision *string
	transport      *string
	tlsMode        *string
	tlsPin         *string
	showConsole    *bool
	offline        *bool
	features       *string
	recordOnLaunch *bool
	saveLast       *time.Duration
	replayStart    *time.Duration
	replaySeek     *time.Duration
	splitTimes     *bool
	hotkeys        *hotkeyTargets
	chaser         *chaserTargets
}

type chaserTargets struct {
	enabled, contact *bool
	count            *int
	delay, spacing   *time.Duration
	spawnDelay       *time.Duration
	name, color      *string
}

// hotkeyTargets is where the six chords land; nil entries are skipped so a
// test can pass only the ones it cares about.
type hotkeyTargets struct {
	recordToggle, saveLast, replayLast, replayRestart, replayRewind, replayFastForward *string
}

// applyFileConfig returns the absolute path of the config file it looked for
// (read or not), so callers can place things beside it -- the replay folder.
func applyFileConfig(path string, explicit map[string]bool, t configTargets) string {
	// Absolute path, BOM strip and empty-file check all live in
	// cfg.ReadConfigFile -- shared with cmd/meshghost-relay, which was carrying
	// the identical sequence. What is NOT shared is the missing-file message
	// below: with the client autostarted there is no console showing which
	// folder it was launched from, so a player needs telling.
	data, shown, err := cfg.ReadConfigFile(path, "meshghost")
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("meshghost: warning: could not read config file %s: %v", shown, err)
			return shown
		}
		// Missing was silent until autostart landed. Silence is fine when a
		// developer passes flags on purpose, and actively misleading for a
		// player whose only feedback channel is this file: every setting they
		// typed is being ignored and there was nothing anywhere saying so.
		log.Printf("meshghost: no config file at %s -- using built-in defaults "+
			"(connect_to 127.0.0.1:7777). If you edited a config.json somewhere else, "+
			"that is not the one being read.", shown)
		return shown
	}
	log.Printf("meshghost: config loaded from %s", shown)
	if data == nil {
		return shown
	}
	var rc rootConfig
	if err := json.Unmarshal(data, &rc); err != nil {
		if !cfg.ApplyDespiteBadValue(err, shown, "meshghost") {
			return shown
		}
	}
	if rc.Client == nil {
		log.Printf("meshghost: warning: config file %s has no \"client\" section -- "+
			"every client setting is falling back to its built-in default", shown)
		return shown
	}
	fc := *rc.Client
	cfg.Override(explicit, "relay", t.relayAddr, fc.Relay)
	cfg.Override(explicit, "bridge", t.bridgeAddr, fc.Bridge)
	cfg.Override(explicit, "game", t.gameID, fc.Game)
	cfg.Override(explicit, "room", t.room, fc.Room)
	cfg.Override(explicit, "name", t.name, fc.Name)
	cfg.Override(explicit, "name-color", t.nameColor, fc.NameColor)
	cfg.OverrideDuration(explicit, "interp", t.interp, fc.Interp, shown, "meshghost", "interp")
	cfg.OverrideDuration(explicit, "local-interp", t.localInterp, fc.LocalInterp, shown, "meshghost", "local_interp")
	cfg.OverrideDuration(explicit, "min-send", t.minSend, fc.MinSend, shown, "meshghost", "min_send")
	cfg.OverrideDuration(explicit, "keepalive", t.keepalive, fc.Keepalive, shown, "meshghost", "keepalive")
	cfg.OverrideDuration(explicit, "extrapolate", t.extrapolate, fc.Extrapolate, shown, "meshghost", "extrapolate")
	cfg.Override(explicit, "curve", t.curve, fc.Curve)
	cfg.Override(explicit, "predict", t.predict, fc.Predict)
	cfg.OverrideDuration(explicit, "stats", t.stats, fc.Stats, shown, "meshghost", "stats")
	cfg.Override(explicit, "room-code", t.roomCode, fc.RoomCode)
	cfg.Override(explicit, "game-version", t.gameVersion, fc.GameVersion)
	cfg.Override(explicit, "max-receive-hz-per-player", t.maxReceiveHz, fc.MaxReceiveHzPerPlayer)
	cfg.Override(explicit, "ghost-collision", t.ghostCollision, fc.GhostCollision)
	cfg.Override(explicit, "transport", t.transport, fc.Transport)
	cfg.Override(explicit, "tls", t.tlsMode, fc.TLS)
	cfg.Override(explicit, "tls-fingerprint", t.tlsPin, fc.TLSFingerprint)
	cfg.Override(explicit, "show-console", t.showConsole, fc.ShowConsole)
	cfg.Override(explicit, "offline", t.offline, fc.Offline)
	if fc.Features != nil && !explicit["features"] {
		// The one setting that is not a straight copy: joined rather than kept as
		// a list, so the config file and the flag resolve to one representation
		// and the flag stays a plain string.
		*t.features = strings.Join(*fc.Features, ",")
	}
	if fc.Replay != nil {
		if t.recordOnLaunch != nil {
			cfg.Override(explicit, "record-on-launch", t.recordOnLaunch, fc.Replay.RecordOnLaunch)
		}
		if t.saveLast != nil {
			cfg.OverrideDuration(explicit, "replay-save-last", t.saveLast, fc.Replay.SaveLast, shown, "meshghost", "replay.save_last")
		}
		if t.replayStart != nil {
			cfg.OverrideDuration(explicit, "replay-start-delay", t.replayStart, fc.Replay.StartDelay, shown, "meshghost", "replay.start_delay")
		}
		if t.replaySeek != nil {
			cfg.OverrideDuration(explicit, "replay-seek", t.replaySeek, fc.Replay.Seek, shown, "meshghost", "replay.seek")
		}
		if t.splitTimes != nil {
			cfg.Override(explicit, "replay-split-times", t.splitTimes, fc.Replay.SplitTimes)
		}
	}
	if fc.Chaser != nil && t.chaser != nil {
		ch := fc.Chaser
		cfg.Override(explicit, "chaser", t.chaser.enabled, ch.Enabled)
		cfg.Override(explicit, "chaser-count", t.chaser.count, ch.Count)
		cfg.OverrideDuration(explicit, "chaser-delay", t.chaser.delay, ch.Delay, shown, "meshghost", "chaser.delay")
		cfg.OverrideDuration(explicit, "chaser-spacing", t.chaser.spacing, ch.Spacing, shown, "meshghost", "chaser.spacing")
		cfg.Override(explicit, "chaser-name", t.chaser.name, ch.Name)
		cfg.Override(explicit, "chaser-color", t.chaser.color, ch.Color)
		cfg.Override(explicit, "chaser-contact", t.chaser.contact, ch.Contact)
		if t.chaser.spawnDelay != nil {
			cfg.OverrideDuration(explicit, "chaser-spawn-delay", t.chaser.spawnDelay, ch.SpawnDelay, shown, "meshghost", "chaser.spawn_delay")
		}
	}
	if fc.Hotkeys != nil && t.hotkeys != nil {
		h := fc.Hotkeys
		cfg.Override(explicit, "hotkey-record", t.hotkeys.recordToggle, h.RecordToggle)
		cfg.Override(explicit, "hotkey-save-last", t.hotkeys.saveLast, h.SaveLast)
		cfg.Override(explicit, "hotkey-replay-last", t.hotkeys.replayLast, h.ReplayLast)
		cfg.Override(explicit, "hotkey-replay-restart", t.hotkeys.replayRestart, h.ReplayRestart)
		cfg.Override(explicit, "hotkey-replay-rewind", t.hotkeys.replayRewind, h.ReplayRewind)
		cfg.Override(explicit, "hotkey-replay-fast-forward", t.hotkeys.replayFastForward, h.ReplayFastForward)
	}
	return shown
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
	backoff := core.InitialReconnectBackoff
	for {
		err := c.ConnectRelayOnAdapterHello(gameID, "", nil)
		if err == nil {
			return
		}
		if core.IsPermanentRejectErr(err) {
			log.Fatalf("meshghost: %v", err)
		}
		time.Sleep(backoff)
		backoff = core.NextReconnectBackoff(backoff)
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
// on that (core.Core.handleBridgeConn), so a real leave is sent either
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

// wineHasNoUsableConsole reports whether a requested console window cannot
// actually appear, which is the case under Wine (Proton on Linux, CrossOver on
// macOS).
//
// Wine only emulates a Windows console through wineconsole/conhost, and a
// Proton-launched game has no usable backend for it, so AllocConsole can report
// success while producing no window at all. This exists purely so the client can
// SAY that, rather than silently doing nothing.
//
// Confirmed by the Linux tester 2026-08-16: the client logged that it was
// showing a console, and no window ever appeared. There was briefly a default
// here that turned the console ON under Wine, as a safety valve in case an
// autostarted client outlived its game there. Both halves of that turned out to
// be wrong -- the window cannot appear, and the same test proved -exit-with-pid
// reaps the client across the Wine boundary anyway (six sessions, every one
// ending in "pid N is gone -- exiting"). So the valve guarded a door that was
// already shut, with a lock that did not work.
// bridgeIsLoopback reports whether addr binds the adapter bridge to loopback
// only. An empty host ("" from ":7778") and "0.0.0.0"/"::" all bind every
// interface, which is the case this exists to catch.
//
// Why this is a refusal and not a warning: the bridge has NO authentication at
// all -- no room code, no hello check -- and needs none GIVEN that it is
// loopback, which core.Core's doc comment states as a fact. Bound to a routable
// address it becomes an open "drive my game and read my whole session" service
// for anyone on the LAN. The realistic path there is not a typo but config
// sharing: config.json is the file a host sends friends, and
// "local_game_bridge" sits in it beside the settings they are meant to edit.
func bridgeIsLoopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		// Not parseable as host:port -- let net.Listen produce the real error
		// rather than refusing for a reason we would be guessing at.
		return true
	}
	if host == "" {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	// A hostname. "localhost" is the only one worth special-casing; anything
	// else would need a DNS lookup to judge, and a bridge address that has to
	// be resolved is already outside what this flag is for.
	return strings.EqualFold(host, "localhost")
}

func wineHasNoUsableConsole(requested, underWine bool) bool {
	return requested && underWine
}

func main() {
	relayAddr := flag.String("relay", "127.0.0.1:7777", "relay address to connect to")
	bridgeAddr := flag.String("bridge", "127.0.0.1:7778", "address to listen on for the adapter bridge")
	bridgeAllowRemote := flag.Bool("bridge-allow-remote", false,
		"allow -bridge to bind a non-loopback address. The bridge has NO authentication, so this "+
			"exposes driving your game and reading your session to anyone who can reach it. "+
			"Refused without this flag.")
	gameID := flag.String("game", "", "game_id to advertise to the relay -- optional now that a "+
		"real adapter's own Hello declares it (bridge.Hello); set this to connect at "+
		"startup instead of waiting for one, e.g. for dev/testing scripts with no adapter attached")
	room := flag.String("room", "default", "room name to join")
	// EMPTY BY DEFAULT, and that is the feature. A name is opt-in: leave it unset and no
	// nametag is drawn over your ghost at all. The old default was "player", which put the
	// SAME label over every ghost in the room -- a nametag that identifies nobody is worse
	// than none, and it also broadcast a name for people who never asked to have one shown.
	// User's call, 2026-08-28: "if its blank it should not display/do anything, it should
	// only have a text box/show something if a custom name is put in".
	name := flag.String("name", "", "display name to show above your ghost for other players. Empty (the default) means no nametag is drawn for you at all; set it only if you want to be labelled. Sanitized by the relay before anyone sees it -- see protocol.SanitizeDisplayName")
	nameColor := flag.String("name-color", "", "colour to draw your nametag in, as a hex code like \"#F54927\" (\"#F00\" shorthand works too). Ignored unless -name is set, since with no name there is no tag to colour. Anything that is not a hex colour is dropped and the game's own default is used -- a bad colour never stops you connecting")
	interp := flag.Duration("interp", core.DefaultInterpolationDelay,
		"interpolation delay for remote ghosts (e.g. 200ms) — how far behind the most recent "+
			"samples remotes are rendered, to smooth over network jitter")
	localInterp := flag.Duration("local-interp", core.DefaultLocalGhostDelay,
		"render delay for a LOCAL ghost -- a replay or a chaser. Nothing to do with the network: "+
			"-interp is the jitter buffer for other players, and a chaser 3s behind you must be drawn "+
			"3s behind you, not 3s+interp. A sample interval or two, enough to interpolate between the "+
			"last two samples instead of holding the newest one")
	lossCover := flag.Bool("loss-cover", true,
		"carry the previous sample inside every state sent at 25Hz or slower, so one lost packet costs "+
			"the receiver nothing (ADR 0045). On by default; -loss-cover=false is the A/B switch for a "+
			"dev run, not a setting a player needs")
	minSend := flag.Duration("min-send", 0,
		"a FLOOR on how slowly you send your position to the relay -- leave this unset (0) to "+
			"just adopt whatever rate the relay advertises (see -send-hz on the relay side; "+
			"defaults to 15Hz/~67ms if the relay doesn't advertise one at all). Setting this only "+
			"ever makes you send SLOWER than the room, never faster: it's for a poor connection "+
			"that wants to opt out of a fast room, not a way to exceed what the relay allows. "+
			"e.g. 100ms means 'send at most 10 times/sec even if this room runs faster'")
	curve := flag.String("curve", string(core.CurveLinear),
		"how a ghost's position BETWEEN two samples is computed: \"linear\" (the default, a "+
			"straight line) or \"catmull-rom\" (a curve fitted through four samples, so an arc "+
			"renders as an arc). The curve is smoother than the samples imply, which is right for "+
			"a game with real momentum and wrong for one that moves on a fixed beat -- judge it "+
			"per game on screen. On a straight path the two are identical")
	extrapolate := flag.Duration("extrapolate", 0,
		"OPT-IN, default off. How far past a peer's newest sample to keep moving their ghost "+
			"along its last measured velocity, e.g. 100ms. It removes the visible half of "+
			"-interp -- a ghost drawn where the peer probably IS rather than where they were -- "+
			"and pays for it with a correction every time the peer does something the prediction "+
			"did not. Only does anything alongside a SMALL -interp: at the shipped 250ms the "+
			"render time never reaches the newest sample. Judge it per game on screen; a game "+
			"that moves on a fixed beat is where it is most likely to look wrong")
	predict := flag.String("predict", string(core.PredictLinear),
		"how a ghost is carried past its newest sample when -extrapolate is on: \"linear\" "+
			"(continue the last measured velocity) or \"accelerated\" (fit the curvature too, so "+
			"a jump is predicted along its arc). Accelerated models a jump properly but estimates "+
			"a SECOND derivative from network samples, which amplifies jitter -- judge it on screen")
	keepalive := flag.Duration("keepalive", core.DefaultIdleKeepalive,
		"how often to re-send your position when NOTHING about it has changed. Identical states "+
			"are otherwise skipped -- a standing player sends the same packet at the room's full "+
			"rate for nothing -- and this is the floor that keeps the relay, a late joiner and a "+
			"lossy udp link from ever being more than this far behind. 0 disables the skipping "+
			"entirely and sends every frame, which is what this client did before 2026-08-28")
	stats := flag.Duration("stats", 0, "log a one-line client stats summary this often (e.g. 10s); "+
		"0 disables it. The client-side counterpart to the relay's -introspect: link health (rtt, "+
		"clock offset), how many peers are known versus actually rendered, bytes sent and received "+
		"with an hourly rate, and what share of received remote states this client threw away "+
		"because the sender was in another area. Costs nothing when off, and one log line when on")
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
	ghostCollision := flag.String("ghost-collision", "",
		"this player's own ghost collision preference: \"disabled\" turns ghost "+
			"collision off for you whatever the room is set to. \"enabled\" or empty "+
			"accepts the host's choice -- it cannot force collision on in a room where "+
			"the host turned it off")
	transportName := flag.String("transport", netx.Auto.String(),
		"which transport to move to AFTER connecting. The handshake is always tcp and this "+
			"cannot be changed -- so you never need to know which port a transport is on, and a "+
			"preference the relay does not serve degrades to a working tcp session instead of a "+
			"timeout. auto (the default): take the best on offer, preferring quic, and never udp "+
			"unless it is all there is. tcp: stay on tcp (reliable, and the only one readable "+
			"with netcat while debugging). udp: upgrade if the relay serves it -- better on a "+
			"lossy connection, but CANNOT be encrypted (Go has no DTLS), so your room code "+
			"crosses the wire in the clear. quic: same loss behaviour as udp but encrypted and "+
			"hard to spoof")
	tlsMode := flag.String("tls", tlsx.Auto.String(),
		"encrypt the connection to the relay: auto (the default), off, or required. This covers "+
			"the tcp handshake every client makes -- the one that carries your room code -- so it "+
			"is worth setting even when -transport is quic, which only encrypts what comes after. "+
			"auto (the default): use TLS when the relay speaks it, and warn loudly in the log if "+
			"it does not -- so a plain relay still works, it just says so. "+
			"required: refuse to send anything to a relay that is not encrypted. The relay's "+
			"certificate is self-signed, so this stops someone READING your traffic; to also stop "+
			"someone impersonating the relay, ask the host for the fingerprint their relay prints "+
			"at startup and put it in -tls-fingerprint")
	tlsPin := flag.String("tls-fingerprint", "",
		"the relay certificate fingerprint you were given by the host, out of band. When set, a "+
			"relay presenting anything else is refused instead of trusted. Empty (the default) "+
			"means an encrypted session with no proof of who is on the other end. Note the relay "+
			"regenerates its certificate every restart, so this has to be updated when the host "+
			"restarts theirs")
	exitWithPID := flag.Int("exit-with-pid", 0,
		"exit when the process with this pid does -- set by a game adapter that starts this "+
			"client for you, so a crashed game can't leave an invisible orphan holding the bridge "+
			"port. 0 (the default) means don't watch anything. Deliberately not a config.json "+
			"setting: it's a per-launch fact from whoever spawned us, not something a player configures")
	offline := flag.Bool("offline", false,
		"play alone: never dial a relay, join no room, and see no peers. Recording, replays and "+
			"chasers all still work -- they never needed one -- and the game's mod still connects to "+
			"this client exactly as it always does. Without this, a client with no relay to reach "+
			"retries forever and says so in the log (config: offline)")
	showConsole := flag.Bool("show-console", false,
		"open a console window and mirror the log to it. Only meaningful when a game adapter "+
			"started this client (it spawns us with no window on purpose); a client you ran "+
			"yourself already has the terminal you ran it from. For \"is it actually running?\" -- "+
			"the log file answers the same question either way. Ignored on non-Windows")
	features := flag.String("features", "",
		"comma-separated capabilities to negotiate beyond the cosmetic ghost overlay, e.g. "+
			"\"event.v1,lease.v1,escrow.v1\". Empty (the default) is cosmetic only and is what "+
			"every shipped adapter uses. EVERYONE in a room must pass the same set -- a "+
			"mismatch is refused at the handshake, on purpose, because a room where one client "+
			"arbitrates and another doesn't fails silently and much later. See "+
			"agent_docs/beyond-cosmetic.md")
	replayDir := flag.String("replay-dir", "",
		"folder recordings are written to and replays are read from (replay/active/ plays on launch). "+
			"Empty (the default) means the replay/ folder beside the config file")
	recordOnLaunch := flag.Bool("record-on-launch", false,
		"record the whole session to the replay folder: the file starts at the first in-game sample "+
			"after the game's mod attaches and ends when the game closes (config: replay.record_on_launch)")
	saveLast := flag.Duration("replay-save-last", 30*time.Second,
		"how many seconds of recent play the save-last hotkey writes out (config: replay.save_last)")
	chaserOn := flag.Bool("chaser", false, "follow yourself: a pack of your own past as cosmetic ghosts (config: chaser.enabled)")
	chaserCount := flag.Int("chaser-count", 1, "how many chasers (1-8; config: chaser.count)")
	chaserDelay := flag.Duration("chaser-delay", 3*time.Second, "how far behind you the first chaser runs (config: chaser.delay)")
	chaserSpacing := flag.Duration("chaser-spacing", 2*time.Second, "how much further behind each next chaser runs (config: chaser.spacing)")
	chaserName := flag.String("chaser-name", "Chaser", "the chasers' nametag; numbered when there are several (config: chaser.name)")
	chaserColor := flag.String("chaser-color", "#7A2A2A", "the chasers' nametag colour (config: chaser.color)")
	chaserSpawn := flag.Duration("chaser-spawn-delay", 0, "a chaser appears only once you have been moving for this long; 0 means the chaser's own delay (config: chaser.spawn_delay)")
	chaserContact := flag.Bool("chaser-contact", false, "tell the adapter a chaser may hurt on touch (config: chaser.contact); no shipped adapter honours this yet")
	hkRecord := flag.String("hotkey-record", "ctrl+shift+F9", "system-wide chord: start/stop recording (config: hotkeys.record_toggle); empty unbinds")
	hkSaveLast := flag.String("hotkey-save-last", "ctrl+shift+F10", "system-wide chord: save the last replay.save_last seconds (config: hotkeys.save_last)")
	hkReplayLast := flag.String("hotkey-replay-last", "ctrl+shift+F11", "system-wide chord: play the newest recording now (config: hotkeys.replay_last)")
	hkRestart := flag.String("hotkey-replay-restart", "ctrl+shift+F5", "system-wide chord: restart every replay ghost (config: hotkeys.replay_restart)")
	hkRewind := flag.String("hotkey-replay-rewind", "ctrl+shift+F6", "system-wide chord: rewind every replay ghost by replay.seek (config: hotkeys.replay_rewind)")
	hkFastForward := flag.String("hotkey-replay-fast-forward", "ctrl+shift+F7", "system-wide chord: fast-forward every replay ghost by replay.seek (config: hotkeys.replay_fast_forward)")
	splitTimes := flag.Bool("replay-split-times", false, "show how far behind or ahead of a replay ghost you are on its nametag, e.g. \"PB +1.2s\" (config: replay.split_times)")
	replaySeek := flag.Duration("replay-seek", 5*time.Second,
		"how far one rewind or fast-forward moves a replay ghost (config: replay.seek)")
	replayStart := flag.Duration("replay-start-delay", 0,
		"how long after your first in-game frame a replay ghost starts, for files whose own "+
			"header start_delay is 0s (config: replay.start_delay)")
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file with a \"client\" section "+
			"(connect_to/local_game_bridge/game/room/name/interp/local_interp/curve/extrapolate/min_send/keepalive/stats/room_code/game_version/"+
			"max_receive_hz_per_player/transport/show_console/features/replay/hotkeys/chaser) -- a friendlier alternative to flags for non-developer use; "+
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

	explicit := cfg.ExplicitFlags()

	configShown := applyFileConfig(*configPath, explicit, configTargets{
		relayAddr:      relayAddr,
		bridgeAddr:     bridgeAddr,
		gameID:         gameID,
		room:           room,
		name:           name,
		nameColor:      nameColor,
		interp:         interp,
		localInterp:    localInterp,
		minSend:        minSend,
		keepalive:      keepalive,
		extrapolate:    extrapolate,
		curve:          curve,
		predict:        predict,
		stats:          stats,
		roomCode:       roomCode,
		gameVersion:    gameVersion,
		maxReceiveHz:   maxReceiveHz,
		ghostCollision: ghostCollision,
		transport:      transportName,
		tlsMode:        tlsMode,
		tlsPin:         tlsPin,
		showConsole:    showConsole,
		offline:        offline,
		features:       features,
		recordOnLaunch: recordOnLaunch,
		saveLast:       saveLast,
		replayStart:    replayStart,
		replaySeek:     replaySeek,
		splitTimes:     splitTimes,
		hotkeys: &hotkeyTargets{recordToggle: hkRecord, saveLast: hkSaveLast, replayLast: hkReplayLast,
			replayRestart: hkRestart, replayRewind: hkRewind, replayFastForward: hkFastForward},
		chaser: &chaserTargets{enabled: chaserOn, count: chaserCount, delay: chaserDelay, spacing: chaserSpacing,
			name: chaserName, color: chaserColor, contact: chaserContact, spawnDelay: chaserSpawn},
	})
	if *replayDir == "" {
		// Beside the config file, read or not: that is the one folder a player
		// autostarted by their game can find, and the one the README names.
		*replayDir = filepath.Join(filepath.Dir(configShown), "replay")
	}
	// BOTH FOLDERS ARE CREATED HERE, EMPTY, AND active/ IS THE ONE THAT MATTERS.
	//
	// Until 2026-09-03 nothing ever created replay/active/. The recorder made
	// replay/ on the first recording, so that one at least appeared eventually,
	// but active/ is READ and never written: StartReplays calls ReadDir on it and
	// returns 0 on ErrNotExist without logging, deliberately, so a player who had
	// not made the folder got silence. docs/config.md meanwhile says "drop a file
	// into replay/active/ and it plays" -- an instruction naming a folder that did
	// not exist and that nothing would create.
	//
	// An empty folder IS the documentation here: it shows where a clip goes
	// without the player having to read anything or type a path correctly. The
	// release ships both too (dev-scripts/stage-release.ps1) so they are there on
	// first unzip, before this ever runs.
	//
	// Failure is not fatal, and deliberately quiet at info level: a read-only
	// install directory is a real thing, and it should cost a player replays, not
	// the session. StartReplays reports the consequence if it comes to that.
	if err := os.MkdirAll(filepath.Join(*replayDir, "active"), 0o755); err != nil {
		log.Printf("could not create %s (replays will not load from it): %v",
			filepath.Join(*replayDir, "active"), err)
	}

	// stderr stays in the list unconditionally: when this client was run from a
	// terminal that IS the live output, and when it was spawned with no window
	// the writes simply go nowhere. cfg.OpenLogFile returns nil if the file could
	// not be opened, which is survivable rather than fatal -- losing the log is
	// worth saying loudly, but not worth refusing to play over.
	writers := []io.Writer{os.Stderr}
	if f := cfg.OpenLogFile("meshghost.log", "meshghost"); f != nil {
		writers = append(writers, f)
	}
	// The Wine check is deliberately independent of whether consoleWriter
	// succeeded: under Wine AllocConsole can report success and still produce no
	// visible window, so a non-nil writer proves nothing there. Warn on the
	// request, not on the result.
	noConsolePossible := wineHasNoUsableConsole(*showConsole, runningUnderWine())
	if *showConsole {
		if w := consoleWriter(); w != nil {
			writers = append(writers, w)
		}
	}
	out := io.MultiWriter(writers...)
	log.SetOutput(out)

	logRunBanner(*exitWithPID != 0)
	_, _ = io.Copy(out, &earlyLog)

	if noConsolePossible {
		log.Printf("meshghost: show_console is on, but this is running under Wine " +
			"(Proton/CrossOver), which has no usable console window -- one will not appear no " +
			"matter what this is set to. Everything it would have shown is in this file " +
			"(meshghost.log) instead.")
	}

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

	// Fatal on a bad value, same reasoning as -transport directly above:
	// tlsx.Off is the zero value, so a lenient parse would hand someone who
	// typed "requried" an unencrypted session with no complaint.
	tlsChoice, err := tlsx.ParseMode(*tlsMode)
	if err != nil {
		log.Fatalf("meshghost: %v", err)
	}
	if tlsChoice == tlsx.Required && transportKind == netx.UDP {
		log.Fatalf("meshghost: -transport udp cannot be encrypted (Go has no DTLS) and -tls is "+
			"%q. Choose quic (encrypted, same loss behaviour) or tcp, or set -tls off if you "+
			"really want plaintext udp.", tlsChoice)
	}

	c := core.New()
	c.Transport = transportKind
	c.TLS = tlsChoice
	c.TLSFingerprint = *tlsPin
	c.InterpolationDelay = *interp
	c.LocalInterpolationDelay = *localInterp
	c.Offline = *offline
	if !*lossCover {
		c.RedundancyMinInterval = -1
	}
	c.MinSendInterval = *minSend
	c.IdleKeepalive = *keepalive
	c.Extrapolate = *extrapolate
	switch core.PredictMode(*predict) {
	case core.PredictLinear, core.PredictAccelerated, core.PredictDamped:
		c.Predict = core.PredictMode(*predict)
	default:
		log.Fatalf("meshghost: -predict %q is not a prediction model -- use %q, %q or %q",
			*predict, core.PredictLinear, core.PredictDamped, core.PredictAccelerated)
	}
	switch core.CurveMode(*curve) {
	case core.CurveLinear, core.CurveCatmullRom:
		c.Curve = core.CurveMode(*curve)
	default:
		// Refused rather than silently ignored: a typo here changes how every
		// ghost moves, and a run that quietly used the default while its
		// launcher said otherwise is exactly the ambiguity the smoothing log
		// line below exists to remove.
		log.Fatalf("meshghost: -curve %q is not a render curve -- use %q or %q",
			*curve, core.CurveLinear, core.CurveCatmullRom)
	}
	// SAY WHICH SMOOTHING THIS RUN IS USING. These two decide how a ghost moves
	// on screen more than anything else the client does, and until 2026-08-23
	// neither appeared in the log -- so a session could not tell afterwards
	// which rig had produced a recording of a stutter. Crystal lost two rounds
	// of renderer work to exactly that: with no launcher of its own the adapter
	// autostarted a core on the defaults, the settings were right by accident
	// and unrecorded, and a quarter second of interpolation was investigated as
	// a renderer fault (`agent_docs/phases/phase9.md`). A log line is cheaper
	// than the ambiguity.
	// "the shipped values" is the part a reader needs: a dev rig is only worth
	// noticing when it has departed from what a player would actually run.
	smoothingNote := " (NOT the shipped defaults -- this is a dev rig)"
	if *interp == core.DefaultInterpolationDelay && *localInterp == core.DefaultLocalGhostDelay &&
		*minSend == 0 && *extrapolate == 0 && c.Curve == core.CurveLinear {
		smoothingNote = " (the shipped defaults)"
	}
	// The keepalive belongs on this line for the same reason the other two do:
	// it decides how long a receiver can be working from a state this client has
	// stopped restating, so a recording of a stutter has to say what it was.
	keepaliveNote := ", unchanged states re-sent every " + keepalive.String()
	if *keepalive <= 0 {
		keepaliveNote = ", change suppression OFF (every frame sent)"
	}
	if c.Curve != core.CurveLinear {
		keepaliveNote += ", curve " + string(c.Curve)
	}
	if c.Predict != core.PredictLinear {
		keepaliveNote += ", prediction " + string(c.Predict)
	}
	if *extrapolate > 0 {
		keepaliveNote += ", EXTRAPOLATING up to " + extrapolate.String() + " past the newest sample"
	}
	log.Printf("meshghost: smoothing: interpolation delay %s, minimum send interval %s%s%s",
		*interp, *minSend, keepaliveNote, smoothingNote)
	c.MaxReceiveHz = *maxReceiveHz
	// Only ever restrictive: "enabled" here does not override a host who
	// turned collision off. protocol.ResolveGhostCollision is where that is
	// actually enforced -- this just carries the preference.
	c.GhostCollision = *ghostCollision
	c.Features = parseFeatures(*features)
	c.ReplayDir = *replayDir
	c.RecordOnLaunch = *recordOnLaunch
	c.SaveLastSpan = *saveLast
	c.ReplayStartDelay = *replayStart
	c.ReplaySeek = *replaySeek
	c.SplitTimes = *splitTimes
	c.ChaserEnabled, c.ChaserCount, c.ChaserDelay, c.ChaserSpacing = *chaserOn, *chaserCount, *chaserDelay, *chaserSpacing
	c.ChaserName, c.ChaserColor, c.ChaserContact = *chaserName, *chaserColor, *chaserContact
	c.ChaserSpawnDelay = *chaserSpawn
	if *chaserOn {
		log.Printf("meshghost: chaser ON -- %d ghost(s) of your own past, %s behind and then every %s", *chaserCount, *chaserDelay, *chaserSpacing)
	}
	startHotkeys(c, []hotkeyBinding{
		{core.ReplayRecordToggle, *hkRecord},
		{core.ReplaySaveLast, *hkSaveLast},
		{core.ReplayLast, *hkReplayLast},
		{core.ReplayRestart, *hkRestart},
		{core.ReplayRewind, *hkRewind},
		{core.ReplayFastForward, *hkFastForward},
	})
	if *recordOnLaunch {
		log.Printf("meshghost: record_on_launch is ON -- every session is written to %s from the first in-game sample", *replayDir)
	}
	c.RelayAddr = *relayAddr
	c.Room = *room
	c.DisplayName = *name
	c.NameColor = *nameColor
	c.RoomCode = *roomCode
	c.GameVersion = *gameVersion
	c.DialTimeout = 5 * time.Second
	c.OnRelayConnected = func(gameID string) {
		log.Printf("meshghost: connected to relay %s as %s in room %q (game %q)", *relayAddr, c.PlayerID(), *room, gameID)
	}

	if *stats > 0 {
		// With stats on, a dry render also gets its own line (at most one a
		// second): which samples sat either side of the hole. The line is
		// written from the render path under c.mu, so keep it to log.Print.
		c.DryLog = func(line string) { log.Print(line) }
		// Its own goroutine rather than folded into an existing tick: this is
		// a diagnostic, and it must not be able to slow the state path down or
		// change its timing. Stats() takes c.mu only briefly and reads the
		// counters atomically.
		go func() {
			t := time.NewTicker(*stats)
			defer t.Stop()
			for range t.C {
				log.Print(c.Stats())
			}
		}()
		log.Printf("meshghost: stats on -- summary every %s", *stats)
	}

	if *exitWithPID != 0 {
		log.Printf("meshghost: watching pid %d -- will exit when it does", *exitWithPID)
		go watchParentPID(*exitWithPID, parentGone, parentPollInterval, func() {
			log.Printf("meshghost: pid %d is gone -- exiting so nothing is left holding %s",
				*exitWithPID, *bridgeAddr)
			os.Exit(0)
		})
	}

	switch {
	case *offline:
		// One line, and no retry goroutine. The bridge listener below still
		// binds -- it is how the game's mod attaches, so without it nothing
		// renders at all -- and core.Offline also refuses the dial an
		// adapter's own hello would otherwise start.
		log.Printf("meshghost: OFFLINE -- not connecting to a relay, so no room and no other " +
			"players. Recording, replays and chasers all still work. Remove \"offline\" from " +
			"config.json (or pass -offline=false) to play with other people.")
	case *gameID != "":
		// Backgrounded, not blocking: the bridge listener below starts
		// immediately regardless of whether the relay is reachable yet —
		// see connectRelayWithRetry's doc comment.
		go connectRelayWithRetry(c, *gameID)
	default:
		log.Printf("meshghost: no game set -- waiting for a game to connect and say hello...")
	}

	if !bridgeIsLoopback(*bridgeAddr) && !*bridgeAllowRemote {
		log.Fatalf(`meshghost: REFUSING to bind the adapter bridge to %s.
  The bridge has no authentication of any kind -- it does not need any while it is
  loopback-only, which is what this check enforces. On a routable address it lets
  anyone who can reach this machine drive your game and read your whole session.
  If you set this in config.json's "local_game_bridge", change it back to
  127.0.0.1:7778 -- that field is local by design and is not how you reach a relay;
  "connect_to" is. If you genuinely meant it, pass -bridge-allow-remote.`, *bridgeAddr)
	}
	if *bridgeAllowRemote && !bridgeIsLoopback(*bridgeAddr) {
		log.Printf("meshghost: WARNING -- the adapter bridge is bound to %s, which is NOT loopback, "+
			"and it has no authentication. Anyone who can reach this address can drive your game "+
			"and read your session.", *bridgeAddr)
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

// parseFeatures turns the comma-separated -features value into the list this
// client advertises. Unknown names are passed through rather than rejected:
// the relay compares capability sets by equality and never interprets a name,
// so a future capability this build has not heard of must still be able to
// travel through it — the same forward-compatibility posture as unknown
// fields and unknown message types.
func parseFeatures(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return protocol.NormalizeFeatures(strings.Split(s, ","))
}

// hotkeyBinding pairs a replay action with the chord a player wrote for it.
type hotkeyBinding struct {
	action core.ReplayAction
	chord  string
}

// startHotkeys parses the chords and runs the system-wide key loop for the
// rest of the process (ADR 0048). Every outcome is logged, and none is fatal:
// a chord that fails to parse or that another program already owns is skipped
// alone, and the rest still work. Empty chords are simply unbound.
func startHotkeys(c *core.Core, bindings []hotkeyBinding) {
	var actions []hotkey.Action
	for _, b := range bindings {
		if strings.TrimSpace(b.chord) == "" {
			continue
		}
		parsed, err := hotkey.Parse(b.chord)
		if err != nil {
			log.Printf("meshghost: hotkey for %s not bound: %v", b.action, err)
			continue
		}
		actions = append(actions, hotkey.Action{Name: string(b.action), Binding: parsed})
	}
	if len(actions) == 0 {
		return
	}
	fire := func(name string) {
		// The key loop's own thread must never wait on the core: a seek waits
		// for a render tick, and the recorder flushes to disk.
		go func() {
			if err := c.ReplayControl(core.ReplayAction(name), 0); err != nil {
				log.Printf("meshghost: hotkey %s: %v", name, err)
			} else {
				log.Printf("meshghost: hotkey %s: done", name)
			}
		}()
	}
	report := func(r hotkey.Result) {
		if r.Err != nil {
			log.Printf("meshghost: hotkey %s (%s) NOT registered: %v", r.Name, r.Binding, r.Err)
			return
		}
		log.Printf("meshghost: hotkey %s bound to %s (system-wide; works with the game focused)", r.Name, r.Binding)
	}
	go func() {
		if err := hotkey.Run(actions, fire, report, make(chan struct{})); err != nil {
			log.Printf("meshghost: hotkeys stopped: %v", err)
		}
	}()
}
