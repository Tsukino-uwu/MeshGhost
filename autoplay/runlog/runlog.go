// Package runlog writes one session's record: every tool call, and the segments a run is divided
// into, each labelled WALKED or REACHED.
//
// The label is the play-game skill's rule turned into code: "walked to X" and "reached X" are
// different claims, and only the first says anything about the game. A segment starts walked and
// becomes reached the moment any call that changes the world by other means than play -- a cheat,
// a restored snapshot -- succeeds in it. Nobody has to remember to say so.
//
// The file is newline-delimited JSON under the runs folder, which is gitignored.
package runlog

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Segment is one labelled stretch of a run.
type Segment struct {
	N       int        `json:"n"`
	Label   string     `json:"label"`
	Claim   string     `json:"claim"` // "walked" or "reached"
	Because []string   `json:"because,omitempty"`
	Started time.Time  `json:"started"`
	Ended   *time.Time `json:"ended,omitempty"` // nil while the segment is open
}

// Log is a session's record. A nil *Log records nothing, so callers need no checks.
type Log struct {
	mu   sync.Mutex
	f    *os.File
	path string
	seg  Segment
	now  func() time.Time
}

// Open creates dir if needed and starts a new file named for the time, with segment 1 open.
func Open(dir string) (*Log, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	now := time.Now
	path := filepath.Join(dir, now().Format("2006-01-02_150405.000000")+".ndjson")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	l := &Log{f: f, path: path, now: now}
	l.seg = Segment{N: 1, Label: "start", Claim: "walked", Started: now()}
	return l, nil
}

// Path is the file being written.
func (l *Log) Path() string {
	if l == nil {
		return ""
	}
	return l.path
}

// Call records one tool call. reachedBy names what the call did to the world when it succeeds by
// other means than play ("cheat:warp", "restore"); empty for play and for reads.
func (l *Log) Call(tool string, args any, err error, reachedBy string) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	rec := map[string]any{
		"at": l.now(), "type": "call", "tool": tool, "args": args, "ok": err == nil, "segment": l.seg.N,
	}
	if err != nil {
		rec["error"] = err.Error()
	}
	if err == nil && reachedBy != "" {
		l.seg.Claim = "reached"
		l.seg.Because = append(l.seg.Because, reachedBy)
		rec["reached_by"] = reachedBy
	}
	l.write(rec)
}

// Current returns the open segment.
func (l *Log) Current() Segment {
	if l == nil {
		return Segment{}
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.seg
}

// Begin closes the open segment, records it, and opens a new one with label. It returns the closed
// segment.
func (l *Log) Begin(label string) Segment {
	if l == nil {
		return Segment{}
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	closed := l.closeLocked()
	l.seg = Segment{N: closed.N + 1, Label: label, Claim: "walked", Started: l.now()}
	return closed
}

// Close records the open segment and closes the file.
func (l *Log) Close() error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closeLocked()
	return l.f.Close()
}

func (l *Log) closeLocked() Segment {
	s := l.seg
	ended := l.now()
	s.Ended = &ended
	l.write(map[string]any{"at": ended, "type": "segment", "segment": s})
	return s
}

func (l *Log) write(rec map[string]any) {
	line, err := json.Marshal(rec)
	if err != nil {
		line = []byte(fmt.Sprintf(`{"type":"log_error","error":%q}`, err.Error()))
	}
	l.f.Write(append(line, '\n'))
}
