package core

import (
	"bytes"
	"encoding/json"
	"log"
	"math"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

const testTimeout = 2 * time.Second

// startRelay starts a real relay.Server on an ephemeral port, per
// relay — this test exercises Core against the actual relay
// implementation, not a mock.
func startRelay(t *testing.T) string {
	t.Helper()
	s := relay.NewServer()
	// Since the send/receive rate-control feature (see the ADR in
	// agent_docs/architecture.md), a relay's advertised send_hz is
	// prescriptive: effectiveSendInterval takes the SLOWER of the relay's
	// rate and a Core's own explicit MinSendInterval. Left at the relay's
	// own 20Hz default, that would silently override every existing test
	// that sets a fast MinSendInterval (e.g. 1ms) purely so its own
	// assertions land inside testTimeout — exactly the same class of
	// regression flagged for dev-scripts (a fast local override getting
	// slowed down by a default-rate relay). protocol.MaxSendHz here means
	// the relay is never the bottleneck in a test; a test that specifically
	// wants to exercise a slower or unconfigured relay uses startRelayWith
	// with its own Server instead.
	s.SendHz = protocol.MaxSendHz
	return startRelayWith(t, s)
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
	// ready/rejects capture the Core's two possible answers to a hello. Buffered
	// so a test that never reads them cannot wedge the receive callback.
	ready   chan struct{}
	rejects chan string
	// policies receives every session_policy the core pushes, in order, so a
	// test can assert both the value and that a re-push did or did not happen.
	policies chan string
	// order records the sequence of message types as they actually arrive, so
	// a test can assert bridge_ready precedes session_policy. The two are
	// produced on DIFFERENT goroutines inside the Core (the adapter read loop
	// and the relay read loop), so their order is a real property worth
	// pinning rather than an implementation detail.
	order chan bridge.MessageType
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
		ready:    make(chan struct{}, 4),
		rejects:  make(chan string, 4),
		policies: make(chan string, 8),
		order:    make(chan bridge.MessageType, 32),
	}
	conn.OnReceive(func(payload []byte) {
		var env bridge.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			t.Errorf("adapter received malformed envelope: %v", err)
			return
		}
		select {
		case fa.order <- env.Type:
		default:
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
		case bridge.TypeBridgeReady:
			select {
			case fa.ready <- struct{}{}:
			default:
			}
		case bridge.TypeSessionPolicy:
			var sp bridge.SessionPolicy
			if err := json.Unmarshal(env.Payload, &sp); err != nil {
				t.Errorf("unmarshal session_policy: %v", err)
				return
			}
			select {
			case fa.policies <- sp.GhostCollision:
			default:
			}
		case bridge.TypeReject:
			var rj bridge.Reject
			if err := json.Unmarshal(env.Payload, &rj); err != nil {
				t.Errorf("unmarshal reject: %v", err)
				return
			}
			select {
			case fa.rejects <- rj.Reason:
			default:
			}
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

// awaitReady fails the test unless the Core answers this adapter's hello with
// bridge_ready inside testTimeout.
func (fa *fakeAdapter) awaitReady() {
	fa.t.Helper()
	select {
	case <-fa.ready:
	case reason := <-fa.rejects:
		fa.t.Fatalf("hello was rejected (%q), want it accepted", reason)
	case <-time.After(testTimeout):
		fa.t.Fatal("timed out waiting for bridge_ready")
	}
}

// awaitReject returns the reason, failing unless the Core rejects this
// adapter's hello inside testTimeout.
func (fa *fakeAdapter) awaitReject() string {
	fa.t.Helper()
	select {
	case reason := <-fa.rejects:
		return reason
	case <-fa.ready:
		fa.t.Fatal("hello was accepted, want it rejected")
	case <-time.After(testTimeout):
		fa.t.Fatal("timed out waiting for a reject")
	}
	return ""
}

// TestSecondAdapterForTheSameGameIsRejected is the important one, and it covers
// a bug rather than a feature. Two adapters running the SAME game_id both used
// to get a successful hello -- ConnectRelayOnAdapterHello returns nil early when
// the game already matches -- and nothing limited adapters per Core, so both
// then drove ONE relay session: one playerID, one seq, one send-rate budget, one
// localAreaID, two games fighting over a single ghost. Neither side logged
// anything unusual.
//
// It matters most in exactly the case that motivated the port walk: two copies
// of one game on one machine, which is also how nearly every adapter in this
// repo got tested.
func TestSecondAdapterForTheSameGameIsRejected(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	first := dialFakeAdapter(t, bridgeAddr)
	first.hello("emerald")
	first.awaitReady()
	waitForPlayerID(t, c)
	idBefore := c.PlayerID()

	second := dialFakeAdapter(t, bridgeAddr)
	second.hello("emerald")
	if reason := second.awaitReject(); reason == "" {
		t.Error("rejected with an empty reason, want one an adapter can log")
	}

	// The first adapter must be entirely undisturbed -- the old failure mode
	// was not an error but a silent hijack of its session.
	if got := c.PlayerID(); got != idBefore {
		t.Errorf("player_id changed to %q after a second adapter attached, want %q kept", got, idBefore)
	}
	first.frame(&protocol.State{AreaID: "a", Position: []float64{1, 2}, Anim: "idle"})
}

// TestSecondAdapterForADifferentGameIsRejectedWithAReason covers the case that
// merely failed rather than corrupting: a Core serves one game, and a second
// game's hello was answered by closing the socket with no explanation. An
// adapter cannot tell that apart from a crashed core, a core still binding its
// port, or an unrelated program, which is why "two games at once" failed
// invisibly and why the reason now goes over the wire.
func TestSecondAdapterForADifferentGameIsRejectedWithAReason(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	first := dialFakeAdapter(t, bridgeAddr)
	first.hello("emerald")
	first.awaitReady()
	waitForPlayerID(t, c)

	second := dialFakeAdapter(t, bridgeAddr)
	second.hello("pseudoregalia")
	if reason := second.awaitReject(); reason == "" {
		t.Error("rejected with an empty reason, want one an adapter can log")
	}
}

// TestCoreAcceptsANewAdapterAfterTheFirstLeaves is the other half of admission
// control, and the one that keeps autostart's reuse working: a Core whose
// adapter has gone must be available again. Without this a relaunched game
// would walk to a new port every time and leave a trail of dead cores behind
// it, each still holding its own port.
func TestCoreAcceptsANewAdapterAfterTheFirstLeaves(t *testing.T) {
	relayAddr := startRelay(t)
	_, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	first := dialFakeAdapter(t, bridgeAddr)
	first.hello("emerald")
	first.awaitReady()
	first.conn.Close()

	// The Core frees the slot in its bridge OnDisconnect, which runs
	// asynchronously, so retry rather than assuming instant.
	deadline := time.Now().Add(testTimeout)
	for {
		second := dialFakeAdapter(t, bridgeAddr)
		second.hello("emerald")
		select {
		case <-second.ready:
			return
		case <-second.rejects:
			if time.Now().After(deadline) {
				t.Fatal("core still refusing adapters after the first one left")
			}
			second.conn.Close()
			time.Sleep(20 * time.Millisecond)
		case <-time.After(testTimeout):
			t.Fatal("timed out waiting for the core to accept a new adapter")
		}
	}
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
func (ct *countingTransport) SendUnreliable(payload []byte) error { return ct.Send(payload) }
func (ct *countingTransport) OnReceive(func([]byte))              {}
func (ct *countingTransport) OnDisconnect(func(error))            {}
func (ct *countingTransport) OnError(func(error))                 {}
func (ct *countingTransport) Close() error                        { return nil }

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
// (TestGameVersionMismatchRejected in relay). See the ADR in
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

// TestJoinArrivingBeforeWelcomeIsNotErased is the regression test for a bug
// with real gameplay consequences, found 2026-08-16 by a relay test written
// for a different race.
//
// The relay adds a joining client to the room BEFORE sending that client's
// Welcome, so a player joining in that window has its Join forwarded to us
// ahead of our own Welcome. Welcome used to assign the roster map outright,
// which erased that player — and because states from anyone outside the
// roster are dropped by design (see Core.roster), we would never render them
// again for the rest of the session. Two people launching at the same moment
// could therefore simply never see each other, which is exactly the "both
// happen to have it on" case the whole thing exists for.
//
// Welcome now merges instead. The ordering itself is left alone deliberately:
// fixing it relay-side would mean holding the room lock across a network
// write to a brand-new connection, and tolerating the order here is both
// cheaper and more robust to any relay that does the same.
func TestJoinArrivingBeforeWelcomeIsNotErased(t *testing.T) {
	c := New()
	welcome := make(chan protocol.Welcome, 1)
	reject := make(chan protocol.Reject, 1)

	// The peer's join lands first, before this Core has been told who it is.
	joinPayload, err := json.Marshal(protocol.Join{PlayerID: "p-early"})
	if err != nil {
		t.Fatalf("marshal join: %v", err)
	}
	joinEnv, err := json.Marshal(protocol.Envelope{Type: protocol.TypeJoin, Payload: joinPayload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	c.handleRelayMessage(joinEnv, welcome, reject)

	// Our own welcome follows, and its roster does not mention that peer --
	// it was snapshotted before they joined.
	welcomePayload, err := json.Marshal(protocol.Welcome{PlayerID: "self", Roster: []string{"p-other"}})
	if err != nil {
		t.Fatalf("marshal welcome: %v", err)
	}
	welcomeEnv, err := json.Marshal(protocol.Envelope{Type: protocol.TypeWelcome, Payload: welcomePayload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	c.handleRelayMessage(welcomeEnv, welcome, reject)

	c.mu.Lock()
	_, early := c.roster["p-early"]
	_, fromWelcome := c.roster["p-other"]
	c.mu.Unlock()

	if !early {
		t.Error("a Join that arrived before Welcome was erased by it — that peer's states " +
			"would be dropped for the rest of the session")
	}
	if !fromWelcome {
		t.Error("Welcome's own roster was not applied")
	}
}

// TestCoreDependsOnOrderedLifecycleDelivery pins down an assumption this
// package makes but cannot enforce: lifecycle messages arrive in the order
// the relay sent them.
//
// There is deliberately no guard here. delete on an absent key is a no-op,
// so a Leave processed before its own Join leaves that peer in the roster
// with nothing remaining to remove them -- their ghost would stay on screen
// for the rest of the session. This test asserts that cost rather than
// pretending it away, so the coupling is visible from this side.
//
// The guarantee is provided one layer down, by every transport: tcp is an
// ordered stream, quic's reliable path is an ordered stream, and udpconn
// resequences (netx/udpconn's TestReliableWritesArriveInOrderUnderLoss).
// udpconn did NOT do that until 2026-08-16, and this scenario was reachable
// and confirmed on udp -- the client default -- before it was fixed.
//
// So: if this test ever starts failing, a guard was added here and the
// comment above needs rewriting. If a transport ever stops delivering
// lifecycle messages in order, this test keeps passing and a ghost strands
// in the field instead -- which is exactly why the ordering property is
// tested down there rather than defended up here.
func TestCoreDependsOnOrderedLifecycleDelivery(t *testing.T) {
	c := New()
	welcome := make(chan protocol.Welcome, 1)
	reject := make(chan protocol.Reject, 1)

	deliver := func(kind protocol.MessageType, payload any) {
		t.Helper()
		p, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("marshal payload: %v", err)
		}
		env, err := json.Marshal(protocol.Envelope{Type: kind, Payload: p})
		if err != nil {
			t.Fatalf("marshal envelope: %v", err)
		}
		c.handleRelayMessage(env, welcome, reject)
	}

	// In order, the normal case: the peer joins, then leaves, and is gone.
	deliver(protocol.TypeJoin, protocol.Join{PlayerID: "p-ordered"})
	deliver(protocol.TypeLeave, protocol.Leave{PlayerID: "p-ordered"})

	c.mu.Lock()
	_, stillHere := c.roster["p-ordered"]
	c.mu.Unlock()
	if stillHere {
		t.Error("a peer that joined and then left is still in the roster")
	}

	// Out of order, which no transport may produce: the Leave lands first
	// and the Join resurrects a peer who is already gone.
	deliver(protocol.TypeLeave, protocol.Leave{PlayerID: "p-reordered"})
	deliver(protocol.TypeJoin, protocol.Join{PlayerID: "p-reordered"})

	c.mu.Lock()
	_, stranded := c.roster["p-reordered"]
	c.mu.Unlock()
	if !stranded {
		t.Error("a guard against reordered lifecycle messages was added to core — that is a " +
			"fine thing to do, but this test and its comment now describe behaviour that no " +
			"longer exists and must be rewritten")
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
// receive side. agent_docs/architecture.md's ADR. Covers all three arms of
// protocol.ValidateState's combined length check — only AreaID had a test
// before this.
func TestOversizedInboundStateFieldsDropped(t *testing.T) {
	cases := map[string]protocol.State{
		"AreaID":      {AreaID: strings.Repeat("a", protocol.MaxAreaIDLen+1), Position: []float64{1, 2}, Anim: "idle"},
		"Anim":        {AreaID: "a", Position: []float64{1, 2}, Anim: strings.Repeat("a", protocol.MaxAnimLen+1)},
		"Orientation": {AreaID: "a", Position: []float64{1, 2}, Anim: "idle", Orientation: json.RawMessage(`"` + strings.Repeat("a", protocol.MaxOrientationBytes+1) + `"`)},
	}
	for name, st := range cases {
		t.Run(name, func(t *testing.T) {
			c := New()
			c.playerID = "self"
			c.roster["p2"] = struct{}{}

			st.PlayerID = "p2"
			c.storeRemoteState(st)

			c.mu.Lock()
			_, exists := c.remotes["p2"]
			c.mu.Unlock()
			if exists {
				t.Fatalf("oversized %s was accepted instead of dropped", name)
			}
		})
	}
}

// TestNonFiniteInboundPositionDropped confirms a State arriving from the
// relay with a non-finite position component (NaN, +Inf, or a magnitude
// past MaxPositionComponent) is dropped rather than stored —
// protocol.IsValidPosition/ValidateState had no test anywhere before this,
// despite being the newest limit added. A syntactically valid JSON number
// like 1e308 survives []float64 unmarshaling and becomes +Inf the moment an
// adapter narrows it to float32.
func TestNonFiniteInboundPositionDropped(t *testing.T) {
	cases := map[string][]float64{
		"NaN":            {math.NaN(), 0},
		"+Inf":           {math.Inf(1), 0},
		"-Inf":           {math.Inf(-1), 0},
		"past max bound": {protocol.MaxPositionComponent + 1, 0},
	}
	for name, pos := range cases {
		t.Run(name, func(t *testing.T) {
			c := New()
			c.playerID = "self"
			c.roster["p2"] = struct{}{}

			c.storeRemoteState(protocol.State{PlayerID: "p2", AreaID: "a", Position: pos, Anim: "idle"})

			c.mu.Lock()
			_, exists := c.remotes["p2"]
			c.mu.Unlock()
			if exists {
				t.Fatalf("non-finite position (%s) was accepted instead of dropped", name)
			}
		})
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

// TestRejectedConnectLeavesNoRelayBehind pins the invariant that makes the
// test above reliable: when ConnectRelay returns a rejection, the Core must
// ALREADY hold no relay connection by the time it returns — not "shortly
// after, once a goroutine gets scheduled".
//
// ConnectRelay assigns c.relay right after the dial, before it knows whether
// the answer will be Welcome or Reject. The failure paths used to just Close
// the connection and leave the cleanup to the OnDisconnect callback, which
// runs on readLoop's own goroutine. In the gap, c.relay is non-nil while
// c.relayGame is still "", which is precisely the state
// ConnectRelayOnAdapterHello's already-connected guard reads — so a retry
// landing in that gap is told it is "already connected to the relay as game
// \"\"" instead of being given the real, permanent reject reason.
//
// Asserted with no sleep and no polling on purpose. A sleep here would pass
// with or without the fix and prove nothing; checking synchronously is what
// makes this fail against the unfixed code, where the readLoop goroutine has
// had no opportunity to run. CI's race job caught the original as an
// intermittent failure of the test above on 2026-08-17; this is the
// deterministic version of the same claim.
func TestRejectedConnectLeavesNoRelayBehind(t *testing.T) {
	s := relay.NewServer()
	s.RoomCode = "letmein"
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	go s.Serve(ln)

	c := New()
	c.RelayAddr = ln.Addr().String()
	c.Room = "room1"
	c.DisplayName = "alice"
	c.RoomCode = "wrong-code"
	c.DialTimeout = testTimeout

	err = c.ConnectRelay("emerald")
	if err == nil {
		t.Fatal("expected a rejection for the wrong room code, got nil")
	}
	if !IsPermanentRejectErr(err) {
		t.Fatalf("wrong room code should be a permanent rejection, got: %v", err)
	}

	c.mu.Lock()
	leftBehind := c.relay
	game := c.relayGame
	c.mu.Unlock()
	if leftBehind != nil {
		t.Fatalf("a rejected connect left c.relay set (relayGame=%q); the next "+
			"ConnectRelayOnAdapterHello would report %q instead of the reject reason",
			game, "already connected to the relay as game")
	}
}

// recordingTransport is a transport.Transport stand-in that records every
// sent envelope's raw bytes, for tests that need to inspect what was sent
// (not just count calls, unlike countingTransport above).
type recordingTransport struct {
	mu   sync.Mutex
	sent [][]byte
}

func (rt *recordingTransport) Send(payload []byte) error {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	cp := make([]byte, len(payload))
	copy(cp, payload)
	rt.sent = append(rt.sent, cp)
	return nil
}
func (rt *recordingTransport) SendUnreliable(payload []byte) error { return rt.Send(payload) }
func (rt *recordingTransport) OnReceive(func([]byte))              {}
func (rt *recordingTransport) OnDisconnect(func(error))            {}
func (rt *recordingTransport) OnError(func(error))                 {}
func (rt *recordingTransport) Close() error                        { return nil }

func (rt *recordingTransport) count() int {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	return len(rt.sent)
}

func (rt *recordingTransport) all() [][]byte {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	out := make([][]byte, len(rt.sent))
	copy(out, rt.sent)
	return out
}

// TestSendHeartbeatsSendsPeriodicPings is a unit test for sendHeartbeats
// itself, bypassing the network: confirms it actually sends "ping" envelopes
// on a fixed cadence, and stops once c.relay is replaced (the same signal
// ConnectRelay's OnDisconnect/reconnect path uses to supersede an old
// connection). See DefaultHeartbeatInterval's doc comment for the live
// idle-timeout-churn bug this exists to prevent.
func TestSendHeartbeatsSendsPeriodicPings(t *testing.T) {
	c := New()
	c.HeartbeatInterval = 5 * time.Millisecond
	rt := &recordingTransport{}
	c.mu.Lock()
	c.relay = rt
	c.mu.Unlock()

	go c.sendHeartbeats(rt)

	deadline := time.Now().Add(testTimeout)
	for rt.count() < 3 && time.Now().Before(deadline) {
		time.Sleep(2 * time.Millisecond)
	}
	if got := rt.count(); got < 3 {
		t.Fatalf("got %d pings sent in %v, want at least 3 at a %v interval", got, testTimeout, c.HeartbeatInterval)
	}
	for _, raw := range rt.all() {
		var env protocol.Envelope
		if err := json.Unmarshal(raw, &env); err != nil {
			t.Fatalf("sent envelope did not unmarshal: %v", err)
		}
		if env.Type != protocol.TypePing {
			t.Fatalf("sent envelope type = %q, want %q", env.Type, protocol.TypePing)
		}
	}

	// Superseding the connection (as a real reconnect does) must stop
	// further sends.
	c.mu.Lock()
	c.relay = &recordingTransport{}
	c.mu.Unlock()
	countAfterSupersede := rt.count()
	time.Sleep(30 * time.Millisecond)
	if got := rt.count(); got != countAfterSupersede {
		t.Fatalf("sendHeartbeats kept sending on a superseded connection: %d sends after supersede, still %d more since", countAfterSupersede, got-countAfterSupersede)
	}
}

// TestSendHeartbeatsDisabledByNonPositiveInterval confirms the <= 0 opt-out
// used by TestWithoutHeartbeatIdleRelayConnectionDrops actually works at the
// mechanism level, not just "the relay dropped it eventually".
func TestSendHeartbeatsDisabledByNonPositiveInterval(t *testing.T) {
	c := New()
	c.HeartbeatInterval = 0
	rt := &recordingTransport{}
	c.mu.Lock()
	c.relay = rt
	c.mu.Unlock()

	go c.sendHeartbeats(rt)
	time.Sleep(30 * time.Millisecond)
	if got := rt.count(); got != 0 {
		t.Fatalf("sendHeartbeats sent %d pings with HeartbeatInterval <= 0, want 0 (disabled)", got)
	}
}

// TestHeartbeatKeepsIdleRelayConnectionAlive is the positive, end-to-end
// counterpart to relay's TestIdleConnectionWithoutPingIsDroppedByIdleTimeout:
// with the same shrunk relay IdleTimeout, a real Core with heartbeats
// enabled and zero forwardLocalState calls the whole time stays connected
// well past the point an unheartbeated connection would have been dropped
// (proven by the control test below). This is the 2026-08-14 live incident
// from agent_docs/verified.md — a core with no adapter attached went idle,
// got killed by the relay's IdleTimeout, and reconnected under a brand-new
// player_id every cycle.
func TestHeartbeatKeepsIdleRelayConnectionAlive(t *testing.T) {
	s := relay.NewServer()
	s.IdleTimeout = 50 * time.Millisecond
	relayAddr := startRelayWith(t, s)

	c := New()
	c.HeartbeatInterval = 15 * time.Millisecond
	c.RelayAddr = relayAddr
	c.DialTimeout = testTimeout
	if err := c.ConnectRelay("emerald"); err != nil {
		t.Fatalf("ConnectRelay: %v", err)
	}
	firstPlayerID := c.PlayerID()
	if firstPlayerID == "" {
		t.Fatal("expected a non-empty player id after a successful connect")
	}

	// Several multiples of IdleTimeout, with no forwardLocalState call at
	// all — the exact "no adapter attached" scenario that surfaced the bug.
	time.Sleep(10 * s.IdleTimeout)

	if got := c.PlayerID(); got != firstPlayerID {
		t.Fatalf("player id = %q after the wait, want unchanged %q — connection was dropped/reconnected despite heartbeats being enabled", got, firstPlayerID)
	}
}

// TestWithoutHeartbeatIdleRelayConnectionDrops is
// TestHeartbeatKeepsIdleRelayConnectionAlive's control: same shrunk relay
// IdleTimeout, heartbeats explicitly disabled, zero forwardLocalState calls
// — the connection must actually die, proving this test harness really
// exercises the bug rather than trivially passing regardless of the fix.
func TestWithoutHeartbeatIdleRelayConnectionDrops(t *testing.T) {
	s := relay.NewServer()
	s.IdleTimeout = 50 * time.Millisecond
	relayAddr := startRelayWith(t, s)

	c := New()
	c.HeartbeatInterval = 0 // disabled -- pre-fix behavior
	c.RelayAddr = relayAddr
	c.DialTimeout = testTimeout
	if err := c.ConnectRelay("emerald"); err != nil {
		t.Fatalf("ConnectRelay: %v", err)
	}
	firstPlayerID := c.PlayerID()
	if firstPlayerID == "" {
		t.Fatal("expected a non-empty player id after a successful connect")
	}

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		if c.PlayerID() == "" {
			return // dropped, as expected with no heartbeat and no traffic
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("connection was not dropped by IdleTimeout with heartbeats disabled — test harness assumption is wrong (still connected as %q)", firstPlayerID)
}

// --- Send/receive rate control (agent_docs/architecture.md's ADR) ---

// TestClientAdoptsRelayAdvertisedSendRateWhenItHasNoPreference confirms a
// Core with no local MinSendInterval genuinely speeds up past its own
// built-in 20Hz default when a relay advertises a faster rate — the
// "prescriptive" half of the design: the relay's number IS the room's rate
// for a client that hasn't expressed a preference.
func TestClientAdoptsRelayAdvertisedSendRateWhenItHasNoPreference(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = 100
	relayAddr := startRelayWith(t, s)

	c, _ := startCore(t, relayAddr, "emerald", "room1", "alice")

	c.mu.Lock()
	interval := c.effectiveSendInterval()
	c.mu.Unlock()

	want := time.Second / 100
	if interval != want {
		t.Fatalf("effective send interval = %v, want %v (adopted from the relay's advertised 100Hz)", interval, want)
	}
}

// TestExplicitMinSendIntervalIsNeverSpedUpByTheRelay confirms a Core that
// deliberately set a slower MinSendInterval keeps it even against a fast
// relay — the user's own "bad internet, don't want to send faster" scenario
// this feature was designed around.
func TestExplicitMinSendIntervalIsNeverSpedUpByTheRelay(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = 100
	relayAddr := startRelayWith(t, s)

	c := New()
	c.MinSendInterval = 200 * time.Millisecond
	c.RelayAddr = relayAddr
	c.Room = "room1"
	c.DisplayName = "alice"
	c.DialTimeout = testTimeout
	if err := c.ConnectRelay("emerald"); err != nil {
		t.Fatalf("connect relay: %v", err)
	}

	c.mu.Lock()
	interval := c.effectiveSendInterval()
	c.mu.Unlock()
	if interval != 200*time.Millisecond {
		t.Fatalf("effective send interval = %v, want 200ms (an explicit floor must never be sped up by a faster relay)", interval)
	}
}

// TestRelayAdvertisedRateWinsWhenSlowerThanTheLocalPreference confirms the
// other half of "slower always wins": a local preference faster than the
// relay's own rate does NOT let this Core exceed the room's configured
// speed — the relay's rate is a ceiling too, not just a floor.
func TestRelayAdvertisedRateWinsWhenSlowerThanTheLocalPreference(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = 10
	relayAddr := startRelayWith(t, s)

	c := New()
	c.MinSendInterval = 10 * time.Millisecond
	c.RelayAddr = relayAddr
	c.Room = "room1"
	c.DisplayName = "alice"
	c.DialTimeout = testTimeout
	if err := c.ConnectRelay("emerald"); err != nil {
		t.Fatalf("connect relay: %v", err)
	}

	c.mu.Lock()
	interval := c.effectiveSendInterval()
	c.mu.Unlock()
	want := time.Second / 10
	if interval != want {
		t.Fatalf("effective send interval = %v, want %v (relay's slower 10Hz must win over a faster local preference)", interval, want)
	}
}

// TestUnadvertisedSendRateFallsBackToTheBuiltInDefault confirms a Welcome
// with no send_hz at all (an older relay that predates this field) is read
// as "nothing advertised," not as an advertised 0Hz — this Core falls back
// to DefaultMinSendInterval instead of never sending at all.
func TestUnadvertisedSendRateFallsBackToTheBuiltInDefault(t *testing.T) {
	c := New()
	payload, err := json.Marshal(protocol.Welcome{PlayerID: "p1"})
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
	interval := c.effectiveSendInterval()
	c.mu.Unlock()
	if interval != DefaultMinSendInterval {
		t.Fatalf("effective send interval = %v, want DefaultMinSendInterval (%v) — a Welcome with no send_hz must not be treated as advertising 0Hz", interval, DefaultMinSendInterval)
	}
}

// TestAbsurdAdvertisedSendRateIsClampedNotBelieved confirms a hostile or
// buggy relay cannot conscript this Core into flooding by advertising an
// absurd send_hz — defense in depth on receive, the same trust-boundary
// posture as the roster cross-check and ValidateState.
func TestAbsurdAdvertisedSendRateIsClampedNotBelieved(t *testing.T) {
	c := New()
	payload, err := json.Marshal(protocol.Welcome{PlayerID: "p1", SendHz: 100000})
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
	interval := c.effectiveSendInterval()
	c.mu.Unlock()
	want := time.Second / time.Duration(protocol.MaxSendHz)
	if interval != want {
		t.Fatalf("effective send interval = %v, want %v — a hostile relay's absurd advertised rate must be clamped, not believed", interval, want)
	}
}

// TestAdvertisedSendRateIsForgottenOnRelayDisconnect confirms
// serverSendInterval is cleared when the relay connection drops, so a
// reconnect (to this relay again, or a different one) starts from
// effectiveSendInterval's "nothing advertised yet" fallback instead of
// inheriting a stale rate from the connection that just died.
func TestAdvertisedSendRateIsForgottenOnRelayDisconnect(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = 100
	relayAddr := startRelayWith(t, s)

	c, _ := startCore(t, relayAddr, "emerald", "room1", "alice")

	c.mu.Lock()
	before := c.serverSendInterval
	relayConn := c.relay
	c.mu.Unlock()
	if before == 0 {
		t.Fatal("setup: serverSendInterval was never set after connecting to a 100Hz relay")
	}

	_ = relayConn.Close()

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		after := c.serverSendInterval
		c.mu.Unlock()
		if after == 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("serverSendInterval was not cleared after the relay connection disconnected")
}

// TestMaxReceiveHzReachesTheRelayInHello confirms Core.MaxReceiveHz
// actually reaches the wire as Hello.MaxReceiveHz — a minimal fake relay
// (a raw listener, not a real relay.Server) that just observes
// the first Hello it receives, since there's no relay-side rejection
// behavior to hang an indirect proof on the way
// TestBridgeHelloGameVersionReachesRelay does for game_version. The relay
// side's own actual throttling behavior is covered end-to-end by
// relay's TestReceiveCapThrottlesOnlyTheClientThatAskedForIt.
func TestMaxReceiveHzReachesTheRelayInHello(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	gotHello := make(chan protocol.Hello, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		// No defer conn.Close() here: registering OnReceive doesn't block,
		// so this goroutine would otherwise return and close the connection
		// immediately after registering the callback -- before Core's Hello
		// could ever arrive. Left open for the rest of the test process;
		// closing ln in the caller (defer ln.Close() above) is enough
		// cleanup for a short-lived test.
		nd := transport.FromConn(conn)
		nd.OnReceive(func(payload []byte) {
			var env protocol.Envelope
			if err := json.Unmarshal(payload, &env); err != nil {
				return
			}
			if env.Type != protocol.TypeHello {
				return
			}
			var h protocol.Hello
			if err := json.Unmarshal(env.Payload, &h); err != nil {
				return
			}
			select {
			case gotHello <- h:
			default:
			}
		})
		// Deliberately never replies with a Welcome -- this test only needs
		// to observe what Core actually sent, not complete the handshake.
	}()

	c := New()
	c.RelayAddr = ln.Addr().String()
	c.Room = "room1"
	c.DisplayName = "alice"
	c.DialTimeout = 200 * time.Millisecond
	c.MaxReceiveHz = 15
	// Expected to time out waiting for a Welcome that never comes -- the
	// Hello has already been sent by the time that happens, which is all
	// this test needs.
	_ = c.ConnectRelay("emerald")

	select {
	case h := <-gotHello:
		if h.MaxReceiveHz != 15 {
			t.Fatalf("Hello.MaxReceiveHz = %d, want 15", h.MaxReceiveHz)
		}
	case <-time.After(testTimeout):
		t.Fatal("timed out waiting for the relay side to observe a Hello")
	}
}

// TestRateLimitedRejectIsRetryableUnlikeAConfigReject confirms
// isPermanentRejectReason's classification: ReasonRateLimited (like
// ReasonServerFull) is retryable, while every config-driven reason stays
// permanent, including a reason this build doesn't recognize — the
// conservative default a future relay's new reason should get.
func TestRateLimitedRejectIsRetryableUnlikeAConfigReject(t *testing.T) {
	retryable := []string{protocol.ReasonRateLimited, protocol.ReasonServerFull}
	for _, reason := range retryable {
		if isPermanentRejectReason(reason) {
			t.Fatalf("isPermanentRejectReason(%q) = true, want false (retryable)", reason)
		}
	}

	permanent := []string{
		protocol.ReasonInvalidRoomCode,
		protocol.ReasonGameMismatch,
		protocol.ReasonGameVersionMismatch,
		protocol.ReasonProtocolVersionMismatch,
		protocol.ReasonHelloFieldTooLong,
		"some-future-reason-this-build-does-not-recognize",
	}
	for _, reason := range permanent {
		if !isPermanentRejectReason(reason) {
			t.Fatalf("isPermanentRejectReason(%q) = false, want true (permanent)", reason)
		}
	}
}

// TestReconnectKeepsSayingItCannotReachTheRelay is the regression test for a
// core that retries a relay address nothing answers on any more: it used to
// log once and then go completely silent, because the log line was gated
// purely on the error message CHANGING and a dead address produces a
// byte-identical error every time.
//
// Found live 2026-08-19 (see lastConnectErrLoggedAt on Core): one of four
// cores had been pointed at a crowd-test relay on a private port by a
// config.json that was later deleted, that relay was killed, and the core
// then dialed it for ten minutes without a word — which read from outside as
// a broken reconnect loop rather than a wrong address. The loop was fine; the
// reporting was not.
func TestReconnectKeepsSayingItCannotReachTheRelay(t *testing.T) {
	// Reserve an address and free it, so dialing it is refused rather than
	// hanging — the same shape as a relay that has exited.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve address: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	prevInterval := reconnectLogInterval
	reconnectLogInterval = 20 * time.Millisecond
	t.Cleanup(func() { reconnectLogInterval = prevInterval })

	var logged bytes.Buffer
	prevOut := log.Writer()
	prevFlags := log.Flags()
	log.SetOutput(&logged)
	log.SetFlags(0)
	t.Cleanup(func() {
		log.SetOutput(prevOut)
		log.SetFlags(prevFlags)
	})

	c := New()
	c.RelayAddr = addr
	c.Room = "room1"
	c.DisplayName = "alice"
	c.DialTimeout = testTimeout

	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err == nil {
		t.Fatal("expected a dial failure with nothing listening, got nil")
	}
	if got := strings.Count(logged.String(), "will keep retrying"); got != 1 {
		t.Fatalf("first failure should log once, got %d:\n%s", got, logged.String())
	}

	// An immediate retry inside the interval must stay quiet — that part of
	// the old behaviour is deliberate and must not regress into a flood.
	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err == nil {
		t.Fatal("expected the retry to fail too, got nil")
	}
	if strings.Contains(logged.String(), "still cannot reach the relay") {
		t.Fatalf("a retry inside the interval must not log:\n%s", logged.String())
	}

	time.Sleep(2 * reconnectLogInterval)
	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err == nil {
		t.Fatal("expected the retry to fail too, got nil")
	}
	out := logged.String()
	if !strings.Contains(out, "still cannot reach the relay") {
		t.Fatalf("a retry past the interval should say so again, log was:\n%s", out)
	}
	// Naming the address is the whole point: the live incident was a core
	// dialing a port nobody expected it to be dialing.
	if !strings.Contains(out, addr) {
		t.Fatalf("the repeat should name the relay address %s, log was:\n%s", addr, out)
	}

	// Once a relay is actually there, the complaining stops and the outage
	// clock resets — otherwise a later blip would report a duration measured
	// from the first outage of the session.
	ln2, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("listen on reserved address %s: %v", addr, err)
	}
	t.Cleanup(func() { ln2.Close() })
	go relay.NewServer().Serve(ln2)

	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err != nil {
		t.Fatalf("connect once the relay is up: %v", err)
	}
	c.mu.Lock()
	failingSince := c.connectFailingSince
	c.mu.Unlock()
	if !failingSince.IsZero() {
		t.Fatalf("connectFailingSince should be cleared on a successful connect, got %v", failingSince)
	}
}
