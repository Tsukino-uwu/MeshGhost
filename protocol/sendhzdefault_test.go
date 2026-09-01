package protocol

import "testing"

// TestDefaultSendHzIsTheMeasuredFifteen pins the 2026-09-01 decision and,
// more importantly, the two properties that decision had to preserve.
//
// The value itself is a judgement call and a test cannot check "looks smooth"
// -- what it CAN do is fail loudly if someone changes the constant without
// meeting the evidence, since the reasoning lives in the constant's comment
// and in adapters/pseudoregalia/VERIFIED.md (the rung-by-rung ladder plus a
// five-round blind A/B against 20Hz that scored at chance).
func TestDefaultSendHzIsTheMeasuredFifteen(t *testing.T) {
	if DefaultSendHz != 15 {
		t.Errorf("DefaultSendHz = %d, want 15 -- lowered from 20 on 2026-09-01 after a watched ladder and a blind A/B; see the constant's comment before changing it", DefaultSendHz)
	}
	// The floor stayed where it was on purpose: 10Hz is where a watcher
	// starts seeing stutters, so the default sits ABOVE the floor rather
	// than on it, and the sub-10 rungs are reachable only with a dev build.
	if MinSendHz != 10 {
		t.Errorf("MinSendHz = %d, want 10 -- the default was lowered to 15, the floor deliberately was not", MinSendHz)
	}
	if DefaultSendHz <= MinSendHz {
		t.Errorf("DefaultSendHz (%d) must stay above MinSendHz (%d): a default sitting on the floor leaves a room no room to degrade", DefaultSendHz, MinSendHz)
	}
	// Zero still means "unspecified", so every caller that omits a rate gets
	// the new default rather than a silent 20 from somewhere else.
	if got := ClampSendHz(0); got != DefaultSendHz {
		t.Errorf("ClampSendHz(0) = %d, want DefaultSendHz (%d)", got, DefaultSendHz)
	}
}
