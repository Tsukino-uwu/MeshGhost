package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// FuzzApplyFileConfigNeverPanicsAndKeepsDefaultsSane: config.json is a file a
// player edits by hand, so every value in it is arbitrary -- a count of -1 or
// 1e9, a duration of "-5s" or "abc", a block that is a string instead of an
// object, keys the build does not know. applyFileConfig must never panic, a
// bad value must leave the flag default in place rather than a zero or a
// garbage value, and the three replay-era blocks are held to that alongside
// the older keys.
//
// Long campaign by hand: go test ./cmd/meshghost -run=XXX -fuzz=FuzzApplyFileConfig -fuzztime=5m
func FuzzApplyFileConfigNeverPanicsAndKeepsDefaultsSane(f *testing.F) {
	f.Add(`{"client":{"replay":{"record_on_launch":true,"save_last":"45s","seek":"abc"},"chaser":{"count":99,"delay":"-3s"},"hotkeys":{"record_toggle":"win+F12"}}}`)
	f.Add(`{"client":{"replay":"not an object","chaser":[1,2],"hotkeys":null}}`)
	f.Add(`{"client":{"chaser":{"count":-1,"delay":"1e9h","spawn_delay":"NaN"},"interp":"-1ms"}}`)
	f.Add(`{"client":{}}`)
	f.Add(`{}`)
	f.Add(`null`)
	f.Add(`{"client":{"replay":{"split_times":"yes"}}}`)
	f.Add("\xef\xbb\xbf{\"client\":{\"replay\":{\"save_last\":\"30s\"}}}")
	f.Fuzz(func(t *testing.T, body string) {
		dir := t.TempDir()
		path := filepath.Join(dir, "config.json")
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		var relayAddr, bridgeAddr, gameID, room, name, gameVersion, roomCode, transport string
		var interp, minSend time.Duration
		var maxReceiveHz int
		var showConsole, recordOnLaunch, splitTimes, chaserOn, contact bool
		saveLast, replayStart, replaySeek := 30*time.Second, time.Duration(0), 5*time.Second
		count, delay, spacing, spawn := 1, 3*time.Second, 2*time.Second, time.Duration(0)
		cname, color := "Chaser", "#7A2A2A"
		record, save, last, restart, rewind, ff := "ctrl+shift+F9", "ctrl+shift+F10", "ctrl+shift+F11", "ctrl+shift+F5", "ctrl+shift+F6", "ctrl+shift+F7"
		shown := applyFileConfig(path, map[string]bool{}, configTargets{
			relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
			room: &room, name: &name, interp: &interp, minSend: &minSend,
			roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
			transport: &transport, showConsole: &showConsole,
			recordOnLaunch: &recordOnLaunch, saveLast: &saveLast, replayStart: &replayStart, replaySeek: &replaySeek, splitTimes: &splitTimes,
			hotkeys: &hotkeyTargets{recordToggle: &record, saveLast: &save, replayLast: &last, replayRestart: &restart, replayRewind: &rewind, replayFastForward: &ff},
			chaser:  &chaserTargets{enabled: &chaserOn, count: &count, delay: &delay, spacing: &spacing, name: &cname, color: &color, contact: &contact, spawnDelay: &spawn},
		})
		if !filepath.IsAbs(shown) {
			t.Fatalf("applyFileConfig returned a relative path %q", shown)
		}
		// A duration the file could not express as a duration must be the
		// default, never zero-by-accident: OverrideDuration keeps the target on
		// a parse failure. Negative durations ARE accepted by time.ParseDuration
		// and are the core's to clamp, so they are not asserted here.
		for _, d := range []struct {
			name string
			got  time.Duration
			def  time.Duration
		}{{"save_last", saveLast, 30 * time.Second}, {"seek", replaySeek, 5 * time.Second}, {"chaser.delay", delay, 3 * time.Second}, {"chaser.spacing", spacing, 2 * time.Second}} {
			if d.got == 0 && d.def != 0 {
				t.Fatalf("%s became 0 from %q; a bad value must keep the default %s", d.name, body, d.def)
			}
		}
	})
}
