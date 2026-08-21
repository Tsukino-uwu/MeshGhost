package core

// The stats counters are a diagnostic, and a diagnostic that is quietly wrong
// is worse than none — someone sizes a bandwidth decision with it. These pin
// the arithmetic and the two rules that are easy to get backwards: an unknown
// local area filters nothing, and Stats must never change behaviour.

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func TestStatsCountCrossAreaDiscardsAtRenderTime(t *testing.T) {
	c := New()
	c.roster = map[string]struct{}{"near": {}, "far": {}}
	c.localAreaID = "town"

	now := time.Now().UnixMilli()
	c.storeRemoteState(protocol.State{PlayerID: "near", AreaID: "town", Timestamp: now, Position: []float64{1, 2}})
	c.storeRemoteState(protocol.State{PlayerID: "far", AreaID: "cave", Timestamp: now, Position: []float64{3, 4}})

	// Render-set build is where the discard happens.
	got := c.remoteStatesAt(now)
	if len(got) != 1 {
		t.Fatalf("rendered %d remotes, want 1 — only the same-area peer", len(got))
	}
	if _, ok := got["near"]; !ok {
		t.Fatal("the same-area peer was not in the render set")
	}

	s := c.Stats()
	if s.StatesReceived != 2 {
		t.Errorf("StatesReceived = %d, want 2", s.StatesReceived)
	}
	if s.StatesFilteredByArea != 1 {
		t.Errorf("StatesFilteredByArea = %d, want 1", s.StatesFilteredByArea)
	}
	if share := s.CrossAreaShare(); share < 0.49 || share > 0.51 {
		t.Errorf("CrossAreaShare = %.2f, want ~0.50", share)
	}
	if s.PeersKnown != 2 {
		t.Errorf("PeersKnown = %d, want 2", s.PeersKnown)
	}
}

// An unknown local area filters nothing — the core's own rule, unchanged since it was written.
// The counter must agree with it, or it would report a saving that no filter
// could actually take.
func TestStatsCountNothingCrossAreaWhenLocalAreaUnknown(t *testing.T) {
	c := New()
	c.roster = map[string]struct{}{"far": {}}
	c.localAreaID = "" // no adapter frame yet

	now := time.Now().UnixMilli()
	c.storeRemoteState(protocol.State{PlayerID: "far", AreaID: "cave", Timestamp: now, Position: []float64{3, 4}})
	if len(c.remoteStatesAt(now)) != 1 {
		t.Fatal("an unknown local area must filter nothing")
	}
	if s := c.Stats(); s.StatesFilteredByArea != 0 {
		t.Fatalf("counted %d cross-area discards with an unknown local area", s.StatesFilteredByArea)
	}
}

// Zero traffic must read as zero, not as a divide-by-zero or a fabricated
// rate. A stats line printed one second after startup is the common case.
func TestStatsOnAFreshCoreAreEmptyNotNonsense(t *testing.T) {
	s := New().Stats()
	if s.CrossAreaShare() != 0 {
		t.Errorf("CrossAreaShare = %v on a fresh core, want 0", s.CrossAreaShare())
	}
	if s.Connected {
		t.Error("a fresh core reports itself connected")
	}
	if got := s.String(); got == "" {
		t.Error("String() produced nothing")
	}
}
