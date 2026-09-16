package core

// B5, B6 and B8 from the 2026-09-12 adversarial review: three things a relay
// could spend a client's resources on without breaking any rule.

import (
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// B8 (P3a-4). The age-out walks c.remotes, so a Join that never sends a state
// creates no buffer and its seat was never reachable. MaxRosterSize of them --
// which cost a relay one line each -- locked the room shut for real arrivals
// AND for the player's own chasers and replays, since admitLocalPeer goes
// through the same capped admission.
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

	// The premise is asked with a RELAY id: since 2026-09-16 (PM-2) local ghosts
	// have their own share of the bound, so a chaser is admitted even now --
	// which closes this finding's chaser half by construction. The age-out below
	// is still what gives the relay's own seats back.
	c.mu.Lock()
	full := c.admitToRosterLocked("one-more-silent")
	c.mu.Unlock()
	if full {
		t.Fatal("test premise broken: the roster was not actually full")
	}

	// Nothing has happened, so nothing is reclaimed yet: a seat that is merely
	// NEW must survive, or every join would be undone before its first state.
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

	// Before the fix: 512 and false, for the rest of the connection.
	if left != 0 {
		t.Errorf("%d seat(s) with no state behind them survived 30s -- the age-out cannot see them, "+
			"because it walks the buffer map and they have no buffer", left)
	}
	if !admitted {
		t.Error("a real arrival was still refused a seat -- a relay that sends nothing but joins " +
			"locks the room shut for the rest of the connection")
	}
}

// The other half of B8's guard: a local ghost is admitted before its feeding
// goroutine has produced anything, and dropping its seat inside that window is
// the 2026-09-08 regression ADR 0053 exists to prevent.
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

// B5 (P3b-3). Every sleep in reconnectWithBackoff came AFTER a failed dial, and
// the loop returns the moment one succeeds -- so a relay that welcomed and then
// dropped got a free immediate redial, forever, at whatever rate it liked.
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

	// Now the welcome-then-drop cycle. Each session comes up and dies at once.
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

	// And a session that actually lasted resets it, so an ordinary relay
	// restart is not punished for the connection before it.
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

// B6 (P3b-4). Pong.ServerTimeMs was bounded by nothing, and nowMsLocked clamps
// its output monotonically -- so one accepted sample moved this client's clock
// forward for the rest of the session, no matter how far.
// NO FAKE CLOCK HERE, deliberately: observePong measures the round trip with
// time.Now() and says why in its own annotation -- an RTT is a fact about the
// real network, and a virtual clock cannot measure one. Mixing the two makes
// every offset in this test a multiple of the gap between 2020 and today.
func TestARelayCannotMoveThisClientsClockArbitrarily(t *testing.T) {
	c := New()
	c.mu.Lock()
	c.activeFeatures = []string{protocol.FeatureClockV1}
	c.mu.Unlock()

	sentAt := time.Now()
	c.recordPingSent(1, sentAt)
	c.recordPingSent(2, sentAt)

	// The largest reading that is still IN SCHEMA -- MaxTimestampMs itself,
	// which lands in the year 2109 and is ~83 years ahead of this clock. The
	// point of using the maximum is that no pre-existing bound touches it:
	// before the fix this was simply accepted.
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
