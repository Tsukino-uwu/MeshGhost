// Command meshghost is the desktop core process: it connects to a relay and listens for a local adapter over the
// bridge. The implementation is package core.
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
	"os/signal"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"syscall"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/core"
	"github.com/Tsukino-uwu/MeshGhost/internal/cfg"
	"github.com/Tsukino-uwu/MeshGhost/internal/hotkey"
	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/netx/quicconn"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// logRunBanner marks where a run starts in the appending log, with what support conversations have guessed wrong:
// which executable runs, the folder its config and log come from, and whether an adapter or a person started it.
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

// fileConfig is the "client" section of the optional JSON config file (-config), a player's alternative to flags.
// Pointer fields tell absent from zero, so the file overrides only what it mentions. The JSON names are player-facing
// and differ from the flags: "connect_to" is where you connect out to, and "local_game_bridge" never leaves the
// machine. Old spellings still read (clientKeyRenames); the wire field protocol.Hello.Room is still "room", a
// contract with anyone who integrates.
type fileConfig struct {
	Relay     *string `json:"connect_to"`
	Bridge    *string `json:"local_game_bridge"`
	Game      *string `json:"game"`
	Room      *string `json:"room_name"`
	Name      *string `json:"player_name"`
	NameColor *string `json:"player_name_color"`
	Interp    *string `json:"interp"`
	// LocalInterp is the render delay for a local ghost (a replay or a chaser), a different job from Interp.
	LocalInterp *string `json:"local_interp"`
	MinSend     *string `json:"min_send"`
	// Keepalive is how often an unchanged state is re-sent (core.Core.IdleKeepalive); "0" sends every frame.
	Keepalive *string `json:"keepalive"`
	// Extrapolate is the opt-in prediction window (core.Core.Extrapolate); absent or "0" holds the newest sample.
	Extrapolate *string `json:"extrapolate"`
	// Curve is "linear" (default) or "catmull-rom" (core.CurveMode).
	Curve *string `json:"curve"`
	// Predict is "linear" (the flag default), "damped" (shipped) or "accelerated" (core.PredictMode).
	Predict *string `json:"predict"`
	// Correction is the error-decay time constant (core.Core.Correction); absent or "0" jumps on every correction.
	Correction *string `json:"correction"`
	// Stats is how often to log the one-line summary, e.g. "10s"; absent or "0" disables it. In the file because a
	// client started by its game gets no flags.
	Stats       *string `json:"stats"`
	RoomCode    *string `json:"room_code"`
	GameVersion *string `json:"game_version"`
	// MaxReceiveHzPerPlayer is the highest rate per other player, not a total, at which the relay forwards their state
	// to this client; absent or 0 is uncapped (core.Core.MaxReceiveHz).
	MaxReceiveHzPerPlayer *int `json:"max_receive_hz_per_player"`
	// GhostCollision is this player's own preference and only restricts: "disabled" turns ghost collision off whatever
	// the room says, "enabled" or absent accepts the host's choice (core.Core.GhostCollision).
	GhostCollision *string `json:"ghost_collision"`
	// Features turns on capabilities beyond the cosmetic overlay (protocol's Feature* constants); absent or empty is
	// cosmetic only. Everyone in a room needs the same list: a client whose list differs is refused at the handshake
	// rather than admitted where half the arbitration silently does not work.
	Features *[]string `json:"features"`
	// Transport is what this client moves to after connecting over tcp: "tcp" stays put, "quic" upgrades if the relay
	// serves it, "auto" takes the best on offer. The relay says what it serves during the handshake, so connect_to
	// needs only the tcp port, and a transport it does not serve degrades to tcp rather than a timeout.
	Transport *string `json:"transport"`
	// TLS and TLSFingerprint are obsolete: every connection is TLS, and the relay's identity is remembered in
	// known_servers.json. Both are still decoded so an old config is judged by checkLegacyTLSKeys, not called unknown.
	TLS            *string `json:"tls"`
	TLSFingerprint *string `json:"tls_fingerprint"`
	// ShowConsole opens a console window for a client an adapter started with none (consoleWriter).
	ShowConsole *bool `json:"show_console"`
	// Offline plays alone: no relay is dialled and no retry loop starts, while recording, replays and chasers work.
	Offline *bool `json:"offline"`
	// Replay is the recording block: record_on_launch writes the whole session to replay/ beside this file, and
	// save_last is how much the save-last hotkey keeps.
	Replay *replayFileConfig `json:"replay"`
	// Hotkeys binds the replay actions to system-wide chords the client registers itself, so they work in every game
	// with no adapter implementing a key; an empty value leaves that action unbound.
	Hotkeys *hotkeyFileConfig `json:"hotkeys"`
	// Chaser is the pack of your own past following you: count ghosts, the first delay behind and each next spacing
	// behind the one before. Cosmetic whatever ghost_collision says.
	Chaser *chaserFileConfig `json:"chaser"`
}

// notClientSettings are keys config.json carries for the game's mod rather than this binary, qualified the way
// cfg.WarnUnknownKeys names a section: to reflection a key the mod reads looks like a typo. Adding one claims another
// reader owns it. TestShippedConfigsProduceNoUnknownKeyWarning pins the list against every shipped config.
var notClientSettings = map[string]bool{
	// Read by every shipped mod.
	"client.autostart": true, // whether the mod starts this client at all
	// Read by one mod each and stripped from the other games' files by stage-release.ps1; the root file has both.
	"client.map_markers":   true, // TEVI's pause-menu peer markers
	"client.input_display": true, // Pseudoregalia's input overlay (a whole subtree)
	// Pseudoregalia's distance tiers, in its per-game config.json.
	"client.ghost_range":          true,
	"client.ghost_range_far":      true,
	"client.ghost_range_throttle": true,
	// The mod draws the recording indicator; the client owns the recording.
	"client.replay.indicator":             true,
	"client.replay.indicator_color":       true,
	"client.replay.indicator_timer_color": true,
}

// clientKeyRenames maps the old spellings of renamed client keys to their current names. cfg.RenameOldKeys applies
// them to the raw bytes before anything decodes the file, so an old config keeps working and the player is told once
// what to rename. They are not notClientSettings entries: an old spelling is this binary's own key, not another
// reader's.
var clientKeyRenames = map[string]string{
	"room":       "room_name",
	"name":       "player_name",
	"name_color": "player_name_color",
}

type chaserFileConfig struct {
	Enabled *bool   `json:"enabled"`
	Count   *int    `json:"count"`
	Delay   *string `json:"delay"`
	Spacing *string `json:"spacing"`
	Name    *string `json:"name"`
	Color   *string `json:"color"`
	// Contact: "off", "hurt" or "kill"; the bool the key once was still reads (chaserContactJSON).
	Contact *chaserContactJSON `json:"contact"`
	// SpawnDelay: a chaser appears only once you have been moving this long, so none spawns on top of you at the
	// start. Absent or "0s" means the chaser's own delay.
	SpawnDelay *string `json:"spawn_delay"`
}

// chaserContactJSON reads chaser.contact as a JSON string ("off", "hurt", "kill") or the legacy bool (true is "hurt",
// the one effect it promised). It only carries the text: core.ParseChaserContact judges it at the override site, so
// a bad word is warned about and skipped rather than failing the whole file.
type chaserContactJSON string

func (m *chaserContactJSON) UnmarshalJSON(b []byte) error {
	var asBool bool
	if err := json.Unmarshal(b, &asBool); err == nil {
		if asBool {
			*m = chaserContactJSON(core.ChaserContactHurt)
		} else {
			*m = chaserContactJSON(core.ChaserContactOff)
		}
		return nil
	}
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return fmt.Errorf("chaser.contact must be \"off\", \"hurt\" or \"kill\", got %s", string(b))
	}
	*m = chaserContactJSON(s)
	return nil
}

// overrideChaserContact is cfg.Override for chaser.contact: the file's word lands only when it names a mode, and
// any other word is warned about and skipped so the settings around it still apply.
func overrideChaserContact(explicit map[string]bool, target *string, value *chaserContactJSON, path string) {
	if value == nil || explicit["chaser-contact"] {
		return
	}
	mode, err := core.ParseChaserContact(string(*value))
	if err != nil {
		log.Printf("meshghost: warning: config file %s: %v -- the previous value stays", path, err)
		return
	}
	*target = string(mode)
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
	// StartDelay is how long after you are in the game a replay ghost starts, for files whose header says 0s.
	StartDelay *string `json:"start_delay"`
	// Seek is how far one rewind or fast-forward key press moves a replay.
	Seek *string `json:"seek"`
	// SplitTimes shows how far behind or ahead of a replay ghost you are on its nametag, e.g. "+1.2s".
	SplitTimes *bool `json:"split_times"`
	// Gzip writes recordings as .ndjson.gz. Off by default: a gzip file cut short when the game closes is refused
	// whole by ordinary tools.
	Gzip *bool `json:"gzip"`
	// Delta writes only the values that changed since the previous sample; the header is untouched, so a clip stays
	// editable.
	Delta *bool `json:"delta"`
	// Inputs also records what you pressed, as a separate track in replay/inputs/ that never plays back as a ghost.
	Inputs *bool `json:"inputs"`
	// Name and Color label the recordings this client writes, the header a replay ghost's nametag reads. Blank falls
	// back to player_name and player_name_color, so a clip is born labelled.
	Name  *string `json:"name"`
	Color *string `json:"color"`
}

// rootConfig is the top-level shape of the config file: a "client" section read here, beside the "server" section
// cmd/meshghost-relay reads from the same file.
type rootConfig struct {
	Client *fileConfig `json:"client"`
}

// configTargets are the flag-backed variables applyFileConfig may overwrite, one per fileConfig field, named at the
// call site rather than passed by position.
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
	correction     *time.Duration
	curve          *string
	predict        *string
	stats          *time.Duration
	roomCode       *string
	gameVersion    *string
	maxReceiveHz   *int
	ghostCollision *string
	transport      *string
	legacyTLS      *string // the obsolete "tls" key, for checkLegacyTLSKeys
	legacyPin      *string // the obsolete "tls_fingerprint" key, likewise
	showConsole    *bool
	offline        *bool
	features       *string
	recordOnLaunch *bool
	saveLast       *time.Duration
	replayStart    *time.Duration
	replaySeek     *time.Duration
	splitTimes     *bool
	replayGzip     *bool
	replayDelta    *bool
	replayInputs   *bool
	replayName     *string
	replayColor    *string
	hotkeys        *hotkeyTargets
	chaser         *chaserTargets
}

type chaserTargets struct {
	enabled        *bool
	count          *int
	delay, spacing *time.Duration
	spawnDelay     *time.Duration
	// contact is the mode's word ("off", "hurt", "kill"), parsed at use.
	name, color, contact *string
}

// hotkeyTargets is where the six chords land; nil entries are skipped so a
// test can pass only the ones it cares about.
type hotkeyTargets struct {
	recordToggle, saveLast, replayLast, replayRestart, replayRewind, replayFastForward *string
}

// applyFileConfig returns the absolute path of the config file it looked for
// (read or not), so callers can place things beside it -- the replay folder.
func applyFileConfig(path string, explicit map[string]bool, t configTargets) string {
	data, shown, err := cfg.ReadConfigFile(path, "meshghost")
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("meshghost: warning: could not read config file %s: %v", shown, err)
			return shown
		}
		// Said, because an autostarted client has no console showing which folder it was launched from.
		log.Printf("meshghost: no config file at %s -- using built-in defaults "+
			"(connect_to 127.0.0.1:7777). If you edited a config.json somewhere else, "+
			"that is not the one being read.", shown)
		return shown
	}
	log.Printf("meshghost: config loaded from %s", shown)
	if data == nil {
		return shown
	}
	// Renamed keys move to their current names first, on the raw bytes, so everything below sees only current names.
	data = cfg.RenameOldKeys(data, "client", clientKeyRenames, shown, "meshghost")
	var rc rootConfig
	if err := json.Unmarshal(data, &rc); err != nil {
		if !cfg.ApplyDespiteBadValue(err, shown, "meshghost") {
			return shown
		}
	}
	// Unknown keys are checked on the raw bytes, the only place one still exists after decoding.
	if sections := clientSection(data); sections != nil {
		cfg.WarnUnknownKeys(sections, fileConfig{}, shown, "meshghost", "client", notClientSettings)
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
	cfg.OverrideDuration(explicit, "correction", t.correction, fc.Correction, shown, "meshghost", "correction")
	cfg.Override(explicit, "curve", t.curve, fc.Curve)
	cfg.Override(explicit, "predict", t.predict, fc.Predict)
	cfg.OverrideDuration(explicit, "stats", t.stats, fc.Stats, shown, "meshghost", "stats")
	cfg.Override(explicit, "room-code", t.roomCode, fc.RoomCode)
	cfg.Override(explicit, "game-version", t.gameVersion, fc.GameVersion)
	cfg.Override(explicit, "max-receive-hz-per-player", t.maxReceiveHz, fc.MaxReceiveHzPerPlayer)
	cfg.Override(explicit, "ghost-collision", t.ghostCollision, fc.GhostCollision)
	cfg.Override(explicit, "transport", t.transport, fc.Transport)
	cfg.Override(explicit, "tls", t.legacyTLS, fc.TLS)
	cfg.Override(explicit, "tls-fingerprint", t.legacyPin, fc.TLSFingerprint)
	cfg.Override(explicit, "show-console", t.showConsole, fc.ShowConsole)
	cfg.Override(explicit, "offline", t.offline, fc.Offline)
	if fc.Features != nil && !explicit["features"] {
		// Joined, so the file and the flag resolve to one representation and the flag stays a plain string.
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
		if t.replayGzip != nil {
			cfg.Override(explicit, "replay-gzip", t.replayGzip, fc.Replay.Gzip)
		}
		if t.replayDelta != nil {
			cfg.Override(explicit, "replay-delta", t.replayDelta, fc.Replay.Delta)
		}
		if t.replayInputs != nil {
			cfg.Override(explicit, "replay-inputs", t.replayInputs, fc.Replay.Inputs)
		}
		if t.replayName != nil {
			cfg.Override(explicit, "replay-name", t.replayName, fc.Replay.Name)
			cfg.Override(explicit, "replay-color", t.replayColor, fc.Replay.Color)
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
		overrideChaserContact(explicit, t.chaser.contact, ch.Contact, shown)
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

// namePlaceholder is what the shipped config.json puts in player_name, and it means unset, so no nametag is drawn:
// the word teaches what the field wants where a blank did not. Matched case-insensitively with surrounding space
// trimmed, so this exact word cannot be a real nametag, though any variation ("Nickname!") can.
const namePlaceholder = "nickname"

// defaultRoom is where an empty room_name lands. Left alone, an empty string would be a real room distinct from
// "default", and the relay keys rooms on the string it is given (relay.roomKey), so two players differing only in
// blank versus "default" would never meet and nobody would be told.
const defaultRoom = "default"

// normalizeRoom is the one place an empty or whitespace-only room becomes the default room, a string function so the
// shipped-config test can pin it against the -room flag's default.
func normalizeRoom(s string) string {
	if strings.TrimSpace(s) == "" {
		return defaultRoom
	}
	return s
}

// isPlaceholderName reports whether a name is the shipped placeholder, a player who has not chosen one yet.
func isPlaceholderName(s string) bool {
	return strings.EqualFold(strings.TrimSpace(s), namePlaceholder)
}

// Said once per process, not per reload: the file is re-read on every save, and a line repeated on each goes unread.
var (
	loggedRoomDefault     bool
	loggedPlaceholderName bool
)

// normalizeIdentity resolves the two settings whose empty value means something other than unset, after flags and
// file. It touches t.room and t.name only: the replay and chaser names share a word and mean something else.
func normalizeIdentity(t configTargets) {
	if t.room != nil {
		if room := normalizeRoom(*t.room); room != *t.room {
			if !loggedRoomDefault {
				log.Printf("meshghost: room_name is empty, so you are in the default room (%q). "+
					"Everyone who wants to see each other picks the same word here.", defaultRoom)
				loggedRoomDefault = true
			}
			*t.room = room
		}
	}
	if t.name != nil && isPlaceholderName(*t.name) && *t.name != "" {
		if !loggedPlaceholderName {
			log.Printf("meshghost: player_name is still the placeholder %q, so no nametag is drawn "+
				"above your ghost. Put your own name there to be labelled.", *t.name)
			loggedPlaceholderName = true
		}
		*t.name = ""
	}
}

// loadClientConfig is applyFileConfig plus normalizeIdentity, used by startup and the reload watcher alike: resolving
// in only one would make an empty room_name read as a change on the first save and ask for a needless relaunch.
func loadClientConfig(path string, explicit map[string]bool, t configTargets) string {
	shown := applyFileConfig(path, explicit, t)
	normalizeIdentity(t)
	return shown
}

// checkLegacyTLSKeys judges the two obsolete config keys; absent is nothing. A "tls" that asked for plaintext (off,
// auto or an alias) is an error, because a security setting must never run with a silently different meaning;
// "required" and its aliases run with a note. A non-empty "tls_fingerprint" is an error too: the player pinned a
// relay on purpose, and remembering on first use instead is a downgrade they did not choose.
func checkLegacyTLSKeys(tlsMode, pin string) (notes []string, err error) {
	switch strings.ToLower(strings.TrimSpace(tlsMode)) {
	case "":
	case "required", "on", "true", "yes":
		notes = append(notes, "NOTE: the \"tls\" key in config.json is obsolete -- every connection is "+
			"TLS since 2026-09-15 and there is nothing to switch. Delete the key.")
	case "off", "false", "no", "auto":
		return nil, fmt.Errorf("\"tls\": %q in config.json is no longer a choice: every connection is "+
			"TLS since 2026-09-15 and a plaintext mode does not exist. Delete \"tls\" from config.json "+
			"to start", tlsMode)
	default:
		return nil, fmt.Errorf("\"tls\": %q in config.json is not a value this key ever had, and the key "+
			"is obsolete -- every connection is TLS since 2026-09-15. Delete it", tlsMode)
	}
	if strings.TrimSpace(pin) != "" {
		return nil, errors.New("\"tls_fingerprint\" in config.json is set, and pins are gone: since " +
			"2026-09-15 a server's identity is remembered automatically on the first connection, " +
			"in known_servers.json beside this config, and a change is warned about. Delete " +
			"\"tls_fingerprint\" from config.json to start")
	}
	return notes, nil
}

// connectRelayWithRetry calls Core.ConnectRelayOnAdapterHello until it succeeds or is permanently refused, so an
// explicit -game does not need the relay up first (without -game, the adapter's own reconnect loop retries). It goes
// through ConnectRelayOnAdapterHello rather than Core.ConnectRelay because that serializes on relayConnectMu and
// checks "already connected": an adapter can send its own hello for the same game while this waits. That function
// logs its own outcomes, so this loop adds only the final Fatalf, and it reads c.GameVersion, already set by main.
func connectRelayWithRetry(c *core.Core, gameID string) {
	backoff := core.InitialReconnectBackoff
	for {
		err := c.ConnectRelayOnAdapterHello(gameID, "", nil)
		if err == nil {
			return
		}
		if core.IsRoomCodeRefusalErr(err) {
			// Retried every core.RoomCodeRetryInterval rather than exiting.
			time.Sleep(core.RoomCodeRetryInterval)
			continue
		}
		if core.IsPermanentRejectErr(err) {
			log.Fatalf("meshghost: %v", err)
		}
		time.Sleep(backoff)
		backoff = core.NextReconnectBackoff(backoff)
	}
}

// parentPollInterval is how often watchParentPID checks the parent. Two seconds matches the adapters' bridge reconnect
// interval, so a restarted game finds the port free, at one process-handle open per tick.
const parentPollInterval = 2 * time.Second

// watchParentPID exits this process once pid does, so an autostarted client dies with the game that started it
// rather than linger with no console, holding the bridge port the game's next launch needs. Peers see the leave
// either way, since the core drops the relay when the bridge socket closes (core.Core.handleBridgeConn); this reaps
// the empty process. pid <= 0 returns at once; gone and poll are parameters so a test needs no real process.
func watchParentPID(pid int, gone func(int) bool, poll time.Duration, onGone func()) {
	if !watchingParentPID(pid) {
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

// watchingParentPID reports whether pid is one this process will watch, the one place that is answered: the
// "watching pid" log line is the only evidence the orphan reaper is armed, so it must agree with the watcher.
func watchingParentPID(pid int) bool {
	return pid > 0
}

// bridgeIsLoopback reports whether addr binds the adapter bridge to loopback only; an empty host (":7778"),
// "0.0.0.0" and "::" bind every interface. main refuses otherwise: the bridge has no authentication and needs none
// only on loopback, and on a routable address anyone on the LAN can drive the game and read the session. The likely
// path there is config sharing, since local_game_bridge sits in the file a host sends friends.
func bridgeIsLoopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		// Not host:port: let net.Listen report the real error rather than guess at one.
		return true
	}
	if host == "" {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	// Of hostnames only localhost is judged; any other would need a DNS lookup.
	return strings.EqualFold(host, "localhost")
}

// wineHasNoUsableConsole reports whether a requested console cannot appear, which is the case under Wine: a
// Proton-launched game has no console backend, so AllocConsole can succeed with no window. The client says so.
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
	// Empty by default: a name is opt-in, and one label shared by every ghost would identify nobody.
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
	correction := flag.Duration("correction", 0,
		"OPT-IN, default off. When a new sample says a ghost was drawn in the wrong place -- a "+
			"hole in a loss burst that prediction filled with a guess, a reversal inside a gap -- "+
			"slide it to the corrected place over about this long (e.g. 100ms) instead of jumping "+
			"there in one frame. 0 jumps, which is what every session before 2026-09-15 did. A warp, "+
			"an area change or a despawn still snaps. Judge it per game on screen; it only shows "+
			"where a render can be wrong, which at the shipped -interp is inside a loss gap")
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
			"timeout. auto (the default): take the best on offer, preferring quic. tcp: stay on "+
			"tcp (reliable, and the only one readable with netcat while debugging). quic: "+
			"loss-tolerant, encrypted and hard to spoof. (udp, the plain unencrypted transport, "+
			"stopped being an option on 2026-09-15 and is refused by name)")
	// No -tls or -tls-fingerprint flags: the obsolete config keys are read into these only to be judged
	// (checkLegacyTLSKeys).
	legacyTLS := new(string)
	legacyPin := new(string)
	qlog := flag.Bool("qlog", false,
		"write quic-go's qlog trace for the quic connection into the directory the QLOGDIR "+
			"environment variable names (dev diagnostics: packets, losses, congestion window). Off "+
			"by default; the variable alone does nothing")
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
	chaserCount := flag.Int("chaser-count", 1, "how many chasers (no cap beyond the roster's 512 seats; config: chaser.count)")
	chaserDelay := flag.Duration("chaser-delay", 3*time.Second, "how far behind you the first chaser runs (config: chaser.delay)")
	chaserSpacing := flag.Duration("chaser-spacing", 2*time.Second, "how much further behind each next chaser runs (config: chaser.spacing)")
	// Blank by default: a chaser is you, and a tag over your own past is clutter. Empty draws nothing, as with -name.
	chaserName := flag.String("chaser-name", "", "a nametag for the chasers, numbered when there are several. Empty (the default) draws no tag at all, which is usually what you want for a ghost of yourself (config: chaser.name)")
	chaserColor := flag.String("chaser-color", "", "colour for that tag, as a hex code like \"#7A2A2A\". Ignored without a name, exactly like player_name_color (config: chaser.color)")
	chaserSpawn := flag.Duration("chaser-spawn-delay", 0, "a chaser appears only once you have been moving for this long; 0 means the chaser's own delay (config: chaser.spawn_delay)")
	chaserContact := flag.String("chaser-contact", string(core.ChaserContactOff),
		"what touching a chaser does to you: \"off\", \"hurt\" (exactly what an enemy's touch does in "+
			"that game) or \"kill\" (a guaranteed death). Told to the game's mod, which triggers the game's "+
			"own damage; no shipped mod honours it yet (config: chaser.contact)")
	hkRecord := flag.String("hotkey-record", "shift+4", "system-wide chord: start/stop recording (config: hotkeys.record_toggle); empty unbinds")
	hkSaveLast := flag.String("hotkey-save-last", "shift+5", "system-wide chord: save the last replay.save_last seconds (config: hotkeys.save_last)")
	hkReplayLast := flag.String("hotkey-replay-last", "shift+2", "system-wide chord: play the newest recording now (config: hotkeys.replay_last)")
	hkRestart := flag.String("hotkey-replay-restart", "shift+F2", "system-wide chord: restart every replay ghost (config: hotkeys.replay_restart)")
	hkRewind := flag.String("hotkey-replay-rewind", "shift+1", "system-wide chord: rewind every replay ghost by replay.seek (config: hotkeys.replay_rewind)")
	hkFastForward := flag.String("hotkey-replay-fast-forward", "shift+3", "system-wide chord: fast-forward every replay ghost by replay.seek (config: hotkeys.replay_fast_forward)")
	replayName := flag.String("replay-name", "",
		"name written into the header of every recording this client makes, which is what a replay "+
			"ghost's nametag shows. Blank uses your own -name (config: replay.name)")
	replayColor := flag.String("replay-color", "",
		"colour for that name, as a hex code like \"#FF8800\". Blank uses your own -name-color "+
			"(config: replay.color)")
	replayGzip := flag.Bool("replay-gzip", false,
		"write recordings as .ndjson.gz instead of a plain .ndjson. Off by default: a recording "+
			"ends when the game closes, and a gzip stream cut short there is refused whole by "+
			"ordinary tools even though its data is intact. Every reader here takes either "+
			"(config: replay.gzip)")
	replayDelta := flag.Bool("replay-delta", true,
		"write only the values that CHANGED since the previous sample, carrying the rest forward "+
			"when the clip is loaded -- about 4x smaller, still plain text, and the header you edit "+
			"is untouched. false writes every value on every line (config: replay.delta)")
	replayInputs := flag.Bool("replay-inputs", false,
		"also record what you PRESSED, as a separate track in replay/inputs/ alongside the ordinary "+
			"recording. Off by default. A track never plays back as a ghost -- it is a record of the "+
			"run's input, which stays true however the rest changes (config: replay.inputs)")
	splitTimes := flag.Bool("replay-split-times", false, "show how far behind or ahead of a replay ghost you are on its nametag, e.g. \"PB +1.2s\" (config: replay.split_times)")
	replaySeek := flag.Duration("replay-seek", 5*time.Second,
		"how far one rewind or fast-forward moves a replay ghost (config: replay.seek)")
	replayStart := flag.Duration("replay-start-delay", 0,
		"how long after your first in-game frame a replay ghost starts, for files whose own "+
			"header start_delay is 0s (config: replay.start_delay)")
	configPath := flag.String("config", "config.json",
		"path to an optional JSON config file with a \"client\" section "+
			"(connect_to/local_game_bridge/game/room_name/player_name/interp/local_interp/curve/extrapolate/correction/min_send/keepalive/stats/room_code/game_version/"+
			"max_receive_hz_per_player/transport/show_console/features/replay/hotkeys/chaser) -- a friendlier alternative to flags for non-developer use; "+
			"a warning is logged if it doesn't exist; any flag explicitly passed on the command line "+
			"overrides the same field from this file")
	flag.Parse()

	// Log into a buffer until the destination is known, then replay it: show_console lives in the file, so the console
	// opens only after the file is read, and the file's own messages are the ones its window is for.
	var earlyLog bytes.Buffer
	log.SetOutput(&earlyLog)

	explicit := cfg.ExplicitFlags()

	targets := configTargets{
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
		correction:     correction,
		curve:          curve,
		predict:        predict,
		stats:          stats,
		roomCode:       roomCode,
		gameVersion:    gameVersion,
		maxReceiveHz:   maxReceiveHz,
		ghostCollision: ghostCollision,
		transport:      transportName,
		legacyTLS:      legacyTLS,
		legacyPin:      legacyPin,
		showConsole:    showConsole,
		offline:        offline,
		features:       features,
		recordOnLaunch: recordOnLaunch,
		saveLast:       saveLast,
		replayStart:    replayStart,
		replaySeek:     replaySeek,
		splitTimes:     splitTimes,
		replayGzip:     replayGzip,
		replayDelta:    replayDelta,
		replayInputs:   replayInputs,
		replayName:     replayName,
		replayColor:    replayColor,
		hotkeys: &hotkeyTargets{recordToggle: hkRecord, saveLast: hkSaveLast, replayLast: hkReplayLast,
			replayRestart: hkRestart, replayRewind: hkRewind, replayFastForward: hkFastForward},
		chaser: &chaserTargets{enabled: chaserOn, count: chaserCount, delay: chaserDelay, spacing: chaserSpacing,
			name: chaserName, color: chaserColor, contact: chaserContact, spawnDelay: chaserSpawn},
	}
	// The flag values before the file: every re-read starts from them, so a key removed from the file falls back here.
	base := snapshot(targets)
	configShown := loadClientConfig(*configPath, explicit, targets)
	if *replayDir == "" {
		// Beside the config file, read or not: the one folder a player whose game autostarted the client can find.
		*replayDir = filepath.Join(filepath.Dir(configShown), "replay")
	}
	// Both folders are created here, empty: active/ is read and never written, and an empty folder shows a player where
	// a clip goes. A failure costs replays, not the session.
	if err := os.MkdirAll(filepath.Join(*replayDir, "active"), 0o755); err != nil {
		log.Printf("could not create %s (replays will not load from it): %v",
			filepath.Join(*replayDir, "active"), err)
	}

	// stderr always: from a terminal it is the live output, and with no window it goes nowhere. A log file that cannot
	// be opened is survivable.
	writers := []io.Writer{os.Stderr}
	if f := cfg.OpenLogFile("meshghost.log", "meshghost"); f != nil {
		writers = append(writers, f)
	}
	// Judged on the request, not on consoleWriter's result: under Wine AllocConsole can succeed with no window.
	noConsolePossible := wineHasNoUsableConsole(*showConsole, runningUnderWine())
	if *showConsole {
		if w := consoleWriter(); w != nil {
			writers = append(writers, w)
		}
	}
	out := io.MultiWriter(writers...)
	log.SetOutput(out)

	logRunBanner(watchingParentPID(*exitWithPID))
	_, _ = io.Copy(out, &earlyLog)

	if noConsolePossible {
		log.Printf("meshghost: show_console is on, but this is running under Wine " +
			"(Proton/CrossOver), which has no usable console window -- one will not appear no " +
			"matter what this is set to. Everything it would have shown is in this file " +
			"(meshghost.log) instead.")
	}

	// Fatal, unlike a bad send_hz or interp: ParseKind returns tcp beside its error, and a lenient parse would quietly
	// run a transport the player did not ask for.
	transportKind, err := netx.ParseKind(*transportName)
	if err != nil {
		log.Fatalf("meshghost: %v", err)
	}

	// A plaintext mode or a pin in the obsolete keys is a startup error: a security setting is never quietly ignored.
	if notes, err := checkLegacyTLSKeys(*legacyTLS, *legacyPin); err != nil {
		log.Fatalf("meshghost: %v", err)
	} else {
		for _, n := range notes {
			log.Printf("meshghost: %s", n)
		}
	}

	if *qlog {
		quicconn.SetQLog(true)
		log.Printf("meshghost: qlog tracing ON for the quic connection -- traces go to QLOGDIR=%q "+
			"(empty means quic-go writes nothing); a dev diagnostic", os.Getenv("QLOGDIR"))
	}

	c := core.New()
	c.Transport = transportKind
	// Relay identities, remembered across launches beside the config (trust on first use).
	c.KnownRelays = core.NewKnownRelaysInDir(filepath.Dir(configShown))
	c.InterpolationDelay = *interp
	c.LocalInterpolationDelay = *localInterp
	c.Offline = *offline
	if !*lossCover {
		c.RedundancyMinInterval = -1
	}
	c.MinSendInterval = *minSend
	c.IdleKeepalive = *keepalive
	c.Extrapolate = *extrapolate
	if *correction < 0 {
		log.Fatalf("meshghost: -correction %s is negative -- 0 turns error decay off, a positive duration is the time a correction slides over", *correction)
	}
	c.Correction = *correction
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
		// Refused, not ignored: a typo here changes how every ghost moves, and the smoothing line must say what ran.
		log.Fatalf("meshghost: -curve %q is not a render curve -- use %q or %q",
			*curve, core.CurveLinear, core.CurveCatmullRom)
	}
	// Say which smoothing this run uses: it decides how a ghost moves on screen, so a recording of a stutter has to
	// say which rig produced it, and whether that is what a player runs.
	smoothingNote := " (NOT the shipped defaults -- this is a dev rig)"
	if runningTheShippedSmoothing(*interp, *localInterp, *minSend, *extrapolate, *correction, c.Curve, c.Predict) {
		smoothingNote = " (the shipped defaults)"
	}
	// The keepalive too: it decides how long a receiver works from a state this client has stopped restating.
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
	if *correction > 0 {
		keepaliveNote += ", corrections slide over " + correction.String() + " instead of jumping"
	}
	log.Printf("meshghost: smoothing: interpolation delay %s, minimum send interval %s%s%s",
		*interp, *minSend, keepaliveNote, smoothingNote)
	maxHz, maxHzWarning := resolveMaxReceiveHz(*maxReceiveHz)
	if maxHzWarning != "" {
		log.Printf("meshghost: %s", maxHzWarning)
	}
	c.MaxReceiveHz = maxHz
	// Only ever restrictive; protocol.ResolveGhostCollision enforces it, and this carries the preference.
	c.GhostCollision = *ghostCollision
	c.Features = parseFeatures(*features)
	c.ReplayDir = *replayDir
	c.RecordOnLaunch = *recordOnLaunch
	c.SaveLastSpan = *saveLast
	c.ReplayStartDelay = *replayStart
	c.ReplaySeek = *replaySeek
	c.SplitTimes = *splitTimes
	c.ReplayGzip = *replayGzip
	c.ReplayDelta = *replayDelta
	c.ReplayInputs = *replayInputs
	c.ReplayName = *replayName
	c.ReplayColor = *replayColor
	c.ChaserEnabled, c.ChaserCount, c.ChaserDelay, c.ChaserSpacing = *chaserOn, *chaserCount, *chaserDelay, *chaserSpacing
	c.ChaserName, c.ChaserColor = *chaserName, *chaserColor
	c.ChaserSpawnDelay = *chaserSpawn
	contact, err := core.ParseChaserContact(*chaserContact)
	if err != nil {
		log.Fatalf("meshghost: -chaser-contact: %v", err)
	}
	c.ChaserContact = contact
	if *chaserOn {
		log.Printf("meshghost: chaser ON -- %d ghost(s) of your own past, %s behind and then every %s", *chaserCount, *chaserDelay, *chaserSpacing)
		if contact.Active() {
			log.Printf("meshghost: chaser contact %s -- told to the game's mod, which decides whether it honours it", contact)
		}
	}
	hkStop := make(chan struct{})
	startHotkeys(c, []hotkeyBinding{
		{core.ReplayRecordToggle, *hkRecord},
		{core.ReplaySaveLast, *hkSaveLast},
		{core.ReplayLast, *hkReplayLast},
		{core.ReplayRestart, *hkRestart},
		{core.ReplayRewind, *hkRewind},
		{core.ReplayFastForward, *hkFastForward},
	}, hkStop)
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
	// config.json stays live from here: a save is re-read and applied. The hotkey rebind releases the old chords
	// first; hkStop is touched only from the watcher's goroutine after this point.
	watcher := newConfigWatcher(configShown, explicit, base, snapshot(targets), c, func(b []hotkeyBinding) {
		close(hkStop)
		hkStop = make(chan struct{})
		startHotkeys(c, b, hkStop)
	})
	go watcher.run(make(chan struct{}))
	log.Print(describeReloadable(configShown))

	if *stats > 0 {
		// With stats on, a dry render gets its own line, at most one a second. It is written from the render path
		// under c.mu, so keep it to log.Print.
		c.DryLog = func(line string) { log.Print(line) }
		// Its own goroutine, so a diagnostic cannot slow the state path or change its timing.
		go func() {
			t := time.NewTicker(*stats)
			defer t.Stop()
			for range t.C {
				log.Print(c.Stats())
			}
		}()
		log.Printf("meshghost: stats on -- summary every %s", *stats)
	}

	// Ctrl+C ends a session the ordinary way for a player running the core by hand, so it closes the recording too.
	// Windows delivers a console Ctrl+C and a console-window close as SIGINT; a kill cannot be caught.
	closeRecordingOnSignal(c)

	if watchingParentPID(*exitWithPID) {
		log.Printf("meshghost: watching pid %d -- will exit when it does", *exitWithPID)
		go watchParentPID(*exitWithPID, parentGone, parentPollInterval, func() {
			// Close the recording first: os.Exit runs no deferred calls, and this is how a session normally ends.
			if path, n, err := c.StopRecording(); err != nil {
				log.Printf("meshghost: could not close the recording cleanly: %v", err)
			} else if n > 0 {
				log.Printf("meshghost: closed the recording at %s (%d samples) before exiting", path, n)
			}
			log.Printf("meshghost: pid %d is gone -- exiting so nothing is left holding %s",
				*exitWithPID, *bridgeAddr)
			os.Exit(0)
		})
	}

	switch {
	case *offline:
		// No retry goroutine. The bridge listener below still binds, since the game's mod attaches through it, and
		// core.Offline also refuses the dial an adapter's own hello would start.
		log.Printf("meshghost: OFFLINE -- not connecting to a relay, so no room and no other " +
			"players. Recording, replays and chasers all still work. Remove \"offline\" from " +
			"config.json (or pass -offline=false) to play with other people.")
	case *gameID != "":
		// Backgrounded: the bridge listener below starts whether or not the relay is reachable yet.
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

// parseFeatures turns the comma-separated -features value into the list this client advertises. Unknown names pass
// through: the relay compares capability sets by equality and never interprets a name, so a future capability still
// travels.
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

// shippedPredict is the prediction model the packaged config.json sets, which differs from the -predict flag default
// on purpose; TestTheShippedPredictorIsWhatTheReleaseShips keeps the two in step.
const shippedPredict = core.PredictDamped

// runningTheShippedSmoothing reports whether this run's smoothing is what a packaged player gets, which the smoothing
// log line labels. predict is compared with shippedPredict, not the flag default, since the two differ.
func runningTheShippedSmoothing(interp, localInterp, minSend, extrapolate, correction time.Duration, curve core.CurveMode, predict core.PredictMode) bool {
	return interp == core.DefaultInterpolationDelay && localInterp == core.DefaultLocalGhostDelay &&
		minSend == 0 && extrapolate == 0 && correction == 0 && curve == core.CurveLinear && predict == shippedPredict
}

// resolveMaxReceiveHz applies protocol.ClampReceiveHz to what the player asked for and returns the value with a
// warning to log, empty when there is nothing to say, since the relay would otherwise clamp it out of sight. A
// warning, not a Fatalf: an out-of-range rate still plays.
func resolveMaxReceiveHz(want int) (int, string) {
	got := protocol.ClampReceiveHz(want)
	if got == want {
		return got, ""
	}
	return got, fmt.Sprintf("max_receive_hz_per_player is %d, which is outside the %d-%d this "+
		"protocol allows -- it is being treated as %d. (0 means uncapped: every peer's state as "+
		"often as it arrives.)", want, protocol.MinSendHz, protocol.MaxSendHz, got)
}

// parseHotkeys turns the configured chords into hotkey.Run's actions, with a warning for each that could not be
// bound. Two actions on one chord are caught here, since Windows would refuse the second as "another program may
// already own this chord"; hotkey.Binding is comparable, and the first action named keeps the chord.
func parseHotkeys(bindings []hotkeyBinding) (actions []hotkey.Action, warnings []string) {
	owner := map[hotkey.Binding]string{}
	for _, b := range bindings {
		if strings.TrimSpace(b.chord) == "" {
			continue
		}
		parsed, err := hotkey.Parse(b.chord)
		if err != nil {
			warnings = append(warnings, fmt.Sprintf("hotkey for %s not bound: %v", b.action, err))
			continue
		}
		if first, taken := owner[parsed]; taken {
			warnings = append(warnings, fmt.Sprintf("hotkey for %s not bound: %s is already "+
				"bound to %s in this config -- one chord cannot do two things, so give %s a "+
				"different one", b.action, parsed, first, b.action))
			continue
		}
		owner[parsed] = string(b.action)
		actions = append(actions, hotkey.Action{Name: string(b.action), Binding: parsed})
	}
	return actions, warnings
}

// startHotkeys parses the chords and runs the system-wide key loop until stop closes. Every outcome is logged and
// none is fatal: a chord that fails to parse or that another program owns is skipped alone.
func startHotkeys(c *core.Core, bindings []hotkeyBinding, stop <-chan struct{}) {
	actions, warnings := parseHotkeys(bindings)
	for _, w := range warnings {
		log.Printf("meshghost: %s", w)
	}
	if len(actions) == 0 {
		return
	}
	fire := func(name string) {
		// The key loop's thread must never wait on the core: a seek waits for a render tick, a recording for the disk.
		go func() {
			// The outcome, not "done": this line is a hotkey's only feedback, and record_toggle has two meanings.
			what, err := c.ReplayControl(core.ReplayAction(name), 0)
			if err != nil {
				log.Printf("meshghost: hotkey %s: %v", name, err)
			} else {
				log.Printf("meshghost: hotkey %s: %s", name, what)
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
		if err := hotkey.Run(actions, fire, report, stop); err != nil {
			log.Printf("meshghost: hotkeys stopped: %v", err)
		}
	}()
}

// clientSection is the raw bytes of the config file's "client" object, or nil if there isn't one, for the unknown-key
// warning, which has to look at what was written rather than at what decoded.
func clientSection(data []byte) json.RawMessage {
	var root map[string]json.RawMessage
	if err := json.Unmarshal(data, &root); err != nil {
		return nil
	}
	return root["client"]
}

// closeRecordingOnSignal ends the process on Ctrl+C with exit code 0, a deliberate end, closing any recording first.
// It does nothing else: a thorough shutdown hangs when one step does, and only the gzip footer cannot be recovered
// later, since peers learn of the leave from the relay's grace window.
func closeRecordingOnSignal(c *core.Core) {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, os.Interrupt, syscall.SIGTERM)
	go func() {
		sig := <-ch
		log.Printf("meshghost: %v -- closing down", sig)
		if path, n, err := c.StopRecording(); err != nil {
			log.Printf("meshghost: could not close the recording cleanly: %v", err)
		} else if n > 0 {
			log.Printf("meshghost: closed the recording at %s (%d samples) before exiting", path, n)
		}
		os.Exit(0)
	}()
}
