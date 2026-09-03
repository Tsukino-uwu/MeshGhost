// Package hotkey binds system-wide keys for the replay actions (ADR 0048).
//
// The core process registers them, so they work in every game with the game
// focused and no adapter has to implement a key. This file is the portable
// half: parsing a chord like "ctrl+shift+F9" into the modifier flags and the
// virtual-key code Windows wants, and the Run contract. The Windows half is
// hotkey_windows.go; every other OS gets hotkey_other.go, a no-op that logs
// once, so CI's linux/darwin builds stay green and a non-Windows client simply
// has no hotkeys.
//
// Every constant below is from learn.microsoft.com, read 2026-09-03 and cited
// in ADR 0048: RegisterHotKey's fsModifiers table and the Virtual-Key Codes
// page. Nothing here is from memory.
package hotkey

import (
	"errors"
	"fmt"
	"sort"
	"strings"
)

// Modifier flags, RegisterHotKey's fsModifiers values.
const (
	ModAlt      uint32 = 0x0001
	ModControl  uint32 = 0x0002
	ModShift    uint32 = 0x0004
	ModWin      uint32 = 0x0008
	ModNoRepeat uint32 = 0x4000
)

// Binding is one chord: the modifiers that must be held and the key.
type Binding struct {
	Mods uint32
	VK   uint32
}

// Action names a binding for the caller's dispatch: Name is what fire() gets.
type Action struct {
	Name    string
	Binding Binding
}

// Result is one registration's outcome, reported as it happens so the log
// says which chord works and which another program already owns.
type Result struct {
	Name    string
	Binding Binding
	Err     error
}

// namedKeys are the non-alphanumeric keys a chord may name, with their
// virtual-key codes from the Virtual-Key Codes page.
var namedKeys = map[string]uint32{
	"space":    0x20,
	"pageup":   0x21, // VK_PRIOR
	"pagedown": 0x22, // VK_NEXT
	"end":      0x23,
	"home":     0x24,
	"insert":   0x2D,
	"delete":   0x2E,
}

// Parse reads a chord: modifiers and one key joined by '+', any order, any
// case. Modifiers: ctrl (or control), shift, alt. Keys: F1-F24 (not F12),
// A-Z, 0-9, and the named keys above.
//
// Refused on purpose: F12, which RegisterHotKey's page reserves for the
// debugger at all times; win, which the same page says is reserved for the
// operating system; and a bare key with no modifier, because a system-wide
// hotkey takes that key away from every other program while the client runs,
// and a plain F9 that suddenly does nothing in a text editor is not a bug a
// player would trace to this file.
func Parse(s string) (Binding, error) {
	var b Binding
	parts := strings.Split(s, "+")
	keys := 0
	for _, raw := range parts {
		p := strings.ToLower(strings.TrimSpace(raw))
		switch p {
		case "":
			return b, fmt.Errorf("hotkey %q: empty part", s)
		case "ctrl", "control":
			b.Mods |= ModControl
			continue
		case "shift":
			b.Mods |= ModShift
			continue
		case "alt":
			b.Mods |= ModAlt
			continue
		case "win", "super", "meta":
			return b, fmt.Errorf("hotkey %q: chords with the Windows key are reserved by the operating system", s)
		}
		vk, err := keyCode(p)
		if err != nil {
			return b, fmt.Errorf("hotkey %q: %w", s, err)
		}
		keys++
		b.VK = vk
	}
	if keys != 1 {
		return b, fmt.Errorf("hotkey %q: exactly one key is needed (with ctrl/shift/alt in front)", s)
	}
	if b.Mods == 0 {
		return b, fmt.Errorf("hotkey %q: a system-wide key needs a modifier (ctrl, shift or alt), or it would be taken away from every other program", s)
	}
	return b, nil
}

func keyCode(p string) (uint32, error) {
	if vk, ok := namedKeys[p]; ok {
		return vk, nil
	}
	if len(p) >= 2 && p[0] == 'f' {
		n := 0
		for _, ch := range p[1:] {
			if ch < '0' || ch > '9' {
				return 0, fmt.Errorf("unknown key %q", p)
			}
			n = n*10 + int(ch-'0')
		}
		if n < 1 || n > 24 {
			return 0, fmt.Errorf("unknown key %q (F1-F24)", p)
		}
		if n == 12 {
			return 0, errors.New("F12 is reserved for the debugger at all times (RegisterHotKey's page) and cannot be a hotkey")
		}
		return 0x70 + uint32(n-1), nil // VK_F1 is 0x70
	}
	if len(p) == 1 {
		ch := p[0]
		switch {
		case ch >= 'a' && ch <= 'z':
			return 0x41 + uint32(ch-'a'), nil // 'A' is 0x41
		case ch >= '0' && ch <= '9':
			return 0x30 + uint32(ch-'0'), nil // '0' is 0x30
		}
	}
	return 0, fmt.Errorf("unknown key %q", p)
}

// String renders a binding the way a player would write it.
func (b Binding) String() string {
	var parts []string
	if b.Mods&ModControl != 0 {
		parts = append(parts, "ctrl")
	}
	if b.Mods&ModShift != 0 {
		parts = append(parts, "shift")
	}
	if b.Mods&ModAlt != 0 {
		parts = append(parts, "alt")
	}
	key := ""
	switch {
	case b.VK >= 0x70 && b.VK <= 0x87:
		key = fmt.Sprintf("F%d", b.VK-0x70+1)
	case b.VK >= 0x41 && b.VK <= 0x5A:
		key = string(rune('A' + b.VK - 0x41))
	case b.VK >= 0x30 && b.VK <= 0x39:
		key = string(rune('0' + b.VK - 0x30))
	default:
		names := make([]string, 0, len(namedKeys))
		for n := range namedKeys {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, n := range names {
			if namedKeys[n] == b.VK {
				key = n
				break
			}
		}
		if key == "" {
			key = fmt.Sprintf("0x%02X", b.VK)
		}
	}
	return strings.Join(append(parts, key), "+")
}

// Run registers every action's chord system-wide, calls fire(name) on each
// press, and blocks until stop is closed, unregistering on the way out. report
// is called once per action with the registration outcome (a chord another
// program already owns fails alone; the rest still work). On an OS with no
// implementation it logs once and blocks until stop.
func Run(actions []Action, fire func(name string), report func(Result), stop <-chan struct{}) error {
	return run(actions, fire, report, stop)
}
