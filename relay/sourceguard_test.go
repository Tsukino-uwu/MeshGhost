package relay

import (
	"encoding/json"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// fakeGuard is a SourceGuard that blocks after a set number of failures and
// records what it was asked, so the relay's side of the contract can be
// asserted without netx/srclimit's bucket in the way.
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

// TestAWrongRoomCodeIsReportedToTheGuardAndABlockedSourceIsRefusedFirst:
// the relay tells the guard about each wrong code, asks it before every
// compare, and once it says blocked the hello is refused as "rate limited"
// -- without the code being compared, so a RIGHT code from a blocked source
// is refused too, and the reply says nothing about which it was.
func TestAWrongRoomCodeIsReportedToTheGuardAndABlockedSourceIsRefusedFirst(t *testing.T) {
	s := NewServer()
	s.RoomCode = "right"
	guard := &fakeGuard{blockAt: 2}
	s.SourceGuard = guard
	addr := startServerWith(t, s)

	for i := 0; i < 2; i++ {
		c := dialTestClientWithHello(t, addr, protocol.Hello{GameID: "g", Room: "r", RoomCode: "wrong"})
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

	// Blocked now: even the right code is refused, as rate limited, and the
	// failure count does not move (nothing was compared).
	c := dialTestClientWithHello(t, addr, protocol.Hello{GameID: "g", Room: "r", RoomCode: "right"})
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

// TestNoGuardMeansNoBudget: every existing test runs with a nil guard, and
// the relay must not so much as touch it.
func TestNoGuardMeansNoBudget(t *testing.T) {
	s := NewServer()
	s.RoomCode = "right"
	addr := startServerWith(t, s)
	for i := 0; i < 5; i++ {
		c := dialTestClientWithHello(t, addr, protocol.Hello{GameID: "g", Room: "r", RoomCode: "wrong"})
		if rej := c.expectReject(2 * time.Second); rej.Code != protocol.CodeInvalidRoomCode {
			t.Fatalf("attempt %d: code %q, want %q", i, rej.Code, protocol.CodeInvalidRoomCode)
		}
		c.conn.Close()
	}
	c := dialTestClientWithHello(t, addr, protocol.Hello{GameID: "g", Room: "r", RoomCode: "right"})
	c.expectWelcome(2 * time.Second)
}
