package core

// Change suppression: an identical state is not worth a packet, and the
// resume after a silence must be indistinguishable from never having stopped.
//
// The last test in this file is the one that matters most. The others check
// that packets are saved; that one checks that saving them costs nothing on
// screen, which is the only reason this feature is allowed to exist
// (adapters/CLAUDE.md: never move a ghost slower than the game moves).

import (
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// capturingTransport keeps every state it was asked to send, in order, so a
// test can ask what a RECEIVER would have had to work with.
type capturingTransport struct {
	mu   sync.Mutex
	sent []protocol.State
}

func (ct *capturingTransport) Send(payload []byte) error {
	var env protocol.Envelope
	if err := json.Unmarshal(payload, &env); err == nil && env.Type == protocol.TypeState {
		var st protocol.State
		if err := json.Unmarshal(env.Payload, &st); err == nil {
			ct.mu.Lock()
			ct.sent = append(ct.sent, st)
			ct.mu.Unlock()
		}
	}
	return nil
}

func (ct *capturingTransport) SendUnreliable(payload []byte) error { return ct.Send(payload) }
func (ct *capturingTransport) OnReceive(func([]byte))              {}
func (ct *capturingTransport) OnDisconnect(func(error))            {}
func (ct *capturingTransport) OnError(func(error))                 {}
func (ct *capturingTransport) Close() error                        { return nil }

func (ct *capturingTransport) states() []protocol.State {
	ct.mu.Lock()
	defer ct.mu.Unlock()
	out := make([]protocol.State, len(ct.sent))
	copy(out, ct.sent)
	return out
}

// suppressionCore is a Core wired for these tests: a real relay transport
// stand-in, no rate limiting in the way (MinSendInterval is a separate
// mechanism with its own test), and a keepalive the test chooses.
func suppressionCore(t *testing.T, keepalive time.Duration) (*Core, *capturingTransport) {
	t.Helper()
	c := New()
	c.MinSendInterval = time.Nanosecond
	c.IdleKeepalive = keepalive
	ct := &capturingTransport{}
	c.relay = ct
	c.playerID = "p1"
	return c, ct
}

// frame drives one adapter frame. The sleep is load-bearing rather than
// decorative: MinSendInterval is a real mechanism and two forwardLocalState
// calls inside one clock tick are rate-limited, not suppressed -- on Windows
// the monotonic clock can return the same instant twice, so a tight loop with
// a nanosecond interval measures the rate limiter instead of this feature.
func frame(c *Core, st protocol.State) {
	time.Sleep(time.Millisecond)
	s := st
	c.forwardLocalState(&s)
}

func state(x, y float64, anim string) protocol.State {
	return protocol.State{AreaID: "a", Position: []float64{x, y}, Anim: anim}
}

func TestIdenticalStatesAreSentOnceUntilTheKeepalive(t *testing.T) {
	c, ct := suppressionCore(t, time.Hour) // no keepalive within the test
	st := state(1, 2, "idle")

	const frames = 60
	for i := 0; i < frames; i++ {
		frame(c, st)
	}

	if got := len(ct.states()); got != 1 {
		t.Fatalf("sent %d states for %d identical frames, want exactly 1", got, frames)
	}
	if got := c.Stats().StatesSuppressed; got != frames-1 {
		t.Fatalf("StatesSuppressed = %d, want %d", got, frames-1)
	}
}

func TestChangedStatesAreNeverSuppressed(t *testing.T) {
	c, ct := suppressionCore(t, time.Hour)

	const frames = 60
	for i := 0; i < frames; i++ {
		frame(c, state(float64(i), 2, "walk"))
	}

	// Every frame moved, so every frame is a send. No brackets: nothing was
	// ever skipped, so there is no silence to bracket.
	if got := len(ct.states()); got != frames {
		t.Fatalf("sent %d states for %d moving frames, want all of them", got, frames)
	}
	if got := c.Stats().BracketsSent; got != 0 {
		t.Fatalf("BracketsSent = %d, want 0 -- nothing was suppressed", got)
	}
}

// A field that is not the position still counts as a change. This is the
// core's whole-state comparison being honest about opaque fields: it does not
// know what `anim` or `extras` mean and must never decide one of them is
// unimportant.
func TestAnOpaqueFieldChangingCountsAsAChange(t *testing.T) {
	c, ct := suppressionCore(t, time.Hour)

	same := state(1, 2, "idle")
	frame(c, same)
	frame(c, same)

	withExtras := state(1, 2, "idle")
	withExtras.Extras = map[string]any{"vfx_seq": 3}
	frame(c, withExtras)

	got := ct.states()
	// first + the extras change + its bracket
	if len(got) != 3 {
		t.Fatalf("sent %d states, want 3 (first, bracket, changed)", len(got))
	}
	if got[2].Extras == nil {
		t.Fatal("the changed state did not carry the extras that made it a change")
	}
}

func TestKeepaliveRestatesAnUnchangedState(t *testing.T) {
	c, ct := suppressionCore(t, 20*time.Millisecond)
	st := state(1, 2, "idle")

	deadline := time.Now().Add(120 * time.Millisecond)
	for time.Now().Before(deadline) {
		frame(c, st)
	}

	got := len(ct.states())
	// ~120ms at a 20ms keepalive: the first send plus roughly five more.
	// Bounded loosely on both sides -- this is checking that the keepalive
	// exists and is not a full-rate stream, not timing precision.
	if got < 3 {
		t.Fatalf("sent %d states in 120ms at a 20ms keepalive, want at least 3 -- the keepalive is not firing", got)
	}
	if got > 20 {
		t.Fatalf("sent %d states, want far fewer -- suppression is not holding between keepalives", got)
	}
}

func TestZeroKeepaliveDisablesSuppressionEntirely(t *testing.T) {
	c, ct := suppressionCore(t, 0)
	st := state(1, 2, "idle")

	const frames = 40
	for i := 0; i < frames; i++ {
		frame(c, st)
	}

	if got := len(ct.states()); got != frames {
		t.Fatalf("sent %d states with suppression disabled, want all %d", got, frames)
	}
	if got := c.Stats().StatesSuppressed; got != 0 {
		t.Fatalf("StatesSuppressed = %d with suppression disabled, want 0", got)
	}
}

// THE ONE THAT MATTERS. Suppression is only acceptable if a receiver cannot
// tell it happened. Without the bracket re-statement, the receiver's buffer
// holds the standing sample and then the moving one with a long gap between
// them, and core/interp.go's lerp blends across that whole gap -- so the ghost
// creeps forward for the entire silence at a fraction of walking speed, which
// is precisely what adapters/CLAUDE.md forbids.
//
// This test reconstructs what the receiver would see: it feeds exactly what
// was sent into a real remoteBuffer and asks where the ghost renders midway
// through the silence.
func TestAResumeAfterSilenceDoesNotMakeAGhostCreep(t *testing.T) {
	c, ct := suppressionCore(t, time.Hour)

	standing := state(100, 0, "idle")
	frame(c, standing)

	// A long silence: many identical frames, none of them sent. Long enough
	// that a blend across it would be unmissable on screen.
	for i := 0; i < 150; i++ {
		frame(c, standing)
	}

	frame(c, state(108, 0, "walk"))

	sent := ct.states()
	if len(sent) != 3 {
		t.Fatalf("sent %d states, want 3 (the first, the bracket, the move) -- got %+v", len(sent), sent)
	}
	if sent[1].Position[0] != standing.Position[0] {
		t.Fatalf("the bracket carried position %v, want the standing position %v", sent[1].Position, standing.Position)
	}
	if sent[1].Timestamp >= sent[2].Timestamp {
		t.Fatalf("bracket timestamp %d is not before the moving state's %d", sent[1].Timestamp, sent[2].Timestamp)
	}

	var buf remoteBuffer
	for _, st := range sent {
		buf.add(st)
	}

	// Midway through the silence, the peer was standing perfectly still, so
	// the ghost must be exactly where it stood. Before the bracket existed,
	// this rendered partway to the new position.
	mid := (sent[0].Timestamp + sent[1].Timestamp) / 2
	at, ok := buf.at(mid)
	if !ok {
		t.Fatal("no state available midway through the silence")
	}
	if at.Position[0] != standing.Position[0] {
		t.Fatalf("ghost rendered at x=%v midway through a silence it spent standing at x=%v -- it is creeping across the gap",
			at.Position[0], standing.Position[0])
	}

	// And one millisecond before the move, still standing.
	at, ok = buf.at(sent[2].Timestamp - 1)
	if !ok {
		t.Fatal("no state available just before the move")
	}
	if at.Position[0] != standing.Position[0] {
		t.Fatalf("ghost rendered at x=%v one millisecond before the peer moved, want x=%v",
			at.Position[0], standing.Position[0])
	}
}
