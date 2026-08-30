package core

import (
	"bytes"
	"encoding/json"
	"math"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// History is bounded by TIME first and count second. It was a bare count of 8
// until 2026-08-28, and a count starves a large interpolation delay at a high
// send rate: at the dev rig's 100Hz, 8 samples span ~80ms, so a 250ms render
// time fell off the buffer's old edge during sustained movement and edge-held
// -- seen on screen as stutter on long walks, while a jump from standing still
// looked correctly delayed because change suppression had spread the idle
// samples out. The "250ms" runs were silently something else. At the shipped
// 20Hz the old count covered 350ms and never bit, which is why nothing noticed.
//
// **That comment described the INTENT and the code did not deliver it, fixed
// 2026-08-30.** The count stayed a functional bound in disguise: 64 samples span
// 64/Hz seconds, so above ~107Hz it cut into the time window the age bound was
// supposed to own, and the 2026-08-28 bug simply came back at a higher rate.
// Measured before the fix (core/hzceiling_test.go): at the shipped 250ms delay
// a room interpolated correctly to 200Hz and edge-held at 256Hz, and a LARGER
// delay broke EARLIER -- 400ms edge-held at 200Hz. Silent every time: no error,
// just a ghost that stutters. agent_docs/hz-ceiling.md has the full table.
//
// A SECOND, RATE-INDEPENDENT BUG hid behind the same constant: a fixed 600ms
// age bound means any interpolation delay above 600ms edge-holds at EVERY rate,
// including the shipped 20Hz. Nobody has configured one that large, which is
// the only reason it never showed.
//
// So the two bounds are now what they always claimed to be:
//
//   - THE WINDOW IS FUNCTIONAL AND DERIVED. remoteBuffer.historyMs is set from
//     the Core's own render settings (see Core.requiredHistoryMs), so the
//     buffer keeps exactly as much history as the configured delay and
//     prediction actually need. Zero means "unset", which uses
//     defaultSnapshotAgeMs -- the old value, so a bare remoteBuffer (every test
//     that predates this) behaves exactly as before.
//   - THE COUNT IS A MEMORY BOUND AND NOTHING ELSE. It exists so an
//     adversarially fast sender cannot grow a buffer without limit, and is set
//     high enough that it cannot reach into the window at any rate anyone will
//     ever configure: 1024 samples cover the default 600ms window up to
//     ~1700Hz, against a MaxSendHz of 100. Cost is ~40 bytes a snapshot, so the
//     worst case is tens of KB per peer and only under abuse.
//
// **Do not put a functional decision back into the count.** If a window needs
// to grow, grow the window.
const maxSnapshots = 1024
const defaultSnapshotAgeMs = 600

// historyMarginMs is slack on top of the terms requiredHistoryMsLocked adds up:
// arrival jitter, and CurveCatmullRom needing a sample either side of the
// bracket rather than only the bracket.
const historyMarginMs = 100

// maxHistoryMs bounds the derived window itself, so a hostile or mistyped
// interpolation delay cannot turn the buffer into unbounded memory through the
// one bound that is allowed to grow. 4s is far past any usable delay -- a ghost
// rendered four seconds late is not a setting, it is a bug report.
const maxHistoryMs = 4000

// remoteBuffer holds a short history of a remote player's snapshots,
// ordered oldest to newest by protocol.State.Timestamp, used to compute an
// interpolated render-time state between real network updates. See the
// tick model in agent_docs/contract.md.
type remoteBuffer struct {
	snapshots []protocol.State

	// historyMs is how far back this buffer must reach, in milliseconds --
	// the FUNCTIONAL bound, derived from the Core's render settings rather
	// than fixed, so a large interpolation delay or a long prediction window
	// keeps the history it needs instead of silently edge-holding. Set by
	// storeRemoteState on every sample so a settings change takes effect
	// without rebuilding the buffer. Zero means unset and uses
	// defaultSnapshotAgeMs, which is what every test constructing a bare
	// remoteBuffer relies on.
	historyMs int64
}

// add inserts a snapshot IN TIMESTAMP ORDER, which is not the order they
// necessarily arrive in.
//
// This used to append blindly and say in its own comment that callers were
// expected to deliver samples in non-decreasing order. That assumption was
// false the whole time and localhost hid it: the state plane travels on
// UNRELIABLE DATAGRAMS by design (contract.md -- lossy, latest-wins), and
// datagrams reorder. Out of order, the buffer's ordering invariant breaks and
// at() brackets a render time with the wrong pair, so a ghost jumps back to
// where it was and then forward again.
//
// Found 2026-08-28 the first time this project ever ran a session through
// meshghost-netsim with real jitter, loss and reordering: the user's read was
// "looks really delayed, and kinda snap/teleport around a bit". The delay was
// the interpolation delay doing its job; the snapping was this.
//
// A sample older than everything held is DROPPED rather than inserted: the
// buffer is a short window near the render time, and a straggler that arrives
// after the window has moved past it can only pull a ghost backwards.
func (b *remoteBuffer) add(s protocol.State) {
	n := len(b.snapshots)
	if n == 0 || s.Timestamp >= b.snapshots[n-1].Timestamp {
		b.snapshots = append(b.snapshots, s)
	} else if s.Timestamp < b.snapshots[0].Timestamp && n >= maxSnapshots {
		return // older than the whole window, and the window is full
	} else {
		i := n
		for i > 0 && b.snapshots[i-1].Timestamp > s.Timestamp {
			i--
		}
		b.snapshots = append(b.snapshots, protocol.State{})
		copy(b.snapshots[i+1:], b.snapshots[i:])
		b.snapshots[i] = s
	}
	if len(b.snapshots) > maxSnapshots {
		b.snapshots = b.snapshots[len(b.snapshots)-maxSnapshots:]
	}
	// Age out the old edge against the NEWEST sample's clock, keeping at least
	// two so interpolation always has a pair to work with. The window is the
	// derived one (see historyMs) -- this is the bound that decides what the
	// renderer can still interpolate, and the count above is only memory.
	window := b.historyMs
	if window <= 0 {
		window = defaultSnapshotAgeMs
	}
	cutoff := b.snapshots[len(b.snapshots)-1].Timestamp - window
	drop := 0
	for drop < len(b.snapshots)-2 && b.snapshots[drop].Timestamp < cutoff {
		drop++
	}
	if drop > 0 {
		b.snapshots = b.snapshots[drop:]
	}
}

// at returns the interpolated state for renderTime (same units as
// protocol.State.Timestamp: milliseconds). Position is linearly
// interpolated component-wise between the two snapshots bracketing
// renderTime. area_id, anim, orientation, and extras are opaque per
// agent_docs/contract.md and are never interpolated — they're taken from
// the older of the two bracketing snapshots, holding their value until the
// next real sample passes renderTime. If renderTime falls outside the
// buffered range, the nearest edge snapshot is returned unchanged -- unless
// extrapolateAhead is positive, which is the opt-in prediction described on
// extrapolate below. ok is false only if no snapshots have been added yet.
// newestTimestamp is when this remote last said anything, or 0 if it never
// has. Used to age out a peer that stopped sending without leaving -- see
// remoteStatesAt.
func (b *remoteBuffer) newestTimestamp() int64 {
	if len(b.snapshots) == 0 {
		return 0
	}
	return b.snapshots[len(b.snapshots)-1].Timestamp
}

// at is the no-prediction form: hold the newest sample once the render time
// passes it. Kept as its own entry point because that is the shipped default
// and most callers (and every test that predates prediction) mean exactly it.
func (b *remoteBuffer) at(renderTime int64) (protocol.State, bool) {
	return b.atAhead(renderTime, 0, CurveLinear, PredictLinear, nil)
}

// orientBracket is the ROTATION half of the render model, and the core's only
// possible contribution to it: the pair of opaque orientation blobs that
// position was interpolated BETWEEN, plus how far between them the render time
// fell. The core still never parses either blob -- it carries them exactly as
// it carries a single one today (contract.md, "orientation ... opaque to the
// core") -- so this adds a passthrough, not an interpretation.
//
// WHY THE CORE CANNOT JUST SMOOTH IT. Orientation is a json.RawMessage whose
// shape is the adapter's business: a compass string for Emerald, a Euler
// triple for Pseudoregalia, a quaternion for whatever ships next. There is no
// midpoint the core can compute without deciding which of those it is, and
// deciding is exactly the game knowledge it is forbidden to hold. So the
// core hands over the two endpoints and the fraction, and the adapter -- which
// does know what its own orientation means -- does the interpolation.
//
// WHY BOTH ENDPOINTS AND NOT JUST THE NEWER ONE. From/To is a self-contained
// instruction, and it stays correct in the one case where the rendered
// State.Orientation is NOT the From end: extrapolation, which returns the
// NEWEST sample's fields and predicts past them, so the arc to continue runs
// from the second-newest to the newest with T above 1. An adapter that read
// State.Orientation as its From would swing the wrong way there.
//
// WHY IT MUST BE THE SAME BRACKET POSITION USED. A rotation chasing the newest
// sample (a damper) is far simpler and is wrong for a reason that only shows up
// while moving fast: position renders an interpolation delay in the past, so a
// damped facing would put the body where the peer was and the head where they
// are now, and the two visibly disagree during exactly the motion that made
// anyone look. Same bracket, same fraction, one clock. agent_docs/scaling.md.
//
// Have is false whenever there is no honest pair -- a single sample, a render
// time outside the buffer with prediction off, or one of the discontinuities
// lerp already refuses to cross (an area change, a position-length change).
// The adapter then holds State.Orientation, which is today's behaviour exactly.
type orientBracket struct {
	From json.RawMessage
	To   json.RawMessage
	T    float64
	Have bool
}

// bracketBetween builds the orientation bracket for a pair of snapshots,
// applying the SAME discontinuity guards lerp does -- so rotation is never
// interpolated across a seam position refused to interpolate across. Returns
// a zero (Have false) bracket when they do not hold, which is the adapter's
// signal to hold the orientation it was given.
func bracketBetween(older, newer protocol.State, renderTime int64) orientBracket {
	span := newer.Timestamp - older.Timestamp
	if span <= 0 || older.AreaID != newer.AreaID || len(older.Position) != len(newer.Position) {
		return orientBracket{}
	}
	if len(older.Orientation) == 0 || len(newer.Orientation) == 0 {
		return orientBracket{}
	}
	// NOTHING ROTATED -- no bracket, and this is a real saving rather than a
	// micro-optimisation. Interpolating a value toward itself returns that
	// value at every fraction, so the adapter's fallback (use State.Orientation
	// unchanged) renders the IDENTICAL result: this cannot change a pixel, and
	// TestNoBracketWhenNothingRotatedIsVisuallyIdentical is that argument kept
	// as a test.
	//
	// What it buys: a standing player, a player walking in a straight line, and
	// every peer of a discrete-facing adapter that opted in anyway, all stop
	// paying two extra blobs per frame. Change suppression (ADR 0039) already
	// made the common case a repeat; this keeps the bracket from re-inflating
	// it on the bridge.
	//
	// A BYTE COMPARE, deliberately, not a parse. The core may not read an
	// orientation, so "did it change" is the only question it is allowed to
	// ask -- the same equality-only treatment area_id and anim get. Two
	// encodings of the same rotation compare unequal and simply produce a
	// bracket that interpolates between identical values, which is correct if
	// slightly wasteful, and is the safe direction to be wrong in.
	if bytes.Equal(older.Orientation, newer.Orientation) {
		return orientBracket{}
	}
	return orientBracket{
		From: older.Orientation,
		To:   newer.Orientation,
		T:    float64(renderTime-older.Timestamp) / float64(span),
		Have: true,
	}
}

// atBracket is atAhead plus the orientation bracket that goes with the state
// it returns. atAhead is the same call with the bracket dropped, kept as its
// own entry point because the in-process adapter path and every test that
// predates rotation interpolation mean exactly it.
func (b *remoteBuffer) atBracket(renderTime int64, extrapolateAhead int64, curve CurveMode, predict PredictMode, meter *extrapolationMeter) (protocol.State, orientBracket, bool) {
	st, ok := b.atAhead(renderTime, extrapolateAhead, curve, predict, meter)
	if !ok {
		return st, orientBracket{}, false
	}
	n := len(b.snapshots)
	if n < 2 || renderTime <= b.snapshots[0].Timestamp {
		return st, orientBracket{}, true
	}
	last := b.snapshots[n-1]
	if renderTime >= last.Timestamp {
		// Past the newest sample. With prediction off the state IS that
		// sample and holding its orientation is the honest answer, so no
		// bracket. With prediction on, continue the last measured arc for
		// the same window position is predicted over, capped the same way --
		// otherwise the body predicts while the head lags, during precisely
		// the motion extrapolation exists for (scaling.md).
		if extrapolateAhead <= 0 {
			return st, orientBracket{}, true
		}
		older := b.snapshots[n-2]
		dt := renderTime - last.Timestamp
		if dt > extrapolateAhead {
			dt = extrapolateAhead
		}
		br := bracketBetween(older, last, last.Timestamp+dt)
		// A pair too far apart says nothing about the rate NOW, the same
		// judgement extrapolate makes about position for the same reason:
		// an idle peer's keepalive-spaced samples must not become a spin.
		if last.Timestamp-older.Timestamp > maxVelocitySpanMs {
			return st, orientBracket{}, true
		}
		return st, br, true
	}
	for i := 0; i < n-1; i++ {
		older, newer := b.snapshots[i], b.snapshots[i+1]
		if renderTime >= older.Timestamp && renderTime <= newer.Timestamp {
			// CurveCatmullRom deliberately gets the straight two-sample arc:
			// the four-sample rotation equivalent is squad, and building it
			// for a field nothing interpolated at all until now would be two
			// speculative steps at once (scaling.md). Pair squad with
			// catmull-rom if that day comes.
			return st, bracketBetween(older, newer, renderTime), true
		}
	}
	return st, orientBracket{}, true
}

// atAhead is at with the opt-in prediction window described on extrapolate.
func (b *remoteBuffer) atAhead(renderTime int64, extrapolateAhead int64, curve CurveMode, predict PredictMode, meter *extrapolationMeter) (protocol.State, bool) {
	n := len(b.snapshots)
	if n == 0 {
		return protocol.State{}, false
	}
	if n == 1 || renderTime <= b.snapshots[0].Timestamp {
		return b.snapshots[0], true
	}
	last := b.snapshots[n-1]
	if renderTime >= last.Timestamp {
		return b.extrapolate(last, renderTime, extrapolateAhead, predict, meter), true
	}
	for i := 0; i < n-1; i++ {
		older, newer := b.snapshots[i], b.snapshots[i+1]
		if renderTime >= older.Timestamp && renderTime <= newer.Timestamp {
			if curve == CurveCatmullRom {
				return b.curved(i, renderTime), true
			}
			return lerp(older, newer, renderTime), true
		}
	}
	// Unreachable: the two bound checks above cover every renderTime
	// outside [snapshots[0], snapshots[n-1]], and the loop covers every
	// value inside it.
	return last, true
}

// lerp linearly interpolates position between older and newer at
// renderTime. Non-position fields come from older. Falls back to older
// unchanged if the snapshots have mismatched position lengths (an
// adapter-side contract violation, not something to guess through), a
// non-positive time span (duplicate timestamps), or a different AreaID —
// found in a review pass: without this, a remote crossing a zone boundary
// gets its two bracketing snapshots' raw world coordinates blended
// together (stamped with older's AreaID), rendering at a meaningless
// midpoint between two zones' unrelated coordinate spaces. This is exactly
// the phantom-ghost failure the 2026-08-13 cross-area filtering ADR
// (agent_docs/architecture.md) exists to prevent — that filter only
// guards against a *stale* remote's area, not an in-flight interpolation
// spanning two different areas.
func lerp(older, newer protocol.State, renderTime int64) protocol.State {
	span := newer.Timestamp - older.Timestamp
	if span <= 0 || len(older.Position) != len(newer.Position) || older.AreaID != newer.AreaID {
		return older
	}

	t := float64(renderTime-older.Timestamp) / float64(span)
	pos := make([]float64, len(older.Position))
	for i := range pos {
		pos[i] = older.Position[i] + (newer.Position[i]-older.Position[i])*t
	}

	out := older
	out.Position = pos
	out.Timestamp = renderTime
	return out
}

// minVelocitySpanMs is the shortest sample gap a velocity may be measured
// over. Two samples a millisecond apart carry no usable rate -- a few pixels
// across 1ms extrapolates to a character crossing the screen -- and the send
// path deliberately produces exactly such a pair: the bracket re-statement
// that makes change suppression invisible sits 1ms before the state that
// follows it (see forwardLocalState). Refusing to measure over it is what
// stops a resume from launching a ghost.
const minVelocitySpanMs = 8

// maxVelocitySpanMs is the longest gap a velocity may be measured over. Past
// it the pair says nothing about what the peer is doing NOW: a sample from
// half a second ago and the newest one average a stand and a walk into a
// creep, which is invented motion at a speed the game never used
// (adapters/CLAUDE.md). It also falls out of change suppression -- an idle
// player's samples sit a keepalive apart (250ms), and those must never be read
// as a rate. Holding is the honest answer when nothing recent can be measured.
const maxVelocitySpanMs = 200

// minPredictConfidence is how much prediction a completely unpredictable axis
// still gets under PredictDamped. Not zero -- see the floor's own comment.
const minPredictConfidence = 0.4

// extrapolate is the OPT-IN half of the render model, off unless a Core sets
// Extrapolate (`-extrapolate`, default 0/off). Instead of holding the newest
// sample when the render time has run past it, it continues the peer's last
// measured velocity for up to extrapolateAhead milliseconds.
//
// What it buys: a ghost drawn where the peer probably IS rather than where
// they were, which is the visible half of the interpolation delay. What it
// costs: every prediction the peer does not follow -- a stop, a turn, a
// landing -- has to be taken back, and that correction is the thing to judge
// on screen rather than in a test. It is off by default for that reason, and
// per adapters/CLAUDE.md the games that move on a fixed beat (2px per tick and
// never 1) are the ones where a smooth prediction is a defect rather than an
// improvement.
//
// Deliberately conservative in three ways, each of which is a way a naive
// version misbehaves:
//   - It measures velocity only over a pair between minVelocitySpanMs and
//     maxVelocitySpanMs apart, so neither a resume's 1ms bracket pair nor a
//     half-second-old sample can be read as a rate.
//   - It refuses to predict across an area change or a position-length change,
//     the same two guards lerp already applies for the same reason.
//   - It caps how far ahead it will go, so a peer who went quiet freezes where
//     they were last seen rather than walking off forever.
func (b *remoteBuffer) extrapolate(last protocol.State, renderTime int64, ahead int64, predict PredictMode, m *extrapolationMeter) protocol.State {
	if ahead <= 0 {
		return last
	}
	dt := renderTime - last.Timestamp
	if dt <= 0 {
		return last
	}
	capped := false
	if dt > ahead {
		dt = ahead
		capped = true
	}
	// The LONGEST usable baseline in the window, not the shortest -- so walk
	// forward from the oldest sample and take the first one close enough to
	// measure against. Sample arrival times wobble by tens of milliseconds on a
	// real link, and a velocity measured across two adjacent samples inherits
	// that wobble in full, which shows up as a ghost that shimmers while its
	// peer moves steadily. A longer baseline averages the same wobble down.
	// Bounded on both sides for the reasons on the two constants.
	for i := 0; i <= len(b.snapshots)-2; i++ {
		older := b.snapshots[i]
		span := last.Timestamp - older.Timestamp
		if span > maxVelocitySpanMs {
			continue
		}
		if span < minVelocitySpanMs {
			break
		}
		if older.AreaID != last.AreaID || len(older.Position) != len(last.Position) {
			return last
		}
		pos := make([]float64, len(last.Position))
		// ACCELERATION, not just velocity, whenever there is a third sample to
		// measure it with. A jump is an accelerating body: predicting it along a
		// straight line lags on the way up and carries the ghost through the
		// floor on the way down, which is exactly what the user reported on
		// 2026-08-28 ("feels a bit slow when jumping", "still sinks into the
		// floor a bit"). Fitting the curvature costs one more subtraction per
		// axis and no extra bytes on the wire -- the samples are already here.
		//
		// The middle sample is the one halfway between in TIME, not in index, so
		// an uneven arrival pattern does not tilt the estimate.
		mid, hasMid := b.midSample(i, len(b.snapshots)-1)
		if predict == PredictLinear {
			hasMid = false
		}
		for j := range pos {
			v := (last.Position[j] - older.Position[j]) / float64(span)
			p := last.Position[j] + v*float64(dt)
			if hasMid && len(mid.Position) == len(last.Position) && mid.AreaID == last.AreaID {
				t1 := float64(mid.Timestamp - older.Timestamp)
				t2 := float64(last.Timestamp - mid.Timestamp)
				if t1 > 0 && t2 > 0 {
					v1 := (mid.Position[j] - older.Position[j]) / t1
					v2 := (last.Position[j] - mid.Position[j]) / t2
					if predict == PredictDamped {
						// PREDICT ONLY WHAT LOOKS PREDICTABLE, per axis.
						//
						// Confidence is how much the two halves of the window
						// AGREE about the velocity: steady running gives v1 ~ v2
						// and full prediction; a jump's vertical axis changes
						// every frame under gravity and gets little; at the apex
						// the velocity reverses outright, v2 ~ -v1, and it gets
						// none at all -- which is precisely the instant a
						// straight-line guess would fling a ghost the wrong way.
						//
						// This is what the user saw as a "constant snap/drag"
						// going up and down while left/right looked fine
						// (2026-08-28): the horizontal axis was predictable and
						// the vertical one never was, and a single prediction
						// applied to both cannot tell them apart.
						//
						// Nothing here knows which axis is which, or that
						// gravity exists -- it is a statement about the samples,
						// not about the game (CLAUDE.md's game-blindness rule).
						spread := math.Abs(v2 - v1)
						scale := math.Abs(v1) + math.Abs(v2)
						confidence := 1.0
						if scale > 0 {
							confidence = 1 - spread/scale
						}
						// FLOORED, not free to reach zero. Refusing outright is
						// right in principle and wrong on screen: rapidly
						// tapping left and right reverses the horizontal axis
						// constantly, confidence collapses, and the ghost falls
						// back to pure lateness -- which the user read as
						// "spam left/right looks slow/delayed" (2026-08-28)
						// while long runs looked fine.
						//
						// A floor keeps some prediction under a peer who is
						// changing their mind, which is better than none: the
						// error it can introduce is bounded by the same cap
						// everything else is, and being a little wrong for
						// 30ms beats being reliably a whole interp delay late.
						if confidence < minPredictConfidence {
							confidence = minPredictConfidence
						}
						// NOT smoothed across frames. That was tried
						// (2026-08-28) to stop the amount of prediction
						// wobbling, and an A/B with everything else held equal
						// made every axis WORSE -- steady walking turned
						// choppy, jumps read as low-framerate -- because a
						// lagging confidence applies yesterday's damping to
						// today's motion. The wobble it was meant to fix
						// turned out to be an interp-below-jitter artifact,
						// cured by keeping the delay above the link's jitter,
						// not by filtering here.
						// VELOCITY ONLY, and that is a measured conclusion,
						// not a first draft. Acceleration was added here twice
						// on 2026-08-28 -- raw (PredictAccelerated) and then
						// gated by its own cross-window consistency -- and
						// BOTH failed the same way on screen: chop on jumps,
						// and the gated version added a snap at the end of a
						// steady run, because the second derivative's
						// contribution fluctuates frame to frame under jitter
						// however it is gated, and a prediction whose SIZE
						// wobbles is visible even when its direction is right.
						// Two variants failing identically is the stop signal
						// (CLAUDE.md); the jump's residual lag is paid for
						// with steadiness everywhere else.
						p = last.Position[j] + v2*float64(dt)*confidence
						pos[j] = p
						continue
					}
					a := (v2 - v1) / ((t1 + t2) / 2)
					// A velocity measured ACROSS a span is the velocity at the
					// MIDDLE of that span, not at its end -- so v2 has to be
					// carried forward by half of t2 to give the rate in force at
					// the newest sample. Without that half-step the prediction
					// is systematically behind on anything accelerating: a body
					// falling to y=20 was predicted at y=30, and the test that
					// says so is the reason this line exists.
					vNow := v2 + a*(t2/2)
					p = last.Position[j] + vNow*float64(dt) + 0.5*a*float64(dt)*float64(dt)
				}
			}
			pos[j] = p
		}
		out := last
		out.Position = pos
		out.Timestamp = renderTime
		m.record(dt, capped)
		return out
	}
	// Nothing to measure against: one sample, or every pair too close
	// together to carry a rate. Holding is the honest answer.
	return last
}

// extrapolationMeter answers "is the prediction doing anything, and how much"
// with numbers rather than opinion. The question came up the moment the knob
// existed (user, 2026-08-28: "does higher/lower extrapolate do anything?") and
// it cannot be answered from the setting: the cap is an upper bound, while what
// is actually predicted is however far the render time has run past the newest
// sample -- about one send interval on a quiet localhost rig, and far more
// under jitter or loss, which is the case the knob exists for.
//
// Cheap on purpose: three integers updated on a path that is already building a
// position. Read through Core.Stats.
type extrapolationMeter struct {
	count     uint64
	cappedHit uint64
	totalMs   uint64
	maxMs     int64
}

func (m *extrapolationMeter) record(dt int64, capped bool) {
	if m == nil {
		return
	}
	m.count++
	m.totalMs += uint64(dt)
	if dt > m.maxMs {
		m.maxMs = dt
	}
	if capped {
		m.cappedHit++
	}
}

// CurveMode picks how a position between two samples is computed. It is a
// per-client setting rather than a per-game one, because the core is not
// allowed to know what game it is serving (CLAUDE.md) -- what makes it a
// per-game DECISION is that a player, an adapter or a launcher chooses it.
type CurveMode string

const (
	// CurveLinear is the shipped default and the only mode used before
	// 2026-08-28: a straight line between the two bracketing samples.
	CurveLinear CurveMode = "linear"

	// CurveCatmullRom fits a curve through four consecutive samples instead,
	// so an arcing path renders as an arc rather than as a series of chords.
	//
	// NOT a free improvement, and off by default for the same reason
	// extrapolation is: a curve is SMOOTHER THAN THE SAMPLES IMPLY. For a game
	// that moves on a fixed beat -- 2px per tick and never 1 -- that is a
	// defect this project already has a case file on (adapters/CLAUDE.md,
	// "never in units the game does not use"), while for a game with real
	// momentum it may well be closer to the truth. It is a per-game judgement
	// to be made on screen.
	//
	// Uniform parameterisation, and it can overshoot slightly on a sharp
	// direction change -- the classic Catmull-Rom trade. Anything that must
	// never overshoot wants the centripetal variant, which is more arithmetic
	// than this is currently worth.
	CurveCatmullRom CurveMode = "catmull-rom"
)

// curved renders between snapshots[i] and snapshots[i+1] using the samples on
// either side as tangents. Falls back to lerp whenever the four samples are
// not all usable -- fewer than four in the buffer, an area change anywhere
// among them, or mismatched position lengths -- so the curve is never fitted
// across a discontinuity the straight line already refuses to cross.
func (b *remoteBuffer) curved(i int, renderTime int64) protocol.State {
	p1, p2 := b.snapshots[i], b.snapshots[i+1]
	if i-1 < 0 || i+2 >= len(b.snapshots) {
		return lerp(p1, p2, renderTime)
	}
	p0, p3 := b.snapshots[i-1], b.snapshots[i+2]
	span := p2.Timestamp - p1.Timestamp
	if span <= 0 {
		return lerp(p1, p2, renderTime)
	}
	d := len(p1.Position)
	for _, s := range []protocol.State{p0, p2, p3} {
		if len(s.Position) != d || s.AreaID != p1.AreaID {
			return lerp(p1, p2, renderTime)
		}
	}

	t := float64(renderTime-p1.Timestamp) / float64(span)
	pos := make([]float64, d)
	for j := range pos {
		pos[j] = catmullRom(p0.Position[j], p1.Position[j], p2.Position[j], p3.Position[j], t)
	}
	out := p1
	out.Position = pos
	out.Timestamp = renderTime
	return out
}

// catmullRom is the standard uniform spline at t in [0,1] between p1 and p2.
// Collinear points give back the straight line exactly, which is what makes
// this safe to enable on motion that happens to be straight.
func catmullRom(p0, p1, p2, p3, t float64) float64 {
	t2 := t * t
	t3 := t2 * t
	return 0.5 * ((2 * p1) +
		(-p0+p2)*t +
		(2*p0-5*p1+4*p2-p3)*t2 +
		(-p0+3*p1-3*p2+p3)*t3)
}

// midSample returns the snapshot closest to halfway in TIME between the two
// given indices, which is what makes an acceleration estimate honest when
// samples arrive unevenly -- the middle by index can sit anywhere.
func (b *remoteBuffer) midSample(lo, hi int) (protocol.State, bool) {
	if hi-lo < 2 {
		return protocol.State{}, false
	}
	target := (b.snapshots[lo].Timestamp + b.snapshots[hi].Timestamp) / 2
	best := -1
	var bestDist int64
	for i := lo + 1; i < hi; i++ {
		d := b.snapshots[i].Timestamp - target
		if d < 0 {
			d = -d
		}
		if best < 0 || d < bestDist {
			best, bestDist = i, d
		}
	}
	if best < 0 {
		return protocol.State{}, false
	}
	return b.snapshots[best], true
}

// PredictMode picks HOW a ghost is carried past its newest sample, when
// prediction is on at all (Core.Extrapolate).
type PredictMode string

const (
	// PredictLinear continues the last measured velocity. Steady, and wrong in
	// one specific way: an accelerating body -- a jump -- lags on the way up and
	// is carried through the floor on the way down, because a straight line
	// cannot describe an arc.
	PredictLinear PredictMode = "linear"

	// PredictAccelerated fits the curvature too, from three samples. It models a
	// jump properly and costs nothing on the wire, but an acceleration estimated
	// from network samples is a SECOND derivative of jittery data, which
	// amplifies that jitter -- so it can read as snappy exactly where it was
	// supposed to help. Which of the two wins is a per-game, on-screen question
	// and that is why both exist.
	PredictAccelerated PredictMode = "accelerated"

	// PredictDamped is linear prediction scaled per axis by how consistent the
	// recent velocity has been. An axis moving steadily is predicted in full; one
	// whose velocity is changing -- or reversing, as at the top of a jump -- is
	// predicted barely or not at all, because there is nothing trustworthy to
	// extend. It is the middle ground between the two above: it keeps what linear
	// prediction is good at without pretending to know where an accelerating body
	// is going.
	PredictDamped PredictMode = "damped"
)
