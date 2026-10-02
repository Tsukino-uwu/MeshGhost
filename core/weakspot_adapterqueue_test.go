package core

// The bridge queue's paths a fast adapter never reaches: adapterQueueCap and its boundary, forgetPending, and the
// behind-to-recovered transition. fakeAdapter reads as fast as Go can, so its queue is empty at every assertion and
// nothing coalesces, while bridge_deadadapter_test.go's adapter never reads at all. gatedBridgeConn is the adapter in
// between.

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// gatedBridgeConn is an adapter whose socket accepts writes only when the test says so: hold() makes every later Send
// block and allow() lets the held ones through. Everything written is kept in order. It is an adapter that is behind
// rather than gone, since a queue holds messages, and coalesces, only while the writer is busy.
type gatedBridgeConn struct {
	mu     sync.Mutex
	sent   [][]byte
	gate   chan struct{}
	closes int
	// entered carries one token per Send that has begun, so a test can wait for the writer to be inside the blocked
	// write. Best-effort: a test that stops reading it must not wedge the writer.
	entered chan struct{}
}

func newGatedBridgeConn() *gatedBridgeConn {
	return &gatedBridgeConn{entered: make(chan struct{}, 64)}
}

// hold makes every Send from now on block until allow is called.
func (g *gatedBridgeConn) hold() {
	g.mu.Lock()
	if g.gate == nil {
		g.gate = make(chan struct{})
	}
	g.mu.Unlock()
}

// allow releases whatever is blocked and lets later sends through.
func (g *gatedBridgeConn) allow() {
	g.mu.Lock()
	if g.gate != nil {
		close(g.gate)
		g.gate = nil
	}
	g.mu.Unlock()
}

func (g *gatedBridgeConn) Send(payload []byte) error {
	g.mu.Lock()
	gate := g.gate
	g.mu.Unlock()
	select {
	case g.entered <- struct{}{}:
	default:
	}
	if gate != nil {
		<-gate
	}
	g.mu.Lock()
	g.sent = append(g.sent, append([]byte(nil), payload...))
	g.mu.Unlock()
	return nil
}

func (g *gatedBridgeConn) SendUnreliable(payload []byte) error { return g.Send(payload) }
func (g *gatedBridgeConn) OnReceive(func([]byte))              {}
func (g *gatedBridgeConn) OnDisconnect(func(error))            {}
func (g *gatedBridgeConn) OnError(func(error))                 {}

func (g *gatedBridgeConn) Close() error {
	g.mu.Lock()
	g.closes++
	g.mu.Unlock()
	g.allow()
	return nil
}

func (g *gatedBridgeConn) closeCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.closes
}

// types returns the bridge message type of every line written, in order.
func (g *gatedBridgeConn) types() []bridge.MessageType {
	g.mu.Lock()
	defer g.mu.Unlock()
	out := make([]bridge.MessageType, 0, len(g.sent))
	for _, line := range g.sent {
		var env bridge.Envelope
		if err := json.Unmarshal(line, &env); err != nil {
			out = append(out, bridge.MessageType("<malformed>"))
			continue
		}
		out = append(out, env.Type)
	}
	return out
}

// waitEntered blocks until the writer goroutine is inside a Send.
func (g *gatedBridgeConn) waitEntered(t *testing.T) {
	t.Helper()
	select {
	case <-g.entered:
	case <-time.After(testTimeout):
		t.Fatal("the writer goroutine never reached a write on the adapter's socket")
	}
}

// eventMsg is one queued message that is not a render, so it never coalesces: the lane adapterQueueCap bounds.
func eventMsg(id string) queuedMsg {
	env, _ := marshalBridge(bridge.TypeDespawnRemote, bridge.DespawnRemote{PlayerID: id})
	return queuedMsg{env: env}
}

func renderMsg(id string, x float64) queuedMsg {
	env, _ := marshalBridge(bridge.TypeRenderRemote, bridge.RenderRemote{
		PlayerID: id, State: protocol.State{Position: []float64{x, 0}},
	})
	return queuedMsg{env: env, renderOf: id}
}

// TestAStuckAdapterAtTheQueueCapLosesItsSocketAndItsSlot pins the verdict at adapterQueueCap: one short of it is a
// healthy adapter having a hard time, and one past it closes the socket and frees the slot, or the mod keeps a healthy
// connection that receives nothing. The writer has no run() goroutine, because the queue depth is the condition under
// test.
func TestAStuckAdapterAtTheQueueCapLosesItsSocketAndItsSlot(t *testing.T) {
	nd := newGatedBridgeConn()
	var dead int
	w := &adapterWriter{
		nd:      nd,
		onDead:  func() { dead++ },
		pending: make(map[string]int),
		wake:    make(chan struct{}, 1),
	}

	// One short of the cap is a healthy adapter having a hard time: a pack restart at 512 chasers queues 512 despawns
	// and 512 nametags back to back.
	for i := 0; i < adapterQueueCap-1; i++ {
		if !w.enqueue(eventMsg("peer")) {
			t.Fatalf("message %d of %d was refused -- the queue gave up below its own cap, "+
				"which is the core becoming the limiting factor", i, adapterQueueCap-1)
		}
	}
	if dead != 0 || nd.closeCount() != 0 {
		t.Fatalf("the adapter was declared dead at %d queued messages, one short of the %d cap "+
			"(onDead fired %d time(s), socket closed %d time(s))", adapterQueueCap-1, adapterQueueCap, dead, nd.closeCount())
	}

	// The cap-th message still fits: the check is on the depth before the append.
	if !w.enqueue(eventMsg("peer")) {
		t.Fatalf("the message that filled the queue to exactly %d was refused", adapterQueueCap)
	}
	if got := w.queueLen(); got != adapterQueueCap {
		t.Fatalf("queue holds %d entries, want exactly %d -- the boundary moved", got, adapterQueueCap)
	}
	if dead != 0 || nd.closeCount() != 0 {
		t.Fatalf("the adapter was declared dead at exactly %d queued messages, which is still legal", adapterQueueCap)
	}

	// One past it is stuck, not slow, and that is a real disconnect.
	if w.enqueue(eventMsg("peer")) {
		t.Fatalf("the message past the %d-entry cap was accepted -- an adapter that has taken "+
			"nothing for that long is stuck, and the queue must stop growing", adapterQueueCap)
	}
	if dead != 1 {
		t.Fatalf("onDead fired %d time(s) on the stuck verdict, want exactly 1 -- the core's "+
			"adapter slot is never freed, so the game's next attach is refused \"busy\"", dead)
	}
	if got := nd.closeCount(); got != 1 {
		t.Fatalf("the stuck verdict closed the socket %d time(s), want exactly 1 -- without it the "+
			"mod keeps a healthy connection, keeps sending local_state and receives nothing ever "+
			"again, because its reconnect logic keys off a socket close", got)
	}
}

// TestADespawnIsNeverCoalescedAwayByALaterRender covers forgetPending, called from sendToAdapter. With [render(A),
// despawn(A)] queued, a respawn render must queue after the despawn rather than replace the first render, or the newest
// fact the adapter hears is the despawn and A stays invisible. It goes through sendToAdapter, where the call under test
// is.
func TestADespawnIsNeverCoalescedAwayByALaterRender(t *testing.T) {
	c := New()
	nd := newGatedBridgeConn()

	// Block the writer inside its first write, so what follows accumulates; with an empty queue nothing can coalesce.
	nd.hold()
	if err := c.sendToAdapter(nd, bridge.TypeBridgeReady, bridge.BridgeReady{}); err != nil {
		t.Fatalf("bridge_ready: %v", err)
	}
	nd.waitEntered(t)

	if err := c.sendToAdapter(nd, bridge.TypeRenderRemote, bridge.RenderRemote{
		PlayerID: "peer", State: protocol.State{AreaID: "a", Position: []float64{1, 0}},
	}); err != nil {
		t.Fatalf("first render: %v", err)
	}
	if err := c.sendToAdapter(nd, bridge.TypeDespawnRemote, bridge.DespawnRemote{PlayerID: "peer"}); err != nil {
		t.Fatalf("despawn: %v", err)
	}
	// The respawn must land after the despawn, not on the render in front of it.
	if err := c.sendToAdapter(nd, bridge.TypeRenderRemote, bridge.RenderRemote{
		PlayerID: "peer", State: protocol.State{AreaID: "a", Position: []float64{2, 0}},
	}); err != nil {
		t.Fatalf("respawn render: %v", err)
	}

	if got := c.writerFor(nd).queueLen(); got != 3 {
		t.Fatalf("queue holds %d entries, want 3 (render, despawn, render) -- a despawn is an "+
			"EVENT and must never be coalesced past, and a render queued after it must not "+
			"replace the one queued before it", got)
	}

	nd.allow()
	waitAdapterDrained(t, c, nd)

	got := nd.types()
	want := []bridge.MessageType{
		bridge.TypeBridgeReady,
		bridge.TypeRenderRemote,
		bridge.TypeDespawnRemote,
		bridge.TypeRenderRemote,
	}
	if len(got) != len(want) {
		t.Fatalf("the adapter was sent %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("message %d was %s, want %s -- the adapter was sent %v", i, got[i], want[i], got)
		}
	}
	if got[len(got)-1] != bridge.TypeRenderRemote {
		t.Fatalf("the last thing the adapter heard about this peer was %s -- it came back and was "+
			"never drawn", got[len(got)-1])
	}
}

// TestTheWriterReportsTheAdapterCaughtUpAgain runs the behind-to-recovered transition, decided in run(). Recovery is
// measured against the count at the end of the previous drain pass, never the count when the behind period began, which
// only grows; a writer latched behind never announces the next real episode either.
func TestTheWriterReportsTheAdapterCaughtUpAgain(t *testing.T) {
	var logs safeBuffer
	log.SetOutput(&logs)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	nd := newGatedBridgeConn()
	nd.hold()
	var superseded uint64
	w := newAdapterWriter(nd, &superseded, nil)
	t.Cleanup(w.close)

	// Fall behind: one render starts a batch the writer blocks on, then enough superseded positions to pass
	// adapterBehindThreshold. A handful is a normal one-frame overrun and is not announced.
	w.enqueue(renderMsg("peer", 0))
	nd.waitEntered(t)
	for i := 1; i <= adapterBehindThreshold+1; i++ {
		w.enqueue(renderMsg("peer", float64(i)))
	}
	w.mu.Lock()
	behind := w.behind
	w.mu.Unlock()
	if !behind {
		t.Fatalf("the writer is not behind after %d superseded renders (threshold %d)",
			adapterBehindThreshold, adapterBehindThreshold)
	}
	if !strings.Contains(logs.String(), "not keeping up") {
		t.Fatalf("nothing said the adapter had fallen behind; log was:\n%s", logs.String())
	}

	// One drain pass carries the coalesced render away; the pass after finds nothing superseded while the last batch
	// was in flight, which is what caught up means.
	nd.allow()
	waitWriterIdle(t, w)
	w.enqueue(renderMsg("peer", 999))
	waitWriterIdle(t, w)

	deadline := time.Now().Add(testTimeout)
	for {
		w.mu.Lock()
		behind = w.behind
		w.mu.Unlock()
		if !behind {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the writer stayed latched behind after the adapter drained every batch -- " +
				"recovery is measured against the count at the end of the previous drain pass, " +
				"and against anything that only grows it can never become true")
		}
		time.Sleep(time.Millisecond)
	}
	if !strings.Contains(logs.String(), "keeping up again") {
		t.Fatalf("the recovery was never announced, so the log says the bridge is still shedding "+
			"load; log was:\n%s", logs.String())
	}
}

// waitWriterIdle blocks until this writer has nothing queued and nothing in flight. idle(), not queueLen(): run()
// clears the queue as it takes a batch and writes it several syscalls later.
func waitWriterIdle(t *testing.T, w *adapterWriter) {
	t.Helper()
	deadline := time.Now().Add(testTimeout)
	for !w.idle() {
		if time.Now().After(deadline) {
			t.Fatalf("the writer's queue never drained in %v", testTimeout)
		}
		time.Sleep(time.Millisecond)
	}
}

// safeBuffer is a bytes.Buffer the log package can write to from the writer goroutine while the test reads it; without
// the mutex -race would report the instrument, not the code.
type safeBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *safeBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *safeBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}
