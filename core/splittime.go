package core

// Split times: "you are 1.2s behind your ghost", on the ghost's nametag
// (ADR 0047). Game-agnostic by construction: the core has the replay's
// samples and the player's live samples, both position streams in the same
// opaque units, and asks one question -- when did the recording pass the spot
// the player is at now? -- with an equality test on area_id and a Euclidean
// distance over the shared position components. The delta rides the existing
// remote_name message, so every adapter with nametags shows it with no change.
//
// Routes revisit places, so the search never scans the whole clip: it looks
// a window of samples either side of the last match, which also makes the
// match monotone on a straight run and cheap at frame rate.

import (
	"fmt"
	"math"
	"sync"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

const (
	// splitWindow is how many samples either side of the last match are
	// searched for the player's current position.
	splitWindow = 60
	// splitPublishMs bounds how often a nametag can change for a split.
	splitPublishMs = 250
	// splitNameMax keeps room for the suffix under the 24-char nametag cap
	// (one space and up to seven characters, e.g. " +12.3s").
	splitNameMax = 16
	// splitMaxDistance: farther than this from every sample in the window,
	// and the player is simply not on the ghost's path here -- no update.
	splitMaxDistance = 3.0
)

// splitState is per replay player.
type splitState struct {
	mu          sync.Mutex
	matchIdx    int
	lastPublish int64
	lastText    string
}

// distance is Euclidean over the components both positions have.
func distance(a, b []float64) float64 {
	n := len(a)
	if len(b) < n {
		n = len(b)
	}
	if n == 0 {
		return math.Inf(1)
	}
	var sum float64
	for i := 0; i < n; i++ {
		d := a[i] - b[i]
		sum += d * d
	}
	return math.Sqrt(sum)
}

// updateSplits is called with every local in-game sample (from the recorder
// tap). For each running replay it finds the nearest recorded sample near the
// last match, compares elapsed times, and re-publishes the nametag when the
// rounded delta changes.
func (c *Core) updateSplits(local *protocol.State) {
	if !c.SplitTimes || len(local.Position) == 0 {
		return
	}
	c.replayMu.Lock()
	players := make([]*replayPlayer, 0, len(c.replays))
	for _, p := range c.replays {
		if p.running() {
			players = append(players, p)
		}
	}
	c.replayMu.Unlock()
	if len(players) == 0 {
		return
	}
	now := c.nowMs()
	for _, p := range players {
		select {
		case <-p.done:
			continue
		default:
		}
		p.mu.Lock()
		startedAt, idx := p.startedAt, p.idx
		p.mu.Unlock()
		if startedAt == 0 || now < startedAt {
			continue
		}
		clip := p.clip
		// Search around the last split match (kept on the player's split
		// state), seeded from the playback index the first time.
		p.split.mu.Lock()
		center := p.split.matchIdx
		if center == 0 {
			center = idx
		}
		lo, hi := center-splitWindow, center+splitWindow
		if lo < 0 {
			lo = 0
		}
		if hi > len(clip.samples) {
			hi = len(clip.samples)
		}
		best, bestD := -1, splitMaxDistance
		for i := lo; i < hi; i++ {
			s := &clip.samples[i]
			if s.AreaID != local.AreaID {
				continue
			}
			if d := distance(s.Position, local.Position); d < bestD {
				best, bestD = i, d
			}
		}
		if best < 0 {
			p.split.mu.Unlock()
			continue
		}
		p.split.matchIdx = best
		// The ghost was HERE at ghostElapsed into its run; the player is here
		// at localElapsed into theirs. Positive = the player is behind.
		ghostElapsed := float64(clip.samples[best].Timestamp-clip.t0) / clip.speed
		localElapsed := float64(now - startedAt)
		delta := (localElapsed - ghostElapsed) / 1000
		text := fmt.Sprintf("%+.1fs", delta)
		if text == "+0.0s" || text == "-0.0s" {
			text = "0.0s"
		}
		publish := text != p.split.lastText && now-p.split.lastPublish >= splitPublishMs
		if publish {
			p.split.lastText = text
			p.split.lastPublish = now
		}
		p.split.mu.Unlock()
		if !publish {
			continue
		}
		base := clip.header.Name
		if base == "" {
			base = "Ghost"
		}
		if len(base) > splitNameMax {
			base = base[:splitNameMax]
		}
		c.storeRemoteNameQuiet(p.id, &protocol.Nametag{Name: base + " " + text, Color: clip.header.Color})
	}
}

// splitOff clears a player's split state (on seek or restart), so the next
// match is searched from the playback index again.
func (p *replayPlayer) splitReset() {
	p.split.mu.Lock()
	p.split.matchIdx = 0
	p.split.lastText = ""
	p.split.mu.Unlock()
}
