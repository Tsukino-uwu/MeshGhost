package core

// Remote peers: what the core knows about them and what it hands the adapter. area_id is compared for equality and
// never parsed (internal/gameblind walks this package's AST to enforce it).

import (
	"fmt"
	"log"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// storeRemoteState validates and buffers one remote sample. It has no acceptableRelayPeerID gate: feedLocalPeer routes
// this core's own replay and chaser ids through here, and the gate belongs at the relay-facing callers.
func (c *Core) storeRemoteState(st protocol.State) {
	if st.PlayerID == "" {
		return
	}
	atomic.AddUint64(&c.stats.statesReceived, 1)
	// The relay's own checks again: a hostile relay is not trusted to have enforced them.
	if !protocol.ValidateState(st) {
		// A dropped state must say so, throttled like the relay's twin.
		now := time.Now() // wall-clock: a five-second LOG throttle, not staleness (that comes from nowMs)
		if last := c.lastStateDropLog.Load(); last == nil || now.Sub(*last) >= 5*time.Second {
			stamp := now
			c.lastStateDropLog.Store(&stamp)
			log.Printf("core: dropping state from %s: %s (repeats suppressed for 5s)", st.PlayerID, protocol.StateRejectReason(st))
		}
		return
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	// Under the lock: c.playerID is written under c.mu.
	if st.PlayerID == c.playerID {
		return
	}
	if _, known := c.roster[st.PlayerID]; !known {
		// An id never seen in a Welcome or Join is dropped. The exception is one aged out for silence: a fresh state
		// is that peer coming back, and it retakes a seat through the capped admission.
		if _, was := c.agedOut[st.PlayerID]; !was || !c.admitToRosterLocked(st.PlayerID) {
			return
		}
		delete(c.agedOut, st.PlayerID)
		atomic.AddUint64(&c.stats.remotesReturned, 1)
		log.Printf("core: %s is sending again after going quiet -- back in the room", st.PlayerID)
	}
	b, ok := c.remotes[st.PlayerID]
	if !ok {
		b = &remoteBuffer{}
		c.remotes[st.PlayerID] = b
	}
	// Set on every sample: InterpolationDelay and Extrapolate may change while running.
	b.historyMs = c.requiredHistoryMsLocked()
	b.lastTransitMs = c.nowMsLocked() - st.Timestamp
	// The receiver's own clock, so the age-out has one fact about this peer that the peer does not supply.
	b.lastArrivalMs = c.nowMsLocked()
	c.transit.record(b.lastTransitMs)
	// Error decay: remember where this ghost is drawn before the new sample moves it, so the difference can slide
	// away. Only with the knob on, never for a local peer, and with a nil meter: these are probes, not renders.
	correct := c.Correction > 0 && !isLocalPeerID(st.PlayerID)
	var drawn protocol.State
	var okDrawn bool
	var speedBefore float64
	var renderTime int64
	if correct {
		now := c.nowMsLocked()
		renderTime = now - c.InterpolationDelay.Milliseconds()
		b.decayCorrection(now, c.Correction.Milliseconds())
		speedBefore = b.topSpeed
		drawn, okDrawn = b.atAhead(renderTime, c.Extrapolate.Milliseconds(), c.Curve, c.Predict, nil)
		drawn = b.withCorrection(drawn)
	}
	// Loss cover: a state may carry the sample sent before it, buffered first if it never arrived, so the ghost walks
	// through it instead of over the hole. The carrying state is stored without it: the buffer holds samples.
	if st.Prev != nil {
		if prev, ok := protocol.ApplyPrev(&st); ok && !b.hasSample(prev.Seq, prev.Timestamp) {
			b.add(prev)
			atomic.AddUint64(&c.stats.prevRecovered, 1)
		}
		st.Prev = nil
	}
	b.add(st)
	if correct {
		after, okAfter := b.atAhead(renderTime, c.Extrapolate.Milliseconds(), c.Curve, c.Predict, nil)
		reach := c.Extrapolate.Milliseconds() + c.Correction.Milliseconds()
		b.noteCorrection(drawn, okDrawn, after, okAfter, speedBefore, reach, c.nowMsLocked())
	}
}

// requiredHistoryMsLocked is how far back a remote's buffer must reach: the interpolation delay, the prediction window
// (extrapolate measures velocity over a pair behind the render time), and maxVelocitySpanMs plus historyMarginMs for
// jitter and Catmull-Rom's outer samples. Floored at defaultSnapshotAgeMs so no shipped setting loses window, and
// capped against a hostile one. Local peers share it: theirs would floor to the same. Caller must hold c.mu.
func (c *Core) requiredHistoryMsLocked() int64 {
	need := c.InterpolationDelay.Milliseconds() + c.Extrapolate.Milliseconds() + maxVelocitySpanMs + historyMarginMs
	if need < defaultSnapshotAgeMs {
		need = defaultSnapshotAgeMs
	}
	if need > maxHistoryMs {
		need = maxHistoryMs
	}
	return need
}

// rememberAgedOutLocked records that id lost its seat to silence rather than a Leave, so a state from it can retake
// one. The set is capped because a relay can cycle join, one state, silence; both age-out paths share this one copy of
// the cap. Caller holds c.mu and has already taken the seat.
func (c *Core) rememberAgedOutLocked(id string) {
	atomic.AddUint64(&c.stats.remotesAgedOut, 1)
	// Full means forget the peer, tag too: it is then exactly an id that left, admitted fresh on its next Join.
	if len(c.agedOut) >= protocol.MaxRosterSize {
		delete(c.remoteNames, id)
		return
	}
	if c.agedOut == nil {
		c.agedOut = make(map[string]struct{})
	}
	c.agedOut[id] = struct{}{}
}

// sweepSeatlessLocked takes back roster seats that never had a state behind them, which the buffer age-out cannot
// see: stateless Joins cost a relay nothing and would lock the room shut. Local ids are exempt: one is admitted before
// its goroutine has fed anything. Caller holds c.mu; cutoff is remoteStatesAt's.
func (c *Core) sweepSeatlessLocked(cutoff int64) {
	for id, seatedAt := range c.roster {
		// Zero is "unset" (see Core.roster) and never sweeps.
		if seatedAt == 0 || seatedAt >= cutoff || isLocalPeerID(id) {
			continue
		}
		if _, buffered := c.remotes[id]; buffered {
			continue
		}
		delete(c.roster, id)
		c.rememberAgedOutLocked(id)
	}
}

func (c *Core) dropRemote(playerID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.remotes, playerID)
}

// dropAllRemotes clears every tracked remote when the relay connection is lost: nothing is left to drive individual
// despawns.
func (c *Core) dropAllRemotes() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.remotes = make(map[string]*remoteBuffer)
}

// remoteStatesAt returns the interpolated state of every known remote in this Core's own area (every remote while
// that area is still unknown), with orientation brackets when the adapter asked. It takes now, not a render time: a
// ghost this core invented is not delayed for a network it never crossed.
func (c *Core) remoteStatesAt(now int64) (map[string]protocol.State, map[string]orientBracket) {
	c.mu.Lock()
	defer c.mu.Unlock()
	netRenderTime := now - c.InterpolationDelay.Milliseconds()
	localRenderTime := now - c.LocalInterpolationDelay.Milliseconds()
	out := make(map[string]protocol.State, len(c.remotes))
	// A separate map, not a field on protocol.State, which is the wire packet. Nil unless the adapter asked: a
	// discrete facing cannot use a midpoint between two orientations.
	var brackets map[string]orientBracket
	if c.adapterWantsOrientBracket {
		brackets = make(map[string]orientBracket, len(c.remotes))
	}
	// Age out a peer nobody hears from: a buffer that stops being fed keeps answering with its newest sample, and a
	// Leave cannot be relied on (a hard-killed client, udp, the dev loopback echo).
	stale := c.remoteStaleAfter()
	cutoff := c.nowMsLocked() - stale.Milliseconds()
	// A Join with no state behind it has no buffer, so the loop below cannot see its seat.
	if stale > 0 {
		c.sweepSeatlessLocked(cutoff)
	}
	for id, buf := range c.remotes {
		// The id, not a c.localPeers lookup: membership drops at every seam, and a tick inside one would move this
		// ghost's render time and teleport it.
		local := isLocalPeerID(id)
		// A local peer is exempt from the age-out: it has no far side and is dropped explicitly, and its feed stops
		// on the gameplay clock during a pause while render ticks go on. Either kind of silence counts, since a
		// timestamp is the sender's choice and can name a far future; lastArrivalMs is this side's.
		silent := buf.newestTimestamp() < cutoff || buf.lastArrivalMs < cutoff
		if stale > 0 && !local && silent {
			delete(c.remotes, id)
			// The seat goes with the buffer, as on a Leave, or silent peers fill the capped roster and every later
			// join is refused. It is remembered, so a paused emulator coming back under the same id is re-admitted;
			// the nametag stays, since a reused id arrives with its own Join.
			delete(c.roster, id)
			c.rememberAgedOutLocked(id)
			continue
		}
		var st protocol.State
		var br orientBracket
		var ok bool
		renderTime := netRenderTime
		// Extrapolation is for a peer whose next sample has not arrived; a local peer's future is already held.
		ahead := c.Extrapolate.Milliseconds()
		if local {
			renderTime = localRenderTime
			ahead = 0
		}
		// The dry meter is a network statistic: at the local delay any adapter hitch would read as a bad connection.
		if !local {
			past, moving := buf.dryBy(renderTime)
			c.dry.record(past, moving)
			// Throttled on now, not a render time, or one peer class's store would suppress the other's.
			if past > 0 && c.DryLog != nil && now-c.dryLoggedAt > 1000 {
				c.dryLoggedAt = now
				n := len(buf.snapshots)
				last, before := buf.snapshots[n-1], buf.snapshots[n-2]
				c.DryLog(fmt.Sprintf("core: buffer dry for %s: render time %dms past newest sample seq %d (t=%d); the one before was seq %d (t=%d), %dms earlier; %d samples held; the newest took %dms to arrive",
					id, past, last.Seq, last.Timestamp, before.Seq, before.Timestamp, last.Timestamp-before.Timestamp, n, buf.lastTransitMs))
			}
		}
		if c.adapterWantsOrientBracket {
			st, br, ok = buf.atBracket(renderTime, ahead, c.Curve, c.Predict, &c.extrapolation)
		} else {
			st, ok = buf.atAhead(renderTime, ahead, c.Curve, c.Predict, &c.extrapolation)
		}
		if !ok {
			continue
		}
		// Draw at the sliding offset, advanced to this tick; a knob turned off live drops whatever was still sliding.
		if buf.correction != nil {
			if local || c.Correction <= 0 {
				buf.correction = nil
			} else {
				buf.decayCorrection(now, c.Correction.Milliseconds())
				st = buf.withCorrection(st)
			}
		}
		if !c.adapterRenderAllAreas && c.localAreaID != "" && st.AreaID != c.localAreaID {
			// Counted per render tick: it measures wasted render work, and arrivals are statesReceived.
			atomic.AddUint64(&c.stats.statesFilteredByArea, 1)
			continue
		}
		out[id] = st
		if br.Have {
			brackets[id] = br
		}
	}
	return out, brackets
}

// tickRenders diffs the interpolated remote set against what rendered last tick, calling render for each current
// remote and despawn for each that dropped out; the bridge and in-process paths share it.
func (c *Core) tickRenders(rendered map[string]bool, render func(id string, st protocol.State, br orientBracket), despawn func(id string)) {
	atomic.AddUint64(&c.ticksStarted, 1)
	// nowMs, the clock outgoing stamps use, so remote samples and the render time share a domain.
	current, brackets := c.remoteStatesAt(c.nowMs())

	for id, st := range current {
		render(id, st, brackets[id])
		rendered[id] = true
	}
	for id := range rendered {
		if _, stillKnown := current[id]; !stillKnown {
			despawn(id)
			delete(rendered, id)
			atomic.AddUint64(&c.stats.despawnsSent, 1)
		}
	}
	atomic.AddUint64(&c.stats.rendersSent, uint64(len(current)))
	// Stored: rendered is the caller's, and Stats cannot see it.
	atomic.StoreInt64(&c.renderedNow, int64(len(rendered)))
	atomic.AddUint64(&c.ticks, 1)
}
