package core

// The input recorder: what the player PRESSED, as a track of its own (ADR 0056).
//
// A SECOND TRACK, never a field on state. The state recording beside this one
// (recorder.go) reproduces the fields we sync; an input track records what the
// player actually did, which stays true however the sync changes later. They are
// independent files, correlated by a shared recording_id and by a timestamp in
// the same clock domain, and either may exist without the other.
//
// EDGES, NOT SAMPLES. A button is written when it goes down and when it comes
// up, so a one-frame press is two lines with consecutive `f` and no rate limit
// anywhere can erase it. That is also why there is no delta encoding here: the
// edge encoding IS the delta, and a line is four integers.
//
// THE CORE READS NONE OF IT. A mask is an integer compared to the previous one
// for equality; labels, axis names and the source tag are strings copied into
// the file header and never read back. The adapter names its own buttons, which
// is the split that keeps this side blind -- see bridge.InputSample.
//
// NOTHING PLAYS ONE BACK. This slice records only. Driving a ghost from inputs
// is a later, per-game ADR blocked on determinism; driving the LOCAL player is
// forbidden in anything that ships.

import (
	"bufio"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// inputFormatVersion is the value of the header's meshghost_inputs key. Same
// rule as replayFormatVersion: bumped only if a reader could not make sense of
// an older file at all, and adding keys does not bump it.
const inputFormatVersion = 1

// inputsSubdir is where every input track is written, and it is a SUBDIRECTORY
// of the replay folder for a specific safety reason rather than for tidiness.
//
// replayLast plays the newest FILE in ReplayDir itself, and StartReplays reads
// everything in ReplayDir/active/. An input track in either would be picked up
// and parsed as a clip. replayLast skips directories outright, so a subfolder is
// invisible to both -- pinned by TestReplayScannersIgnoreTheInputTrack rather
// than by this comment.
const inputsSubdir = "inputs"

// inputHeader is the first line of an input track.
//
// Format is FIRST and is spelled meshghost_inputs, never meshghost_replay:
// parseReplay refuses a header whose meshghost_replay key is absent, so a track
// that somebody hand-copies up into the replay folder is refused with a sentence
// instead of being misplayed as a clip.
type inputHeader struct {
	Format int `json:"meshghost_inputs"`
	// RecordingID is the state recording's own base filename, when one was
	// running -- the correlation between the two tracks. Empty is normal and
	// correct: the ring runs with no state recording at all, and then there is
	// nothing to correlate to yet.
	RecordingID string `json:"recording_id,omitempty"`
	// Source, Labels and Axes are the adapter's, copied verbatim and never
	// read. Labels names bit 0..n-1 of every line's `m`; Axes names the slots
	// of `ax`. They make the file self-describing, which is what lets a reader
	// built later refuse a track it does not understand instead of trusting
	// bits that mean something else.
	Source string   `json:"source,omitempty"`
	Labels []string `json:"labels,omitempty"`
	Axes   []string `json:"axes,omitempty"`

	Game            string `json:"game"`
	GameVersion     string `json:"game_version"`
	ProtocolVersion int    `json:"protocol_version"`
	Recorded        string `json:"recorded"`
}

// inputEdgeLine is one written line: an edge, plus the core's own stamp.
//
// Ts is this core's clock, the same domain recorder.go stamps a state sample
// in, and it is what correlates the two tracks -- no offset table, and both
// drift together under a virtual clock. F and T are the ADAPTER's frame counter
// and millisecond stamp, kept verbatim beside it: one receipt stamp per batch
// would smear the frame spacing inside that batch, and a hold's length has to
// stay expressible in frames.
type inputEdgeLine struct {
	Ts int64     `json:"ts"`
	F  uint64    `json:"f"`
	T  int64     `json:"t"`
	M  uint32    `json:"m"`
	Ax []float64 `json:"ax,omitempty"`
	// Drop is carried on the first line after the adapter reported losing
	// edges, so a reader can tell a lossy region from a quiet one. A gap alone
	// cannot say which it was.
	Drop uint32 `json:"drop,omitempty"`
}

// maxInputRingEdges bounds the ring by COUNT as well as by span, and both
// bounds are load-bearing.
//
// Span alone is not a bound: that is review G8's lesson, which cost the state
// ring a ceiling -- a time-bounded buffer fed at an uncapped rate is an
// unbounded buffer. An input edge is small, but a game with a stuck axis or an
// adapter with a broken change-detector can produce them at frame rate forever,
// and the ring is the always-on half of this feature. 200k edges is ~10MB and
// far more than ten minutes of real play, which is the span ceiling beside it.
const maxInputRingEdges = 200_000

// maxInputEdgesPerSecond is the flood ceiling, averaged over a second. Well
// above any real adapter: 60fps of genuine change is a couple of hundred edges
// a second at the very most.
//
// Over budget the BATCH is dropped and counted. The adapter is never detached
// for being loud -- that is the 2026-09-06 slow-adapter lesson and the "client
// died at 343 ghosts" failure: killing the game's own connection because it
// sent too much is a worse outcome than losing the thing we were recording.
const maxInputEdgesPerSecond = 1000

// inputRing keeps the last `span` milliseconds of edges, trimmed by the newest
// edge's own stamp for the same reason sampleRing is: a game that stops sending
// freezes the ring rather than draining it.
type inputRing struct {
	mu   sync.Mutex
	span int64
	buf  []inputEdgeLine
}

func (r *inputRing) setSpan(span time.Duration) {
	if span > maxRingSpan {
		span = maxRingSpan
	}
	r.mu.Lock()
	r.span = span.Milliseconds()
	if r.span <= 0 {
		r.buf = nil
	}
	r.mu.Unlock()
}

func (r *inputRing) add(e inputEdgeLine) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.span <= 0 {
		return
	}
	r.buf = append(r.buf, e)
	cutoff := e.Ts - r.span
	drop := 0
	for drop < len(r.buf)-1 && r.buf[drop].Ts < cutoff {
		drop++
	}
	// The count ceiling, applied after the span trim: whichever bites first
	// wins, and the oldest go.
	if over := len(r.buf) - drop - maxInputRingEdges; over > 0 {
		drop += over
	}
	if drop > 0 {
		n := copy(r.buf, r.buf[drop:])
		r.buf = r.buf[:n]
	}
}

func (r *inputRing) snapshot() []inputEdgeLine {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.buf) == 0 {
		return nil
	}
	out := make([]inputEdgeLine, len(r.buf))
	copy(out, r.buf)
	return out
}

// inputMeta is the per-connection state a batch is checked against: the sticky
// label table, the last edge accepted (for cross-batch ordering), and the flood
// limiter's window.
//
// Its own mutex, and it is NEVER taken while holding c.mu or c.rec.mu -- the
// same ordering rule the state recorder is held to, for the same reason (the
// 2026-09-04 hang, and the StartRecording/StopRecording re-entrancy deadlock of
// 2026-09-06).
type inputMeta struct {
	mu     sync.Mutex
	labels []string
	axes   []string
	source string

	haveLast bool
	lastF    uint64
	lastT    int64
	lastM    uint32
	lastAx   []float64

	windowMs int64
	inWindow int
	dropped  uint32 // reported by the adapter, carried onto the next line written
	refused  uint64 // dropped by US, for the log
	loggedMs int64
}

// reset clears everything a new adapter connection must not inherit. A second
// adapter's bit 3 is not the first one's bit 3, and its frame counter starts
// again from zero -- so carrying either across a reconnect would either refuse
// every batch as backwards or mislabel every button in the file.
func (m *inputMeta) reset() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.labels, m.axes, m.source = nil, nil, ""
	m.haveLast, m.lastF, m.lastT, m.lastM, m.lastAx = false, 0, 0, 0, nil
	m.windowMs, m.inWindow, m.dropped, m.refused, m.loggedMs = 0, 0, 0, 0, 0
}

// inputRecorder is the file half of the input tap. Same lazy open as the state
// recorder: the file appears at the first edge, so a track armed in the main
// menu leaves nothing behind if the game is quit before play starts.
type inputRecorder struct {
	mu        sync.Mutex
	dir       string
	gzip      bool
	path      string
	f         *os.File
	gz        *gzip.Writer
	w         *bufio.Writer
	header    inputHeader
	written   int
	lastFlush time.Time
	on        bool
	clk       coreClock
}

func (r *inputRecorder) flushClock() coreClock {
	if r.clk == nil {
		return wallClock{}
	}
	return r.clk
}

// writeLocked appends one edge, opening the file (and writing the header) on
// the first. Caller holds r.mu.
func (r *inputRecorder) writeLocked(e inputEdgeLine) error {
	if r.f == nil {
		if err := os.MkdirAll(r.dir, 0o755); err != nil {
			return fmt.Errorf("create %s: %w", r.dir, err)
		}
		f, err := os.OpenFile(r.path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if err != nil {
			return fmt.Errorf("create %s: %w", r.path, err)
		}
		r.f = f
		var sink io.Writer = f
		if r.gzip {
			r.gz = gzip.NewWriter(f)
			sink = r.gz
		}
		r.w = bufio.NewWriterSize(sink, 64*1024)
		r.header.Recorded = time.Now().UTC().Format(time.RFC3339) // wall-clock: written into a file a person reads
		if err := writeReplayLine(r.w, r.header); err != nil {
			return err
		}
		r.lastFlush = r.flushClock().Now()
	}
	if err := writeReplayLine(r.w, e); err != nil {
		return err
	}
	r.written++
	// Flushed on a clock, never per line: the bridge reader goroutine runs this
	// and must not wait on a disk (review E5).
	if r.flushClock().Since(r.lastFlush) >= time.Second {
		r.lastFlush = r.flushClock().Now()
		return r.flushLocked()
	}
	return nil
}

func (r *inputRecorder) flushLocked() error {
	if err := r.w.Flush(); err != nil {
		return err
	}
	if r.gz != nil {
		return r.gz.Flush()
	}
	return nil
}

func (r *inputRecorder) closeLocked() (path string, written int, err error) {
	path, written = r.path, r.written
	if r.f != nil {
		if ferr := r.w.Flush(); ferr != nil {
			err = ferr
		}
		// Close, not Flush: the gzip footer is written here, and a stream
		// without it is refused whole rather than read as a prefix.
		if r.gz != nil {
			if gerr := r.gz.Close(); gerr != nil && err == nil {
				err = gerr
			}
		}
		if cerr := r.f.Close(); cerr != nil && err == nil {
			err = cerr
		}
	}
	r.f, r.gz, r.w = nil, nil, nil
	r.on = false
	r.written = 0
	return path, written, err
}

// roundedAxes copies and trims the axis floats for writing, for the same reason
// roundedForFile copies rather than rounding in place: the slice arrived from a
// decoded batch and the ring holds it too.
func roundedAxes(ax []float64) []float64 {
	if len(ax) == 0 {
		return nil
	}
	out := make([]float64, len(ax))
	for i, v := range ax {
		out[i] = roundTo(v, replayExtraDigits)
	}
	return out
}

func sameAxes(a, b []float64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// recordInput is the input tap: called with every batch the adapter sends. One
// atomic load when nothing is armed, which is the shipped state.
//
// Runs on the bridge reader goroutine, so it never blocks: the ring is bounded,
// the writer is buffered and flushed on a clock, and the limiter DROPS rather
// than waits (review E5 -- a blocking write here stalls the adapter's frames).
func (c *Core) recordInput(s bridge.InputSample) {
	if atomic.LoadUint32(&c.inputTapArmed) == 0 {
		return
	}
	ts := c.nowMs()

	c.inputMeta.mu.Lock()
	// Sticky tables: absent means unchanged, so only a non-empty one replaces.
	if len(s.Labels) > 0 {
		c.inputMeta.labels = append(c.inputMeta.labels[:0:0], s.Labels...)
	}
	if len(s.Axes) > 0 {
		c.inputMeta.axes = append(c.inputMeta.axes[:0:0], s.Axes...)
	}
	if s.Source != "" {
		c.inputMeta.source = s.Source
	}
	if s.Drop > 0 {
		c.inputMeta.dropped += s.Drop
	}

	// The flood ceiling, averaged over a one-second window.
	if ts-c.inputMeta.windowMs >= 1000 {
		c.inputMeta.windowMs, c.inputMeta.inWindow = ts, 0
	}
	c.inputMeta.inWindow += len(s.Edges)
	overBudget := c.inputMeta.inWindow > maxInputEdgesPerSecond
	if overBudget {
		c.inputMeta.refused += uint64(len(s.Edges))
		// Once per ten seconds: a flood that logs per batch is a second flood.
		shout := ts-c.inputMeta.loggedMs >= 10_000
		refused := c.inputMeta.refused
		if shout {
			c.inputMeta.loggedMs = ts
			c.inputMeta.refused = 0
		}
		c.inputMeta.mu.Unlock()
		if shout {
			log.Printf("core: input track over %d edges/s; %d edge(s) dropped (the adapter stays connected)",
				maxInputEdgesPerSecond, refused)
		}
		return
	}

	// Cross-batch ordering. Refused WHOLE rather than repaired: a batch that
	// goes backwards means the adapter's own counters restarted or its queue
	// reordered, and a reader that cannot trust ordering absolutely cannot use
	// the track for anything.
	if len(s.Edges) > 0 && c.inputMeta.haveLast {
		first := s.Edges[0]
		if first.F < c.inputMeta.lastF || first.T < c.inputMeta.lastT {
			c.inputMeta.mu.Unlock()
			log.Printf("core: input batch goes backwards (frame %d/t %d after %d/%d); dropped",
				first.F, first.T, c.inputMeta.lastF, c.inputMeta.lastT)
			return
		}
	}

	// Build the lines, suppressing an edge identical to the one before it. The
	// adapter should not send those; this side must not depend on it.
	// Snapshotted under this lock and applied to the header below, because the
	// label table arrives WITH the first batch and the file is opened lazily at
	// the first edge. Arming the track happens before the adapter has declared
	// anything, so a header built at StartInputRecording time is always empty --
	// which is what the first version of this did.
	metaLabels := append([]string(nil), c.inputMeta.labels...)
	metaAxes := append([]string(nil), c.inputMeta.axes...)
	metaSource := c.inputMeta.source

	lines := make([]inputEdgeLine, 0, len(s.Edges))
	for _, e := range s.Edges {
		ax := roundedAxes(e.Ax)
		if c.inputMeta.haveLast && e.M == c.inputMeta.lastM && sameAxes(ax, c.inputMeta.lastAx) {
			c.inputMeta.lastF, c.inputMeta.lastT = e.F, e.T
			continue
		}
		line := inputEdgeLine{Ts: ts, F: e.F, T: e.T, M: e.M, Ax: ax}
		if c.inputMeta.dropped > 0 {
			line.Drop = c.inputMeta.dropped
			c.inputMeta.dropped = 0
		}
		lines = append(lines, line)
		c.inputMeta.haveLast = true
		c.inputMeta.lastF, c.inputMeta.lastT, c.inputMeta.lastM, c.inputMeta.lastAx = e.F, e.T, e.M, ax
	}
	c.inputMeta.mu.Unlock()

	if len(lines) == 0 {
		return
	}

	c.inputRec.mu.Lock()
	writeFailed := false
	if c.inputRec.on {
		// Only while the file is still unopened: after that the header is
		// written and a later table change belongs to a later track, not to
		// this one retroactively.
		if c.inputRec.f == nil {
			c.inputRec.header.Labels = metaLabels
			c.inputRec.header.Axes = metaAxes
			c.inputRec.header.Source = metaSource
		}
		for _, line := range lines {
			if err := c.inputRec.writeLocked(line); err != nil {
				log.Printf("core: input track stopped: %v", err)
				c.inputRec.closeLocked()
				writeFailed = true
				break
			}
		}
	}
	c.inputRec.mu.Unlock()

	// After the unlock and on a flag captured inside it, the same rule
	// recordLocal follows: rearmInputTap takes c.inputRec.mu and Go mutexes are
	// not reentrant.
	if writeFailed {
		c.rearmInputTap()
	}

	for _, line := range lines {
		c.inputRing.add(line)
	}
}

// logInputReject reports a refused batch, at most once every ten seconds. A
// broken adapter sends a broken batch every frame, and a line per batch would
// bury the console it is trying to report into.
func (c *Core) logInputReject(reason string) {
	if reason == "" {
		return
	}
	ts := c.nowMs()
	c.inputMeta.mu.Lock()
	shout := ts-c.inputMeta.loggedMs >= 10_000
	if shout {
		c.inputMeta.loggedMs = ts
	}
	c.inputMeta.mu.Unlock()
	if shout {
		log.Printf("core: input batch refused: %s", reason)
	}
}

// recordingIDFor turns a recording's path into the id both tracks carry: the
// base filename with its extensions removed, so "rec-20260908-214210.ndjson.gz"
// and the plain form give the same id and a person can see at a glance which
// two files belong together.
func recordingIDFor(path string) string {
	base := filepath.Base(path)
	for {
		ext := filepath.Ext(base)
		if ext == "" {
			return base
		}
		base = base[:len(base)-len(ext)]
	}
}

// inputHeaderFor is the header a fresh track carries.
func (c *Core) inputHeaderFor(game, version, recordingID string, at time.Time) inputHeader {
	c.inputMeta.mu.Lock()
	labels := append([]string(nil), c.inputMeta.labels...)
	axes := append([]string(nil), c.inputMeta.axes...)
	source := c.inputMeta.source
	c.inputMeta.mu.Unlock()
	return inputHeader{
		Format:          inputFormatVersion,
		RecordingID:     recordingID,
		Source:          source,
		Labels:          labels,
		Axes:            axes,
		Game:            game,
		GameVersion:     version,
		ProtocolVersion: protocol.Version,
		Recorded:        at.UTC().Format(time.RFC3339),
	}
}

// inputsDir is the folder every track is written to.
func (c *Core) inputsDir() string {
	if c.ReplayDir == "" {
		return ""
	}
	return filepath.Join(c.ReplayDir, inputsSubdir)
}

// gameLabels answers what the header's game/version pair should say, with the
// same precedence StartRecording uses.
func (c *Core) gameLabels() (game, version string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	game, version = c.adapterGameID, c.adapterGameVersion
	if game == "" {
		game = c.relayGame
	}
	if c.GameVersion != "" {
		version = c.GameVersion
	}
	return game, version
}

// StartInputRecording arms the file half of the input tap, writing to
// replay/inputs/in-YYYYMMDD-HHMMSS.ndjson. recordingID is the state recording
// this track belongs to, or "" when none is running.
//
// A no-op returning "" when ReplayInputs is off: the whole feature is opt-in,
// and a caller should not have to check.
func (c *Core) StartInputRecording(recordingID string) (string, error) {
	if !c.ReplayInputs {
		return "", nil
	}
	dir := c.inputsDir()
	if dir == "" {
		return "", errors.New("no replay folder configured")
	}
	game, version := c.gameLabels()
	header := c.inputHeaderFor(game, version, recordingID, time.Now()) // wall-clock: an artefact timestamp

	c.inputRec.mu.Lock()
	defer c.inputRec.mu.Unlock()
	if c.inputRec.on {
		return c.inputRec.path, errors.New("already recording inputs to " + c.inputRec.path)
	}
	c.inputRec.dir = dir
	c.inputRec.gzip = c.ReplayGzip
	path, err := replayFileName(dir, "in", time.Now(), c.inputRec.gzip) // wall-clock: a filename, deduplicated against the real filesystem
	if err != nil {
		return "", err
	}
	c.inputRec.path = path
	c.inputRec.header = header
	c.inputRec.clk = c.timeSrc
	c.inputRec.on = true
	atomic.StoreUint32(&c.inputTapArmed, 1)
	return path, nil
}

// StopInputRecording closes the track. written is 0 when no edge ever arrived,
// in which case no file exists and path is "".
func (c *Core) StopInputRecording() (path string, written int, err error) {
	c.inputRec.mu.Lock()
	on := c.inputRec.on
	path, written, err = c.inputRec.closeLocked()
	c.inputRec.mu.Unlock()
	c.rearmInputTap()
	if !on || written == 0 {
		return "", 0, err
	}
	return path, written, err
}

// InputRecording says whether the input file tap is armed.
func (c *Core) InputRecording() bool {
	c.inputRec.mu.Lock()
	defer c.inputRec.mu.Unlock()
	return c.inputRec.on
}

// SetInputRingSpan turns the recent-edge ring on (span > 0) or off.
func (c *Core) SetInputRingSpan(span time.Duration) {
	c.inputRing.setSpan(span)
	c.rearmInputTap()
}

// rearmInputTap recomputes the atomic the per-batch tap checks.
//
// A SEPARATE atomic from tapArmed, deliberately. The two taps arm for different
// reasons -- the input ring is always on whenever the feature is enabled, while
// the state tap is on only for a recording, the save-last ring or a chaser pack
// -- and folding them would make an always-on input ring silently switch the
// state tap on and start feeding chasers that nobody asked for.
func (c *Core) rearmInputTap() {
	if !c.ReplayInputs {
		atomic.StoreUint32(&c.inputTapArmed, 0)
		return
	}
	c.inputRec.mu.Lock()
	on := c.inputRec.on
	c.inputRec.mu.Unlock()
	c.inputRing.mu.Lock()
	ring := c.inputRing.span > 0
	c.inputRing.mu.Unlock()
	if on || ring {
		atomic.StoreUint32(&c.inputTapArmed, 1)
	} else {
		atomic.StoreUint32(&c.inputTapArmed, 0)
	}
}

// armInputRing sizes the input ring, which is the ALWAYS-ON half of this
// feature: whenever replay.inputs is set, the last SaveLastSpan of input is
// being kept whether or not anything is recording, so save-last can export it
// after the fact. That is the whole point of the feature for a practice mod --
// "always record inputs, and a button to export the last X seconds" -- and it
// costs one ring plus one atomic per batch.
func (c *Core) armInputRing() {
	if !c.ReplayInputs {
		return
	}
	if span := c.SaveLastSpan; span > 0 {
		c.SetInputRingSpan(span)
	}
}

// SaveLastInputs writes what the input ring holds to
// replay/inputs/inlast-YYYYMMDD-HHMMSS.ndjson. recordingID ties it to the
// state clip written by the same key press.
func (c *Core) SaveLastInputs(recordingID string) (string, int, error) {
	if !c.ReplayInputs {
		return "", 0, nil
	}
	dir := c.inputsDir()
	if dir == "" {
		return "", 0, errors.New("no replay folder configured")
	}
	edges := c.inputRing.snapshot()
	if len(edges) == 0 {
		return "", 0, nil
	}
	game, version := c.gameLabels()

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", 0, fmt.Errorf("create %s: %w", dir, err)
	}
	path, err := replayFileName(dir, "inlast", time.Now(), c.ReplayGzip) // wall-clock: a filename, as above
	if err != nil {
		return "", 0, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return "", 0, fmt.Errorf("create %s: %w", path, err)
	}
	// abandon closes AND removes, the same rule SaveLast follows: a truncated
	// .gz has no CRC footer and is refused whole, and leaving the corpse in the
	// folder leaves a file every later reader has to reject.
	abandon := func() {
		f.Close()
		os.Remove(path)
	}
	var sink io.Writer = f
	var gz *gzip.Writer
	if c.ReplayGzip {
		gz = gzip.NewWriter(f)
		sink = gz
	}
	w := bufio.NewWriterSize(sink, 64*1024)
	hdr := c.inputHeaderFor(game, version, recordingID, time.Now()) // wall-clock: an artefact timestamp, like Recorded below
	// recorded is when the clip STARTS, back-dated from the edges themselves.
	span := time.Duration(edges[len(edges)-1].Ts-edges[0].Ts) * time.Millisecond
	hdr.Recorded = time.Now().Add(-span).UTC().Format(time.RFC3339) // wall-clock: an artefact timestamp
	if err := writeReplayLine(w, hdr); err != nil {
		abandon()
		return "", 0, err
	}
	for _, e := range edges {
		if err := writeReplayLine(w, e); err != nil {
			abandon()
			return "", 0, err
		}
	}
	if err := w.Flush(); err != nil {
		abandon()
		return "", 0, err
	}
	if gz != nil {
		if err := gz.Close(); err != nil {
			abandon()
			return "", 0, err
		}
	}
	if err := f.Close(); err != nil {
		return "", 0, err
	}
	return path, len(edges), nil
}

// flushInputTrackIfOpen pushes whatever the input recorder has buffered out to
// disk. A no-op when nothing is recording.
func (c *Core) flushInputTrackIfOpen() {
	c.inputRec.mu.Lock()
	defer c.inputRec.mu.Unlock()
	if !c.inputRec.on || c.inputRec.w == nil {
		return
	}
	if err := c.inputRec.flushLocked(); err != nil {
		log.Printf("core: could not flush the input track before reading it: %v", err)
	}
}

// inputTrackProgress reports the open track's path and how many edges it has
// written so far. on is false when nothing is recording, which is what the
// hotkey descriptions use to decide whether to mention the track at all.
func (c *Core) inputTrackProgress() (path string, written int, on bool) {
	c.inputRec.mu.Lock()
	defer c.inputRec.mu.Unlock()
	return c.inputRec.path, c.inputRec.written, c.inputRec.on
}
