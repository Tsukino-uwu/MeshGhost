package bridge

import (
	"fmt"
	"math"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The bounds on an input track. They live here rather than in protocol because protocol cannot import bridge. None is
// a relay limit, since an input track never goes on the wire: the bridge tolerates a 64 KiB line, so these are all
// that stands between a broken adapter and the core's memory.
const (
	// MaxInputEdgesPerBatch bounds len(InputSample.Edges): well above a real drain, covering a long stall.
	MaxInputEdgesPerBatch = 64

	// MaxInputAxes bounds len(InputEdge.Ax), with headroom above a stick, a camera and a cursor.
	MaxInputAxes = 8

	// MaxInputLabels bounds how many buttons a track may name. It is the width of InputEdge.M: a label past the mask's
	// bits names a button that can never be set.
	MaxInputLabels = 32

	// MaxInputLabelLen bounds one label or axis name in bytes; the core checks the shape and never reads the meaning.
	MaxInputLabelLen = 32

	// MaxInputFrame bounds InputEdge.F at 2^53, the largest integer a float64 carries exactly: a reader that is not Go
	// parses f as a double, and a uint64 near its maximum rounds to 2^64, past the range of a cast back to uint64.
	MaxInputFrame = 1 << 53

	// MaxInputAxisValue bounds one analog axis, far above any real value (sticks are ±1, a cursor is screen space), to
	// refuse values that survive a float64 and become +Inf when narrowed to float32.
	MaxInputAxisValue = 1e4
)

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

// ValidateInputSample reports whether s passes every bound in this file. It checks ordering within the batch only;
// core.Core.recordInput refuses a batch that goes backwards against its predecessor. A mask bit above len(Labels) is
// not a rejection: refusing it would make the core judge what a label table must contain.
func ValidateInputSample(s InputSample) bool {
	if len(s.Edges) > MaxInputEdgesPerBatch {
		return false
	}
	// An empty batch is legal only when it declares a table.
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
		// An unbounded timestamp overflows a time.Duration downstream.
		if e.T < 0 || e.T > protocol.MaxTimestampMs {
			return false
		}
		if e.F > MaxInputFrame {
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

// InputSampleRejectReason names which check s fails, or "" if it passes them all. Called only on the rejection path,
// because a silently dropped input track shows symptoms that point somewhere else.
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
		if e.F > MaxInputFrame {
			return fmt.Sprintf("edge %d: frame %d is past the %d cap (a double cannot carry it exactly)",
				i, e.F, uint64(MaxInputFrame))
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
