package protocol

// The previous sample, carried inside the next one — loss cover for the state
// plane (ADR 0045, 2026-09-02).
//
// The state plane is unreliable on purpose: on quic it rides datagrams and on
// udp it rides packets, and a lost sample is superseded by the next one rather
// than retransmitted (core/sending.go). That is the right trade for a sample
// in the MIDDLE of a walk. It is the wrong trade for the LAST one: change
// suppression (ADR 0039) means the packet that says "I stopped here" has no
// successor until the idle keepalive, so losing it leaves the ghost walking on
// to nowhere and then jumping when the keepalive lands. Watched on Crystal on
// 2026-09-02 through meshghost-netsim at 2% loss: a glide, then a teleport, on
// quic and udp alike.
//
// The fix is the standard one for an unreliable game transport: every state
// also carries the state before it, so a single lost packet costs nothing —
// the next packet re-delivers what was missed — and only a run of losses
// shows. It is carried as a DELTA against the state it rides in, because a
// full copy would double the state plane's bytes and the fields that differ
// between two consecutive samples are usually the position and a timestamp.
//
// The core decides WHEN to attach it (rate-gated: at a high send rate a lost
// packet is a hole too short to see, so the bytes would buy nothing —
// core.Core.RedundancyMinInterval). This file only defines the shape and the
// two pure functions that build and undo it, so the relay's fuzz target and
// the core's tests exercise the same code.

import (
	"bytes"
	"encoding/json"
	"reflect"
)

// StatePrev is the sender's previous sample as a delta against the State that
// carries it. Every field that is absent means "the same as in the carrying
// state"; Seq and Timestamp are always present because they always differ.
//
// Explicitly nullable fields say "the previous sample did NOT have this":
//   - Orientation: the JSON literal null means the previous sample carried no
//     orientation (omitting it would mean "same as now").
//   - Position: PositionNone true means the previous sample carried none (an
//     empty array would be dropped by omitempty like a nil one).
//   - Extras: a key whose value is null was ABSENT in the previous sample;
//     ExtrasNone true means the previous sample had no extras at all. A real
//     null VALUE inside extras is indistinguishable from absence here, which
//     the contract accepts: extras are a "small free-form dict" and no shipped
//     adapter sends a null value (a key it has nothing to say for is omitted).
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

// BuildPrev expresses prev as a delta against cur. prev must be the sample
// sent IMMEDIATELY before cur by the same sender, with its own Seq and
// Timestamp; cur.Prev is ignored (a prev never carries a prev). Never nil: at
// minimum the delta carries prev's seq and timestamp.
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
			// prev had no position and cur has one. An empty slice is
			// dropped by omitempty exactly like a nil one, so absence needs
			// its own flag, the same way extras_none does.
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

// ApplyPrev reconstructs the previous sample from the state that carries it.
// Returns ok=false when cur carries no prev. The result has no Prev of its own
// and cur's PlayerID (the relay stamps that on the carrying state, and the
// previous sample came from the same sender).
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
		// A fresh map every time: cur.Extras is shared with the carrying
		// state, which the caller still stores, so it is never mutated here.
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
		out.Extras = m
	}
	return out, true
}

// samePositionValues is component-wise equality with nil and empty treated as
// the same absence (a position is "none" either way on the wire).
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

// validPrev is ValidateState's view of a carried previous sample: every bound
// the carrying state must meet, applied to the delta's own fields. No nesting
// is possible by type (StatePrev has no Prev), so this cannot recurse.
func validPrev(p *StatePrev) bool {
	if p == nil {
		return true
	}
	if p.AreaID != nil && !ValidOpaqueString(*p.AreaID, MaxAreaIDLen) {
		return false
	}
	if p.Anim != nil && !ValidOpaqueString(*p.Anim, MaxAnimLen) {
		return false
	}
	if JSONWireLen(p.Orientation) > MaxOrientationBytes {
		return false
	}
	if len(p.Position) > MaxPositionLen || !IsValidPosition(p.Position) {
		return false
	}
	return extrasWithinLimit(p.Extras)
}
