package hotkey

import (
	"strings"
	"testing"
)

// FuzzParseNeverPanicsAndOnlyAdmitsDocumentedChords: a chord is a string a
// player typed into config.json. Whatever it is, Parse must not panic, and
// anything it accepts must be a documented modifier set plus one documented
// key -- never F12, never the Windows key, never a bare key -- and must print
// back to a string that parses to the same binding.
//
// Long campaign by hand: go test ./internal/hotkey -run=XXX -fuzz=FuzzParse -fuzztime=5m
func FuzzParseNeverPanicsAndOnlyAdmitsDocumentedChords(f *testing.F) {
	for _, s := range []string{"ctrl+shift+F9", "alt+space", "win+a", "F12", "ctrl+F12", "", "+", "ctrl++", "CTRL+SHIFT+ALT+z", "ctrl+f25", "ctrl+f0", "ctrl+home+end", "shift+9", "ctrl+\u00e9"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		b, err := Parse(s)
		if err != nil {
			return
		}
		if b.Mods == 0 || b.Mods&ModWin != 0 || b.Mods&^(ModControl|ModShift|ModAlt) != 0 {
			t.Fatalf("Parse(%q) admitted modifiers 0x%x", s, b.Mods)
		}
		if b.VK == 0x7B { // VK_F12
			t.Fatalf("Parse(%q) admitted F12", s)
		}
		ok := (b.VK >= 0x70 && b.VK <= 0x87) || (b.VK >= 0x41 && b.VK <= 0x5A) || (b.VK >= 0x30 && b.VK <= 0x39)
		for _, vk := range namedKeys {
			ok = ok || b.VK == vk
		}
		if !ok {
			t.Fatalf("Parse(%q) admitted virtual key 0x%x, not a documented one", s, b.VK)
		}
		back, err := Parse(b.String())
		if err != nil || back != b {
			t.Fatalf("Parse(%q) = %+v prints as %q which parses to %+v (%v)", s, b, b.String(), back, err)
		}
		if strings.Count(s, "+") > 3 {
			t.Fatalf("Parse(%q) admitted more than three separators", s)
		}
	})
}
