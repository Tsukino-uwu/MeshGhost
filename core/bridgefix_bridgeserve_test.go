package core

// Two defects found by the 2026-09-07 adversarial review, both on the path
// between a render tick and the adapter's socket, and both invisible to the
// tests that were already here:
//
//   - c.writers grew by one permanent entry per game relaunch that landed in a
//     particular window (E12);
//   - a marshal bug in this process was reported and handled as a dead adapter
//     socket, tearing down the whole session (E13).
//
// Each test below fails on the code as it stood on 2026-09-08.

import (
	"encoding/json"
	"errors"
	"math"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// TestAWriterIsNotCreatedForAConnectionAlreadyGone pins E12.
//
// THE INTERLEAVING, which no existing test reaches. Every sendToAdapter caller
// reads c.attachedAdapter under c.mu and releases the lock BEFORE sending --
// deliberately, so that a wedged adapter socket cannot stall the relay side.
// So: a nametag push takes nd; the read loop ends and bridgeConnGone runs
// dropWriter, removing that connection's entry; the push then reaches
// writerFor, which used to register a brand-new writer -- a goroutine and a
// queue -- for a connection nothing would ever remove again. The map key is the
// dead NDJSONConn itself, so the entry pinned it and its buffers for the life
// of the process, one per relaunch that hit the window.
//
// TestBridgeWritersDoNotOutliveTheirConnections asserts the same invariant but
// closes each connection cleanly and then waits, so the late send never
// happens and the race is never exercised. This test performs the send AFTER
// the teardown, which is the whole defect.
func TestAWriterIsNotCreatedForAConnectionAlreadyGone(t *testing.T) {
	c := New()

	ours, theirs := net.Pipe()
	t.Cleanup(func() { ours.Close(); theirs.Close() })
	nd := transport.FromConn(ours)

	// The adapter's socket goes, and the read loop's cleanup runs -- exactly
	// what bridgeConnGone does for a game that was closed.
	if err := nd.Close(); err != nil {
		t.Fatalf("closing the bridge connection: %v", err)
	}
	c.bridgeConnGone(nd)

	// And now the straggler: a goroutine that read nd before all of that and
	// only reaches the send now.
	err := c.sendToAdapter(nd, bridge.TypeRemoteName, bridge.RemoteName{
		PlayerID: "p2", DisplayName: "late",
	})
	c.writerMu.Lock()
	n := len(c.writers)
	c.writerMu.Unlock()
	if n != 0 {
		t.Fatalf("%d bridge writer(s) registered for a connection that was already gone -- one per relaunch, never removed", n)
	}

	if !errors.Is(err, errBridgeGone) {
		t.Fatalf("a send on a connection that is already gone returned %v, want errBridgeGone", err)
	}
}

// TestAMarshalBugDropsOneMessageAndKeepsTheSession pins E13.
//
// A non-finite float in one peer's extras is the reachable trigger:
// encoding/json refuses NaN, so marshalBridge fails, and sendToAdapter returns
// errBridgeMarshal -- "a bug in this process, never a peer's doing", as its own
// declaration says. onAdapterFrame discriminated neither error, so that one
// message tore down the relay session, the chasers, the replays and the
// recording, and logged "the adapter's socket is dead" about a socket nothing
// had touched.
//
// The healthy peer in the same frame is the second half of the assertion: the
// tick must not stop at the bad one either.
func TestAMarshalBugDropsOneMessageAndKeepsTheSession(t *testing.T) {
	c := New()
	c.LocalInterpolationDelay = 0
	nd := &countingBridgeConn{}

	c.mu.Lock()
	c.attachedAdapter = nd
	c.adapterReady = true
	now := c.nowMsLocked()
	// Local-peer ids (a chaser pack): exempt from the wall-clock age-out, so
	// the frame below renders them whatever the machine's timing.
	for _, id := range []string{"chaser:bad", "chaser:good"} {
		b := &remoteBuffer{}
		for _, age := range []int64{50, 10} {
			st := protocol.State{
				PlayerID:  id,
				Timestamp: now - age,
				AreaID:    "a",
				Position:  []float64{1, 2},
			}
			if id == "chaser:bad" {
				// json.Marshal refuses this, and there is no way for the core
				// to know that before it tries.
				st.Extras = map[string]any{"anim_t": math.NaN()}
			}
			b.add(st)
		}
		c.remotes[id] = b
	}
	c.mu.Unlock()

	c.onAdapterFrame(bridge.LocalState{State: &protocol.State{
		AreaID: "a", Position: []float64{0, 0}, Timestamp: now,
	}}, nd, make(map[string]bool))

	c.mu.Lock()
	stillAttached := c.attachedAdapter == nd
	c.mu.Unlock()
	if !stillAttached {
		t.Fatal("a payload that failed to marshal detached the adapter -- the session was torn down for a bug in this process")
	}
	if nd.closes() != 0 {
		t.Fatalf("the adapter's socket was closed %d time(s) over a marshal failure", nd.closes())
	}

	// The healthy peer's render still has to arrive: the marshal failure is
	// per-message, so it may not latch the tick the way a gone connection does.
	deadline := time.Now().Add(testTimeout)
	for {
		if id, ok := nd.firstRenderedPlayer(t); ok {
			if id != "chaser:good" {
				t.Fatalf("rendered %q, want the healthy peer chaser:good", id)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the healthy peer in the same frame was never rendered -- the marshal failure stopped the whole tick")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// TestAGoneConnectionStillDetachesTheAdapter is the other side of the same
// discrimination: errBridgeGone must keep doing exactly what it did before,
// because that is the 2026-09-06 lockout fix (a game reconnecting within
// 150 ms and being refused "busy" by a core whose adapter socket was dead).
func TestAGoneConnectionStillDetachesTheAdapter(t *testing.T) {
	c := New()
	c.LocalInterpolationDelay = 0
	nd := &countingBridgeConn{}
	nd.markClosed()

	c.mu.Lock()
	c.attachedAdapter = nd
	c.adapterReady = true
	now := c.nowMsLocked()
	b := &remoteBuffer{}
	for _, age := range []int64{50, 10} {
		b.add(protocol.State{PlayerID: "chaser:good", Timestamp: now - age, AreaID: "a", Position: []float64{1, 2}})
	}
	c.remotes["chaser:good"] = b
	c.mu.Unlock()

	c.onAdapterFrame(bridge.LocalState{State: &protocol.State{
		AreaID: "a", Position: []float64{0, 0}, Timestamp: now,
	}}, nd, make(map[string]bool))

	c.mu.Lock()
	attached := c.attachedAdapter
	c.mu.Unlock()
	if attached != nil {
		t.Fatal("a send on a gone connection left the adapter attached -- a reconnecting game would be refused busy")
	}
}

// countingBridgeConn is a bridge-side transport that records what was written
// and can report itself closed, which is what writerFor now asks before it
// registers a writer.
type countingBridgeConn struct {
	mu     sync.Mutex
	sent   [][]byte
	closed bool
	closeN int
}

func (t *countingBridgeConn) Send(payload []byte) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	cp := make([]byte, len(payload))
	copy(cp, payload)
	t.sent = append(t.sent, cp)
	return nil
}
func (t *countingBridgeConn) SendUnreliable(payload []byte) error { return t.Send(payload) }
func (t *countingBridgeConn) OnReceive(func([]byte))              {}
func (t *countingBridgeConn) OnDisconnect(func(error))            {}
func (t *countingBridgeConn) OnError(func(error))                 {}
func (t *countingBridgeConn) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.closed = true
	t.closeN++
	return nil
}

// IsClosed is the optional capability transportIsClosed looks for.
func (t *countingBridgeConn) IsClosed() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.closed
}

func (t *countingBridgeConn) markClosed() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.closed = true
}

func (t *countingBridgeConn) closes() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.closeN
}

// firstRenderedPlayer reports the player id of the first render_remote written,
// if one has been written yet.
func (t *countingBridgeConn) firstRenderedPlayer(tb testing.TB) (string, bool) {
	tb.Helper()
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, line := range t.sent {
		var env bridge.Envelope
		if err := json.Unmarshal(line, &env); err != nil {
			tb.Fatalf("the bridge wrote a line that is not an envelope: %v", err)
		}
		if env.Type != bridge.TypeRenderRemote {
			continue
		}
		var rr bridge.RenderRemote
		if err := json.Unmarshal(env.Payload, &rr); err != nil {
			tb.Fatalf("render_remote payload: %v", err)
		}
		return rr.PlayerID, true
	}
	return "", false
}
