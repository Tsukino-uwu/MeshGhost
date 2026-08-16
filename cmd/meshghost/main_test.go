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
	var bridgeAddr, gameID, room, name, gameVersion string
	var interp, minSend time.Duration
	var maxReceiveHz int
	var showConsole bool
	applyFileConfig(path, map[string]bool{}, configTargets{
		relayAddr: &relayAddr, bridgeAddr: &bridgeAddr, gameID: &gameID,
		room: &room, name: &name, interp: &interp, minSend: &minSend,
		roomCode: &roomCode, gameVersion: &gameVersion, maxReceiveHz: &maxReceiveHz,
		transport: &transport, showConsole: &showConsole,
	})
	return relayAddr, roomCode, transport
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
