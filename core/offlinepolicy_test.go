package core

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
)

// A SOLO SESSION MUST STILL BE TOLD THE SESSION POLICY (review J2).
//
// pushSessionPolicy waited for a relay Welcome before telling the adapter
// anything, which is right for a relay that has not answered YET -- an unknown
// room policy resolves to ENABLED, and guessing "make ghosts solid" is the wrong
// direction. It is wrong for a session that will never have a relay at all: there
// is no room, so the room's opinion is not unknown, it is absent, and the
// player's own setting is the whole answer.
//
// The consequence is worse than a missing message, because `chaser_contact`
// rides this same message and the chaser is explicitly a SOLO feature (ADR
// 0047): the one mode where the chaser exists without a room was the one mode
// where its opt-in could never be delivered.
func TestAnOfflineSessionIsToldItsPolicy(t *testing.T) {
	c := New()
	c.Offline = true
	c.GhostCollision = "disabled"
	c.ChaserEnabled = true
	c.ChaserContact = true

	lines := make(chan []byte, 8)
	nd := &policyTransport{lines: lines}
	c.mu.Lock()
	c.attachedAdapter = nd
	c.adapterReady = true
	c.mu.Unlock()

	c.pushSessionPolicy()

	var got bridge.SessionPolicy
	select {
	case line := <-lines:
		var env struct {
			Type    string          `json:"type"`
			Payload json.RawMessage `json:"payload"`
		}
		if err := json.Unmarshal(line, &env); err != nil {
			t.Fatalf("unmarshal envelope: %v", err)
		}
		if env.Type != string(bridge.TypeSessionPolicy) {
			t.Fatalf("first message was %q, want session_policy", env.Type)
		}
		if err := json.Unmarshal(env.Payload, &got); err != nil {
			t.Fatalf("unmarshal payload: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("an offline session was never told its policy -- and chaser_contact rides this " +
			"same message, so the one mode the chaser exists for is the one mode its opt-in " +
			"could never reach")
	}

	if got.GhostCollision != "disabled" {
		t.Fatalf("ghost_collision = %q, want the player's own setting (%q) -- there is no room "+
			"to have overridden it", got.GhostCollision, "disabled")
	}
	if got.ChaserContact != "enabled" {
		t.Fatalf("chaser_contact = %q, want enabled", got.ChaserContact)
	}
}

// AND AN ONLINE SESSION STILL WAITS. The guess this gate prevents -- telling an
// adapter to make ghosts solid because nobody has said otherwise YET -- must
// still be prevented, or the fix above trades one silent wrong answer for
// another.
func TestAnOnlineSessionStillWaitsForTheRoomsPolicy(t *testing.T) {
	c := New()
	c.Offline = false
	c.GhostCollision = ""

	lines := make(chan []byte, 8)
	nd := &policyTransport{lines: lines}
	c.mu.Lock()
	c.attachedAdapter = nd
	c.adapterReady = true
	c.relayPolicyKnown = false // no Welcome yet
	c.mu.Unlock()

	c.pushSessionPolicy()

	select {
	case line := <-lines:
		t.Fatalf("an online session was told a policy before the room answered: %s -- an unknown "+
			"room policy resolves to ENABLED, so this is the core telling an adapter to make "+
			"ghosts solid in a room that may have disabled them", line)
	case <-time.After(100 * time.Millisecond):
	}
}

type policyTransport struct {
	lines chan []byte
}

func (p *policyTransport) Send(payload []byte) error {
	b := make([]byte, len(payload))
	copy(b, payload)
	select {
	case p.lines <- b:
	default:
	}
	return nil
}

func (p *policyTransport) SendUnreliable(payload []byte) error { return p.Send(payload) }
func (p *policyTransport) OnReceive(func([]byte))              {}
func (p *policyTransport) OnDisconnect(func(error))            {}
func (p *policyTransport) OnError(func(error))                 {}
func (p *policyTransport) Close() error                        { return nil }
