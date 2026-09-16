package core

import (
	"net"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// The client's side of the room-code proof (ADR 0067), against a real relay
// over TLS. The code never leaves this process: what these assert is what a
// player sees -- the right code joins, on both legs; the wrong code is a
// permanent, named refusal that the client decides for itself before it
// sends a third message; and a relay with no code welcomes with a note.

func codedCore(t *testing.T, relayAddr, code string) *Core {
	t.Helper()
	c := New()
	c.RelayAddr = relayAddr
	c.Room = "room1"
	c.DisplayName = "alice"
	c.RoomCode = code
	c.DialTimeout = testTimeout
	return c
}

func TestTheRightCodeJoinsAndTheWrongOneIsAPermanentLocalRefusal(t *testing.T) {
	s := relay.NewServer()
	s.RoomCode = "letmein"
	addr := startRelayWith(t, s)

	if err := codedCore(t, addr, "letmein").ConnectRelay("emerald"); err != nil {
		t.Fatalf("the right code did not join: %v", err)
	}

	err := codedCore(t, addr, "wrong").ConnectRelay("emerald")
	if err == nil {
		t.Fatal("the wrong code joined")
	}
	if !IsPermanentRejectErr(err) {
		t.Fatalf("a wrong code is not classified permanent: %v", err)
	}
	if !strings.Contains(err.Error(), "room code") {
		t.Fatalf("the refusal does not name the room code: %v", err)
	}
	if err := codedCore(t, addr, "").ConnectRelay("emerald"); err == nil || !IsPermanentRejectErr(err) {
		t.Fatalf("no code against a coded relay: %v; want a permanent refusal", err)
	}
}

// TestTheDiscoveryLegProvesTheCodeToo: the query-only hello used to carry
// the code, so it must carry the proof now, or a client on transport auto
// could never reach a coded relay's transport list.
func TestTheDiscoveryLegProvesTheCodeToo(t *testing.T) {
	s := relay.NewServer()
	s.RoomCode = "letmein"
	ln := listenTLS(t)
	port := ln.Addr().(*net.TCPAddr).Port
	s.Offers = []protocol.TransportOffer{{Kind: "tcp", Port: port}}
	bindProofToTestIdentity(s)
	go s.Serve(ln)

	c := codedCore(t, ln.Addr().String(), "letmein")
	c.Transport = netx.Auto
	if err := c.ConnectRelay("emerald"); err != nil {
		t.Fatalf("auto transport against a coded relay: %v", err)
	}
	if c.PlayerID() == "" {
		t.Fatal("no player id after a join through discovery")
	}
}

// TestARoomCodeRefusalIsTriedAgainOnceAnInterval is pass 5's P1b-client-3:
// a room-code refusal was cached for the life of the process, so one refusal
// from a server that was not the real one -- or a host who fixed their code
// a moment later -- kept the player solo until they restarted. It stays
// cached (no redial at the adapter's retry pace) until RoomCodeRetryInterval
// has passed, then is tried for real. Any other permanent refusal is not.
func TestARoomCodeRefusalIsTriedAgainOnceAnInterval(t *testing.T) {
	defer func(v time.Duration) { RoomCodeRetryInterval = v }(RoomCodeRetryInterval)
	RoomCodeRetryInterval = 300 * time.Millisecond

	s := relay.NewServer()
	s.RoomCode = "the-old-code"
	addr := startRelayWith(t, s)
	c := codedCore(t, addr, "letmein")

	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err == nil || !IsRoomCodeRefusalErr(err) {
		t.Fatalf("first attempt: %v; want a room-code refusal", err)
	}
	s.SetRoomCode("letmein") // the host fixes it
	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err == nil {
		t.Fatal("an attempt inside the interval dialled again instead of answering from the cache")
	} else if !IsRoomCodeRefusalErr(err) {
		t.Fatalf("the cached refusal lost its code: %v", err)
	}
	time.Sleep(RoomCodeRetryInterval + 50*time.Millisecond)
	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err != nil {
		t.Fatalf("after the interval the refusal was not tried again: %v", err)
	}

	// Another permanent refusal stays cached however long it has been.
	s2 := relay.NewServer()
	s2.SetOnlyGame("crystal")
	c2 := New()
	c2.RelayAddr = startRelayWith(t, s2)
	c2.Room = "room1"
	c2.DisplayName = "bob"
	c2.DialTimeout = testTimeout
	if err := c2.ConnectRelayOnAdapterHello("emerald", "", nil); err == nil || IsRoomCodeRefusalErr(err) {
		t.Fatalf("game not allowed: %v", err)
	}
	s2.SetOnlyGame("")
	time.Sleep(RoomCodeRetryInterval + 50*time.Millisecond)
	if err := c2.ConnectRelayOnAdapterHello("emerald", "", nil); err == nil {
		t.Fatal("a non-room-code permanent refusal was retried after the interval")
	}
}

// TestAClientWithACodeRefusesARelayWithNone: a code on one side only is a
// mismatch (ADR 0070). This client joined and logged a line until 2026-09-16,
// so an impostor took the session by never asking for the proof. The refusal
// is permanent and names the room code, like a wrong code.
func TestAClientWithACodeRefusesARelayWithNone(t *testing.T) {
	addr := startRelay(t)
	c := codedCore(t, addr, "letmein")
	err := c.ConnectRelay("emerald")
	if err == nil {
		t.Fatal("a client with a room code joined a relay that asked for none")
	}
	if !IsPermanentRejectErr(err) || !strings.Contains(err.Error(), "room code") {
		t.Fatalf("refusal %v; want a permanent one naming the room code", err)
	}
	if c.PlayerID() != "" {
		t.Fatalf("the refused session still adopted player id %q", c.PlayerID())
	}
}
