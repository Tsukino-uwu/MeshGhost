package relay

import (
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// THE TEST THIS FEATURE EXISTS FOR, and it fails against the code as it stood
// before outbox.go: Room.forward wrote to every recipient in turn on one
// goroutine, so a peer whose socket had stopped draining starved every peer
// behind it in the loop for up to the ten-second write timeout.
//
// Confirmed capable of failing rather than merely observed to pass -- the same
// discipline used for the udpconn framing lock. Reverting the enqueue in
// Room.forwardLine to an inline Send does not merely turn this red: the test
// HANGS, because Forward never returns at all while the stalled peer holds it.
// That is the defect in its starkest form, and it is worth knowing the old
// behaviour was "the room stops" rather than "the room is slow".
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

// A stalled peer must not stall the SENDER either. Room.forward runs on the
// sending client's own read goroutine (and, one level up, while transport holds
// its delivery mutex), so a blocking write there stops that client being able
// to send anything at all -- its own game freezes out of the session because
// somebody else's socket is wedged.
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

// The overflow policy is the contract's, not an invention: the state plane is
// lossy and latest-wins, so when a queue is full the stale sample is always the
// right one to lose. Everything else -- join, leave, event, lease, escrow,
// world -- may not be dropped at all.
func TestOverflowDropsStaleStateAndKeepsReliableMessages(t *testing.T) {
	o := &outbox{signal: make(chan struct{}, 1), id: "p1", done: make(chan struct{})}
	// No writer goroutine: the queue is inspected directly, so nothing drains.

	for i := 0; i < maxOutboxLines; i++ {
		if !o.enqueue(outMsg{line: []byte("state"), unreliable: true}) {
			t.Fatalf("filling the queue with state should never ask for a disconnect (at %d)", i)
		}
	}

	// One more state: accepted, by displacing an older one. The queue must not
	// grow, which is the property that bounds memory.
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

	// A reliable message at a full queue means the peer is not reading at all.
	// Dropping it would strand a ghost or wedge a trade, so the caller is told
	// to disconnect instead.
	if o.enqueue(outMsg{line: []byte("leave"), unreliable: false}) {
		t.Fatal("a reliable message at a full queue must ask for a disconnect, never be dropped")
	}
}

// A queue holding only reliable messages has nothing droppable in it, so an
// arriving state yields rather than displacing something that may not be lost.
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

// Order within one client's queue is FIFO, which is what keeps the control
// plane's total order intact: Room.sendMu assigns a sequencer stamp and then
// delivers, and "deliver" now means "enqueue in order onto each recipient's
// FIFO". If the queue reordered, the order assigned would stop being the order
// sent, which is the invariant online.go's header calls load-bearing.
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

// Closing drains rather than discards. The last thing a refused client is owed
// is the Reject explaining why, and it travels this same queue -- discarding on
// close would turn an explained refusal into a bare hangup.
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

// One goroutine per client means a leak per player who ever joined if close is
// ever missed. relay/leak_test.go covers the server end to end; this covers the
// primitive directly, including the case where the writer is parked waiting for
// work rather than draining.
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
