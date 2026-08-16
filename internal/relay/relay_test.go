package relay

import (
	"encoding/json"
	"net"
	"strings"
	"sync"
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
	return dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          gameID,
		Room:            room,
		DisplayName:     name,
	})
}

// dialTestClientWithHello is dialTestClient's more general form, for tests
// that need to set fields dialTestClient doesn't expose (RoomCode,
// GameVersion) — added alongside relay-safety hardening,
// agent_docs/architecture.md's room-code/version ADR.
func dialTestClientWithHello(t *testing.T, addr string, hello protocol.Hello) *testClient {
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

	wantGhost := w1.PlayerID + "-ghost"

	// A Join for the synthetic ghost id must precede its first echoed state
	// — otherwise internal/core.storeRemoteState's roster-trust check (see
	// the 2026-08-14 ADR in agent_docs/architecture.md) silently drops it as
	// a state for a player_id it never saw announced. Found live: loopback
	// mode spawned no ghost at all after that hardening landed, since this
	// Join was missing entirely.
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

	// A second State from the same client must NOT re-send the Join —
	// loopbackGhostSent should have latched after the first one.
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

	oversized := make([]float64, protocol.MaxPositionLen+1)
	c1.sendState(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: oversized, Anim: "idle"})

	select {
	case env := <-c2.envs:
		t.Fatalf("c2 unexpectedly received %q for an oversized-position state", env.Type)
	case <-time.After(200 * time.Millisecond):
	}
}

// TestOutOfRangePositionDropped confirms a state with a position component
// past MaxPositionComponent's magnitude is dropped, not forwarded —
// protocol.IsValidPosition/ValidateState had no test anywhere before this,
// despite being the newest limit added. A syntactically valid JSON number
// like 1e308 survives []float64 unmarshaling and becomes +Inf the moment an
// adapter narrows it to float32. NaN/±Inf themselves aren't tested at this
// wire level: standard JSON has no literal for them (confirmed:
// json.Marshal on a NaN/Inf float64 errors), so they can never actually
// arrive over the wire — IsValidPosition's own NaN/Inf checks are defense
// in depth for a State constructed directly in Go, covered instead by
// internal/protocol's own TestIsValidPosition and
// internal/core's TestNonFiniteInboundPositionDropped (which calls
// storeRemoteState directly, bypassing JSON).
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

// TestOversizedOrientationDropped and TestOversizedAnimDropped confirm the
// remaining two arms of the combined length check in
// protocol.ValidateState — only the AreaID arm had a test before this.
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
		Extras:   map[string]any{"junk": string(make([]byte, protocol.MaxLineBytes+1))},
	}
	c1.sendState(huge)

	select {
	case <-disconnected:
	case <-time.After(timeout):
		t.Fatal("timed out waiting for oversized-line connection to close")
	}
}

// TestServerFullRejectsExtraClient confirms a relay at its configured
// MaxClients refuses an additional join rather than growing unbounded.
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

// TestMismatchedProtocolVersionRejected confirms a Hello whose
// protocol_version doesn't match protocol.Version is refused outright, per
// the versioning rule (agent_docs/contract.md). Previously untested —
// closed as a coverage gap while scoping relay-safety hardening
// (agent_docs/architecture.md's room-code/version ADR).
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
		ProtocolVersion: protocol.Version + 1,
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

// TestOversizedExtrasDropped confirms a State whose Extras exceeds
// MaxExtrasBytes is dropped rather than forwarded. Previously untested —
// closed as a coverage gap while scoping relay-safety hardening
// (agent_docs/architecture.md's room-code/version ADR).
func TestOversizedExtrasDropped(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.next(timeout)

	// strings.Repeat, not a raw zero-byte string: JSON escapes each
	// non-printable byte as a 6-character sequence, which would blow past
	// MaxLineBytes first and close the connection instead of exercising
	// the MaxExtrasBytes drop-only path this test targets.
	oversized := map[string]any{"junk": strings.Repeat("a", protocol.MaxExtrasBytes+1)}
	c1.sendState(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{1, 1}, Anim: "idle", Extras: oversized})

	select {
	case env := <-c2.envs:
		t.Fatalf("c2 unexpectedly received %q for an oversized-extras state", env.Type)
	case <-time.After(200 * time.Millisecond):
	}
}

// TestRateLimitClosesConnection confirms a client exceeding
// MaxMessagesPerSecond is disconnected rather than left to keep flooding.
// Previously untested — closed as a coverage gap while scoping relay-safety
// hardening (agent_docs/architecture.md's room-code/version ADR).
func TestRateLimitClosesConnection(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)

	disconnected := make(chan struct{})
	c1.conn.OnDisconnect(func(err error) { close(disconnected) })

	// Marshal once and send raw via conn.Send, ignoring write errors:
	// unlike sendState (which t.Fatalf's on error), a later send in this
	// loop is expected to fail once the relay has already closed the
	// connection for exceeding the rate limit.
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

// TestHelloTimeoutClosesConnection confirms an unauthenticated connection
// that never completes a Hello is closed after Server.HelloTimeout rather
// than held open forever. Found while scoping relay-safety hardening —
// transport's own IdleTimeout doesn't cover this case on its own, since it
// resets on any successfully read line, not just a completed Hello. See
// agent_docs/architecture.md's room-code/version ADR.
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

	// Deliberately never send a Hello.
	select {
	case <-disconnected:
	case <-time.After(timeout):
		t.Fatal("timed out waiting for hello-timeout disconnect")
	}
}

// fakeStallingTransport is a transport.Transport whose Send blocks until
// unblock is closed, used to prove Room.Forward no longer holds r.mu for
// the duration of a slow/stalled Send call.
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

// TestRoomForwardDoesNotBlockOtherOperationsOnStalledSend confirms
// Room.Forward releases r.mu before calling Send, so one stalled room
// member can't freeze other room operations (joins, leaves, roster reads,
// other Forward calls) for the duration of its own send. Previously
// Room.Forward held r.mu for its entire send loop; harmless when Send was
// unbounded-but-fast, but real once NDJSONConn.Send gained a WriteTimeout
// (transport.go) and could legitimately block for seconds against a
// stalled peer. Found while scoping relay-safety hardening —
// agent_docs/architecture.md's room-code/version ADR.
func TestRoomForwardDoesNotBlockOtherOperationsOnStalledSend(t *testing.T) {
	r := newRoom("emerald", "", "room1")
	stalled := &fakeStallingTransport{unblock: make(chan struct{})}
	r.tryAdd(&Client{PlayerID: "p1", Conn: stalled})

	forwardDone := make(chan struct{})
	go func() {
		env, _ := envelope(protocol.TypeLeave, protocol.Leave{PlayerID: "someone"})
		r.Forward(env, []string{"p1"})
		close(forwardDone)
	}()

	// Give Forward a moment to reach the (now stalled) Send call before
	// racing a room operation against it.
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

// TestRoomCodeAcceptsCorrectCode confirms a Hello carrying the relay's
// configured RoomCode is accepted normally — room-code auth added alongside
// relay-safety hardening, agent_docs/architecture.md's ADR.
func TestRoomCodeAcceptsCorrectCode(t *testing.T) {
	s := NewServer()
	s.RoomCode = "letmein"
	addr := startServerWith(t, s)

	c1 := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "alice", RoomCode: "letmein",
	})
	defer c1.conn.Close()

	w := c1.expectWelcome(timeout)
	if w.PlayerID == "" {
		t.Fatal("welcome carried empty player_id for a correct room code")
	}
}

// TestRoomCodeRejectsWrongCode confirms a Hello carrying the wrong RoomCode
// is refused with a legible Reject, not a bare hangup — see the ADR in
// agent_docs/architecture.md on why a rejection needs to be distinguishable
// from "the relay is just slow."
func TestRoomCodeRejectsWrongCode(t *testing.T) {
	s := NewServer()
	s.RoomCode = "letmein"
	addr := startServerWith(t, s)

	c1 := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "alice", RoomCode: "wrong",
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
	if reject.Reason == "" {
		t.Fatal("reject carried an empty reason")
	}
}

// TestEmptyConfiguredRoomCodeAcceptsAnyHello confirms the back-compat
// default: a relay with no RoomCode configured accepts a join regardless of
// what (if anything) the client's Hello.RoomCode contains — auth stays off
// unless the relay operator opts in, matching the pre-existing friend-hosted
// posture. agent_docs/architecture.md's ADR.
func TestEmptyConfiguredRoomCodeAcceptsAnyHello(t *testing.T) {
	addr := startServer(t) // NewServer(), RoomCode left empty

	c1 := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "alice", RoomCode: "whatever-i-feel-like",
	})
	defer c1.conn.Close()

	w := c1.expectWelcome(timeout)
	if w.PlayerID == "" {
		t.Fatal("welcome carried empty player_id when the relay has no room code configured")
	}
}

// TestOnlyGameAcceptsMatchingGame confirms a relay restricted to one game
// still accepts a client playing that game normally — see the ADR in
// agent_docs/architecture.md on the single-game relay setting.
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

// TestOnlyGameRejectsOtherGame confirms a client playing a different game
// than the relay is configured for is refused with a legible Reject naming
// that specific reason, not a bare hangup and not the per-room
// ReasonGameMismatch (no room this client could pick would help).
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

// TestEmptyOnlyGameAcceptsAnyGame confirms the back-compat default: a relay
// with no OnlyGame configured hosts whatever shows up, including two
// different games at once in different rooms — the pre-existing posture,
// unchanged unless the operator opts in. agent_docs/architecture.md's ADR.
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

// TestGameVersionMismatchRejected confirms a room's game_version, once
// declared, is sticky the same way game_id already is: a second client
// claiming a different game_version for the same room is refused, but a
// client that doesn't declare one at all is never refused for it.
// agent_docs/architecture.md's room-code/version ADR.
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

	// A client that doesn't declare a version at all must still be allowed
	// in — only a real mismatch between two declared versions is refused.
	c3 := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "carol",
	})
	defer c3.conn.Close()
	w3 := c3.expectWelcome(timeout)
	if w3.PlayerID == "" {
		t.Fatal("welcome carried empty player_id for a client with no declared game_version")
	}
}

// TestTryAddAndSnapshotRosterIsAtomic is a regression test for a bug found
// in a review pass: the join path used to call Room.roster() and
// Room.tryAdd() as two separate calls, so two clients joining concurrently
// could each snapshot the roster before either had actually added itself —
// neither would then appear in the other's Welcome roster or the resulting
// Join broadcast. tryAddAndSnapshotRoster combines both under one critical
// section so the snapshot for the Nth join always reflects exactly the
// N-1 members added before it, never fewer, by construction.
func TestTryAddAndSnapshotRosterIsAtomic(t *testing.T) {
	r := newRoom("emerald", "", "room1")

	roster1 := r.tryAddAndSnapshotRoster(&Client{PlayerID: "p1", Conn: &fakeStallingTransport{unblock: make(chan struct{})}})
	if len(roster1) != 0 {
		t.Fatalf("first join: roster=%v, want []", roster1)
	}

	roster2 := r.tryAddAndSnapshotRoster(&Client{PlayerID: "p2", Conn: &fakeStallingTransport{unblock: make(chan struct{})}})
	if len(roster2) != 1 || roster2[0] != "p1" {
		t.Fatalf("second join: roster=%v, want [p1]", roster2)
	}

	final := r.roster()
	if len(final) != 2 {
		t.Fatalf("final roster = %v, want both p1 and p2 present", final)
	}
}

// TestOversizedHelloFieldRejected confirms a Hello with a field over
// MaxHelloFieldLen is refused with ReasonHelloFieldTooLong. The
// DisplayName here is also paired with a bad ProtocolVersion, to confirm
// the length check runs *first* (a review-pass fix — previously the
// version check ran first and its rejectAndClose logged the full,
// oversized field value): if the version check won, the reject reason
// would be "protocol version mismatch" instead.
func TestOversizedHelloFieldRejected(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version + 1,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     strings.Repeat("a", MaxHelloFieldLen+1),
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

// TestPingGetsPong confirms the relay's pre-existing Ping handler (added
// alongside the protocol's Ping/Pong types, but never exercised by a real
// sender until internal/core's heartbeat fix — see the 2026-08-14 verified.md
// entry on the idle-timeout reconnect-ID churn bug) actually replies, and
// echoes the nonce back unchanged so a caller can match requests to replies.
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

// TestIdleConnectionWithoutPingIsDroppedByIdleTimeout is the "before the
// fix" control: with IdleTimeout shrunk to something waitable and no Ping
// (or any other traffic) sent, the relay closes the connection once it
// elapses. Proves the scenario the heartbeat fixes is real and this test
// harness actually exercises it — see
// TestHeartbeatKeepsIdleRelayConnectionAlive (internal/core/core_test.go)
// for the "after the fix" counterpart against the same knob.
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
		// expected: the relay's read deadline elapsed with nothing sent.
	case <-time.After(2 * time.Second):
		t.Fatal("connection was not dropped by IdleTimeout — test harness assumption is wrong")
	}
}

// --- Send/receive rate control (agent_docs/architecture.md's ADR) ---

// TestWelcomeAdvertisesConfiguredSendRate confirms a relay operator's
// configured Server.SendHz reaches a joining client verbatim in Welcome.
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

// TestWelcomeAdvertisesDefaultSendRateWhenUnconfigured confirms an
// unconfigured relay (Server.SendHz left at its zero value) advertises
// protocol.DefaultSendHz — the zero-means-default convention applied to
// this new field.
func TestWelcomeAdvertisesDefaultSendRateWhenUnconfigured(t *testing.T) {
	addr := startServer(t)
	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	w := c1.expectWelcome(timeout)
	if w.SendHz != protocol.DefaultSendHz {
		t.Fatalf("Welcome.SendHz = %d, want protocol.DefaultSendHz (%d)", w.SendHz, protocol.DefaultSendHz)
	}
}

// TestOutOfRangeSendRateIsClampedRatherThanRefused confirms an operator's
// bad server.send_hz value is clamped, not refused — a typo in a cosmetic
// tuning knob must not stop a relay from starting. Covers all four
// documented clamp cases: absent/zero and negative both fall back to the
// default; too low and too high are clamped to the nearest valid bound. Not
// table-driven subtests (this file's own convention) — a sequence of
// independent checks instead.
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

// TestReceiveCapThrottlesOnlyTheClientThatAskedForIt confirms the
// per-(sender,recipient) gate is genuinely per-recipient: a sender pushing a
// steady stream of states reaches an uncapped recipient at (close to) full
// rate, while a recipient that requested a 5Hz cap receives meaningfully
// fewer of the same messages — never zero (the gate always lets the first
// one through), never as many as the uncapped peer got.
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
				// Drain whatever already arrived before returning.
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

// TestReceiveCapDoesNotThrottleJoinOrLeave confirms a recipient's own
// receive gate — even set aggressively low — never blocks a Join or Leave.
// A throttled Leave would strand a permanently frozen ghost on that
// recipient's screen, exactly the failure this guarantee exists to prevent.
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

	// Several states in immediate succession -- capped's 1Hz gate will drop
	// all but (at most) the first of these, proving the gate is actually
	// active for this recipient.
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

// TestUncappedRecipientStillReceivesEveryState is the default-path
// regression: with no MaxReceiveHz set (every client today, and every older
// client forever), every single state sent must still arrive, byte for
// byte the same guarantee as before the receive-cap gate existed.
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

// TestRateLimitScalesWithConfiguredSendRate confirms a relay configured for
// a fast room (100Hz) tolerates proportionally more traffic before closing
// a connection — the historical flat 120/sec cap would have tripped well
// before this burst completes.
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
	// 100Hz * RateLimitHeadroomMultiple (6) = 600/sec cap. This burst is
	// well above the OLD flat 120 but comfortably under 600.
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
		// still open, as expected
	}

	// The connection must still work normally afterward, not just survive.
	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.sendState(protocol.State{PlayerID: w1.PlayerID, AreaID: "a", Position: []float64{2, 2}, Anim: "idle"})
	got := c2.next(timeout)
	if got.Type != protocol.TypeState {
		t.Fatalf("got %q, want %q", got.Type, protocol.TypeState)
	}
}

// TestRateLimitNeverFallsBelowTheHistoricalFloor confirms a relay
// configured for a SLOW room (10Hz) still tolerates the historical 120/sec
// floor, not the smaller scaled value (10*6=60) — turning a room down must
// never start disconnecting older clients still sending at their own
// built-in 20Hz default.
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
	// More than the scaled value (10*6=60) but fewer than the historical
	// floor (120) -- proves the floor, not the scaled-down value, applies.
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

// TestRateLimitedClientReceivesRejectBeforeClose confirms the rate-limit
// path sends a Reject (ReasonRateLimited) before closing, replacing the
// previous anonymous hangup — the same "refused/closed, and why" posture
// TypeReject already provides at handshake, extended to a mid-session close.
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

// TestReceiveGateForgetsASenderThatLeft is a white-box regression for
// Room.remove's gate purge: without it, a departed sender's entry would sit
// forever in every remaining member's receive gate (player_ids are never
// reused), one stale map entry per departure over a long-lived relay's
// life.
func TestReceiveGateForgetsASenderThatLeft(t *testing.T) {
	r := newRoom("emerald", "", "room1")
	sender := &Client{PlayerID: "p1", Conn: &fakeStallingTransport{unblock: make(chan struct{})}}
	// maxReceiveHz must be > 0 -- the uncapped (0) path short-circuits
	// allowStateFrom before it ever touches the gate map, so an uncapped
	// recipient would never actually exercise (or need) the purge below.
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
