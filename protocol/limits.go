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
	// its payload). Shared with transport (the actual enforcement
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

	// DefaultSendHz is the room-wide state send rate a relay advertises in
	// Welcome.SendHz when its operator hasn't configured one, and the rate a
	// client falls back to when the relay advertises nothing at all (an
	// older relay). 20Hz, not the brief's original 10Hz hypothesis: 20Hz is
	// the rate live-confirmed across all three shipped games as
	// core.DefaultMinSendInterval (agent_docs/contract.md's Limits
	// section), and this constant exists to keep the two provably equal
	// rather than as a fresh claim about the "right" rate.
	DefaultSendHz = 20

	// MinSendHz / MaxSendHz bound both server.send_hz (a relay's configured
	// room rate) and client.max_receive_hz_per_player (a client's own
	// per-peer receive cap) — see the ADR in agent_docs/architecture.md for
	// the send/receive rate-control feature. The floor is the brief's
	// original 10Hz hypothesis, kept as a smoothness floor: the lower the
	// rate, the closer the gap between samples gets to core's interpolation
	// delay (core.DefaultInterpolationDelay, 250ms — the two are equal at
	// 4Hz), and once the gap reaches it core/interp.go's remoteBuffer.at()
	// falls back to an edge snapshot instead of smoothing — which degrades
	// in a way that looks like a bug, not a setting someone chose. The ceiling is a bandwidth bound, not a technical one: a
	// room's traffic grows with send_hz times the square of its size (see
	// relay.DefaultMaxClients), so 100Hz in a full 8-seat room is
	// already thousands of messages/second through the relay. MaxSendHz also
	// bounds what a hostile relay can talk a client into sending, which is
	// why these live here rather than in relay/limits.go — both
	// sides enforce them, same reasoning as MaxPositionComponent above.
	MinSendHz = 10
	MaxSendHz = 100
)

// IsValidPosition reports whether every component of pos is finite (not
// NaN or ±Inf) and within ±MaxPositionComponent. Shared by relay
// (accepting a State from a client) and core (accepting one
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

// ClampSendHz resolves a configured or advertised send/receive rate to a
// usable one: zero or negative means "unspecified, use DefaultSendHz" (the
// same zero-means-default convention as relay.Server.MaxClients and
// core.Core.DialTimeout), and anything outside [MinSendHz,
// MaxSendHz] is clamped rather than refused — clamping, not refusing: a
// relay must not fail to start over a typo in a cosmetic tuning knob, and a
// client must not drop a working relay connection because that relay
// advertised a number this build doesn't like. Shared by relay (its
// own server.send_hz config) and core (a possibly-hostile relay's
// Welcome.SendHz, and its own client.max_receive_hz_per_player config) so
// the two enforcement points can't drift apart — same reasoning as
// ValidateState above. Callers that want to warn when a value they read from
// config or the wire wasn't already in range compare their input against
// this function's return value themselves; this function only resolves,
// it never logs. For client.max_receive_hz_per_player / Hello.MaxReceiveHz,
// where zero means "uncapped" rather than "use the default rate", use
// ClampReceiveHz instead.
func ClampSendHz(hz int) int {
	if hz <= 0 {
		return DefaultSendHz
	}
	if hz < MinSendHz {
		return MinSendHz
	}
	if hz > MaxSendHz {
		return MaxSendHz
	}
	return hz
}

// ClampReceiveHz resolves a configured or advertised per-peer receive cap
// (client.max_receive_hz_per_player / protocol.Hello.MaxReceiveHz) to a
// usable one. Unlike ClampSendHz, zero or negative here means "uncapped" —
// there is no sensible default cap, only "off" — so it stays 0 rather than
// resolving to DefaultSendHz. A positive value outside [MinSendHz,
// MaxSendHz] is still clamped rather than refused, same reasoning as
// ClampSendHz.
func ClampReceiveHz(hz int) int {
	if hz <= 0 {
		return 0
	}
	if hz < MinSendHz {
		return MinSendHz
	}
	if hz > MaxSendHz {
		return MaxSendHz
	}
	return hz
}

// ValidateState reports whether st passes every size/length/finiteness
// check in this file. Extracted from relay and core,
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
	// AreaID and Anim get the same UTF-8 requirement as the identifiers on
	// the other planes (ValidOpaqueString), and for the identical reason: the
	// core is permitted to compare them by equality and nothing else, and a
	// string that is not valid UTF-8 comes back from a JSON round trip as a
	// different string. A wire-decoded state is already valid UTF-8, so this
	// changes nothing for any shipped adapter — all three speak JSON over the
	// bridge. It guards an in-process Go caller, where the failure would
	// otherwise be a ghost whose area_id silently stops matching its peer's
	// and which therefore never renders, with nothing reporting why.
	if !ValidOpaqueString(st.AreaID, MaxAreaIDLen) || !ValidOpaqueString(st.Anim, MaxAnimLen) ||
		len(st.Orientation) > MaxOrientationBytes {
		return false
	}
	// A syntactically valid JSON number like 1e308 survives []float64
	// unmarshaling and becomes +Inf the moment an adapter narrows it to
	// float32 — see IsValidPosition's doc comment.
	return IsValidPosition(st.Position)
}
