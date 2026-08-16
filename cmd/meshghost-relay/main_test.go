package main

import (
	"os"
	"path/filepath"
	"testing"
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

const testServerConfig = `{"server": {"listen_on": "1.2.3.4:9999", "only_game": "pseudoregalia"}}`

// applyTestConfig runs applyFileConfig over path with no flags marked
// explicit, returning the resulting listen address and only_game.
func applyTestConfig(path string) (addr, onlyGame string) {
	addr, onlyGame, _, _ = applyTestConfigFull(path)
	return addr, onlyGame
}

// applyTestConfigFull is applyTestConfig plus the transport keys, and it
// passes EVERY configTargets field. Passing all of them is not tidiness: a
// nil target is a nil dereference the moment a config file sets the
// corresponding key, so a partially-populated struct here would turn a real
// crash into a test that passes by never exercising the field.
func applyTestConfigFull(path string) (addr, onlyGame, transport, quicAddr string) {
	var maxClients, sendHz int
	var roomCode string
	applyFileConfig(path, map[string]bool{}, configTargets{
		addr: &addr, roomCode: &roomCode, onlyGame: &onlyGame,
		maxClients: &maxClients, sendHz: &sendHz,
		transport: &transport, quicAddr: &quicAddr,
	})
	return addr, onlyGame, transport, quicAddr
}

// TestConfigWithUTF8BOMIsStillRead is the regression test for a config file
// saved by a Windows editor that prepends a UTF-8 BOM: encoding/json refuses
// those three bytes, which used to discard the whole file — silently falling
// back to defaults for every setting in it, including room_code, while
// looking perfectly correct to whoever edited it. Found while testing the
// only_game setting.
func TestConfigWithUTF8BOMIsStillRead(t *testing.T) {
	path := writeConfig(t, []byte{0xEF, 0xBB, 0xBF}, testServerConfig)

	addr, onlyGame := applyTestConfig(path)
	if addr != "1.2.3.4:9999" {
		t.Errorf("listen_on = %q, want it read through the BOM", addr)
	}
	if onlyGame != "pseudoregalia" {
		t.Errorf("only_game = %q, want it read through the BOM", onlyGame)
	}
}

// TestConfigWithoutBOMIsUnaffected confirms the BOM strip didn't change the
// ordinary case.
func TestConfigWithoutBOMIsUnaffected(t *testing.T) {
	path := writeConfig(t, nil, testServerConfig)

	addr, onlyGame := applyTestConfig(path)
	if addr != "1.2.3.4:9999" || onlyGame != "pseudoregalia" {
		t.Errorf("listen_on = %q, only_game = %q, want the plain file read normally", addr, onlyGame)
	}
}

// TestUTF16ConfigLeavesDefaults confirms a UTF-16 file is refused rather than
// half-read: it can't be salvaged by stripping a prefix, so applyFileConfig
// must leave every target untouched (the caller's flag defaults) instead of
// writing garbage into them.
func TestUTF16ConfigLeavesDefaults(t *testing.T) {
	path := writeConfig(t, []byte{0xFF, 0xFE}, testServerConfig)

	addr, onlyGame := applyTestConfig(path)
	if addr != "" || onlyGame != "" {
		t.Errorf("listen_on = %q, only_game = %q, want both left at their defaults", addr, onlyGame)
	}
}

// TestTransportKeysAreReadFromConfig confirms both new server keys reach
// their flag targets. listen_quic matters as much as transport: quic runs
// over udp and so cannot share a port with the plain udp transport, which
// means a relay serving both needs two addresses and silently dropping one
// of them would bind quic somewhere nobody is dialing.
func TestTransportKeysAreReadFromConfig(t *testing.T) {
	path := writeConfig(t, nil, `{"server":{"listen_on":"0.0.0.0:7777",`+
		`"listen_quic":"0.0.0.0:7780","transport":"tcp,udp,quic"}}`)
	addr, _, transport, quicAddr := applyTestConfigFull(path)
	if transport != "tcp,udp,quic" {
		t.Errorf("transport = %q, want %q", transport, "tcp,udp,quic")
	}
	if quicAddr != "0.0.0.0:7780" {
		t.Errorf("listen_quic = %q, want %q", quicAddr, "0.0.0.0:7780")
	}
	if addr != "0.0.0.0:7777" {
		t.Errorf("listen_on = %q, want %q", addr, "0.0.0.0:7777")
	}
}

// TestTransportAbsentFromConfigLeavesTheFlagDefaults is the compatibility
// half: a config.json written before selectable transports existed has
// neither key, and such a relay must keep serving tcp exactly as it did.
func TestTransportAbsentFromConfigLeavesTheFlagDefaults(t *testing.T) {
	path := writeConfig(t, nil, `{"server":{"listen_on":"0.0.0.0:7777"}}`)
	transport, quicAddr := "tcp", DefaultQuicAddr
	var addr, onlyGame, roomCode string
	var maxClients, sendHz int
	applyFileConfig(path, map[string]bool{}, configTargets{
		addr: &addr, roomCode: &roomCode, onlyGame: &onlyGame,
		maxClients: &maxClients, sendHz: &sendHz,
		transport: &transport, quicAddr: &quicAddr,
	})
	if transport != "tcp" {
		t.Errorf("transport = %q, want it left at the flag default %q", transport, "tcp")
	}
	if quicAddr != DefaultQuicAddr {
		t.Errorf("listen_quic = %q, want it left at %q", quicAddr, DefaultQuicAddr)
	}
}
