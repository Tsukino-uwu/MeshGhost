package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/core"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// writeConfig writes body to a temp config.json and returns its path, with prefix prepended raw so a test can put a
// byte-order mark, or anything else an editor might leave, in front of the JSON.
func writeConfig(t *testing.T, prefix []byte, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, append(prefix, []byte(body)...), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

const testClientConfig = `{"client": {"connect_to": "1.2.3.4:9999", "room_code": "letmein"}}`

// applyTestConfig runs applyFileConfig over path with no flags marked explicit, returning the relay address and room
// code.
func applyTestConfig(path string) (relayAddr, roomCode string) {
	relayAddr, roomCode, _ = applyTestConfigFull(path)
	return relayAddr, roomCode
}

// applyTestConfigFull is applyTestConfig plus the transport. Every target it passes matters: a nil target is a nil
// dereference the moment the file sets that key.
func applyTestConfigFull(path string) (relayAddr, roomCode, transport string) {
	relayAddr, roomCode, transport, _, _ = applyTestConfigWithTLS(path, map[string]bool{})
	return relayAddr, roomCode, transport
}

// applyTestConfigWithTLS is applyTestConfigFull plus the two tls keys, taking the explicit-flag set so a test can
// assert flag-beats-file.
func applyTestConfigWithTLS(path string, explicit map[string]bool) (relayAddr, roomCode, transport, tlsMode, tlsPin string) {
	var bridgeAddr, gameID, room, name, gameVersion, features string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole bool
	applyFileConfig(path, explicit, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, legacyTLS: &tlsMode, legacyPin: &tlsPin,
		showConsole: &showConsole, features: &features,
	})
	return relayAddr, roomCode, transport, tlsMode, tlsPin
}

// TestConfigWithUTF8BOMIsStillRead: a Windows editor may prepend a UTF-8 BOM, which encoding/json refuses, and the
// file must still be read rather than silently fall back to defaults.
func TestConfigWithUTF8BOMIsStillRead(t *testing.T) {
	path := writeConfig(t, []byte{0xEF, 0xBB, 0xBF}, testClientConfig)

	relayAddr, roomCode := applyTestConfig(path)
	if relayAddr != "1.2.3.4:9999" {
		t.Errorf("connect_to = %q, want it read through the BOM", relayAddr)
	}
	if roomCode != "letmein" {
		t.Errorf("room_code = %q, want it read through the BOM", roomCode)
	}
}

// TestConfigWithoutBOMIsUnaffected confirms the BOM strip didn't change the ordinary case.
func TestConfigWithoutBOMIsUnaffected(t *testing.T) {
	path := writeConfig(t, nil, testClientConfig)

	relayAddr, roomCode := applyTestConfig(path)
	if relayAddr != "1.2.3.4:9999" || roomCode != "letmein" {
		t.Errorf("connect_to = %q, room_code = %q, want the plain file read normally", relayAddr, roomCode)
	}
}

// TestUTF16ConfigLeavesDefaults: a UTF-16 file is refused rather than half-read, leaving every target at the
// caller's flag default.
func TestUTF16ConfigLeavesDefaults(t *testing.T) {
	path := writeConfig(t, []byte{0xFF, 0xFE}, testClientConfig)

	relayAddr, roomCode := applyTestConfig(path)
	if relayAddr != "" || roomCode != "" {
		t.Errorf("connect_to = %q, room_code = %q, want both left at their defaults", relayAddr, roomCode)
	}
}

// TestTransportIsReadFromConfig confirms the transport key reaches the flag target, or a client asked for quic would
// silently stay on tcp.
func TestTransportIsReadFromConfig(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"connect_to":"1.2.3.4:7779","transport":"quic"}}`)
	relayAddr, _, transport := applyTestConfigFull(path)
	if transport != "quic" {
		t.Errorf("transport = %q, want %q", transport, "quic")
	}
	if relayAddr != "1.2.3.4:7779" {
		t.Errorf("connect_to = %q, want %q", relayAddr, "1.2.3.4:7779")
	}
}

// TestTransportAbsentFromConfigLeavesTheFlagDefault: a config with no "transport" key keeps the flag default rather
// than an empty string that fails to parse.
func TestTransportAbsentFromConfigLeavesTheFlagDefault(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"connect_to":"1.2.3.4:7777"}}`)
	var transport = "tcp" // what flag.String would have left in place
	var relayAddr, bridgeAddr, gameID, room, name, gameVersion, roomCode string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole bool
	applyFileConfig(path, map[string]bool{}, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, showConsole: &showConsole,
	})
	if transport != "tcp" {
		t.Errorf("transport = %q, want it left at the flag default %q", transport, "tcp")
	}
}

// TestShowConsoleIsReadFromConfig covers the only way a player reaches this setting: an autostarted client gets no
// flags.
func TestShowConsoleIsReadFromConfig(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"show_console":true}}`)
	var relayAddr, bridgeAddr, gameID, room, name, gameVersion, roomCode, transport string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole bool
	applyFileConfig(path, map[string]bool{}, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, showConsole: &showConsole,
	})
	if !showConsole {
		t.Error("show_console = false, want true from the config file")
	}
}

// TestShowConsoleAbsentFromConfigStaysOff: an absent key must never open a window, the default that makes autostart
// worth having.
func TestShowConsoleAbsentFromConfigStaysOff(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"connect_to":"1.2.3.4:7777"}}`)
	var relayAddr, bridgeAddr, gameID, room, name, gameVersion, roomCode, transport string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole bool
	applyFileConfig(path, map[string]bool{}, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, showConsole: &showConsole,
	})
	if showConsole {
		t.Error("show_console = true, want it left off when the key is absent")
	}
}

// TestWineConsoleIsReportedNotPretended: a console asked for where one cannot exist is reported, not silently
// skipped.
func TestWineConsoleIsReportedNotPretended(t *testing.T) {
	cases := []struct {
		name      string
		requested bool
		underWine bool
		want      bool
	}{
		{"asked for one under Wine: tell them it cannot appear", true, true, true},
		{"asked for one on real Windows: it works, say nothing", true, false, false},
		{"did not ask, under Wine: nothing to explain", false, true, false},
		{"did not ask, real Windows: nothing to explain", false, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := wineHasNoUsableConsole(tc.requested, tc.underWine); got != tc.want {
				t.Errorf("wineHasNoUsableConsole(requested=%v, wine=%v) = %v, want %v",
					tc.requested, tc.underWine, got, tc.want)
			}
		})
	}
}

// TestOneBadValueDoesNotDiscardTheWholeConfig: a string where a bool belongs must not revert every other setting,
// checked on what matters to a player: where they connect, which room, and what they are called.
func TestOneBadValueDoesNotDiscardTheWholeConfig(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{
		"connect_to": "1.2.3.4:9999",
		"room": "castle",
		"name": "speedrunner",
		"show_console": "true"
	}}`)

	var relayAddr, bridgeAddr, gameID, room, name, gameVersion, roomCode, transport string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole bool
	applyFileConfig(path, map[string]bool{}, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, showConsole: &showConsole,
	})

	if relayAddr != "1.2.3.4:9999" {
		t.Errorf("connect_to = %q, want it applied despite the bad show_console", relayAddr)
	}
	if room != "castle" {
		t.Errorf("room = %q, want it applied despite the bad show_console", room)
	}
	if name != "speedrunner" {
		t.Errorf("name = %q, want it applied despite the bad show_console", name)
	}
	// The offending setting itself is never guessed at: treating "true" as true would invent intent.
	if showConsole {
		t.Error("show_console was applied from a string value, want it skipped as unreadable")
	}
}

// TestSyntaxErrorStillDiscardsTheWholeConfig: a missing comma or stray brace is not one bad field, and the rest of
// the file cannot be trusted to mean what was intended.
func TestSyntaxErrorStillDiscardsTheWholeConfig(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"connect_to": "1.2.3.4:9999" "room": "castle"}}`)

	var relayAddr, bridgeAddr, gameID, room, name, gameVersion, roomCode, transport string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole bool
	applyFileConfig(path, map[string]bool{}, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, showConsole: &showConsole,
	})

	if relayAddr != "" || room != "" {
		t.Errorf("a syntactically broken file was partly applied (connect_to=%q room=%q), "+
			"want the whole file rejected", relayAddr, room)
	}
}

// TestWatchParentPIDFiresOnceWhenTheParentGoes: a crashed game must not leave an orphan client holding the bridge
// port. The probe is injected so the test is deterministic on every platform.
func TestWatchParentPIDFiresOnceWhenTheParentGoes(t *testing.T) {
	var checks int
	fired := make(chan struct{}, 4)
	// Alive for two polls, then gone, so watchParentPID must keep waiting rather than fire on its first look.
	gone := func(int) bool {
		checks++
		return checks > 2
	}
	watchParentPID(1234, gone, time.Millisecond, func() { fired <- struct{}{} })

	if len(fired) != 1 {
		t.Fatalf("onGone fired %d times, want exactly 1", len(fired))
	}
	if checks != 3 {
		t.Errorf("probe called %d times, want 3 (two alive, then gone)", checks)
	}
}

// TestWatchParentPIDIgnoresZero: pid 0, the default, is never watched; on Windows it is a real system process that
// never exits.
func TestWatchParentPIDIgnoresZero(t *testing.T) {
	called := false
	watchParentPID(0, func(int) bool { called = true; return true }, time.Millisecond,
		func() { t.Error("onGone fired for pid 0, want no watch at all") })
	if called {
		t.Error("probe was called for pid 0, want the watch skipped entirely")
	}
}

// TestTheObsoleteTLSKeysAreStillReadSoTheyCanBeJudged: an old config's plaintext mode or pin must reach
// checkLegacyTLSKeys rather than vanish as unknown.
func TestTheObsoleteTLSKeysAreStillReadSoTheyCanBeJudged(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"tls":"off","tls_fingerprint":"AB:CD"}}`)
	_, _, _, tlsMode, tlsPin := applyTestConfigWithTLS(path, map[string]bool{})
	if tlsMode != "off" {
		t.Errorf("tls = %q, want the obsolete value read so it can be refused", tlsMode)
	}
	if tlsPin != "AB:CD" {
		t.Errorf("tls_fingerprint = %q, want it read so it can be refused", tlsPin)
	}
}

// TestTLSAbsentFromConfigLeavesTheTargetsAlone: without the keys both targets stay empty, nothing to say.
func TestTLSAbsentFromConfigLeavesTheTargetsAlone(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"connect_to":"1.2.3.4:7777"}}`)
	_, _, _, tlsMode, tlsPin := applyTestConfigWithTLS(path, map[string]bool{})
	if tlsMode != "" || tlsPin != "" {
		t.Fatalf("tls = %q / fingerprint = %q, want both left alone", tlsMode, tlsPin)
	}
}

// TestTheObsoleteTLSKeysAreJudgedByWhatTheyAskedFor: a plaintext mode or a pin refuses to start, and the harmless
// leftovers run with a note.
func TestTheObsoleteTLSKeysAreJudgedByWhatTheyAskedFor(t *testing.T) {
	for _, tc := range []struct {
		mode, pin string
		wantErr   bool
		wantNotes int
	}{
		{"", "", false, 0},
		{"required", "", false, 1},
		{"on", "", false, 1},
		{"off", "", true, 0},
		{"auto", "", true, 0},
		{"requried", "", true, 0},
		{"", "AB:CD", true, 0},
		{"", "   ", false, 0},
		{"required", "abcd", true, 0},
	} {
		notes, err := checkLegacyTLSKeys(tc.mode, tc.pin)
		if (err != nil) != tc.wantErr {
			t.Errorf("tls=%q pin=%q: err=%v, want error=%v", tc.mode, tc.pin, err, tc.wantErr)
		}
		if err == nil && len(notes) != tc.wantNotes {
			t.Errorf("tls=%q pin=%q: notes=%q, want %d", tc.mode, tc.pin, notes, tc.wantNotes)
		}
		if err != nil && !strings.Contains(err.Error(), "2026-09-15") {
			t.Errorf("tls=%q pin=%q: the error does not say since when: %v", tc.mode, tc.pin, err)
		}
	}
	if _, err := checkLegacyTLSKeys("", "AB:CD"); err == nil || !strings.Contains(err.Error(), "known_servers.json") {
		t.Errorf("a pin's refusal does not say what replaced it: %v", err)
	}
}

// TestBridgeIsLoopback covers the guard on the unauthenticated bridge's bind address; the remote cases, a
// local_game_bridge shared between friends, are the ones it exists for.
func TestBridgeIsLoopback(t *testing.T) {
	loopback := []string{
		"127.0.0.1:7778",
		"127.0.0.1:0",
		"127.5.6.7:7778",
		"[::1]:7778",
		"localhost:7778",
		"LocalHost:7778",
		"not-a-host-port", // unparseable: let net.Listen report the real error
	}
	for _, addr := range loopback {
		if !bridgeIsLoopback(addr) {
			t.Errorf("bridgeIsLoopback(%q) = false, want true", addr)
		}
	}

	remote := []string{
		"0.0.0.0:7778",
		":7778", // empty host binds every interface
		"[::]:7778",
		"198.51.100.10:7778",
		"192.0.2.5:7778",
		"example.com:7778",
	}
	for _, addr := range remote {
		if bridgeIsLoopback(addr) {
			t.Errorf("bridgeIsLoopback(%q) = true, want false -- this address is reachable "+
				"from off the machine and the bridge is unauthenticated", addr)
		}
	}
}

// TestReplayBlockIsReadFromConfig: the nested "replay" block is how a player reaches recording, and absent it keeps
// the flag defaults, so a release never records by surprise.
func TestReplayBlockIsReadFromConfig(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"replay":{"record_on_launch":true,"save_last":"45s","start_delay":"2s","seek":"8s","split_times":true}}}`)
	var relayAddr, bridgeAddr, gameID, room, name, gameVersion, roomCode, transport string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole, recordOnLaunch bool
	saveLast := 30 * time.Second
	var replayStart time.Duration
	replaySeek := 5 * time.Second
	splitTimes := false
	applyFileConfig(path, map[string]bool{}, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, showConsole: &showConsole,
		recordOnLaunch: &recordOnLaunch, saveLast: &saveLast, replayStart: &replayStart, replaySeek: &replaySeek, splitTimes: &splitTimes,
	})
	if !recordOnLaunch || saveLast != 45*time.Second || replayStart != 2*time.Second || replaySeek != 8*time.Second || !splitTimes {
		t.Fatalf("replay block: record_on_launch=%v save_last=%v, want true/45s", recordOnLaunch, saveLast)
	}

	path = writeConfig(t, nil, `{"client":{"connect_to":"1.2.3.4:7777"}}`)
	recordOnLaunch, saveLast = false, 30*time.Second
	shown := applyFileConfig(path, map[string]bool{}, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, showConsole: &showConsole,
		recordOnLaunch: &recordOnLaunch, saveLast: &saveLast,
	})
	if recordOnLaunch || saveLast != 30*time.Second {
		t.Fatalf("absent replay block changed the defaults: %v/%v", recordOnLaunch, saveLast)
	}
	if !filepath.IsAbs(shown) || filepath.Base(shown) != "config.json" {
		t.Fatalf("applyFileConfig returned %q, want the absolute config path", shown)
	}
}

// TestHotkeysBlockIsReadFromConfig: an absent key leaves the flag default, and an empty string is a deliberate
// unbind that survives the merge.
func TestHotkeysBlockIsReadFromConfig(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"hotkeys":{"record_toggle":"alt+r","replay_rewind":""}}}`)
	var relayAddr, bridgeAddr, gameID, room, name, gameVersion, roomCode, transport string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole bool
	record, save, last, restart, rewind, ff := "ctrl+shift+F9", "ctrl+shift+F10", "ctrl+shift+F11", "ctrl+shift+F5", "ctrl+shift+F6", "ctrl+shift+F7"
	applyFileConfig(path, map[string]bool{}, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, showConsole: &showConsole,
		hotkeys: &hotkeyTargets{recordToggle: &record, saveLast: &save, replayLast: &last,
			replayRestart: &restart, replayRewind: &rewind, replayFastForward: &ff},
	})
	if record != "alt+r" || rewind != "" {
		t.Fatalf("hotkeys block: record_toggle=%q replay_rewind=%q, want alt+r and an empty unbind", record, rewind)
	}
	if save != "ctrl+shift+F10" || last != "ctrl+shift+F11" || restart != "ctrl+shift+F5" || ff != "ctrl+shift+F7" {
		t.Fatalf("keys absent from the block changed: %q %q %q %q", save, last, restart, ff)
	}
}

// TestChaserBlockIsReadFromConfig: absent keys in the nested "chaser" block keep the flag defaults.
func TestChaserBlockIsReadFromConfig(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"chaser":{"enabled":true,"count":4,"delay":"2s","name":"Me","spawn_delay":"4s"}}}`)
	var relayAddr, bridgeAddr, gameID, room, name, gameVersion, roomCode, transport string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole bool
	enabled, contact := false, "off"
	count := 1
	delay, spacing := 3*time.Second, 2*time.Second
	var spawn time.Duration
	cname, color := "Chaser", "#7A2A2A"
	applyFileConfig(path, map[string]bool{}, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, showConsole: &showConsole,
		chaser: &chaserTargets{enabled: &enabled, count: &count, delay: &delay, spacing: &spacing, name: &cname, color: &color, contact: &contact, spawnDelay: &spawn},
	})
	if !enabled || count != 4 || delay != 2*time.Second || cname != "Me" || spawn != 4*time.Second {
		t.Fatalf("chaser block: enabled=%v count=%d delay=%v name=%q", enabled, count, delay, cname)
	}
	if spacing != 2*time.Second || color != "#7A2A2A" || contact != "off" {
		t.Fatalf("absent chaser keys changed: spacing=%v color=%q contact=%q", spacing, color, contact)
	}
}

// TestARateOutsideTheDocumentedRangeIsWarnedAbout: a rate the relay would clamp out of the player's sight is warned
// about here, at both ends of the range.
func TestARateOutsideTheDocumentedRangeIsWarnedAbout(t *testing.T) {
	cases := []struct {
		name        string
		want        int
		wantHz      int
		wantWarning bool
	}{
		{"below the floor", 5, protocol.MinSendHz, true},
		{"above the ceiling", 500, protocol.MaxSendHz, true},
		{"uncapped, the shipped value", 0, 0, false},
		{"in range", 30, 30, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			hz, warning := resolveMaxReceiveHz(tc.want)
			if hz != tc.wantHz {
				t.Errorf("resolved to %d, want %d", hz, tc.wantHz)
			}
			if (warning != "") != tc.wantWarning {
				t.Fatalf("warning = %q, want one: %v", warning, tc.wantWarning)
			}
			if !tc.wantWarning {
				return
			}
			// Both numbers: "you asked for X and you are getting Y".
			for _, want := range []string{strconv.Itoa(tc.want), strconv.Itoa(tc.wantHz)} {
				if !strings.Contains(warning, want) {
					t.Errorf("warning %q does not name %s -- it has to say what was asked for AND what is being used", warning, want)
				}
			}
		})
	}
}

// TestANegativeExitWithPIDIsNotAnnouncedAsWatched: the "watching pid" announcement and the watcher agree for every
// sign of pid.
func TestANegativeExitWithPIDIsNotAnnouncedAsWatched(t *testing.T) {
	for _, pid := range []int{-1, -4294967296, 0, 1, 4321} {
		want := pid > 0
		if got := watchingParentPID(pid); got != want {
			t.Errorf("watchingParentPID(%d) = %v, want %v", pid, got, want)
		}
		// gone reports dead on the first poll, so the call returns either way.
		polled, fired := false, false
		watchParentPID(pid, func(int) bool { polled = true; return true }, time.Millisecond, func() { fired = true })
		if polled != want || fired != want {
			t.Errorf("watchParentPID(%d) polled=%v fired=%v, but the log line says it is watched: %v",
				pid, polled, fired, want)
		}
	}
}

// TestTwoActionsOnTheSameChordAreRefusedAsADuplicate: the clash is named as one in the config, not left to Windows
// to report as "another program may already own this chord".
func TestTwoActionsOnTheSameChordAreRefusedAsADuplicate(t *testing.T) {
	actions, warnings := parseHotkeys([]hotkeyBinding{
		{core.ReplayRecordToggle, "ctrl+shift+F9"},
		{core.ReplaySaveLast, "CTRL+Shift+f9"}, // the same chord: parsing is case- and order-insensitive
		{core.ReplayLast, "ctrl+shift+F11"},
	})
	if len(actions) != 2 {
		t.Fatalf("%d actions registered, want 2 -- the duplicate must not reach the OS", len(actions))
	}
	if actions[0].Name != string(core.ReplayRecordToggle) || actions[1].Name != string(core.ReplayLast) {
		t.Fatalf("registered %q and %q, want the FIRST claim on the chord to keep it", actions[0].Name, actions[1].Name)
	}
	if len(warnings) != 1 {
		t.Fatalf("warnings = %v, want exactly one naming the clash", warnings)
	}
	for _, want := range []string{string(core.ReplaySaveLast), string(core.ReplayRecordToggle), "already"} {
		if !strings.Contains(warnings[0], want) {
			t.Errorf("warning %q does not contain %q -- it has to name both actions and say what the problem is", warnings[0], want)
		}
	}
}

// TestAnUnparsableChordIsStillReportedAlone: one bad chord is skipped and every other key still binds.
func TestAnUnparsableChordIsStillReportedAlone(t *testing.T) {
	actions, warnings := parseHotkeys([]hotkeyBinding{
		{core.ReplayRecordToggle, "F12"}, // reserved for the debugger, refused by hotkey.Parse
		{core.ReplaySaveLast, ""},        // empty unbinds, silently
		{core.ReplayLast, "ctrl+shift+F11"},
	})
	if len(actions) != 1 || actions[0].Name != string(core.ReplayLast) {
		t.Fatalf("actions = %v, want only replay_last bound", actions)
	}
	if len(warnings) != 1 || !strings.Contains(warnings[0], string(core.ReplayRecordToggle)) {
		t.Fatalf("warnings = %v, want one naming record_toggle and nothing for the empty chord", warnings)
	}
}

// TestBareFlagDefaultsAreNotCalledTheShippedDefaults: the flag's predictor (linear) is not the release's (damped), so
// a run on bare flag defaults must not be labelled shipped.
func TestBareFlagDefaultsAreNotCalledTheShippedDefaults(t *testing.T) {
	shipped := func(predict core.PredictMode) bool {
		return runningTheShippedSmoothing(core.DefaultInterpolationDelay, core.DefaultLocalGhostDelay,
			0, 0, 0, core.CurveLinear, predict)
	}
	if shipped(core.PredictLinear) {
		t.Error("a run with the flag's default predictor is not the shipped configuration and must not say it is")
	}
	if !shipped(shippedPredict) {
		t.Error("the shipped values themselves must still be labelled as the shipped defaults")
	}
	// The line's other settings, so loosening any check fails too.
	if runningTheShippedSmoothing(core.DefaultInterpolationDelay, core.DefaultLocalGhostDelay,
		0, 500*time.Millisecond, 0, core.CurveLinear, shippedPredict) {
		t.Error("extrapolation on is a dev rig, whatever else matches")
	}
	if runningTheShippedSmoothing(core.DefaultInterpolationDelay, core.DefaultLocalGhostDelay,
		0, 0, 100*time.Millisecond, core.CurveLinear, shippedPredict) {
		t.Error("error decay on is a dev rig, whatever else matches")
	}
	if runningTheShippedSmoothing(core.DefaultInterpolationDelay, core.DefaultLocalGhostDelay,
		0, 0, 0, core.CurveCatmullRom, shippedPredict) {
		t.Error("a non-linear curve is a dev rig, whatever else matches")
	}
}
