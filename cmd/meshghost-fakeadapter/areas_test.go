package main

import "testing"

// -areas exists so this rig can build the one room SHAPE that relay-side area
// filtering is for: peers spread across areas rather than all in one. A
// single-area room is that filter's worst case and saves nothing by
// construction, so without this flag a before/after measurement of it could
// only ever report "no change" (agent_docs/plans.md's scaling-shape argument).
//
// The default is the part worth pinning hardest. Every launcher in dev-scripts
// and every crowd number in agent_docs/crowd-limits.md was recorded before this
// flag existed, so -areas 1 must reproduce the old behaviour EXACTLY -- if it
// did not, this flag would silently invalidate a set of measurements nobody
// would think to re-take.
func TestPeerAreaIDDefaultIsUnchangedBehaviour(t *testing.T) {
	for _, areas := range []int{0, 1} {
		for i := 0; i < 5; i++ {
			if got := peerAreaID("fake-arena", i, areas); got != "fake-arena" {
				t.Fatalf("peerAreaID(base, %d, %d) = %q, want the base unchanged", i, areas, got)
			}
		}
	}
}

func TestPeerAreaIDSpreadsAndRepeats(t *testing.T) {
	// Round-robin, so a count that is not a multiple of the area count still
	// fills every area rather than leaving the last one short by design.
	want := []string{"a-0", "a-1", "a-2", "a-0", "a-1", "a-2", "a-0"}
	for i, w := range want {
		if got := peerAreaID("a", i, 3); got != w {
			t.Fatalf("peerAreaID(a, %d, 3) = %q, want %q", i, got, w)
		}
	}
}

// The suffix keeps the operator's own base in it rather than replacing it, so a
// run stays traceable to the game it was imitating and two rigs pointed at one
// relay cannot collide on a bare index.
func TestPeerAreaIDKeepsTheBase(t *testing.T) {
	got := peerAreaID("map:1:2", 1, 4)
	if got != "map:1:2-1" {
		t.Fatalf("peerAreaID kept no trace of the base: %q", got)
	}
}
