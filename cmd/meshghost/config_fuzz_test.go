package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/core"
)

// FuzzApplyFileConfigNeverPanicsAndKeepsDefaultsSane: config.json is edited by hand, so any value is possible.
// applyFileConfig must never panic, and a bad value must leave the flag default rather than a zero or garbage.
//
// Long campaign by hand: go test ./cmd/meshghost -run=XXX -fuzz=FuzzApplyFileConfig -fuzztime=5m
func FuzzApplyFileConfigNeverPanicsAndKeepsDefaultsSane(f *testing.F) {
	f.Add(`{"client":{"replay":{"record_on_launch":true,"save_last":"45s","seek":"abc"},"chaser":{"count":99,"delay":"-3s"},"hotkeys":{"record_toggle":"win+F12"}}}`)
	f.Add(`{"client":{"replay":"not an object","chaser":[1,2],"hotkeys":null}}`)
	f.Add(`{"client":{"chaser":{"count":-1,"delay":"1e9h","spawn_delay":"NaN"},"interp":"-1ms"}}`)
	f.Add(`{"client":{"correction":"-1ms","extrapolate":"100ms"}}`)
	// chaser.contact: the legacy bool, a mode, a non-mode, a number.
	f.Add(`{"client":{"chaser":{"contact":true}}}`)
	f.Add(`{"client":{"chaser":{"contact":"kill"}}}`)
	f.Add(`{"client":{"chaser":{"contact":"maybe"}}}`)
	f.Add(`{"client":{"chaser":{"contact":1}}}`)
	f.Add(`{"client":{}}`)
	f.Add(`{}`)
	f.Add(`null`)
	f.Add(`{"client":{"replay":{"split_times":"yes"}}}`)
	f.Add(`{"client":{"replay":{"inputs":"yes"}}}`)
	f.Add(`{"client":{"replay":{"inputs":true}}}`)
	f.Add("\xef\xbb\xbf{\"client\":{\"replay\":{\"save_last\":\"30s\"}}}")
	f.Fuzz(func(t *testing.T, body string) {
		dir := t.TempDir()
		path := filepath.Join(dir, "config.json")
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		var relayAddr, bridgeAddr, gameID, room, name, gameVersion, roomCode, transport string
		// Every duration key the file can carry needs a target here: a seed naming a key with a nil target
		// dereferences it.
		var interp, minSend, extrapolate, correction time.Duration
		var maxReceiveHz int
		var showConsole, recordOnLaunch, splitTimes, chaserOn bool
		contact := "off"
		saveLast, replayStart, replaySeek := 30*time.Second, time.Duration(0), 5*time.Second
		count, delay, spacing, spawn := 1, 3*time.Second, 2*time.Second, time.Duration(0)
		cname, color := "Chaser", "#7A2A2A"
		record, save, last, restart, rewind, ff := "ctrl+shift+F9", "ctrl+shift+F10", "ctrl+shift+F11", "ctrl+shift+F5", "ctrl+shift+F6", "ctrl+shift+F7"
		shown := applyFileConfig(path, map[string]bool{}, configTargets{
			relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
			room: &room, name: &name, interp: &interp, minSend: &minSend,
			extrapolate: &extrapolate, correction: &correction,
			roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
			transport: &transport, showConsole: &showConsole,
			recordOnLaunch: &recordOnLaunch, saveLast: &saveLast, replayStart: &replayStart, replaySeek: &replaySeek, splitTimes: &splitTimes,
			hotkeys: &hotkeyTargets{recordToggle: &record, saveLast: &save, replayLast: &last, replayRestart: &restart, replayRewind: &rewind, replayFastForward: &ff},
			chaser:  &chaserTargets{enabled: &chaserOn, count: &count, delay: &delay, spacing: &spacing, name: &cname, color: &color, contact: &contact, spawnDelay: &spawn},
		})
		if !filepath.IsAbs(shown) {
			t.Fatalf("applyFileConfig returned a relative path %q", shown)
		}
		// Whatever the file says, chaser.contact lands as a word ParseChaserContact accepts, so main never exits on it.
		if _, err := core.ParseChaserContact(contact); err != nil {
			t.Fatalf("chaser.contact landed as %q from %q: %v", contact, body, err)
		}
		// A bad duration keeps the default, never zero by accident, but a parsed "0s" is a value the player chose.
		// Negative durations parse, and are the core's to clamp, so they are not asserted here.
		var doc struct {
			Client struct {
				Replay map[string]any `json:"replay"`
				Chaser map[string]any `json:"chaser"`
			} `json:"client"`
		}
		_ = json.Unmarshal([]byte(strings.TrimPrefix(body, "\ufeff")), &doc)
		// Keys match case-insensitively, as encoding/json matches a struct tag; the map mirror keeps the file's case.
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
