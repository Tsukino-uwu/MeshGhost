package protocol

import "testing"

// TestDefaultSendHzIsTheMeasuredFifteen: a test cannot check "looks smooth", so it fails if the constant changes
// without meeting the evidence, and pins the two properties the change kept.
func TestDefaultSendHzIsTheMeasuredFifteen(t *testing.T) {
	if DefaultSendHz != 15 {
		t.Errorf("DefaultSendHz = %d, want 15 -- lowered from 20 on 2026-09-01 after a watched ladder and a blind A/B; see the constant's comment before changing it", DefaultSendHz)
	}
	// The floor stayed: 10Hz is where a watcher starts seeing stutters, so the default sits above it.
	if MinSendHz != 10 {
		t.Errorf("MinSendHz = %d, want 10 -- the default was lowered to 15, the floor deliberately was not", MinSendHz)
	}
	if DefaultSendHz <= MinSendHz {
		t.Errorf("DefaultSendHz (%d) must stay above MinSendHz (%d): a default sitting on the floor leaves a room no room to degrade", DefaultSendHz, MinSendHz)
	}
	// Zero still means unspecified, so a caller that omits a rate gets the default.
	if got := ClampSendHz(0); got != DefaultSendHz {
		t.Errorf("ClampSendHz(0) = %d, want DefaultSendHz (%d)", got, DefaultSendHz)
	}
}
