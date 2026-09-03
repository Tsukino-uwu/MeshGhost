package core

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestChaserFollowsTheLocalPlayerBehindByItsDelay: with the player walking
// x = t/10ms and a 100ms delay, the chaser renders where the player was
// ~100ms ago, cosmetic, offline (no relay involved in the feed at all).
func TestChaserFollowsTheLocalPlayerBehindByItsDelay(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserDelay = 100 * time.Millisecond
	c.ChaserName = "Chaser"
	c.ChaserColor = "#7A2A2A"
	c.mu.Unlock()
	if n := c.StartChasers(); n != 1 {
		t.Fatalf("StartChasers = %d, want 1", n)
	}
	const id = "chaser:1"
	start := time.Now()
	var lag float64 = -1
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		x := float64(time.Since(start) / (10 * time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}, Anim: "run"})
		time.Sleep(10 * time.Millisecond)
		if m, ok := fa.renderMsgOf(id); ok && x > 30 {
			if !m.Cosmetic {
				t.Fatalf("chaser rendered without cosmetic=true: %+v", m)
			}
			lag = x - m.State.Position[0]
			break
		}
	}
	// 100ms behind is 10 samples; allow scheduling slack either way.
	if lag < 5 || lag > 20 {
		t.Fatalf("chaser lag = %v samples (10ms each), want about 10 for a 100ms delay", lag)
	}
	fa.mu.Lock()
	name := fa.names[id]
	fa.mu.Unlock()
	if name.DisplayName != "Chaser" || name.Color != "#7A2A2A" {
		t.Fatalf("chaser nametag %+v", name)
	}
	c.StopChasers()
	pumpUntil(t, fa, func() bool { return drainDespawns(fa, id) > 0 }, "the chaser to despawn on StopChasers")
}

// TestChaserPackIsSpacedAndNumbered: three chasers with 50ms spacing are
// three peers at three different lags, named "Pack 1..3", never two on the
// same spot while the player moves; count clamps to the max.
func TestChaserPackIsSpacedAndNumbered(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserCount = 3
	c.ChaserDelay = 100 * time.Millisecond
	c.ChaserSpacing = 50 * time.Millisecond
	c.ChaserName = "Pack"
	c.mu.Unlock()
	if n := c.StartChasers(); n != 3 {
		t.Fatalf("StartChasers = %d, want 3", n)
	}
	start := time.Now()
	deadline := time.Now().Add(testTimeout)
	var xs [3]float64
	seen := false
	for time.Now().Before(deadline) && !seen {
		x := float64(time.Since(start) / (10 * time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
		time.Sleep(10 * time.Millisecond)
		if x < 40 {
			continue
		}
		all := true
		for i := 0; i < 3; i++ {
			m, ok := fa.renderMsgOf("chaser:" + string(rune('1'+i)))
			if !ok {
				all = false
				break
			}
			xs[i] = m.State.Position[0]
		}
		seen = all
	}
	if !seen {
		t.Fatal("not all three chasers rendered")
	}
	if !(xs[0] > xs[1] && xs[1] > xs[2]) {
		t.Fatalf("chasers not spaced back-to-front: %v", xs)
	}
	fa.mu.Lock()
	n2 := fa.names["chaser:2"].DisplayName
	fa.mu.Unlock()
	if n2 != "Pack 2" {
		t.Fatalf("chaser 2 is named %q, want \"Pack 2\"", n2)
	}
	c.StopChasers()

	c.mu.Lock()
	c.ChaserCount = 99
	c.mu.Unlock()
	if n := c.StartChasers(); n != maxChasers {
		t.Fatalf("count 99 started %d, want the cap %d", n, maxChasers)
	}
	c.StopChasers()
}

// TestChaserSeamsOnALiveGapAndIsOffByDefault: 2s of silence (a menu) makes
// the chaser leave and reappear rather than glide; disabled means no peer.
func TestChaserSeamsOnALiveGapAndIsOffByDefault(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	if n := c.StartChasers(); n != 0 {
		t.Fatalf("chaser off by default, but StartChasers = %d", n)
	}
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserDelay = 50 * time.Millisecond
	c.mu.Unlock()
	c.StartChasers()
	const id = "chaser:1"
	for i := 0; i < 20; i++ {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{float64(i), 0}})
		time.Sleep(10 * time.Millisecond)
	}
	pumpUntil(t, fa, func() bool { _, ok := fa.renderMsgOf(id); return ok }, "the chaser to appear")
	drainDespawns(fa, id)
	// Silence: nil frames for longer than the seam threshold. The chaser
	// ages out (3s) or seams (1.5s gap) -- either way it must be gone, then
	// come back with the next in-game frame.
	for i := 0; i < 8; i++ {
		fa.frame(nil)
		time.Sleep(200 * time.Millisecond)
	}
	// Back in the game, far from where the pack last saw the player. Keep
	// feeding frames out here: the pack follows the LIVE stream, so the
	// reappearance is wherever the player is now, never a glide from x=19.
	gone, back := false, false
	deadline := time.Now().Add(testTimeout)
	for i := 0; time.Now().Before(deadline) && !(gone && back); i++ {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{100 + float64(i), 0}})
		time.Sleep(10 * time.Millisecond)
		if drainDespawns(fa, id) > 0 {
			gone = true
		}
		if m, ok := fa.renderMsgOf(id); ok && m.State.Position[0] >= 100 {
			back = true
		}
	}
	if !gone {
		t.Fatal("the chaser never despawned across a 1.6s gap in the live stream")
	}
	if !back {
		t.Fatal("the chaser never reappeared where the player is after the gap")
	}
	c.StopChasers()
}

// TestChaserPolicyIsPushedOnlyWhenContactIsOn: session_policy carries
// chaser_contact only when the config asks for it (and no shipped adapter
// honours it yet -- that is per game, ADR-gated).
func TestChaserPolicyIsPushedOnlyWhenContactIsOn(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	c.mu.Lock()
	c.relayPolicyKnown = true
	c.relayGhostCollision = protocol.GhostCollisionDisabled
	c.mu.Unlock()
	c.pushSessionPolicy()
	select {
	case p := <-fa.policies:
		if p.ChaserContact != "" {
			t.Fatalf("chaser_contact %q pushed with contact off", p.ChaserContact)
		}
	case <-time.After(testTimeout):
		t.Fatal("no session_policy")
	}
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserContact = true
	c.mu.Unlock()
	c.pushSessionPolicy()
	select {
	case p := <-fa.policies:
		if p.ChaserContact != "enabled" {
			t.Fatalf("chaser_contact = %q, want enabled", p.ChaserContact)
		}
	case <-time.After(testTimeout):
		t.Fatal("no session_policy after turning contact on")
	}
}
