package core

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// A full ring must cost about what a filling one does per add, as a ratio to the same ring's fill in the same run, so
// the algorithm separates the two costs, not the clock. The fill is the baseline: a coarse clock reads a few hundred
// adds as 0s.
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
	// append's next regrowth drops a reslice's dead prefix, so the array stays a small multiple of the live samples.
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
