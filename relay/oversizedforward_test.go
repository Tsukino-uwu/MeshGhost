package relay

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// A state can pass ValidateState and still marshal into a line no receiver will
// accept, because AreaID/Anim are bounded with len() while the relay re-encodes
// them with encoding/json -- which escapes '&', '<' and '>' to six bytes each.
// Measured 2026-09-12: an inbound line of 1185 bytes (which the relay's own
// 4096-byte inbound cap admits) leaves forwardState at 6305 bytes.
//
// The receiver's scanner is capped at protocol.MaxLineBytes, so an oversized
// line does not produce a reject -- it produces bufio.ErrTooLong and the
// connection dies, taking every ghost with it. One sender does that to every
// OTHER member of the room.
//
// The same defect was found and fixed on the world plane on 2026-09-08
// (ValidOpaqueStringOnWire); the state plane never got the equivalent.
func hostileStateLine(t *testing.T) []byte {
	t.Helper()
	// Raw '&' bytes, hand-built. encoding/json would escape them on the way
	// out and make the INBOUND line oversized too -- the asymmetry is the whole
	// point: every JSON parser accepts the raw byte.
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
	// c2's join of c1 is announced to c1, and c1's presence to c2; drain c1's.
	c1.next(timeout)

	if err := c1.conn.Send(line); err != nil {
		t.Fatalf("send hostile state: %v", err)
	}

	// Whatever reaches the victim must be something the victim could actually
	// have read. A line over MaxPayloadBytes kills their scanner.
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
