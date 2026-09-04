package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
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
		// a parse failure. A parsed "0s" is a VALUE the player chose and is
		// allowed -- CI's first campaign (2026-09-03) found this test calling
		// "save_last":"0s" a bug; the corpus entry beside this file is that
		// input. Negative durations ARE accepted by time.ParseDuration and are
		// the core's to clamp, so they are not asserted here.
		var doc struct {
			Client struct {
				Replay map[string]any `json:"replay"`
				Chaser map[string]any `json:"chaser"`
			} `json:"client"`
		}
		_ = json.Unmarshal([]byte(strings.TrimPrefix(body, "\ufeff")), &doc)
		// CASE-INSENSITIVELY, because encoding/json matches a struct tag that way
		// and the client reads its config into a struct. CI found this on
		// 2026-09-04 with {"Client":{"replAY":{"sAve_lAst":"0"}}}: the client
		// correctly applied it as an explicit zero, and this test called that a
		// bug -- because the mirror it checks against is a map[string]any, where
		// a key keeps whatever case the file used and "save_last" simply misses.
		//
		// The same shape as this test's first CI failure a day earlier, one
		// layer down: there the invariant did not know an explicit zero from a
		// bad value; here it did not know the KEY. A test that mirrors a
		// decoder has to mirror how that decoder matches names, or it invents
		// failures the code does not have.
		explicitZero := func(block map[string]any, key string) bool {
			for k, raw := range block {
				if !strings.EqualFold(k, key) {
					continue
				}
				v, ok := raw.(string)
				if !ok {
					continue
				}
				if d, err := time.ParseDuration(v); err == nil && d == 0 {
					return true
				}
			}
			return false
		}
		for _, d := range []struct {
			name  string
			got   time.Duration
			def   time.Duration
			block map[string]any
			key   string
		}{
			{"save_last", saveLast, 30 * time.Second, doc.Client.Replay, "save_last"},
			{"seek", replaySeek, 5 * time.Second, doc.Client.Replay, "seek"},
			{"chaser.delay", delay, 3 * time.Second, doc.Client.Chaser, "delay"},
			{"chaser.spacing", spacing, 2 * time.Second, doc.Client.Chaser, "spacing"},
		} {
			if d.got == 0 && d.def != 0 && !explicitZero(d.block, d.key) {
				t.Fatalf("%s became 0 from %q; a bad value must keep the default %s", d.name, body, d.def)
			}
		}
	})
}
