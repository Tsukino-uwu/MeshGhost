package core

// B7 and its larger half, from the 2026-09-12 adversarial review (P3a-5).
//
// The "a second Welcome is protocol-illegal" guard asked whether c.playerID was
// non-empty -- a value the RELAY supplies in the very message being guarded. A
// relay that named this client "" therefore switched the guard off for the rest
// of the connection and could resend Welcome at will, resetting the roster, the
// agreed feature set, the clock offset and the resume token each time.
//
// Reading the code for that turned up the bigger omission underneath it: the
// 2026-09-12 player_id fix bounded the ids a relay hands us for our PEERS (Join
// and State, via acceptableRelayPeerID) and left the one that names US assigned
// verbatim -- so an empty, unbounded or "replay:"/"chaser:"-shaped id was this
// client's own identity for the session.

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func welcomeEnvelope(t *testing.T, w protocol.Welcome) []byte {
	t.Helper()
	payload, err := json.Marshal(w)
	if err != nil {
		t.Fatalf("marshal welcome: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeWelcome, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	return env
}

// The bypass itself: the guard must not be something the guarded party writes.
func TestAnEmptyPlayerIDCannotSwitchOffTheSecondWelcomeGuard(t *testing.T) {
	c := New()
	// A connection that has had its Welcome, named with the empty id the relay
	// chose. Before the fix this left the guard's own test false forever.
	c.playerID = ""
	c.welcomed = true
	c.roster["p2"] = 0

	welcome := make(chan protocol.Welcome, 1)
	reject := make(chan protocol.Reject, 1)
	c.handleRelayMessage(nil, welcomeEnvelope(t, protocol.Welcome{
		PlayerID: "p1", Roster: []string{"attacker-injected-id"},
	}), welcome, reject)

	c.mu.Lock()
	_, stillKnown := c.roster["p2"]
	_, injected := c.roster["attacker-injected-id"]
	c.mu.Unlock()
	if !stillKnown {
		t.Error("a second Welcome cleared the existing roster")
	}
	if injected {
		t.Error("a second Welcome seeded the roster with an id of the relay's choosing -- " +
			"the guard was keyed off a field the relay fills")
	}
	select {
	case <-welcome:
		t.Error("a second Welcome reached the handshake's welcome channel")
	default:
	}
}

// And the hole under it: this client's OWN id gets the shape check its peers'
// ids already got.
func TestTheRelayCannotNameThisClientWithAnUnusableID(t *testing.T) {
	// No invalid-UTF-8 case, and the omission is a finding rather than a gap: a
	// first draft had one and it failed, because the id goes through
	// json.Marshal here and comes back with the bad byte already replaced by
	// U+FFFD. That is exactly what ValidOpaqueString's comment says -- the UTF-8
	// half of it guards in-process callers, and is unreachable from the wire.
	cases := map[string]string{
		"empty":         "",
		"unbounded":     strings.Repeat("p", protocol.MaxHelloFieldLenForID+1),
		"replay-shaped": localPeerReplayPrefix + "1",
		"chaser-shaped": localPeerChaserPrefix + "1",
	}

	for name, id := range cases {
		t.Run(name, func(t *testing.T) {
			c := New()
			welcome := make(chan protocol.Welcome, 1)
			reject := make(chan protocol.Reject, 1)
			c.handleRelayMessage(nil, welcomeEnvelope(t, protocol.Welcome{
				PlayerID: id, Roster: []string{"p2"},
			}), welcome, reject)

			c.mu.Lock()
			welcomed, seats := c.welcomed, len(c.roster)
			c.mu.Unlock()

			if welcomed {
				t.Errorf("a welcome naming this client with an %s player_id was accepted", name)
			}
			if seats != 0 {
				t.Errorf("a refused welcome still seeded %d roster seat(s)", seats)
			}
			select {
			case <-welcome:
				t.Errorf("a welcome with an %s player_id reached the handshake, which would have "+
					"run the whole session under it", name)
			default:
			}
		})
	}

	// The converse, so this is not simply refusing every Welcome.
	t.Run("an ordinary id is accepted", func(t *testing.T) {
		c := New()
		welcome := make(chan protocol.Welcome, 1)
		reject := make(chan protocol.Reject, 1)
		c.handleRelayMessage(nil, welcomeEnvelope(t, protocol.Welcome{
			PlayerID: "p12", Roster: []string{"p2"},
		}), welcome, reject)

		c.mu.Lock()
		welcomed := c.welcomed
		_, seated := c.roster["p2"]
		c.mu.Unlock()
		if !welcomed || !seated {
			t.Fatalf("an ordinary welcome was refused (welcomed=%v, roster seated=%v)", welcomed, seated)
		}
		select {
		case <-welcome:
		default:
			t.Fatal("an ordinary welcome never reached the handshake")
		}
	})
}
