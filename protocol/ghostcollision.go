package protocol

// Ghost collision is a room-wide policy the host sets, on whether a ghost may be physically present in a player's
// game. Not a boolean: "" means nothing was configured (or an older relay), a different fact from a chosen value.
// Advisory: the relay has no game knowledge and cannot tell whether an adapter honoured it.
const (
	// GhostCollisionEnabled leaves each adapter's own defaults standing, including where it already makes a ghost
	// passable. It does not force collision on: the relay does not know what collision means in any game.
	GhostCollisionEnabled = "enabled"

	// GhostCollisionDisabled is binding: no ghost blocks anything, at any time. An adapter that cannot honour it
	// says so in its own log rather than pretending.
	GhostCollisionDisabled = "disabled"
)

// NormalizeGhostCollision maps a configured or advertised value onto one of the two constants, or "" for absent.
// An unrecognized value normalizes to GhostCollisionDisabled: the setting exists so a host can take a physical
// effect away, so a typo must fail harmless rather than look applied and not be.
func NormalizeGhostCollision(s string) string {
	switch s {
	case "":
		return ""
	case GhostCollisionEnabled:
		return GhostCollisionEnabled
	default:
		return GhostCollisionDisabled
	}
}

// ResolveGhostCollision returns the policy a client applies, given what the relay advertised and what the client
// configured. The more restrictive wins, Welcome.SendHz's rule for a policy: a host can take collision away from a
// room and never force it onto a player. Absent on both sides resolves to GhostCollisionEnabled, each adapter's own
// default, so a client talking to an older relay behaves as before.
func ResolveGhostCollision(relay, client string) string {
	r, c := NormalizeGhostCollision(relay), NormalizeGhostCollision(client)
	if r == GhostCollisionDisabled || c == GhostCollisionDisabled {
		return GhostCollisionDisabled
	}
	return GhostCollisionEnabled
}
