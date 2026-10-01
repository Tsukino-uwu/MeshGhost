package relay

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// hostileStateLine passes ValidateState, which bounds AreaID and Anim with len(), but encoding/json re-encodes '&' as
// six bytes. A line over a receiver's scanner cap kills its connection with no reject.
func hostileStateLine(t *testing.T) []byte {
	t.Helper()
	// Hand-built: encoding/json would escape the inbound line too, and every JSON parser accepts the raw byte.
	amp := strings.Repeat("&", protocol.MaxAreaIDLen)
	return []byte(`{"type":"state","payload":{"player_id":"p1","seq":1,"timestamp":1,` +
		`"area_id":"` + amp + `","position":[1,2],"anim":"` + amp + `",` +
		`"prev":{"seq":0,"timestamp":0,"area_id":"` + amp + `","anim":"` + amp + `"}}}`)
}

func TestForwardedStateLineNeverExceedsWhatAReceiverAccepts(t *testing.T) {
	line := hostileStateLine(t)
	if len(line) > protocol.MaxLineBytes {
		t.Fatalf("premise broken: the attacker's own inbound line is %d bytes, over the %d cap -- "+
			"the relay would refuse it at the door and there is nothing to test", len(line), protocol.MaxLineBytes)
	}

	addr := startServer(t)
	c1 := dialTestClient(t, addr, "emerald", "room1", "attacker")
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	c2 := dialTestClient(t, addr, "emerald", "room1", "victim")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	// Drain the join announcing c2 to c1.
	c1.next(timeout)

	if err := c1.conn.Send(line); err != nil {
		t.Fatalf("send hostile state: %v", err)
	}

	deadline := time.After(timeout)
	for {
		select {
		case env := <-c2.envs:
			if env.Type != protocol.TypeState {
				continue
			}
			full, err := json.Marshal(env)
			if err != nil {
				t.Fatalf("re-marshal: %v", err)
			}
			if len(full) > protocol.MaxPayloadBytes {
				t.Fatalf("the relay forwarded a %d-byte state line from a %d-byte inbound one; "+
					"a receiver accepts at most %d, so this kills the victim's read loop with no reject",
					len(full), len(line), protocol.MaxPayloadBytes)
			}
			return
		case <-deadline:
			// Dropping the hostile state entirely is the correct outcome.
			return
		}
	}
}
