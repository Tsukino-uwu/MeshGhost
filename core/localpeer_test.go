package core

import (
	"net"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// startLocalPeerCore builds a Core with a bridge listener, a recording stand-in
// for the relay and zero interpolation delay, the shape every local-peer test
// wants: whatever leaves for the "relay" is captured, and a fed sample renders
// on the very next adapter frame.
//
// BOTH DELAYS ARE ZEROED, and a test about render TIMING has to opt out of that
// deliberately. Zero on the network one is why nothing here caught the defect
// fixed on 2026-09-03: local ghosts were rendered a full InterpolationDelay
// behind their own schedule, and at 0 that is invisible by construction --
// every test in this file measured a chaser's delay correctly and would have
// gone on doing so forever. internal/e2e's startClient hardcodes -interp 0ms
// for the same convenience and had the same blind spot. See
// core/localrender_test.go, which runs at the shipped 450ms on purpose.
func startLocalPeerCore(t *testing.T) (*Core, *recordingTransport, *fakeAdapter) {
	return startLocalPeerCoreWith(t, nil)
}

// startLocalPeerCoreWith runs cfg on the Core BEFORE the bridge serves, for a
// test that needs a field the hello handler reads (ReplayDir, the Chaser*
// fields): anything set after the adapter attaches races the bridge goroutine.
func startLocalPeerCoreWith(t *testing.T, cfg func(*Core)) (*Core, *recordingTransport, *fakeAdapter) {
	t.Helper()
	c := New()
	c.InterpolationDelay = 0
	c.LocalInterpolationDelay = 0
	if cfg != nil {
		cfg(c)
	}
	rt := &recordingTransport{}
	c.mu.Lock()
	c.relay = rt
	c.playerID = "self"
	c.relayGame = "emerald"
	c.mu.Unlock()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen bridge: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go c.ServeBridge(ln)

	fa := dialFakeAdapter(t, ln.Addr().String())
	fa.hello("emerald")
	fa.awaitReady()
	return c, rt, fa
}

// pumpUntil sends adapter frames (each one drives a render tick) until cond
// holds or testTimeout elapses.
func pumpUntil(t *testing.T, fa *fakeAdapter, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{0, 0}, Anim: "idle"})
		time.Sleep(5 * time.Millisecond)
		if cond() {
			return
		}
	}
	t.Fatalf("timed out waiting for %s", what)
}

// TestALocalPeerRendersWithItsNametagAndNeverReachesTheRelay is the seam test
// for ADR 0047: a peer this core invents renders through the real bridge with
// cosmetic=true and its nametag, is provably never sent to the relay, despawns
// on drop, and survives the roster wipe of a relay session change.
func TestALocalPeerRendersWithItsNametagAndNeverReachesTheRelay(t *testing.T) {
	c, rt, fa := startLocalPeerCore(t)
	const id = "replay:lap1"

	if !c.admitLocalPeer(id, protocol.Nametag{Name: "PB", Color: "#FF8800"}) {
		t.Fatal("admitLocalPeer refused an empty roster")
	}
	feed := func(x float64) {
		if !c.feedLocalPeer(id, protocol.State{Timestamp: c.nowMs(), AreaID: "a", Position: []float64{x, 0}, Anim: "run"}) {
			t.Fatalf("feedLocalPeer(%v) refused", x)
		}
	}
	for i := 0; i < 5; i++ {
		feed(float64(i))
	}

	var msg bridge.RenderRemote
	pumpUntil(t, fa, func() bool {
		m, ok := fa.renderMsgOf(id)
		msg = m
		return ok
	}, "the local peer to render")
	if !msg.Cosmetic {
		t.Fatalf("render_remote for a local peer must carry cosmetic=true, got %+v", msg)
	}
	if msg.State.PlayerID != id || msg.State.Anim != "run" {
		t.Fatalf("rendered state is not the fed sample: %+v", msg.State)
	}
	fa.mu.Lock()
	name := fa.names[id]
	fa.mu.Unlock()
	if name.DisplayName != "PB" || name.Color != "#FF8800" {
		t.Fatalf("adapter was told nametag %+v, want PB/#FF8800", name)
	}

	// Nothing with the local id left for the relay. The adapter's own frames
	// DO go out (that is forwardLocalState doing its job), so the assertion is
	// on the id, not on the count.
	for _, raw := range rt.all() {
		if strings.Contains(string(raw), id) {
			t.Fatalf("a local peer's id reached the relay transport: %s", raw)
		}
	}

	// A relay peer rendered through the same core does NOT get the flag.
	c.mu.Lock()
	c.roster["p7"] = struct{}{}
	c.mu.Unlock()
	c.storeRemoteState(protocol.State{PlayerID: "p7", Timestamp: c.nowMs(), AreaID: "a", Position: []float64{9, 9}, Anim: "idle"})
	pumpUntil(t, fa, func() bool { _, ok := fa.renderMsgOf("p7"); return ok }, "the relay peer to render")
	if m, _ := fa.renderMsgOf("p7"); m.Cosmetic {
		t.Fatalf("a relay peer was marked cosmetic: %+v", m)
	}

	// Drop: the next tick despawns it.
	c.dropLocalPeer(id)
	pumpUntil(t, fa, func() bool {
		select {
		case got := <-fa.despawns:
			return got == id
		default:
			return false
		}
	}, "the despawn after dropLocalPeer")
	if c.feedLocalPeer(id, protocol.State{Timestamp: c.nowMs(), AreaID: "a", Position: []float64{1, 1}}) {
		t.Fatal("feedLocalPeer accepted a sample for a dropped peer")
	}

	// Re-admit, then wipe the roster the way a relay session change does: the
	// peer must come back on the next feed without anyone re-admitting it.
	if !c.admitLocalPeer(id, protocol.Nametag{Name: "PB"}) {
		t.Fatal("re-admit refused")
	}
	c.mu.Lock()
	c.forgetRelaySessionLocked()
	c.mu.Unlock()
	feed(42)
	pumpUntil(t, fa, func() bool {
		m, ok := fa.renderMsgOf(id)
		return ok && len(m.State.Position) == 2 && m.State.Position[0] == 42
	}, "the local peer to render again after the roster wipe")
}

// TestTickCountAdvancesOncePerAdapterFrame pins the seek primitive: every
// adapter frame is one render tick, and awaitTick returns once one has run.
func TestTickCountAdvancesOncePerAdapterFrame(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	before := c.tickCount()
	fa.frame(&protocol.State{AreaID: "a", Position: []float64{0, 0}})
	if !c.awaitTick(before, testTimeout, nil) {
		t.Fatalf("no render tick ran after an adapter frame (count still %d)", c.tickCount())
	}
	if c.awaitTick(c.tickCount(), 30*time.Millisecond, nil) {
		t.Fatal("awaitTick reported a tick that no adapter frame drove")
	}
}

// TestLocalPeerIDsAreASeparateNamespace pins the shape check the never-on-the-
// wire argument leans on.
func TestLocalPeerIDsAreASeparateNamespace(t *testing.T) {
	for _, id := range []string{"replay:lap1", "chaser:1"} {
		if !isLocalPeerID(id) {
			t.Errorf("%q should be a local peer id", id)
		}
	}
	for _, id := range []string{"1", "p7", "self", "replay", "chaser", "xreplay:1"} {
		if isLocalPeerID(id) {
			t.Errorf("%q should not be a local peer id", id)
		}
	}
}
