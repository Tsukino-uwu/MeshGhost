package protocol

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// A display name is the one string on this wire a human types and others read, so it is sanitized, never
// rejected: it is only shown, while opaque strings (ValidOpaqueString) are compared by equality and rejected.
// Nothing trusts a name: two players may share one and the relay forwards both unchanged, while every lookup, seat,
// despawn and lease is keyed by player_id. Disambiguation, if ever wanted, belongs on the display side.

const (
	// MaxDisplayNameBytes bounds what crosses the wire; MaxDisplayNameRunes bounds what a game must fit above a
	// ghost. Both, since 64 bytes of combining marks is one smeared glyph and 24 four-byte runes is 96 bytes.
	MaxDisplayNameBytes = 64
	MaxDisplayNameRunes = 24

	// maxCombiningMarks caps the combining marks after one base character: they stack vertically without
	// advancing, so an unbounded run draws far outside its own line. Two covers every real diacritic stack.
	maxCombiningMarks = 2
)

// SanitizeDisplayName returns the name that is safe to show to other players, or "" when nothing is left, which
// the relay stores as no nametag at all.
//
// It must be idempotent: the relay sanitizes on the way in and every client again on the way out (core's
// storeRemoteName), so a name that changed on the second pass would render differently on different machines.
//
// In order: invalid UTF-8 is dropped; control characters go, since the relay logs the name and a newline would
// forge log lines; bidi controls go, since they make a name read as someone else's; zero-width characters go,
// since they make identical-looking names compare different; combining marks are capped per base character;
// whitespace is collapsed and trimmed; and the result is truncated to MaxDisplayNameRunes, then
// MaxDisplayNameBytes, never splitting a rune.
//
// Unicode normalization and confusable folding are not done: both need golang.org/x/text, neither closes
// impersonation, and folding would reject legitimate non-Latin names. The id is the identity, not the name.
func SanitizeDisplayName(s string) string {
	if s == "" {
		return ""
	}

	var b strings.Builder
	b.Grow(len(s))

	runes := 0
	marks := 0
	lastWasSpace := false

	for _, r := range s {
		if r == utf8.RuneError {
			// Either invalid input or a literal U+FFFD; neither belongs in a name.
			continue
		}
		if isDisallowedInDisplayName(r) {
			continue
		}

		if unicode.IsSpace(r) {
			// A tab or no-break space looks like a space on screen but not to a string comparison.
			if lastWasSpace || runes == 0 {
				continue
			}
			lastWasSpace = true
			marks = 0
			b.WriteRune(' ')
			runes++
			continue
		}
		lastWasSpace = false

		if isCombiningMark(r) {
			if marks >= maxCombiningMarks {
				continue
			}
			marks++
		} else {
			marks = 0
		}

		if runes >= MaxDisplayNameRunes {
			break
		}
		if b.Len()+utf8.RuneLen(r) > MaxDisplayNameBytes {
			break
		}
		b.WriteRune(r)
		runes++
	}

	// A trailing space can only have come from the collapse above.
	return strings.TrimRight(b.String(), " ")
}

// SanitizeNameColor returns a nametag colour as "#RRGGBB", or "" (the adapter's default) for anything it does not
// recognise; nobody is refused a session over a colour. Shorthand "#F00" is expanded and digits are uppercased, so
// one colour is one string; named colours, rgb() and alpha are dropped rather than guessed at.
//
// Strict because the string is handed to a game engine's text renderer: six hex digits parse into three bytes with
// no doubt. Legibility is not clamped; an adapter answers it with an outline or shadow, not a narrower palette.
func SanitizeNameColor(s string) string {
	if len(s) != 4 && len(s) != 7 {
		return ""
	}
	if s[0] != '#' {
		return ""
	}
	digits := make([]byte, 0, 6)
	for i := 1; i < len(s); i++ {
		d, ok := hexDigit(s[i])
		if !ok {
			return ""
		}
		digits = append(digits, d)
		if len(s) == 4 {
			digits = append(digits, d)
		}
	}
	return "#" + string(digits)
}

func hexDigit(b byte) (byte, bool) {
	switch {
	case b >= '0' && b <= '9':
		return b, true
	case b >= 'a' && b <= 'f':
		return b - 'a' + 'A', true
	case b >= 'A' && b <= 'F':
		return b, true
	}
	return 0, false
}

func isDisallowedInDisplayName(r rune) bool {
	switch {
	case r == '\t', r == '\n', r == '\r':
		// Whitespace to Unicode, but they break a log line or a single-line label.
		return true
	case unicode.IsControl(r):
		return true
	case unicode.Is(unicode.Cf, r):
		// Format characters (bidi overrides and isolates, zero-width joiners, U+FEFF), excluded wholesale so one
		// nobody here has heard of does not get in by not being on a list.
		return true
	case r == '\u200B', r == '\u2060':
		// Escapes because a literal invisible character in source is unreviewable; named because some tables put
		// them outside Cf.
		return true
	case unicode.Is(unicode.Co, r):
		// Private use renders as whatever a font decides and means nothing across machines.
		return true
	case !unicode.IsGraphic(r):
		return true
	}
	return false
}

func isCombiningMark(r rune) bool {
	return unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Mc, r) || unicode.Is(unicode.Me, r)
}
