package core

import (
	"math"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// Every way a batch can be out of bounds, and the sentence each is refused
// with. The reasons matter as much as the refusals: a batch dropped silently
// is what makes a missing track look like a broken adapter.
func TestInputSampleBounds(t *testing.T) {
	long := strings.Repeat("x", bridge.MaxInputLabelLen+1)
	tooMany := make([]bridge.InputEdge, bridge.MaxInputEdgesPerBatch+1)
	for i := range tooMany {
		tooMany[i] = bridge.InputEdge{F: uint64(i), T: int64(i)}
	}
	manyLabels := make([]string, bridge.MaxInputLabels+1)
	for i := range manyLabels {
		manyLabels[i] = "b"
	}

	for _, tc := range []struct {
		name   string
		sample bridge.InputSample
		want   string // a substring of the reason
	}{
		{"too many edges", bridge.InputSample{Edges: tooMany}, "over the"},
		{"empty and declaring nothing", bridge.InputSample{}, "empty batch"},
		{"too many labels", bridge.InputSample{Labels: manyLabels}, "over the"},
		{"over-long label", bridge.InputSample{Labels: []string{long}}, "label"},
		{"over-long axis name", bridge.InputSample{Axes: []string{long}}, "axis name"},
		{"over-long source", bridge.InputSample{Source: long, Labels: []string{"a"}}, "source"},
		{"invalid utf-8 label", bridge.InputSample{Labels: []string{"\xff\xfe"}}, "label"},
		{"negative t", bridge.InputSample{
			Edges: []bridge.InputEdge{{F: 1, T: -1}}}, "before the epoch"},
		{"t past the cap", bridge.InputSample{
			Edges: []bridge.InputEdge{{F: 1, T: int64(protocol.MaxTimestampMs) + 1}}}, "past the"},
		{"too many axes", bridge.InputSample{
			Edges: []bridge.InputEdge{{F: 1, T: 1, Ax: make([]float64, bridge.MaxInputAxes+1)}}}, "axes over"},
		{"NaN axis", bridge.InputSample{
			Edges: []bridge.InputEdge{{F: 1, T: 1, Ax: []float64{math.NaN()}}}}, "not finite"},
		{"Inf axis", bridge.InputSample{
			Edges: []bridge.InputEdge{{F: 1, T: 1, Ax: []float64{math.Inf(1)}}}}, "not finite"},
		{"huge axis", bridge.InputSample{
			Edges: []bridge.InputEdge{{F: 1, T: 1, Ax: []float64{1e300}}}}, "not finite"},
		{"frames go backwards", bridge.InputSample{
			Edges: []bridge.InputEdge{{F: 5, T: 1}, {F: 4, T: 2}}}, "goes backwards"},
		{"t goes backwards", bridge.InputSample{
			Edges: []bridge.InputEdge{{F: 1, T: 5}, {F: 2, T: 4}}}, "goes backwards"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if bridge.ValidateInputSample(tc.sample) {
				t.Fatal("accepted a batch that should be refused")
			}
			reason := bridge.InputSampleRejectReason(tc.sample)
			if reason == "" {
				t.Fatal("refused with no reason")
			}
			if !strings.Contains(reason, tc.want) {
				t.Errorf("reason %q, want it to mention %q", reason, tc.want)
			}
		})
	}
}

// A batch that declares only a label table is legal: it is how an adapter says
// what its bits mean before the player has touched anything.
func TestLabelOnlyBatchIsAccepted(t *testing.T) {
	s := bridge.InputSample{Labels: []string{"jump", "attack"}, Source: "pawn_properties"}
	if !bridge.ValidateInputSample(s) {
		t.Fatalf("refused a label-only batch: %s", bridge.InputSampleRejectReason(s))
	}
}

// A mask bit above the label table is LOGGED, never refused: the core is not
// the arbiter of what a game's label table has to contain.
func TestUnlabelledMaskBitIsNotARejection(t *testing.T) {
	s := bridge.InputSample{
		Labels: []string{"jump"},
		Edges:  []bridge.InputEdge{{F: 1, T: 1, M: 0xFF}},
	}
	if !bridge.ValidateInputSample(s) {
		t.Errorf("refused a mask with unnamed bits: %s", bridge.InputSampleRejectReason(s))
	}
}

// A batch that goes backwards against its PREDECESSOR is dropped whole rather
// than repaired -- ordering is the one property a reader may trust absolutely.
func TestBatchGoingBackwardsAcrossBatchesIsDropped(t *testing.T) {
	c := inputCore(t)
	path, err := c.StartInputRecording("")
	if err != nil {
		t.Fatalf("StartInputRecording: %v", err)
	}
	c.recordInput(batch(nil, [2]uint64{10, 1}, [2]uint64{11, 0}))
	c.recordInput(batch(nil, [2]uint64{5, 1})) // backwards: refused whole
	c.recordInput(batch(nil, [2]uint64{12, 1}))
	if _, _, err := c.StopInputRecording(); err != nil {
		t.Fatalf("StopInputRecording: %v", err)
	}
	track, err := loadInputTrack(path)
	if err != nil {
		t.Fatalf("loadInputTrack: %v", err)
	}
	if len(track.edges) != 3 {
		t.Fatalf("got %d edges, want 3 (the backwards batch dropped)", len(track.edges))
	}
	for i := 1; i < len(track.edges); i++ {
		if track.edges[i].F < track.edges[i-1].F {
			t.Errorf("edge %d goes backwards: frame %d after %d", i, track.edges[i].F, track.edges[i-1].F)
		}
	}
}

// The flood ceiling drops edges and NEVER detaches the adapter -- killing the
// game's connection for being loud is a worse outcome than losing the track.
func TestInputFloodDropsWithoutDetaching(t *testing.T) {
	c := inputCore(t)
	if _, err := c.StartInputRecording(""); err != nil {
		t.Fatalf("StartInputRecording: %v", err)
	}
	var frame uint64
	for b := 0; b < 200; b++ {
		s := bridge.InputSample{}
		for i := 0; i < bridge.MaxInputEdgesPerBatch; i++ {
			frame++
			s.Edges = append(s.Edges, bridge.InputEdge{F: frame, T: int64(frame), M: uint32(frame % 2)})
		}
		c.recordInput(s)
	}
	if !c.InputRecording() {
		t.Error("the flood stopped the recording; it should only drop edges")
	}
	c.inputMeta.mu.Lock()
	refusedOrReset := c.inputMeta.inWindow
	c.inputMeta.mu.Unlock()
	if refusedOrReset == 0 {
		t.Error("the limiter window never counted anything")
	}
	path, written, err := c.StopInputRecording()
	if err != nil {
		t.Fatalf("StopInputRecording: %v", err)
	}
	// 200 * 64 = 12800 edges offered in one window; the ceiling is 1000/s.
	if written >= 12800 {
		t.Errorf("wrote %d edges to %s -- the flood ceiling did nothing", written, path)
	}
}

// The ring is bounded by COUNT as well as by span: a time-bounded buffer fed at
// an uncapped rate is an unbounded buffer (review G8's lesson).
func TestInputRingIsBoundedByCountNotOnlySpan(t *testing.T) {
	var r inputRing
	r.setSpan(time.Hour) // a span far too long to ever trim
	for i := 0; i < maxInputRingEdges+5_000; i++ {
		r.add(inputEdgeLine{Ts: int64(i), F: uint64(i)})
	}
	if n := len(r.snapshot()); n > maxInputRingEdges {
		t.Errorf("the ring holds %d edges, over the %d ceiling", n, maxInputRingEdges)
	}
}

// The ring span is clamped to maxRingSpan, like the state ring's.
func TestInputRingSpanIsClamped(t *testing.T) {
	var r inputRing
	r.setSpan(6 * time.Hour)
	r.mu.Lock()
	span := r.span
	r.mu.Unlock()
	if span != maxRingSpan.Milliseconds() {
		t.Errorf("span %dms, want it clamped to %v", span, maxRingSpan)
	}
}
