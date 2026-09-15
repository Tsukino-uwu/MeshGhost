//go:build meshghost_devudp

package relay

// The udp-only relay tests, compiled only under the meshghost_devudp tag (ADR
// 0065, 2026-09-15): plain udp no longer ships, and its tests run through
// dev-scripts/run-gotests-udp.bat. Moved here verbatim from
// relay_transport_test.go and welcomebudget_test.go.

import (
	"encoding/json"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// transportKindsUnderTest is every transport the relay's mixed-room and
// budget tests run against: all three under this tag.
var transportKindsUnderTest = []netx.Kind{netx.TCP, netx.UDP, netx.QUIC}

// TestAWelcomeOverUDPFitsInOneDatagram is the end-to-end assertion: on the
// shipped default transport, a player joining a room whose Welcome cannot fit
// in a datagram still gets in, and still learns about everybody.
//
// The room is not the interesting party here -- the JOINER is. It asserts on
// what the last client receives, because that is the only place the defect was
// ever visible.
func TestAWelcomeOverUDPFitsInOneDatagram(t *testing.T) {
	// Enough that the Welcome for the last joiner cannot fit one datagram, and
	// few enough that it comfortably fits protocol.MaxPayloadBytes -- so a
	// failure here can only be about the transport's budget, never the
	// protocol's. The size is asserted below rather than assumed.
	const members = 12

	// Above DefaultMaxClients (8), which is the only reason this needs saying:
	// the SHIPPED default already crosses the udp budget at 8 members whose
	// names escape (measured below), so the cap is not what protects anyone
	// here -- it just gets in this fixture's way.
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

	// The last one in is the one the room is largest for. Join it separately so
	// its Welcome and its overflow Joins can be read without the earlier
	// clients' join announcements in the way.
	last := dialTestClientOn(t, netx.UDP, addr, "emerald", "room1", maximalEscapedName())
	defer last.conn.Close()

	w := last.expectWelcome(timeout)

	// The Welcome that actually crossed the wire must fit the datagram the wire
	// carries -- measured against sendBudget for the same connection kind the
	// relay wrote it on.
	budget := sendBudget(last.conn)
	if budget >= protocol.MaxPayloadBytes {
		t.Fatalf("this client reports a send budget of %d, which is not a udp one; the fixture "+
			"is no longer testing what it says it tests", budget)
	}
	if got := welcomeLineBytes(w, budget); got > budget {
		t.Fatalf("the Welcome the relay sent is %d bytes against a udp budget of %d -- "+
			"on the real wire this message is refused and the joiner never sees it", got, budget)
	}

	// AND NOBODY MAY BE LOST TO THE TRIM. Whatever the Welcome could not carry
	// arrives as ordinary Joins, before anything else this client is sent.
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

// TestRelayOverUDP is the step's observable outcome: an unmodified relay,
// serving a udpconn listener, carries a real session — hello, welcome, the
// join announcement, and a forwarded state — between two clients that
// never touched TCP.
//
// The point being demonstrated is as much about relay as about
// UDP: this test passes with zero relay changes, because Serve takes a
// net.Listener and Room.Forward sends through the transport.Transport
// interface.
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

	// c1 sees the join for c2 — a reliable message, so it must arrive.
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
