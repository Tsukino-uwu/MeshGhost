package core

// Section F of the 2026-09-12 adversarial review: a hostile LOCAL process
// against the bridge.
//
// The P4a agent's own calibration, which this file keeps because it decides how
// much any of it is worth: against a same-user attacker the loopback + no-auth
// design grants almost nothing new -- that actor can read config.json, kill the
// core and run their own client. What is below is real for ANOTHER local
// account, a sandboxed process, or a web origin, and no further.
//
// Not covered here, deliberately: the adapter slot being claimable without a
// hello (P4a-2/-4/-6, and the connect-before-the-game hole core/bridgeserve.go
// already flags in its own comment). Every candidate fix there changes the
// adapter contract and the autostart flow, so it wants an ADR and the user's
// call rather than a test asserting whichever way somebody guessed.

import (
	"encoding/json"
	"net"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// bridgePipe runs handleBridgeConn over an in-memory pipe and hands back the
// caller's end plus a channel closed when the core hangs up. No socket, so
// nothing here depends on a port being free or on loopback policy.
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
			// The core closing its end is what ends this read. A deadline keeps
			// a test that is going to fail from hanging the package instead.
			_ = client.SetReadDeadline(time.Now().Add(testTimeout))
			if _, err := client.Read(buf); err != nil {
				return
			}
		}
	}()
	return client, done
}

// bridgeEnvelopeFor builds one bridge envelope with an arbitrary payload, so a
// test can send a hello without depending on the Hello struct's field set.
func bridgeEnvelopeFor(t *testing.T, kind string, payload map[string]any) bridge.Envelope {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return bridge.Envelope{Type: bridge.MessageType(kind), Payload: b}
}

// P4a-1, the half that is a bound. maxInputRingEdges -- the same bound on the
// ring beside this one -- says the lesson and names THIS buffer as the one that
// only got half of it: a time-bounded buffer fed at an uncapped rate is an
// unbounded buffer. The bridge applies no rate limit to inbound frames.
func TestTheStateRingIsBoundedByCountAndNotOnlyBySpan(t *testing.T) {
	r := &sampleRing{}
	r.setSpan(maxRingSpan)

	// Every sample inside the span, so the span cutoff never fires: this is
	// exactly the case the span bound cannot see.
	base := time.Now().UnixMilli()
	for i := 0; i < maxRingSamples+5_000; i++ {
		r.add(protocol.State{PlayerID: "p", Timestamp: base + int64(i%1000), Position: []float64{1, 2}})
	}

	held := len(r.snapshot())
	// Before the fix: 205,000, and it keeps going for as long as the sender does.
	if held > maxRingSamples {
		t.Fatalf("the ring holds %d samples, %d past its cap -- span alone bounds nothing when the "+
			"rate is the sender's to choose", held, held-maxRingSamples)
	}
	if held == 0 {
		t.Fatal("the ring holds nothing at all: the count bound took the whole buffer rather than its oldest end")
	}
}

// And the ring keeps its NEWEST samples, because "the last N of play" is what
// SaveLast writes -- a count bound that dropped the newest would quietly turn
// save-last into save-first.
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

// P4a-1, the half that is a teardown. The input ring is disarmed when the
// adapter goes; the state ring beside it was not, so it stayed armed -- and fed
// by any bridge connection that sends -- for the life of the core process.
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
	// Still armed is the part that matters: a freed buffer that refills is not
	// disarmed, it is merely empty.
	c.ring.add(protocol.State{PlayerID: "p", Timestamp: base + 100, Position: []float64{1, 2}})
	if held := len(c.ring.snapshot()); held != 0 {
		t.Errorf("the ring accepted %d sample(s) with no adapter attached -- it is fed by any bridge "+
			"connection that sends, whether or not it ever became the adapter", held)
	}
}

// P4a-3. A browser on any page can POST to 127.0.0.1:7778 without reading the
// reply. Ignoring an unparseable line and keeping the connection is what lets
// the request's headers be skipped until its BODY -- which the page chooses --
// arrives as a line this bridge does parse.
func TestABridgeConnectionThatOpensWithSomethingElseIsHungUpOn(t *testing.T) {
	c := New()
	client, done := bridgePipe(t, c)

	// Exactly what a cross-origin form POST puts on the wire first.
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

// The converse, so the rule is "not NDJSON" and not "anything unexpected": an
// adapter that has proved it speaks the protocol keeps its connection through a
// bad line, because dropping it would cost the player their ghosts over one
// bad frame.
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
	// Give the hello time to be read before the garbage follows it.
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
