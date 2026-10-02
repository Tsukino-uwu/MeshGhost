package core

import (
	"bytes"
	"encoding/json"
	"errors"
	"log"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// stalledTransport is a relay that accepted the connection and stopped reading: every write blocks until the test
// releases it, as a real socket does once the far side's receive window closes. transport's write deadline would end it
// after ten seconds, and those ten seconds are the defect.
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

// TestAStalledRelayDoesNotBlockTheFramePath: a relay that stopped reading must not stop the game. forwardLocalState
// runs on the bridge connection's read goroutine, so while it blocks the bridge buffer fills and the adapter's next
// write blocks the game's main thread.
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
		// More frames than the queue holds, so the drop policy runs too: a state displaced by a newer one is what the
		// lossy plane may lose.
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

	// The writer is where the block went: exactly one write in flight, the rest queued. Wait for that first write,
	// since the writer goroutine may not be scheduled yet; waiting masks nothing, because the stalled write never
	// returns and no second one can start.
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

// TestAFullQueueOfUndroppableLinesGivesUpOnTheConnection: a reliable line is never dropped, so a full queue of them
// gives up on the connection with an error rather than reporting a lost message as sent.
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

// deadTransport fails every write, as a relay socket that has gone does.
type deadTransport struct{ stalledTransport }

func (d *deadTransport) Send([]byte) error           { return errDeadRelay }
func (d *deadTransport) SendUnreliable([]byte) error { return errDeadRelay }
func (d *deadTransport) Close() error                { return nil }

var errDeadRelay = errors.New("wsasend: an existing connection was forcibly closed by the remote host")

// TestADeadRelayCostsTheLogOneLineNotOnePerQueuedMessage: a relay connection that dies with a full queue logs its
// failure at most once a second, not once per queued message.
func TestADeadRelayCostsTheLogOneLineNotOnePerQueuedMessage(t *testing.T) {
	var logs bytes.Buffer
	var mu sync.Mutex
	prev := log.Writer()
	log.SetOutput(writerFunc(func(p []byte) (int, error) { mu.Lock(); defer mu.Unlock(); return logs.Write(p) }))
	defer log.SetOutput(prev)

	w := newRelayWriter(&deadTransport{}, nil)
	for i := 0; i < 200; i++ {
		w.enqueue(outRelayMsg{line: []byte("{}")})
	}
	w.waitDrained()
	w.close()
	mu.Lock()
	defer mu.Unlock()
	if n := strings.Count(logs.String(), "send to relay failed"); n > 2 {
		t.Fatalf("%d failure lines for one dead connection; want at most 2 (one a second)", n)
	}
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }
