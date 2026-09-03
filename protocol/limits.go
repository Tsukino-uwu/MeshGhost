package protocol

import (
	"bytes"
	"encoding/json"
	"fmt"
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

	// MaxRosterSize bounds how many remote players a core will track at
	// once -- the only bound between a hostile or broken relay and the
	// adapter behind the bridge, which spawns one ghost per announced id
	// with no count of its own (found by the 2026-09-02 adversarial review,
	// TEVI's Instantiate per player_id). A join past this is ignored, and
	// so is every state for that id, since the roster is what admits state.
	// Well above the largest room the relay has been driven at (~150, see
	// agent_docs/scaling.md); a relay hosting more than this needs a bigger
	// number here first.
	MaxRosterSize = 512

	// MaxOrientationBytes bounds the serialized size of State.Orientation
	// (raw JSON — scalar, vector, or quaternion depending on the adapter).
	// Generous above any real representation, which is a handful of floats.
	MaxOrientationBytes = 256

	// MaxJSONDepth bounds the NESTING of the two free-form fields, Extras and
	// Orientation. The size caps above bound how MUCH a peer can send and say
	// nothing about its SHAPE, and the two are not the same bound: nested
	// containers cost about a byte a level, so 490 levels fit inside the 1024
	// Extras allows and 127 inside Orientation's 256 (measured 2026-08-24,
	// agent_docs/security-design.md). Every receiver then walks that structure,
	// and the receivers are four hand-written decoders in three languages.
	//
	// This is NOT the core becoming game-aware. The opacity rule says do not
	// interpret the CONTENTS; a depth bound reads no key, no value and no
	// meaning. "No legitimate game state is 200 objects deep" is a fact about
	// JSON, not about any game — and extrasLengthBound below already records
	// that every shipped adapter puts a FLAT scalar map here.
	//
	// 32 rather than 64: it sits below the 64 both Lua adapters enforce
	// (2026-09-03), so nothing an adapter would refuse ever reaches it, and it
	// is still an order of magnitude above anything a game has ever sent.
	MaxJSONDepth = 32

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
	// older relay).
	//
	// **15Hz since 2026-09-01, lowered from 20 on the first evidence anyone
	// ever gathered for this number.** The 20 was inherited rather than
	// measured: it was the rate live-confirmed as core.DefaultMinSendInterval
	// across the games shipping in 2026-08, kept so the two were provably
	// equal, and explicitly not a claim about the right rate.
	//
	// What replaced it (adapters/pseudoregalia/VERIFIED.md, the 2026-09-01
	// evening entry): a rung-by-rung ladder watched on screen with two real
	// game instances through meshghost-netsim, then a FIVE-ROUND BLIND A/B of
	// 15 against 20 with the rate hidden from the watcher -- who scored 2.5/5,
	// chance, and whose one confident "this is the slow one" tell fired twice
	// on rounds that were actually 20Hz (it was a renderer bug in the thrown
	// sword, fixed separately). Below that: 10Hz "some stutters every now and
	// then", 7Hz "jitter/lag every now and then", 5Hz "constantly snapping",
	// 3Hz and 1Hz outright teleporting. So the visible floor is near 10 and
	// 15 carries margin over it, while 20 buys nothing a watcher can see.
	//
	// Measured on Pseudoregalia deliberately -- 3D, momentum, long airborne
	// arcs, the most sample-hungry adapter shipped -- so the other three
	// inherit a rate proven on the hardest case, and each is still free to
	// be swept and raised on its own evidence (ADR 0040's per-game principle).
	// A room that wants more sets server.send_hz; nothing about this being a
	// default makes it a ceiling.
	//
	// Two things deliberately NOT changed with it: MinSendHz stays 10 (the
	// sub-10 rungs above are why -- they were reached with a temporary dev
	// build), and relay.RateLimitHeadroomMultiple stopped deriving from this
	// constant so that lowering the default could not silently widen every
	// configured room's flood cap. See that constant's own comment.
	DefaultSendHz = 15

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
		JSONWireLen(st.Orientation) > MaxOrientationBytes ||
		!rawJSONDepthWithinLimit(st.Orientation) {
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
	if !extrasWithinLimit(st.Extras) {
		return false
	}
	// A carried previous sample meets every bound above, on its own fields
	// (prev.go). It is last because it is absent on most states.
	return validPrev(st.Prev)
}

// StateRejectReason names which ValidateState check st fails, or "" if it
// passes them all. Only ever called on the REJECTION path (both call sites
// drop the state either way, so the accepted path never pays for this), and
// it exists because the drop used to be silent at both enforcement points:
// found 2026-09-01, when a Pseudoregalia sword throw pushed that adapter's
// extras past MaxExtrasBytes and every symptom on the receiving side --
// a ghost holding a sword its peer had thrown, a prop frozen mid-air --
// pointed anywhere but here. A state dropped for size must say so.
func StateRejectReason(st State) string {
	if !ValidOpaqueString(st.AreaID, MaxAreaIDLen) {
		return fmt.Sprintf("area_id invalid or over %d bytes", MaxAreaIDLen)
	}
	if !ValidOpaqueString(st.Anim, MaxAnimLen) {
		return fmt.Sprintf("anim invalid or over %d bytes", MaxAnimLen)
	}
	if n := JSONWireLen(st.Orientation); n > MaxOrientationBytes {
		return fmt.Sprintf("orientation %d bytes over the %d cap", n-MaxOrientationBytes, MaxOrientationBytes)
	}
	if !rawJSONDepthWithinLimit(st.Orientation) {
		return fmt.Sprintf("orientation nests deeper than the %d-level cap", MaxJSONDepth)
	}
	if !IsValidPosition(st.Position) {
		return "position not a finite vector of plausible length"
	}
	if !extrasWithinLimit(st.Extras) {
		// Shape first: a value can be both deep and small, and reporting a size
		// for it would send a reader looking for bytes that are not the problem.
		if !jsonDepthWithinLimit(st.Extras, 1) {
			return fmt.Sprintf("extras nests deeper than the %d-level cap", MaxJSONDepth)
		}
		if b, err := json.Marshal(st.Extras); err == nil {
			return fmt.Sprintf("extras %d bytes, %d over the %d cap", len(b), len(b)-MaxExtrasBytes, MaxExtrasBytes)
		}
		return fmt.Sprintf("extras over the %d-byte cap", MaxExtrasBytes)
	}
	if !validPrev(st.Prev) {
		return "carried previous sample (prev) fails the same bounds"
	}
	return ""
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
// jsonDepthWithinLimit reports whether a decoded JSON value nests no deeper
// than MaxJSONDepth. It recurses, but only ever to MaxJSONDepth frames, because
// exceeding it returns immediately — the bound is what makes the walk safe on
// peer-controlled input rather than merely a check of it.
func jsonDepthWithinLimit(v any, depth int) bool {
	if depth > MaxJSONDepth {
		return false
	}
	switch t := v.(type) {
	case map[string]any:
		for _, e := range t {
			if !jsonDepthWithinLimit(e, depth+1) {
				return false
			}
		}
	case []any:
		for _, e := range t {
			if !jsonDepthWithinLimit(e, depth+1) {
				return false
			}
		}
	}
	return true
}

// rawJSONDepthWithinLimit is the same bound over UNDECODED bytes, for
// Orientation, which is a json.RawMessage and is never unmarshaled here. A byte
// scan rather than a parse: it counts brackets outside string literals, so it
// cannot be fooled by a brace inside a string, and it neither allocates nor
// recurses. It is deliberately not a JSON validator — a malformed value is
// caught elsewhere; this answers one question only.
func rawJSONDepthWithinLimit(b []byte) bool {
	depth := 0
	inString := false
	escaped := false
	for _, c := range b {
		if inString {
			switch {
			case escaped:
				escaped = false
			case c == '\\':
				escaped = true
			case c == '"':
				inString = false
			}
			continue
		}
		switch c {
		case '"':
			inString = true
		case '{', '[':
			depth++
			if depth > MaxJSONDepth {
				return false
			}
		case '}', ']':
			depth--
		}
	}
	return true
}

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
	// Anything still here either holds a nested container (the bound above
	// refuses to recurse, so it returned ok=false) or sits near the size limit.
	// Both are the slow path already, which is exactly where the shape check
	// belongs: a flat scalar map — what every shipped adapter sends — returned
	// above and never pays for this.
	if !jsonDepthWithinLimit(extras, 1) {
		return false
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
