package core

// A hostile local process against the bridge. A same-user attacker gains almost nothing new here (it can read
// config.json and run its own client); these matter for another local account, a sandboxed process or a web origin.

import (
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// bridgePipe runs handleBridgeConn over an in-memory pipe and returns the caller's end plus a channel closed when
// the core hangs up.
func bridgePipe(t *testing.T, c *Core) (net.Conn, <-chan struct{}) {
	t.Helper()
	server, client := net.Pipe()
	t.Cleanup(func() { server.Close(); client.Close() })
	go c.handleBridgeConn(server)

	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 256)
		for {
			// The deadline keeps a failing test from hanging the package.
			_ = client.SetReadDeadline(time.Now().Add(testTimeout))
			if _, err := client.Read(buf); err != nil {
				return
			}
		}
	}()
	return client, done
}

// bridgePipeReadable is bridgePipe for a test that reads the core's reply: bridgePipe's drain goroutine would consume
// those bytes.
func bridgePipeReadable(t *testing.T, c *Core) net.Conn {
	t.Helper()
	server, client := net.Pipe()
	t.Cleanup(func() { server.Close(); client.Close() })
	go c.handleBridgeConn(server)
	return client
}

// bridgeEnvelopeFor builds one bridge envelope with an arbitrary payload, independent of the Hello struct's fields.
func bridgeEnvelopeFor(t *testing.T, kind string, payload map[string]any) bridge.Envelope {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return bridge.Envelope{Type: bridge.MessageType(kind), Payload: b}
}

// TestTheStateRingIsBoundedByCountAndNotOnlyBySpan: a time-bounded buffer fed at an uncapped rate is unbounded, and
// the bridge does not rate-limit inbound frames.
func TestTheStateRingIsBoundedByCountAndNotOnlyBySpan(t *testing.T) {
	r := &sampleRing{}
	r.setSpan(maxRingSpan)

	// Every sample inside the span, so the span cutoff never fires.
	base := time.Now().UnixMilli()
	for i := 0; i < maxRingSamples+5_000; i++ {
		r.add(protocol.State{PlayerID: "p", Timestamp: base + int64(i%1000), Position: []float64{1, 2}})
	}

	held := len(r.snapshot())
	if held > maxRingSamples {
		t.Fatalf("the ring holds %d samples, %d past its cap -- span alone bounds nothing when the "+
			"rate is the sender's to choose", held, held-maxRingSamples)
	}
	if held == 0 {
		t.Fatal("the ring holds nothing at all: the count bound took the whole buffer rather than its oldest end")
	}
}

// TestTheStateRingDropsItsOldestWhenTheCountBounds: SaveLast writes the last of play, so the count bound must drop
// the oldest.
func TestTheStateRingDropsItsOldestWhenTheCountBounds(t *testing.T) {
	r := &sampleRing{}
	r.setSpan(maxRingSpan)
	base := time.Now().UnixMilli()
	for i := 0; i < maxRingSamples+10; i++ {
		r.add(protocol.State{PlayerID: "p", Timestamp: base, Seq: uint64(i), Position: []float64{1, 2}})
	}
	got := r.snapshot()
	if len(got) == 0 {
		t.Fatal("empty ring")
	}
	if newest := got[len(got)-1].Seq; newest != uint64(maxRingSamples+9) {
		t.Fatalf("the newest sample held is seq %d, want the last one added (%d) -- the count bound "+
			"is taking from the wrong end", newest, maxRingSamples+9)
	}
}

// TestTheStateRingIsDisarmedWhenTheAdapterGoes: an armed ring with no adapter would be fed by any bridge connection
// that sends, for the life of the process.
func TestTheStateRingIsDisarmedWhenTheAdapterGoes(t *testing.T) {
	c := New()
	c.SaveLastSpan = 30 * time.Second
	c.armRing()

	base := time.Now().UnixMilli()
	for i := 0; i < 10; i++ {
		c.ring.add(protocol.State{PlayerID: "p", Timestamp: base + int64(i), Position: []float64{1, 2}})
	}
	if len(c.ring.snapshot()) == 0 {
		t.Fatal("setup: the ring recorded nothing while armed")
	}

	c.finishBridgeTeardown(nil, true, false, nil)

	if held := len(c.ring.snapshot()); held != 0 {
		t.Errorf("the ring still holds %d sample(s) after the adapter went away", held)
	}
	// A freed buffer that refills is not disarmed, merely empty.
	c.ring.add(protocol.State{PlayerID: "p", Timestamp: base + 100, Position: []float64{1, 2}})
	if held := len(c.ring.snapshot()); held != 0 {
		t.Errorf("the ring accepted %d sample(s) with no adapter attached -- it is fed by any bridge "+
			"connection that sends, whether or not it ever became the adapter", held)
	}
}

// TestABridgeConnectionThatOpensWithSomethingElseIsHungUpOn: any web page can POST to the bridge port, and skipping
// unparseable lines would let its headers pass until the page-chosen body arrives as a line the bridge parses.
func TestABridgeConnectionThatOpensWithSomethingElseIsHungUpOn(t *testing.T) {
	c := New()
	client, done := bridgePipe(t, c)

	// What a cross-origin form POST puts on the wire first.
	if _, err := client.Write([]byte("POST / HTTP/1.1\r\n")); err != nil {
		t.Fatalf("write: %v", err)
	}

	select {
	case <-done:
	case <-time.After(testTimeout):
		t.Fatal("the bridge kept a connection that opened with an HTTP request line -- every header " +
			"is then skipped until the request body arrives as a line it parses")
	}
}

// TestABadLineMidSessionDoesNotDropAnAdapter: an adapter that has said hello keeps its connection through one bad
// line, which would otherwise cost the player their ghosts.
func TestABadLineMidSessionDoesNotDropAnAdapter(t *testing.T) {
	c := New()
	client, done := bridgePipe(t, c)

	hello, err := json.Marshal(bridgeEnvelopeFor(t, "hello", map[string]any{"game": "testgame"}))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Write(append(hello, '\n')); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	time.Sleep(100 * time.Millisecond)
	if _, err := client.Write([]byte("not json at all\n")); err != nil {
		t.Fatalf("write garbage: %v", err)
	}

	select {
	case <-done:
		t.Fatal("one unparseable line dropped an adapter that had already handshaked")
	case <-time.After(300 * time.Millisecond):
	}
}

// TestTheBridgeIgnoresAConnectionThatNeverSaidHello: before the game starts nothing holds the adapter slot, so a
// silent connection could otherwise send and receive as the player. A hostile process can still say hello; it
// cannot stay silent.
func TestTheBridgeIgnoresAConnectionThatNeverSaidHello(t *testing.T) {
	c := New()
	client, _ := bridgePipe(t, c)

	// local_state is what the relay receives under the player's identity.
	line, err := json.Marshal(bridgeEnvelopeFor(t, "local_state", map[string]any{
		"state": map[string]any{"area_id": "town", "position": []float64{1, 2}},
	}))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Write(append(line, '\n')); err != nil {
		t.Fatalf("write: %v", err)
	}
	time.Sleep(150 * time.Millisecond)

	// The render tick, not attachedAdapter: acting on a frame never set attachedAdapter, but it drives tickRenders.
	if ticks := c.ticksBegun(); ticks != 0 {
		t.Fatalf("a local_state from a connection that never sent a hello drove %d render tick(s) -- "+
			"that tick forwards the player's own state to the relay and hands back every peer's", ticks)
	}
	c.mu.Lock()
	attached := c.attachedAdapter
	c.mu.Unlock()
	if attached != nil {
		t.Fatal("a connection that never sent a hello took the adapter slot")
	}
}

// TestASecondHelloIsRefusedOutLoudRatherThanSilently: a squatter has to claim the slot, so the real game's hello is
// refused out loud instead of the takeover being invisible.
func TestASecondHelloIsRefusedOutLoudRatherThanSilently(t *testing.T) {
	c := New()
	first := bridgePipeReadable(t, c)
	hello, err := json.Marshal(bridgeEnvelopeFor(t, "hello", map[string]any{"game_id": "testgame"}))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := first.Write(append(hello, '\n')); err != nil {
		t.Fatalf("write first hello: %v", err)
	}
	time.Sleep(150 * time.Millisecond)

	c.mu.Lock()
	claimed := c.attachedAdapter != nil
	c.mu.Unlock()
	if !claimed {
		t.Fatal("the first hello did not claim the adapter slot")
	}

	second := bridgePipeReadable(t, c)
	if _, err := second.Write(append(hello, '\n')); err != nil {
		t.Fatalf("write second hello: %v", err)
	}
	_ = second.SetReadDeadline(time.Now().Add(testTimeout))
	buf := make([]byte, 512)
	n, err := second.Read(buf)
	if err != nil {
		t.Fatalf("the second hello got no answer at all: %v -- a refusal a player cannot see "+
			"is the thing this change exists to remove", err)
	}
	if !strings.Contains(string(buf[:n]), "busy") {
		t.Fatalf("the second hello was answered with %q, which does not say the core is busy", buf[:n])
	}
}
