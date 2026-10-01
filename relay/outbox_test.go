package relay

import (
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// With an inline Send in place of the outbox this test hangs rather than failing: Forward never returns.
func TestOneStalledPeerDoesNotBlockTheRoom(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)

	stalled := &fakeStallingTransport{unblock: make(chan struct{})}
	defer close(stalled.unblock)
	healthy := &recordingTransport{}

	stalledClient := &Client{PlayerID: "stalled", Conn: stalled}
	stalledClient.out = newOutbox("stalled", stalled)
	healthyClient := &Client{PlayerID: "healthy", Conn: healthy}
	healthyClient.out = newOutbox("healthy", healthy)
	r.tryAdd(stalledClient)
	r.tryAdd(healthyClient)

	env, err := envelope(protocol.TypeState, protocol.State{PlayerID: "sender", AreaID: "town"})
	if err != nil {
		t.Fatalf("envelope: %v", err)
	}
	r.Forward(env, []string{"stalled", "healthy"})

	deadline := time.After(2 * time.Second)
	for {
		healthy.mu.Lock()
		n := len(healthy.got)
		healthy.mu.Unlock()
		if n > 0 {
			return
		}
		select {
		case <-deadline:
			t.Fatal("the healthy peer received nothing while another peer was stalled — " +
				"a room must degrade one member at a time, not all at once")
		case <-time.After(2 * time.Millisecond):
		}
	}
}

// Room.forward runs on the sender's own read goroutine, so a blocking write there would freeze the sender out of the
// session because somebody else's socket is wedged.
func TestForwardReturnsPromptlyDespiteAStalledPeer(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	stalled := &fakeStallingTransport{unblock: make(chan struct{})}
	defer close(stalled.unblock)
	c := &Client{PlayerID: "stalled", Conn: stalled}
	c.out = newOutbox("stalled", stalled)
	r.tryAdd(c)

	env, _ := envelope(protocol.TypeState, protocol.State{PlayerID: "sender"})
	done := make(chan struct{})
	go func() {
		r.Forward(env, []string{"stalled"})
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Forward blocked on a stalled recipient; the sender's own read goroutine is stuck")
	}
}

// The state plane is lossy and latest-wins, so a full queue loses a stale sample; nothing reliable may be dropped.
func TestOverflowDropsStaleStateAndKeepsReliableMessages(t *testing.T) {
	o := &outbox{signal: make(chan struct{}, 1), id: "p1", done: make(chan struct{})}
	// No writer goroutine, so nothing drains.

	for i := 0; i < maxOutboxLines; i++ {
		if !o.enqueue(outMsg{line: []byte("state"), unreliable: true}) {
			t.Fatalf("filling the queue with state should never ask for a disconnect (at %d)", i)
		}
	}

	if !o.enqueue(outMsg{line: []byte("newer"), unreliable: true}) {
		t.Fatal("an overflowing state must displace a stale one, not disconnect the client")
	}
	o.mu.Lock()
	n := len(o.queue)
	newest := string(o.queue[len(o.queue)-1].line)
	o.mu.Unlock()
	if n != maxOutboxLines {
		t.Fatalf("queue grew to %d, want it bounded at %d", n, maxOutboxLines)
	}
	if newest != "newer" {
		t.Fatalf("newest queued line is %q, want the sample that just arrived", newest)
	}

	// A reliable line at a full queue means the peer is not reading; dropping it would strand a ghost or wedge a trade.
	if o.enqueue(outMsg{line: []byte("leave"), unreliable: false}) {
		t.Fatal("a reliable message at a full queue must ask for a disconnect, never be dropped")
	}
}

func TestStateYieldsRatherThanDisplacingAReliableMessage(t *testing.T) {
	o := &outbox{signal: make(chan struct{}, 1), id: "p1", done: make(chan struct{})}
	for i := 0; i < maxOutboxLines; i++ {
		o.enqueue(outMsg{line: []byte("event"), unreliable: false})
	}
	if !o.enqueue(outMsg{line: []byte("state"), unreliable: true}) {
		t.Fatal("a state arriving at a full reliable queue must be dropped quietly, not disconnect")
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if len(o.queue) != maxOutboxLines {
		t.Fatalf("queue is %d, want it unchanged at %d", len(o.queue), maxOutboxLines)
	}
	for i, m := range o.queue {
		if m.unreliable {
			t.Fatalf("a reliable message at index %d was displaced by a state", i)
		}
	}
}

// The queue is FIFO so the order Room.sendMu assigns sequencer stamps in stays the order sent.
func TestOutboxPreservesOrder(t *testing.T) {
	rt := &recordingTransport{}
	o := newOutbox("p1", rt)
	defer o.close()

	const n = 50
	for i := 0; i < n; i++ {
		o.enqueue(outMsg{line: []byte{byte(i)}})
	}

	deadline := time.After(2 * time.Second)
	for {
		rt.mu.Lock()
		got := len(rt.got)
		rt.mu.Unlock()
		if got >= n {
			break
		}
		select {
		case <-deadline:
			t.Fatalf("only %d of %d lines were written", got, n)
		case <-time.After(2 * time.Millisecond):
		}
	}

	rt.mu.Lock()
	defer rt.mu.Unlock()
	for i := 0; i < n; i++ {
		if len(rt.got[i]) != 1 || rt.got[i][0] != byte(i) {
			t.Fatalf("line %d is %v, want %d — the queue reordered", i, rt.got[i], i)
		}
	}
}

// A refused client's Reject travels this queue, so discarding on close would turn the refusal into a bare hangup.
func TestCloseDrainsWhatIsAlreadyQueued(t *testing.T) {
	rt := &recordingTransport{}
	o := newOutbox("p1", rt)
	o.enqueue(outMsg{line: []byte("reject")})
	o.close()

	select {
	case <-o.done:
	case <-time.After(2 * time.Second):
		t.Fatal("the writer goroutine did not exit after close")
	}
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if len(rt.got) != 1 || string(rt.got[0]) != "reject" {
		t.Fatalf("queued line was not drained before the writer exited: %v", rt.got)
	}
}

// A writer parked waiting for work must exit on close too, or every player who ever joined leaks a goroutine.
func TestClosingAnIdleOutboxStopsItsGoroutine(t *testing.T) {
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			o := newOutbox("p", &recordingTransport{})
			o.close()
			select {
			case <-o.done:
			case <-time.After(2 * time.Second):
				t.Error("an idle outbox's writer did not exit on close")
			}
		}()
	}
	wg.Wait()
}
