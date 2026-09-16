package runlog

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"testing"
)

func readRecords(t *testing.T, path string) []map[string]any {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out []map[string]any
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var rec map[string]any
		if err := json.Unmarshal(sc.Bytes(), &rec); err != nil {
			t.Fatalf("line %q: %v", sc.Text(), err)
		}
		out = append(out, rec)
	}
	return out
}

func TestASegmentIsWalkedUntilSomethingReachesIt(t *testing.T) {
	l, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	l.Call("press", map[string]any{"buttons": []string{"Left"}}, nil, "")
	l.Call("observe", nil, nil, "")
	if got := l.Current().Claim; got != "walked" {
		t.Fatalf("after play only, claim = %q", got)
	}

	walked := l.Begin("to the door")
	if walked.Claim != "walked" || walked.Label != "start" || walked.N != 1 {
		t.Fatalf("closed segment = %+v", walked)
	}

	l.Call("cheat", map[string]any{"kind": "warp"}, errors.New("not in the overworld"), "cheat:warp")
	if got := l.Current().Claim; got != "walked" {
		t.Fatalf("a FAILED cheat must not mark the segment reached, got %q", got)
	}
	l.Call("cheat", map[string]any{"kind": "warp"}, nil, "cheat:warp")
	l.Call("press", nil, nil, "")
	reached := l.Begin("after")
	if reached.Claim != "reached" || len(reached.Because) != 1 || reached.Because[0] != "cheat:warp" || reached.N != 2 {
		t.Fatalf("closed segment = %+v", reached)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}

	recs := readRecords(t, l.Path())
	var segments []string
	for _, r := range recs {
		if r["type"] == "segment" {
			s := r["segment"].(map[string]any)
			segments = append(segments, s["label"].(string)+"="+s["claim"].(string))
		}
	}
	want := []string{"start=walked", "to the door=reached", "after=walked"}
	if len(segments) != len(want) {
		t.Fatalf("segments %v, want %v", segments, want)
	}
	for i := range want {
		if segments[i] != want[i] {
			t.Fatalf("segments %v, want %v", segments, want)
		}
	}
}

func TestANilLogRecordsNothing(t *testing.T) {
	var l *Log
	l.Call("press", nil, nil, "cheat:warp")
	l.Begin("x")
	if l.Current().Claim != "" || l.Close() != nil || l.Path() != "" {
		t.Fatal("a nil log should be a no-op")
	}
}
