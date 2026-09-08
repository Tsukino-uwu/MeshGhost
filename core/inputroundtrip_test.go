package core

import (
	"os"
	"reflect"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
)

// TestInputTrackRoundTrips is what makes the format-stability promise checkable
// rather than a claim in an ADR. A track is meant to still be readable when
// something is finally written to read it, so what goes in comes out -- plain
// and gzipped, since the compressed form is a different write path.
func TestInputTrackRoundTrips(t *testing.T) {
	for _, gz := range []bool{false, true} {
		name := "plain"
		if gz {
			name = "gzip"
		}
		t.Run(name, func(t *testing.T) {
			c := inputCore(t)
			c.ReplayGzip = gz
			path, err := c.StartInputRecording("rec-roundtrip")
			if err != nil {
				t.Fatalf("StartInputRecording: %v", err)
			}

			var want []inputEdgeLine
			var frame uint64
			for i := 0; i < 500; i++ {
				frame++
				s := bridge.InputSample{}
				if i == 0 {
					s.Labels = []string{"jump", "attack", "dash"}
					s.Axes = []string{"move_x", "move_y"}
					s.Source = "pawn_properties"
				}
				// Alternating masks so nothing is suppressed, and axes that
				// survive the 3-decimal rounding exactly.
				e := bridge.InputEdge{
					F: frame, T: int64(frame) * 16, M: uint32(i%7) + 1,
					Ax: []float64{float64(i%100) / 100.0, -float64(i%50) / 100.0},
				}
				s.Edges = append(s.Edges, e)
				c.recordInput(s)
				want = append(want, inputEdgeLine{F: e.F, T: e.T, M: e.M, Ax: e.Ax})
			}
			if _, written, err := c.StopInputRecording(); err != nil {
				t.Fatalf("StopInputRecording: %v", err)
			} else if written != len(want) {
				t.Fatalf("wrote %d edges, offered %d", written, len(want))
			}

			track, err := loadInputTrack(path)
			if err != nil {
				t.Fatalf("loadInputTrack: %v", err)
			}
			if len(track.edges) != len(want) {
				t.Fatalf("read back %d edges, want %d", len(track.edges), len(want))
			}
			for i := range want {
				got := track.edges[i]
				if got.F != want[i].F || got.T != want[i].T || got.M != want[i].M {
					t.Fatalf("edge %d: got f=%d t=%d m=%d, want f=%d t=%d m=%d",
						i, got.F, got.T, got.M, want[i].F, want[i].T, want[i].M)
				}
				if !reflect.DeepEqual(got.Ax, want[i].Ax) {
					t.Fatalf("edge %d: axes %v, want %v", i, got.Ax, want[i].Ax)
				}
			}
			if track.header.Source != "pawn_properties" {
				t.Errorf("source %q did not survive the round trip", track.header.Source)
			}
			if len(track.header.Labels) != 3 || len(track.header.Axes) != 2 {
				t.Errorf("labels %v / axes %v did not survive the round trip",
					track.header.Labels, track.header.Axes)
			}
		})
	}
}

// A track cut off mid-line -- the writer flushes on a clock, so this is what a
// track read while it is still being written looks like -- keeps everything
// that WAS written, exactly as a clip does (ADR 0051).
func TestInputTrackToleratesAHalfWrittenFinalLine(t *testing.T) {
	c := inputCore(t)
	path, err := c.StartInputRecording("")
	if err != nil {
		t.Fatalf("StartInputRecording: %v", err)
	}
	for i := 1; i <= 10; i++ {
		c.recordInput(batch(nil, [2]uint64{uint64(i), uint64(i % 2)}))
	}
	if _, _, err := c.StopInputRecording(); err != nil {
		t.Fatalf("StopInputRecording: %v", err)
	}

	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	// Chop the last line in half.
	cut := len(b) - 12
	if cut <= 0 {
		t.Fatal("the track is too short to truncate meaningfully")
	}
	truncated := path + ".partial.ndjson"
	if err := os.WriteFile(truncated, b[:cut], 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	track, err := loadInputTrack(truncated)
	if err != nil {
		t.Fatalf("a half-written final line was refused: %v", err)
	}
	if len(track.edges) == 0 {
		t.Error("everything before the truncation was thrown away")
	}
}
