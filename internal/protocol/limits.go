package protocol

import (
	"encoding/json"
	"math"
)

// State field limits, checked both where the relay accepts a State from a
// client and where a Core accepts one arriving from the relay — having them
// live here, rather than duplicated as relay.MaxPositionLen and a separate
// core-side magic number, means the two enforcement points can't silently
// drift apart. Originally relay-only, defending against a malformed or
// careless peer; the relay-safety hardening work added the core-side check
// too, since a hostile or compromised relay was previously trusted
// completely — see the ADR in agent_docs/architecture.md.
const (
	// MaxPositionLen bounds len(State.Position). Deliberately never fixed
	// at 2 or 3 components (agent_docs/contract.md), so this is headroom
	// above the largest known real use (3, for a 3D game) rather than a
	// length any adapter should approach.
	MaxPositionLen = 8

	// MaxExtrasBytes bounds the serialized size of State.Extras.
	MaxExtrasBytes = 1024

	// MaxOrientationBytes bounds the serialized size of State.Orientation
	// (raw JSON — scalar, vector, or quaternion depending on the adapter).
	// Generous above any real representation, which is a handful of floats.
	MaxOrientationBytes = 256

	// MaxAreaIDLen and MaxAnimLen bound the opaque AreaID/Anim strings.
	// Compared only by equality elsewhere (CLAUDE.md's opaque-field rule) —
	// bounding their length here is only about resource exhaustion, never
	// about interpreting their contents.
	MaxAreaIDLen = 256
	MaxAnimLen   = 256

	// MaxPositionComponent bounds the absolute value of each State.Position
	// component. Added after a refactor/review pass found that nothing
	// anywhere checked finiteness or magnitude: a peer can put
	// syntactically valid JSON like 1e308 on the wire, which survives
	// []float64 unmarshaling and becomes +Inf the moment any adapter
	// narrows it to float32 (both TEVI's Unity Transform and
	// Pseudoregalia's engine calls do). Every adapter's own local-position
	// values are small (tile/world units, nowhere near this), so this is
	// headroom, not a realistic in-game bound. See the ADR in
	// agent_docs/architecture.md. NaN/Inf are rejected outright regardless
	// of magnitude — see IsValidPosition.
	MaxPositionComponent = 1e7

	// MaxLineBytes bounds one NDJSON line (the whole Envelope, including
	// its payload). Shared with internal/transport (the actual enforcement
	// point, via NDJSONConn.MaxLineBytes / FromConnWithLimits) so the
	// relay's connections and the core's own relay connection can both use
	// the same tighter value — found in a review pass that only the
	// relay's *accepted* connections used this constant, while the core's
	// *dialed* relay connection kept transport's generous 64KiB package
	// default despite the core enforcing every per-field cap on receive.
	// Chosen generously above any legitimate state message (a handful of
	// floats plus short opaque strings comfortably fits in a few hundred
	// bytes) while still ruling out a peer trying to wedge an unbounded
	// payload through Extras.
	MaxLineBytes = 4096
)

// IsValidPosition reports whether every component of pos is finite (not
// NaN or ±Inf) and within ±MaxPositionComponent. Shared by internal/relay
// (accepting a State from a client) and internal/core (accepting one
// arriving from the relay) so both enforcement points use the identical
// check, the same reasoning as the shared limits above.
func IsValidPosition(pos []float64) bool {
	for _, v := range pos {
		if math.IsNaN(v) || math.IsInf(v, 0) || v > MaxPositionComponent || v < -MaxPositionComponent {
			return false
		}
	}
	return true
}

// ValidateState reports whether st passes every size/length/finiteness
// check in this file. Extracted from internal/relay and internal/core,
// which previously carried the identical five checks verbatim — the two
// enforcement points (the relay accepting a State from a client, the core
// accepting one arriving from the relay) can no longer silently drift
// apart, which is the same reason the individual limits above live here
// instead of duplicated as package-local constants.
func ValidateState(st State) bool {
	if len(st.Position) > MaxPositionLen {
		return false
	}
	if len(st.Extras) > 0 {
		extrasBytes, err := json.Marshal(st.Extras)
		if err != nil || len(extrasBytes) > MaxExtrasBytes {
			return false
		}
	}
	if len(st.AreaID) > MaxAreaIDLen || len(st.Anim) > MaxAnimLen ||
		len(st.Orientation) > MaxOrientationBytes {
		return false
	}
	// A syntactically valid JSON number like 1e308 survives []float64
	// unmarshaling and becomes +Inf the moment an adapter narrows it to
	// float32 — see IsValidPosition's doc comment.
	return IsValidPosition(st.Position)
}
