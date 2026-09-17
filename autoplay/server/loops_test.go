package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func answerAt(outcome string, x, y float64) json.RawMessage {
	b, _ := json.Marshal(map[string]any{"outcome": outcome, "after": map[string]any{"location": map[string]any{"map": "0.26", "x": x, "y": y}}})
	return b
}

func TestLoopWatchNamesTheThirdRepeatAtOnePlace(t *testing.T) {
	var w loopWatch
	args := map[string]any{"map": "0.13", "x": 15, "y": 16}
	for i := 0; i < LoopRepeats-1; i++ {
		if n := w.note("goto", args, "dialogue_open", answerAt("dialogue_open", 14, 61)); n != nil {
			t.Fatalf("call %d already a loop: %+v", i+1, n)
		}
		w.note("advance_text", map[string]any{}, "closed", answerAt("closed", 14, 62.4))
	}
	n := w.note("goto", args, "dialogue_open", answerAt("dialogue_open", 14, 61))
	if n == nil || n.Tool != "goto" || n.Outcome != "dialogue_open" || n.Repeats != LoopRepeats || !strings.Contains(n.Where, `"y":61`) {
		t.Fatalf("the third repeat = %+v", n)
	}
}

func TestLoopWatchLeavesAloneWhatDiffers(t *testing.T) {
	var w loopWatch
	args := map[string]any{"policy": "effective"}
	// Four trainers, each met somewhere else: the same call and outcome, another place each time.
	for i := 0; i < 4; i++ {
		if n := w.note("battle", args, "ended", answerAt("ended", float64(20+i), 132)); n != nil {
			t.Fatalf("trainer %d marked a loop: %+v", i+1, n)
		}
	}
	// Positions read to a fraction compare as whole tiles; other arguments are another call.
	for i := 0; i < 4; i++ {
		if n := w.note("walk", map[string]any{"tiles": i}, "done", answerAt("done", 3.2, 4)); n != nil {
			t.Fatalf("walk %d marked a loop: %+v", i+1, n)
		}
	}
	// No outcome word: not watched.
	for i := 0; i < 5; i++ {
		if n := w.note("press", map[string]any{"buttons": []string{"A"}}, "", json.RawMessage(`{}`)); n != nil {
			t.Fatalf("press marked a loop: %+v", n)
		}
	}
}

func TestLoopWatchForgetsPastItsWindowAndOnClear(t *testing.T) {
	var w loopWatch
	same := func() *LoopNote {
		return w.note("goto", map[string]any{"x": 1}, "unreachable", answerAt("unreachable", 1, 1))
	}
	filler := func(i int) { w.note("walk", map[string]any{"i": i}, "done", answerAt("done", float64(i), 0)) }
	same()
	for i := 0; i < LoopWindow; i++ {
		filler(i)
	}
	same()
	if n := same(); n != nil {
		t.Fatalf("a repeat outside the window counted: %+v", n)
	}
	w.clear()
	same()
	if n := same(); n != nil {
		t.Fatalf("a repeat from before clear counted: %+v", n)
	}
	if n := same(); n == nil {
		t.Fatal("three after clear were not a loop")
	}
}

func TestWhereOfReadsTheUsualPlaces(t *testing.T) {
	for _, c := range []struct{ answer, want string }{
		{`{"after":{"location":{"map":"4.1","x":13,"y":10}}}`, `{"map":"4.1","x":13,"y":10}`},
		{`{"location":{"x":17040.4,"y":-2.6}}`, `{"x":17040,"y":-3}`},
		{`{"at":{"x":1,"y":2}}`, `{"x":1,"y":2}`},
		{`{"last":{"after":{"location":{"map":"0.2"}}}}`, `{"map":"0.2"}`},
		{`{"outcome":"done"}`, ``},
		{`[1,2]`, ``},
	} {
		if got := whereOf(json.RawMessage(c.answer)); got != c.want {
			t.Errorf("whereOf(%s) = %q, want %q", c.answer, got, c.want)
		}
	}
}

func TestWithLoopAddsAFieldToAnObjectOnly(t *testing.T) {
	note := &LoopNote{Tool: "goto", Outcome: "done", Repeats: 3, Within: 5, Note: "n"}
	for _, raw := range []string{`{"outcome":"done","x":1}`, ` { } `, `{}`} {
		out := withLoop(json.RawMessage(raw), note)
		var m map[string]any
		if err := json.Unmarshal(out, &m); err != nil {
			t.Fatalf("withLoop(%s) = %s: %v", raw, out, err)
		}
		if loop, ok := m["loop"].(map[string]any); !ok || loop["tool"] != "goto" {
			t.Fatalf("withLoop(%s) = %s", raw, out)
		}
	}
	if out := withLoop(json.RawMessage(`[1]`), note); string(out) != `[1]` {
		t.Fatalf("an array answer was changed: %s", out)
	}
}

func TestARepeatedAnswerCarriesTheLoopAndRestoreClearsIt(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"goto", "snapshot", "restore"}, func(verb string, payload json.RawMessage) (string, any) {
		var p struct {
			Path string `json:"path"`
		}
		json.Unmarshal(payload, &p)
		switch verb {
		case "snapshot":
			os.WriteFile(filepath.FromSlash(p.Path), []byte("state"), 0o644)
			return "result", map[string]any{"path": p.Path}
		case "restore":
			return "result", map[string]any{"path": p.Path}
		}
		return "result", map[string]any{"outcome": "unreachable", "after": map[string]any{"location": map[string]any{"map": "0.26", "x": 17, "y": 38}}}
	})
	gotoSlope := func() string {
		text, isErr := h.call(t, "goto", map[string]any{"x": 17, "y": 35})
		if isErr {
			t.Fatalf("goto = %s", text)
		}
		return text
	}
	for i := 0; i < LoopRepeats-1; i++ {
		if text := gotoSlope(); strings.Contains(text, `"loop"`) {
			t.Fatalf("call %d marked: %s", i+1, text)
		}
	}
	text := gotoSlope()
	var m map[string]any
	if err := json.Unmarshal([]byte(text), &m); err != nil || m["outcome"] != "unreachable" {
		t.Fatalf("the marked answer is not the driver's answer plus a field: %s (%v)", text, err)
	}
	if loop, ok := m["loop"].(map[string]any); !ok || loop["tool"] != "goto" || loop["repeats"] != float64(LoopRepeats) {
		t.Fatalf("the third repeat = %s", text)
	}
	log, err := os.ReadFile(h.log.Path())
	if err != nil || !strings.Contains(string(log), `"type":"loop"`) {
		t.Fatalf("the run log has no loop record (%v)", err)
	}

	if text, isErr := h.call(t, "snapshot", map[string]any{"label": "below_slope"}); isErr {
		t.Fatalf("snapshot = %s", text)
	}
	if text, isErr := h.call(t, "restore", map[string]any{"label": "below_slope"}); isErr {
		t.Fatalf("restore = %s", text)
	}
	if text := gotoSlope(); strings.Contains(text, `"loop"`) {
		t.Fatalf("a repeat from before the restore counted: %s", text)
	}
}
