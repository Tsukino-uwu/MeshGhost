package protocol

import (
	"bytes"
	"encoding/json"
	"math"
	"sync"
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
	// the rate live-confirmed as core.DefaultMinSendInterval across the
	// three games shipping at the time -- Emerald, TEVI and Pseudoregalia;
	// Crystal came later (2026-08-18) and is the fourth
	// (agent_docs/contract.md's Limits section). This constant exists to
	// keep the two provably equal rather than as a fresh claim about the
	// "right" rate.
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
		JSONWireLen(st.Orientation) > MaxOrientationBytes {
		return false
	}
	// A syntactically valid JSON number like 1e308 survives []float64
	// unmarshaling and becomes +Inf the moment an adapter narrows it to
	// float32 — see IsValidPosition's doc comment.
	if !IsValidPosition(st.Position) {
		return false
	}
	// Last on purpose, because it is the only check here that has to SERIALIZE
	// anything: measured 2026-08-28 at 1399ns and 30 of the 115 allocations a
	// relay spends on one Emerald state, against 13ns for every other check in
	// this function put together. Nothing observes WHICH check rejected a state
	// — both call sites drop it either way — so ordering the cheap ones first
	// is invisible for an accepted state and pure profit for a rejected one.
	return extrasWithinLimit(st.Extras)
}

// extrasSizer is a buffer and encoder kept together so the pool hands out one
// warm pair rather than two cold halves.
type extrasSizer struct {
	buf bytes.Buffer
	enc *json.Encoder
}

var extrasSizers = sync.Pool{
	New: func() any {
		s := &extrasSizer{}
		s.enc = json.NewEncoder(&s.buf)
		// Explicit rather than relying on the default, because this must agree
		// with json.Marshal EXACTLY: it is measuring the bytes Marshal would
		// produce, and a disagreement moves a validation boundary rather than
		// merely reporting a different number. A state the relay accepts and
		// the core rejects is precisely the drift this file exists to prevent.
		s.enc.SetEscapeHTML(true)
		return s
	},
}

// maxPooledSizerCap stops one adversarially large in-process Extras from
// parking a big buffer in the pool forever. The wire can never deliver one —
// MaxLineBytes bounds it long before here — but ValidateState is also called
// by in-process Go callers, where nothing has clipped the input yet.
const maxPooledSizerCap = 8 * MaxExtrasBytes

// extrasWithinLimit reports whether extras serializes to at most
// MaxExtrasBytes, WITHOUT allocating the serialized form. It replaced a plain
// json.Marshal whose only use was len() on the result — the same encoder, so
// the byte count is identical by construction rather than by estimate. A
// hand-written size walker would be faster still and is deliberately not used:
// matching encoding/json's float formatting exactly is a real hazard, and being
// wrong here moves a limit rather than costing time.
func extrasWithinLimit(extras map[string]any) bool {
	if len(extras) == 0 {
		return true
	}
	// The cheap path, which every shipped adapter takes: bound the length from
	// above without encoding anything. If even the worst case fits, the exact
	// length cannot possibly exceed the limit and there is nothing to compute.
	//
	// This is safe in a way an exact hand-written sizer is not, and that is the
	// whole reason it is shaped as a bound: it can only ever accept early,
	// never reject early, so any state it is unsure about — and every state
	// near the boundary — still goes through encoding/json itself. No bound,
	// however wrong, can move the limit; a wrong exact sizer would.
	if n, ok := extrasLengthBound(extras); ok && n <= MaxExtrasBytes {
		return true
	}
	s := extrasSizers.Get().(*extrasSizer)
	defer func() {
		if s.buf.Cap() <= maxPooledSizerCap {
			extrasSizers.Put(s)
		}
	}()
	s.buf.Reset()
	if err := s.enc.Encode(extras); err != nil {
		return false
	}
	// Encode terminates its value with a newline that Marshal does not write,
	// so the marshaled length is one less. Pinned by test against Marshal
	// itself rather than trusted from the doc comment.
	return s.buf.Len()-1 <= MaxExtrasBytes
}

// JSONWireLen reports how many bytes a raw JSON value occupies once it is
// actually written to the wire, which is NOT len(raw): encoding/json escapes
// '<', '>' and '&' as \u003c/\u003e/\u0026 (six bytes each), and U+2028/U+2029
// as \u2028/\u2029, wherever they appear. A blob of 128 '&' characters is 130
// bytes in hand and 774 on the wire.
//
// Every blob/payload bound in this package exists to keep a message inside a
// transport's budget — MaxWorldBlobBytes is derived from udpconn's 1200-byte
// datagram — so measuring the value before that expansion under-counts by up
// to six times, in the one direction that matters. It also breaks validation
// itself: the sender's check passes on the raw bytes and the receiver's fails
// on the escaped ones, so a write is rejected on the far side of the relay
// with nothing able to explain why. Found by
// FuzzValidateWorldIsStableAcrossTheWire in CI, 2026-08-22.
//
// This is an upper bound, not the exact encoded length: marshaling also
// compacts insignificant whitespace out, which this deliberately does not
// credit. Erring high is the safe direction, and it keeps the measure stable
// across the wire — an already-escaped, already-compacted value measures no
// larger than it did before it was sent, so a value that passed here cannot
// fail the same check after a round trip.
func JSONWireLen(raw []byte) int {
	n := len(raw)
	for i := 0; i < len(raw); i++ {
		switch raw[i] {
		case '<', '>', '&':
			n += 5
		case 0xe2:
			// U+2028 (e2 80 a8) and U+2029 (e2 80 a9): three bytes out, six in.
			if i+2 < len(raw) && raw[i+1] == 0x80 && (raw[i+2] == 0xa8 || raw[i+2] == 0xa9) {
				n += 3
			}
		}
	}
	return n
}

// maxFloatJSONLen bounds how many bytes encoding/json spends on one float64.
// The longest it can produce is a full-precision negative with a three-digit
// exponent, -1.7976931348623157e+308, which is 24.
const maxFloatJSONLen = 24

// extrasLengthBound returns an UPPER bound on len(json.Marshal(extras)) and
// ok=false when it cannot bound the value cheaply. It never allocates.
//
// It is deliberately not exact. Being exact would mean reproducing
// encoding/json's float formatting, which is the hazard that got a hand-written
// sizer rejected outright; being an upper bound means the only thing a mistake
// can cost is a needless trip through the real encoder. Callers must treat
// ok=false and "bound exceeds the limit" identically: as "go and measure".
//
// Nested containers return ok=false rather than recursing. They are unreachable
// from every shipped adapter — extras is a flat scalar map in all four — so
// recursion would be untested depth for no measured gain, and untested depth on
// peer-controlled input is how a stack overflow gets written.
func extrasLengthBound(extras map[string]any) (int, bool) {
	if len(extras) == 0 {
		// Just "{}". Its own case because the comma arithmetic below goes
		// negative here, which made this the first thing
		// FuzzExtrasSizingMatchesMarshal reported. Unreachable through
		// extrasWithinLimit, which short-circuits an empty map before calling
		// this — but a bound that is wrong only where nobody currently looks is
		// still a bound that is wrong.
		return 2, true
	}
	// The enclosing braces, plus a comma between every pair.
	n := 2 + len(extras) - 1
	for k, v := range extras {
		// Key, quoted, plus its colon.
		n += jsonStringLenBound(k) + 1
		switch val := v.(type) {
		case nil:
			n += len("null")
		case bool:
			n += len("false")
		case string:
			n += jsonStringLenBound(val)
		case float64, float32:
			n += maxFloatJSONLen
		case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
			// json renders these as plain integers, never wider than a float.
			n += maxFloatJSONLen
		default:
			// []any, map[string]any, json.RawMessage, a struct an in-process
			// caller passed — all handed to the encoder rather than guessed at.
			return 0, false
		}
	}
	return n, true
}

// jsonStringLenBound bounds the encoded length of one JSON string, quotes
// included, using the same escaping rules JSONWireLen documents: '<', '>' and
// '&' become six bytes under SetEscapeHTML(true), a quote or backslash becomes
// two, and a control byte becomes six. A byte that is part of invalid UTF-8 is
// replaced by U+FFFD, three bytes for one, which is the case that stops this
// being a simple len() and the reason it is a bound rather than a count.
func jsonStringLenBound(s string) int {
	n := 2 // the surrounding quotes
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '<' || c == '>' || c == '&':
			n += 6
		case c == '"' || c == '\\':
			n += 2
		case c < 0x20:
			n += 6
		case c >= 0x80:
			// Either it is valid UTF-8 and passes through at its own width, or
			// it is not and each offending byte becomes a three-byte U+FFFD.
			// U+2028/U+2029 also escape to six, from three bytes in.
			n += 6
		default:
			n++
		}
	}
	return n
}
