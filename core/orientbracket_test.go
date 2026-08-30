package core

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The orientation bracket, added 2026-08-30. See core.orientBracket for what it
// is and agent_docs/scaling.md for why a stepped facing is a defect on a game
// with continuous 3D rotation and correct on one with four facings.
//
// THE PROPERTY EVERY TEST HERE DEFENDS: the bracket must be the SAME pair of
// samples, at the SAME fraction, that position was interpolated between. A
// rotation on its own clock is the failure mode the whole mechanism exists to
// avoid, and it is invisible until a peer moves fast.

func rot(deg float64) json.RawMessage {
	b, _ := json.Marshal([]float64{0, deg, 0})
	return b
}

func TestOrientBracketIsTheSamePairAndFractionAsPosition(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{PlayerID: "p2", Timestamp: 1000, Position: []float64{0, 0}, AreaID: "a", Orientation: rot(10)})
	b.add(protocol.State{PlayerID: "p2", Timestamp: 2000, Position: []float64{100, 0}, AreaID: "a", Orientation: rot(90)})

	st, br, ok := b.atBracket(1250, 0, CurveLinear, PredictLinear, nil)
	if !ok {
		t.Fatal("atBracket returned ok=false")
	}
	if !br.Have {
		t.Fatal("no bracket for a render time that sits between two samples")
	}
	// Position is a quarter of the way across, so the arc must be too.
	if st.Position[0] != 25 {
		t.Fatalf("position = %v, want x=25", st.Position)
	}
	if br.T != 0.25 {
		t.Fatalf("bracket T = %v, want 0.25 -- rotation and position must share one fraction", br.T)
	}
	if string(br.From) != string(rot(10)) || string(br.To) != string(rot(90)) {
		t.Fatalf("bracket = %s -> %s, want the two samples position used", br.From, br.To)
	}
	// The unchanged field every existing adapter still reads.
	if string(st.Orientation) != string(rot(10)) {
		t.Fatalf("State.Orientation = %s, want the older sample's -- unchanged behaviour for an adapter that ignores the bracket", st.Orientation)
	}
}

func TestOrientBracketRefusesTheSeamsPositionRefuses(t *testing.T) {
	cases := []struct {
		name         string
		older, newer protocol.State
	}{
		{"area change", // a blend across two areas' unrelated coordinate spaces
			protocol.State{Timestamp: 1000, Position: []float64{0, 0}, AreaID: "a", Orientation: rot(0)},
			protocol.State{Timestamp: 2000, Position: []float64{10, 0}, AreaID: "b", Orientation: rot(180)}},
		{"position length change",
			protocol.State{Timestamp: 1000, Position: []float64{0, 0}, AreaID: "a", Orientation: rot(0)},
			protocol.State{Timestamp: 2000, Position: []float64{10, 0, 5}, AreaID: "a", Orientation: rot(180)}},
		{"peer sends no orientation at all",
			protocol.State{Timestamp: 1000, Position: []float64{0, 0}, AreaID: "a"},
			protocol.State{Timestamp: 2000, Position: []float64{10, 0}, AreaID: "a"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var b remoteBuffer
			b.add(tc.older)
			b.add(tc.newer)
			_, br, ok := b.atBracket(1500, 0, CurveLinear, PredictLinear, nil)
			if !ok {
				t.Fatal("atBracket returned ok=false")
			}
			if br.Have {
				t.Fatalf("offered a bracket across %s -- rotation must never interpolate over a seam position refused to cross", tc.name)
			}
		})
	}
}

func TestOrientBracketHoldsPastTheNewestSampleWithPredictionOff(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{Timestamp: 1000, Position: []float64{0}, AreaID: "a", Orientation: rot(0)})
	b.add(protocol.State{Timestamp: 2000, Position: []float64{10}, AreaID: "a", Orientation: rot(90)})

	_, br, _ := b.atBracket(3000, 0, CurveLinear, PredictLinear, nil)
	if br.Have {
		t.Fatal("offered a bracket past the newest sample with prediction off -- holding the newest facing is the honest answer, and is what shipped before this existed")
	}
}

func TestOrientBracketPredictsWhenPositionDoes(t *testing.T) {
	// Samples 50ms apart -- the shipped 20Hz -- turning 10 degrees per step.
	var b remoteBuffer
	b.add(protocol.State{Timestamp: 1000, Position: []float64{0}, AreaID: "a", Orientation: rot(0)})
	b.add(protocol.State{Timestamp: 1050, Position: []float64{10}, AreaID: "a", Orientation: rot(10)})

	_, br, _ := b.atBracket(1075, 300, CurveLinear, PredictLinear, nil)
	if !br.Have {
		t.Fatal("no bracket while position is being predicted -- the body would predict while the head lagged")
	}
	if br.T <= 1 {
		t.Fatalf("bracket T = %v, want above 1: past the newest sample the arc continues rather than stopping", br.T)
	}
	if br.T != 1.5 { // 75ms into a 50ms span
		t.Fatalf("bracket T = %v, want 1.5", br.T)
	}
}

func TestOrientBracketPredictionIsCappedLikePositions(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{Timestamp: 1000, Position: []float64{0}, AreaID: "a", Orientation: rot(0)})
	b.add(protocol.State{Timestamp: 1050, Position: []float64{10}, AreaID: "a", Orientation: rot(10)})

	// 500ms past the newest sample, but only 100ms of prediction allowed.
	_, br, _ := b.atBracket(1550, 100, CurveLinear, PredictLinear, nil)
	if br.T != 3 { // capped to 1050+100 = 1150, i.e. 150ms into a 50ms span
		t.Fatalf("bracket T = %v, want 3 -- a peer who went quiet must stop turning where position stops moving", br.T)
	}
}

func TestOrientBracketRefusesAStaleBaselineForPrediction(t *testing.T) {
	// An idle peer's samples sit a keepalive apart. Reading that pair as a rate
	// is how change suppression would become a slow spin.
	var b remoteBuffer
	b.add(protocol.State{Timestamp: 1000, Position: []float64{0}, AreaID: "a", Orientation: rot(0)})
	b.add(protocol.State{Timestamp: 1000 + maxVelocitySpanMs + 1, Position: []float64{10}, AreaID: "a", Orientation: rot(90)})

	_, br, _ := b.atBracket(1000+maxVelocitySpanMs+20, 300, CurveLinear, PredictLinear, nil)
	if br.Have {
		t.Fatal("predicted rotation from a baseline too old to carry a rate")
	}
}

// TestRenderRemoteCarriesTheBracketOverTheBridge is the end of the plumbing:
// the bracket is useless unless it reaches an adapter, and it reaches one only
// on the bridge message. Nothing about it is on protocol.State, deliberately.
func TestRenderRemoteCarriesTheBracketOverTheBridge(t *testing.T) {
	c := New()
	c.InterpolationDelay = 0
	c.adapterWantsOrientBracket = true // the opt-in this message depends on
	c.roster["p2"] = struct{}{}
	now := time.Now().UnixMilli()
	c.storeRemoteState(protocol.State{PlayerID: "p2", Timestamp: now - 100, Position: []float64{0, 0, 0}, AreaID: "a", Orientation: rot(0)})
	c.storeRemoteState(protocol.State{PlayerID: "p2", Timestamp: now + 100, Position: []float64{10, 0, 0}, AreaID: "a", Orientation: rot(90)})

	var got bridge.RenderRemote
	c.tickRenders(map[string]bool{},
		func(id string, st protocol.State, br orientBracket) {
			got = bridge.RenderRemote{PlayerID: id, State: st}
			if br.Have {
				got.OrientationFrom, got.OrientationTo, got.InterpT = br.From, br.To, br.T
			}
		},
		func(string) {},
	)
	if got.PlayerID != "p2" {
		t.Fatalf("rendered %q, want p2", got.PlayerID)
	}
	if string(got.OrientationFrom) != string(rot(0)) || string(got.OrientationTo) != string(rot(90)) {
		t.Fatalf("bridge message carried %s -> %s, want the bracket", got.OrientationFrom, got.OrientationTo)
	}
	blob, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// The adapter's minimal parsers search for `"key":` -- so the names have to
	// survive serialization intact, and `"orientation":` must not be shadowed.
	for _, want := range []string{`"orientation_from":`, `"orientation_to":`, `"interp_t":`} {
		if !containsSub(string(blob), want) {
			t.Fatalf("serialized render_remote is missing %s: %s", want, blob)
		}
	}
}

func containsSub(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// The opt-in and the two savings, added 2026-08-30 after the first version sent
// the bracket to every adapter. Only a game with CONTINUOUS rotation can use it;
// three of the four shipped adapters have a discrete facing and would discard
// every byte.

func TestNoBracketUnlessTheAdapterAskedForIt(t *testing.T) {
	for _, want := range []bool{false, true} {
		c := New()
		c.InterpolationDelay = 0
		c.adapterWantsOrientBracket = want
		c.roster["p2"] = struct{}{}
		now := time.Now().UnixMilli()
		c.storeRemoteState(protocol.State{PlayerID: "p2", Timestamp: now - 100, Position: []float64{0, 0, 0}, AreaID: "a", Orientation: rot(0)})
		c.storeRemoteState(protocol.State{PlayerID: "p2", Timestamp: now + 100, Position: []float64{10, 0, 0}, AreaID: "a", Orientation: rot(90)})

		states, brackets := c.remoteStatesAt(now)
		if len(states) != 1 {
			t.Fatalf("asked=%v: rendered %d remotes, want 1", want, len(states))
		}
		if got := brackets["p2"].Have; got != want {
			t.Fatalf("asked=%v: bracket present = %v -- an adapter that did not ask must be sent nothing, and one that did must be sent it", want, got)
		}
		if !want && brackets != nil {
			t.Error("the bracket map was allocated for an adapter that never asked")
		}
	}
}

// TestNoBracketWhenNothingRotatedIsVisuallyIdentical is the argument for the
// second saving, kept as a test rather than left in a comment: suppressing the
// bracket when the two orientations are byte-identical cannot change what an
// adapter draws, because interpolating a value toward itself returns that value
// at every fraction -- which is exactly what the adapter's fallback renders.
func TestNoBracketWhenNothingRotatedIsVisuallyIdentical(t *testing.T) {
	var b remoteBuffer
	b.add(protocol.State{Timestamp: 1000, Position: []float64{0}, AreaID: "a", Orientation: rot(42)})
	b.add(protocol.State{Timestamp: 2000, Position: []float64{10}, AreaID: "a", Orientation: rot(42)})

	st, br, _ := b.atBracket(1500, 0, CurveLinear, PredictLinear, nil)
	if br.Have {
		t.Fatal("offered a bracket for a peer whose orientation did not change")
	}
	// What the adapter falls back to must be the same value the suppressed
	// bracket would have produced at any fraction.
	if string(st.Orientation) != string(rot(42)) {
		t.Fatalf("fallback orientation = %s, want %s -- the suppression must be invisible", st.Orientation, rot(42))
	}

	// And the positive control: a peer that DID rotate still gets one, so the
	// suppression is not quietly swallowing real rotation.
	var moved remoteBuffer
	moved.add(protocol.State{Timestamp: 1000, Position: []float64{0}, AreaID: "a", Orientation: rot(42)})
	moved.add(protocol.State{Timestamp: 2000, Position: []float64{10}, AreaID: "a", Orientation: rot(43)})
	if _, br2, _ := moved.atBracket(1500, 0, CurveLinear, PredictLinear, nil); !br2.Have {
		t.Fatal("suppressed the bracket for a peer that rotated by one degree")
	}
}

// TestHelloOptInReachesRenderRemoteEndToEnd is the one that would catch the
// regression that matters: the adapter asks in its Hello, and the bracket has to
// arrive on the real bridge socket. Every layer between those two points is
// exercised -- hello parse, the mirrored preference, remoteStatesAt, the send --
// because a break anywhere in it looks identical from the game's side (a ghost
// whose facing steps again) and identical in the adapter's own logs, which only
// ever prove it SENT the request.
func TestHelloOptInReachesRenderRemoteEndToEnd(t *testing.T) {
	relayAddr := startRelay(t)
	core1, bridge1Addr := startCore(t, relayAddr, "spinner", "room1", "alice")
	core1.MinSendInterval = time.Millisecond
	_, bridge2Addr := startCore(t, relayAddr, "spinner", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter2 := dialFakeAdapter(t, bridge2Addr)
	adapter2.helloInterpolateOrientation("spinner")

	// A peer that is actually TURNING -- a bracket is suppressed for one that
	// is not, so a still peer would make this test pass for the wrong reason.
	yaw := 0.0
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		yaw += 7
		adapter1.frame(&protocol.State{AreaID: "arena", Position: []float64{yaw, 0, 0}, Anim: "idle", Orientation: rot(yaw)})
		adapter2.frame(&protocol.State{AreaID: "arena", Position: []float64{0, 0, 0}, Anim: "idle", Orientation: rot(0)})
		if rr, ok := adapter2.renderMsgOf(core1.PlayerID()); ok && len(rr.OrientationTo) > 0 {
			if len(rr.OrientationFrom) == 0 {
				t.Fatal("render_remote carried orientation_to with no orientation_from -- a bracket must have both ends")
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out: the adapter asked for interpolated orientation and no render_remote ever carried the bracket")
}

// The mirror image, and the reason the opt-in exists: an adapter that does not
// ask is sent nothing, over the same real socket.
func TestNoOptInMeansNoBracketOnTheWire(t *testing.T) {
	relayAddr := startRelay(t)
	core1, bridge1Addr := startCore(t, relayAddr, "stepper", "room1", "alice")
	core1.MinSendInterval = time.Millisecond
	_, bridge2Addr := startCore(t, relayAddr, "stepper", "room1", "bob")

	adapter1 := dialFakeAdapter(t, bridge1Addr)
	adapter2 := dialFakeAdapter(t, bridge2Addr) // no hello opt-in

	yaw := 0.0
	sawRender := false
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		yaw += 7
		adapter1.frame(&protocol.State{AreaID: "arena", Position: []float64{yaw, 0, 0}, Anim: "idle", Orientation: rot(yaw)})
		adapter2.frame(&protocol.State{AreaID: "arena", Position: []float64{0, 0, 0}, Anim: "idle", Orientation: rot(0)})
		if rr, ok := adapter2.renderMsgOf(core1.PlayerID()); ok {
			sawRender = true
			if len(rr.OrientationFrom) > 0 || len(rr.OrientationTo) > 0 || rr.InterpT != 0 {
				t.Fatalf("an adapter that never asked was sent a bracket: from=%s to=%s t=%v",
					rr.OrientationFrom, rr.OrientationTo, rr.InterpT)
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !sawRender {
		t.Fatal("no render_remote arrived at all -- this test proved nothing about the bracket")
	}
}
