package core

import (
	"bufio"
	"encoding/json"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// TestASlowAdapterIsNeverDetached: an adapter that reads steadily but slower than the core writes is healthy and
// having a hard time, so the core sends it less, never times it out and drops the pack it built up.
func TestASlowAdapterIsNeverDetached(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk
	c.InterpolationDelay = 0
	c.LocalInterpolationDelay = 0
	// Short, so the test takes a second; the drain-to-generate ratio is what reproduces the defect.
	c.bridgeWriteTimeout = 2 * time.Second
	c.ChaserEnabled = true
	c.ChaserCount = 128
	c.ChaserDelay = time.Millisecond
	c.ChaserSpacing = 0
	c.ChaserSpawnDelay = time.Millisecond

	rt := &recordingTransport{}
	c.mu.Lock()
	c.relay = rt
	c.playerID = "self"
	c.relayGame = "emerald"
	c.mu.Unlock()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen bridge: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go c.ServeBridge(ln)

	raw, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatalf("dial adapter: %v", err)
	}
	t.Cleanup(func() { raw.Close() })

	// A raw reader, not fakeAdapter: closing the socket while far behind truncates a line, which fakeAdapter reports
	// from its read loop after the test returns, and the testing package panics.
	//
	// 4 KB per 2 ms is a generous adapter and still an order of magnitude under what 128 chasers produce.
	slow := newThrottledConn(raw, 4<<10, 2*time.Millisecond)
	// An atomic: a size-1 channel with a non-blocking send keeps the first unconsumed value, not the newest.
	var got atomic.Int64
	first := make(chan struct{})
	go func() {
		sc := bufio.NewScanner(slow)
		sc.Buffer(make([]byte, 4096), transport.DefaultMaxLineBytes)
		var once sync.Once
		for sc.Scan() {
			got.Add(1)
			once.Do(func() { close(first) })
		}
	}()

	hello, _ := json.Marshal(bridge.Envelope{Type: bridge.TypeHello, Payload: json.RawMessage(`{"game_id":"emerald"}`)})
	if _, err := raw.Write(append(hello, '\n')); err != nil {
		t.Fatalf("hello: %v", err)
	}
	select {
	case <-first:
	case <-time.After(testTimeout):
		t.Fatal("the core never answered the hello")
	}

	// The player moves, so the whole pack is admitted and every tick writes to the slow socket.
	deadline := time.Now().Add(3 * time.Second)
	for i := 0; time.Now().Before(deadline); i++ {
		clk.Advance(5 * time.Millisecond)
		st := protocol.State{AreaID: "a", Position: []float64{float64(i), 0}, Anim: "run"}
		payload, _ := json.Marshal(bridge.LocalState{State: &st})
		env, _ := json.Marshal(bridge.Envelope{Type: bridge.TypeLocalState, Payload: payload})
		if _, err := raw.Write(append(env, '\n')); err != nil {
			t.Fatalf("frame %d: the core closed the bridge on a slow adapter: %v", i, err)
		}
		time.Sleep(time.Millisecond)
	}

	if n := got.Load(); n < 2 {
		t.Fatalf("the slow adapter took %d line(s) in 3s -- the core stopped writing, which passes "+
			"the attachment check below while being just as broken", n)
	} else {
		t.Logf("the slow adapter took %d line(s)", n)
	}

	c.mu.Lock()
	nd := c.attachedAdapter
	c.mu.Unlock()
	if nd == nil {
		t.Fatal("the core detached a slow-but-alive adapter -- a healthy adapter having a hard time " +
			"must be sent less, never disconnected")
	}

	dropped, stalls := c.writerFor(nd).stats()

	// Quiesce before the deferred Close, or an in-flight write is truncated after the test has finished.
	c.StopChasers()
	time.Sleep(100 * time.Millisecond)

	if dropped == 0 {
		t.Fatal("no render was ever superseded -- the adapter kept up, so this run did not " +
			"exercise coalescing at all and the invariant above is untested")
	}
	t.Logf("survived with %d superseded render(s) across %d drain pass(es)", dropped, stalls)
}

// TestBridgeWritersDoNotOutliveTheirConnections: every adapterWriter runs a goroutine, so one left per attach would
// leak it and its queue for the life of the process.
func TestBridgeWritersDoNotOutliveTheirConnections(t *testing.T) {
	c := New()
	rt := &recordingTransport{}
	c.mu.Lock()
	c.relay = rt
	c.playerID = "self"
	c.relayGame = "emerald"
	c.mu.Unlock()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen bridge: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go c.ServeBridge(ln)

	for i := 0; i < 5; i++ {
		fa := reattachFakeAdapterWith(t, "emerald", func() *fakeAdapter {
			return dialFakeAdapter(t, ln.Addr().String())
		})
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{float64(i), 0}})
		fa.conn.Close()
	}

	deadline := time.Now().Add(testTimeout)
	for {
		c.writerMu.Lock()
		n := len(c.writers)
		c.writerMu.Unlock()
		if n == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%d bridge writer(s) still registered after every connection closed", n)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestTheSlowAdapterIsReportedOnceEachWay: shedding load is logged once when it starts, not per superseded render,
// which at 512 ghosts would make the logging the bottleneck. The recovery is decided in run(), so
// TestTheWriterReportsTheAdapterCaughtUpAgain covers it.
func TestTheSlowAdapterIsReportedOnceEachWay(t *testing.T) {
	// No writer goroutine: it would drain the queue and leave no depth to assert.
	var superseded uint64
	w := &adapterWriter{
		superseded: &superseded,
		pending:    make(map[string]int),
		wake:       make(chan struct{}, 1),
	}

	render := func(id string, x float64) queuedMsg {
		env, _ := marshalBridge(bridge.TypeRenderRemote, bridge.RenderRemote{
			PlayerID: id, State: protocol.State{Position: []float64{x, 0}},
		})
		return queuedMsg{env: env, renderOf: id}
	}

	for _, id := range []string{"chaser:1", "chaser:2"} {
		if !w.enqueue(render(id, 0)) {
			t.Fatalf("%s: first render refused", id)
		}
	}
	if got := atomic.LoadUint64(&superseded); got != 0 {
		t.Fatalf("%d superseded after one render each -- the first for a peer has nothing to replace", got)
	}
	// Below the threshold first: a handful of superseded positions is a normal one-frame overrun, not announced.
	for i := 1; i <= 50; i++ {
		w.enqueue(render("chaser:1", float64(i)))
	}
	if got := atomic.LoadUint64(&superseded); got != 50 {
		t.Fatalf("superseded = %d after 50 replacements, want 50", got)
	}
	w.mu.Lock()
	quietlyBehind := w.behind
	w.mu.Unlock()
	if quietlyBehind {
		t.Fatalf("the writer announced the adapter was behind after only 50 superseded renders "+
			"(threshold %d) -- that is a one-frame overrun and logging it flaps", adapterBehindThreshold)
	}
	for i := 0; i < adapterBehindThreshold; i++ {
		w.enqueue(render("chaser:1", float64(i)))
	}

	w.mu.Lock()
	depth := len(w.q)
	behind := w.behind
	w.mu.Unlock()
	if depth != 2 {
		t.Fatalf("queue holds %d entries after 52 renders for 2 peers, want 2 -- "+
			"coalescing is what bounds this, and without it the queue grows without limit", depth)
	}
	if !behind {
		t.Fatal("the writer does not consider the adapter behind after 50 superseded renders")
	}

	last := render("chaser:1", float64(adapterBehindThreshold-1))
	if string(w.q[0].env) != string(last.env) {
		t.Fatal("the queued render for chaser:1 is not the newest one -- coalescing kept a stale position")
	}
}
