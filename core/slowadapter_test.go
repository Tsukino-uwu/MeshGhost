package core

// THE ~350-GHOST CEILING, headless.
//
// A tester's 512-chaser pack broke twice in the same place: at 343 ghosts on
// 2026-09-06 and ~350 on 2026-09-07. The core writes one render_remote line
// per remote per adapter frame, unthrottled -- 380 bytes each, so 512 ghosts
// at Pseudoregalia's ~180Hz is 92,160 messages and 35 MB/s down one loopback
// NDJSON socket. The adapter cannot parse that, the socket's buffer fills, the
// write deadline expires mid-line, and the core tears the session down.
//
// Neither of the two adapters this package had could produce it: a fake
// adapter reads as fast as Go can and never falls behind, and the one in
// bridge_deadadapter_test.go stops reading outright, which is a DEAD adapter
// rather than a slow one. The difference matters, because the fix for a dead
// adapter is to let it reconnect (which shipped, and worked) while the fix for
// a slow one is not to kill it at all.
//
// throttledConn is the missing dial. This is the tester's session at a scale a
// test can run.

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

// TestASlowAdapterIsNeverDetached is the invariant the user asked for
// (2026-09-07): "I never want the server/client to be the limiting factor for
// anything ... if you set 512, you should be able to eventually reach there if
// the game itself don't crash".
//
// An adapter that reads STEADILY but slower than the core writes is a healthy
// adapter having a hard time, and the only correct response is to send it less
// -- never to time out, close the socket and drop the pack it had built up.
func TestASlowAdapterIsNeverDetached(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk
	c.InterpolationDelay = 0
	c.LocalInterpolationDelay = 0
	// Short, so the test takes a second rather than ten. The ratio is what
	// reproduces the defect, not the absolute figures: the adapter below
	// drains far less than the pack generates, exactly as a real one does at
	// 350 ghosts.
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

	// A RAW READER, not the shared fakeAdapter, and deliberately. This test
	// ends with the adapter still far behind, so closing the socket always
	// truncates a line in flight -- which fakeAdapter reports with t.Errorf
	// from its read loop, after the test has returned, and the testing package
	// turns that into a panic. The truncation is teardown, not the defect, and
	// this test does not care what the bytes say: only that they keep coming
	// and the core never hangs up.
	//
	// 4 KB per 2 ms is a generous adapter and still an order of magnitude
	// under what 128 chasers at this frame rate produce.
	slow := newThrottledConn(raw, 4<<10, 2*time.Millisecond)
	// An ATOMIC, not a buffered channel. A size-1 channel with a non-blocking
	// send keeps the FIRST unconsumed value, not the newest, so it reported
	// "2 lines" however many thousands actually arrived -- a number that looks
	// like a finding and is an artefact of the instrument. (CLAUDE.md: a
	// diagnostic can break the thing it measures.)
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

	// Frames for a couple of seconds of wall time, with the player moving so
	// the whole pack is admitted and every tick writes to that slow socket.
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

	// The adapter must still be receiving: a core that quietly stopped writing
	// would pass the attachment check below while being just as broken.
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

	// AND THE MECHANISM DID IT, not a test that turned out to be easy. If
	// nothing was ever superseded then the adapter kept up and this proved
	// nothing about coalescing; the whole point is that the core generated far
	// more renders than the socket could carry and dropped the stale ones.
	dropped, stalls := c.writerFor(nd).stats()

	// Quiesce before the deferred Close: the pack is still generating renders,
	// and closing the socket underneath an in-flight write truncates a line
	// that the adapter's read loop then reports AFTER this test has finished,
	// which the testing package turns into a panic rather than a failure.
	// That is teardown noise, not the defect under test.
	c.StopChasers()
	time.Sleep(100 * time.Millisecond)

	if dropped == 0 {
		t.Fatal("no render was ever superseded -- the adapter kept up, so this run did not " +
			"exercise coalescing at all and the invariant above is untested")
	}
	t.Logf("survived with %d superseded render(s) across %d drain pass(es)", dropped, stalls)
}

// TestBridgeWritersDoNotOutliveTheirConnections: every adapterWriter runs a
// goroutine, so one left behind per attach would leak a goroutine and its
// queue for the life of the process -- and a game that relaunches attaches
// again every time. The map must be empty once the connections are gone.
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

// TestTheSlowAdapterIsReportedOnceEachWay: the user asked for both a log line
// when the bridge starts shedding load and one when it stops, and the running
// count in stats (2026-09-07). One line each way is the whole point -- a line
// per superseded render would be tens of thousands a second at 512 ghosts and
// the logging would become the bottleneck it is reporting on.
func TestTheSlowAdapterIsReportedOnceEachWay(t *testing.T) {
	// The struct directly, with NO writer goroutine: this exercises the
	// enqueue side alone, which is where coalescing, the counter and the
	// behind-transition live. Starting a real writer would drain the queue
	// and there would be nothing left to assert about its depth.
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

	// First render for each peer queues; every one after that supersedes.
	for _, id := range []string{"chaser:1", "chaser:2"} {
		if !w.enqueue(render(id, 0)) {
			t.Fatalf("%s: first render refused", id)
		}
	}
	if got := atomic.LoadUint64(&superseded); got != 0 {
		t.Fatalf("%d superseded after one render each -- the first for a peer has nothing to replace", got)
	}
	// BELOW THE THRESHOLD FIRST: a handful of superseded positions is a normal
	// one-frame overrun and must NOT be announced. The user's first live run
	// logged 31 behind/recovered pairs in four minutes, 23 of them for a single
	// superseded position, which is the noise this guards against.
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
	// Now past it.
	for i := 0; i < adapterBehindThreshold; i++ {
		w.enqueue(render("chaser:1", float64(i)))
	}

	// THE QUEUE DID NOT GROW: that is the property the whole design rests on.
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

	// And the newest position is the one that survived, not the oldest.
	last := render("chaser:1", float64(adapterBehindThreshold-1))
	if string(w.q[0].env) != string(last.env) {
		t.Fatal("the queued render for chaser:1 is not the newest one -- coalescing kept a stale position")
	}
}
