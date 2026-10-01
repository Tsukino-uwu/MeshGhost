package relay

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestFloodCapUnchangedByTheSendHzDefaultDrop pins the per-client flood cap at each send rate, so changing a send-rate
// default cannot move it.
func TestFloodCapUnchangedByTheSendHzDefaultDrop(t *testing.T) {
	for _, tc := range []struct{ hz, want int }{
		{protocol.MinSendHz, 120},     // 10Hz: floor applies
		{protocol.DefaultSendHz, 120}, // 15Hz: 90 scaled, floor still applies
		{20, 120},
		{50, 300},
		{protocol.MaxSendHz, 600}, // 100Hz: 6x, not a multiple derived from DefaultSendHz
	} {
		if got := MaxMessagesPerSecondFor(tc.hz); got != tc.want {
			t.Errorf("MaxMessagesPerSecondFor(%d) = %d, want %d -- the per-client flood cap must not move when a send-rate default does", tc.hz, got, tc.want)
		}
	}
	if RateLimitHeadroomMultiple != 6 {
		t.Errorf("RateLimitHeadroomMultiple = %d, want 6 -- pinned as a literal on 2026-09-01 precisely so it cannot follow DefaultSendHz; see its comment", RateLimitHeadroomMultiple)
	}
}
