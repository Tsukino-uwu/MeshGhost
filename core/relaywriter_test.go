package core

import (
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// stalledTransport is a relay that accepted the connection and stopped reading:
// every write blocks until the test releases it, which is what a real socket
// does once the far side's receive window closes. transport's own write
// deadline would end it after ten seconds -- ten seconds is the defect.
type stalledTransport struct {
	release chan struct{}

	mu    sync.Mutex
	calls int
}

func newStalledTransport() *stalledTransport {
	return &stalledTransport{release: make(chan struct{})}
}

func (st *stalledTransport) Send(payload []byte) error {
	st.mu.Lock()
	st.calls++
	st.mu.Unlock()
	<-st.release
	return nil
}

func (st *stalledTransport) SendUnreliable(payload []byte) error { return st.Send(payload) }
func (st *stalledTransport) OnReceive(func([]byte))              {}
func (st *stalledTransport) OnDisconnect(func(error))            {}
func (st *stalledTransport) OnError(func(error))                 {}
func (st *stalledTransport) Close() error                        { close(st.release); return nil }

// A RELAY THAT STOPPED READING MUST NOT STOP THE GAME.
//
// forwardLocalState runs on the bridge connection's read goroutine, so for as
// long as it blocks, the core reads nothing from the adapter -- the bridge
// socket's buffer fills, and the adapter's next write blocks on the game's own
// main thread. A frozen game, on a machine where nothing is wrong, because
// something across the internet stopped reading. The write deadline bounds it
// at ten seconds, which is not a bound worth having.
//
// Without core/relaywriter.go this test hangs at the first frame until the test
// binary's own timeout kills it.
func TestAStalledRelayDoesNotBlockTheFramePath(t *testing.T) {
	st := newStalledTransport()
	c := New()
	c.MinSendInterval = time.Nanosecond
	c.mu.Lock()
	c.relay = st
	c.playerID = "p1"
	c.mu.Unlock()
	t.Cleanup(func() { st.Close() })

	done := make(chan struct{})
	go func() {
		defer close(done)
		// More frames than the queue holds, so the drop policy is exercised
		// too: a state displaced by a newer one is exactly what the lossy
		// plane says to lose.
		for i := 0; i < maxRelayOutboxLines*2; i++ {
			s := state(float64(i), 0, "walk")
			c.forwardLocalState(&s)
		}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the frame path is still blocked on a relay that stopped reading -- this is the " +
			"game's main thread one bridge buffer later, and the only thing that ends it is a " +
			"ten-second write deadline")
	}

	// And the writer really is where the block went: exactly one write is in
	// flight, holding the socket, while everything behind it waits in the queue.
	//
	// WAIT FOR THAT FIRST WRITE RATHER THAN ASSUMING IT HAPPENED. The frame
	// path returning (above) says nothing about whether the writer goroutine
	// has been scheduled yet, and under CPU contention it has not: this read
	// then sees 0 and the test fails claiming the queue was never entered.
	// Waiting cannot mask the regression it guards, because the stalled
	// transport never returns from a write -- once the count reaches 1 no
	// second write can start, so "exactly 1" is still exactly what is asserted.
	deadline := time.Now().Add(2 * time.Second)
	calls := 0
	for time.Now().Before(deadline) {
		st.mu.Lock()
		calls = st.calls
		st.mu.Unlock()
		if calls > 0 {
			break
		}
		time.Sleep(2 * time.Millisecond)
	}
	if calls != 1 {
		t.Fatalf("the stalled transport saw %d writes, want 1 -- the writer goroutine should be "+
			"parked in the first one with the rest queued behind it", calls)
	}
}

// A RELIABLE LINE IS NEVER DROPPED, so a full queue of them is a connection to
// give up on rather than a message to lose. This is the other half of the
// overflow policy, and the half that must not be a silent success: a lost
// escrow commit is one side having given something away that the other never
// received.
func TestAFullQueueOfUndroppableLinesGivesUpOnTheConnection(t *testing.T) {
	st := newStalledTransport()
	c := New()
	c.mu.Lock()
	c.relay = st
	c.playerID = "p1"
	c.activeFeatures = []string{protocol.FeatureEventV1}
	c.mu.Unlock()

	var lastErr error
	for i := 0; i < maxRelayOutboxLines*2; i++ {
		lastErr = c.SendEvent(protocol.Event{Payload: json.RawMessage(`{"kind":"chest_opened"}`)})
		if lastErr != nil {
			break
		}
	}
	if lastErr == nil {
		t.Fatal("every event was accepted by a relay that has read nothing -- a reliable line " +
			"reported as sent when it was silently dropped is worse than a failure, because " +
			"nothing upstream can retry what it was told arrived")
	}
}
