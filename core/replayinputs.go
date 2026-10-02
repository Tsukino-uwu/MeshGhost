package core

// A replay's input track, streamed beside its frames to an adapter that asked (bridge.Hello.InputTracks). Each edge
// goes out as remote_input carrying at, the render-clock time it is due, rebased exactly as the samples are (start,
// speed, trim, skip_gaps); the adapter applies it on the first render_remote whose timestamp reaches at.
//
// Edges are sent ahead, in windows of replayInputAheadMs: sent at its due moment, an edge would wait behind the adapter
// writer's queue and land late. Every seam (start, loop, seek, clock step) is a despawn and a fresh pawn, so the first
// line after it carries reset and the header tables again, sent after the seam's admit so it stays behind the despawn.
// The core reads no label, mask or axis; driving anything with a track is the adapter's act.

import (
	"log"
	"sort"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
)

const (
	// replayInputAheadMs is how far ahead of the clock edges are sent.
	replayInputAheadMs = 500
	// replayInputMaxLinesPerCall bounds one call; a denser track waits for the next sample. A window at the bridge's
	// 1000-edges-a-second flood ceiling is 500 edges, 8 lines of 64.
	replayInputMaxLinesPerCall = 8
	// replayMaxTrackEdges bounds what one clip keeps of its track; past it the clip still plays, since an edge missing
	// from the end of a run costs a press, not position. 500,000 edges is ~7 hours at real play's 20 edges a second.
	replayMaxTrackEdges = 500_000
)

// replayMaxTrackEdgesPerArchive bounds the tracks inside one zip, as replayMaxSamplesPerArchive bounds its clips. A var
// so a test can shrink it.
var replayMaxTrackEdgesPerArchive = replayMaxTrackEdges

// gapCut is one skip_gaps cut, recorded so a track goes through the same surgery as the samples: an edge stamped inside
// (from, to) is dropped, and one at or after to shifts back by shift, the cumulative cut so far.
type gapCut struct {
	from, to int64
	shift    int64
}

// attachTrack maps a parsed track onto this clip once at load: the edges inside the trim window, shifted through the
// gap cuts, capped. The header is kept for the label tables.
func (rc *replayClip) attachTrack(t *inputTrack) {
	if t == nil || len(rc.samples) == 0 {
		return
	}
	// Capacity for what this clip may keep, not for the source track: the attach runs once per clip sharing the track's
	// recording_id, so sizing it by the source multiplies.
	room := len(t.edges)
	if room > replayMaxTrackEdges {
		room = replayMaxTrackEdges
	}
	edges := make([]inputEdgeLine, 0, room)
	cut := 0
	dropped := 0
	for _, e := range t.edges {
		if e.Ts < rc.trimFirst || e.Ts > rc.trimLast {
			continue
		}
		// Advance to the last cut that starts before this edge.
		for cut < len(rc.gapCuts) && rc.gapCuts[cut].to <= e.Ts {
			cut++
		}
		// cut now indexes the first cut ending after e.Ts, which is the one this edge falls inside, if any.
		if cut < len(rc.gapCuts) && e.Ts > rc.gapCuts[cut].from {
			dropped++
			continue
		}
		var shift int64
		if cut > 0 {
			shift = rc.gapCuts[cut-1].shift
		}
		e.Ts -= shift
		edges = append(edges, e)
		if len(edges) >= replayMaxTrackEdges {
			log.Printf("core: replay %s: input track %s has more than %d edges inside the clip -- the rest are not kept",
				rc.file, t.file, replayMaxTrackEdges)
			break
		}
	}
	if dropped > 0 {
		log.Printf("core: replay %s: %d input edge(s) fell inside gaps skip_gaps cut and were dropped with them",
			rc.file, dropped)
	}
	rc.track = &inputTrack{file: t.file, header: t.header, edges: edges}
}

// inputStream is the per-player cursor into the clip's track.
type inputStream struct {
	idx       int  // the next edge to send
	needReset bool // the next line carries reset + the header tables
}

// inputReset re-aims the cursor at clip time posMs and arms a reset, after every admit of the ghost.
func (p *replayPlayer) inputReset(posMs int64) {
	tr := p.clip.track
	if tr == nil {
		return
	}
	t0 := p.clip.t0
	p.in.idx = sort.Search(len(tr.edges), func(k int) bool { return tr.edges[k].Ts-t0 >= posMs })
	p.in.needReset = true
}

// streamInputs sends every edge due within the window, in a bounded number of lines, and any pending reset. start is
// the lap base (clip time 0 on nowMs), now the clock.
func (p *replayPlayer) streamInputs(start, now int64) {
	tr := p.clip.track
	if tr == nil {
		return
	}
	horizon := now + replayInputAheadMs
	for lines := 0; lines < replayInputMaxLinesPerCall; lines++ {
		var msg bridge.RemoteInput
		msg.PlayerID = p.id
		for p.in.idx < len(tr.edges) && len(msg.Edges) < bridge.MaxInputEdgesPerBatch {
			e := tr.edges[p.in.idx]
			at := start + int64(float64(e.Ts-p.clip.t0)/p.clip.speed)
			if at > horizon {
				break
			}
			msg.Edges = append(msg.Edges, bridge.RemoteInputEdge{F: e.F, T: e.T, M: e.M, Ax: e.Ax, At: at})
			p.in.idx++
		}
		if len(msg.Edges) == 0 && !p.in.needReset {
			return
		}
		if p.in.needReset {
			// The tables ride the reset line only: the adapter re-learns them after a despawn, since their pawn is
			// gone.
			msg.Reset = true
			msg.Labels = tr.header.Labels
			msg.Axes = tr.header.Axes
			msg.Source = tr.header.Source
			p.in.needReset = false
		}
		if msg.Edges == nil {
			// edges is not omitempty: a reset with nothing due is still a whole message, and a null where an array was
			// promised breaks a reader.
			msg.Edges = []bridge.RemoteInputEdge{}
		}
		if !p.c.sendRemoteInput(msg) {
			return
		}
	}
}

// sendRemoteInput hands one line to an attached adapter that was told bridge_ready. False means nobody is listening;
// the player's frame path sees the same absence and ends the lap, so nothing here retries.
func (c *Core) sendRemoteInput(msg bridge.RemoteInput) bool {
	c.mu.Lock()
	nd := c.attachedAdapter
	ready := c.adapterReady
	c.mu.Unlock()
	if nd == nil || !ready {
		return false
	}
	return c.sendToAdapter(nd, bridge.TypeRemoteInput, msg) == nil
}
