package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeConfig writes body to a temp config.json and returns its path, with
// prefix prepended raw so a test can put a byte-order mark (or anything else
// an editor might leave) in front of the JSON.
func writeConfig(t *testing.T, prefix []byte, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.json")
	if err := os.WriteFile(path, append(prefix, []byte(body)...), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}

const testClientConfig = `{"client": {"connect_to": "1.2.3.4:9999", "room_code": "letmein"}}`

// applyTestConfig runs applyFileConfig over path with no flags marked
// explicit, returning the resulting relay address and room code.
func applyTestConfig(path string) (relayAddr, roomCode string) {
	relayAddr, roomCode, _ = applyTestConfigFull(path)
	return relayAddr, roomCode
}

// applyTestConfigFull is applyTestConfig plus the transport, and it passes
// EVERY configTargets field. Passing all of them is not tidiness: a nil
// target is a nil dereference the moment a config file sets the
// corresponding key, so a partially-populated struct here would turn a real
// crash into a test that passes by never exercising the field.
func applyTestConfigFull(path string) (relayAddr, roomCode, transport string) {
	relayAddr, roomCode, transport, _, _ = applyTestConfigWithTLS(path, map[string]bool{})
	return relayAddr, roomCode, transport
}

// applyTestConfigWithTLS is applyTestConfigFull plus the two tls keys, and
// takes the explicit-flag set so a test can assert flag-beats-file.
func applyTestConfigWithTLS(path string, explicit map[string]bool) (relayAddr, roomCode, transport, tlsMode, tlsPin string) {
	var bridgeAddr, gameID, room, name, gameVersion, features string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole bool
	applyFileConfig(path, explicit, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, tlsMode: &tlsMode, tlsPin: &tlsPin,
		showConsole: &showConsole, features: &features,
	})
	return relayAddr, roomCode, transport, tlsMode, tlsPin
}

// TestConfigWithUTF8BOMIsStillRead is the regression test for a config file
// saved by a Windows editor that prepends a UTF-8 BOM: encoding/json refuses
// those three bytes, which used to discard the whole file — silently falling
// back to defaults for every setting in it, including room_code, while
// looking perfectly correct to whoever edited it. Mirrors the relay's own
// test. Found while testing the only_game setting.
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

// TestConfigWithoutBOMIsUnaffected confirms the BOM strip didn't change the
// ordinary case.
func TestConfigWithoutBOMIsUnaffected(t *testing.T) {
	path := writeConfig(t, nil, testClientConfig)

	relayAddr, roomCode := applyTestConfig(path)
	if relayAddr != "1.2.3.4:9999" || roomCode != "letmein" {
		t.Errorf("connect_to = %q, room_code = %q, want the plain file read normally", relayAddr, roomCode)
	}
}

// TestUTF16ConfigLeavesDefaults confirms a UTF-16 file is refused rather than
// half-read: it can't be salvaged by stripping a prefix, so applyFileConfig
// must leave every target untouched (the caller's flag defaults) instead of
// writing garbage into them.
func TestUTF16ConfigLeavesDefaults(t *testing.T) {
	path := writeConfig(t, []byte{0xFF, 0xFE}, testClientConfig)

	relayAddr, roomCode := applyTestConfig(path)
	if relayAddr != "" || roomCode != "" {
		t.Errorf("connect_to = %q, room_code = %q, want both left at their defaults", relayAddr, roomCode)
	}
}

// TestTransportIsReadFromConfig confirms the transport key reaches the flag
// target, since a client that silently ignored it would connect over tcp
// while its operator believed otherwise — and on a quic relay that is the
// difference between an encrypted session and no session at all.
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

// TestTransportAbsentFromConfigLeavesTheFlagDefault is the compatibility
// half: every config.json written before selectable transports existed has
// no "transport" key at all, and those must keep behaving exactly as they
// did rather than being reset to an empty string that then fails to parse.
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

// TestShowConsoleIsReadFromConfig covers the only path a player can actually
// reach this setting by: editing config.json. There is a -show-console flag too,
// but nobody autostarting the client types flags -- the adapter spawns it without
// any.
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

// TestShowConsoleAbsentFromConfigStaysOff guards the default that makes autostart
// worth having. Every config.json written before this key existed omits it, and a
// silent client is the entire point -- an absent key must never be read as "open a
// window".
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

// TestWineConsoleIsReportedNotPretended covers what replaced a mistake. There
// was briefly a default here that turned the console ON under Wine, as a safety
// valve in case an autostarted client outlived its game there. The Linux tester
// proved both halves wrong on 2026-08-16: no window ever appeared (Wine has no
// usable console for a Proton-launched game), and -exit-with-pid reaped the
// client every time anyway, so there was nothing to guard.
//
// What is left is honesty: if someone asks for a console where one cannot exist,
// say so rather than silently doing nothing -- which is exactly what cost that
// tester an afternoon.
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

// TestOneBadValueDoesNotDiscardTheWholeConfig is the regression test for the bug
// that cost a real user their whole session on 2026-08-16. They wrote
// `"show_console": "true"` -- quoted, so a JSON string where a bool belongs --
// and every OTHER setting silently reverted to its built-in default. The relay
// logged them joining as "player" rather than the name they had configured,
// which is how it was spotted at all.
//
// The values checked here are deliberately the ones that matter to a player:
// where they connect, which room, and what they are called.
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
	// The offending setting itself is the one thing that must NOT be guessed at:
	// "true" is a string, and treating it as true would be inventing intent.
	if showConsole {
		t.Error("show_console was applied from a string value, want it skipped as unreadable")
	}
}

// TestSyntaxErrorStillDiscardsTheWholeConfig pins the other half. A missing
// comma or stray brace is not one bad field -- the rest of the file cannot be
// trusted to mean what the user intended, so the original whole-file warning is
// still the right answer there. Being lenient about EVERYTHING would have been
// the easy overcorrection.
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

// TestWatchParentPIDFiresOnceWhenTheParentGoes is the regression test for the
// orphan case autostart introduces: a game crashes, and the client it spawned
// keeps running with no window, holding the bridge port so the next launch can't
// listen. The probe is injected rather than killing a real process so this stays
// deterministic and identical on every platform.
func TestWatchParentPIDFiresOnceWhenTheParentGoes(t *testing.T) {
	var checks int
	fired := make(chan struct{}, 4)
	// Alive for the first two polls, then gone -- so the test also covers that
	// watchParentPID keeps waiting rather than firing on its first look.
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

// TestWatchParentPIDIgnoresZero covers the default. Every client a person starts
// themselves passes no -exit-with-pid, and pid 0 must not be watched: on Windows
// it is a real (system) process id, so a lenient check here would have this client
// watching something that never exits, and on the way there it would call the probe
// forever for no reason.
func TestWatchParentPIDIgnoresZero(t *testing.T) {
	called := false
	watchParentPID(0, func(int) bool { called = true; return true }, time.Millisecond,
		func() { t.Error("onGone fired for pid 0, want no watch at all") })
	if called {
		t.Error("probe was called for pid 0, want the watch skipped entirely")
	}
}

// TestTLSKeysAreReadFromConfig: config.json is the only surface a player
// actually uses -- an autostarted client is spawned with no flags at all --
// so both keys have to work from the file.
func TestTLSKeysAreReadFromConfig(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"tls":"required","tls_fingerprint":"AB:CD"}}`)
	_, _, _, tlsMode, tlsPin := applyTestConfigWithTLS(path, map[string]bool{})
	if tlsMode != "required" {
		t.Errorf("tls = %q, want it read from the config file", tlsMode)
	}
	if tlsPin != "AB:CD" {
		t.Errorf("tls_fingerprint = %q, want it read verbatim (normalizing is tlsx's job)", tlsPin)
	}
}

// TestTLSAbsentFromConfigLeavesTheFlagDefault: an existing config file must
// behave exactly as it did before this feature existed.
func TestTLSAbsentFromConfigLeavesTheFlagDefault(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"connect_to":"1.2.3.4:7777"}}`)
	_, _, _, tlsMode, tlsPin := applyTestConfigWithTLS(path, map[string]bool{})
	if tlsMode != "" || tlsPin != "" {
		t.Fatalf("tls = %q / fingerprint = %q, want both left alone", tlsMode, tlsPin)
	}
}

// TestAnExplicitTLSFlagBeatsTheConfigFile, matching every other setting.
func TestAnExplicitTLSFlagBeatsTheConfigFile(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"tls":"off"}}`)
	_, _, _, tlsMode, _ := applyTestConfigWithTLS(path, map[string]bool{"tls": true})
	if tlsMode != "" {
		t.Fatalf("tls = %q, want the file ignored because the flag was passed explicitly", tlsMode)
	}
}

// TestBridgeIsLoopback covers the guard on the adapter bridge's bind address.
//
// The bridge has no authentication at all, and core.Core's doc comment states
// as a fact that it "is always loopback TCP" -- nothing enforced that until
// 2026-08-25. The case that matters is not a typo but config.json's
// "local_game_bridge" being shared between friends, so the false cases here are
// the ones this test exists for.
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
		"192.168.1.10:7778",
		"10.0.0.5:7778",
		"example.com:7778",
	}
	for _, addr := range remote {
		if bridgeIsLoopback(addr) {
			t.Errorf("bridgeIsLoopback(%q) = true, want false -- this address is reachable "+
				"from off the machine and the bridge is unauthenticated", addr)
		}
	}
}

// TestReplayBlockIsReadFromConfig covers the one way a player reaches
// recording: the nested "replay" block in config.json (ADR 0047). Absent, both
// keys keep the flag defaults -- a release must never record by surprise.
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

// TestHotkeysBlockIsReadFromConfig: the six chords come from the nested
// "hotkeys" block (ADR 0048); an absent block or key leaves the flag default,
// and an empty string is a deliberate unbind that survives the merge.
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

// TestChaserBlockIsReadFromConfig: the nested "chaser" block (ADR 0047), with
// absent keys left at the flag defaults.
func TestChaserBlockIsReadFromConfig(t *testing.T) {
	path := writeConfig(t, nil, `{"client":{"chaser":{"enabled":true,"count":4,"delay":"2s","name":"Me","spawn_delay":"4s"}}}`)
	var relayAddr, bridgeAddr, gameID, room, name, gameVersion, roomCode, transport string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole bool
	enabled, contact := false, false
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
	if spacing != 2*time.Second || color != "#7A2A2A" || contact {
		t.Fatalf("absent chaser keys changed: spacing=%v color=%q contact=%v", spacing, color, contact)
	}
}
