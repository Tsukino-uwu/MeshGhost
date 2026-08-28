package protocol

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// Display names, and why they get their own file.
//
// display_name is the ONLY string on this wire that a human types and other
// humans then read. Everything else is either machine-chosen (player_id), a
// key compared by equality and never shown (area_id, anim), or a number. That
// makes it the one field where "valid" is not the same question as "safe": a
// name can be perfectly well-formed UTF-8, pass every length check, and still
// be a tool for lying about who you are.
//
// It was also, until 2026-08-28, the only free-form string with NO limit at
// all. area_id and anim are capped at 256 bytes and extras at 1024; a name was
// bounded only by MaxLineBytes, four kilobytes of anything.
//
// SANITIZE, DO NOT REJECT. A name is decoration on a cosmetic ghost, and
// refusing to let somebody into a room because of a character in it is a worse
// outcome than quietly dropping that character. This is the opposite of the
// choice made for opaque strings (ValidOpaqueString rejects), and the reason
// is that those are compared for EQUALITY -- silently changing one breaks
// matching -- while a name is only ever shown.
//
// THE IDENTITY IS player_id, ALWAYS. A name is never an identity, is never
// unique by itself, and nothing may ever key off one. Two players may type the
// same name; the relay disambiguates what is DISPLAYED (see
// relay's uniqueDisplayName) but the truth is the id underneath.

const (
	// MaxDisplayNameBytes bounds what crosses the wire; MaxDisplayNameRunes
	// bounds what a game has to find room for above a ghost's head.
	//
	// BOTH, because neither alone is enough. Bytes alone lets 64 combining
	// marks through, which is one visual glyph and a lot of vertical smear.
	// Runes alone lets 24 four-byte runes through, which is 96 bytes on a wire
	// where the whole line budget is 4096 and a state message has to fit too.
	MaxDisplayNameBytes = 64
	MaxDisplayNameRunes = 24

	// maxCombiningMarks is how many combining marks may follow one base
	// character. Combining marks stack VERTICALLY without advancing the cursor,
	// so an unbounded run ("Zalgo" text) draws far outside its own line and, in
	// a game, over whatever the player was trying to look at. Two is enough for
	// every real diacritic stack a name plausibly needs.
	maxCombiningMarks = 2
)

// SanitizeDisplayName returns the name that is safe to show to other players.
//
// IDEMPOTENT BY CONSTRUCTION, and that is load-bearing rather than tidy: the
// relay sanitizes on the way in and every client sanitizes again on the way out
// (a relay is not trusted to have done it -- see core's storeRemoteName), so a
// name that changed on the second pass would render differently on different
// machines and make impersonation EASIER, not harder.
//
// It returns "" for a name with nothing left, and the caller decides what that
// means -- the relay substitutes the player's id, so every ghost carries a
// label that at least cannot be forged.
//
// What comes out, in order:
//
//  1. Invalid UTF-8 is dropped. It cannot reach here from the wire (the JSON
//     decoder already replaced it) but can from an in-process caller.
//  2. CONTROL CHARACTERS GO. This one is not hypothetical and not only about
//     rendering: the relay logs the name it was given, so a name containing a
//     newline could forge relay log lines -- a live log-injection hole that
//     existed before any nametag did.
//  3. BIDI CONTROLS GO. U+202E and its relatives reverse the direction of the
//     text AROUND them, which is the classic way to make your own name read on
//     screen as somebody else's. There is no legitimate use in a name.
//  4. ZERO-WIDTH CHARACTERS GO. They render as nothing, so they exist here only
//     to make two visually identical names compare as different strings.
//  5. Combining marks are capped per base character (see maxCombiningMarks).
//  6. Whitespace is collapsed and trimmed, so leading spaces cannot be used to
//     push a name away from the ghost it belongs to, and a name of nothing but
//     spaces does not read as blank while still being "set".
//  7. Truncated to MaxDisplayNameRunes, then to MaxDisplayNameBytes, never
//     splitting a rune.
//
// DELIBERATELY NOT DONE: unicode normalization and confusable (homoglyph)
// folding. Both need golang.org/x/text, this module has no dependency on it,
// and neither actually closes impersonation -- a determined homoglyph attack
// survives NFC, and folding confusables would reject legitimate non-Latin
// names wholesale. The answer to impersonation is that the id is the identity
// and the relay disambiguates duplicates, not that a name is made unforgeable.
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
			// Collapse any run of whitespace to a single plain space. A tab or a
			// no-break space inside a name is indistinguishable from a space on
			// screen but not to a string comparison.
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

// SanitizeNameColor returns a nametag colour as "#RRGGBB", or "" for anything
// it does not recognise -- which means "no colour of my own, use the adapter's
// default" rather than an error. Nobody is refused a session over a colour.
//
// Deliberately the STRICTEST possible shape: exactly a '#' and six hex digits,
// normalized to uppercase so the same colour is the same string everywhere.
// Three-digit shorthand ("#F00") is accepted and expanded, because it is what
// people type and expanding it is unambiguous. Everything else -- named colours,
// rgb(), alpha channels, anything with a length this does not expect -- is
// dropped rather than guessed at.
//
// WHY SO STRICT, when a colour cannot really be malicious: because this string
// is handed to a game engine's text renderer, and the set of things that happen
// when an engine is passed an unexpected string is open-ended. Six hex digits
// can be parsed into three bytes by the adapter with no parser and no doubt.
// Legibility is NOT clamped -- a player may pick a colour that is hard to read
// against their friend's background, and that is their business. The adapter's
// answer to legibility is an outline or shadow behind the text, not a narrower
// palette (the user asked for exactly this: "it also allows people to pick
// really specific colors if they want to").
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
			// Shorthand: each digit stands for a doubled pair, so #F00 is #FF0000.
			digits = append(digits, d)
		}
	}
	return "#" + string(digits)
}

// hexDigit reports the uppercase form of one hex digit.
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

// isDisallowedInDisplayName reports characters that never belong in a name,
// whatever else is true of them.
func isDisallowedInDisplayName(r rune) bool {
	switch {
	case r == '\t', r == '\n', r == '\r':
		// Whitespace by Unicode's reckoning, control characters by ours: these
		// are the ones that break a log line or a single-line label.
		return true
	case unicode.IsControl(r):
		return true
	case unicode.Is(unicode.Cf, r):
		// Format characters: bidi overrides and isolates (U+202A-U+202E,
		// U+2066-U+2069), the zero-width joiner and non-joiner, U+FEFF, and the
		// rest of the invisible-but-present family. Excluded wholesale rather
		// than one at a time so a character nobody here has heard of does not
		// get in by not being on a list.
		return true
	case r == '\u200B', r == '\u2060':
		// Zero-width space and word joiner, written as ESCAPES ON PURPOSE: a
		// literal invisible character in source is unreviewable, and this file
		// exists because invisible characters are a problem. Zs/Cf edge cases
		// some tables put outside Cf; named so the intent survives a table change.
		return true
	case unicode.Is(unicode.Co, r):
		// Private use area: renders as whatever a font decides, including
		// nothing, and means nothing across machines.
		return true
	case !unicode.IsGraphic(r):
		return true
	}
	return false
}

// isCombiningMark reports a character that stacks onto the preceding one
// instead of advancing the cursor.
func isCombiningMark(r rune) bool {
	return unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Mc, r) || unicode.Is(unicode.Me, r)
}
