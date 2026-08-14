package core

import (
	"encoding/json"
	"net"
	"strings"
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
	return startRelayWith(t, relay.NewServer())
}

// startRelayWith is startRelay's more general form, for tests that need a
// non-default Server (e.g. RoomCode set) — added alongside relay-safety
// hardening, agent_docs/architecture.md's room-code/version ADR.
func startRelayWith(t *testing.T, s *relay.Server) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go s.Serve(ln)
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
	fa.helloWithVersion(gameID, "")
}

// helloWithVersion is hello's more general form, for tests exercising the
// game-version check — added alongside relay-safety hardening,
// agent_docs/architecture.md's room-code/version ADR.
func (fa *fakeAdapter) helloWithVersion(gameID, gameVersion string) {
	fa.t.Helper()
	payload, err := json.Marshal(bridge.Hello{GameID: gameID, GameVersion: gameVersion})
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
	c.RelayAddr = relayAddr
	c.Room = room
	c.DisplayName = name
	c.DialTimeout = testTimeout
	if err := c.ConnectRelay(gameID); err != nil {
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

	if err := c.ConnectRelayOnAdapterHello("tevi", "", nil); err == nil {
		t.Fatal("expected an error connecting a second, different game_id to an already-connected core, got nil")
	}
	if c.PlayerID() != firstPlayerID {
		t.Fatalf("core's relay connection changed after a refused second hello: got player id %q, want unchanged %q", c.PlayerID(), firstPlayerID)
	}

	// The original game_id must still be a no-op, not also refused.
	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err != nil {
		t.Fatalf("re-hello for the same game_id should be a no-op, got error: %v", err)
	}
}

// TestMismatchedSecondAdapterDoesNotKillFirstAdaptersRelaySession is a
// regression test for a bug found in a review pass: handleBridgeConn's
// OnDisconnect used to close c.relay for *any* bridge connection dropping,
// including one that never became the adapter at all. A second real
// adapter connecting to the same bridge port with a different game_id gets
// refused (TestSecondHelloWithDifferentGameIsRefused above already covers
// that) and its bridge connection closed — that used to also tear down the
// *first* adapter's completely unrelated, already-working relay session,
// since the close handler didn't check which bridge connection actually
// owned it. Proven here by exchanging real state with a second, genuinely
// separate Core/peer after the mismatched second adapter is refused — not
// just checking PlayerID() stayed the same, which could pass even with a
// silently-dead relay connection.
func TestMismatchedSecondAdapterDoesNotKillFirstAdaptersRelaySession(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	first := dialFakeAdapter(t, bridgeAddr)
	first.hello("emerald")
	waitForPlayerID(t, c)
	firstPlayerID := c.PlayerID()

	second := dialFakeAdapter(t, bridgeAddr)
	disconnected := make(chan struct{})
	second.conn.OnDisconnect(func(err error) { close(disconnected) })
	second.hello("tevi")

	select {
	case <-disconnected:
	case <-time.After(testTimeout):
		t.Fatal("timed out waiting for the mismatched second adapter's bridge connection to be refused")
	}

	if c.PlayerID() != firstPlayerID {
		t.Fatalf("first adapter's relay session was disrupted: player id changed from %q to %q", firstPlayerID, c.PlayerID())
	}

	// Prove the relay connection is genuinely still alive, not just that
	// PlayerID() happens to hold a stale value: bring in a real second
	// peer and confirm state sent by the first adapter still reaches it.
	core2, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")
	adapter2 := dialFakeAdapter(t, bridge2Addr)
	time.Sleep(50 * time.Millisecond)

	sent := protocol.State{AreaID: "emerald-0001", Position: []float64{5, 6}, Anim: "walking"}
	first.frame(&sent)

	deadline := time.Now().Add(testTimeout)
	var ok bool
	for time.Now().Before(deadline) {
		adapter2.frame(nil)
		if _, ok = adapter2.rendersOf(firstPlayerID); ok {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !ok {
		t.Fatalf("adapter2 never received a render_remote for %s -- first adapter's relay session did not survive the mismatched second adapter's refusal", firstPlayerID)
	}
	_ = core2
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
	firstPlayerID := core1.PlayerID() // captured before disconnect clears it

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
			if id != firstPlayerID {
				t.Fatalf("despawned id = %q, want %q", id, firstPlayerID)
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

// TestBridgeDisconnectDespawnsForPeer covers a third disconnect shape, found
// live 2026-08-13 during the first real two-player TEVI test: a player
// backing out to the main menu (or closing the game) left their ghost frozen
// in the other player's world forever, because nothing told the relay this
// player was gone. Closing the *bridge* connection (the adapter/game side,
// not the relay side covered by the two tests above) must now cascade into
// closing this Core's relay connection, which the relay turns into a real
// Leave for the peer.
func TestBridgeDisconnectDespawnsForPeer(t *testing.T) {
	relayAddr := startRelay(t)

	core1, bridge1Addr := startCore(t, relayAddr, "emerald", "room1", "alice")
	_, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter2 := dialFakeAdapter(t, bridge2Addr)

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
	firstPlayerID := core1.PlayerID() // captured before disconnect clears it

	// Close adapter1's BRIDGE connection -- the adapter/game side, simulating
	// the game exiting or its BridgeClient socket dropping. Not core1.relay
	// directly, which is what the two tests above already cover.
	if err := adapter1.conn.Close(); err != nil {
		t.Fatalf("close adapter1 bridge connection: %v", err)
	}

	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	deadline2 := time.After(testTimeout)
	for {
		select {
		case id := <-adapter2.despawns:
			if id != firstPlayerID {
				t.Fatalf("despawned id = %q, want %q", id, firstPlayerID)
			}
			return
		case <-ticker.C:
			adapter2.frame(nil)
		case <-deadline2:
			t.Fatal("timed out waiting for despawn_remote after bridge disconnect")
		}
	}
}

// TestReconnectAfterBridgeDisconnectGetsFreshPlayerID confirms the other
// half of the same fix: a bridge disconnect must not leave the Core wedged.
// After the adapter/game reconnects (a fresh bridge connection sending a new
// hello), the Core must redial the relay and be assigned a new player_id --
// one live ghost on reconnect, not a stale one plus a new one.
func TestReconnectAfterBridgeDisconnectGetsFreshPlayerID(t *testing.T) {
	relayAddr := startRelay(t)

	// startCoreLazy, not startCore: reconnecting via ConnectRelayOnAdapterHello
	// needs RelayAddr/Room/DisplayName/DialTimeout set on the Core, which only
	// the lazy path populates (see cmd/meshghost/main.go -- both -game and
	// no-game startup set these fields before ServeBridge either way).
	c, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	adapter := dialFakeAdapter(t, bridgeAddr)
	adapter.hello("emerald")
	waitForPlayerID(t, c)
	firstPlayerID := c.PlayerID()

	if err := adapter.conn.Close(); err != nil {
		t.Fatalf("close bridge connection: %v", err)
	}

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) && c.PlayerID() != "" {
		time.Sleep(10 * time.Millisecond)
	}
	if c.PlayerID() != "" {
		t.Fatalf("core did not clear its player id after bridge disconnect, still %q", c.PlayerID())
	}

	adapter2 := dialFakeAdapter(t, bridgeAddr)
	adapter2.hello("emerald")
	waitForPlayerID(t, c)

	if c.PlayerID() == "" || c.PlayerID() == firstPlayerID {
		t.Fatalf("core did not get a fresh player id on reconnect: first = %q, second = %q", firstPlayerID, c.PlayerID())
	}
}

// TestRelayDisconnectAutoReconnects confirms the 2026-08-14 fix found during
// live two-TEVI testing: a relay that drops *after* a successful connect
// (crash, restart, network blip) — while the adapter's own bridge connection
// stays healthy the whole time — must not leave the Core wedged forever. No
// new bridge Hello is sent here (the opposite of
// TestReconnectAfterBridgeDisconnectGetsFreshPlayerID above, which covers the
// bridge-driven case and must NOT auto-reconnect); this only closes the
// relay side, the same simulated-drop shape as
// TestOwnRelayDisconnectDespawnsRemotes.
func TestRelayDisconnectAutoReconnects(t *testing.T) {
	relayAddr := startRelay(t)

	c, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	adapter := dialFakeAdapter(t, bridgeAddr)
	adapter.hello("emerald")
	waitForPlayerID(t, c)
	firstPlayerID := c.PlayerID()

	c.mu.Lock()
	relay := c.relay
	c.mu.Unlock()
	if err := relay.Close(); err != nil {
		t.Fatalf("close relay connection: %v", err)
	}

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		if id := c.PlayerID(); id != "" && id != firstPlayerID {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("core did not auto-reconnect with a fresh player id after a relay-side drop (still %q)", c.PlayerID())
}

// TestCrossAreaFiltersRemote confirms the 2026-08-13 cross-area filtering
// fix: a remote whose area_id differs from this Core's own current area is
// excluded from rendering, and reappears once areas match again. Found live
// during a real two-player TEVI test: without this, a remote's ghost kept
// rendering at its own zone's raw world coordinates regardless of which zone
// the local player was actually in -- invisible only by coincidence when the
// two zones' coordinate ranges didn't happen to overlap on screen.
func TestCrossAreaFiltersRemote(t *testing.T) {
	relayAddr := startRelay(t)

	core1, bridge1Addr := startCore(t, relayAddr, "emerald", "room1", "alice")
	core1.MinSendInterval = time.Millisecond // several real state changes must land quickly, not just one
	_, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter2 := dialFakeAdapter(t, bridge2Addr)

	// adapter2 must establish its own core's local area before filtering
	// engages at all -- see remoteStatesAt's comment on the empty-
	// localAreaID passthrough case.
	self := protocol.State{AreaID: "zone-a", Position: []float64{0, 0}, Anim: "idle"}
	adapter2.frame(&self)

	adapter1.frame(&protocol.State{AreaID: "zone-a", Position: []float64{1, 1}, Anim: "idle"})

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		adapter2.frame(&self)
		if _, ok := adapter2.rendersOf(core1.PlayerID()); ok {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, ok := adapter2.rendersOf(core1.PlayerID()); !ok {
		t.Fatal("setup failed: adapter2 never saw core1 rendered while in the same area")
	}

	// core1 moves to a different area -- adapter2 must despawn it.
	adapter1.frame(&protocol.State{AreaID: "zone-b", Position: []float64{1, 1}, Anim: "idle"})

	deadline2 := time.Now().Add(testTimeout)
	despawned := false
	for !despawned && time.Now().Before(deadline2) {
		adapter2.frame(&self)
		select {
		case id := <-adapter2.despawns:
			if id != core1.PlayerID() {
				t.Fatalf("despawned id = %q, want %q", id, core1.PlayerID())
			}
			despawned = true
		default:
			time.Sleep(10 * time.Millisecond)
		}
	}
	if !despawned {
		t.Fatal("timed out waiting for despawn_remote after core1 left adapter2's area")
	}
	if _, ok := adapter2.rendersOf(core1.PlayerID()); ok {
		t.Fatal("core1 still rendered for adapter2 after moving to a different area")
	}

	// core1 returns to adapter2's area -- must reappear.
	adapter1.frame(&protocol.State{AreaID: "zone-a", Position: []float64{2, 2}, Anim: "idle"})

	deadline3 := time.Now().Add(testTimeout)
	for time.Now().Before(deadline3) {
		adapter2.frame(&self)
		if _, ok := adapter2.rendersOf(core1.PlayerID()); ok {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("core1 did not reappear for adapter2 after returning to the same area")
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
	core1.RelayAddr, core1.Room, core1.DisplayName, core1.DialTimeout = relayAddr, "room1", "alice", testTimeout
	if err := core1.ConnectRelay("faketest"); err != nil {
		t.Fatalf("connect core1: %v", err)
	}
	core2 := New()
	core2.RelayAddr, core2.Room, core2.DisplayName, core2.DialTimeout = relayAddr, "room1", "bob", testTimeout
	if err := core2.ConnectRelay("faketest"); err != nil {
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

// TestConnectRelayWithWrongRoomCodeReturnsReadableError confirms a Core
// refused by a room-code-enabled relay gets a real, readable error back
// promptly — not the "timed out waiting for welcome" message it would have
// gotten before the relay sent a Reject, which is indistinguishable from a
// slow or down relay. agent_docs/architecture.md's room-code/version ADR.
func TestConnectRelayWithWrongRoomCodeReturnsReadableError(t *testing.T) {
	s := relay.NewServer()
	s.RoomCode = "letmein"
	relayAddr := startRelayWith(t, s)

	c := New()
	c.RelayAddr = relayAddr
	c.Room = "room1"
	c.DisplayName = "alice"
	c.RoomCode = "wrong-code"
	c.DialTimeout = testTimeout
	start := time.Now()
	err := c.ConnectRelay("emerald")
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected an error connecting with the wrong room code, got nil")
	}
	if elapsed >= testTimeout {
		t.Fatalf("ConnectRelay took the full timeout (%v) instead of returning promptly on Reject", elapsed)
	}
}

// TestConnectRelayWithCorrectRoomCodeSucceeds confirms the matching case:
// the right code still connects normally through the same path.
func TestConnectRelayWithCorrectRoomCodeSucceeds(t *testing.T) {
	s := relay.NewServer()
	s.RoomCode = "letmein"
	relayAddr := startRelayWith(t, s)

	c := New()
	c.RelayAddr = relayAddr
	c.Room = "room1"
	c.DisplayName = "alice"
	c.RoomCode = "letmein"
	c.DialTimeout = testTimeout
	if err := c.ConnectRelay("emerald"); err != nil {
		t.Fatalf("connect relay with correct room code: %v", err)
	}
	if c.PlayerID() == "" {
		t.Fatal("PlayerID empty after a successful room-code-gated connect")
	}
}

// TestBridgeHelloGameVersionReachesRelay confirms an adapter-reported
// game_version (over bridge.Hello) actually propagates all the way through
// Core.ConnectRelayOnAdapterHello into the relay's own Hello, by driving two
// real Cores whose adapters declare different versions for the same room
// and confirming the second is refused — the same real end-to-end path a
// live game would use, not just the relay-level unit test
// (TestGameVersionMismatchRejected in internal/relay). See the ADR in
// agent_docs/architecture.md.
func TestBridgeHelloGameVersionReachesRelay(t *testing.T) {
	relayAddr := startRelay(t)

	c1, bridgeAddr1 := startCoreLazy(t, relayAddr, "room1", "alice")
	adapter1 := dialFakeAdapter(t, bridgeAddr1)
	adapter1.helloWithVersion("emerald", "1.0")
	waitForPlayerID(t, c1)

	c2, bridgeAddr2 := startCoreLazy(t, relayAddr, "room1", "bob")
	adapter2 := dialFakeAdapter(t, bridgeAddr2)

	disconnected := make(chan struct{})
	adapter2.conn.OnDisconnect(func(err error) { close(disconnected) })
	adapter2.helloWithVersion("emerald", "2.0")

	select {
	case <-disconnected:
	case <-time.After(testTimeout):
		t.Fatal("timed out waiting for the bridge connection to close after a game_version mismatch")
	}
	if c2.PlayerID() != "" {
		t.Fatalf("core2 got a player_id despite a game_version mismatch: %q", c2.PlayerID())
	}
}

// TestStateForUnknownPlayerIDIsIgnored confirms a State arriving for a
// player_id this Core never saw via Welcome/Join is dropped rather than
// silently creating a remote. Before this, the Core trusted any player_id
// arriving in a State completely and discarded Welcome.Roster entirely, so
// a hostile or compromised relay could inject state for an arbitrary id.
// See the ADR in agent_docs/architecture.md.
func TestStateForUnknownPlayerIDIsIgnored(t *testing.T) {
	c := New()
	c.playerID = "self"

	payload, err := json.Marshal(protocol.State{
		PlayerID: "ghost-nobody-announced",
		AreaID:   "a",
		Position: []float64{1, 2},
		Anim:     "idle",
	})
	if err != nil {
		t.Fatalf("marshal state: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeState, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}

	welcome := make(chan protocol.Welcome, 1)
	reject := make(chan protocol.Reject, 1)
	c.handleRelayMessage(env, welcome, reject)

	c.mu.Lock()
	_, exists := c.remotes["ghost-nobody-announced"]
	c.mu.Unlock()
	if exists {
		t.Fatal("state for an unannounced player_id created a remote — roster check not enforced")
	}
}

// TestSecondWelcomeIgnored confirms a second Welcome mid-connection doesn't
// reset this Core's roster or get pushed to the handshake's welcome
// channel — Welcome is protocol-illegal outside the initial handshake, and
// a hostile relay resending one (e.g. with a roster naming an id it wants
// this Core to trust) must not be able to reset state. agent_docs/architecture.md's ADR.
func TestSecondWelcomeIgnored(t *testing.T) {
	c := New()
	c.playerID = "p1"
	c.roster["p2"] = struct{}{}

	payload, err := json.Marshal(protocol.Welcome{PlayerID: "p1", Roster: []string{"attacker-injected-id"}})
	if err != nil {
		t.Fatalf("marshal welcome: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeWelcome, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}

	welcome := make(chan protocol.Welcome, 1)
	reject := make(chan protocol.Reject, 1)
	c.handleRelayMessage(env, welcome, reject)

	c.mu.Lock()
	_, stillKnown := c.roster["p2"]
	_, injected := c.roster["attacker-injected-id"]
	c.mu.Unlock()
	if !stillKnown {
		t.Fatal("a second Welcome cleared the existing roster")
	}
	if injected {
		t.Fatal("a second Welcome's roster was applied despite already being connected")
	}
	select {
	case <-welcome:
		t.Fatal("a second Welcome was pushed to the handshake's welcome channel")
	default:
	}
}

// TestOversizedInboundStateFieldsDropped confirms a State arriving from the
// relay with a field over its cap is dropped rather than stored, mirroring
// the relay's own checks — defense in depth against a hostile or
// compromised relay, which was previously trusted completely on the
// receive side. agent_docs/architecture.md's ADR.
func TestOversizedInboundStateFieldsDropped(t *testing.T) {
	c := New()
	c.playerID = "self"
	c.roster["p2"] = struct{}{}

	c.storeRemoteState(protocol.State{
		PlayerID: "p2",
		AreaID:   strings.Repeat("a", protocol.MaxAreaIDLen+1),
		Position: []float64{1, 2},
		Anim:     "idle",
	})

	c.mu.Lock()
	_, exists := c.remotes["p2"]
	c.mu.Unlock()
	if exists {
		t.Fatal("oversized AreaID was accepted instead of dropped")
	}
}

// TestKnownPlayerIDStateIsAccepted is TestStateForUnknownPlayerIDIsIgnored's
// converse: a State for a player_id actually in the roster (as a real
// Welcome/Join would populate it) must still be stored normally — the
// roster check must not become a second, redundant despawn mechanism.
func TestKnownPlayerIDStateIsAccepted(t *testing.T) {
	c := New()
	c.playerID = "self"
	c.roster["p2"] = struct{}{}

	c.storeRemoteState(protocol.State{PlayerID: "p2", AreaID: "a", Position: []float64{1, 2}, Anim: "idle"})

	c.mu.Lock()
	_, exists := c.remotes["p2"]
	c.mu.Unlock()
	if !exists {
		t.Fatal("state for a known (rostered) player_id was dropped")
	}
}

// TestConnectRelayOnAdapterHelloRetriesUntilRelayUp confirms a Core can be
// pointed at a relay address before anything is listening there, get a
// (non-permanent) dial failure, and succeed on a later retry once a real
// relay actually starts on that same address — the scenario behind
// cmd/meshghost's connectRelayWithRetry, added after the user asked
// whether the client and relay had to be started in a specific order.
func TestConnectRelayOnAdapterHelloRetriesUntilRelayUp(t *testing.T) {
	// Reserve an address, then free it immediately so nothing is actually
	// listening there yet.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve address: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	c := New()
	c.RelayAddr = addr
	c.Room = "room1"
	c.DisplayName = "alice"
	c.DialTimeout = testTimeout

	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err == nil {
		t.Fatal("expected a dial failure connecting before the relay exists, got nil")
	} else if IsPermanentRejectErr(err) {
		t.Fatalf("a plain dial failure was misclassified as permanent: %v", err)
	}

	// Now actually start the relay on the same address and retry.
	ln2, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("listen on reserved address %s: %v", addr, err)
	}
	t.Cleanup(func() { ln2.Close() })
	go relay.NewServer().Serve(ln2)

	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err != nil {
		t.Fatalf("retry after relay came up should succeed, got: %v", err)
	}
	waitForPlayerID(t, c)
	if c.PlayerID() == "" {
		t.Fatal("PlayerID still empty after a successful retry")
	}
}

// TestConnectRelayOnAdapterHelloCachesPermanentReject confirms a permanent
// rejection (e.g. a wrong room code) is cached after the first attempt — a
// later retry for the same gameID returns the identical cached error
// without re-dialing the relay, proven here by shutting the relay down
// entirely between the two calls: a real second dial would fail
// differently (connection refused), not with the same reject reason. This
// is what stops a retrying adapter from spamming the relay (and this
// process's own log) with an identical, hopeless connection attempt every
// couple of seconds forever.
func TestConnectRelayOnAdapterHelloCachesPermanentReject(t *testing.T) {
	s := relay.NewServer()
	s.RoomCode = "letmein"
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	go s.Serve(ln)

	c := New()
	c.RelayAddr = addr
	c.Room = "room1"
	c.DisplayName = "alice"
	c.RoomCode = "wrong-code"
	c.DialTimeout = testTimeout

	err = c.ConnectRelayOnAdapterHello("emerald", "", nil)
	if err == nil {
		t.Fatal("expected a rejection for the wrong room code, got nil")
	}
	if !IsPermanentRejectErr(err) {
		t.Fatalf("wrong room code should be classified as a permanent rejection, got: %v", err)
	}

	// Shut the relay down entirely -- a real second dial would now fail
	// differently (connection refused), not with the same reject reason.
	ln.Close()

	err2 := c.ConnectRelayOnAdapterHello("emerald", "", nil)
	if err2 == nil {
		t.Fatal("expected the cached rejection to still be returned, got nil")
	}
	if err2.Error() != err.Error() {
		t.Fatalf("second call = %v, want the identical cached error %v (a live dial would fail differently, connection refused)", err2, err)
	}
}
