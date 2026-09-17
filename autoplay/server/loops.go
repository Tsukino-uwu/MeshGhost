package server

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"sync"
)

// LOOPS (2026-09-17). Two unattended Emerald sessions spent minutes on calls that kept answering the same thing at the
// same place -- a trip walking back into one message, a goto sliding back down a mud slope -- until the user saw it on
// screen. Every call passes through logged, so the core watches them for every game: a call whose tool, arguments,
// outcome word and place after it all match LoopRepeats of the last LoopWindow calls is a loop. Its answer gains a "loop"
// field saying so (a skill run ends there, outcome "loop"), and the run log a "loop" record. A call with no outcome word
// (press, observe, a read) is not watched, and restore clears what was seen: a fight retried from a snapshot is a choice.
const (
	LoopWindow  = 12
	LoopRepeats = 3
)

// LoopNote is what a looping call's answer carries.
type LoopNote struct {
	Tool    string `json:"tool"`
	Outcome string `json:"outcome"`
	Where   string `json:"where,omitempty"`
	Repeats int    `json:"repeats"`
	Within  int    `json:"within"`
	Note    string `json:"note"`
}

type loopWatch struct {
	mu   sync.Mutex
	seen []string
}

// note records one call and returns a LoopNote when it repeats. args is the call's input; answer its output.
func (w *loopWatch) note(tool string, args any, outcome string, answer any) *LoopNote {
	if outcome == "" {
		return nil
	}
	a, _ := json.Marshal(args)
	where := whereOf(answer)
	key := tool + "\x00" + string(a) + "\x00" + outcome + "\x00" + where
	w.mu.Lock()
	defer w.mu.Unlock()
	w.seen = append(w.seen, key)
	if len(w.seen) > LoopWindow {
		w.seen = w.seen[len(w.seen)-LoopWindow:]
	}
	n := 0
	for _, k := range w.seen {
		if k == key {
			n++
		}
	}
	if n < LoopRepeats {
		return nil
	}
	return &LoopNote{Tool: tool, Outcome: outcome, Where: where, Repeats: n, Within: len(w.seen),
		Note: fmt.Sprintf("%s with these arguments answered %q here %d times in the last %d calls: the same thing keeps "+
			"happening, so another try the same way will too", tool, outcome, n, len(w.seen))}
}

func (w *loopWatch) clear() {
	w.mu.Lock()
	w.seen = nil
	w.mu.Unlock()
}

// whereOf is the place an answer says the player ended at: "after.location", "location", "at", or a skill run's
// "last" answer's; numbers rounded to whole ones, so a position read to a fraction still compares. "" when none.
func whereOf(answer any) string {
	var m map[string]any
	switch a := answer.(type) {
	case json.RawMessage:
		if json.Unmarshal(a, &m) != nil {
			return ""
		}
	default:
		b, err := json.Marshal(answer)
		if err != nil || json.Unmarshal(b, &m) != nil {
			return ""
		}
	}
	for _, path := range [][]string{{"after", "location"}, {"location"}, {"at"}, {"last", "after", "location"}, {"last", "location"}} {
		if v, ok := dig(m, path); ok {
			b, _ := json.Marshal(rounded(v))
			return string(b)
		}
	}
	return ""
}

func dig(m map[string]any, path []string) (any, bool) {
	var v any = m
	for _, k := range path {
		o, ok := v.(map[string]any)
		if !ok {
			return nil, false
		}
		if v, ok = o[k]; !ok {
			return nil, false
		}
	}
	return v, v != nil
}

func rounded(v any) any {
	switch x := v.(type) {
	case float64:
		return math.Round(x)
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, e := range x {
			out[k] = rounded(e)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = rounded(e)
		}
		return out
	}
	return v
}

// withLoop puts note into a JSON object answer as its "loop" field; any other answer is returned unchanged.
func withLoop(raw json.RawMessage, note *LoopNote) json.RawMessage {
	body := bytes.TrimSpace(raw)
	if len(body) < 2 || body[0] != '{' {
		return raw
	}
	n, err := json.Marshal(note)
	if err != nil {
		return raw
	}
	rest := bytes.TrimSpace(body[1:])
	out := append([]byte(`{"loop":`), n...)
	if len(rest) > 0 && rest[0] != '}' {
		out = append(out, ',')
	}
	return append(out, rest...)
}
