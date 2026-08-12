package core

import (
	"encoding/json"
	"net"
	"sync"
	"testing"
	"time"

	"meshghost/internal/bridge"
	"meshghost/internal/protocol"
	"meshghost/internal/relay"
	"meshghost/internal/transport"
)

const testTimeout = 2 * time.Second

// startRelay starts a real relay.Server on an ephemeral port, per
// internal/relay — this test exercises Core against the actual relay
// implementation, not a mock.
func startRelay(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go relay.NewServer().Serve(ln)
	return ln.Addr().String()
}

// fakeAdapter stands in for a real adapter (BizHawk Lua, etc.) by dialing
// a Core's bridge listener directly and speaking the bridge wire protocol
// — the same thing a real adapter would do, minus the game.
type fakeAdapter struct {
	t    *testing.T
	conn *transport.NDJSONConn

	mu       sync.Mutex
	rendered map[string]protocol.State
	despawns chan string
}

func dialFakeAdapter(t *testing.T, bridgeAddr string) *fakeAdapter {
	t.Helper()
	conn, err := transport.Dial(bridgeAddr)
	if err != nil {
		t.Fatalf("dial bridge: %v", err)
	}
	fa := &fakeAdapter{
		t:        t,
		conn:     conn,
		rendered: make(map[string]protocol.State),
		despawns: make(chan string, 16),
	}
	conn.OnReceive(func(payload []byte) {
		var env bridge.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			t.Errorf("adapter received malformed envelope: %v", err)
			return
		}
		switch env.Type {
		case bridge.TypeRenderRemote:
			var rr bridge.RenderRemote
			if err := json.Unmarshal(env.Payload, &rr); err != nil {
				t.Errorf("unmarshal render_remote: %v", err)
				return
			}
			fa.mu.Lock()
			fa.rendered[rr.PlayerID] = rr.State
			fa.mu.Unlock()
		case bridge.TypeDespawnRemote:
			var dr bridge.DespawnRemote
			if err := json.Unmarshal(env.Payload, &dr); err != nil {
				t.Errorf("unmarshal despawn_remote: %v", err)
				return
			}
			fa.mu.Lock()
			delete(fa.rendered, dr.PlayerID)
			fa.mu.Unlock()
			fa.despawns <- dr.PlayerID
		}
	})
	return fa
}

// hello sends a bridge.Hello declaring gameID -- must be the first message
// on a fresh connection per agent_docs/contract.md, same as a real adapter.
func (fa *fakeAdapter) hello(gameID string) {
	fa.t.Helper()
	payload, err := json.Marshal(bridge.Hello{GameID: gameID})
	if err != nil {
		fa.t.Fatalf("marshal hello: %v", err)
	}
	env, err := json.Marshal(bridge.Envelope{Type: bridge.TypeHello, Payload: payload})
	if err != nil {
		fa.t.Fatalf("marshal envelope: %v", err)
	}
	if err := fa.conn.Send(env); err != nil {
		fa.t.Fatalf("send hello: %v", err)
	}
}

// frame simulates one adapter frame tick: sends the given local state (or
// none, for state == nil) to the core.
func (fa *fakeAdapter) frame(state *protocol.State) {
	fa.t.Helper()
	payload, err := json.Marshal(bridge.LocalState{State: state})
	if err != nil {
		fa.t.Fatalf("marshal local_state: %v", err)
	}
	env, err := json.Marshal(bridge.Envelope{Type: bridge.TypeLocalState, Payload: payload})
	if err != nil {
		fa.t.Fatalf("marshal envelope: %v", err)
	}
	if err := fa.conn.Send(env); err != nil {
		fa.t.Fatalf("send local_state: %v", err)
	}
}

func (fa *fakeAdapter) rendersOf(playerID string) (protocol.State, bool) {
	fa.mu.Lock()
	defer fa.mu.Unlock()
	st, ok := fa.rendered[playerID]
	return st, ok
}

func startCore(t *testing.T, relayAddr, gameID, room, name string) (*Core, string) {
	t.Helper()
	c := New()
	if err := c.ConnectRelay(relayAddr, gameID, room, name, testTimeout); err != nil {
		t.Fatalf("connect relay: %v", err)
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen bridge: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go c.ServeBridge(ln)

	return c, ln.Addr().String()
}

// startCoreLazy starts a Core the way cmd/meshghost does with no -game set:
// no relay connection yet, only the fields ConnectRelayOnAdapterHello needs
// to dial once a bridge.Hello actually arrives.
func startCoreLazy(t *testing.T, relayAddr, room, name string) (*Core, string) {
	t.Helper()
	c := New()
	c.RelayAddr = relayAddr
	c.Room = room
	c.DisplayName = name
	c.DialTimeout = testTimeout

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen bridge: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go c.ServeBridge(ln)

	return c, ln.Addr().String()
}

// waitForPlayerID polls until Core.PlayerID() is non-empty (i.e. ConnectRelay
// has completed) or testTimeout elapses.
func waitForPlayerID(t *testing.T, c *Core) {
	t.Helper()
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		if c.PlayerID() != "" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out waiting for core to connect to the relay")
}

// TestBridgeHelloConnectsToRelay confirms Core.ConnectRelayOnAdapterHello --
// the deferred-connect path used when -game/the config file didn't already
// supply one (agent_docs/architecture.md's 2026-08-12 ADR) -- actually
// connects once a real bridge.Hello arrives.
func TestBridgeHelloConnectsToRelay(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	adapter := dialFakeAdapter(t, bridgeAddr)
	adapter.hello("emerald")

	waitForPlayerID(t, c)
}

// TestLocalStateBeforeHelloDoesNotSendOrCrash confirms local_state frames
// arriving before any hello (or with no hello at all) are harmless no-ops --
// forwardLocalState's nil-relay check -- and that a late hello still works
// normally afterward, i.e. the earlier frames didn't leave the core wedged.
func TestLocalStateBeforeHelloDoesNotSendOrCrash(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	adapter := dialFakeAdapter(t, bridgeAddr)
	sent := protocol.State{AreaID: "a", Position: []float64{1, 2}, Anim: "idle"}
	for i := 0; i < 5; i++ {
		adapter.frame(&sent)
	}
	time.Sleep(50 * time.Millisecond)
	if c.PlayerID() != "" {
		t.Fatalf("core connected to the relay without ever receiving a hello (player id = %q)", c.PlayerID())
	}

	adapter.hello("emerald")
	waitForPlayerID(t, c)
}

// TestSecondHelloWithDifferentGameIsRefused confirms a single Core serves
// exactly one game per process: once connected to the relay for one
// game_id, ConnectRelayOnAdapterHello for a different game_id is refused
// rather than silently switching (agent_docs/architecture.md's ADR).
func TestSecondHelloWithDifferentGameIsRefused(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	adapter := dialFakeAdapter(t, bridgeAddr)
	adapter.hello("emerald")
	waitForPlayerID(t, c)
	firstPlayerID := c.PlayerID()

	if err := c.ConnectRelayOnAdapterHello("tevi"); err == nil {
		t.Fatal("expected an error connecting a second, different game_id to an already-connected core, got nil")
	}
	if c.PlayerID() != firstPlayerID {
		t.Fatalf("core's relay connection changed after a refused second hello: got player id %q, want unchanged %q", c.PlayerID(), firstPlayerID)
	}

	// The original game_id must still be a no-op, not also refused.
	if err := c.ConnectRelayOnAdapterHello("emerald"); err != nil {
		t.Fatalf("re-hello for the same game_id should be a no-op, got error: %v", err)
	}
}

// TestAdapterHelloAfterStartupConnectIsNoOp confirms the *other* -game/config
// startup path (startCore, direct ConnectRelay -- used by every dev-scripts
// run-core*.bat that passes -game explicitly) also records which game_id it
// connected as, so a real adapter's hello for that same game_id arriving
// afterward is a no-op, not treated as a second, conflicting game. Found
// live 2026-08-12 testing Phase 7's Pseudoregalia probe: ConnectRelay never
// set relayGame, so ConnectRelayOnAdapterHello always compared the real
// hello's game_id against "", refused it as a mismatch, and closed the
// bridge connection -- a regression hitting any adapter sending hello
// (Emerald and TEVI both do, per agent_docs/architecture.md's 2026-08-12
// ADR) against a core started with an explicit -game.
func TestAdapterHelloAfterStartupConnectIsNoOp(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCore(t, relayAddr, "pseudoregalia", "room1", "alice")
	firstPlayerID := c.PlayerID()

	adapter := dialFakeAdapter(t, bridgeAddr)
	var disconnected bool
	adapter.conn.OnDisconnect(func(err error) { disconnected = true })
	adapter.hello("pseudoregalia")
	time.Sleep(50 * time.Millisecond)

	if disconnected {
		t.Fatal("bridge connection was closed after a same-game hello -- the real symptom of the mismatch bug")
	}
	if c.PlayerID() != firstPlayerID {
		t.Fatalf("core's relay connection changed after a same-game hello: got player id %q, want unchanged %q", c.PlayerID(), firstPlayerID)
	}

	// The connection must still be usable afterward, not just left open.
	adapter.frame(&protocol.State{AreaID: "a", Position: []float64{1, 2}, Anim: "idle"})
	time.Sleep(50 * time.Millisecond)
	if disconnected {
		t.Fatal("bridge connection was closed after a post-hello local_state frame")
	}
}

// TestTwoCoresExchangeStateOverRealRelay is the Phase 3/4 milestone in
// miniature: two Core instances, each driven by a fake adapter standing in
// for a real one, connect to one real relay and a state sent by one
// player's adapter shows up as a render_remote on the other's.
func TestTwoCoresExchangeStateOverRealRelay(t *testing.T) {
	relayAddr := startRelay(t)

	core1, bridge1Addr := startCore(t, relayAddr, "emerald", "room1", "alice")
	core2, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter2 := dialFakeAdapter(t, bridge2Addr)

	// Give core2's join a moment to land at the relay before core1 sends
	// state, so the relay's room already has both members (this is what
	// the loopback/two-player milestone actually exercises: both are
	// already in the room, not racing to join).
	time.Sleep(50 * time.Millisecond)

	sent := protocol.State{
		AreaID:   "emerald-0001",
		Position: []float64{12, 34},
		Anim:     "walking",
	}
	adapter1.frame(&sent)

	deadline := time.Now().Add(testTimeout)
	var got protocol.State
	var ok bool
	for time.Now().Before(deadline) {
		adapter2.frame(nil) // each frame tick is what causes core2 to push renders
		if got, ok = adapter2.rendersOf(core1.PlayerID()); ok {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !ok {
		t.Fatalf("adapter2 never received a render_remote for %s", core1.PlayerID())
	}
	if got.AreaID != sent.AreaID || got.Anim != sent.Anim {
		t.Fatalf("rendered state = %+v, want area_id=%s anim=%s", got, sent.AreaID, sent.Anim)
	}
	if len(got.Position) != 2 || got.Position[0] != sent.Position[0] || got.Position[1] != sent.Position[1] {
		t.Fatalf("rendered position = %v, want %v (single sample, no interpolation window yet)", got.Position, sent.Position)
	}

	_ = core2 // core2 is exercised entirely through adapter2's frames above
}

// TestDisconnectDespawnsRemote confirms a player's bridge connection sees
// a despawn_remote once the relay reports the peer left.
func TestDisconnectDespawnsRemote(t *testing.T) {
	relayAddr := startRelay(t)

	core1, bridge1Addr := startCore(t, relayAddr, "emerald", "room1", "alice")
	_, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter2 := dialFakeAdapter(t, bridge2Addr)
	time.Sleep(50 * time.Millisecond)

	sent := protocol.State{AreaID: "a", Position: []float64{1, 1}, Anim: "idle"}
	adapter1.frame(&sent)

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		adapter2.frame(nil)
		if _, ok := adapter2.rendersOf(core1.PlayerID()); ok {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, ok := adapter2.rendersOf(core1.PlayerID()); !ok {
		t.Fatal("setup failed: adapter2 never saw core1 rendered before disconnect test")
	}

	// Closing core1's relay connection (not the bridge) is what makes the
	// relay observe a disconnect and broadcast a Leave — that's the signal
	// that should flow through to adapter2 as a despawn_remote.
	if err := core1.relay.Close(); err != nil {
		t.Fatalf("close core1 relay connection: %v", err)
	}

	// despawn_remote is only pushed in response to an adapter frame call
	// (the adapter always drives, per the tick model), so keep ticking
	// frames until the Leave has propagated through the relay to core2.
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	deadline2 := time.After(testTimeout)
	for {
		select {
		case id := <-adapter2.despawns:
			if id != core1.PlayerID() {
				t.Fatalf("despawned id = %q, want %q", id, core1.PlayerID())
			}
			return
		case <-ticker.C:
			adapter2.frame(nil)
		case <-deadline2:
			t.Fatal("timed out waiting for despawn_remote")
		}
	}
}

// TestOwnRelayDisconnectDespawnsRemotes covers a different failure than
// TestDisconnectDespawnsRemote: there, a *peer* disconnects and the relay
// tells everyone else via Leave. Here, *this Core's own* connection to the
// relay is lost (found live during Phase 3 verification: killing the relay
// process left a loopback ghost frozen in place forever, tracking nothing,
// because nothing cleared its last known snapshot). No Leave can ever
// arrive once the relay itself is gone, so the Core must proactively clear
// its remotes on its own disconnect rather than waiting for one.
func TestOwnRelayDisconnectDespawnsRemotes(t *testing.T) {
	relayAddr := startRelay(t)

	core1, bridge1Addr := startCore(t, relayAddr, "emerald", "room1", "alice")
	core2, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter2 := dialFakeAdapter(t, bridge2Addr)
	time.Sleep(50 * time.Millisecond)

	sent := protocol.State{AreaID: "a", Position: []float64{1, 1}, Anim: "idle"}
	adapter1.frame(&sent)

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		adapter2.frame(nil)
		if _, ok := adapter2.rendersOf(core1.PlayerID()); ok {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, ok := adapter2.rendersOf(core1.PlayerID()); !ok {
		t.Fatal("setup failed: adapter2 never saw core1 rendered before disconnect test")
	}

	// Close core2's OWN relay connection this time (not core1's) — no Leave
	// message is possible after this, since core2 has no relay connection
	// left to receive one on.
	if err := core2.relay.Close(); err != nil {
		t.Fatalf("close core2 relay connection: %v", err)
	}

	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	deadline2 := time.After(testTimeout)
	for {
		select {
		case id := <-adapter2.despawns:
			if id != core1.PlayerID() {
				t.Fatalf("despawned id = %q, want %q", id, core1.PlayerID())
			}
			return
		case <-ticker.C:
			adapter2.frame(nil)
		case <-deadline2:
			t.Fatal("timed out waiting for despawn_remote after own relay disconnect")
		}
	}
}

// inProcessAdapter is Phase 5's proof shape: a type satisfying core.Adapter
// with no bridge socket at all, no game, and — critically — this test file
// imports nothing under adapters/. If the core had a game-specific leak,
// driving it purely through this interface (RunAdapter) rather than the
// bridge wire protocol is where it would surface.
type inProcessAdapter struct {
	localState protocol.State
	sendLocal  bool

	mu       sync.Mutex
	rendered map[string]protocol.State
	despawns chan string
}

func newInProcessAdapter() *inProcessAdapter {
	return &inProcessAdapter{
		rendered: make(map[string]protocol.State),
		despawns: make(chan string, 16),
	}
}

func (a *inProcessAdapter) GetLocalState() (protocol.State, bool) {
	return a.localState, a.sendLocal
}

func (a *inProcessAdapter) RenderRemote(playerID string, state protocol.State) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.rendered[playerID] = state
}

func (a *inProcessAdapter) DespawnRemote(playerID string) {
	a.mu.Lock()
	delete(a.rendered, playerID)
	a.mu.Unlock()
	a.despawns <- playerID
}

func (a *inProcessAdapter) rendersOf(playerID string) (protocol.State, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	st, ok := a.rendered[playerID]
	return st, ok
}

// TestRunAdapterInProcess is the Phase 5 milestone: the same
// state-exchange-over-a-real-relay behavior as
// TestTwoCoresExchangeStateOverRealRelay, but with both Cores driven by
// RunAdapter against an in-process core.Adapter instead of a bridge socket
// — confirming the core works standalone, with no game and no adapter
// process attached.
func TestRunAdapterInProcess(t *testing.T) {
	relayAddr := startRelay(t)

	core1 := New()
	if err := core1.ConnectRelay(relayAddr, "faketest", "room1", "alice", testTimeout); err != nil {
		t.Fatalf("connect core1: %v", err)
	}
	core2 := New()
	if err := core2.ConnectRelay(relayAddr, "faketest", "room1", "bob", testTimeout); err != nil {
		t.Fatalf("connect core2: %v", err)
	}

	adapter1 := newInProcessAdapter()
	adapter1.sendLocal = true
	adapter1.localState = protocol.State{AreaID: "fake-arena", Position: []float64{12, 34}, Anim: "walking"}
	adapter2 := newInProcessAdapter()

	stop := make(chan struct{})
	defer close(stop)
	go core1.RunAdapter(adapter1, 10*time.Millisecond, stop)
	go core2.RunAdapter(adapter2, 10*time.Millisecond, stop)

	deadline := time.Now().Add(testTimeout)
	var got protocol.State
	var ok bool
	for time.Now().Before(deadline) {
		if got, ok = adapter2.rendersOf(core1.PlayerID()); ok {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !ok {
		t.Fatalf("adapter2 never received a render for %s", core1.PlayerID())
	}
	if got.AreaID != adapter1.localState.AreaID || got.Anim != adapter1.localState.Anim {
		t.Fatalf("rendered state = %+v, want area_id=%s anim=%s", got, adapter1.localState.AreaID, adapter1.localState.Anim)
	}
}

// countingTransport is a minimal transport.Transport stand-in that just
// counts Send calls, for testing forwardLocalState's rate cap without a
// real relay in the loop.
type countingTransport struct {
	mu    sync.Mutex
	sends int
}

func (ct *countingTransport) Send(payload []byte) error {
	ct.mu.Lock()
	ct.sends++
	ct.mu.Unlock()
	return nil
}
func (ct *countingTransport) OnReceive(func([]byte))   {}
func (ct *countingTransport) OnConnect(func())         {}
func (ct *countingTransport) OnDisconnect(func(error)) {}
func (ct *countingTransport) OnError(func(error))      {}
func (ct *countingTransport) Close() error             { return nil }

func (ct *countingTransport) count() int {
	ct.mu.Lock()
	defer ct.mu.Unlock()
	return ct.sends
}

// TestForwardLocalStateRespectsMinSendInterval is a regression test for the
// Phase 6 (TEVI) bug found live: a Unity adapter's Update() calls in well
// above the relay's 120 messages/second limit, and forwardLocalState used to
// send to the relay on every single call, getting the connection closed by
// the relay after a couple of minutes (agent_docs/verified.md's Phase
// 6.4/6.5 entry). This drives forwardLocalState far faster than
// MinSendInterval and checks the actual send count stays capped rather than
// tracking the call count 1:1.
func TestForwardLocalStateRespectsMinSendInterval(t *testing.T) {
	c := New()
	c.MinSendInterval = 20 * time.Millisecond
	ct := &countingTransport{}
	c.relay = ct
	c.playerID = "p1"

	state := protocol.State{AreaID: "a", Position: []float64{1, 2}, Anim: "idle"}

	const callCount = 1000
	start := time.Now()
	for i := 0; i < callCount; i++ {
		c.forwardLocalState(&state)
	}
	elapsed := time.Since(start)

	// A tight loop of 1000 calls with no sleep should complete in well under
	// one MinSendInterval, so this is really checking "far fewer sends than
	// calls", not timing precision -- generous upper bound (10) so this
	// isn't flaky on a slow CI machine, while still failing hard against the
	// original 1:1 bug (which would report sends == 1000).
	maxExpectedSends := int(elapsed/c.MinSendInterval) + 10
	got := ct.count()
	if got >= callCount {
		t.Fatalf("forwardLocalState sent on every call (%d sends for %d calls) -- MinSendInterval cap is not working", got, callCount)
	}
	if got > maxExpectedSends {
		t.Fatalf("sends = %d, want at most ~%d for %v elapsed at a %v interval", got, maxExpectedSends, elapsed, c.MinSendInterval)
	}
	if got < 1 {
		t.Fatalf("expected at least the first call to send, got 0 sends")
	}
}
