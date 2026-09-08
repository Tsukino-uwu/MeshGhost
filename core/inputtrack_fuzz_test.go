package core

import (
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// FuzzParseInputTrackNeverPanics holds the track parser to the same promise
// parseReplay is held to: a file is a stranger's bytes the moment one person
// sends another a track, and the parser's job is to refuse rather than to
// crash. Anything it ACCEPTS must also meet the bounds a live batch would have
// met -- a file is not a way around the validator.
func FuzzParseInputTrackNeverPanics(f *testing.F) {
	f.Add(`{"meshghost_inputs":1,"game":"g","labels":["jump"]}` + "\n" +
		`{"ts":1,"f":1,"t":16,"m":1}` + "\n" +
		`{"ts":2,"f":2,"t":32,"m":0,"ax":[0.5,-0.25]}` + "\n")
	f.Add(`{"meshghost_inputs":1}` + "\n")
	f.Add(`{"meshghost_inputs":7,"game":"g"}` + "\n" + `{"ts":1,"f":1,"t":1,"m":1}` + "\n")
	f.Add(`{"meshghost_replay":1,"game":"g"}` + "\n") // a CLIP: must be refused, not read
	f.Add("not json at all\n")
	f.Add("")
	f.Add("\n\n\n")
	f.Add(`{"meshghost_inputs":1}` + "\n" + strings.Repeat("A", protocol.MaxLineBytes+10) + "\n")
	f.Add(`{"meshghost_inputs":1}` + "\n" + `{"ts":1,"f":1,"t":-5,"m":1}` + "\n")
	f.Add(`{"meshghost_inputs":1}` + "\n" + `{"ts":1,"f":9,"t":9,"m":1}` + "\n" + `{"ts":0,"f":1,"t":1,"m":1}` + "\n")
	f.Add(`{"meshghost_inputs":1}` + "\n" + `{"ts":1,"f":1,"t":1,"m":1,"ax":[1e308]}` + "\n")
	f.Add(`{"meshghost_inputs":1}` + "\n" + `{"ts":1,"f":1,"t":1,"m":4294967295}` + "\n")
	f.Add(`{"meshghost_inputs":1,"labels":["` + strings.Repeat("x", 200) + `"]}` + "\n")

	f.Fuzz(func(t *testing.T, body string) {
		track, err := parseInputTrack(strings.NewReader(body), "fuzz")
		if err != nil {
			return
		}
		if track == nil {
			t.Fatal("no error and no track")
		}
		if track.header.Format == 0 {
			t.Fatal("accepted a file with no meshghost_inputs key")
		}
		if len(track.header.Labels) > bridge.MaxInputLabels {
			t.Fatalf("accepted %d labels, over the %d cap", len(track.header.Labels), bridge.MaxInputLabels)
		}
		for i, e := range track.edges {
			if e.Ts < 0 {
				t.Fatalf("edge %d: accepted ts %d", i, e.Ts)
			}
			s := bridge.InputSample{Edges: []bridge.InputEdge{{F: e.F, T: e.T, M: e.M, Ax: e.Ax}}}
			if !bridge.ValidateInputSample(s) {
				t.Fatalf("edge %d passed the parser but fails the validator: %s",
					i, bridge.InputSampleRejectReason(s))
			}
			if i > 0 {
				p := track.edges[i-1]
				if e.Ts < p.Ts || e.F < p.F || e.T < p.T {
					t.Fatalf("edge %d is out of order: ts %d/f %d/t %d after %d/%d/%d",
						i, e.Ts, e.F, e.T, p.Ts, p.F, p.T)
				}
			}
		}
	})
}
