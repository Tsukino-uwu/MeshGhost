package relay

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestFloodCapUnchangedByTheSendHzDefaultDrop is the regression test for the
// trap that the 2026-09-01 DefaultSendHz 20 -> 15 change walked into:
// RateLimitHeadroomMultiple used to be DERIVED as MaxMessagesPerSecond /
// protocol.DefaultSendHz, so lowering the default would have silently raised
// the multiple to 8 and widened the per-client flood cap at every configured
// rate -- a 100Hz room going from 600 to 800 messages/second as a side effect
// of a smoothness decision that had nothing to do with resource guards.
//
// The cap's behaviour, not the arithmetic link, is the invariant: these are
// the numbers the relay enforced before that change and must still enforce.
func TestFloodCapUnchangedByTheSendHzDefaultDrop(t *testing.T) {
	for _, tc := range []struct{ hz, want int }{
		{protocol.MinSendHz, 120},     // 10Hz: floor applies
		{protocol.DefaultSendHz, 120}, // 15Hz: 90 scaled, floor still applies
		{20, 120},                     // the old default: unchanged
		{50, 300},
		{protocol.MaxSendHz, 600}, // 100Hz: 6x, NOT the 8x a derived multiple would have given
	} {
		if got := MaxMessagesPerSecondFor(tc.hz); got != tc.want {
			t.Errorf("MaxMessagesPerSecondFor(%d) = %d, want %d -- the per-client flood cap must not move when a send-rate default does", tc.hz, got, tc.want)
		}
	}
	if RateLimitHeadroomMultiple != 6 {
		t.Errorf("RateLimitHeadroomMultiple = %d, want 6 -- pinned as a literal on 2026-09-01 precisely so it cannot follow DefaultSendHz; see its comment", RateLimitHeadroomMultiple)
	}
}
