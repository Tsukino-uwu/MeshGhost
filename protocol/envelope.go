package protocol

import "unicode/utf8"

// Building an envelope's wire bytes without marshaling twice.
//
// The relay produced every state line twice. envelope() marshals a State into
// payload bytes, and Room.forward then marshaled the Envelope around those
// bytes -- which re-parses, re-escapes and re-copies every byte the first
// marshal had just written. Measured 2026-08-28 at 915ns and two allocations
// out of the ~8.3us a relay spent on one Emerald state, to produce bytes it
// already held.

// AppendEnvelope appends to dst the exact bytes json.Marshal would produce for
// an Envelope carrying this type and payload, and returns the extended slice.
//
// No trailing newline: NDJSON framing belongs to the transport, which appends
// it inside Send from a buffer it reuses (transport.NDJSONConn).
//
// THE PRECONDITION IS A SAFETY BOUNDARY, NOT A STYLE NOTE. payload must be
// bytes that encoding/json itself produced. json.RawMessage's encoder
// re-compacts its input and re-escapes '<', '>' and '&' on the way out;
// appending does neither. This is byte-identical only because that second pass
// is provably a no-op on output the standard library has already compacted and
// escaped. Hand a client-supplied slice to this and the two stop agreeing.
//
// That holds throughout this project today, and not by luck: a peer's own raw
// bytes only ever appear NESTED (Event.Payload, State.Orientation), inside a
// struct the relay marshals itself, so the outer marshal still compacts and
// escapes them. Anything that ever forwards a peer's bytes as a whole payload
// must keep marshaling rather than appending.
// FuzzAppendEnvelopeMatchesMarshal is the proof, not this comment.
func AppendEnvelope(dst []byte, t MessageType, payload []byte) []byte {
	// Grow once up front rather than letting append discover the size in
	// stages. Skipping this made the change a REGRESSION on its first
	// measurement -- three extra allocations per state against the very
	// json.Marshal it replaced, which had been filling one sized buffer while
	// this dribbled into a nil slice. The saving was real; growth was eating
	// it and then some.
	if need := envelopeLen(t, payload); cap(dst)-len(dst) < need {
		grown := make([]byte, len(dst), len(dst)+need)
		copy(grown, dst)
		dst = grown
	}
	dst = append(dst, `{"type":`...)
	dst = appendJSONString(dst, string(t))
	dst = append(dst, `,"payload":`...)
	if len(payload) == 0 {
		// A nil or empty json.RawMessage marshals as null, not as nothing --
		// appending nothing here would emit invalid JSON.
		dst = append(dst, "null"...)
	} else {
		dst = append(dst, payload...)
	}
	return append(dst, '}')
}

// envelopeLen sizes the buffer AppendEnvelope needs. It is exact whenever the
// type needs no escaping, which is every type this project defines; a type that
// did would simply let append grow the tail, so being an estimate costs
// correctness nothing.
//
//	{"type":"" ,"payload":}   fixed syntax
func envelopeLen(t MessageType, payload []byte) int {
	const syntax = len(`{"type":"","payload":}`)
	n := syntax + len(t) + len(payload)
	if len(payload) == 0 {
		n += len("null")
	}
	return n
}

// appendJSONString appends s as a quoted JSON string, matching encoding/json
// with its default SetEscapeHTML(true).
//
// It is only ever called with a MessageType -- a short ASCII identifier from
// the fixed set in protocol.go -- so in practice nothing below the first case
// ever fires. It is written for arbitrary input anyway, because an assumption
// about the caller outliving the comment that recorded it is a familiar way to
// get hurt, and because the two non-obvious cases here are exactly the ones a
// hand-rolled encoder normally gets wrong. Both were caught by
// TestAppendEnvelope* on their first run rather than reasoned about:
//
//   - U+2028 and U+2029 are perfectly valid UTF-8 and encoding/json escapes
//     them anyway, because they are line terminators to a JavaScript parser.
//     limits.go's JSONWireLen already documents the same pair for the same
//     reason.
//   - An invalid UTF-8 byte becomes U+FFFD on the way out, so passing bytes
//     through unexamined would produce a string Marshal would not have.
func appendJSONString(dst []byte, s string) []byte {
	dst = append(dst, '"')
	for i := 0; i < len(s); {
		if c := s[i]; c < utf8.RuneSelf {
			switch {
			case c == '<' || c == '>' || c == '&':
				dst = appendUnicodeEscape(dst, rune(c))
			case c == '"':
				dst = append(dst, '\\', '"')
			case c == '\\':
				dst = append(dst, '\\', '\\')
			// The five control characters encoding/json gives a short escape,
			// with the rest going to \u00XX below. Enumerated from the standard
			// library's actual output on this Go version rather than from
			// memory -- the first draft guessed and omitted \b and \f, which
			// FuzzAppendEnvelopeMatchesMarshal reported within a minute.
			case c == '\b':
				dst = append(dst, '\\', 'b')
			case c == '\t':
				dst = append(dst, '\\', 't')
			case c == '\n':
				dst = append(dst, '\\', 'n')
			case c == '\f':
				dst = append(dst, '\\', 'f')
			case c == '\r':
				dst = append(dst, '\\', 'r')
			case c < 0x20:
				dst = appendUnicodeEscape(dst, rune(c))
			default:
				dst = append(dst, c)
			}
			i++
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && size == 1:
			dst = append(dst, escapedRuneError...)
		case r == 0x2028 || r == 0x2029:
			dst = appendUnicodeEscape(dst, r)
		default:
			dst = append(dst, s[i:i+size]...)
		}
		i += size
	}
	return append(dst, '"')
}

// escapedRuneError is what encoding/json writes for a byte that is not valid
// UTF-8: the six-character escape sequence, not the replacement character
// itself. Spelled with a backslash on purpose -- the literal glyph is three
// bytes and would silently produce a shorter, different string.
const escapedRuneError = `\ufffd`

func appendUnicodeEscape(dst []byte, r rune) []byte {
	const hex = "0123456789abcdef"
	return append(dst, '\\', 'u',
		hex[(r>>12)&0xF], hex[(r>>8)&0xF], hex[(r>>4)&0xF], hex[r&0xF])
}
