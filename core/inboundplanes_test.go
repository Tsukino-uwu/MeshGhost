package core

// An unasked-for plane is not a stray message: the event lane does not coalesce, so a relay repeating one fills the
// adapter queue, and a full queue tears the bridge down as a stuck adapter.

import (
	"encoding/json"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func onlineEnvelope(t *testing.T, kind protocol.MessageType, payload any) protocol.Envelope {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal %s: %v", kind, err)
	}
	return protocol.Envelope{Type: kind, Payload: b}
}

// A cosmetic room that negotiated nothing, the configuration almost every player is in.
func TestAnOptInPlaneNeverReachesAGameThatDidNotAskForIt(t *testing.T) {
	cases := []struct {
		name    string
		kind    protocol.MessageType
		payload any
	}{
		{"event", protocol.TypeEvent, protocol.Event{}},
		{"lease_state", protocol.TypeLeaseState, protocol.LeaseState{Key: "door", Holder: "p1"}},
		{"escrow_state", protocol.TypeEscrowState, protocol.EscrowState{
			ID: "trade-1", Phase: protocol.EscrowPhaseOpen, Parties: []string{"p1", "p2"}}},
		{"world_state", protocol.TypeWorldState, protocol.WorldState{Authority: "sim", Seq: 1}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := New()
			delivered := false
			c.OnEvent = func(protocol.Event) { delivered = true }
			c.OnLeaseState = func(protocol.LeaseState) { delivered = true }
			c.OnEscrowState = func(protocol.EscrowState) { delivered = true }
			c.OnWorldState = func(protocol.WorldState) { delivered = true }

			env := onlineEnvelope(t, tc.kind, tc.payload)
			// Still claimed, so handleRelayMessage does not take a refused plane for an unknown type.
			if handled := c.handleOnlineMessage(env); !handled {
				t.Fatalf("handleOnlineMessage did not claim a %s at all", tc.name)
			}
			if delivered {
				t.Fatalf("a %s reached the game in a room that negotiated no such plane -- "+
					"repeated, this fills the non-coalescing adapter lane and the core tears "+
					"the bridge down as a stuck adapter", tc.name)
			}
		})
	}
}

// The converse, so the gate is not simply refusing everything.
func TestAnOptInPlaneStillArrivesWhenBothSidesAgreedIt(t *testing.T) {
	cases := []struct {
		name    string
		feature string
		kind    protocol.MessageType
		payload any
	}{
		{"event", protocol.FeatureEventV1, protocol.TypeEvent, protocol.Event{}},
		{"lease_state", protocol.FeatureLeaseV1, protocol.TypeLeaseState,
			protocol.LeaseState{Key: "door", Holder: "p1", Reason: protocol.LeaseGranted}},
		{"escrow_state", protocol.FeatureEscrowV1, protocol.TypeEscrowState, protocol.EscrowState{
			ID: "trade-1", Phase: protocol.EscrowPhaseOpen, Parties: []string{"p1", "p2"}}},
		{"world_state", protocol.FeatureWorldV1, protocol.TypeWorldState,
			protocol.WorldState{Authority: "sim", Seq: 1, Reason: protocol.WorldSnapshot}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := New()
			c.Features = []string{tc.feature}
			c.mu.Lock()
			c.activeFeatures = []string{tc.feature}
			c.mu.Unlock()

			delivered := false
			c.OnEvent = func(protocol.Event) { delivered = true }
			c.OnLeaseState = func(protocol.LeaseState) { delivered = true }
			c.OnEscrowState = func(protocol.EscrowState) { delivered = true }
			c.OnWorldState = func(protocol.WorldState) { delivered = true }

			c.handleOnlineMessage(onlineEnvelope(t, tc.kind, tc.payload))
			if !delivered {
				t.Fatalf("a %s was dropped in a room that agreed %s on both sides", tc.name, tc.feature)
			}
		})
	}
}

// TestARelayCannotTurnAPlaneOnByItself: a relay writes Welcome.Features itself, so a gate asking only "did the room
// agree it" is one it opens for free.
func TestARelayCannotTurnAPlaneOnByItself(t *testing.T) {
	c := New()
	// The relay claims every plane in its Welcome; this side asked for none.
	c.mu.Lock()
	c.activeFeatures = []string{
		protocol.FeatureEventV1, protocol.FeatureLeaseV1,
		protocol.FeatureEscrowV1, protocol.FeatureWorldV1,
	}
	c.mu.Unlock()

	delivered := 0
	c.OnEvent = func(protocol.Event) { delivered++ }
	c.OnLeaseState = func(protocol.LeaseState) { delivered++ }
	c.OnEscrowState = func(protocol.EscrowState) { delivered++ }
	c.OnWorldState = func(protocol.WorldState) { delivered++ }

	c.handleOnlineMessage(onlineEnvelope(t, protocol.TypeEvent, protocol.Event{}))
	c.handleOnlineMessage(onlineEnvelope(t, protocol.TypeLeaseState, protocol.LeaseState{Key: "k"}))
	c.handleOnlineMessage(onlineEnvelope(t, protocol.TypeEscrowState,
		protocol.EscrowState{ID: "t", Phase: protocol.EscrowPhaseOpen}))
	c.handleOnlineMessage(onlineEnvelope(t, protocol.TypeWorldState,
		protocol.WorldState{Authority: "sim", Seq: 1}))

	if delivered != 0 {
		t.Fatalf("%d plane message(s) reached the game on the relay's say-so alone -- "+
			"activeFeatures comes out of the relay's own Welcome, so it cannot be the whole gate", delivered)
	}
}

func TestAHostileLeaseOrEscrowStateIsCheckedOnReceive(t *testing.T) {
	long := make([]byte, protocol.MaxLeaseKeyLen+1)
	for i := range long {
		long[i] = 'k'
	}
	tooManyParties := []string{"p1", "p2", "p3"}

	t.Run("lease_state", func(t *testing.T) {
		bad := []protocol.LeaseState{
			{Key: ""},
			{Key: string(long)},
			{Key: "door", Holder: string(long)},
			{Key: "door", Reason: string(long)},
		}
		for i, st := range bad {
			c := New()
			c.Features = []string{protocol.FeatureLeaseV1}
			c.mu.Lock()
			c.activeFeatures = []string{protocol.FeatureLeaseV1}
			c.mu.Unlock()
			delivered := false
			c.OnLeaseState = func(protocol.LeaseState) { delivered = true }
			c.handleOnlineMessage(onlineEnvelope(t, protocol.TypeLeaseState, st))
			if delivered {
				t.Errorf("case %d: an out-of-bounds lease_state was handed to the game unchecked", i)
			}
		}
	})

	t.Run("escrow_state", func(t *testing.T) {
		bad := []protocol.EscrowState{
			{ID: "", Phase: protocol.EscrowPhaseOpen},
			{ID: "t", Phase: "not-a-phase"},
			{ID: "t", Phase: protocol.EscrowPhaseOpen, Parties: tooManyParties},
			{ID: "t", Phase: protocol.EscrowPhaseOpen, Deposited: tooManyParties},
			{ID: "t", Phase: protocol.EscrowPhaseCommitted, Blobs: map[string]json.RawMessage{
				"p1": json.RawMessage("1"), "p2": json.RawMessage("2"), "p3": json.RawMessage("3"),
			}},
		}
		for i, st := range bad {
			c := New()
			c.Features = []string{protocol.FeatureEscrowV1}
			c.mu.Lock()
			c.activeFeatures = []string{protocol.FeatureEscrowV1}
			c.mu.Unlock()
			delivered := false
			c.OnEscrowState = func(protocol.EscrowState) { delivered = true }
			c.handleOnlineMessage(onlineEnvelope(t, protocol.TypeEscrowState, st))
			if delivered {
				t.Errorf("case %d: an out-of-bounds escrow_state was handed to the game unchecked", i)
			}
		}
	})
}
