package core

// A ghost this core invented is not delayed for a network it never crossed. Every other test that touches a local peer
// pins InterpolationDelay to 0, where the delay cannot show, so everything here runs at the shipped 450ms on purpose.

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestLocalGhostsAreNotDelayedByTheNetworkInterpolationDelay: one relay peer and one chaser, fed the identical sample
// stream and rendered in one tick, must not land in the same place. remoteStatesAt takes now and subtracts per class,
// so the numbers are exact.
func TestLocalGhostsAreNotDelayedByTheNetworkInterpolationDelay(t *testing.T) {
	c := New()
	c.InterpolationDelay = 450 * time.Millisecond
	c.LocalInterpolationDelay = 25 * time.Millisecond
	c.playerID = "me"
	c.roster = map[string]int64{"p1": 0, "chaser:1": 0}

	// x is the sample's age in ms, negative into the past, so a rendered x reads as "this ghost is drawn |x| ms behind
	// now".
	base := c.nowMs()
	for ts := base - 600; ts <= base; ts += 10 {
		for _, id := range []string{"p1", "chaser:1"} {
			c.storeRemoteState(protocol.State{
				PlayerID: id, AreaID: "a", Timestamp: ts,
				Position: []float64{float64(ts - base), 0},
			})
		}
	}

	states, _ := c.remoteStatesAt(base)
	net, ok := states["p1"]
	if !ok {
		t.Fatal("the relay peer was not rendered at all")
	}
	local, ok := states["chaser:1"]
	if !ok {
		t.Fatal("the chaser was not rendered at all")
	}
	if got := net.Position[0]; got != -450 {
		t.Errorf("relay peer drawn at x=%v, want -450 (one InterpolationDelay behind)", got)
	}
	if got := local.Position[0]; got != -25 {
		t.Errorf("chaser drawn at x=%v, want -25 (one LocalInterpolationDelay behind). "+
			"-475 means it is being charged the network delay on top of its own schedule, "+
			"which is the 2026-09-03 defect: a 3s chaser drawn at 3.45s", got)
	}
}

// TestALocalGhostStillInterpolatesRatherThanEdgeHolding pins why the local delay is 25ms, not 0: at zero the render
// time lands at or past the newest sample and, with Extrapolate off, holds it, a stair-step at the feed rate instead of
// a glide.
func TestALocalGhostStillInterpolatesRatherThanEdgeHolding(t *testing.T) {
	// build returns its own base, and the test asserts against that rather than reading nowMs again: every number a
	// timing assertion compares must come from one reading of the clock.
	build := func(localDelay time.Duration) (*Core, int64) {
		c := New()
		c.InterpolationDelay = 450 * time.Millisecond
		c.LocalInterpolationDelay = localDelay
		c.playerID = "me"
		c.roster = map[string]int64{"replay:pb": 0}
		base := c.nowMs()
		// Samples every 10ms, x = age in ms, so any x that is not a multiple
		// of 10 can only have come from interpolating between two of them.
		for ts := base - 300; ts <= base; ts += 10 {
			c.storeRemoteState(protocol.State{
				PlayerID: "replay:pb", AreaID: "a", Timestamp: ts,
				Position: []float64{float64(ts - base), 0},
			})
		}
		return c, base
	}

	// The shipped shape: a render time three milliseconds off the feed grid
	// still lands between two samples.
	c, base := build(25 * time.Millisecond)
	states, _ := c.remoteStatesAt(base + 3)
	if got := states["replay:pb"].Position[0]; got != -22 {
		t.Errorf("with a 25ms local delay the ghost drew at x=%v, want -22 (interpolated "+
			"between the samples at -30 and -20)", got)
	}

	// The same instant with the delay at zero: nothing is ahead of the render
	// time, so the newest sample is held. This is what a local ghost would look
	// like at 0 -- stepping at the feed rate, not gliding.
	c, base = build(0)
	states, _ = c.remoteStatesAt(base + 3)
	if got := states["replay:pb"].Position[0]; got != 0 {
		t.Errorf("with a zero local delay the ghost drew at x=%v, want 0 -- the newest sample "+
			"held. If this ever interpolates, the reasoning behind DefaultLocalGhostDelay has "+
			"changed and the constant should be revisited", got)
	}
}

// TestAChaserLagsByItsOwnDelayNotDelayPlusInterp: the same claim through a running chaser, the real bridge and a real
// render tick at the shipped 450ms interpolation delay. TestChaserFollowsTheLocalPlayerBehindByItsDelay runs at interp
// 0, where this cannot fail.
func TestAChaserLagsByItsOwnDelayNotDelayPlusInterp(t *testing.T) {
	c, _, fa := startLocalPeerCoreWith(t, func(c *Core) {
		c.InterpolationDelay = 450 * time.Millisecond
		c.LocalInterpolationDelay = DefaultLocalGhostDelay
		c.ChaserEnabled = true
		c.ChaserDelay = 300 * time.Millisecond
		c.ChaserSpawnDelay = 50 * time.Millisecond
		c.ChaserName = "Chaser"
	})
	if n := c.StartChasers(); n != 1 {
		t.Fatalf("StartChasers = %d, want 1", n)
	}
	const id = "chaser:1"

	// The player walks one unit per 10ms, so a lag in units is a lag in hundredths of a second: 30 units = 300ms.
	start := time.Now()
	lag := -1.0
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		x := float64(time.Since(start) / (10 * time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}, Anim: "run"})
		time.Sleep(10 * time.Millisecond)
		if m, ok := fa.renderMsgOf(id); ok && x > 60 {
			lag = x - m.State.Position[0]
			break
		}
	}
	if lag < 0 {
		t.Fatalf("the chaser never rendered")
	}
	// Its own 300ms, plus the local delay and a frame of scheduling slack.
	if lag < 20 || lag > 45 {
		t.Fatalf("the chaser lagged the player by %.0f units (~%.0fms), want ~30 (300ms). "+
			"About 75 means it is being charged the 450ms network delay as well, which is the "+
			"2026-09-03 defect", lag, lag*10)
	}
}

// TestAFinishedReplayHoldsItsLastSampleLongEnoughToBeDrawn guards the other site that read the network delay, the
// end-of-clip hold: it must be at least the local delay, so the final position renders before the despawn, and no
// longer, or a finished ghost freezes on its finish line.
func TestAFinishedReplayHoldsItsLastSampleLongEnoughToBeDrawn(t *testing.T) {
	c, _, fa := startLocalPeerCoreWith(t, func(c *Core) {
		c.ReplayDir = filepath.Join(t.TempDir(), "replay")
		c.InterpolationDelay = 450 * time.Millisecond
		c.LocalInterpolationDelay = DefaultLocalGhostDelay
	})
	writeActive(t, c, "pb.ndjson", clipBytes(map[string]any{"name": "PB"}, walkStates(20, 10)))
	if n := c.StartReplays(); n != 1 {
		t.Fatalf("StartReplays loaded %d, want 1", n)
	}
	const id = "replay:pb.ndjson"
	pumpUntil(t, fa, func() bool {
		m, ok := fa.renderMsgOf(id)
		return ok && len(m.State.Position) == 2 && m.State.Position[0] == 19
	}, "the replay's LAST sample to be drawn before the ghost is dropped")
}
