package core

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

// TestAWriterIsNotCreatedForAConnectionAlreadyGone: sendToAdapter callers release c.mu before sending, so a send can
// reach writerFor after bridgeConnGone dropped that connection's writer, and must not register a new one for it.
func TestAWriterIsNotCreatedForAConnectionAlreadyGone(t *testing.T) {
	c := New()

	ours, theirs := net.Pipe()
	t.Cleanup(func() { ours.Close(); theirs.Close() })
	nd := transport.FromConn(ours)

	if err := nd.Close(); err != nil {
		t.Fatalf("closing the bridge connection: %v", err)
	}
	c.bridgeConnGone(nd)

	// A goroutine that read nd before the teardown reaches the send only now.
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

// TestAMarshalBugDropsOneMessageAndKeepsTheSession: errBridgeMarshal (here a NaN in one peer's extras) drops that one
// message; the adapter stays attached and the healthy peer in the same frame still renders.
func TestAMarshalBugDropsOneMessageAndKeepsTheSession(t *testing.T) {
	c := New()
	c.LocalInterpolationDelay = 0
	nd := &countingBridgeConn{}

	c.mu.Lock()
	c.attachedAdapter = nd
	c.adapterReady = true
	now := c.nowMsLocked()
	// Local-peer ids are exempt from the wall-clock age-out, so they render whatever the machine's timing.
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

	// A marshal failure is per message, so it must not latch the tick the way a gone connection does.
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

// TestAGoneConnectionStillDetachesTheAdapter: errBridgeGone still detaches, or a game reconnecting at once is refused
// "busy" by a core whose adapter socket is dead.
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

// countingBridgeConn is a bridge-side transport that records what was written and can report itself closed, which
// writerFor asks before it registers a writer.
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
