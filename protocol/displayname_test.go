package protocol

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// The attacks this field is actually exposed to, each named for what it does to
// a person rather than for the code point involved.
func TestSanitizeDisplayNameClosesTheAttacks(t *testing.T) {
	cases := []struct {
		name   string
		in     string
		want   string
		wanted string // why this matters, printed on failure
	}{
		{
			name:   "a plain name is left completely alone",
			in:     "Tsukino",
			want:   "Tsukino",
			wanted: "sanitizing must be invisible to everybody who is not attacking it",
		},
		{
			name:   "non-latin names survive intact",
			in:     "つきの",
			want:   "つきの",
			wanted: "a safety rule that deletes legitimate names is not a safety rule",
		},
		{
			name:   "accents survive",
			in:     "Zoë",
			want:   "Zoë",
			wanted: "a normal diacritic is one combining mark and must pass",
		},
		{
			name:   "NEWLINE: forging relay log lines",
			in:     "alice\nrelay: p1 joined",
			want:   "alicerelay: p1 joined",
			wanted: "the relay LOGS this string; a newline lets a player write their own log lines",
		},
		{
			name: "NEWLINE, full-length forgery: the length cap finishes what the newline strip started",
			in:   "alice\n2026/08/28 relay: p1 joined room \"admin\"",
			// Two independent defences, and this is what makes the case worth keeping
			// separate: stripping the newline already means the forged text cannot start
			// its own line, and the 24-rune cap then removes most of the payload anyway.
			// A realistic forgery attempt does not fit in a name.
			want:   "alice2026/08/28 relay: p", // exactly MaxDisplayNameRunes
			wanted: "a real forged log line is far longer than a name is allowed to be",
		},
		{
			name:   "CARRIAGE RETURN and TAB are gone too",
			in:     "a\rb\tc",
			want:   "abc",
			wanted: "both break a single-line label and a log line",
		},
		{
			name:   "BIDI OVERRIDE: making your name read as someone else's",
			in:     "alice\u202Ebob",
			want:   "alicebob",
			wanted: "U+202E reverses the text after it -- the classic on-screen impersonation",
		},
		{
			name:   "every bidi isolate and embedding is stripped",
			in:     "a\u202Ab\u202Bc\u202Cd\u202De\u2066f\u2067g\u2068h\u2069i",
			want:   "abcdefghi",
			wanted: "excluding the whole Cf category means no relative gets in by not being listed",
		},
		{
			name:   "ZERO WIDTH: two names that look identical but compare different",
			in:     "adm\u200Bin",
			want:   "admin",
			wanted: "invisible characters exist here only to defeat an equality check",
		},
		{
			name:   "ZALGO: combining marks drawn outside the name's own box",
			in:     "a\u0301\u0302\u0303\u0304\u0305\u0306b",
			want:   "a\u0301\u0302b",
			wanted: "marks stack vertically without advancing, so a long run covers the screen",
		},
		{
			name:   "control characters generally",
			in:     "a\x00b\ac\x1bd",
			want:   "abcd",
			wanted: "NUL, BEL and ESC have no business in a label",
		},
		{
			name:   "leading and trailing space cannot shift the label off the ghost",
			in:     "      Tsukino      ",
			want:   "Tsukino",
			wanted: "padding a name moves the drawn text away from the thing it labels",
		},
		{
			name:   "runs of whitespace collapse, including exotic spaces",
			in:     "a \u00A0 \u2003 b",
			want:   "a b",
			wanted: "a no-break space is indistinguishable on screen and distinct to a comparison",
		},
		{
			name:   "a name of nothing but whitespace comes out empty",
			in:     "   \u00A0\u2003   ",
			want:   "",
			wanted: "otherwise a blank-looking name is still 'set' and draws an empty box",
		},
		{
			name:   "a name of nothing but invisibles comes out empty",
			in:     "\u200B\u200C\u200D\uFEFF",
			want:   "",
			wanted: "the whole point is that this cannot render as a mysterious floating nothing",
		},
		{
			name:   "empty stays empty",
			in:     "",
			want:   "",
			wanted: "empty means NO nametag at all -- the shipped default",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := SanitizeDisplayName(tc.in)
			if got != tc.want {
				t.Fatalf("SanitizeDisplayName(%q) = %q, want %q\n  why this matters: %s",
					tc.in, got, tc.want, tc.wanted)
			}
		})
	}
}

// Truncation must never split a rune, or the name that reaches other players is
// invalid UTF-8 that encoding/json then replaces with U+FFFD -- turning a length
// limit into visible corruption.
func TestSanitizeDisplayNameTruncatesWithoutBreakingRunes(t *testing.T) {
	cases := []string{
		strings.Repeat("a", 200),
		strings.Repeat("あ", 200), // 3 bytes each: the rune cap is not the byte cap
		strings.Repeat("😀", 200), // 4 bytes each, and non-BMP
		strings.Repeat("aあ😀", 50),
	}
	for _, in := range cases {
		got := SanitizeDisplayName(in)
		if !utf8.ValidString(got) {
			t.Fatalf("SanitizeDisplayName(%d bytes) produced invalid UTF-8", len(in))
		}
		if len(got) > MaxDisplayNameBytes {
			t.Fatalf("result is %d bytes, over the %d-byte cap", len(got), MaxDisplayNameBytes)
		}
		if n := utf8.RuneCountInString(got); n > MaxDisplayNameRunes {
			t.Fatalf("result is %d runes, over the %d-rune cap", n, MaxDisplayNameRunes)
		}
	}
}

// IDEMPOTENCE IS LOAD-BEARING, not tidiness.
//
// The relay sanitizes on the way in and every client sanitizes again on receive,
// because a relay is not trusted to have done it. If a second pass could change
// the string, the same player would render under different names on different
// machines -- which makes impersonation EASIER, which is the opposite of the point.
func TestSanitizeDisplayNameIsIdempotent(t *testing.T) {
	inputs := []string{
		"Tsukino", "つきの", "Zoë", "", "   ",
		"alice\u202Ebob", "adm\u200Bin", "a\u0301\u0302\u0303\u0304b",
		"a\nb\tc\rd", strings.Repeat("あ", 200), strings.Repeat("😀", 100),
		"a \u00A0 \u2003 b", "\u200B\u200C\u200D\uFEFF",
	}
	for _, in := range inputs {
		once := SanitizeDisplayName(in)
		twice := SanitizeDisplayName(once)
		if once != twice {
			t.Fatalf("not idempotent for %q: first pass %q, second pass %q", in, once, twice)
		}
	}
}

// Whatever comes out must be safe for the two things that then happen to it:
// it is written to the relay's log, and it is sent back out as JSON.
func FuzzSanitizeDisplayNameIsAlwaysSafeToShowAndLog(f *testing.F) {
	seeds := []string{
		"Tsukino", "", "   ", "alice\u202Ebob", "a\nb", "\u200B", "つきの",
		strings.Repeat("😀", 100), "a\u0301\u0302\u0303\u0304\u0305b", "�",
	}
	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, in string) {
		got := SanitizeDisplayName(in)

		if !utf8.ValidString(got) {
			t.Fatalf("produced invalid UTF-8 from %q", in)
		}
		if len(got) > MaxDisplayNameBytes {
			t.Fatalf("produced %d bytes from %q, over the cap", len(got), in)
		}
		if utf8.RuneCountInString(got) > MaxDisplayNameRunes {
			t.Fatalf("produced too many runes from %q", in)
		}
		// The log-injection property, stated directly: no line can ever be broken.
		if strings.ContainsAny(got, "\n\r\t") {
			t.Fatalf("produced a line-breaking character from %q -- this is the log injection", in)
		}
		for _, r := range got {
			if isDisallowedInDisplayName(r) {
				t.Fatalf("produced disallowed rune %U from %q", r, in)
			}
		}
		if got != SanitizeDisplayName(got) {
			t.Fatalf("not idempotent for %q", in)
		}
		if strings.HasPrefix(got, " ") || strings.HasSuffix(got, " ") {
			t.Fatalf("produced padded name %q from %q", got, in)
		}
	})
}

// A colour cannot really be "malicious", but it is handed to a game engine's
// text renderer, and the set of things an engine does with an unexpected string
// is open-ended. So the shape is the strictest one that still lets somebody pick
// exactly the colour they want: a '#' and six hex digits, nothing else.
func TestSanitizeNameColor(t *testing.T) {
	cases := []struct{ in, want, why string }{
		{"#F54927", "#F54927", "the ordinary case: a full hex colour passes untouched"},
		{"#f54927", "#F54927", "normalized to uppercase so one colour is one string everywhere"},
		{"#F00", "#FF0000", "three-digit shorthand is what people type, and expands unambiguously"},
		{"#abc", "#AABBCC", "shorthand expands each digit to a doubled pair"},
		{"#000000", "#000000", "black is a legitimate choice; legibility is the adapter's problem"},
		{"#FFFFFF", "#FFFFFF", "so is white"},

		{"", "", "no colour is the default and means 'use the adapter's own'"},
		{"F54927", "", "without the # it is not the shape we accept"},
		{"#F5492", "", "five digits is neither shorthand nor full"},
		{"#F549277", "", "seven digits is not a colour we accept"},
		{"#F5492G", "", "G is not a hex digit"},
		{"#FF0000AA", "", "no alpha channel: eight digits is a different format"},
		{"red", "", "named colours are a renderer-specific vocabulary, not a wire format"},
		{"rgb(255,0,0)", "", "function syntax is a parser we are not writing"},
		{"javascript:alert(1)", "", "whatever this is, it is not going to a text renderer"},
		{"#F54927\n#000000", "", "a newline cannot smuggle a second value through"},
	}
	for _, tc := range cases {
		if got := SanitizeNameColor(tc.in); got != tc.want {
			t.Errorf("SanitizeNameColor(%q) = %q, want %q\n  why: %s", tc.in, got, tc.want, tc.why)
		}
	}
}

// Same reasoning as the name: the relay sanitizes and every client sanitizes
// again, so a second pass must never change the answer.
func TestSanitizeNameColorIsIdempotent(t *testing.T) {
	for _, in := range []string{"#F54927", "#f00", "", "nonsense", "#FFF", "#12345G"} {
		once := SanitizeNameColor(in)
		if twice := SanitizeNameColor(once); once != twice {
			t.Fatalf("not idempotent for %q: %q then %q", in, once, twice)
		}
	}
}

// Whatever comes out is either empty or exactly seven characters an adapter can
// read as three bytes with no parser and no failure case.
func FuzzSanitizeNameColorIsAlwaysAHexColourOrNothing(f *testing.F) {
	for _, s := range []string{"#F54927", "#f00", "", "red", "#12345678", "#GGGGGG"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, in string) {
		got := SanitizeNameColor(in)
		if got == "" {
			return
		}
		if len(got) != 7 || got[0] != '#' {
			t.Fatalf("produced %q from %q, which is not #RRGGBB", got, in)
		}
		for i := 1; i < len(got); i++ {
			c := got[i]
			if !(c >= '0' && c <= '9') && !(c >= 'A' && c <= 'F') {
				t.Fatalf("produced %q from %q, containing non-uppercase-hex %q", got, in, c)
			}
		}
		if got != SanitizeNameColor(got) {
			t.Fatalf("not idempotent for %q", in)
		}
	})
}
