package core

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// A full ring must cost about what a filling one does per add. Before
// 2026-09-15 both rings copied every live sample down one slot on every add
// once the count bound bit -- 200,000 samples moved per sample -- which put
// the core package at Go's ten-minute limit under the race detector, and in a
// game is the whole buffer memmoved once per frame. The reslice fix is O(1).
//
// The comparison is a RATIO against the same machine's fill of the same ring,
// taken in the same run, so it holds on a slow runner too: the copy-down was
// three to four orders of magnitude worse, and a hundred is the line. The fill
// is the baseline rather than a handful of empty adds because a coarse clock
// (Windows ticks at about half a millisecond) reads a few hundred adds as 0s;
// 200,000 of them take tens of milliseconds on any machine. This is not a
// tolerance band on a timing assertion (testing.md, 2026-09-04): the two
// costs are separated by the algorithm, not by a clock reading.
const ringCostAdds = 5_000

func TestAFullStateRingCostsWhatAFillingOneDoesPerAdd(t *testing.T) {
	sample := func(i int) protocol.State {
		return protocol.State{PlayerID: "p", Timestamp: int64(i), Seq: uint64(i), Position: []float64{1, 2}}
	}
	r := &sampleRing{}
	r.setSpan(maxRingSpan)
	start := time.Now()
	for i := 0; i < maxRingSamples; i++ {
		r.add(sample(i))
	}
	perFillAdd := time.Since(start) / maxRingSamples

	start = time.Now()
	for i := maxRingSamples; i < maxRingSamples+ringCostAdds; i++ {
		r.add(sample(i))
	}
	perFullAdd := time.Since(start) / ringCostAdds
	t.Logf("state ring: %v per add filling, %v per add full", perFillAdd, perFullAdd)

	if perFullAdd > 100*perFillAdd {
		t.Fatalf("an add to a full ring costs %v, an add while filling %v -- the ring is moving its "+
			"live samples on every add again", perFullAdd, perFillAdd)
	}
	got := r.snapshot()
	if len(got) != maxRingSamples {
		t.Fatalf("the ring holds %d samples, want exactly its cap %d", len(got), maxRingSamples)
	}
	if newest := got[len(got)-1].Seq; newest != uint64(maxRingSamples+ringCostAdds-1) {
		t.Fatalf("newest held is seq %d, want %d -- the reslice took the wrong end", newest, maxRingSamples+ringCostAdds-1)
	}
	// The dead prefix a reslice leaves is reclaimed by append's next regrowth,
	// so the backing array stays within a small multiple of the live samples.
	if c := cap(r.buf); c > 2*maxRingSamples {
		t.Fatalf("the backing array has grown to %d slots for %d live samples -- the reslice is leaking its prefix", c, maxRingSamples)
	}
}

func TestAFullInputRingCostsWhatAFillingOneDoesPerAdd(t *testing.T) {
	var r inputRing
	r.setSpan(time.Hour)
	start := time.Now()
	for i := 0; i < maxInputRingEdges; i++ {
		r.add(inputEdgeLine{Ts: int64(i), F: uint64(i)})
	}
	perFillAdd := time.Since(start) / maxInputRingEdges

	start = time.Now()
	for i := maxInputRingEdges; i < maxInputRingEdges+ringCostAdds; i++ {
		r.add(inputEdgeLine{Ts: int64(i), F: uint64(i)})
	}
	perFullAdd := time.Since(start) / ringCostAdds
	t.Logf("input ring: %v per add filling, %v per add full", perFillAdd, perFullAdd)

	if perFullAdd > 100*perFillAdd {
		t.Fatalf("an add to a full input ring costs %v, an add while filling %v -- the ring is moving "+
			"its live edges on every add again", perFullAdd, perFillAdd)
	}
	got := r.snapshot()
	if len(got) != maxInputRingEdges {
		t.Fatalf("the ring holds %d edges, want exactly its cap %d", len(got), maxInputRingEdges)
	}
	if newest := got[len(got)-1].F; newest != uint64(maxInputRingEdges+ringCostAdds-1) {
		t.Fatalf("newest held is frame %d, want %d -- the reslice took the wrong end", newest, maxInputRingEdges+ringCostAdds-1)
	}
	if c := cap(r.buf); c > 2*maxInputRingEdges {
		t.Fatalf("the backing array has grown to %d slots for %d live edges -- the reslice is leaking its prefix", c, maxInputRingEdges)
	}
}
