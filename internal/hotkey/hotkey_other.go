//go:build !windows

package hotkey

import "log"

// run on anything but Windows registers nothing: the actions stay reachable through the bridge's replay_control. It
// logs once so "the key does nothing" answers itself, then blocks until stop so the caller's shape is the same.
func run(actions []Action, fire func(name string), report func(Result), stop <-chan struct{}) error {
	if len(actions) > 0 {
		log.Printf("hotkey: system-wide hotkeys are Windows-only; %d binding(s) not registered on this OS", len(actions))
	}
	<-stop
	return nil
}
