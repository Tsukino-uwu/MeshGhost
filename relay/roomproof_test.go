package relay

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/paketest"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// The room-code proof on the relay's side (ADR 0067). What the pake package
// tests is the cryptography's integration; what these test is the relay's
// state machine around it: a hello that offers no proof, a proof that is
// started and abandoned, and a second hello while one is parked.

// TestAHelloWithoutAProofIsRefusedWhenACodeIsSet: the wire no longer has a
// room_code field, so a client that has no code sends nothing -- and a relay
// with a code must refuse that exactly as it refused a wrong code, and
// charge it to the source's budget.
func TestAHelloWithoutAProofIsRefusedWhenACodeIsSet(t *testing.T) {
	s := NewServer()
	s.RoomCode = "letmein"
	guard := &fakeGuard{blockAt: 100}
	s.SourceGuard = guard
	addr := startServerWith(t, s)

	c := dialTestClientWithHello(t, addr, protocol.Hello{GameID: "g", Room: "r"})
	defer c.conn.Close()
	if rej := c.expectReject(2 * time.Second); rej.Code != protocol.CodeInvalidRoomCode {
		t.Fatalf("a hello with no proof got %q (%q), want %q", rej.Code, rej.Reason, protocol.CodeInvalidRoomCode)
	}
	guard.mu.Lock()
	defer guard.mu.Unlock()
	if guard.failures != 1 {
		t.Fatalf("guard saw %d failures for a proof-less hello, want 1", guard.failures)
	}
}

// TestAnAbandonedProofIsChargedToTheSource: a client that learns its code is
// wrong at KE2 hangs up without a KE3 (core does exactly that). If that cost
// nothing, a guesser would start a proof per guess and never pay -- so the
// relay charges the budget when a parked hello's connection ends.
func TestAnAbandonedProofIsChargedToTheSource(t *testing.T) {
	s := NewServer()
	s.RoomCode = "letmein"
	guard := &fakeGuard{blockAt: 100}
	s.SourceGuard = guard
	addr := startServerWith(t, s)

	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	got := make(chan protocol.Envelope, 4)
	conn.OnReceive(func(payload []byte) {
		var env protocol.Envelope
		if json.Unmarshal(payload, &env) == nil {
			got <- env
		}
	})
	hello := protocol.Hello{ProtocolVersion: protocol.Version, GameID: "g", Room: "r",
		PakeKE1: paketest.New(t, "whatever", "").KE1()}
	hb, _ := json.Marshal(hello)
	env, _ := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hb})
	if err := conn.Send(env); err != nil {
		t.Fatalf("send: %v", err)
	}
	select {
	case e := <-got:
		if e.Type != protocol.TypePake {
			t.Fatalf("got %q, want the relay's KE2", e.Type)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no KE2 from the relay")
	}
	// Hang up mid-proof, as a client with the wrong code does.
	conn.Close()

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		guard.mu.Lock()
		n := guard.failures
		guard.mu.Unlock()
		if n == 1 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	guard.mu.Lock()
	defer guard.mu.Unlock()
	t.Fatalf("guard saw %d failures after an abandoned proof, want 1", guard.failures)
}

// TestASecondHelloDuringAParkedProofIsIgnored: between KE2 and KE3 the only
// line the relay acts on is the KE3; a hello there is neither answered nor
// admitted, so a client cannot use the parked window to skip the proof.
func TestASecondHelloDuringAParkedProofIsIgnored(t *testing.T) {
	s := NewServer()
	s.RoomCode = "letmein"
	addr := startServerWith(t, s)

	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	got := make(chan protocol.Envelope, 4)
	conn.OnReceive(func(payload []byte) {
		var env protocol.Envelope
		if json.Unmarshal(payload, &env) == nil {
			got <- env
		}
	})
	send := func(h protocol.Hello) {
		h.ProtocolVersion = protocol.Version
		hb, _ := json.Marshal(h)
		env, _ := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hb})
		_ = conn.Send(env)
	}
	send(protocol.Hello{GameID: "g", Room: "r", PakeKE1: paketest.New(t, "letmein", "").KE1()})
	select {
	case e := <-got:
		if e.Type != protocol.TypePake {
			t.Fatalf("got %q, want the relay's KE2", e.Type)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no KE2 from the relay")
	}
	// A second hello, with and without a proof, while the first is parked.
	send(protocol.Hello{GameID: "g", Room: "r"})
	send(protocol.Hello{GameID: "g", Room: "r", PakeKE1: paketest.New(t, "letmein", "").KE1()})
	select {
	case e := <-got:
		t.Fatalf("the relay answered a hello sent during a parked proof with %q", e.Type)
	case <-time.After(500 * time.Millisecond):
	}
}
