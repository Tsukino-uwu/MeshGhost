package core

// The replay control surface: one entry point for the mid-play actions, whoever triggers them (a system-wide hotkey
// owned by cmd/meshghost, a replay_control message from the adapter, a test). Everything else about replays is config.

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

// ReplayAction is one of the mid-play actions. The strings are the wire form of bridge.ReplayControl.Action and the
// names cmd/meshghost binds hotkeys to.
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

// ReplayControl performs one action and returns a short account of what it actually did. seconds applies to rewind
// and fast-forward; 0 or less means the configured ReplaySeek. Nothing here is fatal, and an action with nothing to
// act on says so. A description, not just an error, because neither caller can reply: the line the caller logs is the
// only feedback a player gets, and the toggle is where one keypress means opposite things.
func (c *Core) ReplayControl(a ReplayAction, seconds int) (string, error) {
	switch a {
	case ReplayRecordStart:
		return c.describeStart()
	case ReplayRecordStop:
		return c.describeStop()
	case ReplayRecordToggle:
		// The same wording as the explicit actions, so the log does not depend on which key was pressed.
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

// describeStart and describeStop exist so the toggle and the explicit actions cannot describe one event two ways.
func (c *Core) describeStart() (string, error) {
	path, err := c.StartRecording()
	if err != nil {
		return "", err
	}
	msg := "recording STARTED -> " + path
	// This sentence is the key's only feedback, so it says whether the input half armed too.
	if ipath, _, on := c.inputTrackProgress(); on {
		msg += " (+ inputs -> " + ipath + ")"
	}
	return msg, nil
}

func (c *Core) describeStop() (string, error) {
	// Read before stopping: StopRecording closes the input track too and reports only the state half's numbers.
	ipath, iwritten, ion := c.inputTrackProgress()
	path, written, err := c.StopRecording()
	if err != nil {
		return "", err
	}
	inputs := ""
	if ion {
		if iwritten == 0 {
			inputs = " (no inputs recorded)"
		} else {
			inputs = fmt.Sprintf(" (+ %d input edge(s) -> %s)", iwritten, ipath)
		}
	}
	if written == 0 {
		return "recording STOPPED -- no in-game samples, nothing written" + inputs, nil
	}
	return fmt.Sprintf("recording STOPPED -- %d sample(s) -> %s%s", written, path, inputs), nil
}

// seekReplays sends one command to every replay player. One whose clip has ended is relaunched from the top on restart
// or rewind, which is what pressing the key after the ghost left means.
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
				// Not started yet (no in-game frame): the first frame starts it, as a seek before play means.
				continue
			}
			select {
			case p.ctrl <- cmd:
			default:
				// A full queue is a key held down; the ghost cannot seek faster, so this one is dropped.
			}
		}
	}
	return nil
}

// replayLast plays the newest recording in the replay folder itself (not active/) now, without moving the file.
// Pressing it again restarts it.
func (c *Core) replayLast() error {
	if c.replayDir() == "" {
		return errors.New("no replay folder configured")
	}
	entries, err := os.ReadDir(c.replayDir())
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
		// A .zip too, as replay/active takes them; this path plays one clip, so a zip of several gives its first.
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
	c.pruneFinishedReplaysLocked()
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
	// The newest file may be the recording still open, so flush it: the clip then holds everything up to now, not up to
	// the last time a 64KiB buffer filled.
	c.flushRecordingIfOpen()
	// Read before the load: a zip attaches its track at parse time, which the clip.track == nil test below cannot gate.
	c.mu.Lock()
	wantTracks := c.adapterWantsInputTracks
	c.mu.Unlock()
	clip, err := loadReplay(filepath.Join(c.replayDir(), filepath.Base(name)), wantTracks)
	if err != nil {
		return err
	}
	// The newest recording's track is often still being written; flushRecordingIfOpen flushed it with the clip.
	if wantTracks && clip.track == nil && clip.header.RecordingID != "" {
		c.attachTrackFromIndex(clip, name, c.inputTrackIndex())
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
