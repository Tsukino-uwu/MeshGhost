package core

// Three things a relay could spend a client's resources on without breaking any rule.

import (
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestASeatWithNoStateBehindItIsGivenBack: the age-out walks c.remotes, and a Join that never sends a state creates
// no buffer, so MaxRosterSize of them, a line each for a relay, would lock the room shut.
func TestASeatWithNoStateBehindItIsGivenBack(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk

	// Fill every seat with ids that arrived and then said nothing at all.
	for i := 0; i < protocol.MaxRosterSize; i++ {
		c.mu.Lock()
		ok := c.admitToRosterLocked(fmt.Sprintf("silent-%d", i))
		c.mu.Unlock()
		if !ok {
			t.Fatalf("could not fill the roster: refused at %d", i)
		}
	}

	// A relay id: local ghosts have their own share of the bound, so a chaser would be admitted even now.
	c.mu.Lock()
	full := c.admitToRosterLocked("one-more-silent")
	c.mu.Unlock()
	if full {
		t.Fatal("test premise broken: the roster was not actually full")
	}

	// A seat that is merely new must survive, or every join would be undone before its first state.
	c.remoteStatesAt(clk.Now().UnixMilli())
	c.mu.Lock()
	stillFull := len(c.roster)
	c.mu.Unlock()
	if stillFull != protocol.MaxRosterSize {
		t.Fatalf("a freshly admitted seat was reclaimed immediately (%d left of %d)",
			stillFull, protocol.MaxRosterSize)
	}

	clk.Advance(30 * time.Second)
	c.remoteStatesAt(clk.Now().UnixMilli())

	c.mu.Lock()
	left := len(c.roster)
	admitted := c.admitToRosterLocked("a-real-arrival")
	c.mu.Unlock()

	if left != 0 {
		t.Errorf("%d seat(s) with no state behind them survived 30s -- the age-out cannot see them, "+
			"because it walks the buffer map and they have no buffer", left)
	}
	if !admitted {
		t.Error("a real arrival was still refused a seat -- a relay that sends nothing but joins " +
			"locks the room shut for the rest of the connection")
	}
}

// TestTheSweepNeverTakesALocalGhostsSeat: a local ghost is admitted before its feeding goroutine has produced
// anything, so the seatless sweep must not take its seat inside that window.
func TestTheSweepNeverTakesALocalGhostsSeat(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk

	if !c.admitLocalPeer(localPeerChaserPrefix+"1", protocol.Nametag{Name: "Chaser"}) {
		t.Fatal("could not admit a local chaser")
	}
	clk.Advance(30 * time.Second)
	c.remoteStatesAt(clk.Now().UnixMilli())

	c.mu.Lock()
	_, seated := c.roster[localPeerChaserPrefix+"1"]
	c.mu.Unlock()
	if !seated {
		t.Fatal("a chaser that had not yet been fed lost its roster seat to the seatless sweep")
	}
}

// TestASessionThatDiesInstantlyDoesNotGetAFreeRedial: reconnectWithBackoff returns the moment a dial succeeds, so a
// relay that welcomes and then drops must still cost the next dial a backoff.
func TestASessionThatDiesInstantlyDoesNotGetAFreeRedial(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk
	c.ReconnectInitialBackoff = 10 * time.Millisecond
	c.ReconnectMaxBackoff = 80 * time.Millisecond
	initial, max := c.reconnectBackoffBounds()

	// A first connect, with nothing before it to judge: no wait, and the floor.
	backoff, hold := c.resumeReconnectBackoff(initial, max)
	if hold || backoff != initial {
		t.Fatalf("a first connect waited (hold=%v, backoff=%s) -- nothing had failed yet", hold, backoff)
	}

	// The welcome-then-drop cycle: each session comes up and dies at once.
	for i := 0; i < 4; i++ {
		c.mu.Lock()
		c.relaySessionUpAt = clk.Now()
		c.mu.Unlock()
		clk.Advance(2 * time.Millisecond) // a session shorter than any backoff

		backoff, hold = c.resumeReconnectBackoff(initial, max)
		if !hold {
			t.Fatalf("cycle %d: the loop went straight to a dial after a session that lasted 2ms -- "+
				"this is the free redial, and it costs a TLS handshake and a goroutine set each time", i)
		}
		backoff = c.escalateReconnectBackoff(backoff, max)
	}
	if backoff != max {
		t.Errorf("after four instant sessions the wait is %s, want the ceiling %s", backoff, max)
	}

	// A session that lasted resets it, so an ordinary relay restart is not punished for the connection before it.
	c.mu.Lock()
	c.relaySessionUpAt = clk.Now()
	c.mu.Unlock()
	clk.Advance(500 * time.Millisecond)
	backoff, hold = c.resumeReconnectBackoff(initial, max)
	if hold || backoff != initial {
		t.Errorf("a session that lasted 500ms still made the next connect wait %s (hold=%v) -- "+
			"a relay restart must not inherit the cadence of whatever came before it", backoff, hold)
	}
}

// TestARelayCannotMoveThisClientsClockArbitrarily: nowMsLocked clamps monotonically, so one accepted Pong.ServerTimeMs
// would move this client's clock forward for the rest of the session. No fake clock: observePong measures the round
// trip with time.Now(), and mixing the two would skew every offset by the fake clock's epoch.
func TestARelayCannotMoveThisClientsClockArbitrarily(t *testing.T) {
	c := New()
	c.mu.Lock()
	c.activeFeatures = []string{protocol.FeatureClockV1}
	c.mu.Unlock()

	sentAt := time.Now()
	c.recordPingSent(1, sentAt)
	c.recordPingSent(2, sentAt)

	// MaxTimestampMs, the largest reading still in schema, so no other bound touches it.
	c.observePong(protocol.Pong{Nonce: 1, ServerTimeMs: protocol.MaxTimestampMs})

	c.mu.Lock()
	offset := c.clock.offsetMs
	c.mu.Unlock()
	if offset != 0 {
		t.Errorf("a relay moved this client's clock by %s -- every render time then runs past every "+
			"sample in the room, so the ghosts freeze and the age-out despawns everyone every tick",
			time.Duration(offset)*time.Millisecond)
	}

	// Out of schema entirely: refused before it is even paired with a ping.
	c.observePong(protocol.Pong{Nonce: 2, ServerTimeMs: protocol.MaxTimestampMs + 1})
	c.mu.Lock()
	offset, pending := c.clock.offsetMs, len(c.pendingPings)
	c.mu.Unlock()
	if offset != 0 {
		t.Errorf("a pong with a timestamp past MaxTimestampMs moved the clock by %d", offset)
	}
	if pending != 1 {
		t.Errorf("an out-of-schema pong consumed its pending ping (%d left, want 1) -- "+
			"a refused message must not spend the nonce a real reply needs", pending)
	}

	// The converse: an ordinary offset is still learned, or clock.v1 is dead.
	c.recordPingSent(3, time.Now())
	c.observePong(protocol.Pong{Nonce: 3, ServerTimeMs: time.Now().UnixMilli() + 5_000})
	c.mu.Lock()
	offset = c.clock.offsetMs
	c.mu.Unlock()
	if offset < 4_000 || offset > 6_000 {
		t.Errorf("an ordinary 5s clock offset came out as %d -- the bound is refusing the skew "+
			"clock sync exists to correct", offset)
	}
}
