package core

import (
	"bytes"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// FuzzParseReplayNeverPanics is the loader's pin (ADR 0047): a replay file is
// a stranger's bytes -- shared, hand-edited, or hostile -- and the loader must
// refuse or accept them without ever panicking, and anything it accepts must
// pass the same validation a relay packet does, sample by sample.
//
// Run a long campaign by hand after touching the loader or protocol limits:
//
//	go test ./core -run=XXX -fuzz=FuzzParseReplayNeverPanics -fuzztime=10m
func FuzzParseReplayNeverPanics(f *testing.F) {
	f.Add(clipBytes(map[string]any{"name": "PB", "speed": 2.0, "loop": true}, walkStates(3, 50)))
	f.Add(clipBytes(map[string]any{"trim_start": "auto", "skip_gaps": "1s", "trim_end": "10ms"}, walkStates(5, 800)))
	f.Add([]byte(`{"meshghost_replay":1}` + "\n" + `{"area_id":"a","position":[1,2]}` + "\n"))
	f.Add([]byte(`{"meshghost_replay":7,"speed":"fast"}` + "\n"))
	f.Add([]byte("not json at all\n"))
	f.Add([]byte{})
	f.Add([]byte("\n\n\n"))
	f.Add(bytes.Repeat([]byte("x"), protocol.MaxLineBytes+1))

	f.Fuzz(func(t *testing.T, data []byte) {
		clip, err := parseReplay(bytes.NewReader(data), "fuzz")
		if err != nil {
			return
		}
		if len(clip.samples) == 0 {
			t.Fatal("a clip with no samples was accepted")
		}
		var prev int64 = -1
		for i, st := range clip.samples {
			if !protocol.ValidateState(st) {
				t.Fatalf("sample %d accepted by the loader fails ValidateState: %s", i, protocol.StateRejectReason(st))
			}
			if st.PlayerID != "" || st.Prev != nil {
				t.Fatalf("sample %d kept a player id or loss cover: %+v", i, st)
			}
			if st.Timestamp < prev {
				t.Fatalf("sample %d goes backwards in time", i)
			}
			prev = st.Timestamp
		}
		if clip.speed < replaySpeedMin || clip.speed > replaySpeedMax {
			t.Fatalf("speed %v escaped the clamp", clip.speed)
		}
		if clip.startDelay < 0 || clip.startDelay > replayMaxDelay {
			t.Fatalf("start delay %v escaped the clamp", clip.startDelay)
		}
		if protocol.SanitizeDisplayName(clip.header.Name) != clip.header.Name {
			t.Fatalf("header name %q is not sanitized", clip.header.Name)
		}
	})
}
