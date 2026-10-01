package relay

import (
	"encoding/json"
	"net"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/paketest"
	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// startServerOn is startServerWith for another transport: Serve takes any net.Listener, so relay needs no change.
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

func dialTestClientOn(t *testing.T, kind netx.Kind, addr, gameID, room, name string) *testClient {
	t.Helper()
	// quic has no unverified dial, and these tests are about the relay, not identity, so they trust any certificate.
	// tcp here is a raw listener (startServerOn), so it stays on the plain dial.
	var netConn net.Conn
	var err error
	if kind == netx.QUIC {
		netConn, err = netx.DialWithTLS(kind, addr, 5*time.Second, netx.TLSOptions{Verify: tlsx.TrustAnyCertificate})
	} else {
		netConn, err = netx.Dial(kind, addr, 5*time.Second)
	}
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

// TestRelayMixesAllThreeTransportsInOneRoom: a room holds clients on different transports at once, or picking a
// transport would partition the players.
func TestRelayMixesAllThreeTransportsInOneRoom(t *testing.T) {
	s := NewServer()

	// tcp and quic, plus udp under the meshghost_devudp tag; the name keeps its "three".
	order := transportKindsUnderTest
	addrs := map[netx.Kind]string{}
	for _, k := range order {
		addrs[k] = startServerOn(t, s, k)
	}
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

		for _, prev := range order[:i] {
			if env := clients[prev].next(timeout); env.Type != protocol.TypeJoin {
				t.Fatalf("%s client got %q, want a join for the %s client", prev, env.Type, k)
			}
		}
	}

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

// queryTransports performs the discovery exchange the way core does and returns the relay's answer.
func queryTransports(t *testing.T, addr string, hello protocol.Hello) (protocol.Envelope, bool) {
	t.Helper()
	return queryTransportsWithCode(t, addr, hello, "")
}

// queryTransportsWithCode is queryTransports proving a room code on the discovery leg, as the core does.
func queryTransportsWithCode(t *testing.T, addr string, hello protocol.Hello, code string) (protocol.Envelope, bool) {
	t.Helper()
	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	prover := paketest.New(t, code, "")
	hello.PakeKE1 = prover.KE1()
	replies := make(chan protocol.Envelope, 4)
	conn.OnReceive(func(payload []byte) {
		if prover.Handle(payload, conn.Send) {
			return
		}
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

// TestQueryOnlyReturnsTheTransportListAndDoesNotJoin: discovery runs before a client picks a transport, so it takes
// no player_id or slot and announces nothing, or asking first would bring back the leave/rejoin flicker.
func TestQueryOnlyReturnsTheTransportListAndDoesNotJoin(t *testing.T) {
	s := NewServer()
	s.Offers = []protocol.TransportOffer{
		{Kind: "tcp", Port: 7777},
		{Kind: "quic", Port: 7780},
	}
	addr := startServerOn(t, s, netx.TCP)

	// A real member, to watch whether the query disturbs the room.
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

	select {
	case env := <-member.envs:
		t.Fatalf("the room saw a %q from a query that should never have joined", env.Type)
	case <-time.After(300 * time.Millisecond):
	}
}

// TestQueryOnlyStillRequiresTheRoomCode: answering before the room-code check would make discovery the relay's one
// pre-auth endpoint.
func TestQueryOnlyStillRequiresTheRoomCode(t *testing.T) {
	s := NewServer()
	s.RoomCode = "correct-horse"
	s.Offers = []protocol.TransportOffer{{Kind: "quic", Port: 7780}}
	addr := startServerOn(t, s, netx.TCP)

	reply, ok := queryTransportsWithCode(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "stranger",
	}, "wrong")
	if !ok {
		t.Fatal("no reply at all to a query with a wrong room code")
	}
	if reply.Type == protocol.TypeTransports {
		t.Fatal("the relay disclosed its transport list to a client that did not know the room code")
	}
	if reply.Type != protocol.TypeReject {
		t.Fatalf("got %q, want %q", reply.Type, protocol.TypeReject)
	}

	// The correct code still works, so this is a gate rather than broken discovery.
	reply, ok = queryTransportsWithCode(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "friend",
	}, "correct-horse")
	if !ok || reply.Type != protocol.TypeTransports {
		t.Fatalf("a correct room code got %q, want a transport list", reply.Type)
	}
}

// TestQueryOnlyAgainstARelayWithNoOffersIsHarmless: a relay that could not determine its ports answers an empty list,
// which a client reads as nothing to upgrade to.
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

// TestJoinLogRecordsTheTransport: in a room that mixes transports, the join log is the host's only way to tell
// which one a player is on.
func TestJoinLogRecordsTheTransport(t *testing.T) {
	s := NewServer()
	type row struct {
		kind netx.Kind
		want string
	}
	var rows []row
	for _, k := range transportKindsUnderTest {
		rows = append(rows, row{k, k.String()})
	}
	for _, tc := range rows {
		addr := startServerOn(t, s, tc.kind)
		c := dialTestClientOn(t, tc.kind, addr, "emerald", "room-"+tc.want, "alice")
		defer c.conn.Close()
		w := c.expectWelcome(timeout)

		s.mu.Lock()
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
