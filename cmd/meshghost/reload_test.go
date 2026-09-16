package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/core"
)

// Every key the file can carry, changed at once: each one is named in the
// report with its old and new value, and the groups the Core applies live are
// visible on the Core afterwards. Fails without reload.go's per-key lines.
func TestApplyLiveNamesEveryChangedKeyAndAppliesTheLiveGroups(t *testing.T) {
	prev := liveValues{
		relayAddr: "127.0.0.1:7777", bridgeAddr: "127.0.0.1:7778", gameID: "a", room: "r1", name: "n1", nameColor: "#111111",
		interp: 450 * time.Millisecond, localInterp: 100 * time.Millisecond, minSend: 50 * time.Millisecond, keepalive: time.Second,
		extrapolate: 0, correction: 0, curve: "linear", predict: "linear", stats: 0, roomCode: "", gameVersion: "v1", maxReceiveHz: 30,
		ghostCollision: "enabled", transport: "tcp", legacyTLS: "", legacyPin: "", showConsole: false, offline: false, features: "",
		recordOnLaunch: false, saveLast: 30 * time.Second, replayStart: 0, replaySeek: 5 * time.Second,
		splitTimes: false, replayGzip: false, replayDelta: true, replayInputs: false, replayName: "", replayColor: "",
		hkRecord: "ctrl+shift+F9", hkSaveLast: "ctrl+shift+F10", hkReplayLast: "ctrl+shift+F11",
		hkRestart: "ctrl+shift+F5", hkRewind: "ctrl+shift+F6", hkFastForward: "ctrl+shift+F7",
		chaserOn: false, chaserCount: 1, chaserDelay: time.Second, chaserSpacing: 100 * time.Millisecond,
		chaserName: "Why?", chaserColor: "", chaserContact: "off", chaserSpawn: time.Second,
	}
	next := liveValues{
		relayAddr: "192.0.2.1:7777", bridgeAddr: "127.0.0.1:7790", gameID: "b", room: "r2", name: "n2", nameColor: "#222222",
		interp: 300 * time.Millisecond, localInterp: 120 * time.Millisecond, minSend: 66 * time.Millisecond, keepalive: 2 * time.Second,
		extrapolate: 50 * time.Millisecond, correction: 100 * time.Millisecond, curve: "catmull-rom", predict: "damped", stats: time.Second, roomCode: "code", gameVersion: "v2", maxReceiveHz: 20,
		ghostCollision: "disabled", transport: "quic", legacyTLS: "off", legacyPin: "ab", showConsole: true, offline: true, features: "x",
		recordOnLaunch: true, saveLast: 60 * time.Second, replayStart: time.Second, replaySeek: 10 * time.Second,
		splitTimes: true, replayGzip: true, replayDelta: false, replayInputs: true, replayName: "rn", replayColor: "#333333",
		hkRecord: "ctrl+shift+F1", hkSaveLast: "ctrl+shift+F2", hkReplayLast: "ctrl+shift+F3",
		hkRestart: "ctrl+shift+F4", hkRewind: "ctrl+shift+F8", hkFastForward: "ctrl+shift+F12",
		chaserOn: true, chaserCount: 2, chaserDelay: 2 * time.Second, chaserSpacing: 200 * time.Millisecond,
		chaserName: "past", chaserColor: "#444444", chaserContact: "kill", chaserSpawn: 2 * time.Second,
	}
	c := core.New()
	t.Cleanup(c.StopChasers)
	var rebound []hotkeyBinding
	lines := applyLive(&prev, &next, c, func(b []hotkeyBinding) { rebound = b })
	report := strings.Join(lines, "\n")
	for _, key := range []string{
		"interp 450ms -> 300ms", "local_interp", "extrapolate", "correction 0s -> 100ms", "curve linear -> catmull-rom", "predict linear -> damped",
		"ghost_collision enabled -> disabled",
		"chaser.enabled false -> true", "chaser.count 1 -> 2", "chaser.delay", "chaser.spacing", "chaser.name Why? -> past",
		"chaser.color", "chaser.contact off -> kill", "chaser.spawn_delay", "chaser pack restarted: 2 ghost(s)",
		"replay.record_on_launch false -> true", "replay.save_last 30s -> 1m0s", "replay.start_delay", "replay.seek 5s -> 10s",
		"replay.split_times", "replay.gzip", "replay.delta true -> false", "replay.inputs", "replay.name", "replay.color",
		"connect_to 127.0.0.1:7777 -> 192.0.2.1:7777", "room_name r1 -> r2", "room_code", "player_name n1 -> n2", "player_name_color",
		"max_receive_hz_per_player 30 -> 20", "offline false -> true",
		"hotkeys.record_toggle", "hotkeys.save_last", "hotkeys.replay_last", "hotkeys.replay_restart", "hotkeys.replay_rewind", "hotkeys.replay_fast_forward",
		"bridge", "game a -> b", "game_version", "min_send", "keepalive", "stats", "transport tcp -> quic", "tls  -> off",
		"tls_fingerprint", "show_console", "features",
	} {
		if !strings.Contains(report, key) {
			t.Errorf("report does not name %q:\n%s", key, report)
		}
	}
	for _, needle := range []string{"needs the client relaunched", "the next recording", "rejoin"} {
		if !strings.Contains(report, needle) {
			t.Errorf("report lacks the effect %q:\n%s", needle, report)
		}
	}
	if c.InterpolationDelay != 300*time.Millisecond || c.Curve != core.CurveCatmullRom || c.Predict != core.PredictDamped {
		t.Errorf("smoothing not applied: interp=%s curve=%s predict=%s", c.InterpolationDelay, c.Curve, c.Predict)
	}
	if c.GhostCollision != "disabled" {
		t.Errorf("ghost_collision not applied: %q", c.GhostCollision)
	}
	if !c.ChaserEnabled || c.ChaserCount != 2 || c.ChaserName != "past" {
		t.Errorf("chaser settings not applied: enabled=%v count=%d name=%q", c.ChaserEnabled, c.ChaserCount, c.ChaserName)
	}
	if !c.ReplayGzip || c.ReplayDelta || !c.ReplayInputs || c.SaveLastSpan != 60*time.Second || c.ReplaySeek != 10*time.Second || !c.RecordOnLaunch {
		t.Errorf("replay settings not applied: gzip=%v delta=%v inputs=%v save_last=%s seek=%s record_on_launch=%v",
			c.ReplayGzip, c.ReplayDelta, c.ReplayInputs, c.SaveLastSpan, c.ReplaySeek, c.RecordOnLaunch)
	}
	if c.DisplayName != "n2" || !c.Offline || c.MaxReceiveHz != 20 {
		t.Errorf("connection settings not applied: name=%q offline=%v hz=%d", c.DisplayName, c.Offline, c.MaxReceiveHz)
	}
	// WHERE YOU ARE CONNECTED IS NOT LIVE-EDITABLE since 2026-09-12, so the two
	// that moved a running session are carried over from what is live rather
	// than taken from the file -- while still being NAMED in the report above,
	// with the relaunch effect. The user's call; see reload.go.
	if c.RelayAddr == "192.0.2.1:7777" || c.Room == "r2" {
		t.Errorf("a saved config moved the live session: relay=%q room=%q -- editing this file must not "+
			"be able to put a running player in somebody else's room", c.RelayAddr, c.Room)
	}
	if len(rebound) != 6 || rebound[0].chord != "ctrl+shift+F1" {
		t.Errorf("hotkeys not rebound: %+v", rebound)
	}
}

// A bad curve name saved mid-session is refused and the previous smoothing
// stays -- the startup path exits on the same typo, and a running session must
// neither exit nor silently pick a default.
func TestApplyLiveRefusesABadCurveAndKeepsTheOld(t *testing.T) {
	prev := liveValues{interp: 450 * time.Millisecond, curve: "linear", predict: "linear"}
	next := prev
	next.curve = "bezier"
	c := core.New()
	c.InterpolationDelay, c.Curve, c.Predict = prev.interp, core.CurveLinear, core.PredictLinear
	lines := applyLive(&prev, &next, c, nil)
	report := strings.Join(lines, "\n")
	if !strings.Contains(report, "NOT applied") {
		t.Fatalf("a bad curve was not reported as refused:\n%s", report)
	}
	if c.Curve != core.CurveLinear {
		t.Errorf("curve changed to %q on a refused reload", c.Curve)
	}
	if next.curve != "linear" {
		t.Errorf("the live copy kept the refused value %q; the next diff would hide the typo", next.curve)
	}
}

// Nothing changed in the file (a save with no edit) reports no line, so the
// log does not fill with "config.json changed" on every ctrl+s.
func TestApplyLiveIsQuietWhenNothingDiffers(t *testing.T) {
	v := liveValues{interp: time.Second, curve: "linear", predict: "linear"}
	w := v
	if lines := applyLive(&v, &w, core.New(), nil); len(lines) != 0 {
		t.Errorf("no change reported %d line(s): %v", len(lines), lines)
	}
}

// The watcher end to end on a real file: a save is applied on the second poll
// that sees it unchanged (the editor's write has stopped), a removed key falls
// back to the flag default rather than keeping the old value, and a value the
// flag pinned on the command line is not overridden by the file.
func TestConfigWatcherAppliesASaveAndFallsBackForARemovedKey(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	write := func(body string) {
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(`{"client": {"interp": "450ms", "room": "start", "replay": {"seek": "5s"}}}`)
	base := liveValues{interp: 200 * time.Millisecond, room: "default", replaySeek: 3 * time.Second, curve: "linear", predict: "linear"}
	live := base
	applyFileConfig(path, map[string]bool{"room": true}, live.targets())
	c := core.New()
	c.InterpolationDelay, c.ReplaySeek, c.Room = live.interp, live.replaySeek, live.room
	w := newConfigWatcher(path, map[string]bool{"room": true}, base, live, c, nil)
	if w.prev.interp != 450*time.Millisecond || w.prev.room != "default" {
		t.Fatalf("setup: live interp=%s room=%q (the room flag is explicit, so the file must not set it)", w.prev.interp, w.prev.room)
	}

	// Rewrite: interp changes, seek is removed, room in the file changes but is pinned by the flag.
	time.Sleep(20 * time.Millisecond) // wall-clock: two writes need distinct mtimes on a coarse filesystem clock
	write(`{"client": {"interp": "300ms", "room": "elsewhere", "replay": {}}}`)
	// Force a visibly different mtime even on filesystems that round to a second.
	future := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(path, future, future); err != nil {
		t.Fatal(err)
	}
	w.poll() // first sight: pending
	if c.InterpolationDelay != 450*time.Millisecond {
		t.Fatal("applied on the first poll -- a half-written save would be read")
	}
	w.poll() // held still: applied
	if c.InterpolationDelay != 300*time.Millisecond {
		t.Errorf("interp not applied by the second poll: %s", c.InterpolationDelay)
	}
	if c.ReplaySeek != 3*time.Second {
		t.Errorf("a removed key kept the old value: seek=%s, want the flag default 3s", c.ReplaySeek)
	}
	if c.Room != "default" {
		t.Errorf("the file overrode a flag given on the command line: room=%q", c.Room)
	}
	w.poll() // nothing new: no re-apply
	if w.fw.Pending() {
		t.Error("a poll with no change left a pending state")
	}
}

// F5 from the 2026-09-12 adversarial review (P4a-5), and specifically the half
// that is easy to get wrong.
//
// connect_to, room and room_code stopped being live-editable that day: a live
// re-read meant anything on this machine that can WRITE config.json could move
// a running session onto a relay of its choosing, with the player still playing
// and nothing on screen saying so.
//
// THE TRAP IS THE SECOND SAVE. reload() replaces `prev` with what it just read,
// so if the file's relay address landed there, the next save of ANY other key
// -- a name, a colour -- would rejoin carrying it, because applyLive builds the
// Hello from prev. The gate would hold for exactly one save and then open. That
// is what this test is for; the first save is the easy case.
func TestASavedConfigCannotMoveALiveSessionEvenOnTheSecondSave(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	write := func(body string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		// A visibly different mtime even where the filesystem clock is coarse.
		future := time.Now().Add(2 * time.Second)
		if err := os.Chtimes(path, future, future); err != nil {
			t.Fatal(err)
		}
	}
	save := func(w *configWatcher, body string) {
		t.Helper()
		write(body)
		w.poll() // first sight: pending
		w.poll() // held still: applied
	}

	write(`{"client": {"connect_to": "127.0.0.1:7777", "room": "mine", "name": "me"}}`)
	base := liveValues{curve: "linear", predict: "linear"}
	live := base
	applyFileConfig(path, nil, live.targets())
	c := core.New()
	t.Cleanup(c.StopChasers)
	c.RelayAddr, c.Room, c.DisplayName = live.relayAddr, live.room, live.name
	w := newConfigWatcher(path, nil, base, live, c, nil)
	if c.RelayAddr != "127.0.0.1:7777" || c.Room != "mine" {
		t.Fatalf("setup: relay=%q room=%q", c.RelayAddr, c.Room)
	}

	// Save one: the relay and room are moved. Reported, not applied.
	save(w, `{"client": {"connect_to": "192.0.2.1:9999", "room": "theirs", "name": "me"}}`)
	if c.RelayAddr != "127.0.0.1:7777" || c.Room != "mine" {
		t.Fatalf("the first save moved the session: relay=%q room=%q", c.RelayAddr, c.Room)
	}

	// Save two changes only the NAME -- which legitimately rejoins. The relay
	// and room it rejoins with must still be the live ones.
	save(w, `{"client": {"connect_to": "192.0.2.1:9999", "room": "theirs", "name": "renamed"}}`)
	if c.DisplayName != "renamed" {
		t.Errorf("a name change stopped applying: %q", c.DisplayName)
	}
	if c.RelayAddr != "127.0.0.1:7777" || c.Room != "mine" {
		t.Fatalf("the SECOND save moved the session: relay=%q room=%q -- the gate held for one save "+
			"and then let the first save's address through on the back of a name change",
			c.RelayAddr, c.Room)
	}
}

// TestConfigWatcherKeepsTheLiveSettingsWhenASaveGoesWrong: found 2026-09-16 with
// the real binaries -- a save with a stray comma re-read from the defaults, so
// the client rebound its default hotkeys system-wide and left the room until the
// file was fixed. A broken, empty or section-less save must change nothing.
func TestConfigWatcherKeepsTheLiveSettingsWhenASaveGoesWrong(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	write := func(body string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		future := time.Now().Add(2 * time.Second)
		if err := os.Chtimes(path, future, future); err != nil {
			t.Fatal(err)
		}
	}
	write(`{"client": {"interp": "300ms", "name": "me"}}`)
	base := liveValues{interp: 450 * time.Millisecond, curve: "linear", predict: "linear"}
	live := base
	applyFileConfig(path, nil, live.targets())
	c := core.New()
	t.Cleanup(c.StopChasers)
	c.InterpolationDelay, c.DisplayName = live.interp, live.name
	rebinds := 0
	w := newConfigWatcher(path, nil, base, live, c, func([]hotkeyBinding) { rebinds++ })

	for _, bad := range []string{`{"client": {"interp": "300ms",, "name": "me"}}`, ``, `{"server": {}}`} {
		write(bad)
		w.poll()
		if lines := w.reload(); len(lines) != 0 {
			t.Fatalf("a bad save %q applied changes: %v", bad, lines)
		}
		if c.InterpolationDelay != 300*time.Millisecond || c.DisplayName != "me" || rebinds != 0 {
			t.Fatalf("a bad save %q moved what is live: interp=%s name=%q rebinds=%d",
				bad, c.InterpolationDelay, c.DisplayName, rebinds)
		}
	}
}
