package protocol

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"sync"
)

// State field limits, checked both where the relay accepts a State from a client and where a core accepts one from
// the relay. Living here, rather than as a constant on each side, means the two enforcement points cannot drift.
const (
	// MaxPositionLen bounds len(State.Position): headroom above the largest real use (3, for a 3D game), never a
	// fixed length.
	MaxPositionLen = 8

	// MaxExtrasBytes bounds the serialized size of State.Extras.
	MaxExtrasBytes = 1024

	// MaxRosterSize bounds how many remote players a core tracks: the only bound between a hostile relay and an
	// adapter that spawns a ghost per announced id. Well above the largest room driven (about 150 peers).
	MaxRosterSize = 512

	// MaxOrientationBytes bounds the serialized size of State.Orientation, generous above any real representation
	// (a handful of floats).
	MaxOrientationBytes = 256

	// MaxJSONDepth bounds the nesting of Extras and Orientation, since a size cap says nothing about shape and every
	// receiver walks it. It reads no key or value, so it is not the core becoming game-aware. 32 sits below the 64
	// both Lua adapters enforce.
	MaxJSONDepth = 32

	// MaxAreaIDLen and MaxAnimLen bound the opaque AreaID/Anim strings against resource exhaustion only; they are
	// compared by equality and never interpreted.
	MaxAreaIDLen = 256
	MaxAnimLen   = 256

	// MaxTimestampMs bounds State.Timestamp so no difference between two valid timestamps overflows a time.Duration
	// (int64 nanoseconds wrap past about 9.22e12 ms; 1<<42 is about 4.4e12, the year 2109). Negative is refused too:
	// it means nothing on any clock this field can be in, and would double the worst-case span.
	MaxTimestampMs = 1 << 42

	// MaxPositionComponent bounds the absolute value of each State.Position component. A peer can send 1e308,
	// which survives []float64 unmarshaling and becomes +Inf when an adapter narrows it to float32. Headroom far
	// above any adapter's units; NaN and Inf are refused regardless (IsValidPosition).
	MaxPositionComponent = 1e7

	// MaxLineBytes bounds one NDJSON line, the whole Envelope. Shared with transport, the enforcement point, so the
	// relay's accepted connections and the core's dialed one use the same value. Generous above any legitimate state
	// (a few hundred bytes) while ruling out an unbounded payload through Extras.
	MaxLineBytes = 4096

	// MaxPayloadBytes is the largest line a receiver accepts: one under MaxLineBytes, because bufio.Scanner counts
	// the delimiter against its own buffer, so a payload of exactly the limit never fits. Senders compare against
	// this; the scanner is still configured with MaxLineBytes, the size it may grow to.
	MaxPayloadBytes = MaxLineBytes - 1

	// DefaultSendHz is the room send rate a relay advertises when its operator set none, and a client's fallback. 15
	// because a blind A/B against 20 scored at chance and stutter shows near 10. Lowering it widens no configured
	// room's flood cap: relay.RateLimitHeadroomMultiple deliberately does not derive from it.
	DefaultSendHz = 15

	// MinSendHz and MaxSendHz bound server.send_hz and client.max_receive_hz_per_player. The floor keeps the sample
	// gap well inside core.DefaultInterpolationDelay, past which interpolation falls back to edge snapshots; the
	// ceiling bounds bandwidth, and what a hostile relay can talk a client into sending.
	MinSendHz = 10
	MaxSendHz = 100
)

// IsValidPosition reports whether every component of pos is finite and within ±MaxPositionComponent. The relay and
// the core both call it, so the two enforcement points use the identical check.
func IsValidPosition(pos []float64) bool {
	for _, v := range pos {
		if math.IsNaN(v) || math.IsInf(v, 0) || v > MaxPositionComponent || v < -MaxPositionComponent {
			return false
		}
	}
	return true
}

// ClampSendHz resolves a configured or advertised send rate: zero or negative means DefaultSendHz, and anything
// outside [MinSendHz, MaxSendHz] is clamped rather than refused, since a typo in a cosmetic knob must not stop a
// relay or drop a connection. It never logs; a caller that wants to warn compares its input with the result.
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

// ClampReceiveHz resolves a per-peer receive cap (Hello.MaxReceiveHz). Unlike ClampSendHz, zero or negative means
// uncapped and stays 0; a positive value is clamped to [MinSendHz, MaxSendHz] rather than refused.
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

// ValidateState reports whether st passes every bound in this file. The relay and the core both call it, so the two
// enforcement points cannot drift apart.
func ValidateState(st State) bool {
	if len(st.Position) > MaxPositionLen {
		return false
	}
	if st.Timestamp < 0 || st.Timestamp > MaxTimestampMs {
		return false
	}
	// AreaID and Anim must be valid UTF-8, like the other planes' identifiers: an invalid string comes back from a
	// JSON round trip as a different one, and the core compares them by equality. This guards in-process callers.
	if !ValidOpaqueString(st.AreaID, MaxAreaIDLen) || !ValidOpaqueString(st.Anim, MaxAnimLen) ||
		JSONWireLen(st.Orientation) > MaxOrientationBytes ||
		!rawJSONDepthWithinLimit(st.Orientation) {
		return false
	}
	if !IsValidPosition(st.Position) {
		return false
	}
	// After the cheap checks on purpose: it serializes, and nothing observes which check rejected a state.
	if !extrasWithinLimit(st.Extras) {
		return false
	}
	// A carried previous sample meets every bound above on its own fields; last because most states lack one.
	return validPrev(st.Prev)
}

// StateRejectReason names which ValidateState check st fails, or "" if it passes them all. Called only on the
// rejection path, so a dropped state can say why rather than vanish silently.
func StateRejectReason(st State) string {
	if st.Timestamp < 0 {
		return fmt.Sprintf("timestamp %d is before the epoch", st.Timestamp)
	}
	if st.Timestamp > MaxTimestampMs {
		return fmt.Sprintf("timestamp %d is past the %d cap (a span that wide overflows a time.Duration)",
			st.Timestamp, int64(MaxTimestampMs))
	}
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
		// Shape first: a value can be both deep and small, and a size would send a reader looking for bytes.
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

// extrasSizer keeps a buffer and its encoder together so the pool hands out one warm pair.
type extrasSizer struct {
	buf bytes.Buffer
	enc *json.Encoder
}

var extrasSizers = sync.Pool{
	New: func() any {
		s := &extrasSizer{}
		s.enc = json.NewEncoder(&s.buf)
		// Explicit: this must agree with json.Marshal exactly, or a validation boundary moves.
		s.enc.SetEscapeHTML(true)
		return s
	},
}

// maxPooledSizerCap stops one large in-process Extras from parking a big buffer in the pool. The wire cannot deliver
// one (MaxLineBytes), but in-process callers reach ValidateState unclipped.
const maxPooledSizerCap = 8 * MaxExtrasBytes

// jsonDepthWithinLimit reports whether a decoded JSON value nests no deeper than MaxJSONDepth. It recurses at most
// MaxJSONDepth frames, which is what makes the walk safe on peer-controlled input.
func jsonDepthWithinLimit(v any, depth int) bool {
	// The bound is tested on containers only, never on a scalar leaf, so it counts depth the way the byte scan does.
	switch t := v.(type) {
	case map[string]any:
		if depth > MaxJSONDepth {
			return false
		}
		for _, e := range t {
			if !jsonDepthWithinLimit(e, depth+1) {
				return false
			}
		}
	case []any:
		if depth > MaxJSONDepth {
			return false
		}
		for _, e := range t {
			if !jsonDepthWithinLimit(e, depth+1) {
				return false
			}
		}
	}
	return true
}

// rawJSONDepthWithinLimit is the same bound over undecoded bytes, for Orientation, which is never unmarshaled here.
// It counts brackets outside string literals, neither allocating nor recursing, and is not a JSON validator.
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

// extrasWithinLimit reports whether extras serializes to at most MaxExtrasBytes without allocating the serialized
// form. The slow path uses the same encoder as json.Marshal, so the count is identical by construction; a
// hand-written sizer would have to match encoding/json's float formatting, and being wrong here moves a limit.
func extrasWithinLimit(extras map[string]any) bool {
	if len(extras) == 0 {
		return true
	}
	// The cheap path, which every shipped adapter takes: an upper bound on the length. It can only accept early,
	// never reject, so a state near the limit still goes through encoding/json itself.
	if n, ok := extrasLengthBound(extras); ok && n <= MaxExtrasBytes {
		return true
	}
	// Still here means a nested container or a size near the limit: the slow path, where the shape check belongs.
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
	// Encode ends its value with a newline that Marshal does not write.
	return s.buf.Len()-1 <= MaxExtrasBytes
}

// JSONWireLen reports how many bytes a raw JSON value occupies on the wire, which is not len(raw): encoding/json
// escapes '<', '>', '&' and U+2028/U+2029 to six bytes each, so a bound measured in hand under-counts by up to six
// times. An upper bound: compaction is not credited, which errs high and stays stable across a round trip.
func JSONWireLen(raw []byte) int {
	n := len(raw)
	for i := 0; i < len(raw); i++ {
		switch raw[i] {
		case '<', '>', '&':
			n += 5
		case 0xe2:
			// U+2028 (e2 80 a8) and U+2029 (e2 80 a9): three bytes in, six on the wire.
			if i+2 < len(raw) && raw[i+1] == 0x80 && (raw[i+2] == 0xa8 || raw[i+2] == 0xa9) {
				n += 3
			}
		}
	}
	return n
}

// maxFloatJSONLen bounds the bytes encoding/json spends on one float64: the longest is -1.7976931348623157e+308.
const maxFloatJSONLen = 24

// extrasLengthBound returns an upper bound on len(json.Marshal(extras)) without allocating, or ok=false when it
// cannot bound the value cheaply, including any nested container. An over-estimate only costs a trip through the
// real encoder; an under-estimate would accept early, so it must never happen.
func extrasLengthBound(extras map[string]any) (int, bool) {
	if extras == nil {
		// A nil map encodes as "null", four bytes, not as "{}"; a bound must never under-estimate.
		return len("null"), true
	}
	if len(extras) == 0 {
		// Just "{}": its own case because the comma arithmetic below goes negative here.
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
			// A slice, map, RawMessage or in-process struct goes to the encoder rather than being guessed at.
			return 0, false
		}
	}
	return n, true
}

// jsonStringLenBound bounds the encoded length of one JSON string, quotes included: '<', '>' and '&' become six
// bytes, a quote or backslash two, a control byte six. An invalid UTF-8 byte becomes a three-byte U+FFFD, which is
// why this is a bound rather than a count.
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
			// Valid UTF-8 passes at its own width, an invalid byte becomes three, U+2028/9 become six: six covers all.
			n += 6
		default:
			n++
		}
	}
	return n
}
