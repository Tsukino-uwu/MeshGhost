package core

// The input recorder: what the player pressed, as a track of its own beside the state recording, tied to it by
// recording_id and a timestamp on the same clock. Buttons are written as edges, so a one-frame press is two lines no
// rate limit can erase. The core reads none of it: masks are compared for equality and the adapter's labels are only
// copied into the header. Driving the local player from a track is forbidden in anything that ships.

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

// inputFormatVersion is the header's meshghost_inputs value, bumped only when a reader could not make sense of an
// older file at all.
const inputFormatVersion = 1

// inputsSubdir is a subdirectory because replayLast plays the newest file in ReplayDir and StartReplays reads
// ReplayDir/active/, and both skip directories; a track in either would be parsed as a clip.
const inputsSubdir = "inputs"

// inputHeader is the first line of a track. Its key is meshghost_inputs, never meshghost_replay, so a track copied
// into the replay folder is refused with a sentence instead of misplayed.
type inputHeader struct {
	Format int `json:"meshghost_inputs"`
	// RecordingID is the state recording's base filename, empty when none was running.
	RecordingID string `json:"recording_id,omitempty"`
	// Source, Labels and Axes are the adapter's, copied verbatim and never read: Labels names the bits of m, Axes the
	// slots of ax, so a later reader can refuse a track it does not understand.
	Source string   `json:"source,omitempty"`
	Labels []string `json:"labels,omitempty"`
	Axes   []string `json:"axes,omitempty"`

	Game            string `json:"game"`
	GameVersion     string `json:"game_version"`
	ProtocolVersion int    `json:"protocol_version"`
	Recorded        string `json:"recorded"`
}

// inputEdgeLine is one edge plus the core's own stamp. Ts is the clock state samples are stamped in, which correlates
// the two tracks. F and T are the adapter's frame and stamp: one receipt stamp per batch would smear the frame spacing.
type inputEdgeLine struct {
	Ts int64     `json:"ts"`
	F  uint64    `json:"f"`
	T  int64     `json:"t"`
	M  uint32    `json:"m"`
	Ax []float64 `json:"ax,omitempty"`
	// Drop rides on the first line after the adapter reported losing edges, so a reader can tell a lossy gap from a
	// quiet one.
	Drop uint32 `json:"drop,omitempty"`
}

// maxInputRingEdges bounds the ring by count as well as span: a time-bounded buffer fed at an uncapped rate is
// unbounded, and a stuck axis can send edges at frame rate forever. Far more than ten minutes of real play.
const maxInputRingEdges = 200_000

// maxInputEdgesPerSecond is the flood ceiling, well above any real adapter. Over it the batch is dropped and counted,
// never the connection: losing a recording beats killing the game's own link.
const maxInputEdgesPerSecond = 1000

// inputRing keeps the last span of edges, trimmed by the newest edge's stamp, so a game that stops sending freezes
// the ring rather than draining it.
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
	if over := len(r.buf) - drop - maxInputRingEdges; over > 0 {
		drop += over
	}
	if drop > 0 {
		// Reslice, never copy down: O(1) per edge, and append's next regrowth reclaims the dead prefix.
		r.buf = r.buf[drop:]
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

// inputMeta is the per-connection state a batch is checked against. Its mutex is never taken while holding c.mu or
// c.rec.mu, the order the state recorder keeps.
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
	refused  uint64 // dropped by this side, for the log
	loggedMs int64
}

// reset clears what a new adapter connection must not inherit: its bit 3 is not the last one's and its frame counter
// restarts, so either would mislabel every button or refuse every batch as backwards.
func (m *inputMeta) reset() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.labels, m.axes, m.source = nil, nil, ""
	m.haveLast, m.lastF, m.lastT, m.lastM, m.lastAx = false, 0, 0, 0, nil
	m.windowMs, m.inWindow, m.dropped, m.refused, m.loggedMs = 0, 0, 0, 0, 0
}

// inputRecorder is the file half of the input tap. The file opens at the first edge, so a track armed in the main
// menu leaves nothing if the game quits before play.
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
	// Flushed on a clock, never per line: the bridge reader goroutine runs this and must not wait on a disk.
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
		// Close, not Flush: the gzip footer is written here, and a stream without it is refused whole.
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

// roundedAxes copies before rounding: the slice came from a decoded batch, which the ring holds too.
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

// recordInput is the input tap, called with every batch the adapter sends; one atomic load when nothing is armed. It
// runs on the bridge reader goroutine, so it never blocks: the limiter drops rather than waits.
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

	// A backwards batch is refused whole, not repaired: the adapter's counters restarted or its queue reordered, and a
	// track whose order cannot be trusted is useless.
	if len(s.Edges) > 0 && c.inputMeta.haveLast {
		first := s.Edges[0]
		if first.F < c.inputMeta.lastF || first.T < c.inputMeta.lastT {
			c.inputMeta.mu.Unlock()
			log.Printf("core: input batch goes backwards (frame %d/t %d after %d/%d); dropped",
				first.F, first.T, c.inputMeta.lastF, c.inputMeta.lastT)
			return
		}
	}

	// The tables are snapshotted for the header here: they arrive with the first batch, after the track was armed.
	metaLabels := append([]string(nil), c.inputMeta.labels...)
	metaAxes := append([]string(nil), c.inputMeta.axes...)
	metaSource := c.inputMeta.source

	lines := make([]inputEdgeLine, 0, len(s.Edges))
	// An edge identical to the one before it is suppressed; the adapter should not send those, but may.
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
		// Only while the file is unopened; once the header is written, a table change belongs to a later track.
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

	// After the unlock: rearmInputTap takes c.inputRec.mu.
	if writeFailed {
		c.rearmInputTap()
	}

	for _, line := range lines {
		c.inputRing.add(line)
	}
}

// logInputReject reports a refused batch at most once every ten seconds: a broken adapter sends one every frame.
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

// recordingIDFor is the id both tracks carry: the base filename without extensions, so the gzip and plain forms of a
// recording give the same id.
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

func (c *Core) inputsDir() string {
	if c.replayDir() == "" {
		return ""
	}
	return filepath.Join(c.replayDir(), inputsSubdir)
}

// gameLabels is the header's game and version, with the precedence StartRecording uses.
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

// StartInputRecording arms the file half of the input tap, writing to replay/inputs/in-YYYYMMDD-HHMMSS.ndjson.
// recordingID is the state recording this track belongs to, or "". A no-op returning "" when ReplayInputs is off.
func (c *Core) StartInputRecording(recordingID string) (string, error) {
	if !c.replayInputs() {
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
	c.inputRec.gzip = c.replayGzip()
	path, err := replayFileName(dir, "in", time.Now(), c.inputRec.gzip) // wall-clock: a filename, checked on disk
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

// StopInputRecording closes the track. written is 0 when no edge ever arrived, and then no file exists and path is "".
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

// rearmInputTap recomputes inputTapArmed, kept apart from tapArmed: the input ring is always on with the feature, and
// folding the two would switch the state tap on and feed chasers nobody asked for.
func (c *Core) rearmInputTap() {
	if !c.replayInputs() {
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

// armInputRing sizes the input ring, the always-on half of the feature: with replay.inputs set, the last SaveLastSpan
// of input is kept whether or not anything is recording, so save-last can export it after the fact.
func (c *Core) armInputRing() {
	if !c.replayInputs() {
		return
	}
	if span := c.saveLastSpan(); span > 0 {
		c.SetInputRingSpan(span)
	}
}

// SaveLastInputs writes what the input ring holds to replay/inputs/inlast-YYYYMMDD-HHMMSS.ndjson. recordingID ties it
// to the state clip written by the same key press.
func (c *Core) SaveLastInputs(recordingID string) (string, int, error) {
	if !c.replayInputs() {
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
	path, err := replayFileName(dir, "inlast", time.Now(), c.replayGzip()) // wall-clock: a filename, as above
	if err != nil {
		return "", 0, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return "", 0, fmt.Errorf("create %s: %w", path, err)
	}
	// abandon closes and removes: a truncated .gz has no CRC footer and is refused whole by every later reader.
	abandon := func() {
		f.Close()
		os.Remove(path)
	}
	var sink io.Writer = f
	var gz *gzip.Writer
	if c.replayGzip() {
		gz = gzip.NewWriter(f)
		sink = gz
	}
	w := bufio.NewWriterSize(sink, 64*1024)
	hdr := c.inputHeaderFor(game, version, recordingID, time.Now()) // wall-clock: an artefact timestamp
	// Recorded is when the clip starts, back-dated from the edges themselves.
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

// flushInputTrackIfOpen pushes whatever the input recorder has buffered to disk; a no-op when nothing is recording.
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

// inputTrackProgress reports the open track's path and edges written; on is false when nothing is recording.
func (c *Core) inputTrackProgress() (path string, written int, on bool) {
	c.inputRec.mu.Lock()
	defer c.inputRec.mu.Unlock()
	return c.inputRec.path, c.inputRec.written, c.inputRec.on
}
