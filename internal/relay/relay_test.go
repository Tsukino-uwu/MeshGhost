package relay

import (
	"encoding/json"
	"net"
	"testing"
	"time"

	"meshghost/internal/protocol"
	"meshghost/internal/transport"
)

// testClient is a minimal relay-protocol client used only to exercise
// Server from the outside, over a real TCP connection.
type testClient struct {
	t    *testing.T
	conn *transport.NDJSONConn
	envs chan protocol.Envelope
}

func dialTestClient(t *testing.T, addr, gameID, room, name string) *testClient {
	t.Helper()
	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	tc := &testClient{t: t, conn: conn, envs: make(chan protocol.Envelope, 16)}
	conn.OnReceive(func(payload []byte) {
		var env protocol.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			t.Errorf("client received malformed envelope: %v", err)
			return
		}
		tc.envs <- env
	})

	hello, err := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          gameID,
		Room:            room,
		DisplayName:     name,
	})
	if err != nil {
		t.Fatalf("marshal hello: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	if err := conn.Send(env); err != nil {
		t.Fatalf("send hello: %v", err)
	}
	return tc
}

func (tc *testClient) next(timeout time.Duration) protocol.Envelope {
	tc.t.Helper()
	select {
	case env := <-tc.envs:
		return env
	case <-time.After(timeout):
		tc.t.Fatal("timed out waiting for message")
		return protocol.Envelope{}
	}
}

func (tc *testClient) expectWelcome(timeout time.Duration) protocol.Welcome {
	tc.t.Helper()
	env := tc.next(timeout)
	if env.Type != protocol.TypeWelcome {
		tc.t.Fatalf("got message type %q, want %q", env.Type, protocol.TypeWelcome)
	}
	var w protocol.Welcome
	if err := json.Unmarshal(env.Payload, &w); err != nil {
		tc.t.Fatalf("unmarshal welcome: %v", err)
	}
	return w
}

func (tc *testClient) sendState(st protocol.State) {
	tc.t.Helper()
	payload, err := json.Marshal(st)
	if err != nil {
		tc.t.Fatalf("marshal state: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeState, Payload: payload})
	if err != nil {
		tc.t.Fatalf("marshal envelope: %v", err)
	}
	if err := tc.conn.Send(env); err != nil {
		tc.t.Fatalf("send state: %v", err)
	}
}

func startServer(t *testing.T) string {
	t.Helper()
	return startServerWith(t, NewServer())
}

func startServerWith(t *testing.T, s *Server) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go s.Serve(ln)
	return ln.Addr().String()
}

const timeout = 2 * time.Second

// TestHelloWelcome confirms a single client joining an empty room gets a
// Welcome with its assigned player_id and an empty roster.
func TestHelloWelcome(t *testing.T) {
	addr := startServer(t)
	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()

	w := c1.expectWelcome(timeout)
	if w.PlayerID == "" {
		t.Fatal("welcome carried empty player_id")
	}
	if len(w.Roster) != 0 {
		t.Fatalf("roster = %v, want empty (first client in room)", w.Roster)
	}
}

// TestSecondClientSeesJoinAndState is the "see on second client" milestone:
// two clients join the same room, the second sees a Join for the first
// (roster) and its own Welcome shows the first client already present, then
// a State sent by one arrives at the other.
func TestSecondClientSeesJoinAndState(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	w2 := c2.expectWelcome(timeout)

	if len(w2.Roster) != 1 || w2.Roster[0] != w1.PlayerID {
		t.Fatalf("second client's welcome roster = %v, want [%s]", w2.Roster, w1.PlayerID)
	}

	// c1 should observe a join announcing c2.
	joinEnv := c1.next(timeout)
	if joinEnv.Type != protocol.TypeJoin {
		t.Fatalf("c1 got message type %q, want %q", joinEnv.Type, protocol.TypeJoin)
	}
	var join protocol.Join
	if err := json.Unmarshal(joinEnv.Payload, &join); err != nil {
		t.Fatalf("unmarshal join: %v", err)
	}
	if join.PlayerID != w2.PlayerID {
		t.Fatalf("join.PlayerID = %q, want %q", join.PlayerID, w2.PlayerID)
	}

	// c1 sends a state update; c2 should receive it forwarded, with the
	// sender's assigned player_id intact.
	c1.sendState(protocol.State{
		PlayerID:  w1.PlayerID,
		Seq:       1,
		Timestamp: 1000,
		AreaID:    "emerald-0001",
		Position:  []float64{1, 2},
		Anim:      "walking",
	})

	stateEnv := c2.next(timeout)
	if stateEnv.Type != protocol.TypeState {
		t.Fatalf("c2 got message type %q, want %q", stateEnv.Type, protocol.TypeState)
	}
	var st protocol.State
	if err := json.Unmarshal(stateEnv.Payload, &st); err != nil {
		t.Fatalf("unmarshal state: %v", err)
	}
	if st.PlayerID != w1.PlayerID || st.AreaID != "emerald-0001" || st.Anim != "walking" {
		t.Fatalf("forwarded state = %+v, want player_id=%s area_id=emerald-0001 anim=walking", st, w1.PlayerID)
	}

	// c1 must not receive its own state back.
	select {
	case env := <-c1.envs:
		t.Fatalf("c1 unexpectedly received %q; state should not echo to sender", env.Type)
	case <-time.After(200 * time.Millisecond):
	}
}

// TestLeaveOnDisconnect confirms a client closing its connection produces a
// Leave for the remaining room member — this is what drives
// despawn_remote on the adapter side of the bridge.
func TestLeaveOnDisconnect(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)
	_ = w1

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	w2 := c2.expectWelcome(timeout)
	c1.next(timeout) // consume the join for c2

	if err := c2.conn.Close(); err != nil {
		t.Fatalf("close c2: %v", err)
	}

	leaveEnv := c1.next(timeout)
	if leaveEnv.Type != protocol.TypeLeave {
		t.Fatalf("c1 got message type %q, want %q", leaveEnv.Type, protocol.TypeLeave)
	}
	var leave protocol.Leave
	if err := json.Unmarshal(leaveEnv.Payload, &leave); err != nil {
		t.Fatalf("unmarshal leave: %v", err)
	}
	if leave.PlayerID != w2.PlayerID {
		t.Fatalf("leave.PlayerID = %q, want %q", leave.PlayerID, w2.PlayerID)
	}
}

// TestMismatchedGameIDRejected confirms a room's game_id is sticky: a
// second client claiming a different game_id for the same room name is
// refused rather than silently mixed in.
func TestMismatchedGameIDRejected(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	disconnected := make(chan struct{})
	conn.OnDisconnect(func(err error) { close(disconnected) })

	hello, _ := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "tevi",
		Room:            "room1",
		DisplayName:     "carol",
	})
	env, _ := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
	if err := conn.Send(env); err != nil {
		t.Fatalf("send hello: %v", err)
	}

	select {
	case <-disconnected:
	case <-time.After(timeout):
		t.Fatal("timed out waiting for connection to be refused")
	}
}

// TestLoopbackEchoesGhost confirms the Phase 3 -loopback flag: a lone
// client's own State comes back to it under a synthetic "<id>-ghost"
// player_id, so the loopback milestone exercises a real relay round trip
// without a second physical client.
func TestLoopbackEchoesGhost(t *testing.T) {
	s := NewServer()
	s.Loopback = true
	addr := startServerWith(t, s)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	c1.sendState(protocol.State{
		PlayerID:  w1.PlayerID,
		Seq:       1,
		Timestamp: 1000,
		AreaID:    "0:9",
		Position:  []float64{5, 6},
		Anim:      "walking",
	})

	env := c1.next(timeout)
	if env.Type != protocol.TypeState {
		t.Fatalf("got message type %q, want %q", env.Type, protocol.TypeState)
	}
	var st protocol.State
	if err := json.Unmarshal(env.Payload, &st); err != nil {
		t.Fatalf("unmarshal state: %v", err)
	}
	wantGhost := w1.PlayerID + "-ghost"
	if st.PlayerID != wantGhost {
		t.Fatalf("echoed player_id = %q, want %q", st.PlayerID, wantGhost)
	}
	if st.AreaID != "0:9" || len(st.Position) != 2 || st.Position[0] != 5 || st.Position[1] != 6 {
		t.Fatalf("echoed state = %+v, want area_id=0:9 position=[5 6]", st)
	}
}

// TestNoLoopbackNoEcho confirms the default (flag off) behavior is
// unchanged: a lone client sending State receives nothing back, matching
// the existing "must not receive its own state back" guarantee.
func TestNoLoopbackNoEcho(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	c1.sendState(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{1, 1}, Anim: "idle"})

	select {
	case env := <-c1.envs:
		t.Fatalf("c1 unexpectedly received %q with -loopback off", env.Type)
	case <-time.After(200 * time.Millisecond):
	}
}

// TestServerStampsPlayerID confirms the relay overwrites State.PlayerID
// with the connection's own assigned id rather than trusting the payload —
// a client claiming a different id must not be forwarded under that id.
func TestServerStampsPlayerID(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.next(timeout) // consume c1's join notification for c2

	c1.sendState(protocol.State{PlayerID: "someone-else", AreaID: "a", Position: []float64{1, 1}, Anim: "idle"})

	env := c2.next(timeout)
	var st protocol.State
	if err := json.Unmarshal(env.Payload, &st); err != nil {
		t.Fatalf("unmarshal state: %v", err)
	}
	if st.PlayerID != w1.PlayerID {
		t.Fatalf("forwarded player_id = %q, want %q (server-stamped, not client-claimed)", st.PlayerID, w1.PlayerID)
	}
}

// TestOversizedPositionDropped confirms a State whose Position exceeds
// MaxPositionLen is dropped rather than forwarded — one of the Limits
// agent_docs/contract.md says are "enforced starting Phase 3".
func TestOversizedPositionDropped(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.next(timeout)

	oversized := make([]float64, MaxPositionLen+1)
	c1.sendState(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: oversized, Anim: "idle"})

	select {
	case env := <-c2.envs:
		t.Fatalf("c2 unexpectedly received %q for an oversized-position state", env.Type)
	case <-time.After(200 * time.Millisecond):
	}
}

// TestOversizedLineClosesConnection confirms a client sending a line over
// MaxLineBytes gets disconnected rather than silently accepted.
func TestOversizedLineClosesConnection(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	disconnected := make(chan struct{})
	c1.conn.OnDisconnect(func(err error) { close(disconnected) })

	huge := protocol.State{
		PlayerID: "p1",
		AreaID:   "a",
		Position: []float64{1, 1},
		Anim:     "idle",
		Extras:   map[string]any{"junk": string(make([]byte, MaxLineBytes+1))},
	}
	c1.sendState(huge)

	select {
	case <-disconnected:
	case <-time.After(timeout):
		t.Fatal("timed out waiting for oversized-line connection to close")
	}
}

// TestRoomFullRejectsExtraClient confirms a room at MaxClientsPerRoom
// refuses an additional join rather than growing unbounded.
func TestRoomFullRejectsExtraClient(t *testing.T) {
	addr := startServer(t)

	var clients []*testClient
	for i := 0; i < MaxClientsPerRoom; i++ {
		c := dialTestClient(t, addr, "emerald", "room1", "member")
		defer c.conn.Close()
		c.expectWelcome(timeout)
		clients = append(clients, c)
	}

	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	disconnected := make(chan struct{})
	conn.OnDisconnect(func(err error) { close(disconnected) })

	hello, _ := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "one-too-many",
	})
	env, _ := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
	if err := conn.Send(env); err != nil {
		t.Fatalf("send hello: %v", err)
	}

	select {
	case <-disconnected:
	case <-time.After(timeout):
		t.Fatal("timed out waiting for the over-capacity join to be refused")
	}
}
