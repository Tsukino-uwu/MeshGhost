package core

// A replay's input track, streamed beside its frames (ADR 0057).
//
// A clip that was recorded with replay.inputs on has a second file beside it
// (ADR 0056): what the player PRESSED, as edges stamped in the same clock the
// clip's samples are. When such a clip plays for an adapter that asked
// (bridge.Hello.InputTracks), the edges go to the adapter as remote_input
// messages, each carrying `at` -- the render-clock time it is due -- computed
// through exactly the rebasing the samples get: start, speed, and the trim and
// skip_gaps the header asked for. The adapter applies an edge on the first
// render_remote whose state.timestamp reaches `at`, so a press lands on the
// frame the ghost's rendered state lands on, whatever the bridge's latency.
//
// AHEAD, NOT JUST IN TIME. Edges are sent in windows of replayInputAheadMs of
// replay time, from the player's own goroutine right after it feeds a sample.
// Sending each edge at its due moment would put it behind the adapter writer's
// queue -- which can hold a line for hundreds of ms under a slow adapter and
// one poll interval under a healthy one -- and the adapter would apply it late
// by that much, unmeasurably. The `at` stamp plus a lookahead makes alignment
// independent of the bridge; the cost is a few hundred buffered edges per
// ghost on the adapter's side.
//
// EVERY SEAM IS A RESET. The clip starting, looping, being seeked, or re-based
// after a clock step is a drop-and-readmit of the ghost (replayPlayer.seam),
// which reaches the adapter as a despawn_remote and a fresh pawn. The first
// remote_input after any of those carries reset=true and the header tables
// again, so the adapter drops what it held and re-learns the labels. The
// reset is sent AFTER the seam's admit, from the next streamInputs call,
// which is what keeps it behind the despawn on the bridge (the writer keeps
// every non-render message in order).
//
// THE CORE STAYS BLIND. Nothing here reads a label, decomposes a mask or
// branches on an axis. It copies a file's edges to an adapter at the times a
// clip says, and could not tell a jump from a pause button while doing it.
// Driving anything with a track is the adapter's act and the adapter's rule
// (adapters/_template/PROTOCOL.md); the core drives nothing.

import (
	"log"
	"sort"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
)

const (
	// replayInputAheadMs is how far ahead of the clock edges are sent.
	replayInputAheadMs = 500
	// replayInputMaxLinesPerCall bounds one streamInputs call: a track dense
	// enough to need more waits for the next sample, which is at most one
	// recording interval away. A window is replayInputAheadMs long, so even at
	// the bridge's 1000-edges-a-second flood ceiling that is 500 edges, or 8
	// lines of 64.
	replayInputMaxLinesPerCall = 8
	// replayMaxTrackEdges bounds what one clip keeps resident from its track.
	// A track is truncated here and the clip still plays: unlike a sample,
	// an edge missing from the END of a run costs the ghost a press, not its
	// position. 500,000 edges is ~7 hours at real play's 20 edges a second.
	replayMaxTrackEdges = 500_000
)

// replayMaxTrackEdgesPerArchive bounds the tracks inside ONE zip the way
// replayMaxSamplesPerArchive bounds its clips: an archive is a stranger's
// bytes, and a track inside one may not cost more than a single track is
// allowed to. A var so a test can shrink it.
var replayMaxTrackEdgesPerArchive = replayMaxTrackEdges

// gapCut is one skip_gaps cut, recorded by applySkipGaps so a track can be
// mapped through the same surgery the samples had: every edge with a raw
// stamp inside (from, to) fell in the cut and is dropped, every edge at or
// after `to` is shifted back by `shift` -- the cumulative cut so far.
type gapCut struct {
	from, to int64
	shift    int64
}

// attachTrack maps a parsed track onto this clip: the edges inside the trim
// window, shifted through the gap cuts, capped. The result replaces
// rc.track's edges; rc.track's header is kept for the label tables.
//
// Done once at load rather than per edge at stream time, so the stream loop
// is one comparison per edge and the seek search is a sort.Search over
// stamps already in the clip's own domain.
func (rc *replayClip) attachTrack(t *inputTrack) {
	if t == nil || len(rc.samples) == 0 {
		return
	}
	edges := make([]inputEdgeLine, 0, len(t.edges))
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
		// cut now indexes the first cut whose `to` is after e.Ts; the cut
		// this edge falls INSIDE, if any, is that one.
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

// inputReset re-aims the cursor at clip time posMs and arms a reset. Called
// after every admit of the ghost -- the start, a loop, a seek, a clock step --
// so the first line after the seam says so.
func (p *replayPlayer) inputReset(posMs int64) {
	tr := p.clip.track
	if tr == nil {
		return
	}
	t0 := p.clip.t0
	p.in.idx = sort.Search(len(tr.edges), func(k int) bool { return tr.edges[k].Ts-t0 >= posMs })
	p.in.needReset = true
}

// streamInputs sends every edge due within the window, at most a bounded
// number of lines, and the pending reset if any. start is the player's
// current lap base (clip time 0 in nowMs), now the clock.
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
			// The tables ride the reset line only: sticky, like every
			// declaration on the bridge, and the adapter re-learns them
			// after a despawn because the pawn it applied them to is gone.
			msg.Reset = true
			msg.Labels = tr.header.Labels
			msg.Axes = tr.header.Axes
			msg.Source = tr.header.Source
			p.in.needReset = false
		}
		if msg.Edges == nil {
			// `edges` is not omitempty, deliberately: a reset with nothing due
			// yet is still a whole message, and an adapter reading a null
			// where an array was promised is a bug report waiting to happen.
			msg.Edges = []bridge.RemoteInputEdge{}
		}
		if !p.c.sendRemoteInput(msg) {
			return
		}
	}
}

// sendRemoteInput hands one line to the attached adapter, if there is one
// that has been told bridge_ready. false means nobody is listening; the
// player's frame path notices the same absence and ends the lap, so nothing
// here retries.
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
