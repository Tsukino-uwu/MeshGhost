package core

import (
	"sync"
	"sync/atomic"
	"testing"
)

// wedgedTransport is an adapter that accepts a connection and never reads: Send blocks until the test releases it,
// which is what "stuck, not slow" means. It records whether it was closed.
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

// TestAStuckAdapterHasItsSocketClosed, not merely its session torn down: the queue cap is the only verdict reached
// without a failed write, which closes the connection for free, and the mod's reconnect keys off a socket close.
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

	// Events, which never coalesce: coalescing is the slow path, and this test is about the stuck one. Loop until
	// refused, since the writer takes one batch before its first Send blocks; the ceiling makes a broken cap fail.
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
