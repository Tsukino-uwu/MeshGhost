package protocol_test

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func TestNormalizeGhostCollisionFailsSafe(t *testing.T) {
	for _, tc := range []struct {
		in, want string
	}{
		{"", ""},
		{protocol.GhostCollisionEnabled, protocol.GhostCollisionEnabled},
		{protocol.GhostCollisionDisabled, protocol.GhostCollisionDisabled},
		{"Enabled", protocol.GhostCollisionDisabled},  // case matters
		{"enabled ", protocol.GhostCollisionDisabled}, // stray whitespace
		{"off", protocol.GhostCollisionDisabled},
		{"true", protocol.GhostCollisionDisabled},
		{"nonsense", protocol.GhostCollisionDisabled},
	} {
		if got := protocol.NormalizeGhostCollision(tc.in); got != tc.want {
			t.Errorf("NormalizeGhostCollision(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// TestResolveGhostCollisionMoreRestrictiveWins spells out every combination, since a symmetric implementation would
// pass a sampled test.
func TestResolveGhostCollisionMoreRestrictiveWins(t *testing.T) {
	const (
		on  = protocol.GhostCollisionEnabled
		off = protocol.GhostCollisionDisabled
	)
	for _, tc := range []struct {
		name          string
		relay, client string
		want          string
	}{
		{"nobody configured anything is the pre-existing behaviour", "", "", on},
		{"old relay advertises nothing, client is content", "", on, on},
		{"old relay advertises nothing, client opts out", "", off, off},
		{"host enables, client silent", on, "", on},
		{"host enables, client agrees", on, on, on},
		{"host enables, client still opts out for itself", on, off, off},
		{"host disables, client silent", off, "", off},
		{"host disables, client cannot opt back in", off, on, off},
		{"host disables, client agrees", off, off, off},
		{"garbage from a hostile relay cannot enable anything", "garbage", on, off},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := protocol.ResolveGhostCollision(tc.relay, tc.client); got != tc.want {
				t.Errorf("ResolveGhostCollision(relay=%q, client=%q) = %q, want %q",
					tc.relay, tc.client, got, tc.want)
			}
		})
	}
}

// TestResolveGhostCollisionNeverReturnsEmpty: an adapter is told a real policy, so it never carries a default of its
// own.
func TestResolveGhostCollisionNeverReturnsEmpty(t *testing.T) {
	for _, relay := range []string{"", "enabled", "disabled", "junk"} {
		for _, client := range []string{"", "enabled", "disabled", "junk"} {
			if got := protocol.ResolveGhostCollision(relay, client); got == "" {
				t.Errorf("ResolveGhostCollision(%q, %q) returned empty", relay, client)
			}
		}
	}
}
