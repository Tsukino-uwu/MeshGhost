package core

// The replay control surface (ADR 0047, ADR 0048): one entry point for the
// mid-play actions, whoever triggers them -- a system-wide hotkey owned by
// cmd/meshghost, a replay_control message from the adapter over the bridge,
// or a test. Everything else about replays is config.

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// ReplayAction is one of the mid-play actions. The strings are the wire form
// of bridge.ReplayControl.Action and the names cmd/meshghost binds hotkeys to.
type ReplayAction string

const (
	ReplayRecordStart  ReplayAction = "record_start"
	ReplayRecordStop   ReplayAction = "record_stop"
	ReplayRecordToggle ReplayAction = "record_toggle"
	ReplaySaveLast     ReplayAction = "save_last"
	ReplayLast         ReplayAction = "replay_last"
	ReplayRestart      ReplayAction = "restart"
	ReplayRewind       ReplayAction = "rewind"
	ReplayFastForward  ReplayAction = "fast_forward"
)

// replayCmd is what a player receives on its control channel.
type replayCmd struct {
	kind    ReplayAction
	seconds int
}

// ReplayControl performs one action and returns a short account of what it
// ACTUALLY did. seconds applies to rewind and fast-forward; 0 or less means the
// configured ReplaySeek. The error is for the caller's log: nothing here is
// fatal, and an action that has nothing to act on (rewind with no replay
// playing) says so rather than failing silently.
//
// WHY IT RETURNS A DESCRIPTION AND NOT JUST AN ERROR (2026-09-04). Neither
// caller can reply: a system-wide hotkey has nobody to answer, and the bridge
// sends no acknowledgement. So the log line the caller writes is the ONLY
// feedback a player gets, and both callers used to write "done" -- identical
// whichever branch ran. A tester, on record_toggle: "at least right now I can't
// discern from the console log whether a record toggle started or stopped the
// recording". They could not, and the toggle is precisely the action where the
// same keypress means opposite things.
//
// The core DOES log a distinguishing line under each ("core: recording to ..."
// at recorder.go:543, "core: recording stopped ..." at :559/:562), so the fault
// is narrower than "no feedback": the two lines are the recorder's, phrased for
// the recorder, and the hotkey's own line sat next to them saying "done". A
// player watching for the effect of the key they just pressed read the useless
// one. Naming the outcome on the caller's line is what makes the key legible
// without having to know which neighbouring line belongs to it.
func (c *Core) ReplayControl(a ReplayAction, seconds int) (string, error) {
	switch a {
	case ReplayRecordStart:
		return c.describeStart()
	case ReplayRecordStop:
		return c.describeStop()
	case ReplayRecordToggle:
		// The SAME wording as the explicit actions, deliberately: a player
		// reading the log should not have to know which key was pressed to
		// know what happened.
		if c.Recording() {
			return c.describeStop()
		}
		return c.describeStart()
	case ReplaySaveLast:
		path, written, err := c.SaveLast()
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("SAVED %d sample(s) -> %s", written, path), nil
	case ReplayLast:
		if err := c.replayLast(); err != nil {
			return "", err
		}
		return "REPLAYING the last recording", nil
	case ReplayRestart, ReplayRewind, ReplayFastForward:
		if seconds <= 0 {
			c.mu.Lock()
			seconds = int(c.ReplaySeek / time.Second)
			c.mu.Unlock()
			if seconds <= 0 {
				seconds = 5
			}
		}
		if err := c.seekReplays(replayCmd{kind: a, seconds: seconds}); err != nil {
			return "", err
		}
		if a == ReplayRestart {
			return "RESTARTED every replay", nil
		}
		return fmt.Sprintf("%s %ds", strings.ToUpper(string(a)), seconds), nil
	default:
		return "", fmt.Errorf("unknown replay action %q", a)
	}
}

// describeStart and describeStop exist so the toggle and the explicit actions
// cannot drift into describing the same event two different ways.
func (c *Core) describeStart() (string, error) {
	path, err := c.StartRecording()
	if err != nil {
		return "", err
	}
	return "recording STARTED -> " + path, nil
}

func (c *Core) describeStop() (string, error) {
	path, written, err := c.StopRecording()
	if err != nil {
		return "", err
	}
	if written == 0 {
		return "recording STOPPED -- no in-game samples, nothing written", nil
	}
	return fmt.Sprintf("recording STOPPED -- %d sample(s) -> %s", written, path), nil
}

// seekReplays sends one command to every player. A player whose goroutine
// has finished (a non-looping clip that reached its end) is relaunched from
// the top on restart or rewind, which is what a player pressing the key
// after the ghost left expects.
func (c *Core) seekReplays(cmd replayCmd) error {
	c.replayMu.Lock()
	defer c.replayMu.Unlock()
	if len(c.replays) == 0 {
		return errors.New("no replay is loaded")
	}
	for id, p := range c.replays {
		select {
		case <-p.done:
			if cmd.kind == ReplayFastForward {
				continue
			}
			fresh := newReplayPlayer(c, id, p.clip)
			c.replays[id] = fresh
			fresh.launch()
		default:
			if !p.running() {
				// Loaded but not yet started (no in-game frame yet): a seek
				// before play means "start now", which the first frame does.
				continue
			}
			select {
			case p.ctrl <- cmd:
			default:
				// Four commands already queued: a key held down. Dropping the
				// fifth is the right answer; the ghost cannot seek faster.
			}
		}
	}
	return nil
}

// replayLast plays the newest recording in the replay folder itself (not
// active/) right now, without moving the file. Pressing it again restarts it.
func (c *Core) replayLast() error {
	if c.ReplayDir == "" {
		return errors.New("no replay folder configured")
	}
	entries, err := os.ReadDir(c.ReplayDir)
	if err != nil {
		return fmt.Errorf("replay folder: %w", err)
	}
	type cand struct {
		name string
		mod  time.Time
	}
	var cands []cand
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		lower := strings.ToLower(e.Name())
		// .zip too, since replay/active takes them and a person who put one
		// here means it. This path plays exactly ONE clip, so a zip of several
		// gives its first -- the folder is where a pack belongs.
		if !strings.HasSuffix(lower, ".ndjson") && !strings.HasSuffix(lower, ".ndjson.gz") &&
			!strings.HasSuffix(lower, ".zip") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		cands = append(cands, cand{e.Name(), info.ModTime()})
	}
	if len(cands) == 0 {
		return errors.New("no recording in the replay folder yet")
	}
	sort.Slice(cands, func(i, j int) bool { return cands[i].mod.After(cands[j].mod) })
	name := cands[0].name
	id := localPeerReplayPrefix + name

	c.replayMu.Lock()
	defer c.replayMu.Unlock()
	if p, ok := c.replays[id]; ok {
		select {
		case <-p.done:
		default:
			if p.running() {
				select {
				case p.ctrl <- replayCmd{kind: ReplayRestart}:
				default:
				}
				return nil
			}
		}
	}
	if len(c.replays) >= maxActiveReplays {
		return fmt.Errorf("%d replays are already active (the cap)", maxActiveReplays)
	}
	// FLUSH FIRST IF WE ARE READING WHAT WE ARE WRITING. The most natural
	// moment to press replay-last is mid-recording -- "let me see what I just
	// did" -- and the newest file is then the open one. parseReplay tolerates a
	// half-written final line, but flushing means the clip actually contains
	// everything up to this instant rather than everything up to the last time
	// a 64KiB buffer happened to fill.
	c.flushRecordingIfOpen()
	clip, err := loadReplay(filepath.Join(c.ReplayDir, filepath.Base(name)))
	if err != nil {
		return err
	}
	p := newReplayPlayer(c, id, clip)
	if c.replays == nil {
		c.replays = make(map[string]*replayPlayer)
	}
	c.replays[id] = p
	log.Printf("core: replay_last: playing %s now", name)
	p.launch()
	return nil
}
