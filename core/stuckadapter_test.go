package core

import (
	"sync"
	"sync/atomic"
	"testing"
)

// wedgedTransport is an adapter that accepts a connection and then never reads:
// Send blocks until the test releases it, which is what "stuck, not slow" means.
// It records whether it was closed, which is the thing under test.
type wedgedTransport struct {
	mu      sync.Mutex
	closed  bool
	release chan struct{}
}

func newWedgedTransport() *wedgedTransport {
	return &wedgedTransport{release: make(chan struct{})}
}

func (w *wedgedTransport) Send(payload []byte) error {
	<-w.release
	return nil
}
func (w *wedgedTransport) SendUnreliable(payload []byte) error { return w.Send(payload) }
func (w *wedgedTransport) OnReceive(func(payload []byte))      {}
func (w *wedgedTransport) OnDisconnect(func(err error))        {}
func (w *wedgedTransport) OnError(func(err error))             {}
func (w *wedgedTransport) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.closed = true
	close(w.release) // unblock the writer goroutine so the test can finish
	return nil
}
func (w *wedgedTransport) wasClosed() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.closed
}

// A stuck adapter must have its SOCKET closed, not merely its session torn down.
//
// The queue-cap branch is the only terminal verdict in adapterwriter.go reached
// without a write ever failing -- every other path gets the close for free,
// because transport.Send closes the connection before returning an error. So it
// sent the relay a Goodbye, cleared auto-retry, stopped chasers, replays and
// recording, freed the adapter slot, and left the connection ESTABLISHED. The
// mod kept a healthy socket, kept sending local_state forever, and received
// nothing ever again -- and because its reconnect logic keys off a socket close,
// it never fired. A player silently alone, with no error in the game, until they
// restart it.
//
// That is strictly worse than the 2026-09-06 lockout this refactor was written
// to fix, where the game at least saw a RESET and was back in 150 ms.
func TestAStuckAdapterHasItsSocketClosed(t *testing.T) {
	nd := newWedgedTransport()
	var superseded uint64
	var deadCalls atomic.Int64
	w := newAdapterWriter(nd, &superseded, func() { deadCalls.Add(1) })
	t.Cleanup(func() {
		if !nd.wasClosed() {
			nd.Close()
		}
	})

	// Fill past the cap. Every message is a distinct player so nothing can be
	// coalesced away -- coalescing is the SLOW path, and this test is about the
	// stuck one.
	// Loop until it refuses rather than guessing where that is: the writer
	// goroutine takes one batch before its first Send blocks, so the refusal
	// lands a batch-size past the cap and the exact number is not the point.
	// The generous ceiling is only so a broken cap fails the test instead of
	// hanging it.
	accepted, refused := 0, false
	for i := 0; i < adapterQueueCap*4; i++ {
		if !w.enqueue(queuedMsg{env: []byte(`{"type":"x"}`)}) {
			refused = true
			break
		}
		accepted++
	}

	if !refused {
		t.Fatalf("the writer accepted all %d messages against an adapter that reads nothing: "+
			"the queue cap never tripped, so this test proves nothing", accepted)
	}
	if got := deadCalls.Load(); got != 1 {
		t.Fatalf("onDead called %d times, want exactly 1", got)
	}
	if !nd.wasClosed() {
		t.Fatal("the writer declared the adapter stuck and tore the session down, but never " +
			"closed its socket -- the game keeps a healthy connection, sends forever, receives " +
			"nothing, and never reconnects because its reconnect keys off the close")
	}
}
