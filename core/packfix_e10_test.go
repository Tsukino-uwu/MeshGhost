package core

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestTheChaserPackSurvivesAPauseLongerThanTheStaleWindow: a frozen player feeds the chasers nothing while the adapter
// keeps sending frames, so a wall-clock age-out would delete the pack after RemoteStaleAfter. The pause is four times
// a short RemoteStaleAfter, a long pause without the wall time.
func TestTheChaserPackSurvivesAPauseLongerThanTheStaleWindow(t *testing.T) {
	// Before the bridge serves: the render goroutine reads RemoteStaleAfter.
	c, _, fa := startLocalPeerCoreWith(t, func(c *Core) {
		c.RemoteStaleAfter = 150 * time.Millisecond
	})
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserDelay = 100 * time.Millisecond
	c.ChaserSpawnDelay = 50 * time.Millisecond
	c.ChaserName = "Chaser"
	c.ChaserColor = "#7A2A2A"
	c.mu.Unlock()
	if n := c.StartChasers(); n != 1 {
		t.Fatalf("StartChasers = %d, want 1", n)
	}
	t.Cleanup(c.StopChasers)
	const id = "chaser:1"

	frozen := func(f bool) {
		payload, _ := json.Marshal(bridge.PlayerFrozen{Frozen: f})
		env, _ := json.Marshal(bridge.Envelope{Type: bridge.TypePlayerFrozen, Payload: payload})
		if err := fa.conn.Send(env); err != nil {
			t.Fatalf("send player_frozen: %v", err)
		}
	}

	// Walk until the chaser is on screen and behind, the state a pause must leave untouched.
	start := time.Now()
	var x float64
	deadline := time.Now().Add(testTimeout)
	seen := false
	for time.Now().Before(deadline) && !seen {
		x = float64(time.Since(start) / (10 * time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
		time.Sleep(10 * time.Millisecond)
		if st, ok := fa.rendersOf(id); ok && x > 30 && x-st.Position[0] >= 5 {
			seen = true
		}
	}
	if !seen {
		t.Fatalf("chaser never appeared behind the player")
	}
	// The spawn window despawns once on its way in; only the freeze is under test.
	drainDespawns(fa, id)

	// Four times the stale window, the adapter still sending the same frame as a pause menu does.
	frozen(true)
	held := x
	until := time.Now().Add(600 * time.Millisecond)
	for time.Now().Before(until) {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{held, 0}})
		time.Sleep(10 * time.Millisecond)
	}
	if n := drainDespawns(fa, id); n != 0 {
		t.Fatalf("the chaser was despawned %d time(s) during a pause of 600ms with RemoteStaleAfter at 150ms; ADR 0053 says the pack holds", n)
	}
	if _, ok := fa.rendersOf(id); !ok {
		t.Fatalf("the chaser stopped rendering during the pause")
	}
	// Nor the seat and nametag: feedLocalPeer does not re-run admitLocalPeer, so the ghost would return nameless.
	c.mu.Lock()
	tag, named := c.remoteNames[id]
	_, seated := c.roster[id]
	c.mu.Unlock()
	if !named || tag.Name != "Chaser" {
		t.Fatalf("the chaser lost its nametag across the pause: %+v (present %v)", tag, named)
	}
	if !seated {
		t.Fatalf("the chaser lost its roster seat across the pause")
	}

	// After a long pause it follows again, as TestChaserHoldsWhileThePlayerIsFrozen pins for a short one.
	frozen(false)
	base := time.Now()
	moved := false
	deadline = time.Now().Add(testTimeout)
	for time.Now().Before(deadline) && !moved {
		x = held + float64(time.Since(base)/(10*time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
		time.Sleep(10 * time.Millisecond)
		if st, ok := fa.rendersOf(id); ok && st.Position[0] > held+2 {
			moved = true
		}
	}
	if !moved {
		t.Fatalf("the chaser never followed again after the pause ended")
	}
}
