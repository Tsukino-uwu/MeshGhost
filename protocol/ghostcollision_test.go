package protocol_test

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// A typo must fail SAFE. The whole point of the setting is letting a host
// take a physical effect away, so an unrecognized value resolving to
// "enabled" would be a setting that looks applied and isn't -- the same class
// of bug as the UTF-16 config file that silently discarded a room_code.
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

// The rule the whole feature rests on: a host can take collision AWAY, and can
// never force it ON. Every combination is spelled out rather than sampled,
// because the asymmetry is the design and a symmetric implementation would
// pass a looser test.
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

// Resolve never returns "": an adapter is told a real policy or nothing at
// all, so it never has to carry a default of its own.
func TestResolveGhostCollisionNeverReturnsEmpty(t *testing.T) {
	for _, relay := range []string{"", "enabled", "disabled", "junk"} {
		for _, client := range []string{"", "enabled", "disabled", "junk"} {
			if got := protocol.ResolveGhostCollision(relay, client); got == "" {
				t.Errorf("ResolveGhostCollision(%q, %q) returned empty", relay, client)
			}
		}
	}
}
