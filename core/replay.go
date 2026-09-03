package core

// Playback: a recorded run as a local fake peer (ADR 0047).
//
// Every file in <ReplayDir>/active/ is loaded when the adapter attaches and
// starts playing at the player's FIRST in-game frame -- the same moment a
// recording starts -- so a ghost of a run lines up with the run. The file is
// read once into memory, each sample's timestamp is rebased into this core's
// nowMs domain (first sample at start + the file's start_delay, then at the
// recorded spacing divided by speed), and a goroutine hands each sample to
// feedLocalPeer at its due time. Everything after that is the ordinary peer
// path: buffer, interpolation, render_remote with cosmetic=true.
//
// SEAMS. The interpolation buffer blends across any gap in the same area, so
// anything that must look like a jump -- the loop's end-to-start, a recorded
// gap longer than replayGapSeamMs (a loading screen, a long menu), a gap the
// player cut out with skip_gaps -- is a leave and a rejoin: drop the peer,
// wait one render tick so the despawn reaches the adapter, admit it again.
//
// SAFETY. A file is exactly as trusted as a stranger's packets and enters by
// the same door: every sample passes protocol.ValidateState in storeRemoteState,
// the line length is capped at the wire's limit before decoding, the header's
// name and colour go through the nametag sanitizers, speed and durations are
// clamped, and nothing in a file ever becomes a path (names come from the
// directory listing). internal/gameblind fails the build if a second entry
// point for remote state appears.

import (
	"archive/zip"
	"bufio"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

const (
	// maxActiveReplays caps what replay/active/ may start: each is a roster
	// seat and an adapter render slot, and the Pokemon adapters have a small
	// fixed number of the latter.
	maxActiveReplays = 16
	// replayGapSeamMs: a recorded gap longer than this is a seam, not a
	// blend. Under the 3s stale age-out so the despawn is ours and explicit
	// rather than the age-out's a second later.
	replayGapSeamMs = 1500
	// replayMaxSamples bounds memory: a whole file is held as []State.
	// 2,000,000 samples is ~11 hours at the shipped 50Hz adapter rate.
	replayMaxSamples = 2_000_000
	replaySpeedMin   = 0.1
	replaySpeedMax   = 4.0
	replayMaxDelay   = time.Hour
	// replayBackstepMs: nowMs can step backwards when a relay session is
	// forgotten mid-replay (the clock offset resets); a step this large is
	// treated as a seam and the clip re-based, never fed out of order.
	replayBackstepMs = 500
)

// replayClip is a loaded file: the sanitized header, the samples after trim,
// and the seams skip_gaps introduced.
type replayClip struct {
	file       string // base name, for ids and logs
	header     replayHeader
	samples    []protocol.State
	t0         int64
	speed      float64
	startDelay time.Duration
	loop       bool
	forcedSeam map[int]bool // sample index -> a gap was cut before it
}

// duration returns the clip's length at speed 1.
func (rc *replayClip) duration() time.Duration {
	if len(rc.samples) == 0 {
		return 0
	}
	return time.Duration(rc.samples[len(rc.samples)-1].Timestamp-rc.t0) * time.Millisecond
}

// loadReplay reads one file: a plain .ndjson, a .ndjson.gz, or a .zip holding
// one of those.
//
// ZIP IS FOR PEOPLE, NOT FOR THE RECORDER. Nothing here ever writes one -- a
// recording ends when the game closes, and an archive cut short there is refused
// whole by every ordinary tool (ADR 0051, learned the hard way). What a player
// does with a finished clip afterwards is a different question, and zipping one
// up to send it is the obvious thing to do on Windows, so reading them costs one
// function and saves the recipient a step.
//
// No decompression bomb worry beyond what already applies: nothing is extracted
// to disk, and parseReplay bounds what it will accept by line length
// (protocol.MaxLineBytes) and sample count (replayMaxSamples) whatever the
// stream underneath claims about its size.
func loadReplay(path string) (*replayClip, error) {
	name := filepath.Base(path)
	if strings.HasSuffix(strings.ToLower(path), ".zip") {
		return loadReplayZip(path, name)
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var r io.Reader = f
	if strings.HasSuffix(strings.ToLower(path), ".gz") {
		gz, err := gzip.NewReader(f)
		if err != nil {
			return nil, fmt.Errorf("%s: not a gzip file: %w", name, err)
		}
		defer gz.Close()
		r = gz
	}
	return parseReplay(r, name)
}

// loadedClip is one clip and the name it should be known by -- the file's own
// name, or "<archive>/<entry>" for one that came out of a zip.
type loadedClip struct {
	name string
	clip *replayClip
}

// loadReplayAll reads every clip in one file. A plain .ndjson or .ndjson.gz is
// one; a zip is however many it holds.
//
// A ZIP OF THREE CLIPS IS THREE GHOSTS, which is the answer to the obvious
// question and the only one that is not a trap: replay/active/ already means
// "everything in here plays", so a zip behaves like a folder that happens to be
// one file. Taking only the first would leave someone who zipped two clips
// watching one ghost with nothing anywhere saying why.
func loadReplayAll(path string) ([]loadedClip, error) {
	name := filepath.Base(path)
	if !strings.HasSuffix(strings.ToLower(path), ".zip") {
		clip, err := loadReplay(path)
		if err != nil {
			return nil, err
		}
		return []loadedClip{{name: name, clip: clip}}, nil
	}

	zr, err := zip.OpenReader(path)
	if err != nil {
		return nil, fmt.Errorf("%s: not a zip file: %w", name, err)
	}
	defer zr.Close()

	var out []loadedClip
	// The archive's own order, not sorted: a zip made from a selection keeps
	// the order the person made it in, and StartReplays sorts the FILES it
	// found anyway. An entry that is not a clip -- a readme, a screenshot, the
	// folder itself -- is skipped rather than refused, because someone zipping
	// a clip to send it will put other things in beside it.
	for _, entry := range zr.File {
		if entry.FileInfo().IsDir() {
			continue
		}
		lower := strings.ToLower(entry.Name)
		if !strings.HasSuffix(lower, ".ndjson") && !strings.HasSuffix(lower, ".ndjson.gz") {
			continue
		}
		inner := name + "/" + filepath.Base(entry.Name)
		clip, err := readZipEntry(entry, inner)
		if err != nil {
			// One bad entry does not condemn the archive: the others still play,
			// and the log says which one was dropped.
			log.Printf("core: replay skipped: %v", err)
			continue
		}
		out = append(out, loadedClip{name: inner, clip: clip})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%s: no .ndjson inside", name)
	}
	return out, nil
}

func readZipEntry(entry *zip.File, name string) (*replayClip, error) {
	rc, err := entry.Open()
	if err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	defer rc.Close()
	var r io.Reader = rc
	if strings.HasSuffix(strings.ToLower(entry.Name), ".gz") {
		gz, err := gzip.NewReader(rc)
		if err != nil {
			return nil, fmt.Errorf("%s: not a gzip file: %w", name, err)
		}
		defer gz.Close()
		r = gz
	}
	return parseReplay(r, name)
}

// loadReplayZip reads the FIRST clip in a zip, for the one caller that plays
// exactly one file (the replay-last hotkey).
func loadReplayZip(path, name string) (*replayClip, error) {
	all, err := loadReplayAll(path)
	if err != nil {
		return nil, err
	}
	return all[0].clip, nil
}

// parseReplay is loadReplay on a stream, and the fuzz target's entry.
func parseReplay(r io.Reader, name string) (*replayClip, error) {
	sc := bufio.NewScanner(r)
	// The wire's own line cap, applied BEFORE decoding: a longer line is
	// refused, never allocated for.
	sc.Buffer(make([]byte, 0, 4096), protocol.MaxLineBytes)

	if !sc.Scan() {
		if err := sc.Err(); err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		return nil, fmt.Errorf("%s: empty file", name)
	}
	var hdr replayHeader
	if err := json.Unmarshal(sc.Bytes(), &hdr); err != nil {
		return nil, fmt.Errorf("%s: line 1 is not a replay header: %w", name, err)
	}
	if hdr.Format == 0 {
		return nil, fmt.Errorf("%s: line 1 has no meshghost_replay key -- not a replay file", name)
	}
	if hdr.Format > replayFormatVersion {
		// Latest version assumed; an older reader plays what it understands.
		log.Printf("core: replay %s is format %d, this build reads %d -- playing what it understands", name, hdr.Format, replayFormatVersion)
	}

	clip := &replayClip{file: name, forcedSeam: map[int]bool{}}
	clip.header = sanitizeReplayHeader(hdr)
	clip.speed = clip.header.Speed
	clip.loop = clip.header.Loop
	clip.startDelay = parseReplayDuration(clip.header.StartDelay)

	// DELTA FILES CARRY ONLY WHAT CHANGED (recorder.go's extrasDelta): every
	// key absent from a sample's extras means "same as the line before", and an
	// explicit null means "this key went away". Reconstructed HERE, before
	// validation, so everything downstream -- ValidateState, the fuzz target,
	// every render -- sees exactly the samples a non-delta file would produce.
	//
	// Note a hand-edited file stays consistent: deleting a line loses that
	// line's changes and nothing else, because the carry-forward is a running
	// value rather than a back-reference to a particular line.
	var carried map[string]any
	line := 1
	for sc.Scan() {
		line++
		raw := sc.Bytes()
		if len(strings.TrimSpace(string(raw))) == 0 {
			continue
		}
		var st protocol.State
		if err := json.Unmarshal(raw, &st); err != nil {
			// A HALF-WRITTEN LAST LINE IS NOT A BROKEN FILE. The recorder's
			// buffer flushes whenever it fills, which lands mid-line, so a
			// recording read while it is still being written -- the replay-last
			// hotkey pressed without stopping first -- ends in a partial line.
			// So does one whose process was killed. Refusing the whole clip for
			// it threw away everything that WAS written, which is the same
			// mistake gzip made (ADR 0051): a plain text file cut short should
			// still play what it has.
			//
			// Only the LAST line, and only a decode failure. A bad line with
			// anything after it is a corrupt file and still refused, which is
			// what keeps this from being a licence to accept garbage.
			if !sc.Scan() {
				log.Printf("core: replay %s: line %d is incomplete and was dropped -- the file was "+
					"still being written, or the game that wrote it did not close it", name, line)
				break
			}
			return nil, fmt.Errorf("%s: line %d: %w", name, line, err)
		}
		st.PlayerID = ""
		st.Prev = nil
		if hdr.Delta {
			st.Extras = mergeCarriedExtras(carried, st.Extras)
			carried = st.Extras
		}
		// The same caps a relay packet meets, and here they are also what
		// keeps a hand-edited file from ever reaching the adapter malformed.
		if !protocol.ValidateState(st) {
			return nil, fmt.Errorf("%s: line %d: %s", name, line, protocol.StateRejectReason(st))
		}
		if len(clip.samples) > 0 && st.Timestamp < clip.samples[len(clip.samples)-1].Timestamp {
			return nil, fmt.Errorf("%s: line %d: timestamp %d goes backwards (previous %d)", name, line, st.Timestamp, clip.samples[len(clip.samples)-1].Timestamp)
		}
		if len(clip.samples) >= replayMaxSamples {
			return nil, fmt.Errorf("%s: more than %d samples", name, replayMaxSamples)
		}
		clip.samples = append(clip.samples, st)
	}
	if err := sc.Err(); err != nil {
		if errors.Is(err, bufio.ErrTooLong) {
			return nil, fmt.Errorf("%s: line %d is longer than %d bytes", name, line+1, protocol.MaxLineBytes)
		}
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	if len(clip.samples) == 0 {
		return nil, fmt.Errorf("%s: header only, no samples", name)
	}

	clip.applyTrim()
	clip.applySkipGaps()
	if len(clip.samples) == 0 {
		return nil, fmt.Errorf("%s: trim left no samples", name)
	}
	clip.t0 = clip.samples[0].Timestamp
	return clip, nil
}

// mergeCarriedExtras applies one delta line's extras onto the running value.
// A nil result stays nil rather than becoming an empty map, so a clip whose
// game sends no extras at all is byte-identical to what it always was.
func mergeCarriedExtras(carried, delta map[string]any) map[string]any {
	if len(carried) == 0 {
		return delta
	}
	if len(delta) == 0 {
		return carried
	}
	out := make(map[string]any, len(carried)+len(delta))
	for k, v := range carried {
		out[k] = v
	}
	for k, v := range delta {
		if v == nil {
			// An explicit null is the key going AWAY, which is why the writer
			// spends a null on it: absence already means "unchanged".
			delete(out, k)
			continue
		}
		out[k] = v
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// sanitizeReplayHeader clamps every player-editable key. The recorder-written
// keys are passed through: they are read for a warning and nothing else.
func sanitizeReplayHeader(h replayHeader) replayHeader {
	h.Name = protocol.SanitizeDisplayName(h.Name)
	h.Color = protocol.SanitizeNameColor(h.Color)
	if h.Speed == 0 || math.IsNaN(h.Speed) || math.IsInf(h.Speed, 0) {
		h.Speed = 1.0
	}
	h.Speed = math.Min(math.Max(h.Speed, replaySpeedMin), replaySpeedMax)
	switch h.Anchor {
	case "launch", "start", "area":
	default:
		h.Anchor = "launch"
	}
	if h.AnchorRadius <= 0 || math.IsNaN(h.AnchorRadius) || math.IsInf(h.AnchorRadius, 0) {
		h.AnchorRadius = 1.0
	}
	h.StartDelay = parseReplayDuration(h.StartDelay).String()
	h.TrimEnd = parseReplayDuration(h.TrimEnd).String()
	h.SkipGaps = parseReplayDuration(h.SkipGaps).String()
	if h.TrimStart != "auto" {
		h.TrimStart = parseReplayDuration(h.TrimStart).String()
	}
	return h
}

// parseReplayDuration is time.ParseDuration clamped to [0, replayMaxDelay];
// anything unparseable is 0.
func parseReplayDuration(s string) time.Duration {
	d, err := time.ParseDuration(strings.TrimSpace(s))
	if err != nil || d < 0 {
		return 0
	}
	if d > replayMaxDelay {
		return replayMaxDelay
	}
	return d
}

// applyTrim drops samples before trim_start (or, for "auto", before the
// position first changes) and after the last sample minus trim_end.
func (rc *replayClip) applyTrim() {
	n := len(rc.samples)
	first := rc.samples[0].Timestamp
	last := rc.samples[n-1].Timestamp
	start := 0
	if rc.header.TrimStart == "auto" {
		for start+1 < n && samePosition(rc.samples[start].Position, rc.samples[start+1].Position) {
			start++
		}
	} else if d := parseReplayDuration(rc.header.TrimStart); d > 0 {
		cut := first + d.Milliseconds()
		for start < n && rc.samples[start].Timestamp < cut {
			start++
		}
	}
	end := n
	if d := parseReplayDuration(rc.header.TrimEnd); d > 0 {
		cut := last - d.Milliseconds()
		for end > start && rc.samples[end-1].Timestamp > cut {
			end--
		}
	}
	rc.samples = rc.samples[start:end]
}

// applySkipGaps collapses every gap longer than skip_gaps to one millisecond
// and marks a forced seam there, so cut time is a jump and never a blend.
func (rc *replayClip) applySkipGaps() {
	d := parseReplayDuration(rc.header.SkipGaps)
	if d <= 0 || len(rc.samples) < 2 {
		return
	}
	limit := d.Milliseconds()
	var shift int64
	prevOrig := rc.samples[0].Timestamp
	for i := 1; i < len(rc.samples); i++ {
		orig := rc.samples[i].Timestamp
		gap := orig - prevOrig
		prevOrig = orig
		if gap > limit {
			shift += gap - 1
			rc.forcedSeam[i] = true
		}
		rc.samples[i].Timestamp = orig - shift
	}
}

// replayPlayer feeds one clip as one local peer.
type replayPlayer struct {
	c    *Core
	id   string
	clip *replayClip
	stop chan struct{}
	once sync.Once
	done chan struct{}
	// ctrl carries seeks from ReplayControl (restart, rewind, fast-forward);
	// buffered so a key held down never blocks the caller.
	ctrl    chan replayCmd
	started uint32

	split splitState

	mu        sync.Mutex
	startedAt int64 // nowMs at which clip time 0 is due, for the current lap
	idx       int   // the last sample fed
	laps      int
}

func newReplayPlayer(c *Core, id string, clip *replayClip) *replayPlayer {
	return &replayPlayer{c: c, id: id, clip: clip, stop: make(chan struct{}), done: make(chan struct{}), ctrl: make(chan replayCmd, 4)}
}

// launch starts the goroutine exactly once.
func (p *replayPlayer) launch() {
	if atomic.CompareAndSwapUint32(&p.started, 0, 1) {
		go p.run()
	}
}

func (p *replayPlayer) running() bool {
	return atomic.LoadUint32(&p.started) == 1
}

func (p *replayPlayer) halt() {
	p.once.Do(func() { close(p.stop) })
}

func (p *replayPlayer) stopped() bool {
	select {
	case <-p.stop:
		return true
	default:
		return false
	}
}

// sleepUntil waits for the clock to reach due, in slices short enough that a
// stop or a seek is noticed promptly and a goroutine stall can never approach
// the stale age-out. Returns a command if one arrived first; stopped=true
// means the player was halted.
func (p *replayPlayer) sleepUntil(due int64) (cmd *replayCmd, stopped bool) {
	for {
		if p.stopped() {
			return nil, true
		}
		select {
		case c := <-p.ctrl:
			return &c, false
		default:
		}
		now := p.c.nowMs()
		if now >= due {
			return nil, false
		}
		wait := time.Duration(due-now) * time.Millisecond
		if wait > 50*time.Millisecond {
			wait = 50 * time.Millisecond
		}
		select {
		case <-p.stop:
			return nil, true
		case c := <-p.ctrl:
			return &c, false
		case <-time.After(wait): // wall-clock: the SLEEP; its due time comes from nowMs, which is virtual
		}
	}
}

// seam is the leave-and-rejoin that makes a discontinuity a jump.
func (p *replayPlayer) seam(tag protocol.Nametag) bool {
	p.c.dropLocalPeer(p.id)
	// One render tick that BEGAN after the drop carries the despawn (see
	// ticksBegun). Bounded: an adapter in a menu sends no frames, and a
	// replay must not hang on it.
	p.c.awaitTick(p.c.ticksBegun(), 500*time.Millisecond, p.stop)
	if p.stopped() {
		return false
	}
	return p.c.admitLocalPeer(p.id, tag)
}

func (p *replayPlayer) run() {
	defer close(p.done)
	defer p.c.dropLocalPeer(p.id)
	clip := p.clip
	tag := protocol.Nametag{Name: clip.header.Name, Color: clip.header.Color}
	if !p.c.admitLocalPeer(p.id, tag) {
		log.Printf("core: replay %s: the roster is full, not playing", clip.file)
		return
	}
	delay := clip.startDelay
	if delay == 0 {
		p.c.mu.Lock()
		delay = p.c.ReplayStartDelay
		p.c.mu.Unlock()
	}
	durMs := clip.duration().Milliseconds()
	start := p.c.nowMs() + delay.Milliseconds()
	log.Printf("core: replay %s: %d samples, %s at %.2gx, starting in %s%s", clip.file, len(clip.samples),
		clip.duration().Round(time.Millisecond), clip.speed, delay, map[bool]string{true: ", looping", false: ""}[clip.loop])
	setStart := func(v int64) {
		start = v
		p.mu.Lock()
		p.startedAt = v
		p.mu.Unlock()
		// A new start is a new race: the split match is searched afresh.
		p.splitReset()
	}
	setStart(start)

	// indexAt is the first sample at or after a clip time.
	indexAt := func(posMs int64) int {
		i := sort.Search(len(clip.samples), func(k int) bool { return clip.samples[k].Timestamp-clip.t0 >= posMs })
		if i >= len(clip.samples) {
			i = len(clip.samples) - 1
		}
		return i
	}
	// seek applies a control command: the ghost jumps to the new clip time
	// through a seam. false means the clip is over (fast-forward past the end
	// of a non-looping clip).
	seek := func(cmd *replayCmd, i *int) bool {
		now := p.c.nowMs()
		pos := int64(float64(now-start) * clip.speed)
		switch cmd.kind {
		case ReplayRestart:
			pos = 0
		case ReplayRewind:
			pos -= int64(cmd.seconds) * 1000
		case ReplayFastForward:
			pos += int64(cmd.seconds) * 1000
		}
		if pos < 0 {
			pos = 0
		}
		if pos > durMs {
			if !clip.loop {
				log.Printf("core: replay %s: fast-forwarded past the end", clip.file)
				return false
			}
			pos = 0
		}
		setStart(now - int64(float64(pos)/clip.speed))
		*i = indexAt(pos)
		log.Printf("core: replay %s: %s -> %s into the clip", clip.file, cmd.kind, (time.Duration(pos) * time.Millisecond).Round(time.Millisecond))
		return p.seam(tag)
	}

	prevNow := p.c.nowMs()
	i := 0
	for {
		if i >= len(clip.samples) {
			if !clip.loop {
				// Hold the last sample long enough to be rendered: the buffer
				// renders LocalInterpolationDelay behind for a ghost this core
				// invented (remoteStatesAt), and the deferred drop would
				// otherwise despawn the ghost before its final position was
				// drawn. A seek during the hold still works.
				//
				// The NETWORK delay was read here until 2026-09-03, which held
				// a finished clip frozen on its finish line for 425ms longer
				// than it had any reason to.
				p.c.mu.Lock()
				hold := p.c.LocalInterpolationDelay
				p.c.mu.Unlock()
				cmd, stopped := p.sleepUntil(p.c.nowMs() + hold.Milliseconds() + 1)
				if stopped {
					return
				}
				if cmd != nil {
					if !seek(cmd, &i) {
						return
					}
					continue
				}
				p.c.awaitTick(p.c.ticksBegun(), 500*time.Millisecond, p.stop)
				log.Printf("core: replay %s: finished", clip.file)
				return
			}
			if !p.seam(tag) {
				return
			}
			setStart(p.c.nowMs())
			p.mu.Lock()
			p.laps++
			p.mu.Unlock()
			i = 0
			continue
		}
		s := clip.samples[i]
		if i > 0 && (clip.forcedSeam[i] || s.Timestamp-clip.samples[i-1].Timestamp > replayGapSeamMs) {
			if !p.seam(tag) {
				return
			}
		}
		due := start + int64(float64(s.Timestamp-clip.t0)/clip.speed)
		cmd, stopped := p.sleepUntil(due)
		if stopped {
			return
		}
		if cmd != nil {
			if !seek(cmd, &i) {
				return
			}
			continue
		}
		now := p.c.nowMs()
		if now < prevNow-replayBackstepMs {
			// The clock stepped back (a relay session reset mid-replay):
			// re-base so this sample is due now, and make it a seam so the
			// buffer never sees time run backwards.
			setStart(now - (due - start))
			due = now
			if !p.seam(tag) {
				return
			}
		}
		prevNow = now
		st := s
		st.Timestamp = due
		if !p.c.feedLocalPeer(p.id, st) {
			// Dropped from outside (StopReplays) or refused by a full roster
			// after a reconnect. Either way this lap is over.
			if p.stopped() {
				return
			}
			log.Printf("core: replay %s: sample refused (roster full?), stopping", clip.file)
			return
		}
		p.mu.Lock()
		p.idx = i
		p.mu.Unlock()
		i++
	}
}

// StartReplays loads every file in <ReplayDir>/active/ and arms them to start
// at the player's first in-game frame. Called when the adapter attaches; safe
// to call again (running players are stopped first). Returns how many loaded.
func (c *Core) StartReplays() int {
	c.StopReplays()
	if c.ReplayDir == "" {
		return 0
	}
	dir := filepath.Join(c.ReplayDir, "active")
	entries, err := os.ReadDir(dir)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("core: replay folder %s: %v", dir, err)
		}
		return 0
	}
	c.mu.Lock()
	game := c.adapterGameID
	if game == "" {
		game = c.relayGame
	}
	c.mu.Unlock()

	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		lower := strings.ToLower(e.Name())
		if strings.HasSuffix(lower, ".ndjson") || strings.HasSuffix(lower, ".ndjson.gz") ||
			strings.HasSuffix(lower, ".zip") {
			names = append(names, e.Name())
		}
		if strings.HasSuffix(lower, ".7z") || strings.HasSuffix(lower, ".rar") {
			// Said out loud rather than skipped in silence: a player who put one
			// here is watching for a ghost that will never come, and the fix is
			// one right-click away.
			log.Printf("core: replay %s ignored: only .ndjson, .ndjson.gz and .zip are read -- re-zip it as .zip", e.Name())
		}
	}
	sort.Strings(names)

	c.replayMu.Lock()
	defer c.replayMu.Unlock()
	for _, name := range names {
		if len(c.replays) >= maxActiveReplays {
			log.Printf("core: replay %s skipped: %d replays are already active (the cap)", name, maxActiveReplays)
			continue
		}
		// filepath.Join of the LISTING's own name, cleaned: nothing inside a
		// file ever chooses a path, and a listing entry cannot escape dir.
		path := filepath.Join(dir, filepath.Base(name))
		loaded, err := loadReplayAll(path)
		if err != nil {
			log.Printf("core: replay skipped: %v", err)
			continue
		}
		for _, lc := range loaded {
			name, clip := lc.name, lc.clip
			if len(c.replays) >= maxActiveReplays {
				log.Printf("core: replay %s skipped: %d replays are already active (the cap)", name, maxActiveReplays)
				continue
			}
			if game != "" && clip.header.Game != "" && clip.header.Game != game {
				log.Printf("core: replay %s skipped: recorded for game %q, this is %q", name, clip.header.Game, game)
				continue
			}
			if clip.header.Game == "" && game != "" {
				log.Printf("core: replay %s names no game; assuming it is for %q", name, game)
			}
			id := localPeerReplayPrefix + name
			p := newReplayPlayer(c, id, clip)
			if c.replays == nil {
				c.replays = make(map[string]*replayPlayer)
			}
			c.replays[id] = p
		}
	}
	n := len(c.replays)
	if n > 0 {
		atomic.StoreUint32(&c.replaysPending, 1)
		log.Printf("core: %d replay(s) loaded from %s -- they start at your first in-game frame", n, dir)
	}
	return n
}

// launchPendingReplays is the hook forwardLocalState calls on every non-nil
// frame: one atomic load, and on the first frame after StartReplays every
// loaded player starts its goroutine.
func (c *Core) launchPendingReplays() {
	if !atomic.CompareAndSwapUint32(&c.replaysPending, 1, 0) {
		return
	}
	c.replayMu.Lock()
	defer c.replayMu.Unlock()
	for _, p := range c.replays {
		p.launch()
	}
}

// StopReplays halts every player and drops its ghost. Called when the adapter
// detaches, so a relaunched game starts every replay from the top.
func (c *Core) StopReplays() {
	atomic.StoreUint32(&c.replaysPending, 0)
	c.replayMu.Lock()
	players := c.replays
	c.replays = nil
	c.replayMu.Unlock()
	for _, p := range players {
		p.halt()
	}
	for _, p := range players {
		if p.running() {
			select {
			case <-p.done:
			case <-time.After(time.Second): // wall-clock: a shutdown join -- virtual would turn a leak into a hang
			}
		}
		c.dropLocalPeer(p.id)
	}
}

// ActiveReplays is how many replays are loaded or playing.
func (c *Core) ActiveReplays() int {
	c.replayMu.Lock()
	defer c.replayMu.Unlock()
	return len(c.replays)
}
