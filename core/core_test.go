package core

import (
	"bytes"
	"encoding/json"
	"errors"
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

// startRelay starts a real relay.Server on an ephemeral port, so Core runs against the actual relay, not a mock.
func startRelay(t *testing.T) string {
	t.Helper()
	s := relay.NewServer()
	// A relay's send_hz wins when it is slower than a Core's MinSendInterval, so MaxSendHz keeps the relay from slowing
	// a test's fast MinSendInterval; a test of a slower relay uses startRelayWith.
	s.SendHz = protocol.MaxSendHz
	return startRelayWith(t, s)
}

// startRelayWith is startRelay for a test that needs a non-default Server, such as one with a room code.
func startRelayWith(t *testing.T, s *relay.Server) string {
	t.Helper()
	ln := listenTLS(t)
	bindProofToTestIdentity(s)
	go s.Serve(ln)
	return ln.Addr().String()
}

// fakeAdapter stands in for a real adapter: it dials a Core's bridge listener and speaks the bridge protocol.
type fakeAdapter struct {
	t    *testing.T
	conn *transport.NDJSONConn

	mu       sync.Mutex
	rendered map[string]protocol.State
	// renderMsgs is the whole render_remote per peer, for the orientation bracket that sits beside State.
	renderMsgs map[string]bridge.RenderRemote
	// names is every remote_name this adapter was told; a test reading only the Core's map misses the handover.
	names    map[string]bridge.RemoteName
	despawns chan string
	// ready and rejects are the Core's two answers to a hello, buffered so an unread one cannot wedge the callback.
	ready   chan struct{}
	rejects chan string
	// policies receives every session_policy in order, so a test can assert whether a re-push happened.
	policies   chan bridge.SessionPolicy
	recordings chan bridge.RecordingState
	// inputs receives every remote_input, stamped with the newest rendered timestamp for that player (edges must arrive
	// ahead of their frames) and its despawn count (a seam's first line carries a reset).
	inputs chan receivedInput
	// lastRenderTs and despawnCount are the per-player stamps above.
	lastRenderTs map[string]int64
	despawnCount map[string]int
	// order records message types as they arrive: bridge_ready and session_policy come from different goroutines in the
	// Core, so their order is a real property.
	order chan bridge.MessageType
}

func dialFakeAdapter(t *testing.T, bridgeAddr string) *fakeAdapter {
	t.Helper()
	fa, err := dialFakeAdapterErr(t, bridgeAddr)
	if err != nil {
		t.Fatalf("dial bridge: %v", err)
	}
	return fa
}

// dialFakeAdapterErr is dialFakeAdapter for a caller that dials repeatedly: a fuzz target can run Windows out of
// ephemeral ports, which is not a fact about the code under test.
func dialFakeAdapterErr(t *testing.T, bridgeAddr string) (*fakeAdapter, error) {
	t.Helper()
	conn, err := transport.Dial(bridgeAddr)
	if err != nil {
		return nil, err
	}
	return newFakeAdapter(t, conn), nil
}

// newFakeAdapter wires the receive callbacks onto an open bridge connection, a TCP dial or the fuzz target's pipe.
func newFakeAdapter(t *testing.T, conn *transport.NDJSONConn) *fakeAdapter {
	t.Helper()
	fa := &fakeAdapter{
		t:          t,
		conn:       conn,
		rendered:   make(map[string]protocol.State),
		renderMsgs: make(map[string]bridge.RenderRemote),
		despawns:   make(chan string, 1024),
		ready:      make(chan struct{}, 4),
		rejects:    make(chan string, 4),
		policies:   make(chan bridge.SessionPolicy, 8),
		recordings: make(chan bridge.RecordingState, 8),
		order:      make(chan bridge.MessageType, 32),
		// Deep and never blocking: a dense track at 4x can send a few hundred lines in a short test.
		inputs:       make(chan receivedInput, 4096),
		lastRenderTs: map[string]int64{},
		despawnCount: map[string]int{},
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
			fa.renderMsgs[rr.PlayerID] = rr
			if rr.State.Timestamp > fa.lastRenderTs[rr.PlayerID] {
				fa.lastRenderTs[rr.PlayerID] = rr.State.Timestamp
			}
			fa.mu.Unlock()
		case bridge.TypeDespawnRemote:
			var dr bridge.DespawnRemote
			if err := json.Unmarshal(env.Payload, &dr); err != nil {
				t.Errorf("unmarshal despawn_remote: %v", err)
				return
			}
			fa.mu.Lock()
			delete(fa.rendered, dr.PlayerID)
			fa.despawnCount[dr.PlayerID]++
			fa.mu.Unlock()
			// Non-blocking like its siblings: once the buffer fills, a blocking send stalls the bridge read loop until
			// the stuck-adapter verdict tears the session down, while the test's assertions still pass.
			select {
			case fa.despawns <- dr.PlayerID:
			default:
			}
		case bridge.TypeRemoteName:
			var rn bridge.RemoteName
			if err := json.Unmarshal(env.Payload, &rn); err != nil {
				t.Errorf("unmarshal remote_name: %v", err)
				return
			}
			fa.mu.Lock()
			if fa.names == nil {
				fa.names = map[string]bridge.RemoteName{}
			}
			fa.names[rn.PlayerID] = rn
			fa.mu.Unlock()
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
			case fa.policies <- sp:
			default:
			}
		case bridge.TypeRecordingState:
			var rs bridge.RecordingState
			if err := json.Unmarshal(env.Payload, &rs); err != nil {
				t.Errorf("unmarshal recording_state: %v", err)
				return
			}
			select {
			case fa.recordings <- rs:
			default:
			}
		case bridge.TypeRemoteInput:
			var ri bridge.RemoteInput
			if err := json.Unmarshal(env.Payload, &ri); err != nil {
				t.Errorf("unmarshal remote_input: %v", err)
				return
			}
			if ri.Edges == nil {
				t.Errorf("remote_input for %s carries no edges array at all (null), want [] at least", ri.PlayerID)
			}
			fa.mu.Lock()
			got := receivedInput{msg: ri, renderTs: fa.lastRenderTs[ri.PlayerID], despawns: fa.despawnCount[ri.PlayerID]}
			fa.mu.Unlock()
			select {
			case fa.inputs <- got:
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

// hello sends a bridge.Hello declaring gameID, the first message on a fresh connection.
func (fa *fakeAdapter) hello(gameID string) {
	fa.t.Helper()
	fa.helloWithVersion(gameID, "")
}

// helloWithVersion is hello with a game version, for tests of the game-version check.
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

// helloAllAreas is hello with render_all_areas set: the adapter owns area visibility.
func (fa *fakeAdapter) helloAllAreas(gameID string) {
	fa.t.Helper()
	payload, err := json.Marshal(bridge.Hello{GameID: gameID, RenderAllAreas: true})
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

// frame simulates one adapter frame tick: it sends state to the core, or none for nil.
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

// renderMsgOf is rendersOf for the whole bridge message, for a field that sits beside State.
func (fa *fakeAdapter) renderMsgOf(playerID string) (bridge.RenderRemote, bool) {
	fa.mu.Lock()
	defer fa.mu.Unlock()
	rr, ok := fa.renderMsgs[playerID]
	return rr, ok
}

// receivedInput is one remote_input with the per-player stamps the fake adapter had when it arrived.
type receivedInput struct {
	msg      bridge.RemoteInput
	renderTs int64
	despawns int
}

// helloInputTracks is hello with input_tracks, the opt-in of an adapter that can use a replay's input track.
func (fa *fakeAdapter) helloInputTracks(gameID string) {
	fa.t.Helper()
	payload, err := json.Marshal(bridge.Hello{GameID: gameID, InputTracks: true})
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

// helloInterpolateOrientation is hello with interpolate_orientation, the opt-in of an adapter with continuous rotation.
func (fa *fakeAdapter) helloInterpolateOrientation(gameID string) {
	fa.t.Helper()
	payload, err := json.Marshal(bridge.Hello{GameID: gameID, InterpolateOrientation: true})
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

// startCoreLazy starts a Core as cmd/meshghost does with no -game: no relay connection until a bridge.Hello arrives.
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

// waitForPlayerID polls until ConnectRelay has completed or testTimeout elapses.
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

// TestBridgeHelloConnectsToRelay: a core started with no game dials the relay once a bridge.Hello arrives.
func TestBridgeHelloConnectsToRelay(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	adapter := dialFakeAdapter(t, bridgeAddr)
	adapter.hello("emerald")

	waitForPlayerID(t, c)
}

// awaitReady fails the test unless the Core answers this adapter's hello with bridge_ready inside testTimeout.
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

// awaitReject returns the reason, failing unless the Core rejects this adapter's hello inside testTimeout.
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

// TestSecondAdapterForTheSameGameIsRejected: two adapters with one game_id must not share one relay session (one
// player_id, seq and send budget), and nothing would log it.
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

	// The failure mode is a silent hijack of the first adapter's session, not an error.
	if got := c.PlayerID(); got != idBefore {
		t.Errorf("player_id changed to %q after a second adapter attached, want %q kept", got, idBefore)
	}
	first.frame(&protocol.State{AreaID: "a", Position: []float64{1, 2}, Anim: "idle"})
}

// TestSecondAdapterForADifferentGameIsRejectedWithAReason: the reason goes over the wire, since a bare close looks the
// same as a crashed core, a core still binding its port, or an unrelated program.
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

// TestCoreAcceptsANewAdapterAfterTheFirstLeaves: a Core whose adapter left is available again, so a relaunched game
// reuses it rather than walking to a new port and leaving dead cores behind.
func TestCoreAcceptsANewAdapterAfterTheFirstLeaves(t *testing.T) {
	relayAddr := startRelay(t)
	_, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	first := dialFakeAdapter(t, bridgeAddr)
	first.hello("emerald")
	first.awaitReady()
	first.conn.Close()

	reattachFakeAdapter(t, bridgeAddr, "emerald")
}

// reattachFakeAdapter models a relaunched game: dial, say hello, and retry while the Core finishes with the connection
// that just went away. The Core frees its admission slot from the departing connection's read loop, so a close and a
// redial in the same breath can be answered "busy"; a real relaunch takes seconds.
func reattachFakeAdapter(t *testing.T, bridgeAddr, gameID string) *fakeAdapter {
	t.Helper()
	return reattachFakeAdapterWith(t, gameID, func() *fakeAdapter { return dialFakeAdapter(t, bridgeAddr) })
}

// reattachFakeAdapterWith is reattachFakeAdapter over any way of opening a connection, the in-memory pipe included.
func reattachFakeAdapterWith(t *testing.T, gameID string, dial func() *fakeAdapter) *fakeAdapter {
	t.Helper()
	deadline := time.Now().Add(testTimeout)
	for attempt := 1; ; attempt++ {
		fa := dial()
		fa.hello(gameID)
		select {
		case <-fa.ready:
			return fa
		case reason := <-fa.rejects:
			fa.conn.Close()
			if time.Now().After(deadline) {
				t.Fatalf("core still refusing adapters %v after the first one left "+
					"(%d attempts, last reason %q)", testTimeout, attempt, reason)
			}
			time.Sleep(20 * time.Millisecond)
		case <-time.After(testTimeout):
			t.Fatal("timed out waiting for the core to accept a new adapter")
		}
	}
}

// TestLocalStateBeforeHelloDoesNotSendOrCrash: a hello after early local_state frames still connects.
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

// TestSecondHelloWithDifferentGameIsRefused: a Core serves one game per process, so a different game_id is refused
// rather than switched to, and the same one is a no-op.
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

	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err != nil {
		t.Fatalf("re-hello for the same game_id should be a no-op, got error: %v", err)
	}
}

// TestMismatchedSecondAdapterDoesNotKillFirstAdaptersRelaySession: a refused second adapter's disconnect must not close
// the first adapter's relay session. Real state through a second peer proves it, since PlayerID survives a dead link.
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

	core2, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")
	adapter2 := dialFakeAdapter(t, bridge2Addr)
	adapter2.hello("emerald")
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

// TestAdapterHelloAfterStartupConnectIsNoOp: a core started with -game records its game, so a real adapter's hello for
// that game is a no-op, not a mismatch that closes the bridge.
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

func TestTwoCoresExchangeStateOverRealRelay(t *testing.T) {
	relayAddr := startRelay(t)

	core1, bridge1Addr := startCore(t, relayAddr, "emerald", "room1", "alice")
	core2, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter1.hello("emerald")
	adapter2 := dialFakeAdapter(t, bridge2Addr)
	adapter2.hello("emerald")

	// Let core2's join land, so the room has both members before core1 sends.
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

// TestDisconnectDespawnsRemote: a peer leaving the relay reaches this adapter as a despawn_remote.
func TestDisconnectDespawnsRemote(t *testing.T) {
	relayAddr := startRelay(t)

	core1, bridge1Addr := startCore(t, relayAddr, "emerald", "room1", "alice")
	_, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter1.hello("emerald")
	adapter2 := dialFakeAdapter(t, bridge2Addr)
	adapter2.hello("emerald")
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

	// Closing core1's relay connection, not its bridge, makes the relay broadcast a Leave.
	if err := core1.relay.Close(); err != nil {
		t.Fatalf("close core1 relay connection: %v", err)
	}

	// despawn_remote is pushed only in answer to an adapter frame, so keep ticking until the Leave arrives.
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

// TestOwnRelayDisconnectDespawnsRemotes: when this Core's own relay connection is lost no Leave can arrive, so the Core
// clears its remotes itself.
func TestOwnRelayDisconnectDespawnsRemotes(t *testing.T) {
	relayAddr := startRelay(t)

	core1, bridge1Addr := startCore(t, relayAddr, "emerald", "room1", "alice")
	core2, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter1.hello("emerald")
	adapter2 := dialFakeAdapter(t, bridge2Addr)
	adapter2.hello("emerald")
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

// TestBridgeDisconnectDespawnsForPeer: closing the bridge (the game exiting) closes this Core's relay connection, which
// the relay turns into a Leave for the peer.
func TestBridgeDisconnectDespawnsForPeer(t *testing.T) {
	relayAddr := startRelay(t)

	core1, bridge1Addr := startCore(t, relayAddr, "emerald", "room1", "alice")
	_, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter1.hello("emerald")
	adapter2 := dialFakeAdapter(t, bridge2Addr)
	adapter2.hello("emerald")

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

	// Close adapter1's bridge connection, as when the game exits, not core1.relay as the two tests above do.
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

// TestReconnectAfterBridgeDisconnectGetsFreshPlayerID: after a bridge disconnect a fresh hello redials the relay and
// gets a new player_id, so one live ghost remains, not a stale one plus a new one.
func TestReconnectAfterBridgeDisconnectGetsFreshPlayerID(t *testing.T) {
	relayAddr := startRelay(t)

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

// TestRelayDisconnectAutoReconnects: a relay that drops after a connect, with the bridge healthy, is redialled with no
// new hello and a fresh player_id.
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

// TestCrossAreaFiltersRemote: a remote in a different area from this Core's own is not rendered, and reappears once the
// areas match again.
func TestCrossAreaFiltersRemote(t *testing.T) {
	relayAddr := startRelay(t)

	core1, bridge1Addr := startCore(t, relayAddr, "emerald", "room1", "alice")
	core1.MinSendInterval = time.Millisecond // several real state changes must land quickly, not just one
	_, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter1.hello("emerald")
	adapter2 := dialFakeAdapter(t, bridge2Addr)
	adapter2.hello("emerald")

	// Filtering engages only once adapter2's own area is known.
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

	// Re-sent every iteration: forwardLocalState drops a frame inside MinSendInterval rather than deferring it, so a
	// state sent once may never reach the wire. A real adapter sends its current state continuously.
	zoneB := protocol.State{AreaID: "zone-b", Position: []float64{1, 1}, Anim: "idle"}
	adapter1.frame(&zoneB)

	deadline2 := time.Now().Add(testTimeout)
	despawned := false
	for !despawned && time.Now().Before(deadline2) {
		adapter2.frame(&self)
		adapter1.frame(&zoneB)
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

	// Re-sent every iteration as above, and here every time: the loop above left lastSendAt milliseconds old.
	back := protocol.State{AreaID: "zone-a", Position: []float64{2, 2}, Anim: "idle"}
	adapter1.frame(&back)

	deadline3 := time.Now().Add(testTimeout)
	for time.Now().Before(deadline3) {
		adapter2.frame(&self)
		adapter1.frame(&back)
		if _, ok := adapter2.rendersOf(core1.PlayerID()); ok {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("core1 did not reappear for adapter2 after returning to the same area")
}

// TestRenderAllAreasDeliversCrossArea: an adapter whose hello sets render_all_areas keeps receiving a remote that moves
// to a different area, with no despawn_remote.
func TestRenderAllAreasDeliversCrossArea(t *testing.T) {
	relayAddr := startRelay(t)

	core1, bridge1Addr := startCore(t, relayAddr, "emerald", "room1", "alice")
	core1.MinSendInterval = time.Millisecond
	_, bridge2Addr := startCore(t, relayAddr, "emerald", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter1.hello("emerald")
	adapter2 := dialFakeAdapter(t, bridge2Addr)
	adapter2.helloAllAreas("emerald")

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

	// With render_all_areas the zone-b state keeps flowing, with no despawn. Re-sent every iteration, as above.
	zoneB := protocol.State{AreaID: "zone-b", Position: []float64{7, 7}, Anim: "idle"}
	adapter1.frame(&zoneB)

	sawZoneB := false
	deadline2 := time.Now().Add(testTimeout)
	for !sawZoneB && time.Now().Before(deadline2) {
		adapter2.frame(&self)
		adapter1.frame(&zoneB)
		if st, ok := adapter2.rendersOf(core1.PlayerID()); ok && st.AreaID == "zone-b" {
			sawZoneB = true
		}
		select {
		case id := <-adapter2.despawns:
			t.Fatalf("despawn_remote for %q -- render_all_areas must leave area hiding to the adapter", id)
		default:
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !sawZoneB {
		t.Fatal("timed out: core1's zone-b state never reached the render_all_areas adapter")
	}
}

// inProcessAdapter satisfies core.Adapter with no bridge socket and no game, and this file imports nothing under
// adapters/: a game-specific leak in the core would surface when driven through it.
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
		despawns: make(chan string, 1024),
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
	// Non-blocking, as in fakeAdapter: once the buffer fills, a blocking send stalls whatever goroutine delivers the
	// despawn, and StopChasers drops one peer per chaser.
	select {
	case a.despawns <- playerID:
	default:
	}
}

func (a *inProcessAdapter) rendersOf(playerID string) (protocol.State, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	st, ok := a.rendered[playerID]
	return st, ok
}

// TestRunAdapterInProcess: two Cores driven by RunAdapter against an in-process core.Adapter exchange state over a real
// relay, with no game and no adapter process.
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

// countingTransport counts Send calls, to test forwardLocalState's rate cap without a relay.
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

// waitForSendCount blocks until ct's count stops moving, for a total an asynchronous writer is still producing. It
// gives up rather than hangs; the assertions that follow report what they saw.
func waitForSendCount(t *testing.T, ct *countingTransport) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	last := -1
	stable := 0
	for time.Now().Before(deadline) {
		got := ct.count()
		if got == last && got > 0 {
			if stable++; stable >= 3 {
				return
			}
		} else {
			stable = 0
		}
		last = got
		time.Sleep(2 * time.Millisecond)
	}
}

// TestForwardLocalStateRespectsMinSendInterval: calls far faster than MinSendInterval send a capped number of times,
// not one per call.
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

	// relayWriter's goroutine drains the queue, so wait for it before counting; the cap was decided during the loop.
	waitForSendCount(t, ct)

	// The loop takes under one interval; the slack of 10 absorbs a slow CI machine and still fails a send per call.
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

// TestConnectRelayWithWrongRoomCodeReturnsReadableError: a refused Core gets a readable error promptly, not a welcome
// timeout that looks like a slow or down relay.
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

// TestBridgeHelloGameVersionReachesRelay: an adapter's game_version reaches the relay's hello end to end, so a second
// Core whose adapter declares another version is refused.
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

// TestStateForUnknownPlayerIDIsIgnored: a State for a player_id no Welcome or Join announced is dropped, so a hostile
// relay cannot inject state for an arbitrary id.
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
	c.handleRelayMessage(nil, env, welcome, reject)

	c.mu.Lock()
	_, exists := c.remotes["ghost-nobody-announced"]
	c.mu.Unlock()
	if exists {
		t.Fatal("state for an unannounced player_id created a remote — roster check not enforced")
	}
}

// TestJoinArrivingBeforeWelcomeIsNotErased: the relay adds a joining client to the room before sending its Welcome, so
// a peer's Join can arrive ahead of ours. Welcome merges into the roster; replacing it would drop that peer's states
// for the session. The order is tolerated here rather than fixed in the relay, which would hold the room lock across a
// network write.
func TestJoinArrivingBeforeWelcomeIsNotErased(t *testing.T) {
	c := New()
	welcome := make(chan protocol.Welcome, 1)
	reject := make(chan protocol.Reject, 1)

	joinPayload, err := json.Marshal(protocol.Join{PlayerID: "p-early"})
	if err != nil {
		t.Fatalf("marshal join: %v", err)
	}
	joinEnv, err := json.Marshal(protocol.Envelope{Type: protocol.TypeJoin, Payload: joinPayload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	c.handleRelayMessage(nil, joinEnv, welcome, reject)

	// The welcome's roster was snapshotted before that peer joined.
	welcomePayload, err := json.Marshal(protocol.Welcome{PlayerID: "self", Roster: []string{"p-other"}})
	if err != nil {
		t.Fatalf("marshal welcome: %v", err)
	}
	welcomeEnv, err := json.Marshal(protocol.Envelope{Type: protocol.TypeWelcome, Payload: welcomePayload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	c.handleRelayMessage(nil, welcomeEnv, welcome, reject)

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

// TestCoreDependsOnOrderedLifecycleDelivery pins an assumption the core cannot enforce: lifecycle messages arrive in
// the order the relay sent them. A Leave before its Join strands the peer in the roster. Every transport guarantees the
// order (udpconn resequences), so if this test fails, a guard was added here and this comment needs rewriting.
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
		c.handleRelayMessage(nil, env, welcome, reject)
	}

	deliver(protocol.TypeJoin, protocol.Join{PlayerID: "p-ordered"})
	deliver(protocol.TypeLeave, protocol.Leave{PlayerID: "p-ordered"})

	c.mu.Lock()
	_, stillHere := c.roster["p-ordered"]
	c.mu.Unlock()
	if stillHere {
		t.Error("a peer that joined and then left is still in the roster")
	}

	// Out of order, which no transport may produce: the Join resurrects a peer who is already gone.
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

// TestSecondWelcomeIgnored: a Welcome mid-connection neither resets the roster nor reaches the handshake's channel, so
// a hostile relay cannot reset state with it.
func TestSecondWelcomeIgnored(t *testing.T) {
	c := New()
	c.playerID = "p1"
	// The guard reads welcomed, not playerID, which a relay could defeat by naming this client "".
	c.welcomed = true
	c.roster["p2"] = 0

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
	c.handleRelayMessage(nil, env, welcome, reject)

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

// TestOversizedInboundStateFieldsDropped: a State from the relay with any of ValidateState's length-checked fields over
// its cap is dropped, mirroring the relay's own checks.
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
			c.roster["p2"] = 0

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

// TestNonFiniteInboundPositionDropped: a NaN, infinite or out-of-bound position component is dropped. A JSON number
// like 1e308 survives []float64 unmarshaling and becomes +Inf once an adapter narrows it to float32.
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
			c.roster["p2"] = 0

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

// TestKnownPlayerIDStateIsAccepted: a State for a rostered player_id is stored; the roster check must not become a
// second despawn mechanism.
func TestKnownPlayerIDStateIsAccepted(t *testing.T) {
	c := New()
	c.playerID = "self"
	c.roster["p2"] = 0

	c.storeRemoteState(protocol.State{PlayerID: "p2", AreaID: "a", Position: []float64{1, 2}, Anim: "idle"})

	c.mu.Lock()
	_, exists := c.remotes["p2"]
	c.mu.Unlock()
	if !exists {
		t.Fatal("state for a known (rostered) player_id was dropped")
	}
}

// TestConnectRelayOnAdapterHelloRetriesUntilRelayUp: a Core pointed at an address nothing listens on yet gets a
// retryable dial failure, then connects once a relay starts there.
func TestConnectRelayOnAdapterHelloRetriesUntilRelayUp(t *testing.T) {
	// Reserve an address, then free it so nothing listens there yet.
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

	// Start the relay on the same address and retry.
	ln2 := listenTLSOn(t, addr)
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

// TestConnectRelayOnAdapterHelloCachesPermanentReject: a permanent rejection is cached per gameID, so a retrying
// adapter does not redial a hopeless relay every few seconds. The relay is shut down between the calls, where a real
// dial would fail differently.
func TestConnectRelayOnAdapterHelloCachesPermanentReject(t *testing.T) {
	s := relay.NewServer()
	s.RoomCode = "letmein"
	ln := listenTLS(t)
	addr := ln.Addr().String()
	go s.Serve(ln)

	c := New()
	c.RelayAddr = addr
	c.Room = "room1"
	c.DisplayName = "alice"
	c.RoomCode = "wrong-code"
	c.DialTimeout = testTimeout

	err := c.ConnectRelayOnAdapterHello("emerald", "", nil)
	if err == nil {
		t.Fatal("expected a rejection for the wrong room code, got nil")
	}
	if !IsPermanentRejectErr(err) {
		t.Fatalf("wrong room code should be classified as a permanent rejection, got: %v", err)
	}

	ln.Close()

	err2 := c.ConnectRelayOnAdapterHello("emerald", "", nil)
	if err2 == nil {
		t.Fatal("expected the cached rejection to still be returned, got nil")
	}
	if err2.Error() != err.Error() {
		t.Fatalf("second call = %v, want the identical cached error %v (a live dial would fail differently, connection refused)", err2, err)
	}
}

// TestRejectedConnectLeavesNoRelayBehind: when ConnectRelay returns a rejection the Core already holds no relay
// connection, or a retry in the gap is told "already connected" instead of the reject reason. Asserted with no sleep
// on purpose: a sleep would pass without the fix.
func TestRejectedConnectLeavesNoRelayBehind(t *testing.T) {
	s := relay.NewServer()
	s.RoomCode = "letmein"
	ln := listenTLS(t)
	go s.Serve(ln)

	c := New()
	c.RelayAddr = ln.Addr().String()
	c.Room = "room1"
	c.DisplayName = "alice"
	c.RoomCode = "wrong-code"
	c.DialTimeout = testTimeout

	err := c.ConnectRelay("emerald")
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

// recordingTransport records every sent envelope's raw bytes, for tests that inspect what was sent.
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

// TestSendHeartbeatsSendsPeriodicPings: sendHeartbeats sends pings on a fixed cadence and stops once c.relay is
// replaced, as a reconnect supersedes a connection.
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

	c.mu.Lock()
	c.relay = &recordingTransport{}
	c.mu.Unlock()
	countAfterSupersede := rt.count()
	time.Sleep(30 * time.Millisecond)
	if got := rt.count(); got != countAfterSupersede {
		t.Fatalf("sendHeartbeats kept sending on a superseded connection: %d sends after supersede, still %d more since", countAfterSupersede, got-countAfterSupersede)
	}
}

// TestSendHeartbeatsDisabledByNonPositiveInterval: the <= 0 opt-out holds at the mechanism, not only as an eventual
// relay drop.
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

// TestHeartbeatKeepsIdleRelayConnectionAlive: with a shrunk relay IdleTimeout and no adapter traffic, a Core with
// heartbeats stays connected past the point the control below is dropped, rather than reconnecting under a new
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

	// Several multiples of IdleTimeout with no forwardLocalState call, as with no adapter attached.
	time.Sleep(10 * s.IdleTimeout)

	if got := c.PlayerID(); got != firstPlayerID {
		t.Fatalf("player id = %q after the wait, want unchanged %q — connection was dropped/reconnected despite heartbeats being enabled", got, firstPlayerID)
	}
}

// TestWithoutHeartbeatIdleRelayConnectionDrops is the control: with heartbeats off the connection dies, so the harness
// exercises the drop.
func TestWithoutHeartbeatIdleRelayConnectionDrops(t *testing.T) {
	s := relay.NewServer()
	s.IdleTimeout = 50 * time.Millisecond
	relayAddr := startRelayWith(t, s)

	c := New()
	c.HeartbeatInterval = 0 // disabled
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

// --- Send/receive rate control ---

// TestClientAdoptsRelayAdvertisedSendRateWhenItHasNoPreference: with no local MinSendInterval the relay's advertised
// rate is the room's rate, even past the built-in default.
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

// TestExplicitMinSendIntervalIsNeverSpedUpByTheRelay: a slower MinSendInterval holds against a fast relay, for a player
// on a bad connection.
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

// TestRelayAdvertisedRateWinsWhenSlowerThanTheLocalPreference: the relay's rate is a ceiling as well as a floor.
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

// TestUnadvertisedSendRateFallsBackToTheBuiltInDefault: a Welcome with no send_hz (an older relay) advertises nothing,
// not 0Hz, so the Core falls back to DefaultMinSendInterval.
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
	c.handleRelayMessage(nil, env, welcome, reject)

	c.mu.Lock()
	interval := c.effectiveSendInterval()
	c.mu.Unlock()
	if interval != DefaultMinSendInterval {
		t.Fatalf("effective send interval = %v, want DefaultMinSendInterval (%v) — a Welcome with no send_hz must not be treated as advertising 0Hz", interval, DefaultMinSendInterval)
	}
}

// TestAbsurdAdvertisedSendRateIsClampedNotBelieved: a hostile or buggy relay cannot make this Core flood by advertising
// an absurd send_hz.
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
	c.handleRelayMessage(nil, env, welcome, reject)

	c.mu.Lock()
	interval := c.effectiveSendInterval()
	c.mu.Unlock()
	want := time.Second / time.Duration(protocol.MaxSendHz)
	if interval != want {
		t.Fatalf("effective send interval = %v, want %v — a hostile relay's absurd advertised rate must be clamped, not believed", interval, want)
	}
}

// TestAdvertisedSendRateIsForgottenOnRelayDisconnect: a reconnect starts from the nothing-advertised fallback, not a
// rate from the connection that died.
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

// TestMaxReceiveHzReachesTheRelayInHello: Core.MaxReceiveHz reaches the wire as Hello.MaxReceiveHz, observed by a raw
// listener because no relay-side refusal can prove it indirectly.
func TestMaxReceiveHzReachesTheRelayInHello(t *testing.T) {
	ln := listenTLS(t)

	gotHello := make(chan protocol.Hello, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		// No defer conn.Close(): OnReceive does not block, so closing on return would close before the Hello arrives.
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
	}()

	c := New()
	c.RelayAddr = ln.Addr().String()
	c.Room = "room1"
	c.DisplayName = "alice"
	c.DialTimeout = 200 * time.Millisecond
	c.MaxReceiveHz = 15
	// Times out waiting for a Welcome that never comes, after the Hello has been sent.
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

// TestRateLimitedRejectIsRetryableUnlikeAConfigReject: rate-limited and server-full are retryable, while every config
// reason stays permanent, an unrecognised one included, the conservative default for a future relay's new reason.
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

// lockedBuffer is the log sink for tests that redirect the global log package: Core logs through it from goroutines,
// and reconnect loops leaked by earlier tests keep writing into whatever log.SetOutput points at.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

// linesMentioning returns only the log lines that contain addr, so assertions
// ignore lines written by other tests' cores about other relays.
func (b *lockedBuffer) linesMentioning(addr string) string {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out strings.Builder
	for _, line := range strings.Split(b.buf.String(), "\n") {
		if strings.Contains(line, addr) {
			out.WriteString(line)
			out.WriteByte('\n')
		}
	}
	return out.String()
}

// TestReconnectKeepsSayingItCannotReachTheRelay: a core retrying an address nothing answers on keeps saying so, though
// a dead address gives a byte-identical error every time. Assertions read only lines naming this test's relay address,
// so other tests' reconnect loops cannot flake them.
func TestReconnectKeepsSayingItCannotReachTheRelay(t *testing.T) {
	// Reserve an address and free it, so a dial is refused rather than hangs, as for a relay that has exited.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve address: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	prevInterval := setReconnectLogInterval(20 * time.Millisecond)
	t.Cleanup(func() { setReconnectLogInterval(prevInterval) })

	var logged lockedBuffer
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
	if got := strings.Count(logged.linesMentioning(addr), "will keep retrying"); got != 1 {
		t.Fatalf("first failure should log once, got %d:\n%s", got, logged.linesMentioning(addr))
	}

	// A retry inside the interval stays quiet rather than flooding the log.
	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err == nil {
		t.Fatal("expected the retry to fail too, got nil")
	}
	if strings.Contains(logged.linesMentioning(addr), "still cannot reach the relay") {
		t.Fatalf("a retry inside the interval must not log:\n%s", logged.linesMentioning(addr))
	}

	time.Sleep(2 * getReconnectLogInterval())
	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err == nil {
		t.Fatal("expected the retry to fail too, got nil")
	}
	// The repeat must name the address, since a core dialing an unexpected port is what it exposes.
	out := logged.linesMentioning(addr)
	if !strings.Contains(out, "still cannot reach the relay") {
		t.Fatalf("a retry past the interval should say so again and name %s, log was:\n%s", addr, out)
	}

	// Once a relay is there the complaining stops and the outage clock resets, or a later blip would report a duration
	// measured from the session's first outage.
	ln2 := listenTLSOn(t, addr)
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

// TestRelayOwnershipMovesToARelaunchedAdapter: the connection allowed to tear down the relay session is the current
// adapter, never a replaced one, or the old adapter's disconnect kills its replacement's session and disarms
// auto-retry. It calls ConnectRelayOnAdapterHello directly while the first session is live: reattaching a real adapter
// waits out the teardown and never reaches the fast path the rule lives in.
func TestRelayOwnershipMovesToARelaunchedAdapter(t *testing.T) {
	relayAddr := startRelay(t)
	c, bridgeAddr := startCoreLazy(t, relayAddr, "room1", "alice")

	first := dialFakeAdapter(t, bridgeAddr)
	defer first.conn.Close()
	first.hello("emerald")
	waitForPlayerID(t, c)

	c.mu.Lock()
	ownerAfterFirst := c.relayOwner
	c.mu.Unlock()
	if ownerAfterFirst == nil {
		t.Fatal("the first adapter's hello established a relay session but claimed no ownership of it")
	}

	// A stand-in for the relaunched game's bridge connection: only a distinct transport.Transport, since the assertion
	// is about which connection the Core holds responsible.
	mine, theirs := net.Pipe()
	defer mine.Close()
	defer theirs.Close()
	replacement := transport.FromConn(mine)
	defer replacement.Close()

	if err := c.ConnectRelayOnAdapterHello("emerald", "", replacement); err != nil {
		t.Fatalf("a replacement adapter saying hello for the same game should be a no-op, got: %v", err)
	}

	c.mu.Lock()
	owner := c.relayOwner
	retryConn := c.autoRetryBridgeConn
	c.mu.Unlock()

	if owner != transport.Transport(replacement) {
		t.Error("relay ownership did not move to the replacement adapter: the departed connection " +
			"is still entitled to tear down the session its replacement is using, which is the bug")
	}
	if retryConn != transport.Transport(replacement) {
		t.Error("auto-retry still points at the departed bridge connection -- if the relay drops " +
			"now, the redial goes through a dead socket")
	}

	// The session must still work afterwards.
	waitForPlayerID(t, c)
}

// pipeListener is a net.Listener that hands out in-memory net.Pipe connections, so a caller drives the real bridge
// (ServeBridge, the NDJSON framing, every callback) with no sockets: FuzzEverything attaching on every iteration
// exhausts Windows' ephemeral ports. It is not a mock: the bytes still cross a net.Conn into the shipped code.
type pipeListener struct {
	conns chan net.Conn
	done  chan struct{}
	once  sync.Once
}

func newPipeListener() *pipeListener {
	return &pipeListener{conns: make(chan net.Conn), done: make(chan struct{})}
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

// Close stops Accept and every pending dial. It closes done rather than conns: a dial racing a Close would panic
// sending on a closed channel, and a detach step does exactly that.
func (l *pipeListener) Close() error {
	l.once.Do(func() { close(l.done) })
	return nil
}

func (l *pipeListener) Addr() net.Addr { return pipeAddr{} }

// dial opens one connection to whoever serves this listener and returns the caller's end. It blocks until Accept takes
// the other end, as a TCP dial does against a listening socket.
func (l *pipeListener) dial() (net.Conn, error) {
	server, client := net.Pipe()
	select {
	case l.conns <- server:
		return client, nil
	case <-l.done:
		server.Close()
		client.Close()
		return nil, net.ErrClosed
	}
}

type pipeAddr struct{}

func (pipeAddr) Network() string { return "pipe" }
func (pipeAddr) String() string  { return "pipe" }

// dialFakeAdapterPipe is dialFakeAdapter over a pipeListener.
func dialFakeAdapterPipe(t *testing.T, l *pipeListener) *fakeAdapter {
	t.Helper()
	fa, err := dialFakeAdapterPipeErr(t, l)
	if err != nil {
		t.Fatalf("dial bridge pipe: %v", err)
	}
	return fa
}

// dialFakeAdapterPipeErr is the non-fatal form. It fails only when the listener is closed, as the test tears down, so a
// caller that swallows the error hides no resource problem.
func dialFakeAdapterPipeErr(t *testing.T, l *pipeListener) (*fakeAdapter, error) {
	t.Helper()
	return dialThrottledFakeAdapterPipeErr(t, l, 0, 0)
}

// dialThrottledFakeAdapterPipeErr is the same dial with the adapter's end capped at drainBytes per drainEvery; zero
// means unlimited, which every caller but FuzzEverything wants.
func dialThrottledFakeAdapterPipeErr(t *testing.T, l *pipeListener, drainBytes int, drainEvery time.Duration) (*fakeAdapter, error) {
	t.Helper()
	conn, err := l.dial()
	if err != nil {
		return nil, err
	}
	return newFakeAdapter(t, transport.FromConn(newThrottledConn(conn, drainBytes, drainEvery))), nil
}

// TestSecondGameOnOneCoreIsAPermanentRefusal: a hello for a second game_id on a Core already serving one can never
// succeed, so it must classify as permanent. bridgeserve.go refuses a hello only then; otherwise it accepts the adapter
// and retries forever.
func TestSecondGameOnOneCoreIsAPermanentRefusal(t *testing.T) {
	s := relay.NewServer()
	ln := listenTLS(t)
	go s.Serve(ln)

	c := New()
	c.RelayAddr = ln.Addr().String()
	c.Room = "room1"
	c.DisplayName = "alice"
	c.DialTimeout = testTimeout

	if err := c.ConnectRelayOnAdapterHello("emerald", "", nil); err != nil {
		t.Fatalf("first connect as emerald: %v", err)
	}

	err := c.ConnectRelayOnAdapterHello("crystal", "", nil)
	if err == nil {
		t.Fatal("a second game_id on one core must be refused, got nil")
	}

	var serving *AlreadyServingError
	if !errors.As(err, &serving) {
		t.Fatalf("want *AlreadyServingError, got %T: %v", err, err)
	}
	if serving.Connected != "emerald" || serving.Requested != "crystal" {
		t.Errorf("error names the wrong games: connected=%q requested=%q, want emerald/crystal",
			serving.Connected, serving.Requested)
	}

	if !IsPermanentRejectErr(err) {
		t.Fatalf("a second game_id must classify as permanent, or the bridge accepts it and retries forever: %v", err)
	}

	// The relay was never asked, and this string reaches the adapter through rejectBridge.
	if strings.Contains(err.Error(), "relay refused") {
		t.Errorf("message blames the relay for a local refusal: %q", err.Error())
	}
}
