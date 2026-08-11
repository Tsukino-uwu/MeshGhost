package core

import "meshghost/internal/protocol"

// maxSnapshots bounds how much history is kept per remote — enough to
// smooth over a couple of dropped packets, not a full replay log.
const maxSnapshots = 8

// remoteBuffer holds a short history of a remote player's snapshots,
// ordered oldest to newest by protocol.State.Timestamp, used to compute an
// interpolated render-time state between real network updates. See the
// tick model in agent_docs/contract.md.
type remoteBuffer struct {
	snapshots []protocol.State
}

// add appends a new snapshot. Callers are expected to add snapshots in
// non-decreasing Timestamp order (the order they arrive from the relay);
// add does not re-sort.
func (b *remoteBuffer) add(s protocol.State) {
	b.snapshots = append(b.snapshots, s)
	if len(b.snapshots) > maxSnapshots {
		b.snapshots = b.snapshots[len(b.snapshots)-maxSnapshots:]
	}
}

// at returns the interpolated state for renderTime (same units as
// protocol.State.Timestamp: milliseconds). Position is linearly
// interpolated component-wise between the two snapshots bracketing
// renderTime. area_id, anim, orientation, and extras are opaque per
// agent_docs/contract.md and are never interpolated — they're taken from
// the older of the two bracketing snapshots, holding their value until the
// next real sample passes renderTime. If renderTime falls outside the
// buffered range, the nearest edge snapshot is returned unchanged (no
// extrapolation). ok is false only if no snapshots have been added yet.
func (b *remoteBuffer) at(renderTime int64) (protocol.State, bool) {
	n := len(b.snapshots)
	if n == 0 {
		return protocol.State{}, false
	}
	if n == 1 || renderTime <= b.snapshots[0].Timestamp {
		return b.snapshots[0], true
	}
	last := b.snapshots[n-1]
	if renderTime >= last.Timestamp {
		return last, true
	}
	for i := 0; i < n-1; i++ {
		older, newer := b.snapshots[i], b.snapshots[i+1]
		if renderTime >= older.Timestamp && renderTime <= newer.Timestamp {
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
// adapter-side contract violation, not something to guess through) or a
// non-positive time span (duplicate timestamps).
func lerp(older, newer protocol.State, renderTime int64) protocol.State {
	span := newer.Timestamp - older.Timestamp
	if span <= 0 || len(older.Position) != len(newer.Position) {
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
	out.Seq = newer.Seq
	return out
}
