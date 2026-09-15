package core

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// The client's known-relays store (ADR 0066). Every test here drives the
// store the way the TLS handshake does -- through the Verifier, with a leaf
// certificate's DER -- and reads the file back through a fresh store rather
// than through the one that wrote it.

func newStore(t *testing.T) (*KnownRelays, string, *[]string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "tls", KnownRelaysFileName)
	var lines []string
	var mu sync.Mutex
	k := NewKnownRelays(path)
	k.Logf = func(format string, args ...any) {
		mu.Lock()
		lines = append(lines, fmt.Sprintf(format, args...))
		mu.Unlock()
	}
	return k, path, &lines
}

// der returns a distinct certificate's DER bytes per name, deterministic
// within a process so two calls with one name are one relay.
var (
	derMu    sync.Mutex
	derCache = map[string][]byte{}
)

func der(t *testing.T, name string) []byte {
	t.Helper()
	derMu.Lock()
	defer derMu.Unlock()
	if d, ok := derCache[name]; ok {
		return d
	}
	cfg, _, err := tlsx.ServerConfig("")
	if err != nil {
		t.Fatal(err)
	}
	d := cfg.Certificates[0].Certificate[0]
	derCache[name] = d
	return d
}

func TestTheFirstConnectionRecordsAndTheSecondMatches(t *testing.T) {
	k, path, lines := newStore(t)
	relayA := der(t, "A")

	if err := k.Verifier("relay.example:7777")(relayA); err != nil {
		t.Fatalf("first connection refused: %v", err)
	}
	if len(*lines) != 1 || !strings.Contains((*lines)[0], "first connection") {
		t.Fatalf("first connection logged %q; want one 'first connection' line", *lines)
	}
	if err := k.Verifier("relay.example:7777")(relayA); err != nil {
		t.Fatalf("second connection refused: %v", err)
	}
	if len(*lines) != 1 {
		t.Fatalf("a matching second connection logged %q; want silence", (*lines)[1:])
	}

	// Read back by a fresh store: what a relaunch sees.
	again := NewKnownRelays(path)
	if got, ok := again.Lookup("relay.example:7777"); !ok || got != tlsx.Fingerprint(relayA) {
		t.Fatalf("a fresh store reads %q (present=%v); want %q", got, ok, tlsx.Fingerprint(relayA))
	}
}

func TestAChangedIdentityWarnsLoudlyAndUpdatesTheEntry(t *testing.T) {
	k, path, lines := newStore(t)
	relayA, relayB := der(t, "A"), der(t, "B")
	addr := "relay.example:7777"

	if err := k.Verifier(addr)(relayA); err != nil {
		t.Fatal(err)
	}
	if err := k.Verifier(addr)(relayB); err != nil {
		// Deliberate for now: no PAKE yet, so a change is warned about, not
		// refused (agent_docs/tls-planning.md, the accepted trade-off).
		t.Fatalf("a changed identity was refused: %v", err)
	}
	warning := (*lines)[len(*lines)-1]
	if !strings.Contains(warning, "WARNING") || !strings.Contains(warning, "DIFFERENT identity") {
		t.Fatalf("the change was not warned about loudly: %q", warning)
	}
	if !strings.Contains(warning, tlsx.Fingerprint(relayA)) || !strings.Contains(warning, tlsx.Fingerprint(relayB)) {
		t.Fatalf("the warning does not name both fingerprints: %q", warning)
	}
	if got, _ := NewKnownRelays(path).Lookup(addr); got != tlsx.Fingerprint(relayB) {
		t.Fatalf("the entry holds %q after the change; want the new %q", got, tlsx.Fingerprint(relayB))
	}
	// And a further connection with the new identity is silent again.
	before := len(*lines)
	if err := k.Verifier(addr)(relayB); err != nil {
		t.Fatal(err)
	}
	if len(*lines) != before {
		t.Fatalf("the new identity is still being warned about: %q", (*lines)[before:])
	}
}

// TestTheRoomCodeIsNotPartOfTheTrustEntry: a host changing, adding or
// removing the room code changes nothing in the trust store -- the entry is
// the relay's certificate, and the code never touches it.
func TestTheRoomCodeIsNotPartOfTheTrustEntry(t *testing.T) {
	s := relay.NewServer()
	s.RoomCode = "first-code"
	addr := startRelayWith(t, s)
	k, path, _ := newStore(t)

	connect := func(code string) {
		t.Helper()
		c := New()
		c.KnownRelays = k
		c.RelayAddr = addr
		c.Room = "room1"
		c.DisplayName = "alice"
		c.RoomCode = code
		c.DialTimeout = testTimeout
		if err := c.ConnectRelay("emerald"); err != nil {
			t.Fatalf("connect with code %q: %v", code, err)
		}
	}
	connect("first-code")
	first, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	s.SetRoomCode("second-code")
	connect("second-code")
	s.SetRoomCode("")
	connect("")
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first, after) {
		t.Fatalf("the trust file changed across room-code changes:\nbefore: %s\nafter:  %s", first, after)
	}
}

func TestConcurrentFirstConnectionsDoNotCorruptTheFile(t *testing.T) {
	k, path, _ := newStore(t)
	const relays = 40
	var wg sync.WaitGroup
	for i := 0; i < relays; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			addr := fmt.Sprintf("relay-%d.example:7777", i)
			if err := k.Verifier(addr)(der(t, addr)); err != nil {
				t.Errorf("%s: %v", addr, err)
			}
		}(i)
	}
	wg.Wait()

	again := NewKnownRelays(path)
	for i := 0; i < relays; i++ {
		addr := fmt.Sprintf("relay-%d.example:7777", i)
		if got, ok := again.Lookup(addr); !ok || got != tlsx.Fingerprint(der(t, addr)) {
			t.Fatalf("%s: read back %q (present=%v)", addr, got, ok)
		}
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Fatalf("temporary file %s left behind", e.Name())
		}
	}
}

// TestACorruptFileRefusesRatherThanOverwrites: whoever can write the file can
// change a fingerprint in it, so one that does not parse is a question for
// the player, named in the error, never something to quietly replace.
func TestACorruptFileRefusesRatherThanOverwrites(t *testing.T) {
	k, path, _ := newStore(t)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	corrupt := []byte("{\"version\":1,\"relays\":{\"x:1\":{\"fingerprint\":\"not-a-fingerprint\"}}}")
	if err := os.WriteFile(path, corrupt, 0o644); err != nil {
		t.Fatal(err)
	}
	err := k.Verifier("relay.example:7777")(der(t, "A"))
	if err == nil {
		t.Fatal("a corrupt trust file did not refuse the connection")
	}
	if !strings.Contains(err.Error(), path) {
		t.Fatalf("the error does not name the file: %v", err)
	}
	if got, _ := os.ReadFile(path); !bytes.Equal(got, corrupt) {
		t.Fatalf("the corrupt file was rewritten to %q", got)
	}
}

// TestAHandEditedFingerprintStillMatches: colons and capitals in the file
// compare equal to what the relay presents -- the same forgiveness the old
// pin had, so a host who pastes their relay's fingerprint into a player's
// file by hand gets a match, not a warning.
func TestAHandEditedFingerprintStillMatches(t *testing.T) {
	k, path, lines := newStore(t)
	relayA := der(t, "A")
	fp := strings.ToUpper(tlsx.Fingerprint(relayA))
	var spaced strings.Builder
	for i := 0; i < len(fp); i += 2 {
		if i > 0 {
			spaced.WriteByte(':')
		}
		spaced.WriteString(fp[i : i+2])
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	file := fmt.Sprintf("{\"version\":1,\"relays\":{\"relay.example:7777\":{\"fingerprint\":%q}}}", spaced.String())
	if err := os.WriteFile(path, []byte(file), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := k.Verifier("relay.example:7777")(relayA); err != nil {
		t.Fatal(err)
	}
	if len(*lines) != 0 {
		t.Fatalf("a hand-edited match was treated as new or changed: %q", *lines)
	}
}

// TestAnUnwritableStoreStillConnects: an install on read-only media plays;
// it is warned once that nothing is remembered, and never again.
func TestAnUnwritableStoreStillConnects(t *testing.T) {
	blocker := filepath.Join(t.TempDir(), "tls")
	if err := os.WriteFile(blocker, []byte("a file where the folder should be"), 0o644); err != nil {
		t.Fatal(err)
	}
	var lines []string
	k := NewKnownRelays(filepath.Join(blocker, KnownRelaysFileName))
	k.Logf = func(format string, args ...any) { lines = append(lines, fmt.Sprintf(format, args...)) }
	for i := 0; i < 3; i++ {
		if err := k.Verifier(fmt.Sprintf("r%d:1", i))(der(t, "A")); err != nil {
			t.Fatalf("connection %d refused because the store cannot be written: %v", i, err)
		}
	}
	warned := 0
	for _, l := range lines {
		if strings.Contains(l, "could not write") {
			warned++
		}
	}
	if warned != 1 {
		t.Fatalf("%d write warnings for three connections; want exactly one:\n%s", warned, strings.Join(lines, "\n"))
	}
}

// TestANilStoreRefusesRatherThanTrusts: the nil pointer is not the
// in-memory store (Core allocates that); a caller holding nil gets an
// error, not a free pass.
func TestANilStoreRefusesRatherThanTrusts(t *testing.T) {
	var k *KnownRelays
	if err := k.Verifier("x:1")(der(t, "A")); err == nil {
		t.Fatal("a nil store accepted a certificate")
	}
	if _, ok := k.Lookup("x:1"); ok {
		t.Fatal("a nil store reports an entry")
	}
}

// TestACoreSharesOneStoreAcrossItsLegs: knownRelays() hands every caller
// the same store, so the discovery leg and the session leg cannot each
// trust on their own.
func TestACoreSharesOneStoreAcrossItsLegs(t *testing.T) {
	c := New()
	a, b := c.knownRelays(), c.knownRelays()
	if a != b || a == nil {
		t.Fatalf("two calls gave %p and %p; want one store", a, b)
	}
	if a.Path() != "" {
		t.Fatalf("a Core's default store is on disk at %q; want memory only", a.Path())
	}
}

// FuzzKnownRelaysFileNeverPanics: the file is written by this process and
// edited, at most, by a hand -- but it is still bytes off a disk, and the
// loader must come back with an error or a store, never a panic. A valid
// file must round-trip.
func FuzzKnownRelaysFileNeverPanics(f *testing.F) {
	valid, _ := json.Marshal(knownRelaysFile{Version: 1, Relays: map[string]knownRelay{
		"relay.example:7777": {Fingerprint: strings.Repeat("ab", 32), FirstSeen: "2026-09-15T00:00:00Z"},
	}})
	f.Add(valid)
	f.Add([]byte(""))
	f.Add([]byte("{}"))
	f.Add([]byte("null"))
	f.Add([]byte("[]"))
	f.Add([]byte("{\"version\":1,\"relays\":null}"))
	f.Add([]byte("{\"version\":2,\"relays\":{}}"))
	f.Add([]byte("{\"version\":1,\"relays\":{\"\":{\"fingerprint\":\"ab\"}}}"))
	f.Add([]byte("{\"version\":1,\"relays\":{\"a:1\":{\"fingerprint\":\"AB:CD\"}}}"))
	f.Add([]byte("{\"version\":1,\"relays\":{\"a:1\":{\"fingerprint\":12}}}"))
	f.Add(bytes.Repeat([]byte("{"), 10000))
	f.Fuzz(func(t *testing.T, data []byte) {
		entries, err := parseKnownRelays(data)
		if err != nil {
			return
		}
		for addr, e := range entries {
			if addr == "" || len(e.Fingerprint) != tlsx.FingerprintHexLen {
				t.Fatalf("a parsed store holds an invalid entry %q -> %q", addr, e.Fingerprint)
			}
		}
		// What parsed must write and parse again to the same thing.
		out, err := json.Marshal(knownRelaysFile{Version: knownRelaysFileVersion, Relays: entries})
		if err != nil {
			t.Fatal(err)
		}
		again, err := parseKnownRelays(out)
		if err != nil {
			t.Fatalf("a store's own output does not parse: %v", err)
		}
		if len(again) != len(entries) {
			t.Fatalf("round trip lost entries: %d -> %d", len(entries), len(again))
		}
	})
}
