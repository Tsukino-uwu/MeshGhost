package main

import "testing"

// TestPeerAreaIDDefaultIsUnchangedBehaviour: -areas 0 and 1 keep every peer in the base area, so numbers measured
// before the flag existed stay comparable.
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
	want := []string{"a-0", "a-1", "a-2", "a-0", "a-1", "a-2", "a-0"}
	for i, w := range want {
		if got := peerAreaID("a", i, 3); got != w {
			t.Fatalf("peerAreaID(a, %d, 3) = %q, want %q", i, got, w)
		}
	}
}

// TestPeerAreaIDKeepsTheBase: the base stays in the area id, so a run stays traceable to the game it imitates and two
// rigs on one relay cannot collide on a bare index.
func TestPeerAreaIDKeepsTheBase(t *testing.T) {
	got := peerAreaID("map:1:2", 1, 4)
	if got != "map:1:2-1" {
		t.Fatalf("peerAreaID kept no trace of the base: %q", got)
	}
}
