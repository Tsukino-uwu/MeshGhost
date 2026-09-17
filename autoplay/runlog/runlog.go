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
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
	l.write(map[string]any{"at": l.seg.Started, "type": "segment_begin", "segment": l.seg})
	return l, nil
}

// MaxRecordBytes bounds one line Resume will read back; a record is a tool call's arguments at most.
const MaxRecordBytes = 1 << 20

// Resume reopens a run log a previous core wrote and carries on its open segment -- the one begun last --
// with the label it was given and the claim its calls earned. mcpcall starts a core per invocation, so
// without this one run would be split across as many files, each starting a new walked segment. A core
// that stops closes the segment only for itself (a segment record with session_end), which Resume undoes.
func Resume(path string) (*Log, error) {
	in, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	seg, err := openSegment(in)
	in.Close()
	if err != nil {
		return nil, fmt.Errorf("resume %s: %w", path, err)
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	l := &Log{f: f, path: path, now: time.Now, seg: seg}
	l.write(map[string]any{"at": l.now(), "type": "session_resume", "segment": seg.N})
	return l, nil
}

// errNoOpenSegment is a log with no segment_begin record, or whose last segment was closed by Begin.
var errNoOpenSegment = errors.New("no open segment to carry on (a log written before segments were begun in it?)")

func openSegment(r io.Reader) (Segment, error) {
	var seg *Segment
	br := bufio.NewReaderSize(r, MaxRecordBytes)
	for {
		line, err := br.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			return Segment{}, fmt.Errorf("a record over %d bytes", MaxRecordBytes)
		}
		if len(line) > 0 {
			var rec struct {
				Type       string          `json:"type"`
				Segment    json.RawMessage `json:"segment"`
				ReachedBy  string          `json:"reached_by"`
				SessionEnd bool            `json:"session_end"`
			}
			if jerr := json.Unmarshal(line, &rec); jerr != nil {
				return Segment{}, fmt.Errorf("a record that does not parse: %w", jerr)
			}
			switch rec.Type {
			case "segment_begin":
				var s Segment
				if jerr := json.Unmarshal(rec.Segment, &s); jerr != nil {
					return Segment{}, fmt.Errorf("a segment_begin record: %w", jerr)
				}
				// A segment begins walked unless it began reached by something already in effect.
				if s.Claim != "reached" || len(s.Because) == 0 {
					s.Claim, s.Because = "walked", nil
				}
				s.Ended = nil
				seg = &s
			case "call", "in_effect":
				var n int
				if seg != nil && rec.ReachedBy != "" && json.Unmarshal(rec.Segment, &n) == nil && n == seg.N {
					seg.Claim = "reached"
					seg.Because = append(seg.Because, rec.ReachedBy)
				}
			case "segment":
				var s Segment
				if seg != nil && !rec.SessionEnd && json.Unmarshal(rec.Segment, &s) == nil && s.N == seg.N {
					seg = nil
				}
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return Segment{}, err
		}
	}
	if seg == nil {
		return Segment{}, errNoOpenSegment
	}
	return *seg, nil
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
	l.CallOutcome(tool, args, err, reachedBy, "")
}

// CallOutcome is Call with the answer's outcome, the word a program ends on ("done", "stuck"), when it has one: a
// session's report counts the stops from the log without reading any answer.
func (l *Log) CallOutcome(tool string, args any, err error, reachedBy, outcome string) {
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
	if outcome != "" {
		rec["outcome"] = outcome
	}
	if err == nil && reachedBy != "" {
		l.seg.Claim = "reached"
		l.seg.Because = append(l.seg.Because, reachedBy)
		rec["reached_by"] = reachedBy
	}
	l.write(rec)
}

// InEffect marks the open segment reached by something already in effect when a call is made (a cheat left on),
// once per cause: a segment opened before the driver said so, or carried on by Resume, is reached all the same.
func (l *Log) InEffect(by string) {
	if l == nil || by == "" {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, b := range l.seg.Because {
		if b == by {
			return
		}
	}
	l.seg.Claim = "reached"
	l.seg.Because = append(l.seg.Because, by)
	l.write(map[string]any{"at": l.now(), "type": "in_effect", "segment": l.seg.N, "reached_by": by})
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
// segment. reachedBy, when given, names what already holds at the start (a cheat still in effect), and
// the new segment begins reached by it.
func (l *Log) Begin(label string, reachedBy ...string) Segment {
	if l == nil {
		return Segment{}
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	closed := l.closeLocked(false)
	l.seg = Segment{N: closed.N + 1, Label: label, Claim: "walked", Started: l.now()}
	if len(reachedBy) > 0 {
		l.seg.Claim, l.seg.Because = "reached", append([]string(nil), reachedBy...)
	}
	l.write(map[string]any{"at": l.seg.Started, "type": "segment_begin", "segment": l.seg})
	return closed
}

// Close records the open segment as it stands when this core stops (session_end: Resume carries it on)
// and closes the file.
func (l *Log) Close() error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.closeLocked(true)
	return l.f.Close()
}

func (l *Log) closeLocked(sessionEnd bool) Segment {
	s := l.seg
	ended := l.now()
	s.Ended = &ended
	rec := map[string]any{"at": ended, "type": "segment", "segment": s}
	if sessionEnd {
		rec["session_end"] = true
	}
	l.write(rec)
	return s
}

func (l *Log) write(rec map[string]any) {
	line, err := json.Marshal(rec)
	if err != nil {
		line = []byte(fmt.Sprintf(`{"type":"log_error","error":%q}`, err.Error()))
	}
	l.f.Write(append(line, '\n'))
}
