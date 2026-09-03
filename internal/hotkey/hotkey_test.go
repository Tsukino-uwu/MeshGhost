package hotkey

import (
	"runtime"
	"testing"
	"time"
)

// TestParseReadsChordsAnyOrderAnyCase pins the parser against the values
// RegisterHotKey and the Virtual-Key Codes page define (ADR 0048).
func TestParseReadsChordsAnyOrderAnyCase(t *testing.T) {
	cases := map[string]Binding{
		"ctrl+shift+F9":     {Mods: ModControl | ModShift, VK: 0x78},
		"SHIFT+CTRL+f9":     {Mods: ModControl | ModShift, VK: 0x78},
		"control+alt+a":     {Mods: ModControl | ModAlt, VK: 0x41},
		"alt+1":             {Mods: ModAlt, VK: 0x31},
		"ctrl+F1":           {Mods: ModControl, VK: 0x70},
		"ctrl+F24":          {Mods: ModControl, VK: 0x87},
		"ctrl+space":        {Mods: ModControl, VK: 0x20},
		"ctrl+pageup":       {Mods: ModControl, VK: 0x21},
		"ctrl+pagedown":     {Mods: ModControl, VK: 0x22},
		"ctrl+end":          {Mods: ModControl, VK: 0x23},
		"ctrl+home":         {Mods: ModControl, VK: 0x24},
		"ctrl+insert":       {Mods: ModControl, VK: 0x2D},
		"ctrl+delete":       {Mods: ModControl, VK: 0x2E},
		" ctrl + shift + z": {Mods: ModControl | ModShift, VK: 0x5A},
	}
	for in, want := range cases {
		got, err := Parse(in)
		if err != nil {
			t.Errorf("Parse(%q): %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("Parse(%q) = %+v, want %+v", in, got, want)
		}
	}
	if ModAlt != 0x0001 || ModControl != 0x0002 || ModShift != 0x0004 || ModWin != 0x0008 || ModNoRepeat != 0x4000 {
		t.Fatal("modifier constants drifted from RegisterHotKey's documented values")
	}
}

// TestParseRefusesWhatTheDocsReserve: F12 (the debugger), the Windows key
// (the OS), a bare key (every other program), and garbage.
func TestParseRefusesWhatTheDocsReserve(t *testing.T) {
	for _, in := range []string{"ctrl+F12", "win+F9", "super+a", "F9", "ctrl", "ctrl+shift", "ctrl+F0", "ctrl+F25", "ctrl+enter", "ctrl+a+b", "", "ctrl++a", "ctrl+ctrl+a", "shift+alt+shift+F1"} {
		if _, err := Parse(in); err == nil {
			t.Errorf("Parse(%q) accepted, want a refusal", in)
		}
	}
}

// TestStringRoundTrips: what the log prints parses back to the same chord.
func TestStringRoundTrips(t *testing.T) {
	for _, in := range []string{"ctrl+shift+F9", "alt+space", "ctrl+alt+7", "shift+pagedown", "ctrl+q"} {
		b, err := Parse(in)
		if err != nil {
			t.Fatal(err)
		}
		back, err := Parse(b.String())
		if err != nil || back != b {
			t.Errorf("%q -> %q -> %+v (err %v), want %+v", in, b.String(), back, err, b)
		}
	}
}

// TestRunReturnsOnStop: the contract every OS keeps -- Run blocks until stop
// and then returns. On Windows this registers a real chord and unregisters
// it; elsewhere it logs once. Nothing is pressed either way.
func TestRunReturnsOnStop(t *testing.T) {
	b, _ := Parse("ctrl+shift+alt+F23")
	stop := make(chan struct{})
	reported := make(chan Result, 1)
	errc := make(chan error, 1)
	go func() {
		errc <- Run([]Action{{Name: "probe", Binding: b}}, func(string) {}, func(r Result) { reported <- r }, stop)
	}()
	if runtime.GOOS == "windows" {
		select {
		case r := <-reported:
			if r.Name != "probe" {
				t.Fatalf("reported %+v", r)
			}
			// A failure here is another program owning ctrl+shift+alt+F23,
			// which is not this package's bug; it is still reported, not hidden.
			if r.Err != nil {
				t.Logf("registration refused on this machine: %v", r.Err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("no registration result within 2s")
		}
	}
	close(stop)
	select {
	case err := <-errc:
		if err != nil {
			t.Fatalf("Run: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return within 2s of stop")
	}
}

// TestRunWithNoActionsJustWaits: an empty binding list registers nothing.
func TestRunWithNoActionsJustWaits(t *testing.T) {
	stop := make(chan struct{})
	errc := make(chan error, 1)
	go func() { errc <- Run(nil, func(string) {}, nil, stop) }()
	close(stop)
	select {
	case err := <-errc:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Run with no actions did not return on stop")
	}
}
