package relay

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/paketest"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// testClient exercises Server from the outside, over a real TCP connection.
type testClient struct {
	t    *testing.T
	conn *transport.NDJSONConn
	envs chan protocol.Envelope
}

func dialTestClient(t *testing.T, addr, gameID, room, name string) *testClient {
	t.Helper()
	return dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          gameID,
		Room:            room,
		DisplayName:     name,
	})
}

func dialTestClientWithHello(t *testing.T, addr string, hello protocol.Hello) *testClient {
	t.Helper()
	return dialTestClientWithCode(t, addr, hello, "")
}

// dialTestClientWithCode proves code: KE2 is answered from the receive loop against pake.UnboundIdentity, and a wrong
// code sends an unusable KE3 so the test reads the relay's own refusal.
func dialTestClientWithCode(t *testing.T, addr string, hello protocol.Hello, code string) *testClient {
	t.Helper()
	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	prover := paketest.New(t, code, "")
	hello.PakeKE1 = prover.KE1()
	tc := &testClient{t: t, conn: conn, envs: make(chan protocol.Envelope, 16)}
	conn.OnReceive(func(payload []byte) {
		if prover.Handle(payload, conn.Send) {
			return
		}
		var env protocol.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			t.Errorf("client received malformed envelope: %v", err)
			return
		}
		tc.envs <- env
	})

	if hello.ProtocolVersion == 0 {
		hello.ProtocolVersion = protocol.Version
	}
	helloBytes, err := json.Marshal(hello)
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

	select {
	case env := <-c1.envs:
		t.Fatalf("c1 unexpectedly received %q; state should not echo to sender", env.Type)
	case <-time.After(200 * time.Millisecond):
	}
}

// TestLeaveOnDisconnect: the Leave is what drives despawn_remote on the adapter side.
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

// TestSameRoomNameInDifferentGamesAreSeparateRooms: rooms are keyed by game_id and name, so two games asking for the
// same room name (the shipped default) get two rooms that cannot see each other.
func TestSameRoomNameInDifferentGamesAreSeparateRooms(t *testing.T) {
	addr := startServer(t)

	emerald := dialTestClient(t, addr, "emerald", "default", "alice")
	defer emerald.conn.Close()
	wEmerald := emerald.expectWelcome(timeout)

	tevi := dialTestClient(t, addr, "tevi", "default", "bob")
	defer tevi.conn.Close()
	wTevi := tevi.expectWelcome(timeout)
	if wTevi.PlayerID == "" {
		t.Fatal("a second game was refused the default room name")
	}

	if len(wTevi.Roster) != 0 {
		t.Fatalf("tevi's roster = %v, want empty — it must not see the emerald room", wTevi.Roster)
	}
	emerald.expectNothingOfType(protocol.TypeJoin, 300*time.Millisecond)

	tevi.sendState(protocol.State{AreaID: "tevi-zone", Position: []float64{1, 2}})
	emerald.expectNothingOfType(protocol.TypeState, 300*time.Millisecond)

	if wEmerald.PlayerID == wTevi.PlayerID {
		t.Fatal("both clients were given the same player_id")
	}
}

// TestLoopbackEchoesGhost: -loopback echoes a lone client's state under a synthetic "<id>-ghost" id, a real relay
// round trip without a second client.
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

	wantGhost := w1.PlayerID + "-ghost"

	// The Join must precede the first echo, or core.storeRemoteState drops the state as from an unannounced id.
	joinEnv := c1.next(timeout)
	if joinEnv.Type != protocol.TypeJoin {
		t.Fatalf("got message type %q, want %q (loopback ghost join)", joinEnv.Type, protocol.TypeJoin)
	}
	var join protocol.Join
	if err := json.Unmarshal(joinEnv.Payload, &join); err != nil {
		t.Fatalf("unmarshal join: %v", err)
	}
	if join.PlayerID != wantGhost {
		t.Fatalf("ghost join player_id = %q, want %q", join.PlayerID, wantGhost)
	}
	// The sender's own nametag comes back with a "-ghost" suffix, so nametags can be judged in loopback.
	if join.Nametag == nil {
		t.Fatalf("ghost join carried no nametag; want the sender's own with a -ghost suffix")
	}
	if join.Nametag.Name != "alice-ghost" {
		t.Fatalf("ghost join nametag = %q, want %q", join.Nametag.Name, "alice-ghost")
	}

	env := c1.next(timeout)
	if env.Type != protocol.TypeState {
		t.Fatalf("got message type %q, want %q", env.Type, protocol.TypeState)
	}
	var st protocol.State
	if err := json.Unmarshal(env.Payload, &st); err != nil {
		t.Fatalf("unmarshal state: %v", err)
	}
	if st.PlayerID != wantGhost {
		t.Fatalf("echoed player_id = %q, want %q", st.PlayerID, wantGhost)
	}
	if st.AreaID != "0:9" || len(st.Position) != 2 || st.Position[0] != 5 || st.Position[1] != 6 {
		t.Fatalf("echoed state = %+v, want area_id=0:9 position=[5 6]", st)
	}

	// A second state must not re-send the Join.
	c1.sendState(protocol.State{
		PlayerID:  w1.PlayerID,
		Seq:       2,
		Timestamp: 2000,
		AreaID:    "0:9",
		Position:  []float64{7, 8},
		Anim:      "walking",
	})
	env2 := c1.next(timeout)
	if env2.Type != protocol.TypeState {
		t.Fatalf("second echo: got message type %q, want %q (no repeat join)", env2.Type, protocol.TypeState)
	}
}

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

// TestJoinIsNeverSentForAPlayerAlreadyInTheWelcomeRoster states the invariant, not the mechanism. Clients join
// concurrently to widen the window, which in practice only the race detector's scheduling opens.
func TestJoinIsNeverSentForAPlayerAlreadyInTheWelcomeRoster(t *testing.T) {
	addr := startServer(t)

	const clients = 6
	type observation struct {
		roster map[string]bool
		client *testClient
	}
	observations := make([]*observation, clients)

	// testClient's helpers call t.Fatal, which is invalid off the test goroutine, so these dial at the transport level
	// and report through a channel.
	var wg sync.WaitGroup
	var mu sync.Mutex
	failures := make(chan error, clients)
	for i := 0; i < clients; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()

			conn, err := transport.Dial(addr)
			if err != nil {
				failures <- fmt.Errorf("client %d: dial: %w", i, err)
				return
			}
			tc := &testClient{t: t, conn: conn, envs: make(chan protocol.Envelope, 64)}
			conn.OnReceive(func(payload []byte) {
				var env protocol.Envelope
				if err := json.Unmarshal(payload, &env); err == nil {
					tc.envs <- env
				}
			})

			hello, _ := json.Marshal(protocol.Hello{
				ProtocolVersion: protocol.Version,
				GameID:          "emerald",
				Room:            "room1",
				DisplayName:     fmt.Sprintf("p%d", i),
			})
			env, _ := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
			if err := conn.Send(env); err != nil {
				failures <- fmt.Errorf("client %d: send hello: %w", i, err)
				return
			}

			// Client.holdUntilWelcome puts the welcome first; a join that still arrived early counts as already known.
			deadline := time.After(timeout)
			early := make(map[string]bool)
			for observations[i] == nil {
				select {
				case e := <-tc.envs:
					if e.Type == protocol.TypeJoin {
						var j protocol.Join
						if err := json.Unmarshal(e.Payload, &j); err == nil {
							early[j.PlayerID] = true
						}
						continue
					}
					if e.Type != protocol.TypeWelcome {
						failures <- fmt.Errorf("client %d: got %q before welcome", i, e.Type)
						return
					}
					var w protocol.Welcome
					if err := json.Unmarshal(e.Payload, &w); err != nil {
						failures <- fmt.Errorf("client %d: unmarshal welcome: %w", i, err)
						return
					}
					seen := early
					for _, id := range w.Roster {
						seen[id] = true
					}
					mu.Lock()
					observations[i] = &observation{roster: seen, client: tc}
					mu.Unlock()
				case <-deadline:
					failures <- fmt.Errorf("client %d: timed out waiting for welcome", i)
					return
				}
			}
		}(i)
	}
	wg.Wait()
	close(failures)
	for err := range failures {
		t.Fatal(err)
	}

	// Let every join that is going to be delivered arrive before judging.
	time.Sleep(200 * time.Millisecond)

	for i, obs := range observations {
		if obs == nil {
			continue
		}
		defer obs.client.conn.Close()
	drain:
		for {
			select {
			case env := <-obs.client.envs:
				if env.Type != protocol.TypeJoin {
					continue
				}
				var j protocol.Join
				if err := json.Unmarshal(env.Payload, &j); err != nil {
					t.Fatalf("unmarshal join: %v", err)
				}
				if obs.roster[j.PlayerID] {
					t.Fatalf("client %d received a join for %q, which was already in its welcome roster",
						i, j.PlayerID)
				}
			default:
				break drain
			}
		}
	}
}

func TestOversizedPositionDropped(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.next(timeout)

	oversized := make([]float64, protocol.MaxPositionLen+1)
	c1.sendState(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: oversized, Anim: "idle"})

	select {
	case env := <-c2.envs:
		t.Fatalf("c2 unexpectedly received %q for an oversized-position state", env.Type)
	case <-time.After(200 * time.Millisecond):
	}
}

// TestOutOfRangePositionDropped: 1e308 is valid JSON and survives []float64, but is +Inf once an adapter narrows it
// to float32. NaN and Inf have no JSON literal, so protocol's and core's own tests cover them.
func TestOutOfRangePositionDropped(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.next(timeout)

	c1.sendState(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{protocol.MaxPositionComponent + 1, 0}, Anim: "idle"})

	select {
	case env := <-c2.envs:
		t.Fatalf("c2 unexpectedly received %q for an out-of-range position", env.Type)
	case <-time.After(200 * time.Millisecond):
	}
}

func TestOversizedOrientationDropped(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.next(timeout)

	oversized := json.RawMessage(`"` + strings.Repeat("a", protocol.MaxOrientationBytes+1) + `"`)
	c1.sendState(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{1, 1}, Anim: "idle", Orientation: oversized})

	select {
	case env := <-c2.envs:
		t.Fatalf("c2 unexpectedly received %q for an oversized-orientation state", env.Type)
	case <-time.After(200 * time.Millisecond):
	}
}

func TestOversizedAnimDropped(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.next(timeout)

	c1.sendState(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{1, 1}, Anim: strings.Repeat("a", protocol.MaxAnimLen+1)})

	select {
	case env := <-c2.envs:
		t.Fatalf("c2 unexpectedly received %q for an oversized-anim state", env.Type)
	case <-time.After(200 * time.Millisecond):
	}
}

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
		Extras:   map[string]any{"junk": string(make([]byte, protocol.MaxLineBytes+1))},
	}
	c1.sendState(huge)

	select {
	case <-disconnected:
	case <-time.After(timeout):
		t.Fatal("timed out waiting for oversized-line connection to close")
	}
}

func TestServerFullRejectsExtraClient(t *testing.T) {
	addr := startServer(t)

	var clients []*testClient
	for i := 0; i < DefaultMaxClients; i++ {
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

// TestMismatchedProtocolVersionRejected: a version below protocol.MinProtocolVersion is refused.
func TestMismatchedProtocolVersionRejected(t *testing.T) {
	addr := startServer(t)

	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	disconnected := make(chan struct{})
	conn.OnDisconnect(func(err error) { close(disconnected) })

	hello, _ := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.MinProtocolVersion - 1,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "alice",
	})
	env, _ := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
	if err := conn.Send(env); err != nil {
		t.Fatalf("send hello: %v", err)
	}

	select {
	case <-disconnected:
	case <-time.After(timeout):
		t.Fatal("timed out waiting for version-mismatch connection to be refused")
	}
}

// A newer client joins: unknown JSON fields are ignored, and refusing it would make every relay upgrade a
// synchronised one.
func TestAClientNewerThanTheRelayIsAccepted(t *testing.T) {
	addr := startServer(t)

	tc := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version + 5,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "alice",
	})
	defer tc.conn.Close()

	env := tc.next(timeout)
	if env.Type != protocol.TypeWelcome {
		t.Fatalf("a client %d versions ahead of the relay got %q, want a welcome -- the check is a "+
			"FLOOR, and refusing a newer peer makes every relay upgrade a synchronised one",
			5, env.Type)
	}
}

// The relay's own version lets a client apply the floor the other way, refusing a relay below its minimum.
func TestTheWelcomeCarriesTheRelaysProtocolVersion(t *testing.T) {
	addr := startServer(t)

	tc := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer tc.conn.Close()

	env := tc.next(timeout)
	if env.Type != protocol.TypeWelcome {
		t.Fatalf("got %q, want welcome", env.Type)
	}
	var w protocol.Welcome
	if err := json.Unmarshal(env.Payload, &w); err != nil {
		t.Fatalf("unmarshal welcome: %v", err)
	}
	if w.ProtocolVersion != protocol.Version {
		t.Fatalf("welcome advertised protocol version %d, want %d -- without it a client cannot "+
			"tell an ancient relay from a current one and the floor only runs one way",
			w.ProtocolVersion, protocol.Version)
	}
}

func TestOversizedExtrasDropped(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.next(timeout)

	// Printable bytes: JSON escapes a zero byte as six characters, which would hit MaxLineBytes and close the
	// connection instead of reaching the MaxExtrasBytes drop.
	oversized := map[string]any{"junk": strings.Repeat("a", protocol.MaxExtrasBytes+1)}
	c1.sendState(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{1, 1}, Anim: "idle", Extras: oversized})

	select {
	case env := <-c2.envs:
		t.Fatalf("c2 unexpectedly received %q for an oversized-extras state", env.Type)
	case <-time.After(200 * time.Millisecond):
	}
}

func TestRateLimitClosesConnection(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	disconnected := make(chan struct{})
	c1.conn.OnDisconnect(func(err error) { close(disconnected) })

	// Raw sends, not sendState: a later send is expected to fail once the relay has closed the connection.
	payload, err := json.Marshal(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{1, 1}, Anim: "idle"})
	if err != nil {
		t.Fatalf("marshal state: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeState, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	for i := 0; i < MaxMessagesPerSecond+50; i++ {
		if c1.conn.Send(env) != nil {
			break
		}
	}

	select {
	case <-disconnected:
	case <-time.After(timeout):
		t.Fatal("timed out waiting for rate-limited connection to close")
	}
}

// TestHelloTimeoutClosesConnection: transport's IdleTimeout resets on any line read, not only a completed Hello, so
// it cannot bound an unauthenticated connection.
func TestHelloTimeoutClosesConnection(t *testing.T) {
	s := NewServer()
	s.HelloTimeout = 100 * time.Millisecond
	addr := startServerWith(t, s)

	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	disconnected := make(chan struct{})
	conn.OnDisconnect(func(err error) { close(disconnected) })

	select {
	case <-disconnected:
	case <-time.After(timeout):
		t.Fatal("timed out waiting for hello-timeout disconnect")
	}
}

// fakeStallingTransport's Send blocks until unblock is closed.
type fakeStallingTransport struct {
	unblock chan struct{}
}

func (f *fakeStallingTransport) Send(payload []byte) error {
	<-f.unblock
	return nil
}
func (f *fakeStallingTransport) SendUnreliable(payload []byte) error { return f.Send(payload) }
func (f *fakeStallingTransport) OnReceive(func([]byte))              {}
func (f *fakeStallingTransport) OnDisconnect(func(error))            {}
func (f *fakeStallingTransport) OnError(func(error))                 {}
func (f *fakeStallingTransport) Close() error                        { return nil }

// TestRoomForwardDoesNotBlockOtherOperationsOnStalledSend: Room.Forward releases r.mu before sending, so a member
// whose Send blocks for its write timeout cannot freeze joins, leaves or other sends.
func TestRoomForwardDoesNotBlockOtherOperationsOnStalledSend(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	stalled := &fakeStallingTransport{unblock: make(chan struct{})}
	r.tryAdd(&Client{PlayerID: "p1", Conn: stalled})

	forwardDone := make(chan struct{})
	go func() {
		env, _ := envelope(protocol.TypeLeave, protocol.Leave{PlayerID: "someone"})
		r.Forward(env, []string{"p1"})
		close(forwardDone)
	}()

	// Let Forward reach the stalled Send first.
	time.Sleep(50 * time.Millisecond)

	roomOpDone := make(chan struct{})
	go func() {
		r.tryAdd(&Client{PlayerID: "p2", Conn: &fakeStallingTransport{unblock: make(chan struct{})}})
		close(roomOpDone)
	}()

	select {
	case <-roomOpDone:
	case <-time.After(timeout):
		t.Fatal("room operation blocked behind Room.Forward's stalled Send — r.mu held too long")
	}

	close(stalled.unblock)
	select {
	case <-forwardDone:
	case <-time.After(timeout):
		t.Fatal("Forward never returned after unblocking Send")
	}
}

func TestRoomCodeAcceptsCorrectCode(t *testing.T) {
	s := NewServer()
	s.RoomCode = "letmein"
	addr := startServerWith(t, s)

	c1 := dialTestClientWithCode(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "alice",
	}, "letmein")
	defer c1.conn.Close()

	w := c1.expectWelcome(timeout)
	if w.PlayerID == "" {
		t.Fatal("welcome carried empty player_id for a correct room code")
	}
}

// TestRoomCodeRejectsWrongCode: a wrong code gets a Reject, not a bare hangup that looks like a slow relay.
func TestRoomCodeRejectsWrongCode(t *testing.T) {
	s := NewServer()
	s.RoomCode = "letmein"
	addr := startServerWith(t, s)

	c1 := dialTestClientWithCode(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "alice",
	}, "wrong")
	defer c1.conn.Close()

	env := c1.next(timeout)
	if env.Type != protocol.TypeReject {
		t.Fatalf("got message type %q, want %q", env.Type, protocol.TypeReject)
	}
	var reject protocol.Reject
	if err := json.Unmarshal(env.Payload, &reject); err != nil {
		t.Fatalf("unmarshal reject: %v", err)
	}
	if reject.Reason == "" {
		t.Fatal("reject carried an empty reason")
	}
}

// TestEmptyConfiguredRoomCodeAcceptsAnyHello: with no RoomCode the relay admits whatever the client offers to prove.
func TestEmptyConfiguredRoomCodeAcceptsAnyHello(t *testing.T) {
	addr := startServer(t) // NewServer(), RoomCode left empty

	c1 := dialTestClientWithCode(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "alice",
	}, "whatever-i-feel-like")
	defer c1.conn.Close()

	w := c1.expectWelcome(timeout)
	if w.PlayerID == "" {
		t.Fatal("welcome carried empty player_id when the relay has no room code configured")
	}
}

func TestOnlyGameAcceptsMatchingGame(t *testing.T) {
	s := NewServer()
	s.OnlyGame = "pseudoregalia"
	addr := startServerWith(t, s)

	c1 := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "pseudoregalia", Room: "room1", DisplayName: "alice",
	})
	defer c1.conn.Close()

	w := c1.expectWelcome(timeout)
	if w.PlayerID == "" {
		t.Fatal("welcome carried empty player_id for the relay's configured game")
	}
}

// TestOnlyGameRejectsOtherGame: the reason is ReasonGameNotAllowed, not the per-room ReasonGameMismatch, since no room
// this client could pick would help.
func TestOnlyGameRejectsOtherGame(t *testing.T) {
	s := NewServer()
	s.OnlyGame = "pseudoregalia"
	addr := startServerWith(t, s)

	c1 := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "alice",
	})
	defer c1.conn.Close()

	env := c1.next(timeout)
	if env.Type != protocol.TypeReject {
		t.Fatalf("got message type %q, want %q", env.Type, protocol.TypeReject)
	}
	var reject protocol.Reject
	if err := json.Unmarshal(env.Payload, &reject); err != nil {
		t.Fatalf("unmarshal reject: %v", err)
	}
	if reject.Reason != protocol.ReasonGameNotAllowed {
		t.Fatalf("reject reason = %q, want %q", reject.Reason, protocol.ReasonGameNotAllowed)
	}
}

// TestEmptyOnlyGameAcceptsAnyGame: with no OnlyGame the relay hosts two games at once, in different rooms.
func TestEmptyOnlyGameAcceptsAnyGame(t *testing.T) {
	addr := startServer(t) // NewServer(), OnlyGame left empty

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	if w := c1.expectWelcome(timeout); w.PlayerID == "" {
		t.Fatal("welcome carried empty player_id when the relay restricts no game")
	}

	c2 := dialTestClient(t, addr, "pseudoregalia", "room2", "bob")
	defer c2.conn.Close()
	if w := c2.expectWelcome(timeout); w.PlayerID == "" {
		t.Fatal("second game refused by a relay that restricts no game")
	}
}

// TestGameVersionMismatchRejected: a room's declared game_version is sticky, but a client that declares none is never
// refused for it.
func TestGameVersionMismatchRejected(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "alice", GameVersion: "1.0",
	})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	c2 := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "bob", GameVersion: "2.0",
	})
	defer c2.conn.Close()

	env := c2.next(timeout)
	if env.Type != protocol.TypeReject {
		t.Fatalf("got message type %q, want %q for a mismatched game_version", env.Type, protocol.TypeReject)
	}

	c3 := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "carol",
	})
	defer c3.conn.Close()
	w3 := c3.expectWelcome(timeout)
	if w3.PlayerID == "" {
		t.Fatal("welcome carried empty player_id for a client with no declared game_version")
	}
}

// TestTryAddAndSnapshotRosterIsAtomic: the Nth join's snapshot holds exactly the N-1 members added before it, or two
// concurrent joiners could each miss the other.
func TestTryAddAndSnapshotRosterIsAtomic(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)

	roster1, _ := r.tryAddAndSnapshotRoster(&Client{PlayerID: "p1", Conn: &fakeStallingTransport{unblock: make(chan struct{})}})
	if len(roster1) != 0 {
		t.Fatalf("first join: roster=%v, want []", roster1)
	}

	roster2, _ := r.tryAddAndSnapshotRoster(&Client{PlayerID: "p2", Conn: &fakeStallingTransport{unblock: make(chan struct{})}})
	if len(roster2) != 1 || roster2[0] != "p1" {
		t.Fatalf("second join: roster=%v, want [p1]", roster2)
	}

	final := r.roster()
	if len(final) != 2 {
		t.Fatalf("final roster = %v, want both p1 and p2 present", final)
	}
}

// TestOversizedHelloFieldRejected pairs an oversized DisplayName with a bad ProtocolVersion: the length check must
// run first, since every refusal logs the hello's fields.
func TestOversizedHelloFieldRejected(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version + 1,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     strings.Repeat("a", protocol.MaxHelloFieldLen+1),
	})
	defer c1.conn.Close()

	env := c1.next(timeout)
	if env.Type != protocol.TypeReject {
		t.Fatalf("got message type %q, want %q", env.Type, protocol.TypeReject)
	}
	var reject protocol.Reject
	if err := json.Unmarshal(env.Payload, &reject); err != nil {
		t.Fatalf("unmarshal reject: %v", err)
	}
	if reject.Reason != protocol.ReasonHelloFieldTooLong {
		t.Fatalf("reject reason = %q, want %q (length check should run before the version check)", reject.Reason, protocol.ReasonHelloFieldTooLong)
	}
}

// TestPingGetsPong: the pong echoes the nonce, so a caller can match replies to requests.
func TestPingGetsPong(t *testing.T) {
	addr := startServer(t)
	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	payload, err := json.Marshal(protocol.Ping{Nonce: 42})
	if err != nil {
		t.Fatalf("marshal ping: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypePing, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	if err := c1.conn.Send(env); err != nil {
		t.Fatalf("send ping: %v", err)
	}

	got := c1.next(timeout)
	if got.Type != protocol.TypePong {
		t.Fatalf("got message type %q, want %q", got.Type, protocol.TypePong)
	}
	var pong protocol.Pong
	if err := json.Unmarshal(got.Payload, &pong); err != nil {
		t.Fatalf("unmarshal pong: %v", err)
	}
	if pong.Nonce != 42 {
		t.Fatalf("pong nonce = %d, want 42 (echoed from the ping)", pong.Nonce)
	}
}

// TestIdleConnectionWithoutPingIsDroppedByIdleTimeout is the control for core's
// TestHeartbeatKeepsIdleRelayConnectionAlive: with no traffic at all, IdleTimeout drops the connection.
func TestIdleConnectionWithoutPingIsDroppedByIdleTimeout(t *testing.T) {
	s := NewServer()
	s.IdleTimeout = 50 * time.Millisecond
	addr := startServerWith(t, s)
	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	disconnected := make(chan error, 1)
	c1.conn.OnDisconnect(func(err error) { disconnected <- err })

	select {
	case <-disconnected:
	case <-time.After(2 * time.Second):
		t.Fatal("connection was not dropped by IdleTimeout — test harness assumption is wrong")
	}
}

func TestWelcomeAdvertisesConfiguredSendRate(t *testing.T) {
	s := NewServer()
	s.SendHz = 50
	addr := startServerWith(t, s)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w := c1.expectWelcome(timeout)
	if w.SendHz != 50 {
		t.Fatalf("Welcome.SendHz = %d, want 50", w.SendHz)
	}
}

func TestWelcomeAdvertisesDefaultSendRateWhenUnconfigured(t *testing.T) {
	addr := startServer(t)
	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w := c1.expectWelcome(timeout)
	if w.SendHz != protocol.DefaultSendHz {
		t.Fatalf("Welcome.SendHz = %d, want protocol.DefaultSendHz (%d)", w.SendHz, protocol.DefaultSendHz)
	}
}

// TestOutOfRangeSendRateIsClampedRatherThanRefused: a typo in a cosmetic tuning knob must not stop a relay starting.
func TestOutOfRangeSendRateIsClampedRatherThanRefused(t *testing.T) {
	check := func(configured, want int) {
		s := NewServer()
		s.SendHz = configured
		addr := startServerWith(t, s)
		c := dialTestClient(t, addr, "emerald", "room1", "alice")
		defer c.conn.Close()
		w := c.expectWelcome(timeout)
		if w.SendHz != want {
			t.Fatalf("configured send_hz=%d: Welcome.SendHz = %d, want %d", configured, w.SendHz, want)
		}
	}
	check(0, protocol.DefaultSendHz)
	check(-5, protocol.DefaultSendHz)
	check(5, protocol.MinSendHz)
	check(1000, protocol.MaxSendHz)
}

// TestReceiveCapThrottlesOnlyTheClientThatAskedForIt: a 5Hz-capped recipient gets fewer of the same states than an
// uncapped one, and never zero, since the gate always lets the first through.
func TestReceiveCapThrottlesOnlyTheClientThatAskedForIt(t *testing.T) {
	addr := startServer(t)

	sender := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer sender.conn.Close()
	wSender := sender.expectWelcome(timeout)

	uncapped := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer uncapped.conn.Close()
	uncapped.expectWelcome(timeout)

	capped := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "carol", MaxReceiveHz: 5,
	})
	defer capped.conn.Close()
	capped.expectWelcome(timeout)

	const sendCount = 50
	const sendInterval = 15 * time.Millisecond // ~750ms total, well under any flood cap

	countStates := func(tc *testClient, done <-chan struct{}) int {
		count := 0
		for {
			select {
			case env := <-tc.envs:
				if env.Type == protocol.TypeState {
					count++
				}
			case <-done:
				for {
					select {
					case env := <-tc.envs:
						if env.Type == protocol.TypeState {
							count++
						}
					default:
						return count
					}
				}
			}
		}
	}

	doneUncapped := make(chan struct{})
	doneCapped := make(chan struct{})
	var gotUncapped, gotCapped int
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); gotUncapped = countStates(uncapped, doneUncapped) }()
	go func() { defer wg.Done(); gotCapped = countStates(capped, doneCapped) }()

	for i := 0; i < sendCount; i++ {
		sender.sendState(protocol.State{PlayerID: wSender.PlayerID, AreaID: "a", Position: []float64{float64(i), 0}, Anim: "idle"})
		time.Sleep(sendInterval)
	}
	time.Sleep(100 * time.Millisecond) // let any in-flight forwards land
	close(doneUncapped)
	close(doneCapped)
	wg.Wait()

	if gotUncapped < sendCount/2 {
		t.Fatalf("uncapped recipient got %d of %d states, want most of them", gotUncapped, sendCount)
	}
	if gotCapped == 0 {
		t.Fatal("capped recipient (5Hz) got zero states — the gate should always let the first one through")
	}
	if gotCapped >= gotUncapped {
		t.Fatalf("capped recipient got %d states, uncapped recipient got %d — want the capped one meaningfully fewer", gotCapped, gotUncapped)
	}
}

// TestReceiveCapDoesNotThrottleJoinOrLeave: a throttled Leave would strand a frozen ghost on that recipient's screen.
func TestReceiveCapDoesNotThrottleJoinOrLeave(t *testing.T) {
	addr := startServer(t)

	capped := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "watcher", MaxReceiveHz: 1,
	})
	defer capped.conn.Close()
	capped.expectWelcome(timeout)

	peer := dialTestClient(t, addr, "emerald", "room1", "peer")
	w := peer.expectWelcome(timeout)

	join := capped.next(timeout)
	if join.Type != protocol.TypeJoin {
		t.Fatalf("got %q, want %q (peer's join)", join.Type, protocol.TypeJoin)
	}

	// The 1Hz gate drops all but the first of these, so it is active for this recipient.
	for i := 0; i < 5; i++ {
		peer.sendState(protocol.State{PlayerID: w.PlayerID, AreaID: "a", Position: []float64{float64(i), 0}, Anim: "idle"})
	}
	peer.conn.Close()

	deadline := time.After(timeout)
	for {
		select {
		case env := <-capped.envs:
			if env.Type != protocol.TypeLeave {
				continue // ignore any State that made it through the gate
			}
			var l protocol.Leave
			if err := json.Unmarshal(env.Payload, &l); err != nil {
				t.Fatalf("unmarshal leave: %v", err)
			}
			if l.PlayerID != w.PlayerID {
				t.Fatalf("leave player_id = %q, want %q", l.PlayerID, w.PlayerID)
			}
			return
		case <-deadline:
			t.Fatal("capped recipient never received peer's Leave — join/leave must never be throttled")
		}
	}
}

func TestUncappedRecipientStillReceivesEveryState(t *testing.T) {
	addr := startServer(t)

	sender := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer sender.conn.Close()
	wSender := sender.expectWelcome(timeout)

	recipient := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer recipient.conn.Close()
	recipient.expectWelcome(timeout)

	const sendCount = 20
	for i := 0; i < sendCount; i++ {
		sender.sendState(protocol.State{PlayerID: wSender.PlayerID, AreaID: "a", Position: []float64{float64(i), 0}, Anim: "idle"})
	}

	got := 0
	deadline := time.After(timeout)
	for got < sendCount {
		select {
		case env := <-recipient.envs:
			if env.Type == protocol.TypeState {
				got++
			}
		case <-deadline:
			t.Fatalf("received %d of %d states before timing out — an uncapped recipient must receive every one", got, sendCount)
		}
	}
}

func TestRateLimitScalesWithConfiguredSendRate(t *testing.T) {
	s := NewServer()
	s.SendHz = 100
	addr := startServerWith(t, s)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	disconnected := make(chan struct{})
	c1.conn.OnDisconnect(func(err error) { close(disconnected) })

	payload, err := json.Marshal(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{1, 1}, Anim: "idle"})
	if err != nil {
		t.Fatalf("marshal state: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeState, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	// 100Hz * RateLimitHeadroomMultiple (6) is a 600/sec cap; this burst is past the 120 floor and well under it.
	const burst = 200
	for i := 0; i < burst; i++ {
		if err := c1.conn.Send(env); err != nil {
			t.Fatalf("send %d of %d: %v (connection closed prematurely)", i, burst, err)
		}
	}

	select {
	case <-disconnected:
		t.Fatal("connection was closed — the flood cap did not scale with the configured 100Hz send rate")
	case <-time.After(200 * time.Millisecond):
	}

	// It must still work afterwards, not just survive.
	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.sendState(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{2, 2}, Anim: "idle"})
	got := c2.next(timeout)
	if got.Type != protocol.TypeState {
		t.Fatalf("got %q, want %q", got.Type, protocol.TypeState)
	}
}

// TestRateLimitNeverFallsBelowTheHistoricalFloor: turning a room down must never disconnect an older client still
// sending at its own built-in 20Hz.
func TestRateLimitNeverFallsBelowTheHistoricalFloor(t *testing.T) {
	s := NewServer()
	s.SendHz = 10
	addr := startServerWith(t, s)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	disconnected := make(chan struct{})
	c1.conn.OnDisconnect(func(err error) { close(disconnected) })

	payload, err := json.Marshal(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{1, 1}, Anim: "idle"})
	if err != nil {
		t.Fatalf("marshal state: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeState, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	// Past the scaled 10*6=60 and under the 120 floor.
	const burst = 100
	for i := 0; i < burst; i++ {
		if err := c1.conn.Send(env); err != nil {
			t.Fatalf("send %d of %d: %v (connection closed prematurely -- floor not enforced)", i, burst, err)
		}
	}

	select {
	case <-disconnected:
		t.Fatal("connection was closed at 100 messages — the flood cap fell below its historical 120 floor")
	case <-time.After(200 * time.Millisecond):
	}
}

// TestRateLimitedClientReceivesRejectBeforeClose: a mid-session close says why, as a handshake refusal does.
func TestRateLimitedClientReceivesRejectBeforeClose(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	disconnected := make(chan struct{})
	c1.conn.OnDisconnect(func(err error) { close(disconnected) })

	payload, err := json.Marshal(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{1, 1}, Anim: "idle"})
	if err != nil {
		t.Fatalf("marshal state: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeState, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	for i := 0; i < MaxMessagesPerSecond+50; i++ {
		if c1.conn.Send(env) != nil {
			break
		}
	}

	var reject protocol.Envelope
	deadline := time.After(timeout)
	found := false
	for !found {
		select {
		case e := <-c1.envs:
			if e.Type == protocol.TypeReject {
				reject = e
				found = true
			}
		case <-deadline:
			t.Fatal("timed out waiting for a Reject before the rate-limited connection closed")
		}
	}
	var r protocol.Reject
	if err := json.Unmarshal(reject.Payload, &r); err != nil {
		t.Fatalf("unmarshal reject: %v", err)
	}
	if r.Reason != protocol.ReasonRateLimited {
		t.Fatalf("reject reason = %q, want %q", r.Reason, protocol.ReasonRateLimited)
	}

	select {
	case <-disconnected:
	case <-time.After(timeout):
		t.Fatal("received Reject but the connection was never actually closed afterward")
	}
}

// TestReceiveGateForgetsASenderThatLeft: player_ids are never reused, so without Room.remove's purge every departed
// sender stays in each remaining member's receive gate for the relay's life.
func TestReceiveGateForgetsASenderThatLeft(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	sender := &Client{PlayerID: "p1", Conn: &fakeStallingTransport{unblock: make(chan struct{})}}
	// Capped: an uncapped allowStateFrom returns before it touches the gate map.
	recipient := &Client{PlayerID: "p2", Conn: &fakeStallingTransport{unblock: make(chan struct{})}, maxReceiveHz: 10}
	r.tryAdd(sender)
	r.tryAdd(recipient)

	if !recipient.allowStateFrom("p1", time.Now()) {
		t.Fatal("setup: the first state from a sender should always be allowed through the gate")
	}
	recipient.gateMu.Lock()
	_, tracked := recipient.lastStateTo["p1"]
	recipient.gateMu.Unlock()
	if !tracked {
		t.Fatal("setup: the gate did not record the sender")
	}

	r.remove("p1")

	recipient.gateMu.Lock()
	_, stillTracked := recipient.lastStateTo["p1"]
	recipient.gateMu.Unlock()
	if stillTracked {
		t.Fatal("departed sender's entry was not purged from the remaining member's receive gate")
	}
}

// TestRoomsAreIndependentAcrossTheirWholeLifecycle walks one interleaving of rooms created and dropped, checking
// isolation at every step: a room dropped or reached through the wrong key does not error, it stops delivering.
func TestRoomsAreIndependentAcrossTheirWholeLifecycle(t *testing.T) {
	s := &Server{rooms: make(map[string]*Room), MaxClients: DefaultMaxClients}
	addr := startServerWith(t, s)

	roomCount := func() int {
		s.mu.Lock()
		defer s.mu.Unlock()
		return len(s.rooms)
	}

	a1 := dialTestClient(t, addr, "emerald", "alpha", "a1")
	defer a1.conn.Close()
	a1.expectWelcome(timeout)
	if roomCount() != 1 {
		t.Fatalf("after the first join there are %d rooms, want 1", roomCount())
	}

	a2 := dialTestClient(t, addr, "emerald", "alpha", "a2")
	defer a2.conn.Close()
	if w := a2.expectWelcome(timeout); len(w.Roster) != 1 {
		t.Fatalf("second client's roster = %v, want the first client", w.Roster)
	}
	a1.nextOfType(protocol.TypeJoin, timeout)
	if roomCount() != 1 {
		t.Fatalf("joining an existing room created a new one: %d rooms", roomCount())
	}

	b1 := dialTestClient(t, addr, "emerald", "beta", "b1")
	defer b1.conn.Close()
	if w := b1.expectWelcome(timeout); len(w.Roster) != 0 {
		t.Fatalf("new room's roster = %v, want empty", w.Roster)
	}
	if roomCount() != 2 {
		t.Fatalf("%d rooms, want 2", roomCount())
	}
	a1.expectNothingOfType(protocol.TypeJoin, 200*time.Millisecond)

	c1 := dialTestClient(t, addr, "tevi", "alpha", "c1")
	defer c1.conn.Close()
	if w := c1.expectWelcome(timeout); len(w.Roster) != 0 {
		t.Fatalf("same-name-other-game roster = %v, want empty", w.Roster)
	}
	if roomCount() != 3 {
		t.Fatalf("%d rooms, want 3", roomCount())
	}

	a1.sendState(protocol.State{AreaID: "alpha-zone", Position: []float64{1, 1}})
	if st := a2.nextOfType(protocol.TypeState, timeout); st.Type != protocol.TypeState {
		t.Fatal("state did not reach the other member of the same room")
	}
	b1.expectNothingOfType(protocol.TypeState, 200*time.Millisecond)
	c1.expectNothingOfType(protocol.TypeState, 200*time.Millisecond)

	// The dropped room shares its name with a live room in another game: deleting by name would evict the wrong one.
	a1.conn.Close()
	a2.conn.Close()
	deadline := time.Now().Add(3 * time.Second)
	for roomCount() != 2 {
		if time.Now().After(deadline) {
			t.Fatalf("emptied room was not dropped: %d rooms remain", roomCount())
		}
		time.Sleep(20 * time.Millisecond)
	}

	b2 := dialTestClient(t, addr, "emerald", "beta", "b2")
	defer b2.conn.Close()
	if w := b2.expectWelcome(timeout); len(w.Roster) != 1 {
		t.Fatalf("surviving room lost its member: roster = %v", w.Roster)
	}
	c1.sendState(protocol.State{AreaID: "tevi-zone", Position: []float64{2, 2}})
	b1.expectNothingOfType(protocol.TypeState, 200*time.Millisecond)

	a3 := dialTestClient(t, addr, "emerald", "alpha", "a3")
	defer a3.conn.Close()
	if w := a3.expectWelcome(timeout); len(w.Roster) != 0 {
		t.Fatalf("recreated room's roster = %v, want empty", w.Roster)
	}
	if roomCount() != 3 {
		t.Fatalf("%d rooms after recreating one, want 3", roomCount())
	}

	a4 := dialTestClient(t, addr, "emerald", "alpha", "a4")
	defer a4.conn.Close()
	a4.expectWelcome(timeout)
	a3.nextOfType(protocol.TypeJoin, timeout)
	a4.sendState(protocol.State{AreaID: "alpha-zone", Position: []float64{3, 3}})
	a3.nextOfType(protocol.TypeState, timeout)
	c1.expectNothingOfType(protocol.TypeState, 200*time.Millisecond)
}

// TestJoinRacingTheLastLeaveIsNotOrphaned: if the last member leaves between joinOrCreateRoom and the add, dropIfEmpty
// removes the room and the joiner lands in one nobody can reach. Nothing errors; the ghosts never appear.
func TestJoinRacingTheLastLeaveIsNotOrphaned(t *testing.T) {
	s := &Server{rooms: make(map[string]*Room), MaxClients: DefaultMaxClients}
	addr := startServerWith(t, s)

	for i := 0; i < 40; i++ {
		leaver := dialTestClient(t, addr, "emerald", "churn", "leaver")
		leaver.expectWelcome(timeout)

		var wg sync.WaitGroup
		var joiner *testClient
		var joinerID string
		wg.Add(2)
		go func() {
			defer wg.Done()
			leaver.conn.Close()
		}()
		go func() {
			defer wg.Done()
			joiner = dialTestClient(t, addr, "emerald", "churn", "joiner")
			joinerID = joiner.expectWelcome(timeout).PlayerID
		}()
		wg.Wait()

		witness := dialTestClient(t, addr, "emerald", "churn", "witness")
		w := witness.expectWelcome(timeout)

		found := false
		for _, id := range w.Roster {
			if id == joinerID {
				found = true
			}
		}
		if !found {
			t.Fatalf("iteration %d: a client that joined room %q was invisible to the next "+
				"client to join it (roster %v, missing %s) — it was left in a room that had "+
				"already been dropped", i, "churn", w.Roster, joinerID)
		}

		joiner.conn.Close()
		witness.conn.Close()
		deadline := time.Now().Add(2 * time.Second)
		for {
			s.mu.Lock()
			n := len(s.rooms)
			s.mu.Unlock()
			if n == 0 || time.Now().After(deadline) {
				break
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
}

// TestRoomDroppedWhileAClientIsJoiningIt drives the same hazard in the order handleConn can interleave it, without
// depending on timing.
func TestRoomDroppedWhileAClientIsJoiningIt(t *testing.T) {
	s := &Server{rooms: make(map[string]*Room), MaxClients: DefaultMaxClients}

	// Handed the room, not added yet: that happens several statements later in handleConn.
	joining, reason := s.joinOrCreateRoom("emerald", "", "x", nil)
	if reason != "" {
		t.Fatalf("join refused: %s", reason)
	}

	// The room's last member departs meanwhile.
	s.dropIfEmpty(joining)

	joining.tryAdd(&Client{PlayerID: "p1"})

	later, reason := s.joinOrCreateRoom("emerald", "", "x", nil)
	if reason != "" {
		t.Fatalf("second join refused: %s", reason)
	}
	if later != joining {
		t.Fatalf("a client that joined room %q was left in a room that had already been "+
			"dropped: the next client asking for the same room got a different one, so the "+
			"two can never see each other", "x")
	}
}

// TestForwardHoldsTrafficUntilWelcomeIsWritten: a client is a room member before its Welcome is written, and core
// reads its player_id and roster from the Welcome, so nothing may reach it first. At the Room level, so no timing.
func TestForwardHoldsTrafficUntilWelcomeIsWritten(t *testing.T) {
	r := newRoom("emerald", "", "churn", nil)
	rt := &recordingTransport{}
	r.tryAdd(&Client{PlayerID: "p1", Conn: rt, holdUntilWelcome: true})

	leave, err := envelope(protocol.TypeLeave, protocol.Leave{PlayerID: "p2"})
	if err != nil {
		t.Fatalf("build leave: %v", err)
	}
	r.Forward(leave, []string{"p1"})

	if got := rt.received(t); len(got) != 0 {
		t.Fatalf("a client that has not been sent its Welcome yet received %d message(s) "+
			"(first type %q); nothing may reach a client ahead of its own Welcome",
			len(got), got[0].Type)
	}

	// State is held too: joinSnapshot covers a dropped sample only in a snapshot.v1 room, so elsewhere its sender
	// stays invisible until it sends again.
	state, err := envelope(protocol.TypeState, protocol.State{AreaID: "a", Position: []float64{1, 2}})
	if err != nil {
		t.Fatalf("build state: %v", err)
	}
	r.ForwardUnreliable(state, []string{"p1"})

	if got := rt.received(t); len(got) != 0 {
		t.Fatalf("state reached the client before its Welcome (%d message(s))", len(got))
	}

	r.markWelcomedAndFlush("p1")

	got := rt.received(t)
	if len(got) != 2 {
		types := make([]string, 0, len(got))
		for _, e := range got {
			types = append(types, string(e.Type))
		}
		t.Fatalf("after the Welcome the client received %v, want the held leave then the held state", types)
	}
	if got[0].Type != protocol.TypeLeave || got[1].Type != protocol.TypeState {
		t.Fatalf("held messages arrived as %q,%q — want %q then %q, the order they were produced in",
			got[0].Type, got[1].Type, protocol.TypeLeave, protocol.TypeState)
	}

	r.Forward(leave, []string{"p1"})
	if got := rt.received(t); len(got) != 3 {
		t.Fatalf("after the flush the client received %d message(s), want 3 — the hold "+
			"should be released, not permanent", len(got))
	}
}

// TestFlushIsNotOvertakenByANewerMessage: a message produced while the backlog flushes must not overtake it.
// recordingTransport's block parks the flush inside its first write, so the window is deterministic.
func TestFlushIsNotOvertakenByANewerMessage(t *testing.T) {
	r := newRoom("emerald", "", "churn", nil)
	rt := &recordingTransport{block: make(chan struct{})}
	r.tryAdd(&Client{PlayerID: "p1", Conn: rt, holdUntilWelcome: true})

	first, err := envelope(protocol.TypeLeave, protocol.Leave{PlayerID: "first"})
	if err != nil {
		t.Fatalf("build first: %v", err)
	}
	second, err := envelope(protocol.TypeLeave, protocol.Leave{PlayerID: "second"})
	if err != nil {
		t.Fatalf("build second: %v", err)
	}

	// Queued behind the hold.
	r.Forward(first, []string{"p1"})

	flushed := make(chan struct{})
	go func() {
		defer close(flushed)
		r.markWelcomedAndFlush("p1")
	}()

	// Wait until the flush is parked inside its write of `first`.
	deadline := time.Now().Add(2 * time.Second)
	for {
		rt.mu.Lock()
		parked := rt.blocked
		rt.mu.Unlock()
		if parked {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("flush never reached its first write")
		}
		time.Sleep(time.Millisecond)
	}

	// Produced mid-flush.
	r.Forward(second, []string{"p1"})

	close(rt.block)
	<-flushed

	got := rt.received(t)
	if len(got) != 2 {
		t.Fatalf("client received %d message(s), want 2", len(got))
	}
	var ids []string
	for _, e := range got {
		var lv protocol.Leave
		if err := json.Unmarshal(e.Payload, &lv); err != nil {
			t.Fatalf("decode leave: %v", err)
		}
		ids = append(ids, lv.PlayerID)
	}
	if ids[0] != "first" || ids[1] != "second" {
		t.Fatalf("delivered %v — a message produced during the flush overtook the backlog", ids)
	}
}

// TestBigRoomWelcomeStaysUnderLineLimit: a whole roster with nametags outgrows protocol.MaxLineBytes, the cap on every
// core's scanner, so boundWelcomeRoster sends the rest as Joins. The reader is a raw scanner at that cap, not a
// testClient with transport.Dial's 64KiB, so it fails the way a real core does.
func TestBigRoomWelcomeStaysUnderLineLimit(t *testing.T) {
	big := NewServer()
	big.MaxClients = 200
	addr := startServerWith(t, big)

	const members = 120
	clients := make([]*testClient, 0, members)
	for i := 0; i < members; i++ {
		c := dialTestClient(t, addr, "faketest", "bigroom", fmt.Sprintf("load-test-name-%03d", i))
		defer c.conn.Close()
		c.expectWelcome(timeout)
		clients = append(clients, c)
	}

	raw, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("raw dial: %v", err)
	}
	defer raw.Close()
	hello, _ := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: mustMarshal(t, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "faketest",
		Room:            "bigroom",
	})})
	if _, err := raw.Write(append(hello, '\n')); err != nil {
		t.Fatalf("raw hello: %v", err)
	}

	known := map[string]bool{}
	sc := bufio.NewScanner(raw)
	sc.Buffer(make([]byte, 4096), protocol.MaxLineBytes)
	_ = raw.SetReadDeadline(time.Now().Add(5 * time.Second))
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) > protocol.MaxLineBytes {
			t.Fatalf("relay sent a %d-byte line, over protocol.MaxLineBytes=%d", len(line), protocol.MaxLineBytes)
		}
		var env protocol.Envelope
		if err := json.Unmarshal(line, &env); err != nil {
			t.Fatalf("unparseable line from relay: %v", err)
		}
		switch env.Type {
		case protocol.TypeWelcome:
			var w protocol.Welcome
			if err := json.Unmarshal(env.Payload, &w); err != nil {
				t.Fatalf("unmarshal welcome: %v", err)
			}
			for _, id := range w.Roster {
				known[id] = true
			}
		case protocol.TypeJoin:
			var j protocol.Join
			if err := json.Unmarshal(env.Payload, &j); err != nil {
				t.Fatalf("unmarshal join: %v", err)
			}
			known[j.PlayerID] = true
		}
		if len(known) >= members {
			return // every pre-existing member learned, no line over the limit
		}
	}
	t.Fatalf("connection ended before all %d members were learned (got %d): %v -- the exact failure a real core hit at 150 peers", members, len(known), sc.Err())
}

func mustMarshal(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}
