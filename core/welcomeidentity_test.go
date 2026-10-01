package core

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

// TestAnEmptyPlayerIDCannotSwitchOffTheSecondWelcomeGuard: the guard must not be something the guarded party writes,
// or a relay that names this client "" can resend Welcome at will.
func TestAnEmptyPlayerIDCannotSwitchOffTheSecondWelcomeGuard(t *testing.T) {
	c := New()
	// A connection already welcomed, named with the empty id the relay chose.
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

// TestTheRelayCannotNameThisClientWithAnUnusableID: this client's own id gets the shape check its peers' ids get.
func TestTheRelayCannotNameThisClientWithAnUnusableID(t *testing.T) {
	// No invalid-UTF-8 case: json.Marshal replaces the bad byte with U+FFFD, so that half of ValidOpaqueString
	// guards in-process callers and is unreachable from the wire.
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
