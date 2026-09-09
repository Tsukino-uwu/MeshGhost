package main

import (
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/core"
)

// CONFIG.JSON RE-READ WHILE RUNNING (2026-09-09). A tester edited config.json
// mid-session and saw the input display change and nothing else: the
// Pseudoregalia mod polls the file for its own keys, while every client setting
// was read once in main() and copied onto the Core. The user's call: "make
// everything refresh if edit/save is used." This polls the file's modification
// time once a second, and when it changes -- and holds still for one more poll,
// because an editor writes a file in more than one step -- re-reads it into a
// FRESH copy of the flag values as they were before the file was first applied
// (a removed key must fall back to its default, not keep the old value:
// cfg.Override writes only when the key is present), diffs against what is
// live, hands each changed group to the Core's live setters (core/settings.go)
// and logs one line per changed key saying what happened to it. Flags given on
// the command line still beat the file, exactly as at start.
//
// Three outcomes a line can report: applied now; applies at the next use (a
// recording setting to the next recording, a connection setting by rejoining
// the relay); needs a relaunch (the transport, the bridge address, the
// console). Nothing is re-serialised: the file is only ever read.

// liveValues is every client setting the file can carry, by value. Two copies
// exist: `base`, the flag values before the file was applied, which every
// re-read starts from; and `prev`, what is live now, which a re-read is diffed
// against.
type liveValues struct {
	relayAddr, bridgeAddr, gameID, room, name, nameColor string
	interp, localInterp, minSend, keepalive, extrapolate time.Duration
	curve, predict                                       string
	stats                                                time.Duration
	roomCode, gameVersion                                string
	maxReceiveHz                                         int
	ghostCollision, transport, tlsMode, tlsPin           string
	showConsole, offline                                 bool
	features                                             string
	recordOnLaunch                                       bool
	saveLast, replayStart, replaySeek                    time.Duration
	splitTimes, replayGzip, replayDelta, replayInputs    bool
	replayName, replayColor                              string
	hkRecord, hkSaveLast, hkReplayLast                   string
	hkRestart, hkRewind, hkFastForward                   string
	chaserOn, chaserContact                              bool
	chaserCount                                          int
	chaserDelay, chaserSpacing, chaserSpawn              time.Duration
	chaserName, chaserColor                              string
}

// targets points a configTargets at this copy, so applyFileConfig fills it.
func (v *liveValues) targets() configTargets {
	return configTargets{
		relayAddr: &v.relayAddr, bridgeAddr: &v.bridgeAddr, gameID: &v.gameID, room: &v.room,
		name: &v.name, nameColor: &v.nameColor, interp: &v.interp, localInterp: &v.localInterp,
		minSend: &v.minSend, keepalive: &v.keepalive, extrapolate: &v.extrapolate, curve: &v.curve,
		predict: &v.predict, stats: &v.stats, roomCode: &v.roomCode, gameVersion: &v.gameVersion,
		maxReceiveHz: &v.maxReceiveHz, ghostCollision: &v.ghostCollision, transport: &v.transport,
		tlsMode: &v.tlsMode, tlsPin: &v.tlsPin, showConsole: &v.showConsole, offline: &v.offline,
		features: &v.features, recordOnLaunch: &v.recordOnLaunch, saveLast: &v.saveLast,
		replayStart: &v.replayStart, replaySeek: &v.replaySeek, splitTimes: &v.splitTimes,
		replayGzip: &v.replayGzip, replayDelta: &v.replayDelta, replayInputs: &v.replayInputs,
		replayName: &v.replayName, replayColor: &v.replayColor,
		hotkeys: &hotkeyTargets{recordToggle: &v.hkRecord, saveLast: &v.hkSaveLast, replayLast: &v.hkReplayLast,
			replayRestart: &v.hkRestart, replayRewind: &v.hkRewind, replayFastForward: &v.hkFastForward},
		chaser: &chaserTargets{enabled: &v.chaserOn, count: &v.chaserCount, delay: &v.chaserDelay,
			spacing: &v.chaserSpacing, name: &v.chaserName, color: &v.chaserColor,
			contact: &v.chaserContact, spawnDelay: &v.chaserSpawn},
	}
}

func (v *liveValues) hotkeyBindings() []hotkeyBinding {
	return []hotkeyBinding{
		{core.ReplayRecordToggle, v.hkRecord},
		{core.ReplaySaveLast, v.hkSaveLast},
		{core.ReplayLast, v.hkReplayLast},
		{core.ReplayRestart, v.hkRestart},
		{core.ReplayRewind, v.hkRewind},
		{core.ReplayFastForward, v.hkFastForward},
	}
}

// snapshot copies the flag variables (after flag.Parse, before or after the
// file) into a liveValues.
func snapshot(t configTargets) liveValues {
	return liveValues{
		relayAddr: *t.relayAddr, bridgeAddr: *t.bridgeAddr, gameID: *t.gameID, room: *t.room,
		name: *t.name, nameColor: *t.nameColor, interp: *t.interp, localInterp: *t.localInterp,
		minSend: *t.minSend, keepalive: *t.keepalive, extrapolate: *t.extrapolate, curve: *t.curve,
		predict: *t.predict, stats: *t.stats, roomCode: *t.roomCode, gameVersion: *t.gameVersion,
		maxReceiveHz: *t.maxReceiveHz, ghostCollision: *t.ghostCollision, transport: *t.transport,
		tlsMode: *t.tlsMode, tlsPin: *t.tlsPin, showConsole: *t.showConsole, offline: *t.offline,
		features: *t.features, recordOnLaunch: *t.recordOnLaunch, saveLast: *t.saveLast,
		replayStart: *t.replayStart, replaySeek: *t.replaySeek, splitTimes: *t.splitTimes,
		replayGzip: *t.replayGzip, replayDelta: *t.replayDelta, replayInputs: *t.replayInputs,
		replayName: *t.replayName, replayColor: *t.replayColor,
		hkRecord: *t.hotkeys.recordToggle, hkSaveLast: *t.hotkeys.saveLast, hkReplayLast: *t.hotkeys.replayLast,
		hkRestart: *t.hotkeys.replayRestart, hkRewind: *t.hotkeys.replayRewind, hkFastForward: *t.hotkeys.replayFastForward,
		chaserOn: *t.chaser.enabled, chaserCount: *t.chaser.count, chaserDelay: *t.chaser.delay,
		chaserSpacing: *t.chaser.spacing, chaserName: *t.chaser.name, chaserColor: *t.chaser.color,
		chaserContact: *t.chaser.contact, chaserSpawn: *t.chaser.spawnDelay,
	}
}

// configWatcher is the poll. poll() is separate from the goroutine so a test
// drives it with its own clock.
type configWatcher struct {
	path     string
	explicit map[string]bool
	base     liveValues // the flag values before the file: what a re-read starts from
	prev     liveValues // what is live now
	c        *core.Core
	rebind   func(bindings []hotkeyBinding)

	seenMod     time.Time // the file as last applied
	seenSize    int64
	pendingMod  time.Time // a change seen once, waiting to hold still
	pendingSize int64
	havePending bool
}

func newConfigWatcher(path string, explicit map[string]bool, base, live liveValues, c *core.Core, rebind func([]hotkeyBinding)) *configWatcher {
	w := &configWatcher{path: path, explicit: explicit, base: base, prev: live, c: c, rebind: rebind}
	if info, err := os.Stat(path); err == nil {
		w.seenMod, w.seenSize = info.ModTime(), info.Size()
	}
	return w
}

// run polls once a second until stop closes.
func (w *configWatcher) run(stop <-chan struct{}) {
	t := time.NewTicker(time.Second) // wall-clock: it paces a stat() of a file a human edits
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			w.poll()
		}
	}
}

// poll looks at the file once. A change is applied on the SECOND poll that
// shows the same new mtime and size -- one poll after the write stopped -- so
// an editor's two-step save (truncate, then write) is read whole.
func (w *configWatcher) poll() {
	info, err := os.Stat(w.path)
	if err != nil {
		w.havePending = false
		return // a missing file changes nothing; the settings in force stay
	}
	mod, size := info.ModTime(), info.Size()
	if mod.Equal(w.seenMod) && size == w.seenSize {
		w.havePending = false
		return
	}
	if !w.havePending || !mod.Equal(w.pendingMod) || size != w.pendingSize {
		w.havePending, w.pendingMod, w.pendingSize = true, mod, size
		return
	}
	w.havePending = false
	w.seenMod, w.seenSize = mod, size
	w.reload()
}

// reload re-reads the file into a fresh copy of the flag values, applies what
// changed, and logs it.
func (w *configWatcher) reload() []string {
	next := w.base
	applyFileConfig(w.path, w.explicit, next.targets())
	lines := applyLive(&w.prev, &next, w.c, w.rebind)
	if len(lines) == 0 {
		log.Printf("meshghost: config.json was saved with no client setting changed")
	}
	for _, l := range lines {
		log.Printf("meshghost: config.json changed: %s", l)
	}
	w.prev = next
	return lines
}

// applyLive hands every changed group to the Core and returns one line per
// changed key. prev is not modified; the caller replaces it with next.
func applyLive(prev, next *liveValues, c *core.Core, rebind func([]hotkeyBinding)) []string {
	var lines []string
	changed := func(key string, a, b any, effect string) bool {
		if a == b {
			return false
		}
		lines = append(lines, fmt.Sprintf("%s %v -> %v (%s)", key, a, b, effect))
		return true
	}

	// Smoothing: the render path reads these every tick.
	smoothing := false
	smoothing = changed("interp", prev.interp, next.interp, "applied") || smoothing
	smoothing = changed("local_interp", prev.localInterp, next.localInterp, "applied") || smoothing
	smoothing = changed("extrapolate", prev.extrapolate, next.extrapolate, "applied") || smoothing
	smoothing = changed("curve", prev.curve, next.curve, "applied") || smoothing
	smoothing = changed("predict", prev.predict, next.predict, "applied") || smoothing
	if smoothing {
		if err := c.SetSmoothing(next.interp, next.localInterp, next.extrapolate, core.CurveMode(next.curve), core.PredictMode(next.predict)); err != nil {
			lines = append(lines, fmt.Sprintf("smoothing NOT applied -- %v; the previous values stay", err))
			next.curve, next.predict = prev.curve, prev.predict
			next.interp, next.localInterp, next.extrapolate = prev.interp, prev.localInterp, prev.extrapolate
		}
	}

	if changed("ghost_collision", prev.ghostCollision, next.ghostCollision, "applied; the room's own policy still wins where stricter") {
		c.SetGhostCollisionPreference(next.ghostCollision)
	}

	// The chaser pack restarts from the new values (it despawns and respawns
	// after spawn_delay, as on a fresh attach).
	chaser := false
	chaser = changed("chaser.enabled", prev.chaserOn, next.chaserOn, "applied") || chaser
	chaser = changed("chaser.count", prev.chaserCount, next.chaserCount, "applied") || chaser
	chaser = changed("chaser.delay", prev.chaserDelay, next.chaserDelay, "applied") || chaser
	chaser = changed("chaser.spacing", prev.chaserSpacing, next.chaserSpacing, "applied") || chaser
	chaser = changed("chaser.name", prev.chaserName, next.chaserName, "applied") || chaser
	chaser = changed("chaser.color", prev.chaserColor, next.chaserColor, "applied") || chaser
	chaser = changed("chaser.contact", prev.chaserContact, next.chaserContact, "applied") || chaser
	chaser = changed("chaser.spawn_delay", prev.chaserSpawn, next.chaserSpawn, "applied") || chaser
	if chaser {
		n := c.SetChaserSettings(core.ChaserSettings{
			Enabled: next.chaserOn, Count: next.chaserCount, Delay: next.chaserDelay, Spacing: next.chaserSpacing,
			Name: next.chaserName, Color: next.chaserColor, Contact: next.chaserContact, SpawnDelay: next.chaserSpawn,
		})
		lines = append(lines, fmt.Sprintf("chaser pack restarted: %d ghost(s) of your own past", n))
	}

	// Replay: read at the next use, except the ring, which is re-armed now.
	replay := false
	replay = changed("replay.record_on_launch", prev.recordOnLaunch, next.recordOnLaunch, "the next game launch; a recording in progress is left alone") || replay
	replay = changed("replay.save_last", prev.saveLast, next.saveLast, "applied") || replay
	replay = changed("replay.start_delay", prev.replayStart, next.replayStart, "the next replay start") || replay
	replay = changed("replay.seek", prev.replaySeek, next.replaySeek, "applied") || replay
	replay = changed("replay.split_times", prev.splitTimes, next.splitTimes, "applied") || replay
	replay = changed("replay.gzip", prev.replayGzip, next.replayGzip, "the next recording") || replay
	replay = changed("replay.delta", prev.replayDelta, next.replayDelta, "the next recording") || replay
	replay = changed("replay.inputs", prev.replayInputs, next.replayInputs, "the next recording") || replay
	replay = changed("replay.name", prev.replayName, next.replayName, "the next recording") || replay
	replay = changed("replay.color", prev.replayColor, next.replayColor, "the next recording") || replay
	if replay {
		c.SetReplaySettings(core.ReplaySettings{
			RecordOnLaunch: next.recordOnLaunch, SaveLastSpan: next.saveLast, StartDelay: next.replayStart,
			Seek: next.replaySeek, SplitTimes: next.splitTimes, Gzip: next.replayGzip, Delta: next.replayDelta,
			Inputs: next.replayInputs, Name: next.replayName, Color: next.replayColor,
		})
	}

	// Connection: a fresh Hello is the only way these take effect, so the
	// core leaves the session and rejoins with them.
	conn := false
	conn = changed("connect_to", prev.relayAddr, next.relayAddr, "rejoining") || conn
	conn = changed("room", prev.room, next.room, "rejoining") || conn
	conn = changed("room_code", prev.roomCode, next.roomCode, "rejoining") || conn
	conn = changed("name", prev.name, next.name, "rejoining") || conn
	conn = changed("name_color", prev.nameColor, next.nameColor, "rejoining") || conn
	conn = changed("max_receive_hz_per_player", prev.maxReceiveHz, next.maxReceiveHz, "rejoining") || conn
	conn = changed("offline", prev.offline, next.offline, "applied") || conn
	if conn {
		maxHz, warning := resolveMaxReceiveHz(next.maxReceiveHz)
		if warning != "" {
			lines = append(lines, warning)
		}
		rejoined := c.SetConnectionSettings(core.ConnectionSettings{
			RelayAddr: next.relayAddr, Room: next.room, RoomCode: next.roomCode,
			DisplayName: next.name, NameColor: next.nameColor, MaxReceiveHz: maxHz, Offline: next.offline,
		})
		if rejoined {
			lines = append(lines, "left the relay session to rejoin with the new connection settings")
		} else {
			lines = append(lines, "no relay session to rejoin right now; the new connection settings apply at the next connect")
		}
	}

	// Hotkeys: the old chords are released and the new ones registered.
	hk := false
	hk = changed("hotkeys.record_toggle", prev.hkRecord, next.hkRecord, "rebound") || hk
	hk = changed("hotkeys.save_last", prev.hkSaveLast, next.hkSaveLast, "rebound") || hk
	hk = changed("hotkeys.replay_last", prev.hkReplayLast, next.hkReplayLast, "rebound") || hk
	hk = changed("hotkeys.replay_restart", prev.hkRestart, next.hkRestart, "rebound") || hk
	hk = changed("hotkeys.replay_rewind", prev.hkRewind, next.hkRewind, "rebound") || hk
	hk = changed("hotkeys.replay_fast_forward", prev.hkFastForward, next.hkFastForward, "rebound") || hk
	if hk && rebind != nil {
		rebind(next.hotkeyBindings())
	}

	// Read once at start and not re-readable: named so a player knows a
	// relaunch is what applies them, instead of wondering.
	const relaunch = "needs the client relaunched -- close the game or stop meshghost.exe"
	changed("bridge", prev.bridgeAddr, next.bridgeAddr, relaunch)
	changed("game", prev.gameID, next.gameID, relaunch)
	changed("game_version", prev.gameVersion, next.gameVersion, relaunch)
	changed("min_send", prev.minSend, next.minSend, relaunch)
	changed("keepalive", prev.keepalive, next.keepalive, relaunch)
	changed("stats", prev.stats, next.stats, relaunch)
	changed("transport", prev.transport, next.transport, relaunch)
	changed("tls", prev.tlsMode, next.tlsMode, relaunch)
	changed("tls_fingerprint", prev.tlsPin, next.tlsPin, relaunch)
	changed("show_console", prev.showConsole, next.showConsole, relaunch)
	changed("features", prev.features, next.features, relaunch)
	return lines
}

// describeReloadable is the one-line summary the start-up log prints, so a
// player learns the file is live without reading anything else.
func describeReloadable(path string) string {
	return "meshghost: " + strings.TrimSpace(path) + " is re-read when saved: smoothing, ghost collision, chaser, replay and hotkey " +
		"settings apply without a relaunch; a change to the relay, room or name rejoins the relay"
}
