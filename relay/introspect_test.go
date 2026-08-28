package relay

// Tests for the relay's introspection view -- specifically the cross-area
// fan-out counters, which exist to answer whether relay-side area filtering is
// worth building at all. See Room's counter fields and agent_docs/risks.md.

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The cross-area fan-out counters are a MEASUREMENT, and a measurement that is
// quietly wrong is worse than none — it would be used to decide whether to
// build relay-side area filtering at all. So this pins the arithmetic against a
// room whose answer can be worked out by hand.
//
// It also pins the two things the counters must NOT do: read area_id contents
// (equality only), and change what anyone receives.
func TestCrossAreaFanoutCountersMeasureWhatTheyClaim(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	for _, id := range []string{"a", "b", "c"} {
		r.tryAdd(&Client{PlayerID: id, Conn: &recordingTransport{}})
	}

	// Everyone's area is known: a and b together in "town", c away in "cave".
	for id, area := range map[string]string{"a": "town", "b": "town", "c": "cave"} {
		r.recordState(id, protocol.State{PlayerID: id, AreaID: area})
	}

	// One state from a. Recipients are b (same area) and c (cross-area).
	const payload = 100
	got := r.stateRecipients("a", "town", "town", payload, time.Now())
	if len(got) != 2 {
		t.Fatalf("forwarded to %v, want both other members — the counters must not change delivery", got)
	}

	r.mu.Lock()
	if r.statesIn != 1 {
		t.Errorf("statesIn = %d, want 1", r.statesIn)
	}
	if r.stateRecipientsOut != 2 {
		t.Errorf("recipients = %d, want 2", r.stateRecipientsOut)
	}
	if r.stateRecipientsCross != 1 {
		t.Errorf("cross-area recipients = %d, want 1 (only c is elsewhere)", r.stateRecipientsCross)
	}
	if r.stateBytesForwarded != 2*payload {
		t.Errorf("bytes forwarded = %d, want %d", r.stateBytesForwarded, 2*payload)
	}
	if r.stateBytesCrossArea != payload {
		t.Errorf("cross-area bytes = %d, want %d", r.stateBytesCrossArea, payload)
	}
	r.mu.Unlock()

	// Through the same path -introspect uses, so the reported numbers and the
	// counted ones cannot drift apart.
	snap := r.snapshot(time.Now()).StateFanout
	if snap.DistinctAreas != 2 {
		t.Errorf("distinct areas = %d, want 2", snap.DistinctAreas)
	}
	if share := snap.SuppressibleShare(); share < 0.49 || share > 0.51 {
		t.Errorf("suppressible share = %.2f, want ~0.50", share)
	}
}

// Fail open, in both directions. An area-equality filter could only ever
// suppress when BOTH sides are known, so the counter must not claim a saving
// that a real filter could not take — the core's own rule is that an unknown
// local area filters nothing.
func TestUnknownAreaIsNeverCountedAsSuppressible(t *testing.T) {
	for _, tc := range []struct{ name, senderArea, recipientArea string }{
		{"sender area unknown", "", "town"},
		{"recipient area unknown", "town", ""},
		{"both unknown", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newRoom("emerald", "", "room1", nil)
			r.tryAdd(&Client{PlayerID: "a", Conn: &recordingTransport{}})
			r.tryAdd(&Client{PlayerID: "b", Conn: &recordingTransport{}})
			r.recordState("b", protocol.State{PlayerID: "b", AreaID: tc.recipientArea})

			r.stateRecipients("a", tc.senderArea, tc.senderArea, 100, time.Now())

			r.mu.Lock()
			defer r.mu.Unlock()
			if r.stateRecipientsCross != 0 {
				t.Fatalf("counted %d suppressible with an unknown area — a real filter must fail open here",
					r.stateRecipientsCross)
			}
		})
	}
}
