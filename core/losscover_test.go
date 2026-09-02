package core

// Loss cover (ADR 0045): a state carries the sample before it, so a single
// lost packet costs a receiver nothing. Watched on Crystal 2026-09-02 through
// meshghost-netsim at 2% loss: the lost packet that mattered was the LAST one
// of a walk, which change suppression gives no successor until the keepalive,
// so the ghost walked on and then teleported. The last test here is that case.

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// coverCore is suppressionCore with the cover forced ON regardless of the
// effective send interval (a test cannot wait 40ms per frame), or OFF.
func coverCore(t *testing.T, on bool) (*Core, *capturingTransport) {
	t.Helper()
	c, ct := suppressionCore(t, time.Hour)
	if on {
		c.RedundancyMinInterval = time.Nanosecond
	} else {
		c.RedundancyMinInterval = -1
	}
	return c, ct
}

func TestEverySentStateCarriesItsPredecessor(t *testing.T) {
	c, ct := coverCore(t, true)
	for i := 0; i < 4; i++ {
		frame(c, state(float64(i), 0, "walk"))
	}
	got := ct.states()
	if len(got) != 4 {
		t.Fatalf("sent %d, want 4", len(got))
	}
	if got[0].Prev != nil {
		t.Fatal("the very first state has no predecessor and must not carry one")
	}
	for i := 1; i < 4; i++ {
		p := got[i].Prev
		if p == nil {
			t.Fatalf("state %d carries no prev", i)
		}
		if p.Seq != got[i-1].Seq || p.Timestamp != got[i-1].Timestamp {
			t.Fatalf("state %d's prev is seq %d/ts %d, want the state before it (seq %d/ts %d)",
				i, p.Seq, p.Timestamp, got[i-1].Seq, got[i-1].Timestamp)
		}
		if len(p.Position) != 2 || p.Position[0] != float64(i-1) {
			t.Fatalf("state %d's prev position = %v, want [%d 0]", i, p.Position, i-1)
		}
	}
	if s := c.Stats(); s.PrevCarried != 3 {
		t.Fatalf("PrevCarried = %d, want 3", s.PrevCarried)
	}
}

func TestTheCoverIsGatedOnTheSendInterval(t *testing.T) {
	// Off below the gate: a fast room pays nothing.
	c, ct := coverCore(t, false)
	frame(c, state(0, 0, "walk"))
	frame(c, state(1, 0, "walk"))
	for i, st := range ct.states() {
		if st.Prev != nil {
			t.Fatalf("state %d carries a prev with the cover off", i)
		}
	}
	// The default gate against a real interval: 15Hz carries, 100Hz does not.
	d := New()
	if !d.redundancyOnLocked(time.Second/15) || d.redundancyOnLocked(time.Second/100) {
		t.Fatal("default gate: want on at 15Hz and off at 100Hz")
	}
}

func TestTheBracketCarriesThePreSilenceStateAndIsCarriedByTheResume(t *testing.T) {
	c, ct := coverCore(t, true)
	idle := state(1, 1, "idle")
	frame(c, idle)
	frame(c, idle) // suppressed
	frame(c, state(2, 1, "walk"))
	got := ct.states()
	if len(got) != 3 {
		t.Fatalf("sent %d, want 3 (first, bracket, resume)", len(got))
	}
	bracket, resume := got[1], got[2]
	if bracket.Prev == nil || bracket.Prev.Seq != got[0].Seq {
		t.Fatal("the bracket does not carry the first state")
	}
	if resume.Prev == nil || resume.Prev.Seq != bracket.Seq {
		t.Fatal("the resume does not carry the bracket, which was the packet sent right before it")
	}
}

// receiverWith returns a Core that knows peer "p2" and has received the given
// states in order; the returned buffer is p2's.
func receiverWith(t *testing.T, states ...protocol.State) (*Core, *remoteBuffer) {
	t.Helper()
	c := New()
	c.playerID = "p1"
	c.roster["p2"] = struct{}{}
	for _, st := range states {
		c.storeRemoteState(st)
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c, c.remotes["p2"]
}

func lcSample(seq uint64, ts int64, x float64) protocol.State {
	return protocol.State{PlayerID: "p2", Seq: seq, Timestamp: ts, AreaID: "a",
		Position: []float64{x, 0}, Anim: "walk"}
}

func withPrev(cur, prev protocol.State) protocol.State {
	cur.Prev = protocol.BuildPrev(&prev, &cur)
	return cur
}

func TestALostMiddleSampleIsRecoveredFromTheNextPacket(t *testing.T) {
	s1, s2, s3 := lcSample(1, 1000, 0), lcSample(2, 1067, 1), lcSample(3, 1133, 2)
	// s2 is lost; s3 arrives carrying it.
	c, b := receiverWith(t, s1, withPrev(s3, s2))
	if len(b.snapshots) != 3 {
		t.Fatalf("buffer holds %d samples, want 3 (the lost one recovered)", len(b.snapshots))
	}
	if b.snapshots[1].Seq != 2 || b.snapshots[1].Timestamp != 1067 || b.snapshots[1].Position[0] != 1 {
		t.Fatalf("recovered sample wrong: %+v", b.snapshots[1])
	}
	for i, s := range b.snapshots {
		if s.Prev != nil {
			t.Fatalf("snapshot %d stored with a prev attached; the buffer holds samples, not packets", i)
		}
	}
	if st := c.Stats(); st.PrevRecovered != 1 {
		t.Fatalf("PrevRecovered = %d, want 1", st.PrevRecovered)
	}
}

func TestACarriedSampleAlreadySeenIsNotDuplicated(t *testing.T) {
	s1, s2 := lcSample(1, 1000, 0), lcSample(2, 1067, 1)
	c, b := receiverWith(t, s1, withPrev(s2, s1))
	if len(b.snapshots) != 2 {
		t.Fatalf("buffer holds %d samples, want 2 -- s1 arrived and must not be inserted twice", len(b.snapshots))
	}
	if st := c.Stats(); st.PrevRecovered != 0 {
		t.Fatalf("PrevRecovered = %d on a clean link, want 0", st.PrevRecovered)
	}
}

// The case that was watched: the last sample of a walk is lost. Without the
// cover the receiver's newest sample is one step short until the keepalive
// re-states the stop, and the ghost renders there and then jumps. With it, the
// keepalive (a bracket-free repeat of the same state) carries the lost stop as
// its prev, so the receiver holds the true final position with its true
// timestamp and interpolates onto it.
func TestTheLostLastSampleOfAWalkArrivesWithTheKeepalive(t *testing.T) {
	walk1, walk2 := lcSample(1, 1000, 0), lcSample(2, 1067, 1)
	stop := lcSample(3, 1133, 2) // lost
	keepalive := lcSample(4, 1383, 2)
	_, b := receiverWith(t, walk1, withPrev(walk2, walk1), withPrev(keepalive, stop))
	if len(b.snapshots) != 4 {
		t.Fatalf("buffer holds %d samples, want 4", len(b.snapshots))
	}
	got, ok := b.at(1140) // a render time just after the true stop
	if !ok {
		t.Fatal("no sample")
	}
	if got.Position[0] != 2 {
		t.Fatalf("at the stop time the ghost is at x=%v, want 2 (the recovered stop)", got.Position[0])
	}
	// And the ordering invariant held: the recovered sample sits between the
	// walk and the keepalive by timestamp, not at the end where it arrived.
	if b.snapshots[2].Seq != 3 || b.snapshots[3].Seq != 4 {
		t.Fatalf("recovered sample out of order: seqs %d,%d,%d,%d",
			b.snapshots[0].Seq, b.snapshots[1].Seq, b.snapshots[2].Seq, b.snapshots[3].Seq)
	}
}
