package core

import (
	"sync"
	"testing"
)

// closeSpy is a transport that records whether it was closed and what was
// written to it. Enough to tell a Goodbye-and-close apart from being left alone.
type closeSpy struct {
	mu     sync.Mutex
	closed bool
	sends  int
}

func (t *closeSpy) Send(payload []byte) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.sends++
	return nil
}
func (t *closeSpy) SendUnreliable(payload []byte) error { return t.Send(payload) }
func (t *closeSpy) OnReceive(func(payload []byte))      {}
func (t *closeSpy) OnDisconnect(func(err error))        {}
func (t *closeSpy) OnError(func(err error))             {}
func (t *closeSpy) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.closed = true
	return nil
}
func (t *closeSpy) wasClosed() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.closed
}

// A late teardown must not close the relay a SUCCESSOR is using.
//
// releaseAdapterSlot frees the admission slot and returns a SNAPSHOT of what the
// gone connection owned. From the instant it returns, a relaunched game may
// attach -- 150 ms is the measured real-world figure (2026-09-06, the
// 512-chaser session) -- and since 2026-09-07 the writer's onDead runs the
// teardown as `go c.finishBridgeTeardown(...)`, adding unbounded scheduling
// latency between the snapshot and the act.
//
// finishBridgeTeardown acted on that stale snapshot: it closed the relay before
// it ever looked for a successor, and its successor check was a separate c.mu
// section that was already out of date by the time StopReplays ran. Its own
// comment claimed ownership made this safe; ownership was read once and never
// re-read, and a successor can inherit this very relay connection through
// relaysession.go's same-game transfer branch. The result on screen is peers
// seeing the player leave and rejoin under a new player_id, and a relaunched
// game running with no chasers, no replays and no recording -- with every log
// line looking normal.
func TestALateTeardownLeavesTheSuccessorsRelayAlone(t *testing.T) {
	c := New()
	relay := &closeSpy{}
	gone := &closeSpy{}      // the adapter that went away
	successor := &closeSpy{} // the relaunched game, already attached

	c.mu.Lock()
	c.relay = relay
	c.relayOwner = successor // the successor inherited the relay
	c.attachedAdapter = successor
	c.mu.Unlock()

	// The stale snapshot the gone connection's releaseAdapterSlot would have
	// produced: it DID own the relay at the time it was taken.
	c.finishBridgeTeardown(gone, true, true, relay)

	if relay.wasClosed() {
		t.Fatal("a late teardown closed the relay connection the successor had taken over: " +
			"ownership was snapshotted before the slot was freed and never re-read, so peers " +
			"see the player leave and rejoin under a new player_id")
	}
	if relay.sends != 0 {
		t.Fatalf("a late teardown sent %d message(s) on the successor's relay -- a Goodbye "+
			"clears the resume record the successor is holding", relay.sends)
	}
}

// The ordinary case must still work: no successor, the relay is still ours, so
// the teardown really does say goodbye and close. Without this the test above
// would pass against a finishBridgeTeardown that had simply stopped working.
func TestAnOrdinaryTeardownStillClosesItsOwnRelay(t *testing.T) {
	c := New()
	relay := &closeSpy{}
	gone := &closeSpy{}

	c.mu.Lock()
	c.relay = relay
	c.relayOwner = gone
	c.attachedAdapter = nil // nobody took the slot
	c.mu.Unlock()

	c.finishBridgeTeardown(gone, true, true, relay)

	if !relay.wasClosed() {
		t.Fatal("an ordinary adapter disconnect did not close its own relay connection -- " +
			"the player's ghost freezes in place for everyone else instead of leaving")
	}
	if relay.sends == 0 {
		t.Fatal("no Goodbye was sent before the close")
	}
}
