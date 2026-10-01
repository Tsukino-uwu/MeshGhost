//go:build meshghost_devudp

package relay

// The udp-only relay tests: plain udp is a dev-build transport, and dev-scripts/run-gotests-udp.bat runs these.

import (
	"encoding/json"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// transportKindsUnderTest is all three transports under this tag.
var transportKindsUnderTest = []netx.Kind{netx.TCP, netx.UDP, netx.QUIC}

// TestAWelcomeOverUDPFitsInOneDatagram: a joiner whose Welcome cannot fit one datagram still gets in and learns about
// everybody. It asserts on what the last joiner receives, the only place the defect shows.
func TestAWelcomeOverUDPFitsInOneDatagram(t *testing.T) {
	// Past one datagram and well under protocol.MaxPayloadBytes, so a failure is the transport's budget, never the
	// protocol's.
	const members = 12

	// Above DefaultMaxClients, which protects no one here: escaping names cross the udp budget below it.
	s := NewServer()
	s.MaxClients = members + 4
	addr := startServerOn(t, s, netx.UDP)

	ids := make([]string, 0, members)
	for i := 0; i < members; i++ {
		c := dialTestClientOn(t, netx.UDP, addr, "emerald", "room1", maximalEscapedName())
		defer c.conn.Close()
		w := c.expectWelcome(timeout)
		if w.PlayerID == "" {
			t.Fatalf("member %d got a welcome with no player_id", i)
		}
		ids = append(ids, w.PlayerID)
	}

	// The last joiner sees the largest room; joined apart, so earlier announcements do not mix with its overflow Joins.
	last := dialTestClientOn(t, netx.UDP, addr, "emerald", "room1", maximalEscapedName())
	defer last.conn.Close()

	w := last.expectWelcome(timeout)

	// Measured against sendBudget for the connection kind the relay wrote it on.
	budget := sendBudget(last.conn)
	if budget >= protocol.MaxPayloadBytes {
		t.Fatalf("this client reports a send budget of %d, which is not a udp one; the fixture "+
			"is no longer testing what it says it tests", budget)
	}
	if got := welcomeLineBytes(w, budget); got > budget {
		t.Fatalf("the Welcome the relay sent is %d bytes against a udp budget of %d -- "+
			"on the real wire this message is refused and the joiner never sees it", got, budget)
	}

	// Nobody may be lost to the trim: the rest arrive as Joins before anything else.
	known := map[string]bool{}
	for _, id := range w.Roster {
		known[id] = true
	}
	for len(known) < len(ids) {
		env := last.next(timeout)
		if env.Type != protocol.TypeJoin {
			t.Fatalf("after a trimmed Welcome the joiner got %q; it knows %d of %d members and the "+
				"rest were dropped rather than handed over as joins", env.Type, len(known), len(ids))
		}
		var j protocol.Join
		if err := json.Unmarshal(env.Payload, &j); err != nil {
			t.Fatalf("unmarshal join: %v", err)
		}
		known[j.PlayerID] = true
	}
	for _, id := range ids {
		if !known[id] {
			t.Fatalf("member %s reached the joiner neither in the Welcome roster nor as a Join", id)
		}
	}
}

// TestRelayOverUDP: the unmodified relay carries a whole session over a udpconn listener, since Serve takes a
// net.Listener and Room.Forward sends through transport.Transport.
func TestRelayOverUDP(t *testing.T) {
	addr := startServerOn(t, NewServer(), netx.UDP)

	c1 := dialTestClientOn(t, netx.UDP, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)
	if w1.PlayerID == "" {
		t.Fatal("welcome carried empty player_id over udp")
	}

	c2 := dialTestClientOn(t, netx.UDP, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	w2 := c2.expectWelcome(timeout)
	if len(w2.Roster) != 1 || w2.Roster[0] != w1.PlayerID {
		t.Fatalf("second client's roster = %v, want [%s]", w2.Roster, w1.PlayerID)
	}

	// A join is reliable, so it must arrive.
	joinEnv := c1.next(timeout)
	if joinEnv.Type != protocol.TypeJoin {
		t.Fatalf("c1 got %q, want %q", joinEnv.Type, protocol.TypeJoin)
	}

	c1.sendState(protocol.State{
		PlayerID: w1.PlayerID, Seq: 1, Timestamp: 1000,
		AreaID: "emerald-0001", Position: []float64{1, 2}, Anim: "walking",
	})

	stateEnv := c2.next(timeout)
	if stateEnv.Type != protocol.TypeState {
		t.Fatalf("c2 got %q, want %q", stateEnv.Type, protocol.TypeState)
	}
	var st protocol.State
	if err := json.Unmarshal(stateEnv.Payload, &st); err != nil {
		t.Fatalf("unmarshal state: %v", err)
	}
	if st.PlayerID != w1.PlayerID || st.AreaID != "emerald-0001" || st.Anim != "walking" {
		t.Fatalf("forwarded state = %+v, want player_id=%s area_id=emerald-0001", st, w1.PlayerID)
	}
}
