// Package session is the unattended session loop's library (Phase 3): what a headless Claude Code session may
// run with, how its model calls are counted from its stream, what its run log says it did, and the report.
//
// The loop runs on the user's Claude subscription only (the user, 2026-09-17): never an API key, never API billing,
// never a dollar figure in a report. See CheckEnv.
package session

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/runlog"
)

// Stops are the outcome words a report counts as a program stopping short: a driver's (`stuck`, `no_response`,
// `unreachable`, `blocked`, `needs_choice`) and a skill's (`no_rule`, `max_calls`, `tool_error`, `stopped`).
var Stops = map[string]bool{
	"stuck": true, "no_response": true, "unreachable": true, "blocked": true, "needs_choice": true,
	"no_rule": true, "max_calls": true, "tool_error": true, "stopped": true,
}

// RunSummary is what a run log says happened from one segment on.
type RunSummary struct {
	Segments []runlog.Segment `json:"segments"`
	// Calls counts every call by tool, status left out: mcpcall and a client waiting for the driver poll it.
	Calls      map[string]int `json:"calls"`
	TotalCalls int            `json:"total_calls"`
	Refused    int            `json:"refused"`
	// Outcomes counts each call's outcome word; Stops the ones that stopped short, by word.
	Outcomes map[string]int `json:"outcomes"`
	Stops    map[string]int `json:"stops"`
	// ReachedBy lists every cheat, restore or exec that reached a segment, in order, with its segment.
	ReachedBy []string `json:"reached_by"`
}

// SummarizeRunLog reads a run log's segments numbered from to to (both included; to 0 for every one after from).
func SummarizeRunLog(path string, from, to int) (RunSummary, error) {
	s := RunSummary{Calls: map[string]int{}, Outcomes: map[string]int{}, Stops: map[string]int{}}
	f, err := os.Open(path)
	if err != nil {
		return s, err
	}
	defer f.Close()
	open := map[int]int{} // segment number -> index in Segments
	br := bufio.NewReaderSize(f, runlog.MaxRecordBytes)
	for {
		line, err := br.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			return s, fmt.Errorf("a record over %d bytes", runlog.MaxRecordBytes)
		}
		if len(line) > 1 {
			var rec struct {
				Type       string          `json:"type"`
				Tool       string          `json:"tool"`
				OK         bool            `json:"ok"`
				Outcome    string          `json:"outcome"`
				ReachedBy  string          `json:"reached_by"`
				SessionEnd bool            `json:"session_end"`
				Segment    json.RawMessage `json:"segment"`
			}
			if jerr := json.Unmarshal(line, &rec); jerr != nil {
				return s, fmt.Errorf("a record that does not parse: %w", jerr)
			}
			var seg runlog.Segment
			var n int
			isSeg := json.Unmarshal(rec.Segment, &seg) == nil && seg.N > 0
			if !isSeg {
				json.Unmarshal(rec.Segment, &n)
			} else {
				n = seg.N
			}
			if n >= from && (to == 0 || n <= to) {
				switch rec.Type {
				case "segment_begin":
					open[n] = len(s.Segments)
					s.Segments = append(s.Segments, seg)
				case "segment":
					// A core stopping writes its open segment with session_end; the segment carries on in the next core.
					if i, ok := open[n]; ok && !rec.SessionEnd {
						s.Segments[i] = seg
					} else if ok {
						s.Segments[i].Claim, s.Segments[i].Because = seg.Claim, seg.Because
					}
				case "in_effect":
					if i, ok := open[n]; ok && rec.ReachedBy != "" {
						s.Segments[i].Claim = "reached"
						s.ReachedBy = append(s.ReachedBy, fmt.Sprintf("segment %d: %s", n, rec.ReachedBy))
					}
				case "call":
					if rec.Tool == "status" {
						break
					}
					s.Calls[rec.Tool]++
					s.TotalCalls++
					if !rec.OK {
						s.Refused++
					}
					if rec.Outcome != "" {
						s.Outcomes[rec.Outcome]++
						if Stops[rec.Outcome] {
							s.Stops[rec.Outcome]++
						}
					}
					if rec.ReachedBy != "" {
						s.ReachedBy = append(s.ReachedBy, fmt.Sprintf("segment %d: %s", n, rec.ReachedBy))
						if i, ok := open[n]; ok {
							s.Segments[i].Claim = "reached"
						}
					}
				}
			}
		}
		if err != nil {
			break
		}
	}
	sort.SliceStable(s.Segments, func(i, j int) bool { return s.Segments[i].N < s.Segments[j].N })
	return s, nil
}
