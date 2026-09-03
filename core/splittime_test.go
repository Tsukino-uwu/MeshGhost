package core

import (
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestSplitTimeShowsHowFarBehindTheGhostThePlayerIs: the ghost walks
// x = 0..99 in 1s (10ms a sample); the player walks the same line at half
// that pace. At the player's x, the ghost was there half as long ago as the
// player took to get there, so the tag reads "+<about half the elapsed>s"
// and grows as the player falls further behind.
func TestSplitTimeShowsHowFarBehindTheGhostThePlayerIs(t *testing.T) {
	c, fa := replayCore(t)
	c.SplitTimes = true
	writeActive(t, c, "pb.ndjson", clipBytes(map[string]any{"name": "PB", "color": "#FF8800"}, walkStates(100, 10)))
	c.StartReplays()
	const id = "replay:pb.ndjson"

	start := time.Now()
	var tag string
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		elapsed := time.Since(start)
		x := float64(elapsed / (20 * time.Millisecond)) // half the ghost's pace
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
		time.Sleep(10 * time.Millisecond)
		fa.mu.Lock()
		tag = fa.names[id].DisplayName
		fa.mu.Unlock()
		if x >= 40 && strings.HasPrefix(tag, "PB +") {
			// At x=40 the player has spent 800ms; the ghost passed x=40 at
			// 400ms. Delta ~ +0.4s, growing. Accept a generous band.
			var secs float64
			if _, err := fmtSscanf(tag, &secs); err != nil {
				t.Fatalf("tag %q did not parse", tag)
			}
			if secs < 0.15 || secs > 1.0 {
				t.Fatalf("tag %q: delta %.2fs at x=%.0f, want roughly +0.4s", tag, secs, x)
			}
			return
		}
	}
	t.Fatalf("no split tag appeared; last nametag %q", tag)
}

// fmtSscanf pulls the seconds out of "PB  +0.4s".
func fmtSscanf(tag string, secs *float64) (int, error) {
	i := strings.LastIndex(tag, " ")
	if i < 0 {
		return 0, errNoSplit
	}
	s := strings.TrimSuffix(tag[i+1:], "s")
	var v float64
	var sign float64 = 1
	if strings.HasPrefix(s, "+") {
		s = s[1:]
	} else if strings.HasPrefix(s, "-") {
		sign = -1
		s = s[1:]
	}
	if _, err := parseFloat(s, &v); err != nil {
		return 0, err
	}
	*secs = sign * v
	return 1, nil
}

var errNoSplit = &splitParseError{}

type splitParseError struct{}

func (*splitParseError) Error() string { return "no split suffix" }

func parseFloat(s string, v *float64) (int, error) {
	var whole, frac float64
	var seenDot bool
	var div float64 = 1
	for _, ch := range s {
		switch {
		case ch == '.':
			seenDot = true
		case ch >= '0' && ch <= '9':
			if seenDot {
				div *= 10
				frac = frac*10 + float64(ch-'0')
			} else {
				whole = whole*10 + float64(ch-'0')
			}
		default:
			return 0, errNoSplit
		}
	}
	*v = whole + frac/div
	return 1, nil
}

// TestSplitTimeIgnoresAnotherAreaAndTheNameStaysShort: a player in another
// area gets no split; a long header name is clamped so the suffix survives the
// 24-character nametag cap.
func TestSplitTimeIgnoresAnotherAreaAndTheNameStaysShort(t *testing.T) {
	c, fa := replayCore(t)
	c.SplitTimes = true
	writeActive(t, c, "long.ndjson", clipBytes(map[string]any{"name": "AVeryLongGhostNameIndeed"}, walkStates(100, 10)))
	c.StartReplays()
	const id = "replay:long.ndjson"
	for i := 0; i < 30; i++ {
		fa.frame(&protocol.State{AreaID: "elsewhere", Position: []float64{float64(i), 0}})
		time.Sleep(10 * time.Millisecond)
	}
	fa.mu.Lock()
	tag := fa.names[id].DisplayName
	fa.mu.Unlock()
	if strings.Contains(tag, "s") && strings.Contains(tag, "+") {
		t.Fatalf("a split %q was published while the player was in another area", tag)
	}
	start := time.Now()
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		x := float64(time.Since(start) / (20 * time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
		time.Sleep(10 * time.Millisecond)
		fa.mu.Lock()
		tag = fa.names[id].DisplayName
		fa.mu.Unlock()
		if strings.Contains(tag, " ") && strings.HasSuffix(tag, "s") {
			if len(tag) > 24 {
				t.Fatalf("tag %q is longer than the 24-char nametag cap", tag)
			}
			if !strings.HasPrefix(tag, "AVeryLongGhostNa") {
				t.Fatalf("tag %q lost its name prefix", tag)
			}
			return
		}
	}
	t.Fatalf("no split tag appeared in the shared area; last %q", tag)
}

// TestSplitTimesAreOffByDefault: with the switch off the replay ghost's tag
// is the header name and nothing else, however far behind the player falls.
func TestSplitTimesAreOffByDefault(t *testing.T) {
	c, fa := replayCore(t)
	writeActive(t, c, "pb.ndjson", clipBytes(map[string]any{"name": "PB"}, walkStates(100, 10)))
	c.StartReplays()
	start := time.Now()
	for time.Since(start) < 600*time.Millisecond {
		x := float64(time.Since(start) / (20 * time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
		time.Sleep(10 * time.Millisecond)
	}
	fa.mu.Lock()
	tag := fa.names["replay:pb.ndjson"].DisplayName
	fa.mu.Unlock()
	if tag != "PB" {
		t.Fatalf("tag %q with split times off, want the bare header name", tag)
	}
}
