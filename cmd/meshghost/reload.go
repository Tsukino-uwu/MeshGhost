package main

import (
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/core"
	"github.com/Tsukino-uwu/MeshGhost/internal/cfg"
)

// config.json is re-read while running: a save that holds still for one more poll is read into a fresh copy of the
// pre-file flag values, so a removed key falls back to its default (cfg.Override writes only a present key), diffed
// against what is live, handed to the Core's live setters, and logged one line per changed key: applied now, applied
// at the next use, or needing a relaunch. Flags still beat the file, and the file is only ever read.

// liveValues is every client setting the file can carry, by value: base, the flag values every re-read starts from,
// and prev, what is live now, are two copies.
type liveValues struct {
	relayAddr, bridgeAddr, gameID, room, name, nameColor string
	interp, localInterp, minSend, keepalive, extrapolate time.Duration
	correction                                           time.Duration
	curve, predict                                       string
	stats                                                time.Duration
	roomCode, gameVersion                                string
	maxReceiveHz                                         int
	ghostCollision, transport, legacyTLS, legacyPin      string
	showConsole, offline                                 bool
	features                                             string
	recordOnLaunch                                       bool
	saveLast, replayStart, replaySeek                    time.Duration
	splitTimes, replayGzip, replayDelta, replayInputs    bool
	replayName, replayColor                              string
	hkRecord, hkSaveLast, hkReplayLast                   string
	hkRestart, hkRewind, hkFastForward                   string
	chaserOn                                             bool
	chaserCount                                          int
	chaserDelay, chaserSpacing, chaserSpawn              time.Duration
	chaserName, chaserColor, chaserContact               string
}

// targets points a configTargets at this copy, so applyFileConfig fills it.
func (v *liveValues) targets() configTargets {
	return configTargets{
		relayAddr: &v.relayAddr, bridgeAddr: &v.bridgeAddr, gameID: &v.gameID, room: &v.room,
		name: &v.name, nameColor: &v.nameColor, interp: &v.interp, localInterp: &v.localInterp,
		minSend: &v.minSend, keepalive: &v.keepalive, extrapolate: &v.extrapolate, correction: &v.correction, curve: &v.curve,
		predict: &v.predict, stats: &v.stats, roomCode: &v.roomCode, gameVersion: &v.gameVersion,
		maxReceiveHz: &v.maxReceiveHz, ghostCollision: &v.ghostCollision, transport: &v.transport,
		legacyTLS: &v.legacyTLS, legacyPin: &v.legacyPin, showConsole: &v.showConsole, offline: &v.offline,
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

// snapshot copies the flag variables, before or after the file is applied, into a liveValues.
func snapshot(t configTargets) liveValues {
	return liveValues{
		relayAddr: *t.relayAddr, bridgeAddr: *t.bridgeAddr, gameID: *t.gameID, room: *t.room,
		name: *t.name, nameColor: *t.nameColor, interp: *t.interp, localInterp: *t.localInterp,
		minSend: *t.minSend, keepalive: *t.keepalive, extrapolate: *t.extrapolate, correction: *t.correction, curve: *t.curve,
		predict: *t.predict, stats: *t.stats, roomCode: *t.roomCode, gameVersion: *t.gameVersion,
		maxReceiveHz: *t.maxReceiveHz, ghostCollision: *t.ghostCollision, transport: *t.transport,
		legacyTLS: *t.legacyTLS, legacyPin: *t.legacyPin, showConsole: *t.showConsole, offline: *t.offline,
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

// configWatcher is the poll; poll is separate from the goroutine so a test drives it with its own clock.
type configWatcher struct {
	path     string
	explicit map[string]bool
	base     liveValues // the flag values before the file: what a re-read starts from
	prev     liveValues // what is live now
	c        *core.Core
	rebind   func(bindings []hotkeyBinding)

	// fw is the poll itself: mtime and size, applied on the second poll that shows the same new values.
	fw *cfg.FileWatch
}

func newConfigWatcher(path string, explicit map[string]bool, base, live liveValues, c *core.Core, rebind func([]hotkeyBinding)) *configWatcher {
	return &configWatcher{path: path, explicit: explicit, base: base, prev: live, c: c, rebind: rebind,
		fw: cfg.NewFileWatch(path)}
}

// run polls once a second until stop closes.
func (w *configWatcher) run(stop <-chan struct{}) {
	w.fw.Run(stop, func() { w.reload() })
}

// poll looks at the file once and applies a settled change (cfg.FileWatch).
func (w *configWatcher) poll() {
	if w.fw.Poll() {
		w.reload()
	}
}

// reload re-reads the file into a fresh copy of the flag values, applies what
// changed, and logs it.
func (w *configWatcher) reload() []string {
	// A save that went wrong keeps what is live: re-reading from the defaults would rebind default hotkeys
	// system-wide and leave the room over one stray comma (cfg.ReloadRefusal).
	if why := cfg.ReloadRefusal(w.path, "meshghost", "client"); why != "" {
		log.Printf("meshghost: config.json was saved but %s -- NOTHING changed: every setting stays as it "+
			"is running; fix the file and save again", why)
		return nil
	}
	next := w.base
	loadClientConfig(w.path, w.explicit, next.targets())
	lines := applyLive(&w.prev, &next, w.c, w.rebind)
	if len(lines) == 0 {
		log.Printf("meshghost: config.json was saved with no client setting changed")
	}
	for _, l := range lines {
		log.Printf("meshghost: config.json changed: %s", l)
	}
	// The three relaunch-only connection keys do not carry forward: applyLive rejoins with prev's, so letting the
	// file's value land here would let the next save of any key, a name, move the session after all.
	live := w.prev
	w.prev = next
	w.prev.relayAddr, w.prev.room, w.prev.roomCode = live.relayAddr, live.room, live.roomCode
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
	smoothing = changed("correction", prev.correction, next.correction, "applied") || smoothing
	smoothing = changed("curve", prev.curve, next.curve, "applied") || smoothing
	smoothing = changed("predict", prev.predict, next.predict, "applied") || smoothing
	if smoothing {
		if err := c.SetSmoothing(next.interp, next.localInterp, next.extrapolate, next.correction, core.CurveMode(next.curve), core.PredictMode(next.predict)); err != nil {
			lines = append(lines, fmt.Sprintf("smoothing NOT applied -- %v; the previous values stay", err))
			next.curve, next.predict = prev.curve, prev.predict
			next.interp, next.localInterp, next.extrapolate, next.correction = prev.interp, prev.localInterp, prev.extrapolate, prev.correction
		}
	}

	if changed("ghost_collision", prev.ghostCollision, next.ghostCollision, "applied; the room's own policy still wins where stricter") {
		c.SetGhostCollisionPreference(next.ghostCollision)
	}

	// The chaser pack restarts from the new values, respawning after spawn_delay as on a fresh attach.
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
		// overrideChaserContact already refused anything that is not a mode, so this parse cannot fail on the file.
		contact, err := core.ParseChaserContact(next.chaserContact)
		if err != nil {
			lines = append(lines, fmt.Sprintf("chaser.contact NOT applied -- %v; the previous value stays", err))
			contact, _ = core.ParseChaserContact(prev.chaserContact)
			next.chaserContact = prev.chaserContact
		}
		n := c.SetChaserSettings(core.ChaserSettings{
			Enabled: next.chaserOn, Count: next.chaserCount, Delay: next.chaserDelay, Spacing: next.chaserSpacing,
			Name: next.chaserName, Color: next.chaserColor, Contact: contact, SpawnDelay: next.chaserSpawn,
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

	// Where you are connected is not live-editable: otherwise anything on this machine that can write config.json
	// could move a running session onto a relay of its choosing, with nothing on screen saying so. A change is
	// reported rather than silently ignored.
	const relaunchToMove = "needs the client relaunched -- where you connect is deliberately not live-editable"
	changed("connect_to", prev.relayAddr, next.relayAddr, relaunchToMove)
	changed("room_name", prev.room, next.room, relaunchToMove)
	changed("room_code", prev.roomCode, next.roomCode, relaunchToMove)

	// Connection: only a fresh Hello applies these, so the core rejoins with them, to the live relay and room.
	conn := false
	conn = changed("player_name", prev.name, next.name, "rejoining") || conn
	conn = changed("player_name_color", prev.nameColor, next.nameColor, "rejoining") || conn
	conn = changed("max_receive_hz_per_player", prev.maxReceiveHz, next.maxReceiveHz, "rejoining") || conn
	conn = changed("offline", prev.offline, next.offline, "applied") || conn
	if conn {
		maxHz, warning := resolveMaxReceiveHz(next.maxReceiveHz)
		if warning != "" {
			lines = append(lines, warning)
		}
		rejoined := c.SetConnectionSettings(core.ConnectionSettings{
			// prev, not next: a rejoin for a name change must not carry a relay address the file changed too.
			RelayAddr: prev.relayAddr, Room: prev.room, RoomCode: prev.roomCode,
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

	// Read once at start: named so a player knows a relaunch applies them.
	const relaunch = "needs the client relaunched -- close the game or stop meshghost.exe"
	changed("bridge", prev.bridgeAddr, next.bridgeAddr, relaunch)
	changed("game", prev.gameID, next.gameID, relaunch)
	changed("game_version", prev.gameVersion, next.gameVersion, relaunch)
	changed("min_send", prev.minSend, next.minSend, relaunch)
	changed("keepalive", prev.keepalive, next.keepalive, relaunch)
	changed("stats", prev.stats, next.stats, relaunch)
	changed("transport", prev.transport, next.transport, relaunch)
	const obsolete = "this key is obsolete (every connection is TLS since 2026-09-15); delete it"
	changed("tls", prev.legacyTLS, next.legacyTLS, obsolete)
	changed("tls_fingerprint", prev.legacyPin, next.legacyPin, obsolete)
	changed("show_console", prev.showConsole, next.showConsole, relaunch)
	changed("features", prev.features, next.features, relaunch)
	return lines
}

// describeReloadable is the start-up line that tells a player the file is live.
func describeReloadable(path string) string {
	return "meshghost: " + strings.TrimSpace(path) + " is re-read when saved: smoothing, ghost collision, chaser, replay and hotkey " +
		"settings apply without a relaunch, and a name change rejoins the relay; the relay address and room need a relaunch"
}
