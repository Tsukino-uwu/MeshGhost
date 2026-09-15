package core

import (
	"net"
	"strings"
	"testing"

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

// TestARelayWithNoCodeWelcomesAClientThatHasOne: the relay ignores the offered
// proof; the client joins and notes that its code was not used.
func TestARelayWithNoCodeWelcomesAClientThatHasOne(t *testing.T) {
	addr := startRelay(t)
	var err error
	logged := captureLog(t, func() { err = codedCore(t, addr, "letmein").ConnectRelay("emerald") })
	if err != nil {
		t.Fatalf("a coded client against an uncoded relay did not join: %v", err)
	}
	if !strings.Contains(logged, "has no room code set") {
		t.Fatalf("the client did not note that its code went unused; log:\n%s", logged)
	}
}
