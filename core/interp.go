package core

import (
	"bytes"
	"encoding/json"
	"math"
	"sort"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// History is bounded by time first: the window (remoteBuffer.historyMs) is derived from the render settings, so a
// large delay or prediction window keeps what it needs. maxSnapshots is a memory bound against a fast sender and
// nothing else; if a window needs to grow, grow the window, never the count, or a large delay silently edge-holds.
const maxSnapshots = 1024
const defaultSnapshotAgeMs = 600

// historyMarginMs is slack on top of requiredHistoryMsLocked's terms: arrival jitter, and CurveCatmullRom needing a
// sample either side of the bracket.
const historyMarginMs = 100

// maxHistoryMs bounds the derived window, so a hostile or mistyped delay cannot turn it into unbounded memory.
const maxHistoryMs = 4000

// remoteBuffer holds a remote player's recent snapshots, oldest to newest by Timestamp, for the render-time state
// between network updates.
type remoteBuffer struct {
	snapshots []protocol.State
	// lastTransitMs is how long the newest sample took to arrive (dev diagnostics, printed by the dry log).
	lastTransitMs int64

	// lastArrivalMs is when a sample last arrived on the receiver's clock. The age-out also requires it, because
	// the sender chooses the timestamp: one far in the future would otherwise keep a silent peer forever.
	lastArrivalMs int64

	// historyMs is how far back this buffer must reach, derived from the Core's render settings and set on every
	// sample so a settings change applies at once. Zero means defaultSnapshotAgeMs.
	historyMs int64

	// correction is the decaying offset between where this ghost is drawn and where the buffer puts it, nil while
	// Core.Correction is 0 (correction.go). topSpeed, in position units per millisecond, tells a wrong guess from a
	// warp.
	correction   []float64
	correctionAt int64
	topSpeed     float64
}

// add inserts a snapshot in timestamp order, not arrival order: the state plane is unreliable datagrams, which
// reorder. A sample older than everything held, in a full buffer, is dropped: it could only pull a ghost backwards.
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
	// Age out against the newest sample's clock, keeping at least two so interpolation always has a pair.
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
	b.noteSpeed()
}

// hasSample reports whether the sample with this seq and timestamp is already held, so the loss cover inserts a
// carried previous sample only when its own packet never arrived. A previous sample keeps its own timestamp, so
// only the run sharing ts is compared: this runs under c.mu for every state on a lossy link.
func (b *remoteBuffer) hasSample(seq uint64, ts int64) bool {
	i := sort.Search(len(b.snapshots), func(i int) bool {
		return b.snapshots[i].Timestamp >= ts
	})
	for ; i < len(b.snapshots) && b.snapshots[i].Timestamp == ts; i++ {
		if b.snapshots[i].Seq == seq {
			return true
		}
	}
	return false
}

// newestTimestamp is when this remote last said anything, or 0 if it never has.
func (b *remoteBuffer) newestTimestamp() int64 {
	if len(b.snapshots) == 0 {
		return 0
	}
	return b.snapshots[len(b.snapshots)-1].Timestamp
}

// at returns the state for renderTime in milliseconds, holding the newest sample once the render time passes it, the
// shipped default. Opaque fields are never interpolated: they come from the older bracketing sample. ok is false only
// with no snapshots.
func (b *remoteBuffer) at(renderTime int64) (protocol.State, bool) {
	return b.atAhead(renderTime, 0, CurveLinear, PredictLinear, nil)
}

// orientBracket is the rotation half of the render model: the two opaque orientation blobs position was interpolated
// between, and how far between them the render time fell. The core cannot interpolate orientation without knowing
// its shape, which is game knowledge, so the adapter does. Both endpoints, since under extrapolation the state's own
// orientation is the To end, with T above 1. It is the bracket position used, so body and facing share one clock.
// Have is false when there is no honest pair, and the adapter holds State.Orientation.
type orientBracket struct {
	From json.RawMessage
	To   json.RawMessage
	T    float64
	Have bool
}

// bracketBetween builds the orientation bracket for a pair of snapshots with lerp's own discontinuity guards, so
// rotation never crosses a seam position refused to cross.
func bracketBetween(older, newer protocol.State, renderTime int64) orientBracket {
	span := newer.Timestamp - older.Timestamp
	if span <= 0 || older.AreaID != newer.AreaID || len(older.Position) != len(newer.Position) {
		return orientBracket{}
	}
	if len(older.Orientation) == 0 || len(newer.Orientation) == 0 {
		return orientBracket{}
	}
	// Nothing rotated, so no bracket: holding renders the identical result and saves two blobs a frame. A byte
	// compare, since the core may only ask equality of an opaque field.
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

// atBracket is atAhead plus the orientation bracket that goes with the state it returns.
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
		// Past the newest sample: with prediction off the state is that sample, so no bracket. With it on, continue
		// the arc over the same pair and window position uses, or the body predicts while the head lags.
		if extrapolateAhead <= 0 {
			return st, orientBracket{}, true
		}
		i, ok := b.velocityBaselineIndex()
		if !ok {
			return st, orientBracket{}, true
		}
		older := b.snapshots[i]
		dt := renderTime - last.Timestamp
		if dt > extrapolateAhead {
			dt = extrapolateAhead
		}
		return st, bracketBetween(older, last, last.Timestamp+dt), true
	}
	for i := 0; i < n-1; i++ {
		older, newer := b.snapshots[i], b.snapshots[i+1]
		if renderTime >= older.Timestamp && renderTime <= newer.Timestamp {
			// CurveCatmullRom also gets the two-sample arc; its rotation equivalent (squad) is not built.
			return st, bracketBetween(older, newer, renderTime), true
		}
	}
	return st, orientBracket{}, true
}

// atAhead is at with the opt-in prediction window described on extrapolate, and a choice of curve.
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
	// Unreachable: the bound checks and the loop cover every renderTime.
	return last, true
}

// lerp linearly interpolates position between older and newer at renderTime; other fields come from older. It
// returns older unchanged across mismatched position lengths, a non-positive span, or an area change, where blending
// two areas' unrelated coordinates would draw a ghost at a meaningless midpoint.
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

// minVelocitySpanMs is the shortest sample gap a velocity may be measured over: change suppression's bracket
// re-statement sits 1ms before the next state, and a rate over 1ms would launch a resuming ghost across the screen.
const minVelocitySpanMs = 8

// maxVelocitySpanMs is the longest gap a velocity may be measured over: an older pair averages a stand and a walk
// into a creep the game never moved at, and an idle player's samples sit a keepalive apart.
const maxVelocitySpanMs = 200

// minPredictConfidence is how much prediction a completely unpredictable axis still gets under PredictDamped.
const minPredictConfidence = 0.4

// velocityBaselineIndex picks the pair a peer's rate is measured over: the oldest sample still within
// maxVelocitySpanMs of the newest, since the longest baseline averages away arrival wobble that would make a ghost
// shimmer. Position and the orientation bracket both use it, so body and facing predict over one pair.
func (b *remoteBuffer) velocityBaselineIndex() (int, bool) {
	n := len(b.snapshots)
	if n < 2 {
		return 0, false
	}
	last := b.snapshots[n-1]
	for i := 0; i <= n-2; i++ {
		span := last.Timestamp - b.snapshots[i].Timestamp
		if span > maxVelocitySpanMs {
			continue
		}
		if span < minVelocitySpanMs {
			break
		}
		return i, true
	}
	return 0, false
}

// extrapolate is the opt-in half of the render model, off unless a Core sets Extrapolate: past the newest sample it
// continues the peer's last measured velocity for up to ahead milliseconds, instead of holding. Every prediction a
// peer does not follow is taken back on screen, and a game that moves on a fixed beat is drawn in steps it never
// takes, so it is judged per game. Conservative: a bounded measuring span, lerp's guards, and a cap on how far ahead.
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
	i, ok := b.velocityBaselineIndex()
	if !ok {
		// Nothing recent enough to carry a rate: hold.
		return last
	}
	older := b.snapshots[i]
	span := last.Timestamp - older.Timestamp
	if older.AreaID != last.AreaID || len(older.Position) != len(last.Position) {
		return last
	}
	pos := make([]float64, len(last.Position))
	// A third sample, halfway in time rather than index, measures change in velocity: a jump is an accelerating body
	// that a straight line lags on the way up and sinks through the floor on the way down.
	mid, hasMid := b.midSample(i, len(b.snapshots)-1)
	// Anything not one of the two curved modes is linear, the empty string included.
	if predict != PredictDamped && predict != PredictAccelerated {
		hasMid = false
	}
	for j := range pos {
		v := (last.Position[j] - older.Position[j]) / float64(span)
		p := last.Position[j] + v*float64(dt)
		if hasMid && len(mid.Position) == len(last.Position) && mid.AreaID == last.AreaID {
			t1 := float64(mid.Timestamp - older.Timestamp)
			t2 := float64(last.Timestamp - mid.Timestamp)
			// Both legs need minVelocitySpanMs too: when a peer stops standing still, the sample nearest the midpoint
			// is the 1ms bracket re-statement. Otherwise the straight-line v above stands.
			if t1 >= minVelocitySpanMs && t2 >= minVelocitySpanMs {
				v1 := (mid.Position[j] - older.Position[j]) / t1
				v2 := (last.Position[j] - mid.Position[j]) / t2
				if predict == PredictDamped {
					// Per axis, prediction scales with how far the two halves of the window agree on velocity: full
					// for steady running, little under gravity, none where a jump's apex reverses it. A statement
					// about the samples, not the game.
					spread := math.Abs(v2 - v1)
					scale := math.Abs(v1) + math.Abs(v2)
					confidence := 1.0
					if scale > 0 {
						confidence = 1 - spread/scale
					}
					// Floored, or a peer tapping left and right falls back to pure lateness: a little wrong for
					// 30ms beats a whole interp delay late.
					if confidence < minPredictConfidence {
						confidence = minPredictConfidence
					}
					// Velocity only, and not smoothed across frames: acceleration and a lagging confidence both made
					// a prediction whose size wobbles under jitter, which shows even when its direction is right.
					p = last.Position[j] + v2*float64(dt)*confidence
					pos[j] = p
					continue
				}
				a := (v2 - v1) / ((t1 + t2) / 2)
				// A velocity measured across a span is the velocity at its middle, so v2 is carried forward half of t2.
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

// extrapolationMeter measures how much prediction actually happens, which the setting cannot say: Extrapolate is a
// cap, while what is predicted is however far the render time has run past the newest sample. Read through
// Core.Stats.
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

// CurveMode picks how a position between two samples is computed. A per-client setting, since the core may not know
// its game; a player, adapter or launcher makes it a per-game choice.
type CurveMode string

const (
	// CurveLinear is the shipped default: a straight line between the two bracketing samples.
	CurveLinear CurveMode = "linear"

	// CurveCatmullRom fits a uniform curve through four consecutive samples, so an arc renders as an arc. Off by
	// default: a curve is smoother than the samples imply, a defect for a game that moves on a fixed beat. It can
	// overshoot slightly on a sharp turn; the centripetal variant would not.
	CurveCatmullRom CurveMode = "catmull-rom"
)

// curved renders between snapshots[i] and snapshots[i+1] with the samples either side as tangents, falling back to
// lerp when any of the four is unusable, so a curve never crosses a discontinuity the straight line refuses.
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

// catmullRom is the uniform spline at t in [0,1] between p1 and p2. Collinear points give the straight line exactly.
func catmullRom(p0, p1, p2, p3, t float64) float64 {
	t2 := t * t
	t3 := t2 * t
	return 0.5 * ((2 * p1) +
		(-p0+p2)*t +
		(2*p0-5*p1+4*p2-p3)*t2 +
		(-p0+3*p1-3*p2+p3)*t3)
}

// midSample returns the snapshot closest to halfway in time between two indices; the middle by index can sit
// anywhere when samples arrive unevenly.
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

// PredictMode picks how a ghost is carried past its newest sample, when Core.Extrapolate is on.
type PredictMode string

const (
	// PredictLinear continues the last measured velocity. Steady, but a straight line lags a jump on the way up and
	// carries it through the floor on the way down.
	PredictLinear PredictMode = "linear"

	// PredictAccelerated fits the curvature too, from three samples. It models a jump, but a second derivative of
	// jittery samples amplifies the jitter and can read as snappy where it was meant to help.
	PredictAccelerated PredictMode = "accelerated"

	// PredictDamped is linear prediction scaled per axis by how consistent the recent velocity has been: a steady
	// axis is predicted in full, one changing or reversing, as at a jump's apex, barely or not at all.
	PredictDamped PredictMode = "damped"
)

// transitMeter records how long samples take to arrive: arrival minus the sender's timestamp, on this machine's
// clock. A transit far above what the link adds means delivery stalls in bursts, not that interp is short. Guarded
// by Core.mu.
type transitMeter struct {
	count   uint64
	totalMs uint64
	maxMs   int64
	slow    uint64
	hist    msHistogram
}

const slowTransitMs = 200

// msHistogram buckets millisecond readings so the stats line can print high percentiles: a delay sized on an average
// is undersized by construction. Fixed size, one increment per reading.
type msHistogram struct {
	buckets [msHistBuckets]uint64 // [i] holds readings in [i*width, (i+1)*width); the last holds everything above
	count   uint64
}

const (
	msHistWidthMs = 10
	msHistBuckets = 301 // 0..3000ms in 10ms steps, then one overflow bucket
)

func (h *msHistogram) add(ms int64) {
	i := 0
	if ms > 0 {
		i = int(ms / msHistWidthMs)
		if i >= msHistBuckets {
			i = msHistBuckets - 1
		}
	}
	h.buckets[i]++
	h.count++
}

// percentile returns the upper edge of the bucket holding the p-th percentile reading (p in 0..100), so a size read
// off it covers that share, capped at maxMs so a 2ms link never reads "p50 10ms". The overflow bucket returns maxMs.
func (h *msHistogram) percentile(p float64, maxMs int64) int64 {
	if h.count == 0 {
		return 0
	}
	rank := uint64(math.Ceil(p / 100 * float64(h.count)))
	if rank < 1 {
		rank = 1
	}
	var seen uint64
	for i, n := range h.buckets {
		seen += n
		if seen >= rank {
			if i == msHistBuckets-1 {
				return maxMs
			}
			return min(int64(i+1)*msHistWidthMs, maxMs)
		}
	}
	return maxMs
}

func (m *transitMeter) record(ms int64) {
	m.hist.add(ms)
	m.count++
	if ms > 0 {
		m.totalMs += uint64(ms)
	}
	if ms > m.maxMs {
		m.maxMs = ms
	}
	if ms > slowTransitMs {
		m.slow++
	}
}

// dryMeter counts renders past the newest sample while the peer was moving: the buffer running dry, seen as a hitch
// then a snap. Non-zero means interp is short for the link's holes; zero means the adapter snaps on its own. An idle
// peer is not counted: its keepalive spacing puts the newest sample behind the render time by design. Guarded by
// Core.mu.
type dryMeter struct {
	renders uint64 // every render of a moving peer, dry or not
	dry     uint64
	totalMs uint64
	maxMs   int64
	hist    msHistogram // how far past the newest sample, dry renders only
}

// dryBy reports how far (ms) renderTime sits past the newest sample when the sender moved between its last two
// samples, or 0 when the render is covered or the peer is idle.
func (b *remoteBuffer) dryBy(renderTime int64) (past int64, moving bool) {
	n := len(b.snapshots)
	if n < 2 {
		return 0, false
	}
	last, before := b.snapshots[n-1], b.snapshots[n-2]
	if len(last.Position) != len(before.Position) {
		return 0, false
	}
	for i := range last.Position {
		if last.Position[i] != before.Position[i] {
			moving = true
			break
		}
	}
	if !moving {
		return 0, false
	}
	if renderTime > last.Timestamp {
		past = renderTime - last.Timestamp
	}
	return past, true
}

func (m *dryMeter) record(past int64, moving bool) {
	if !moving {
		return
	}
	m.renders++
	if past <= 0 {
		return
	}
	m.dry++
	m.hist.add(past)
	m.totalMs += uint64(past)
	if past > m.maxMs {
		m.maxMs = past
	}
}
