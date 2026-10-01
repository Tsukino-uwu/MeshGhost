package protocol

import "unicode/utf8"

// AppendEnvelope appends to dst the exact bytes json.Marshal would produce for an Envelope carrying this type and
// payload, so a payload already marshaled is not marshaled twice. No trailing newline: framing is the transport's.
//
// payload must be bytes encoding/json produced: RawMessage's encoder re-compacts and re-escapes '<', '>' and '&',
// appending does neither, and the two agree only because that pass is a no-op on the library's own output. A peer's
// raw bytes only appear nested (Event.Payload, State.Orientation) inside a struct the relay marshals; anything that
// forwards a peer's bytes as a whole payload must keep marshaling. FuzzAppendEnvelopeMatchesMarshal pins this.
func AppendEnvelope(dst []byte, t MessageType, payload []byte) []byte {
	// Grow once: letting append grow in stages allocates more than the json.Marshal this replaces.
	if need := envelopeLen(t, payload); cap(dst)-len(dst) < need {
		grown := make([]byte, len(dst), len(dst)+need)
		copy(grown, dst)
		dst = grown
	}
	dst = append(dst, `{"type":`...)
	dst = appendJSONString(dst, string(t))
	dst = append(dst, `,"payload":`...)
	if len(payload) == 0 {
		// A nil RawMessage marshals as null and Marshal refuses an empty one; appending nothing would be invalid JSON.
		dst = append(dst, "null"...)
	} else {
		dst = append(dst, payload...)
	}
	return append(dst, '}')
}

// envelopeLen sizes the buffer AppendEnvelope needs: exact unless the type needs escaping, which no defined type
// does, and then append grows the tail.
func envelopeLen(t MessageType, payload []byte) int {
	const syntax = len(`{"type":"","payload":}`)
	n := syntax + len(t) + len(payload)
	if len(payload) == 0 {
		n += len("null")
	}
	return n
}

// appendJSONString appends s as a quoted JSON string, matching encoding/json with its default SetEscapeHTML(true).
// Only ever called with a MessageType, but written for any input: U+2028 and U+2029 are escaped because they are
// line terminators to JavaScript, and an invalid UTF-8 byte becomes the \ufffd escape.
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
			// The five control characters encoding/json gives a short escape, taken from its output.
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

// escapedRuneError is what encoding/json writes for a byte that is not valid UTF-8: the six-character escape, not
// the three-byte replacement glyph, which would be a different string.
const escapedRuneError = `\ufffd`

func appendUnicodeEscape(dst []byte, r rune) []byte {
	const hex = "0123456789abcdef"
	return append(dst, '\\', 'u',
		hex[(r>>12)&0xF], hex[(r>>8)&0xF], hex[(r>>4)&0xF], hex[r&0xF])
}
