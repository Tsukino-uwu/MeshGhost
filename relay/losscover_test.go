package relay

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The carried prev rides through forwardState intact and is never stored: a late joiner is seeded with the newest
// sample only.
func TestForwardStateKeepsTheCarriedPrevAndDoesNotRecordIt(t *testing.T) {
	r := benchRoom(2)
	prev := emeraldState()
	prev.Seq, prev.Timestamp = 1, 1000
	cur := emeraldState()
	cur.Seq, cur.Timestamp = 2, 1067
	cur.Position = []float64{cur.Position[0] + 1, cur.Position[1]}
	cur.Prev = protocol.BuildPrev(&prev, &cur)

	got, ok := r.forwardState("p0", mustPayload(t, cur))
	if !ok {
		t.Fatal("state with a prev was dropped")
	}
	if got.Prev == nil || got.Prev.Seq != 1 || len(got.Prev.Position) != 2 {
		t.Fatalf("the forwarded state lost its prev: %+v", got.Prev)
	}
	r.mu.Lock()
	remembered := r.lastState["p0"]
	r.mu.Unlock()
	if remembered.Prev != nil {
		t.Fatal("the relay remembered the prev; a late joiner must get only the newest sample")
	}
	if remembered.Seq != 2 {
		t.Fatalf("remembered seq %d, want 2", remembered.Seq)
	}
}

// A prev is checked by the same validator as its state, so the cover is no way past ValidateState.
func TestAStateWithAnInvalidPrevIsDroppedAtTheRelay(t *testing.T) {
	r := benchRoom(2)
	st := emeraldState()
	st.Prev = &protocol.StatePrev{Position: []float64{1e308}}
	if _, ok := r.forwardState("p0", mustPayload(t, st)); ok {
		t.Fatal("a state whose prev carries a non-finite position was forwarded")
	}
}
