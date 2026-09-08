package core

// A pause must not despawn the pack.
//
// ADR 0053 put the chaser on the GAMEPLAY clock so a pause menu costs it no
// delay: it holds where it is and resumes the same distance behind. But
// remoteStatesAt aged every buffer out on the WALL clock, with no exemption
// for a ghost this core invents, and a frozen player feeds his chasers
// nothing while the adapter keeps sending frames -- so render ticks kept
// running, the cutoff kept advancing, and after RemoteStaleAfter the whole
// pack was deleted. What the player saw: sit in a pause menu for longer than
// the stale window (3s on the shipped default) and every chaser blinks out,
// then pops back on the first frame after the resume.
//
// Reviewed 2026-09-08. TestChaserHoldsWhileThePlayerIsFrozen freezes for
// 400ms, which is inside the window and so never saw this; the freeze here is
// four times a deliberately short RemoteStaleAfter, which is the same
// scenario as a four-second pause on the default without spending four
// seconds to run it.

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func TestTheChaserPackSurvivesAPauseLongerThanTheStaleWindow(t *testing.T) {
	// RemoteStaleAfter is read by the render goroutine, so it is set before
	// the bridge serves rather than after the adapter attaches.
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

	// Walk until the chaser is on screen and behind, the state a pause has
	// to leave untouched.
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
	// The spawn window itself despawns once on its way in; only what happens
	// during the freeze is under test.
	drainDespawns(fa, id)

	// PAUSE: the pawn holds still for four times the stale window while the
	// adapter keeps sending the same frame, which is what a pause menu looks
	// like from here.
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
	// The other half of the same bug: the age-out took the roster seat and the
	// nametag with the buffer, while the chaser goroutine still believed it
	// was admitted -- so it re-fed through feedLocalPeer, which does not
	// re-run admitLocalPeer, and the ghost came back nameless.
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

	// RESUME: it follows again, which is what TestChaserHoldsWhileThePlayerIsFrozen
	// pins for a short pause and is re-checked here for a long one.
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
