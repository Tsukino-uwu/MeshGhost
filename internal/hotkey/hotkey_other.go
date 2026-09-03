//go:build !windows

package hotkey

import "log"

// run on anything but Windows: no system-wide hotkey mechanism is built
// (ADR 0048), so the actions stay reachable through config and the bridge's
// replay_control only. Logged once so "the key does nothing" answers itself,
// then blocks until stop so the caller's shape is the same on every OS.
func run(actions []Action, fire func(name string), report func(Result), stop <-chan struct{}) error {
	if len(actions) > 0 {
		log.Printf("hotkey: system-wide hotkeys are Windows-only; %d binding(s) not registered on this OS", len(actions))
	}
	<-stop
	return nil
}
