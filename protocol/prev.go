package protocol

// The previous sample, carried inside the next one: loss cover for the state plane. A lost sample is superseded
// rather than retransmitted, which is right mid-walk and wrong for the last one: with change suppression, "I stopped
// here" has no successor until the idle keepalive, so losing it leaves a ghost gliding on and then jumping.
//
// So every state also carries the one before it, as a delta, since a full copy would double the bytes. The core
// decides when to attach it (core.Core.RedundancyMinInterval); this file is the shape and the two pure functions
// that build and undo it, so the relay's fuzz target and the core's tests exercise the same code.

import (
	"bytes"
	"encoding/json"
	"reflect"
)

// StatePrev is the sender's previous sample as a delta against the State that carries it: an absent field means
// "the same as in the carrying state", and Seq and Timestamp are always present.
//
// Absence in the previous sample is explicit: Orientation null means it had no orientation, PositionNone that it
// had no position (an empty array is dropped by omitempty), an extras key set to null that the key was absent, and
// ExtrasNone that it had no extras. A real null value inside extras therefore reads as absence, which the contract
// accepts.
type StatePrev struct {
	Seq          uint64          `json:"seq"`
	Timestamp    int64           `json:"timestamp"`
	AreaID       *string         `json:"area_id,omitempty"`
	Position     []float64       `json:"position,omitempty"`
	PositionNone bool            `json:"position_none,omitempty"`
	Orientation  json.RawMessage `json:"orientation,omitempty"`
	Anim         *string         `json:"anim,omitempty"`
	Extras       map[string]any  `json:"extras,omitempty"`
	ExtrasNone   bool            `json:"extras_none,omitempty"`
}

var jsonNull = []byte("null")

// BuildPrev expresses prev as a delta against cur. prev must be the sample sent immediately before cur by the same
// sender; cur.Prev is ignored, since a prev never carries a prev. Never nil: the delta carries at least prev's seq
// and timestamp.
func BuildPrev(prev, cur *State) *StatePrev {
	d := &StatePrev{Seq: prev.Seq, Timestamp: prev.Timestamp}
	if prev.AreaID != cur.AreaID {
		a := prev.AreaID
		d.AreaID = &a
	}
	if prev.Anim != cur.Anim {
		a := prev.Anim
		d.Anim = &a
	}
	if !samePositionValues(prev.Position, cur.Position) {
		if len(prev.Position) == 0 {
			// An empty slice is dropped by omitempty like a nil one, so absence needs its own flag.
			d.PositionNone = true
		} else {
			d.Position = append([]float64(nil), prev.Position...)
		}
	}
	if !bytes.Equal(prev.Orientation, cur.Orientation) {
		if len(prev.Orientation) == 0 {
			d.Orientation = jsonNull
		} else {
			d.Orientation = append(json.RawMessage(nil), prev.Orientation...)
		}
	}
	if !reflect.DeepEqual(prev.Extras, cur.Extras) {
		if len(prev.Extras) == 0 {
			d.ExtrasNone = true
		} else {
			d.Extras = make(map[string]any, len(prev.Extras))
			for k, v := range prev.Extras {
				if cv, ok := cur.Extras[k]; !ok || !reflect.DeepEqual(cv, v) {
					d.Extras[k] = v
				}
			}
			for k := range cur.Extras {
				if _, ok := prev.Extras[k]; !ok {
					d.Extras[k] = nil
				}
			}
		}
	}
	return d
}

// ApplyPrev reconstructs the previous sample from the state that carries it, with no Prev and cur's PlayerID (the
// same sender). ok=false when cur carries no prev, or when the extras union, the one field this function creates,
// breaks a bound neither ValidateState nor validPrev can see.
func ApplyPrev(cur *State) (State, bool) {
	p := cur.Prev
	if p == nil {
		return State{}, false
	}
	out := *cur
	out.Prev = nil
	out.Seq = p.Seq
	out.Timestamp = p.Timestamp
	if p.AreaID != nil {
		out.AreaID = *p.AreaID
	}
	if p.Anim != nil {
		out.Anim = *p.Anim
	}
	switch {
	case p.PositionNone:
		out.Position = nil
	case len(p.Position) > 0:
		out.Position = append([]float64(nil), p.Position...)
	}
	if len(p.Orientation) != 0 {
		if bytes.Equal(bytes.TrimSpace(p.Orientation), jsonNull) {
			out.Orientation = nil
		} else {
			out.Orientation = append(json.RawMessage(nil), p.Orientation...)
		}
	}
	switch {
	case p.ExtrasNone:
		out.Extras = nil
	case p.Extras != nil:
		// A fresh map: cur.Extras is shared with the carrying state, which the caller still stores.
		m := make(map[string]any, len(cur.Extras)+len(p.Extras))
		for k, v := range cur.Extras {
			m[k] = v
		}
		for k, v := range p.Extras {
			if v == nil {
				delete(m, k)
			} else {
				m[k] = v
			}
		}
		// ValidateState bounds cur.Extras and validPrev bounds p.Extras, each alone, so disjoint keys can both
		// pass and sum to twice the bound. Dropping the cover rather than the state costs almost nothing: prev is
		// pure redundancy, and the caller stores cur regardless.
		if !extrasWithinLimit(m) {
			return State{}, false
		}
		out.Extras = m
	}
	return out, true
}

// samePositionValues is component-wise equality with nil and empty treated as the same absence.
func samePositionValues(a, b []float64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// validPrev is ValidateState's view of a carried previous sample: every bound the carrying state must meet, applied
// to the delta's own fields. StatePrev has no Prev, so this cannot recurse.
func validPrev(p *StatePrev) bool {
	if p == nil {
		return true
	}
	// ApplyPrev copies the timestamp verbatim, so an unbounded one would reach the buffer as a sample ValidateState
	// refuses and leave the peer immune to the stale age-out.
	if p.Timestamp < 0 || p.Timestamp > MaxTimestampMs {
		return false
	}
	if p.AreaID != nil && !ValidOpaqueString(*p.AreaID, MaxAreaIDLen) {
		return false
	}
	if p.Anim != nil && !ValidOpaqueString(*p.Anim, MaxAnimLen) {
		return false
	}
	// Both halves of the orientation bound, as ValidateState applies them: ApplyPrev copies orientation verbatim to
	// the adapter.
	if JSONWireLen(p.Orientation) > MaxOrientationBytes ||
		!rawJSONDepthWithinLimit(p.Orientation) {
		return false
	}
	if len(p.Position) > MaxPositionLen || !IsValidPosition(p.Position) {
		return false
	}
	return extrasWithinLimit(p.Extras)
}
