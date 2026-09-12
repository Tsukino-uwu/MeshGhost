package bridge

import (
	"encoding/json"
	"math"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The first fuzz target in this package that calls anything in this package
// (2026-09-12).
//
// `FuzzEnvelopeUnmarshalNeverPanics` and `FuzzHelloUnmarshalNeverPanics` both
// do `json.Unmarshal` into a plain struct and `json.Marshal` back. Neither type
// has a custom UnmarshalJSON, so between them they exercise `encoding/json` --
// which the Go team fuzzes rather better than this repo can -- and zero lines of
// bridge. Two registered targets, a CI step each, a roster row each, and no
// coverage of the package they live in. Found by the coverage cell of the third
// adversarial review (X2-3).
//
// `ValidateInputSample` was the obvious thing they should have been pointed at,
// and it had the opposite problem: it appears in `FuzzParseInputTrackNeverPanics`
// over in core as the ORACLE -- the thing the parser's output is checked
// AGAINST -- and always on a batch of exactly one edge, built by hand from a
// parsed edge. So it was executed constantly and tested never, and the parts of
// it that only exist for a multi-edge batch (the edge cap, the within-batch
// monotonicity) or for a header (labels, axes, source) were never reached at
// all. Found as X2-7 by the same cell.
//
// # What is asserted, and why the second one is the real property
//
//  1. Neither function panics on anything a JSON decoder will produce.
//  2. **They agree.** They are two hand-maintained ladders over one set of
//     rules, walked in the same order, and nothing but this makes them stay in
//     step. A rule added to one and not the other is silent in both directions
//     and bad in both: a batch rejected with an empty reason logs "input batch
//     refused: " and tells the player's log nothing, and a batch accepted while
//     the reason function has an opinion means the reason function is describing
//     a check that no longer runs.
//  3. Anything ACCEPTED really is within the bounds, re-derived here from the
//     constants rather than by calling the function under test. That is what
//     stops a future loosening from being invisible -- a validator that returns
//     true unconditionally passes 1 and 2 perfectly.
func FuzzValidateInputSampleAgreesWithItsOwnRejectReason(f *testing.F) {
	// Real lines first: the two shapes the Pseudoregalia adapter emits, which
	// TestPseudoregaliaAdapterLinesAreAccepted pins by hand.
	f.Add(`{"labels":["jump","attack"],"axes":["move_x","move_y"],"source":"imc_keys","edges":[{"f":1041,"t":17350,"m":1,"ax":[0,0]}]}`)
	f.Add(`{"edges":[{"f":1043,"t":17383,"m":0,"ax":[0.5,-0.25]},{"f":1044,"t":17400,"m":9,"ax":[0.5,-0.25]}]}`)
	f.Add(`{"labels":["jump"],"edges":[]}`)
	// The empty batch that is not a table declaration, which is the one shape
	// both functions special-case.
	f.Add(`{"edges":[]}`)
	f.Add(`{}`)
	// Multi-edge ordering, which the oracle use in core could never reach.
	f.Add(`{"edges":[{"f":2,"t":2},{"f":1,"t":3}]}`)
	f.Add(`{"edges":[{"f":1,"t":9},{"f":2,"t":3}]}`)
	f.Add(`{"edges":[{"f":1,"t":1},{"f":1,"t":1}]}`)
	// Header tables, likewise.
	f.Add(`{"labels":["` + strings.Repeat("x", MaxInputLabelLen+1) + `"],"edges":[{"f":1,"t":1}]}`)
	f.Add(`{"axes":["ok"],"source":"` + strings.Repeat("s", MaxInputLabelLen+1) + `","edges":[{"f":1,"t":1}]}`)
	f.Add(`{"labels":["\ud800"],"edges":[{"f":1,"t":1}]}`)
	// The numeric edges of every field.
	f.Add(`{"edges":[{"f":1,"t":-1}]}`)
	f.Add(`{"edges":[{"f":1,"t":1,"ax":[1e308]}]}`)
	f.Add(`{"edges":[{"f":1,"t":1,"ax":[0,0,0,0,0,0,0,0,0]}]}`)
	f.Add(`{"edges":[{"f":1,"t":1,"m":4294967295}]}`)
	// P2e-1: the frame counter a double cannot carry, which is what the
	// Pseudoregalia adapter narrows with static_cast<uint64_t>.
	f.Add(`{"edges":[{"f":18446744073709551615,"t":1}]}`)
	f.Add(`{"edges":[{"f":9007199254740993,"t":1}]}`)
	f.Add(`{"edges":[{"f":9007199254740992,"t":1}]}`)

	f.Fuzz(func(t *testing.T, body string) {
		var s InputSample
		if err := json.Unmarshal([]byte(body), &s); err != nil {
			return // a batch that does not decode never reaches either function
		}

		ok := ValidateInputSample(s)
		reason := InputSampleRejectReason(s)

		if ok != (reason == "") {
			if ok {
				t.Fatalf("accepted a batch that InputSampleRejectReason objects to (%q); the reason "+
					"function is describing a check that no longer runs: %s", reason, body)
			}
			t.Fatalf("refused a batch with no reason to give, so the core logs an empty one: %s", body)
		}
		if !ok {
			return
		}

		// Re-derived from the constants, not from the validator: a validator
		// that returned true unconditionally would satisfy everything above.
		if len(s.Edges) > MaxInputEdgesPerBatch {
			t.Fatalf("accepted %d edges, over the %d cap", len(s.Edges), MaxInputEdgesPerBatch)
		}
		if len(s.Edges) == 0 && len(s.Labels) == 0 && len(s.Axes) == 0 {
			t.Fatal("accepted an empty batch carrying no table")
		}
		if len(s.Labels) > MaxInputLabels || len(s.Axes) > MaxInputLabels {
			t.Fatalf("accepted %d labels and %d axis names, over the %d cap",
				len(s.Labels), len(s.Axes), MaxInputLabels)
		}
		for _, n := range append(append([]string{}, s.Labels...), append(s.Axes, s.Source)...) {
			if n == s.Source && n == "" {
				continue // source is optional; the tables' entries are not
			}
			if !protocol.ValidOpaqueString(n, MaxInputLabelLen) {
				t.Fatalf("accepted %q as a label, axis name or source", n)
			}
		}
		var lastF uint64
		var lastT int64
		for i, e := range s.Edges {
			if e.T < 0 || e.T > protocol.MaxTimestampMs {
				t.Fatalf("edge %d: accepted t %d", i, e.T)
			}
			// P2e-1. A double cannot represent consecutive integers past 2^53,
			// and the Pseudoregalia adapter reads this field as one before
			// narrowing it to uint64_t -- so anything past here is undefined
			// behaviour in the player's game process.
			if e.F > MaxInputFrame {
				t.Fatalf("edge %d: accepted frame %d, past the %d a double carries exactly",
					i, e.F, uint64(MaxInputFrame))
			}
			if len(e.Ax) > MaxInputAxes {
				t.Fatalf("edge %d: accepted %d axes", i, len(e.Ax))
			}
			for j, v := range e.Ax {
				if math.IsNaN(v) || math.IsInf(v, 0) || v > MaxInputAxisValue || v < -MaxInputAxisValue {
					t.Fatalf("edge %d axis %d: accepted %v", i, j, v)
				}
			}
			if i > 0 && (e.F < lastF || e.T < lastT) {
				t.Fatalf("edge %d: accepted f %d/t %d after %d/%d", i, e.F, e.T, lastF, lastT)
			}
			lastF, lastT = e.F, e.T
		}
	})
}
