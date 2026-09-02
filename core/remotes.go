package core

// Remote peers: what the core knows about them and what it hands the adapter.
//
// Split out of core.go on 2026-08-25.
//
// **area_id is compared for equality and never parsed**, here as everywhere --
// CLAUDE.md's opaque-field rule, which internal/gameblind enforces by walking
// this package's AST. The cross-area filter below is an equality test and a
// despawn, not a judgement about what an area contains.

import (
	"log"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

func (c *Core) storeRemoteState(st protocol.State) {
	if st.PlayerID == "" {
		return
	}
	atomic.AddUint64(&c.stats.statesReceived, 1)
	// Size/length/finiteness caps mirror the relay's own checks, via the
	// shared protocol.ValidateState, applied here
	// too since a hostile or compromised relay was previously trusted
	// completely. See the ADR in agent_docs/architecture.md.
	if !protocol.ValidateState(st) {
		// Throttled like the relay's twin (relay/states.go): a state dropped
		// for size must say so -- the 2026-09-01 sword throw presented as four
		// ghost bugs while both enforcement points stayed silent.
		now := time.Now()
		if last := c.lastStateDropLog.Load(); last == nil || now.Sub(*last) >= 5*time.Second {
			stamp := now
			c.lastStateDropLog.Store(&stamp)
			log.Printf("core: dropping state from %s: %s (repeats suppressed for 5s)", st.PlayerID, protocol.StateRejectReason(st))
		}
		return
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if st.PlayerID == c.playerID {
		// Moved inside the lock — c.playerID is written under c.mu
		// elsewhere (ConnectRelay et al.); reading it unlocked here was a
		// real data race, found in a review pass.
		return
	}
	if _, known := c.roster[st.PlayerID]; !known {
		// A state for a player_id this Core never saw via Welcome/Join is
		// dropped rather than trusted — only the relay stamps player_id
		// server-side, and this Core has no other way to confirm who's
		// actually in the room. See the roster field's doc comment.
		return
	}
	b, ok := c.remotes[st.PlayerID]
	if !ok {
		b = &remoteBuffer{}
		c.remotes[st.PlayerID] = b
	}
	// Set on every sample, not just at creation: InterpolationDelay and
	// Extrapolate are public fields a caller may change while running, and a
	// window derived once would then be wrong for the rest of the session.
	b.historyMs = c.requiredHistoryMsLocked()
	// LOSS COVER (ADR 0045): a state may carry the sample sent before it. If
	// that sample never arrived here, it goes into the buffer first, in its
	// own timestamp order, so the ghost walks through it instead of over the
	// hole. Seen already (the common case on a clean link) it is dropped, so
	// the cover costs a receiver one seq comparison per state. The carrying
	// state is stored WITHOUT it: the buffer holds samples, not packets.
	if st.Prev != nil {
		if prev, ok := protocol.ApplyPrev(&st); ok && !b.hasSeq(prev.Seq) {
			b.add(prev)
			atomic.AddUint64(&c.stats.prevRecovered, 1)
		}
		st.Prev = nil
	}
	b.add(st)
}

// requiredHistoryMsLocked is how far back a remote's buffer must reach for the
// CURRENT render settings to work -- the fix for the two silent edge-hold bugs
// described on maxSnapshots.
//
// Three terms, each earning its place:
//   - THE INTERPOLATION DELAY, because the render time is exactly that far in
//     the past and the buffer must still bracket it. This is the term that was
//     missing: a fixed 600ms window meant any delay above it edge-held at every
//     rate, and at high rates the COUNT cut the window shorter still.
//   - THE PREDICTION WINDOW (Extrapolate), because a render time may run that
//     much PAST the newest sample, and extrapolate still measures velocity over
//     a pair behind it.
//   - maxVelocitySpanMs, the longest baseline extrapolate will measure over,
//     plus historyMarginMs of slack for arrival jitter and for CurveCatmullRom,
//     which needs a sample on either side of the bracket rather than just the
//     bracket itself.
//
// Floored at defaultSnapshotAgeMs so nothing that works today gets a SHORTER
// window than it had -- this must not be able to regress a shipped
// configuration -- and ceilinged so a hostile or fat-fingered setting cannot
// turn the buffer into unbounded memory by another route.
//
// Caller must hold c.mu.
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

func (c *Core) dropRemote(playerID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.remotes, playerID)
}

// dropAllRemotes clears every tracked remote at once — used when the relay
// connection itself is lost, since there's no longer any source for
// updates or an explicit Leave to drive individual despawns.
func (c *Core) dropAllRemotes() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.remotes = make(map[string]*remoteBuffer)
}

// remoteStatesAt returns the interpolated state of every currently known
// remote at renderTime that is also in this Core's own current area --
// cross-area filtering, added 2026-08-13 after a real two-player TEVI test
// showed a remote's ghost rendering at another zone's raw world coordinates,
// invisible only by coincidence (see the ADR in architecture.md). Equality
// comparison only, per contract.md's area_id rule -- never branches on
// contents. If localAreaID is still empty (no real local frame has arrived
// yet), every remote passes through unfiltered rather than hiding
// everything on an unknown local area.
func (c *Core) remoteStatesAt(renderTime int64) (map[string]protocol.State, map[string]orientBracket) {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string]protocol.State, len(c.remotes))
	// The orientation bracket that goes with each state -- see orientBracket.
	// A separate map rather than a field on protocol.State on purpose: State is
	// the WIRE packet, and nothing here travels off this machine.
	//
	// NOT COMPUTED AT ALL unless the adapter asked (bridge.Hello's
	// interpolate_orientation). An adapter with a discrete facing -- four
	// compass directions, a flipped sprite -- cannot use a midpoint between two
	// orientations and would discard every one of these. Left nil so the map
	// is not even allocated for those three adapters.
	var brackets map[string]orientBracket
	if c.adapterWantsOrientBracket {
		brackets = make(map[string]orientBracket, len(c.remotes))
	}
	// AGE OUT A PEER NOBODY IS HEARING FROM. Until 2026-08-28 a remote was
	// dropped only when the relay said it had LEFT, and a buffer that stops
	// being fed keeps answering: remoteBuffer.at returns its newest sample for
	// any render time past it. So a peer that simply went quiet rendered
	// forever, frozen at its last position -- which is what the user saw as
	// "multiple static ghosts", one per core restart, each a relay identity
	// that stopped sending without ever leaving.
	//
	// A Leave is not something to rely on: the relay's dev loopback echo never
	// sends one by construction, a hard-killed client never gets to say
	// goodbye, and udp signals nothing on close at all (status.md). Aging out
	// is the only mechanism covering all three, and it is game-agnostic --
	// "no sample for this long" needs no knowledge of what a sample means.
	stale := c.remoteStaleAfter()
	cutoff := c.nowMsLocked() - stale.Milliseconds()
	for id, buf := range c.remotes {
		if stale > 0 && buf.newestTimestamp() < cutoff {
			// Dropped from the map, not merely skipped: keeping it would hold
			// its snapshots forever and let it spring back to life.
			delete(c.remotes, id)
			atomic.AddUint64(&c.stats.remotesAgedOut, 1)
			continue
		}
		var st protocol.State
		var br orientBracket
		var ok bool
		if c.adapterWantsOrientBracket {
			st, br, ok = buf.atBracket(renderTime, c.Extrapolate.Milliseconds(), c.Curve, c.Predict, &c.extrapolation)
		} else {
			st, ok = buf.atAhead(renderTime, c.Extrapolate.Milliseconds(), c.Curve, c.Predict, &c.extrapolation)
		}
		if !ok {
			continue
		}
		if !c.adapterRenderAllAreas && c.localAreaID != "" && st.AreaID != c.localAreaID {
			// The client side of the relay's cross-area fan-out question:
			// this sample was received, validated, buffered and is now being
			// thrown away. Counted per render tick rather than per arrival on
			// purpose -- it measures wasted RENDER-set work, and the arrival
			// count is already tracked separately as statesReceived.
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

// tickRenders diffs the currently-interpolated remote set against what was
// rendered last tick, calling render for every current remote and despawn
// for every remote that dropped out — shared by both the bridge-wire path
// (onAdapterFrame) and the in-process path (onAdapterFrameInProcess) so the
// tick-model diff logic exists exactly once.
func (c *Core) tickRenders(rendered map[string]bool, render func(id string, st protocol.State, br orientBracket), despawn func(id string)) {
	// The same clock domain outgoing timestamps are stamped in (nowMs), which
	// is the whole point: remote samples carry the sender's idea of the time,
	// and comparing them against a render time measured on a different clock
	// is what makes interpolation degrade silently under skew. With clock
	// sync off — every room today — this is exactly the previous
	// time.Now().Add(-delay).
	renderTime := c.nowMs() - c.InterpolationDelay.Milliseconds()
	current, brackets := c.remoteStatesAt(renderTime)

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
	// Stored rather than derived, because `rendered` is owned by the caller
	// and Stats has no access to it.
	atomic.StoreInt64(&c.renderedNow, int64(len(rendered)))
}
