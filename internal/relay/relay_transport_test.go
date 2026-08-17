package relay

import (
	"encoding/json"
	"testing"
	"time"

	"meshghost/internal/netx"
	"meshghost/internal/protocol"
	"meshghost/internal/transport"
)

// startServerOn is startServerWith for a transport other than tcp. Nothing
// in internal/relay changes to support one: Serve takes any net.Listener,
// which is the entire reason the demultiplexing lives in
// internal/netx/udpconn instead of here.
func startServerOn(t *testing.T, s *Server, kind netx.Kind) string {
	t.Helper()
	ln, err := netx.Listen(kind, "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen %s: %v", kind, err)
	}
	t.Cleanup(func() { ln.Close() })
	go s.Serve(ln)
	return ln.Addr().String()
}

// dialTestClientOn is dialTestClient over an arbitrary transport.
func dialTestClientOn(t *testing.T, kind netx.Kind, addr, gameID, room, name string) *testClient {
	t.Helper()
	netConn, err := netx.Dial(kind, addr, 5*time.Second)
	if err != nil {
		t.Fatalf("dial %s: %v", kind, err)
	}
	conn := transport.FromConnWithLimits(netConn, protocol.MaxLineBytes, 0, 0)
	tc := &testClient{t: t, conn: conn, envs: make(chan protocol.Envelope, 16)}
	conn.OnReceive(func(payload []byte) {
		var env protocol.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			t.Errorf("client received malformed envelope: %v", err)
			return
		}
		tc.envs <- env
	})

	helloBytes, err := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          gameID,
		Room:            room,
		DisplayName:     name,
	})
	if err != nil {
		t.Fatalf("marshal hello: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: helloBytes})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	if err := conn.Send(env); err != nil {
		t.Fatalf("send hello: %v", err)
	}
	return tc
}

// TestRelayOverUDP is the step's observable outcome: an unmodified relay,
// serving a udpconn listener, carries a real session — hello, welcome, the
// join announcement, and a forwarded state — between two clients that
// never touched TCP.
//
// The point being demonstrated is as much about internal/relay as about
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

// TestRelayOverQUIC is TestRelayOverUDP for the encrypted transport. Same
// unmodified relay, a third listener type.
func TestRelayOverQUIC(t *testing.T) {
	addr := startServerOn(t, NewServer(), netx.QUIC)

	c1 := dialTestClientOn(t, netx.QUIC, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)
	if w1.PlayerID == "" {
		t.Fatal("welcome carried empty player_id over quic")
	}

	c2 := dialTestClientOn(t, netx.QUIC, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	w2 := c2.expectWelcome(timeout)
	if len(w2.Roster) != 1 || w2.Roster[0] != w1.PlayerID {
		t.Fatalf("second client's roster = %v, want [%s]", w2.Roster, w1.PlayerID)
	}

	if joinEnv := c1.next(timeout); joinEnv.Type != protocol.TypeJoin {
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
}

// TestRelayMixesAllThreeTransportsInOneRoom is the property that makes a
// per-transport choice safe to offer at all: a room may hold clients on
// different transports at once, and neither they nor the relay can tell.
// If this did not hold, picking a transport would partition the player base
// and the setting would be a trap rather than a feature.
//
// It also demonstrates the point of the whole design — three transports,
// one relay, and internal/relay contains not one line that knows which is
// which.
func TestRelayMixesAllThreeTransportsInOneRoom(t *testing.T) {
	s := NewServer()

	addrs := map[netx.Kind]string{
		netx.TCP:  startServerOn(t, s, netx.TCP),
		netx.UDP:  startServerOn(t, s, netx.UDP),
		netx.QUIC: startServerOn(t, s, netx.QUIC),
	}

	order := []netx.Kind{netx.TCP, netx.UDP, netx.QUIC}
	names := map[netx.Kind]string{netx.TCP: "alice", netx.UDP: "bob", netx.QUIC: "carol"}

	clients := map[netx.Kind]*testClient{}
	welcomes := map[netx.Kind]protocol.Welcome{}
	for i, k := range order {
		c := dialTestClientOn(t, k, addrs[k], "emerald", "shared", names[k])
		defer c.conn.Close()
		w := c.expectWelcome(timeout)
		if len(w.Roster) != i {
			t.Fatalf("%s client's roster = %v, want %d peers already present", k, w.Roster, i)
		}
		clients[k], welcomes[k] = c, w

		// Everyone already in the room sees this one join.
		for _, prev := range order[:i] {
			if env := clients[prev].next(timeout); env.Type != protocol.TypeJoin {
				t.Fatalf("%s client got %q, want a join for the %s client", prev, env.Type, k)
			}
		}
	}

	// Every sender's state must reach both other transports.
	for _, sender := range order {
		clients[sender].sendState(protocol.State{
			PlayerID: welcomes[sender].PlayerID, Seq: 1, Timestamp: 1,
			AreaID: "a", Position: []float64{1, 2}, Anim: "walk",
		})
		for _, receiver := range order {
			if receiver == sender {
				continue
			}
			env := clients[receiver].next(timeout)
			if env.Type != protocol.TypeState {
				t.Fatalf("%s client got %q, want a state forwarded from the %s client",
					receiver, env.Type, sender)
			}
		}
	}
}

// queryTransports performs the discovery exchange the way internal/core
// does and returns the relay's answer.
func queryTransports(t *testing.T, addr string, hello protocol.Hello) (protocol.Envelope, bool) {
	t.Helper()
	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	replies := make(chan protocol.Envelope, 4)
	conn.OnReceive(func(payload []byte) {
		var env protocol.Envelope
		if err := json.Unmarshal(payload, &env); err == nil {
			replies <- env
		}
	})

	hello.ProtocolVersion = protocol.Version
	hello.QueryOnly = true
	hb, err := json.Marshal(hello)
	if err != nil {
		t.Fatalf("marshal hello: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hb})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	if err := conn.Send(env); err != nil {
		t.Fatalf("send: %v", err)
	}

	select {
	case reply := <-replies:
		return reply, true
	case <-time.After(timeout):
		return protocol.Envelope{}, false
	}
}

// TestQueryOnlyReturnsTheTransportListAndDoesNotJoin covers the discovery
// exchange itself. "Does not join" is half the point: this runs before a
// client commits to a transport, so it must not consume a player_id,
// occupy a slot, or announce anything to anyone — otherwise the whole
// reason for asking first (no leave/rejoin flicker) is lost.
func TestQueryOnlyReturnsTheTransportListAndDoesNotJoin(t *testing.T) {
	s := NewServer()
	s.Offers = []protocol.TransportOffer{
		{Kind: "tcp", Port: 7777},
		{Kind: "quic", Port: 7780},
	}
	addr := startServerOn(t, s, netx.TCP)

	// A real member, so we can watch whether the query disturbs the room.
	member := dialTestClientOn(t, netx.TCP, addr, "emerald", "room1", "alice")
	defer member.conn.Close()
	member.expectWelcome(timeout)

	reply, ok := queryTransports(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "prober",
	})
	if !ok {
		t.Fatal("no reply to a query_only hello")
	}
	if reply.Type != protocol.TypeTransports {
		t.Fatalf("got %q, want %q", reply.Type, protocol.TypeTransports)
	}
	var got protocol.Transports
	if err := json.Unmarshal(reply.Payload, &got); err != nil {
		t.Fatalf("unmarshal transports: %v", err)
	}
	if len(got.Offers) != 2 || got.Offers[0].Kind != "tcp" || got.Offers[1].Port != 7780 {
		t.Fatalf("offers = %+v, want the two configured", got.Offers)
	}

	// The existing member must not have seen a join, and must still be
	// able to use the room.
	select {
	case env := <-member.envs:
		t.Fatalf("the room saw a %q from a query that should never have joined", env.Type)
	case <-time.After(300 * time.Millisecond):
	}
}

// TestQueryOnlyStillRequiresTheRoomCode is the property that made asking
// first acceptable at all. If discovery answered before the room-code
// check, it would be the relay's only pre-auth endpoint — a hole in
// exactly what the 2026-08-14 hardening pass closed. A wrong code must get
// a reject, not a transport list.
func TestQueryOnlyStillRequiresTheRoomCode(t *testing.T) {
	s := NewServer()
	s.RoomCode = "correct-horse"
	s.Offers = []protocol.TransportOffer{{Kind: "quic", Port: 7780}}
	addr := startServerOn(t, s, netx.TCP)

	reply, ok := queryTransports(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "stranger",
		RoomCode: "wrong",
	})
	if !ok {
		t.Fatal("no reply at all to a query with a wrong room code")
	}
	if reply.Type == protocol.TypeTransports {
		t.Fatal("the relay disclosed its transport list to a client that did not know the room code")
	}
	if reply.Type != protocol.TypeReject {
		t.Fatalf("got %q, want %q", reply.Type, protocol.TypeReject)
	}

	// And the correct code still works, so the check is a real gate rather
	// than discovery being broken outright.
	reply, ok = queryTransports(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "friend",
		RoomCode: "correct-horse",
	})
	if !ok || reply.Type != protocol.TypeTransports {
		t.Fatalf("a correct room code got %q, want a transport list", reply.Type)
	}
}

// TestQueryOnlyAgainstARelayWithNoOffersIsHarmless covers every existing
// test's server and any relay that could not determine its own ports: an
// empty list, not an error, which a client treats as "nothing to upgrade
// to."
func TestQueryOnlyAgainstARelayWithNoOffersIsHarmless(t *testing.T) {
	addr := startServerOn(t, NewServer(), netx.TCP)
	reply, ok := queryTransports(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "prober",
	})
	if !ok || reply.Type != protocol.TypeTransports {
		t.Fatalf("got %q, want an (empty) transport list", reply.Type)
	}
	var got protocol.Transports
	if err := json.Unmarshal(reply.Payload, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(got.Offers) != 0 {
		t.Fatalf("offers = %+v, want none", got.Offers)
	}
}

// TestJoinLogRecordsTheTransport pins that a Client carries the transport it
// arrived over. Logging-only, but it is the host's only way to tell which
// transport a given player is on now that a room can mix them — without it,
// diagnosing "why is this one player stuttering" means asking them to read
// their own client log.
func TestJoinLogRecordsTheTransport(t *testing.T) {
	s := NewServer()
	for _, tc := range []struct {
		kind netx.Kind
		want string
	}{{netx.TCP, "tcp"}, {netx.UDP, "udp"}, {netx.QUIC, "quic"}} {
		addr := startServerOn(t, s, tc.kind)
		c := dialTestClientOn(t, tc.kind, addr, "emerald", "room-"+tc.want, "alice")
		defer c.conn.Close()
		w := c.expectWelcome(timeout)

		s.mu.Lock()
		// Keyed by game_id AND name since rooms became genuinely partitioned
		// by game (see roomKey) -- a name alone no longer identifies a room.
		room := s.rooms[roomKey("emerald", "room-"+tc.want)]
		s.mu.Unlock()
		if room == nil {
			t.Fatalf("%s: room was not created", tc.kind)
		}
		room.mu.Lock()
		member := room.members[w.PlayerID]
		room.mu.Unlock()
		if member == nil {
			t.Fatalf("%s: client %s not in the room", tc.kind, w.PlayerID)
		}
		if member.transport != tc.want {
			t.Errorf("client over %s recorded transport %q, want %q", tc.kind, member.transport, tc.want)
		}
	}
}
