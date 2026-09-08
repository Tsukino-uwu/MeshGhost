package bridge

import (
	"fmt"
	"math"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The bounds on an input track, and the check that enforces them.
//
// WHY THESE LIVE HERE AND NOT IN protocol/limits.go, which is where every other
// limit in this project lives. InputSample is a bridge type, and protocol
// cannot import bridge -- bridge already imports protocol, so it would be a
// cycle. The reason limits.go gives for centralizing (two enforcement points
// that must never drift apart) also does not apply: there is exactly one, the
// core accepting a batch from its own adapter, plus the file loader that reads
// a track back, and both import this package.
//
// NONE OF THIS IS A RELAY LIMIT. An input track never goes on the wire. The
// bridge tolerates a 64 KiB line (transport.DefaultMaxLineBytes), not
// protocol.MaxLineBytes' 4096 -- so a batch is bounded by the numbers below and
// by nothing else, and they are the only thing standing between a broken
// adapter and the core's memory.
const (
	// MaxInputEdgesPerBatch bounds len(InputSample.Edges) in one message. Well
	// above a real drain: an adapter reading at 60fps into a poll loop running
	// several times faster sends 0 or 1 edges a batch, and 64 covers a long
	// stall without ever being a size an adapter should aim at.
	MaxInputEdgesPerBatch = 64

	// MaxInputAxes bounds len(InputEdge.Ax), mirroring protocol.MaxPositionLen
	// and for the same reason: headroom above the largest real use (a stick, a
	// camera, maybe a cursor -- so four to six) rather than a target.
	MaxInputAxes = 8

	// MaxInputLabels bounds how many buttons a track may name, and it is 32
	// because that is the width of InputEdge.M. The two must agree: a label
	// table longer than the mask has bits for is naming buttons that can never
	// be set.
	MaxInputLabels = 32

	// MaxInputLabelLen bounds one label or axis name, in bytes. Same
	// opaque-string treatment area_id and anim get -- the core validates the
	// SHAPE and never reads the meaning.
	MaxInputLabelLen = 32

	// MaxInputAxisValue bounds the magnitude of one analog axis. Sticks are
	// normalized to ±1 and a cursor is screen space, so this is far above any
	// real value; it exists to refuse the infinities and 1e308s that survive a
	// JSON round trip into a float64 and become +Inf the moment something
	// narrows them to float32 (protocol.IsValidPosition's lesson, applied here).
	MaxInputAxisValue = 1e4
)

// validInputAxes reports whether every axis is finite and within bounds.
func validInputAxes(ax []float64) bool {
	if len(ax) > MaxInputAxes {
		return false
	}
	for _, v := range ax {
		if math.IsNaN(v) || math.IsInf(v, 0) || v > MaxInputAxisValue || v < -MaxInputAxisValue {
			return false
		}
	}
	return true
}

// validInputNames reports whether a label or axis-name table is within bounds
// and every entry is a valid opaque string.
func validInputNames(names []string) bool {
	if len(names) > MaxInputLabels {
		return false
	}
	for _, n := range names {
		if !protocol.ValidOpaqueString(n, MaxInputLabelLen) {
			return false
		}
	}
	return true
}

// ValidateInputSample reports whether s passes every bound in this file.
//
// It checks ordering WITHIN the batch only. Ordering ACROSS batches is the
// core's business, because only the core remembers the last edge it accepted --
// see core.Core.recordInput, which refuses a batch that goes backwards against
// its predecessor rather than repairing it.
//
// A mask bit set above len(Labels) is NOT a rejection, deliberately. An adapter
// that sets a bit it forgot to name has produced a legible track with one
// unnamed bit, which is a thing to log and not a thing to refuse -- and
// refusing it would make the core the arbiter of what a label table has to
// contain, which is exactly the game knowledge it must not have.
func ValidateInputSample(s InputSample) bool {
	if len(s.Edges) > MaxInputEdgesPerBatch {
		return false
	}
	// An empty batch is legal only when it is declaring a table. Anything else
	// empty is an adapter burning a line to say nothing.
	if len(s.Edges) == 0 && len(s.Labels) == 0 && len(s.Axes) == 0 {
		return false
	}
	if !validInputNames(s.Labels) || !validInputNames(s.Axes) ||
		!protocol.ValidOpaqueString(s.Source, MaxInputLabelLen) {
		return false
	}
	var lastF uint64
	var lastT int64
	for i, e := range s.Edges {
		// Same bound and the same reason as protocol.ValidateState's: an
		// unbounded timestamp overflows a time.Duration downstream.
		if e.T < 0 || e.T > protocol.MaxTimestampMs {
			return false
		}
		if !validInputAxes(e.Ax) {
			return false
		}
		if i > 0 && (e.F < lastF || e.T < lastT) {
			return false
		}
		lastF, lastT = e.F, e.T
	}
	return true
}

// InputSampleRejectReason names which check s fails, or "" if it passes them
// all. Only ever called on the rejection path, for the same reason
// protocol.StateRejectReason is: a batch dropped for size or shape must say so,
// because every symptom of a silently dropped input track points somewhere else.
func InputSampleRejectReason(s InputSample) string {
	if n := len(s.Edges); n > MaxInputEdgesPerBatch {
		return fmt.Sprintf("%d edges, %d over the %d cap", n, n-MaxInputEdgesPerBatch, MaxInputEdgesPerBatch)
	}
	if len(s.Edges) == 0 && len(s.Labels) == 0 && len(s.Axes) == 0 {
		return "empty batch carrying neither edges nor a label table"
	}
	if len(s.Labels) > MaxInputLabels {
		return fmt.Sprintf("%d labels over the %d cap (the mask is %d bits wide)",
			len(s.Labels), MaxInputLabels, MaxInputLabels)
	}
	if !validInputNames(s.Labels) {
		return fmt.Sprintf("a label is invalid UTF-8 or over %d bytes", MaxInputLabelLen)
	}
	if len(s.Axes) > MaxInputLabels {
		return fmt.Sprintf("%d axis names over the %d cap", len(s.Axes), MaxInputLabels)
	}
	if !validInputNames(s.Axes) {
		return fmt.Sprintf("an axis name is invalid UTF-8 or over %d bytes", MaxInputLabelLen)
	}
	if !protocol.ValidOpaqueString(s.Source, MaxInputLabelLen) {
		return fmt.Sprintf("source invalid UTF-8 or over %d bytes", MaxInputLabelLen)
	}
	var lastF uint64
	var lastT int64
	for i, e := range s.Edges {
		if e.T < 0 {
			return fmt.Sprintf("edge %d: t %d is before the epoch", i, e.T)
		}
		if e.T > protocol.MaxTimestampMs {
			return fmt.Sprintf("edge %d: t %d is past the %d cap", i, e.T, int64(protocol.MaxTimestampMs))
		}
		if n := len(e.Ax); n > MaxInputAxes {
			return fmt.Sprintf("edge %d: %d axes over the %d cap", i, n, MaxInputAxes)
		}
		if !validInputAxes(e.Ax) {
			return fmt.Sprintf("edge %d: an axis is not finite or is past ±%g", i, float64(MaxInputAxisValue))
		}
		if i > 0 && e.F < lastF {
			return fmt.Sprintf("edge %d: frame %d goes backwards from %d", i, e.F, lastF)
		}
		if i > 0 && e.T < lastT {
			return fmt.Sprintf("edge %d: t %d goes backwards from %d", i, e.T, lastT)
		}
		lastF, lastT = e.F, e.T
	}
	return ""
}
