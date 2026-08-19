package protocol

// Ghost collision is a room-wide policy the host sets and every client in the
// room is told about, on whether a ghost may be physically present in a
// player's own game -- solid, shoving, standing on a tile. See the ADR in
// agent_docs/architecture.md.
//
// It is deliberately NOT a boolean. "" means "nothing was configured / an
// older relay advertised nothing", which is a different fact from "the host
// chose enabled", and the two must stay distinguishable for the same reason
// Welcome.SendHz's zero does: a client has to be able to tell an unset value
// from a chosen one before deciding what to fall back to.
//
// The policy is ADVISORY. The relay has no game knowledge and cannot tell
// whether an adapter honored it -- exactly like SendHz. Shipped adapters
// honor it; nothing makes them, and the host-facing docs say so rather than
// implying enforcement.
const (
	// GhostCollisionEnabled leaves each adapter's OWN defaults standing,
	// including the places an adapter already makes a ghost passable
	// (Crystal's idle/pushed-into rules, say). It does not mean "force
	// collision on": the relay does not know what collision means in any
	// game and is in no position to demand it.
	GhostCollisionEnabled = "enabled"

	// GhostCollisionDisabled is binding: no ghost blocks anything, in any
	// game, at any time. An adapter that cannot honor this says so in its
	// own log rather than pretending -- see ResolveGhostCollision.
	GhostCollisionDisabled = "disabled"
)

// NormalizeGhostCollision maps a configured or advertised value onto one of
// the two constants above, or "" for absent.
//
// An UNRECOGNIZED value normalizes to GhostCollisionDisabled, not to enabled
// and not to "". That asymmetry is deliberate and is the one interesting
// decision here: this setting exists so a host can take a physical effect
// AWAY, so the failure mode of a typo must be the harmless one. A typo that
// silently left ghosts solid would be a setting that looks applied and isn't
// -- the same class of bug as the UTF-16 config file in packaging/README.md,
// where the dangerous case was a room_code that appeared set and was not.
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

// ResolveGhostCollision returns the policy a client should actually apply,
// given what the relay advertised and what this client configured for itself.
//
// The MORE RESTRICTIVE of the two wins. This is Welcome.SendHz's rule applied
// to a policy rather than a rate: there, the relay's value is prescriptive
// for a client that expressed no preference, but a client that deliberately
// chose a slower rate keeps it, and the slower of the two wins. Here a host
// can take collision away from a room, and can never force it onto a player
// who does not want it -- the host owns the room's rules, a player owns their
// own comfort.
//
// Absent on both sides resolves to GhostCollisionEnabled, which is the
// pre-existing behavior: every shipped adapter's own default, unchanged. That
// is what keeps this feature invisible to anyone who never sets it, and what
// makes a new client talking to an OLD relay (which advertises nothing) behave
// exactly as it did before the field existed.
func ResolveGhostCollision(relay, client string) string {
	r, c := NormalizeGhostCollision(relay), NormalizeGhostCollision(client)
	if r == GhostCollisionDisabled || c == GhostCollisionDisabled {
		return GhostCollisionDisabled
	}
	return GhostCollisionEnabled
}
