package relay

import (
	"encoding/json"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/paketest"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// fakeGuard blocks after a set number of failures and records what it was asked, so the relay's side can be
// asserted without netx/srclimit's bucket.
type fakeGuard struct {
	mu       sync.Mutex
	failures int
	blockAt  int
	asked    int
}

func (g *fakeGuard) Blocked(net.Conn) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.asked++
	return g.failures >= g.blockAt
}

func (g *fakeGuard) NoteAuthFailure(net.Conn) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.failures++
}

func (g *fakeGuard) NoteAuthSuccess(net.Conn) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.failures--
}

// TestLoginsHeldOpenInParallelCannotOutspendTheBudget: the KE2 tells a client whether its code was right, so the third
// concurrent login from a source with a budget of two is refused before its code is compared.
func TestLoginsHeldOpenInParallelCannotOutspendTheBudget(t *testing.T) {
	s := NewServer()
	s.RoomCode = "right"
	guard := &fakeGuard{blockAt: 2}
	s.SourceGuard = guard
	addr := startServerWith(t, s)

	held := func(code string) protocol.MessageType {
		conn, err := transport.Dial(addr)
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		t.Cleanup(func() { conn.Close() })
		got := make(chan protocol.MessageType, 4)
		conn.OnReceive(func(payload []byte) {
			var env protocol.Envelope
			if json.Unmarshal(payload, &env) == nil {
				got <- env.Type
			}
		})
		prover := paketest.New(t, code, "")
		b, err := json.Marshal(protocol.Hello{GameID: "g", Room: "r", ProtocolVersion: protocol.Version, PakeKE1: prover.KE1()})
		if err != nil {
			t.Fatal(err)
		}
		line, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: b})
		if err != nil {
			t.Fatal(err)
		}
		if err := conn.Send(line); err != nil {
			t.Fatalf("send hello: %v", err)
		}
		select {
		case typ := <-got:
			return typ // and never answered: the login stays open
		case <-time.After(2 * time.Second):
			t.Fatal("no answer to the hello")
			return ""
		}
	}
	for i := 0; i < 2; i++ {
		if typ := held("guess"); typ != protocol.TypePake {
			t.Fatalf("login %d: got %q, want a KE2 while the budget lasts", i, typ)
		}
	}
	if typ := held("guess"); typ != protocol.TypeReject {
		t.Fatalf("a third login held open beside two others got %q: each was answered against a budget none had spent", typ)
	}
}

// TestARightCodeCostsNothing: the attempt charged when a proof begins is refunded when it proves the right code.
func TestARightCodeCostsNothing(t *testing.T) {
	s := NewServer()
	s.RoomCode = "right"
	guard := &fakeGuard{blockAt: 1}
	s.SourceGuard = guard
	addr := startServerWith(t, s)
	for i := 0; i < 3; i++ {
		c := dialTestClientWithCode(t, addr, protocol.Hello{GameID: "g", Room: "r"}, "right")
		c.expectWelcome(2 * time.Second)
		c.conn.Close()
	}
	guard.mu.Lock()
	defer guard.mu.Unlock()
	if guard.failures != 0 {
		t.Fatalf("three right codes left %d charged attempts, want 0", guard.failures)
	}
}

func (tc *testClient) expectReject(timeout time.Duration) protocol.Reject {
	tc.t.Helper()
	env := tc.next(timeout)
	if env.Type != protocol.TypeReject {
		tc.t.Fatalf("got %q, want a reject", env.Type)
	}
	var rej protocol.Reject
	if err := json.Unmarshal(env.Payload, &rej); err != nil {
		tc.t.Fatalf("unmarshal reject: %v", err)
	}
	return rej
}

// TestAWrongRoomCodeIsReportedToTheGuardAndABlockedSourceIsRefusedFirst: a blocked source is refused as rate limited
// before any compare, so even a right code is refused and the reply says nothing about which it was.
func TestAWrongRoomCodeIsReportedToTheGuardAndABlockedSourceIsRefusedFirst(t *testing.T) {
	s := NewServer()
	s.RoomCode = "right"
	guard := &fakeGuard{blockAt: 2}
	s.SourceGuard = guard
	addr := startServerWith(t, s)

	for i := 0; i < 2; i++ {
		c := dialTestClientWithCode(t, addr, protocol.Hello{GameID: "g", Room: "r"}, "wrong")
		if rej := c.expectReject(2 * time.Second); rej.Code != protocol.CodeInvalidRoomCode {
			t.Fatalf("attempt %d: code %q, want %q", i, rej.Code, protocol.CodeInvalidRoomCode)
		}
		c.conn.Close()
	}
	guard.mu.Lock()
	failures, asked := guard.failures, guard.asked
	guard.mu.Unlock()
	if failures != 2 || asked != 2 {
		t.Fatalf("guard saw %d failures and %d questions, want 2 and 2", failures, asked)
	}

	// Blocked: the right code is refused as rate limited, and nothing is compared.
	c := dialTestClientWithCode(t, addr, protocol.Hello{GameID: "g", Room: "r"}, "right")
	rej := c.expectReject(2 * time.Second)
	if rej.Code != protocol.CodeForReason(protocol.ReasonRateLimited) {
		t.Fatalf("blocked source got code %q (%q), want the rate-limited one", rej.Code, rej.Reason)
	}
	if !rej.Retryable {
		t.Fatal("a rate-limited refusal must be retryable, or the client gives up on a code that is right")
	}
	guard.mu.Lock()
	failures = guard.failures
	guard.mu.Unlock()
	if failures != 2 {
		t.Fatalf("a blocked hello was counted as a failure (%d); the code must not be compared at all", failures)
	}
}

// TestNoGuardMeansNoBudget: every other test runs with a nil guard, which the relay must not touch.
func TestNoGuardMeansNoBudget(t *testing.T) {
	s := NewServer()
	s.RoomCode = "right"
	addr := startServerWith(t, s)
	for i := 0; i < 5; i++ {
		c := dialTestClientWithCode(t, addr, protocol.Hello{GameID: "g", Room: "r"}, "wrong")
		if rej := c.expectReject(2 * time.Second); rej.Code != protocol.CodeInvalidRoomCode {
			t.Fatalf("attempt %d: code %q, want %q", i, rej.Code, protocol.CodeInvalidRoomCode)
		}
		c.conn.Close()
	}
	c := dialTestClientWithCode(t, addr, protocol.Hello{GameID: "g", Room: "r"}, "right")
	c.expectWelcome(2 * time.Second)
}
