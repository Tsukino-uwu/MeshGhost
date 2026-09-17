package runlog

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
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

// mcpcall starts a core per invocation: each one resumes the same file, and the segment a previous core
// left open carries on with its label and the claim its calls earned.
func TestResumeCarriesOnTheOpenSegment(t *testing.T) {
	l, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	l.Begin("to the door")
	l.Call("cheat", map[string]any{"kind": "warp"}, nil, "cheat:warp")
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}

	second, err := Resume(l.Path())
	if err != nil {
		t.Fatal(err)
	}
	cur := second.Current()
	if cur.N != 2 || cur.Label != "to the door" || cur.Claim != "reached" || len(cur.Because) != 1 || cur.Because[0] != "cheat:warp" {
		t.Fatalf("resumed segment = %+v", cur)
	}
	if closed := second.Begin("next"); closed.N != 2 || closed.Claim != "reached" {
		t.Fatalf("closed after resume = %+v", closed)
	}
	if err := second.Close(); err != nil {
		t.Fatal(err)
	}

	third, err := Resume(l.Path())
	if err != nil {
		t.Fatal(err)
	}
	if cur := third.Current(); cur.N != 3 || cur.Label != "next" || cur.Claim != "walked" {
		t.Fatalf("resumed segment = %+v", cur)
	}
	third.Call("cheat", map[string]any{"kind": "warp"}, errors.New("refused"), "cheat:warp")
	if err := third.Close(); err != nil {
		t.Fatal(err)
	}

	fourth, err := Resume(l.Path())
	if err != nil {
		t.Fatal(err)
	}
	if cur := fourth.Current(); cur.Claim != "walked" {
		t.Fatalf("a FAILED cheat before the resume marked the segment %q", cur.Claim)
	}
	fourth.Call("restore", map[string]any{"label": "x"}, nil, "restore")
	if err := fourth.Close(); err != nil {
		t.Fatal(err)
	}

	fifth, err := Resume(l.Path())
	if err != nil {
		t.Fatal(err)
	}
	if cur := fifth.Current(); cur.N != 3 || cur.Claim != "reached" || len(cur.Because) != 1 || cur.Because[0] != "restore" {
		t.Fatalf("resumed segment = %+v", cur)
	}
	fifth.Close()
}

func TestResumeRefusesALogWithNoOpenSegment(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.ndjson")
	old := `{"type":"call","tool":"press","segment":1,"ok":true}` + "\n" +
		`{"type":"segment","segment":{"n":1,"label":"start","claim":"walked"}}` + "\n"
	if err := os.WriteFile(path, []byte(old), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Resume(path); !errors.Is(err, errNoOpenSegment) {
		t.Fatalf("Resume of a log with no segment_begin = %v, want errNoOpenSegment", err)
	}
}

// A cheat still in effect when a segment begins (a noclip left on) reaches it from its first call, and a
// resumed log keeps that claim rather than rebuilding the segment as walked.
func TestASegmentBegunReachedStaysReachedAcrossAResume(t *testing.T) {
	l, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	l.Begin("through the wall", "cheat:noclip (still on)")
	if cur := l.Current(); cur.Claim != "reached" || len(cur.Because) != 1 || cur.Because[0] != "cheat:noclip (still on)" {
		t.Fatalf("begun reached = %+v", cur)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}

	second, err := Resume(l.Path())
	if err != nil {
		t.Fatal(err)
	}
	if cur := second.Current(); cur.N != 2 || cur.Claim != "reached" || len(cur.Because) != 1 {
		t.Fatalf("resumed = %+v", cur)
	}
	if closed := second.Begin("on foot again"); closed.Claim != "reached" {
		t.Fatalf("closed = %+v", closed)
	}
	if cur := second.Current(); cur.Claim != "walked" || cur.Because != nil {
		t.Fatalf("a segment begun with nothing in effect = %+v", cur)
	}
	if err := second.Close(); err != nil {
		t.Fatal(err)
	}

	third, err := Resume(l.Path())
	if err != nil {
		t.Fatal(err)
	}
	if cur := third.Current(); cur.N != 3 || cur.Claim != "walked" {
		t.Fatalf("resumed = %+v", cur)
	}
	third.Close()
}

// A call made while a cheat is in effect reaches the open segment once per cause, and Resume keeps it.
func TestInEffectReachesTheOpenSegmentOncePerCause(t *testing.T) {
	l, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	l.InEffect("")
	if cur := l.Current(); cur.Claim != "walked" {
		t.Fatalf("an empty cause reached the segment: %+v", cur)
	}
	l.InEffect("cheat:noclip (still on)")
	l.InEffect("cheat:noclip (still on)")
	if cur := l.Current(); cur.Claim != "reached" || len(cur.Because) != 1 {
		t.Fatalf("after two calls with noclip on = %+v", cur)
	}
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	again, err := Resume(l.Path())
	if err != nil {
		t.Fatal(err)
	}
	if cur := again.Current(); cur.N != 1 || cur.Claim != "reached" || len(cur.Because) != 1 || cur.Because[0] != "cheat:noclip (still on)" {
		t.Fatalf("resumed = %+v", cur)
	}
	again.Close()
}
