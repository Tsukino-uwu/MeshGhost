package core

// Error decay (correction.go), step A3 of agent_docs/prediction-planning.md.
//
// Every test here drives a real Core through storeRemoteState and
// remoteStatesAt on the fake clock, so the render time, the decay and the
// "drawn before" probe all read one clock and every number is exact. Position
// x is 1 unit per ms of sender time, so a speed reads as 1 and a distance
// reads as milliseconds.

import (
	"math"
	"math/rand"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func newCorrectionCore(t *testing.T, correction, extrapolate time.Duration) (*Core, *fakeClock) {
	t.Helper()
	c := New()
	clk := newFakeClock()
	c.timeSrc = clk
	c.InterpolationDelay = 450 * time.Millisecond
	c.LocalInterpolationDelay = 25 * time.Millisecond
	c.Extrapolate = extrapolate
	c.Predict = PredictLinear
	c.Correction = correction
	c.playerID = "me"
	c.roster = map[string]int64{"p1": 0, "chaser:1": 0}
	return c, clk
}

func feed(c *Core, id string, ts int64, area string, pos ...float64) {
	c.storeRemoteState(protocol.State{PlayerID: id, AreaID: area, Timestamp: ts, Position: pos, Anim: "run"})
}

func drawnX(t *testing.T, c *Core, id string) (float64, protocol.State) {
	t.Helper()
	states, _ := c.remoteStatesAt(c.nowMs())
	st, ok := states[id]
	if !ok {
		t.Fatalf("%s was not rendered", id)
	}
	return st.Position[0], st
}

// reversalScenario runs the one motion that defeats a stateless render: a peer
// moving +1/ms whose samples stop 50ms short of the render time, so the render
// predicts them onward, and who then turns out to have REVERSED. Returns the
// position drawn just before the reversal sample landed and the core ready to
// render just after it. With prediction on and no decay the next render jumps
// by 100 (predicted +50 forward, truth is 50 back).
func reversalScenario(t *testing.T, c *Core, clk *fakeClock, id string) (drawnBefore float64) {
	t.Helper()
	now := c.nowMs()
	t0 := now - 1000
	for ts := t0; ts <= now-500; ts += 50 {
		feed(c, id, ts, "a", float64(ts-t0), 0)
	}
	drawnBefore, _ = drawnX(t, c, id)
	feed(c, id, now-450, "a", float64(now-500-t0)-50, 0)
	return drawnBefore
}

func TestCorrectionOffKeepsTheRenderByteIdentical(t *testing.T) {
	for _, predict := range []PredictMode{PredictLinear, PredictDamped} {
		for _, curve := range []CurveMode{CurveLinear, CurveCatmullRom} {
			c, clk := newCorrectionCore(t, 0, 200*time.Millisecond)
			c.Predict, c.Curve = predict, curve
			reversalScenario(t, c, clk, "p1")
			for i := 0; i < 20; i++ {
				clk.Advance(16 * time.Millisecond)
				now := c.nowMs()
				got, _ := drawnX(t, c, "p1")
				c.mu.Lock()
				buf := c.remotes["p1"]
				raw, _ := buf.atAhead(now-450, 200, curve, predict, nil)
				if buf.correction != nil {
					t.Fatalf("%s/%s: an offset exists with Correction 0", curve, predict)
				}
				c.mu.Unlock()
				if got != raw.Position[0] {
					t.Fatalf("%s/%s: rendered %v, the buffer alone says %v -- off must be byte-identical", curve, predict, got, raw.Position[0])
				}
			}
		}
	}
}

func TestACorrectionKeepsTheDrawnPositionContinuous(t *testing.T) {
	c, clk := newCorrectionCore(t, 100*time.Millisecond, 200*time.Millisecond)
	before := reversalScenario(t, c, clk, "p1")
	after, _ := drawnX(t, c, "p1")
	if after != before {
		t.Fatalf("drawn at %v before the reversal sample and %v on the tick after it; the offset must absorb the whole correction at dt=0", before, after)
	}
	c.mu.Lock()
	buf := c.remotes["p1"]
	raw, _ := buf.atAhead(c.nowMsLocked()-450, 200, CurveLinear, PredictLinear, nil)
	off := buf.correction
	c.mu.Unlock()
	if off == nil || math.Abs(off[0]-(before-raw.Position[0])) > 1e-9 {
		t.Fatalf("offset %v, want drawn-minus-raw %v", off, before-raw.Position[0])
	}
}

func TestAReversalUnderPredictionDoesNotJump(t *testing.T) {
	maxJump := func(correction time.Duration) float64 {
		c, clk := newCorrectionCore(t, correction, 200*time.Millisecond)
		prev := reversalScenario(t, c, clk, "p1")
		worst := 0.0
		for i := 0; i < 30; i++ {
			clk.Advance(16 * time.Millisecond)
			// Keep feeding the reversed motion so the buffer is never dry
			// for long: the correction is what is under test, not a gap.
			now := c.nowMs()
			feed(c, "p1", now-450, "a", float64(now-500-(now-1000))-50-float64(16*(i+1)), 0)
			x, _ := drawnX(t, c, "p1")
			if d := math.Abs(x - prev); d > worst {
				worst = d
			}
			prev = x
		}
		return worst
	}
	off := maxJump(0)
	on := maxJump(100 * time.Millisecond)
	// One frame of motion at speed 1 is 16 units; the decay adds at most
	// 100*(1-exp(-16/100)) ~ 15 on its first frame.
	if on > 40 {
		t.Errorf("largest frame-to-frame move with decay on is %v units, want under 40 (16 of motion plus the first decay step)", on)
	}
	if off < 90 {
		t.Errorf("largest move with decay OFF is %v; the scenario is meant to jump by ~100, so the test is not exercising a correction", off)
	}
	if on >= off/2 {
		t.Errorf("decay on %v vs off %v: it must at least halve the jump", on, off)
	}
}

func TestTheOffsetDecaysToNothing(t *testing.T) {
	c, clk := newCorrectionCore(t, 100*time.Millisecond, 200*time.Millisecond)
	reversalScenario(t, c, clk, "p1")
	// Hold the peer still after the reversal so the raw render is exact and
	// the only thing changing is the offset.
	c.mu.Lock()
	buf := c.remotes["p1"]
	last := buf.snapshots[len(buf.snapshots)-1]
	c.mu.Unlock()
	for i := 1; i <= 160; i++ { // 2.6s, over twenty-five time constants
		clk.Advance(16 * time.Millisecond)
		feed(c, "p1", c.nowMs()-450, "a", last.Position[0], 0)
	}
	x, _ := drawnX(t, c, "p1")
	if math.Abs(x-last.Position[0]) > 1e-3 {
		t.Fatalf("after twenty-five time constants the ghost is still %v from the truth", x-last.Position[0])
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if buf.correction != nil && math.Abs(buf.correction[0]) > correctionEpsilon {
		t.Fatalf("offset still %v; it must decay away, not linger", buf.correction)
	}
}

func TestAWarpFromStandingStillSnaps(t *testing.T) {
	c, clk := newCorrectionCore(t, 100*time.Millisecond, 0)
	now := c.nowMs()
	for ts := now - 1000; ts <= now-450; ts += 50 {
		feed(c, "p1", ts, "a", 0, 0)
	}
	if x, _ := drawnX(t, c, "p1"); x != 0 {
		t.Fatalf("standing peer drawn at %v", x)
	}
	clk.Advance(16 * time.Millisecond)
	feed(c, "p1", c.nowMs()-450, "a", 1000, 0)
	x, _ := drawnX(t, c, "p1")
	if x != 1000 {
		t.Fatalf("a warp from standing still drew at %v, want 1000: nobody predicts a warp, so it is not a correction to slide", x)
	}
}

func TestAnAreaOrShapeChangeSnaps(t *testing.T) {
	for name, next := range map[string]protocol.State{
		"area":  {AreaID: "b", Position: []float64{7, 0}},
		"shape": {AreaID: "a", Position: []float64{7, 0, 0}},
	} {
		c, clk := newCorrectionCore(t, 100*time.Millisecond, 200*time.Millisecond)
		reversalScenario(t, c, clk, "p1") // an offset now exists
		clk.Advance(16 * time.Millisecond)
		c.localAreaID = ""
		feed(c, "p1", c.nowMs()-450, next.AreaID, next.Position...)
		_, st := drawnX(t, c, "p1")
		if st.AreaID != next.AreaID || len(st.Position) != len(next.Position) || st.Position[0] != 7 {
			t.Errorf("%s change: rendered %v in %q, want exactly the new sample (7 in %q) -- sliding across it would show a place the game never had", name, st.Position, st.AreaID, next.AreaID)
		}
		c.mu.Lock()
		if c.remotes["p1"].correction != nil {
			t.Errorf("%s change: an offset survived the snap", name)
		}
		c.mu.Unlock()
	}
}

func TestALocalPeerIsNeverCorrected(t *testing.T) {
	c, clk := newCorrectionCore(t, 100*time.Millisecond, 200*time.Millisecond)
	reversalScenario(t, c, clk, "chaser:1")
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.remotes["chaser:1"].correction != nil {
		t.Fatal("a chaser got an offset; its future is on disk and it is never predicted, so it is never corrected")
	}
}

func TestTurningTheKnobOffLiveDropsAnOffset(t *testing.T) {
	c, clk := newCorrectionCore(t, 100*time.Millisecond, 200*time.Millisecond)
	reversalScenario(t, c, clk, "p1")
	if err := c.SetSmoothing(450*time.Millisecond, 25*time.Millisecond, 200*time.Millisecond, 0, CurveLinear, PredictLinear); err != nil {
		t.Fatal(err)
	}
	now := c.nowMs()
	x, _ := drawnX(t, c, "p1")
	c.mu.Lock()
	defer c.mu.Unlock()
	raw, _ := c.remotes["p1"].atAhead(now-450, 200, CurveLinear, PredictLinear, nil)
	if x != raw.Position[0] || c.remotes["p1"].correction != nil {
		t.Fatalf("knob off live: rendered %v, buffer says %v, offset %v", x, raw.Position[0], c.remotes["p1"].correction)
	}
}

func TestSetSmoothingRefusesANegativeCorrection(t *testing.T) {
	c := New()
	c.Correction = 50 * time.Millisecond
	if err := c.SetSmoothing(450*time.Millisecond, 25*time.Millisecond, 0, -time.Millisecond, CurveLinear, PredictLinear); err == nil {
		t.Fatal("a negative correction was accepted")
	}
	if c.Correction != 50*time.Millisecond {
		t.Fatalf("a refused call changed Correction to %v", c.Correction)
	}
}

func TestWithCorrectionNeverWritesIntoTheBuffer(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{AreaID: "a", Timestamp: 1000, Position: []float64{1, 2}})
	b.add(protocol.State{AreaID: "a", Timestamp: 1100, Position: []float64{3, 4}})
	b.correction = []float64{10, 10}
	held, _ := b.atAhead(5000, 0, CurveLinear, PredictLinear, nil) // past the newest: held, aliasing the snapshot
	out := b.withCorrection(held)
	if out.Position[0] != 13 || b.snapshots[1].Position[0] != 3 {
		t.Fatalf("rendered %v, snapshot now %v: the offset must be added into a copy", out.Position, b.snapshots[1].Position)
	}
}

// TestCorrectionOnANetsimShapedLink is the numbers gate from the plan: a
// synthetic walk with reversals, delivered through a link shaped like the
// no-arg netsim profile (transit 200ms +/- 50, reordering by jitter, and a
// burst of twelve lost samples straddling every reversal, so the buffer is
// dry exactly while the peer turns), rendered at 60Hz. It says whether
// the step is ready to show, never whether it looks right -- that is the
// user's, on screen.
func TestCorrectionOnANetsimShapedLink(t *testing.T) {
	type arrival struct {
		at int64
		st protocol.State
	}
	build := func() []arrival {
		rng := rand.New(rand.NewSource(7))
		var out []arrival
		const period = 2000 // ms per full back-and-forth
		for i := 0; i < 400; i++ {
			ts := int64(i) * 50
			phase := ts % period
			x := float64(phase)
			if phase >= period/2 {
				x = float64(period - phase)
			}
			// Every reversal loses the 300ms on either side of it.
			rev := ts % (period / 2)
			if rev < 300 || rev > period/2-300 {
				continue
			}
			transit := 200 + rng.Int63n(101) - 50
			out = append(out, arrival{at: ts + transit, st: protocol.State{PlayerID: "p1", AreaID: "a", Timestamp: ts, Position: []float64{x, 0}, Anim: "run"}})
		}
		for i := 1; i < len(out); i++ { // insertion sort by arrival: reorder is real
			for j := i; j > 0 && out[j-1].at > out[j].at; j-- {
				out[j-1], out[j] = out[j], out[j-1]
			}
		}
		return out
	}
	run := func(correction time.Duration) (maxJump, meanErr float64) {
		c, clk := newCorrectionCore(t, correction, 100*time.Millisecond)
		c.Predict = PredictDamped
		base := c.nowMs()
		arrivals := build()
		next := 0
		var prev float64
		have := false
		var errSum float64
		var n int
		for tick := int64(0); tick < 20000; tick += 16 {
			clk.Advance(16 * time.Millisecond)
			now := c.nowMs()
			for next < len(arrivals) && base+arrivals[next].at <= now {
				st := arrivals[next].st
				st.Timestamp += base
				c.storeRemoteState(st)
				next++
			}
			states, _ := c.remoteStatesAt(now)
			st, ok := states["p1"]
			// Measure once the render time has passed the first sample: before
			// that the render is an edge hold of whichever sample arrived first,
			// and a reordered pair makes it switch, which is a spawn artifact
			// rather than a correction.
			if !ok || now-450-base < 100 {
				continue
			}
			x := st.Position[0]
			if have {
				if d := math.Abs(x - prev); d > maxJump {
					maxJump = d
				}
			}
			prev, have = x, true
			// Truth at the render time, for the lateness number.
			rt := (now - 450 - base) % 2000
			truth := float64(rt)
			if rt >= 1000 {
				truth = float64(2000 - rt)
			}
			errSum += math.Abs(x - truth)
			n++
		}
		return maxJump, errSum / float64(n)
	}
	offJump, offErr := run(0)
	onJump, onErr := run(100 * time.Millisecond)
	t.Logf("decay off: largest frame move %.1f, mean error %.1f | decay on: largest %.1f, mean %.1f", offJump, offErr, onJump, onErr)
	if offJump <= 40 {
		t.Fatalf("the link never produced a jump worth decaying (largest move %.1f); the scenario is not exercising a correction", offJump)
	}
	if onJump > 40 {
		t.Errorf("largest frame-to-frame move with decay on is %.1f units; a 60Hz frame of this walk is 16", onJump)
	}
	if onErr > offErr*1.5+5 {
		t.Errorf("mean error with decay on is %.1f vs %.1f off: sliding costs a little lateness, not this much", onErr, offErr)
	}
}
