package bridge

import (
	"encoding/json"
	"math"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// FuzzValidateInputSampleAgreesWithItsOwnRejectReason: neither function panics; they agree, since they are two
// hand-maintained ladders over one set of rules; and anything accepted is within the bounds, re-derived from the
// constants so a validator that always returned true would still fail.
func FuzzValidateInputSampleAgreesWithItsOwnRejectReason(f *testing.F) {
	// The three shapes one shipped adapter emits, pinned by hand in TestPseudoregaliaAdapterLinesAreAccepted.
	f.Add(`{"labels":["jump","attack"],"axes":["move_x","move_y"],"source":"imc_keys","edges":[{"f":1041,"t":17350,"m":1,"ax":[0,0]}]}`)
	f.Add(`{"edges":[{"f":1043,"t":17383,"m":0,"ax":[0.5,-0.25]},{"f":1044,"t":17400,"m":9,"ax":[0.5,-0.25]}]}`)
	f.Add(`{"labels":["jump"],"edges":[]}`)
	// The empty batch that is not a table declaration, which both functions special-case.
	f.Add(`{"edges":[]}`)
	f.Add(`{}`)
	// Multi-edge ordering.
	f.Add(`{"edges":[{"f":2,"t":2},{"f":1,"t":3}]}`)
	f.Add(`{"edges":[{"f":1,"t":9},{"f":2,"t":3}]}`)
	f.Add(`{"edges":[{"f":1,"t":1},{"f":1,"t":1}]}`)
	// Header tables.
	f.Add(`{"labels":["` + strings.Repeat("x", MaxInputLabelLen+1) + `"],"edges":[{"f":1,"t":1}]}`)
	f.Add(`{"axes":["ok"],"source":"` + strings.Repeat("s", MaxInputLabelLen+1) + `","edges":[{"f":1,"t":1}]}`)
	f.Add(`{"labels":["\ud800"],"edges":[{"f":1,"t":1}]}`)
	// The numeric edges of every field.
	f.Add(`{"edges":[{"f":1,"t":-1}]}`)
	f.Add(`{"edges":[{"f":1,"t":1,"ax":[1e308]}]}`)
	f.Add(`{"edges":[{"f":1,"t":1,"ax":[0,0,0,0,0,0,0,0,0]}]}`)
	f.Add(`{"edges":[{"f":1,"t":1,"m":4294967295}]}`)
	// Frame counters a double cannot carry exactly.
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
