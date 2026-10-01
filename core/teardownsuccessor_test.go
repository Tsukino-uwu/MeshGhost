package core

import (
	"sync"
	"testing"
)

// closeSpy is a transport that records whether it was closed and how many sends it took.
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

// TestALateTeardownLeavesTheSuccessorsRelayAlone: finishBridgeTeardown gets a snapshot taken when the slot was freed,
// and a relaunched game may attach and inherit the relay before it runs, so ownership is re-read at the act.
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

	// The stale snapshot releaseAdapterSlot would have produced: the gone connection owned the relay when it was taken.
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

// The control: with no successor the teardown still says goodbye and closes, or the test above passes against a
// finishBridgeTeardown that stopped working.
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
