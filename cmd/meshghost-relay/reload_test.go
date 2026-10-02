package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// These drive the poll by hand, two polls per save as cfg.FileWatch settles, and check the effect on a real server.

func writeRelayConfig(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	// A poll compares mtime and size, so two same-length saves inside one mtime tick would be missed by design.
	now := time.Now()
	_ = os.Chtimes(path, now, now)
}

func settle(w *relayConfigWatcher) {
	w.poll() // first sight: pending
	w.poll() // held still: applied
}

// TestRelayReloadAppliesTheThreeLiveKeysWithoutDroppingAnyone: a new code
// gates the next hello and the member already in stays.
func TestRelayReloadAppliesTheThreeLiveKeysWithoutDroppingAnyone(t *testing.T) {
	captureLog(t)
	path := filepath.Join(t.TempDir(), "config.json")
	writeRelayConfig(t, path, `{"server":{"room_code":"first","max_clients":8}}`)

	addr, srv := startShippedStack(t, stackOpts{roomCode: "first"})
	base := relayLive{maxClients: relay.DefaultMaxClients}
	live := base
	live.roomCode = "first"
	w := newRelayConfigWatcher(path, map[string]bool{}, base, live, srv)

	// A member joins under the first code and stays connected throughout.
	member := dialTLS(t, addr)
	sendHelloWithCode(t, member, helloFor(), "first", srv.PakeIdentity)
	if env := readEnvelope(t, member); env.Type != protocol.TypeWelcome {
		t.Fatalf("member got %q, want a welcome", env.Type)
	}

	writeRelayConfig(t, path, `{"server":{"room_code":"second","only_game":"game-a","max_clients":2}}`)
	settle(w)

	c := dialTLS(t, addr)
	sendHelloWithCode(t, c, helloFor(), "first", srv.PakeIdentity)
	if rej := readReject(t, c); rej.Code != protocol.CodeInvalidRoomCode {
		t.Fatalf("old code after the reload: %q, want %q", rej.Code, protocol.CodeInvalidRoomCode)
	}
	c = dialTLS(t, addr)
	h := helloFor()
	h.GameID = "game-b"
	sendHelloWithCode(t, c, h, "second", srv.PakeIdentity)
	if rej := readReject(t, c); rej.Code != protocol.CodeForReason(protocol.ReasonGameNotAllowed) {
		t.Fatalf("other game after only_game was set: %q, want %q", rej.Code, protocol.CodeForReason(protocol.ReasonGameNotAllowed))
	}
	c = dialTLS(t, addr)
	sendHelloWithCode(t, c, helloFor(), "second", srv.PakeIdentity)
	if env := readEnvelope(t, c); env.Type != protocol.TypeWelcome {
		t.Fatalf("new code after the reload got %q, want a welcome", env.Type)
	}
	// max_clients 2: the member and this one fill it; a third is refused.
	third := dialTLS(t, addr)
	sendHelloWithCode(t, third, helloFor(), "second", srv.PakeIdentity)
	if rej := readReject(t, third); rej.Code != protocol.CodeForReason(protocol.ReasonServerFull) {
		t.Fatalf("third join under max_clients 2: %q (%q), want server full", rej.Code, rej.Reason)
	}
	// The first member was never disconnected: it still reads the joins.
	_ = member.SetReadDeadline(time.Now().Add(2 * time.Second))
	if env := readEnvelope(t, member); env.Type != protocol.TypeJoin {
		t.Fatalf("the member got %q after the reload, want the join of the new player (still connected)", env.Type)
	}
}

// TestRelayReloadFallsBackToTheFlagValueAndNamesRelaunchOnlyKeys: a removed key returns to what the flags said, and a
// changed relaunch-only key is reported against the running value on every save and never carries forward.
func TestRelayReloadFallsBackToTheFlagValueAndNamesRelaunchOnlyKeys(t *testing.T) {
	captureLog(t)
	path := filepath.Join(t.TempDir(), "config.json")
	writeRelayConfig(t, path, `{"server":{"room_code":"first","listen_on":"0.0.0.0:7777"}}`)
	srv := relay.NewServer()
	srv.RoomCode = "first"
	base := relayLive{addr: "127.0.0.1:7777", maxClients: relay.DefaultMaxClients}
	live := base
	live.roomCode, live.addr = "first", "0.0.0.0:7777"
	w := newRelayConfigWatcher(path, map[string]bool{}, base, live, srv)

	writeRelayConfig(t, path, `{"server":{"listen_on":"0.0.0.0:9999"}}`)
	w.poll()
	lines := w.reload()
	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, "room_code removed") {
		t.Fatalf("removing room_code was not reported as applied:\n%s", joined)
	}
	if srv.RoomCode != "" {
		t.Fatalf("room_code still %q after the key was removed; want the flag value (empty)", srv.RoomCode)
	}
	if !strings.Contains(joined, "listen_on 0.0.0.0:7777 -> 0.0.0.0:9999 (needs a relaunch") {
		t.Fatalf("a changed listen_on was not reported as relaunch-only:\n%s", joined)
	}
	// A second save applies max_clients; listen_on, still differing from the running value, is reported again but
	// never applied.
	writeRelayConfig(t, path, `{"server":{"listen_on":"0.0.0.0:9999","max_clients":3}}`)
	w.poll()
	lines = w.reload()
	joined = strings.Join(lines, "\n")
	if !strings.Contains(joined, "listen_on 0.0.0.0:7777 -> 0.0.0.0:9999 (needs a relaunch") {
		t.Fatalf("a still-pending relaunch-only key was not reported against the running value:\n%s", joined)
	}
	if !strings.Contains(joined, "max_clients 8 -> 3") {
		t.Fatalf("max_clients change not reported:\n%s", joined)
	}
	if w.prev.addr != "0.0.0.0:7777" {
		t.Fatalf("the relaunch-only listen_on carried forward to %q; the running value must stay", w.prev.addr)
	}
	// An explicit flag is never overridden by the file; with -max-clients given, the running value is the flag's.
	livex := w.prev
	livex.maxClients = base.maxClients
	wx := newRelayConfigWatcher(path, map[string]bool{"max-clients": true}, base, livex, srv)
	writeRelayConfig(t, path, `{"server":{"max_clients":5}}`)
	wx.poll()
	if lines := wx.reload(); strings.Contains(strings.Join(lines, "\n"), "max_clients") {
		t.Fatalf("the file overrode a flag given on the command line:\n%s", strings.Join(lines, "\n"))
	}
}

// TestRelayReloadKeepsTheLiveSettingsWhenASaveGoesWrong: a broken, empty or section-less save changes nothing, and
// the next good save still applies.
func TestRelayReloadKeepsTheLiveSettingsWhenASaveGoesWrong(t *testing.T) {
	captureLog(t)
	path := filepath.Join(t.TempDir(), "config.json")
	writeRelayConfig(t, path, `{"server":{"room_code":"secret","only_game":"game-a","max_clients":3}}`)
	srv := relay.NewServer()
	srv.RoomCode = "secret"
	base := relayLive{maxClients: relay.DefaultMaxClients}
	live := base
	live.roomCode, live.onlyGame, live.maxClients = "secret", "game-a", 3
	w := newRelayConfigWatcher(path, map[string]bool{}, base, live, srv)

	for _, bad := range []string{
		`{"server":{"room_code":"secret",,"max_clients":3}}`, // a stray comma
		``,                        // an editor that truncates before writing
		`{"client":{"name":"x"}}`, // the server section gone
		`{"server":null}`,
	} {
		writeRelayConfig(t, path, bad)
		w.poll()
		if lines := w.reload(); len(lines) != 0 {
			t.Fatalf("a bad save %q applied changes:\n%s", bad, strings.Join(lines, "\n"))
		}
		if srv.RoomCode != "secret" || w.prev.onlyGame != "game-a" || w.prev.maxClients != 3 {
			t.Fatalf("a bad save %q moved what is live: room_code=%q only_game=%q max_clients=%d",
				bad, srv.RoomCode, w.prev.onlyGame, w.prev.maxClients)
		}
	}
	writeRelayConfig(t, path, `{"server":{"room_code":"rotated","only_game":"game-a","max_clients":3}}`)
	w.poll()
	if lines := w.reload(); !strings.Contains(strings.Join(lines, "\n"), "room_code changed") || srv.RoomCode != "rotated" {
		t.Fatalf("the good save after the bad ones did not apply: room_code=%q lines=%v", srv.RoomCode, lines)
	}
}

// TestRelayReloadDoesNotReportAResolvedListenAddressAsChanged: main resolves an empty listen_quic or listen_udp in
// place, and a watcher seeded with the resolved value would report it changed on every save.
func TestRelayReloadDoesNotReportAResolvedListenAddressAsChanged(t *testing.T) {
	captureLog(t)
	path := filepath.Join(t.TempDir(), "config.json")
	writeRelayConfig(t, path, `{"server":{"room_code":"a"}}`)
	srv := relay.NewServer()
	var l relayLive
	l.maxClients = relay.DefaultMaxClients
	targets := l.targets()
	l.roomCode = "a"
	// As main does: the file leaves both empty, then they are resolved in place.
	fileQuic, fileUDP := l.quicAddr, l.udpAddr
	l.quicAddr, l.udpAddr = "127.0.0.1:7777", "127.0.0.1:7778"
	w := newRelayConfigWatcher(path, map[string]bool{}, relayLive{maxClients: relay.DefaultMaxClients},
		watcherSeed(targets, fileQuic, fileUDP), srv)

	writeRelayConfig(t, path, `{"server":{"room_code":"b"}}`)
	w.poll()
	joined := strings.Join(w.reload(), "\n")
	if strings.Contains(joined, "listen_quic") || strings.Contains(joined, "listen_udp") {
		t.Fatalf("an untouched listen address was reported as changed:\n%s", joined)
	}
	if !strings.Contains(joined, "room_code changed") {
		t.Fatalf("the real change was not reported:\n%s", joined)
	}
}
