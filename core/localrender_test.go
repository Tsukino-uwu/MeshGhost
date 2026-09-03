package core

// A ghost this core INVENTED is not delayed for a network it never crossed.
//
// The defect these tests exist for, shipped and found by reading on 2026-09-03:
// a replay and a chaser feed their samples stamped at the wall time they are
// meant to be AT, and tickRenders then drew every remote one InterpolationDelay
// in the past -- so a chaser configured for 3s was drawn at 3.45s, and a replay
// ran 450ms behind its own schedule. Nothing caught it because every test that
// touches a local peer pins InterpolationDelay to 0 (core/localpeer_test.go's
// helper, internal/e2e's startClient), where the defect cannot exist.
//
// So: everything here runs at the SHIPPED 450ms on purpose.

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestLocalGhostsAreNotDelayedByTheNetworkInterpolationDelay is the fast,
// deterministic form of the whole bug: one relay peer and one chaser fed the
// IDENTICAL sample stream, rendered in the same tick, must not come out in the
// same place. remoteStatesAt takes `now` and subtracts per class, so no clock
// races this -- the numbers below are exact.
func TestLocalGhostsAreNotDelayedByTheNetworkInterpolationDelay(t *testing.T) {
	c := New()
	c.InterpolationDelay = 450 * time.Millisecond
	c.LocalInterpolationDelay = 25 * time.Millisecond
	c.playerID = "me"
	c.roster = map[string]struct{}{"p1": {}, "chaser:1": {}}

	// x IS the sample's age in ms, negative into the past, so a rendered x
	// reads directly as "this ghost is drawn |x| ms behind now".
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

// TestALocalGhostStillInterpolatesRatherThanEdgeHolding pins the reason the
// local delay is 25ms and not 0, so nobody "simplifies" it to zero later.
//
// At zero the render time lands at or past the newest fed sample, atAhead takes
// its past-the-newest branch, and with Extrapolate at its default of 0 it holds
// that sample: a stair-step at the feed rate instead of a smooth glide. A
// couple of sample intervals is all it takes to always have something ahead to
// interpolate toward.
func TestALocalGhostStillInterpolatesRatherThanEdgeHolding(t *testing.T) {
	build := func(localDelay time.Duration) *Core {
		c := New()
		c.InterpolationDelay = 450 * time.Millisecond
		c.LocalInterpolationDelay = localDelay
		c.playerID = "me"
		c.roster = map[string]struct{}{"replay:pb": {}}
		base := c.nowMs()
		// Samples every 10ms, x = age in ms, so any x that is not a multiple
		// of 10 can only have come from interpolating between two of them.
		for ts := base - 300; ts <= base; ts += 10 {
			c.storeRemoteState(protocol.State{
				PlayerID: "replay:pb", AreaID: "a", Timestamp: ts,
				Position: []float64{float64(ts - base), 0},
			})
		}
		return c
	}

	// The shipped shape: a render time three milliseconds off the feed grid
	// still lands between two samples.
	c := build(25 * time.Millisecond)
	states, _ := c.remoteStatesAt(c.nowMs() + 3)
	if got := states["replay:pb"].Position[0]; got != -22 {
		t.Errorf("with a 25ms local delay the ghost drew at x=%v, want -22 (interpolated "+
			"between the samples at -30 and -20)", got)
	}

	// The same instant with the delay at zero: nothing is ahead of the render
	// time, so the newest sample is held. This is what a local ghost would look
	// like at 0 -- stepping at the feed rate, not gliding.
	c = build(0)
	states, _ = c.remoteStatesAt(c.nowMs() + 3)
	if got := states["replay:pb"].Position[0]; got != 0 {
		t.Errorf("with a zero local delay the ghost drew at x=%v, want 0 -- the newest sample "+
			"held. If this ever interpolates, the reasoning behind DefaultLocalGhostDelay has "+
			"changed and the constant should be revisited", got)
	}
}

// TestAChaserLagsByItsOwnDelayNotDelayPlusInterp is the same claim through the
// real machinery -- a running chaser, the real bridge, a real render tick --
// at the shipped 450ms interpolation delay.
//
// core/chaser_test.go's TestChaserFollowsTheLocalPlayerBehindByItsDelay is the
// same shape at interp 0, which is exactly why it passed throughout the defect.
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

	// The player walks one unit per 10ms, so a lag in units IS a lag in
	// hundredths of a second: 30 units = 300ms.
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

// TestAFinishedReplayHoldsItsLastSampleLongEnoughToBeDrawn guards the other
// site that read the network delay: the end-of-clip hold (replay.go). It exists
// so the deferred drop cannot despawn the ghost before its final position has
// been rendered, so it must be at least the LOCAL delay -- and reading the
// network one instead left a finished ghost frozen on its finish line for
// several hundred milliseconds longer than it had any reason to.
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
