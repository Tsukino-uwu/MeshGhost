package core

// The recorder: the adapter's own state stream written to a file, tapped at the top of forwardLocalState, before the
// send-rate limit and the relay check, so it is the densest copy and works offline. A recording is 1:1 with the
// gameplay: nothing is trimmed but an identical consecutive sample inside the keepalive window, which playback cannot
// tell apart. The same tap feeds the ring save-last drains and the chaser pack's history, each independent.

import (
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
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// replayFormatVersion is the header's meshghost_replay value, bumped only when a reader could not make sense of an
// older file at all; an added key does not bump it.
const replayFormatVersion = 1

// replayHeader is the first line of a replay file. The first group is what a player may edit; the last is what the
// recorder wrote, which playback reads only for a warning.
type replayHeader struct {
	Format       int     `json:"meshghost_replay"`
	Name         string  `json:"name"`
	Color        string  `json:"color"`
	Speed        float64 `json:"speed"`
	Loop         bool    `json:"loop"`
	Anchor       string  `json:"anchor"`
	AnchorRadius float64 `json:"anchor_radius"`
	StartDelay   string  `json:"start_delay"`
	TrimStart    string  `json:"trim_start"`
	TrimEnd      string  `json:"trim_end"`
	SkipGaps     string  `json:"skip_gaps"`
	// Delta says sample lines carry only the extras that changed since the line before.
	Delta bool `json:"delta,omitempty"`
	// RecordingID is this recording's base filename, also in its input track's header; absent means no track.
	RecordingID string `json:"recording_id,omitempty"`

	Game            string `json:"game"`
	GameVersion     string `json:"game_version"`
	ProtocolVersion int    `json:"protocol_version"`
	Recorded        string `json:"recorded"`
}

// defaultReplayHeader spells out every player-editable key at its default, so a player opening the file sees what can
// change.
func defaultReplayHeader(game, version string, recorded time.Time) replayHeader {
	return replayHeader{
		Format:          replayFormatVersion,
		Speed:           1.0,
		Anchor:          "launch",
		AnchorRadius:    1.0,
		StartDelay:      "0s",
		TrimStart:       "0s",
		TrimEnd:         "0s",
		SkipGaps:        "0s",
		Game:            game,
		GameVersion:     version,
		ProtocolVersion: protocol.Version,
		Recorded:        recorded.UTC().Format(time.RFC3339),
	}
}

// replayHeaderFor names a recording at birth, since editing a header inside a .gz means recompressing the file.
// ReplayName and ReplayColor win, then the player's own display name and colour.
func (c *Core) replayHeaderFor(game, version string, at time.Time) replayHeader {
	h := defaultReplayHeader(game, version, at)
	h.Name, h.Color = c.replayNameColor()
	if h.Name == "" {
		h.Name, h.Color = c.displayName(), c.nameColor()
	}
	return h
}

// sampleRing keeps the last span of stamped samples, trimmed by the newest sample's stamp, so a game that stops
// sending (a menu) freezes the ring rather than draining it.
type sampleRing struct {
	mu   sync.Mutex
	span int64
	buf  []protocol.State
}

// maxRingSpan caps how much recent play the ring keeps, so a fat-fingered save_last cannot become unbounded memory.
// Ten minutes, like maxChaserBehind: both bound how far back this core keeps the player's own past.
const maxRingSpan = 10 * time.Minute

// maxRingSamples bounds the ring by count as well: a span bounds nothing about the rate, which a local process
// chooses. It sits above the fastest real feed over maxRingSpan; the oldest go, as with the span cutoff.
const maxRingSamples = 200_000

// setSpan clamps silently: armRing, the config path, says what was asked for and what took effect.
func (r *sampleRing) setSpan(span time.Duration) {
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

func (r *sampleRing) add(st protocol.State) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.span <= 0 {
		return
	}
	r.buf = append(r.buf, st)
	cutoff := st.Timestamp - r.span
	drop := 0
	for drop < len(r.buf)-1 && r.buf[drop].Timestamp < cutoff {
		drop++
	}
	if over := len(r.buf) - drop - maxRingSamples; over > 0 {
		drop += over
	}
	if drop > 0 {
		// Reslice, never copy down: copying is O(n) per sample at the cap. The dead prefix is not leaked: once the
		// shrunk capacity runs out, append allocates fresh from the length.
		r.buf = r.buf[drop:]
	}
}

func (r *sampleRing) snapshot() []protocol.State {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.buf) == 0 {
		return nil
	}
	out := make([]protocol.State, len(r.buf))
	copy(out, r.buf)
	return out
}

// recorder is the file half of the tap. The file opens at the first sample, so a recording armed in the main menu
// leaves nothing if the game quits before play.
type recorder struct {
	// startedUnixMs is the recording's wall-clock start, for the adapter's elapsed time: the adapter is another
	// process on this machine and cannot see the core's clock.
	startedUnixMs int64

	mu          sync.Mutex
	dir         string
	gzip        bool // write .ndjson.gz; see Core.ReplayGzip
	delta       bool // write only extras that changed; see Core.ReplayDelta
	prevExtras  map[string]any
	path        string // decided at start; the file exists only once written>0
	f           *os.File
	gz          *gzip.Writer // nil when writing plain ndjson
	w           *bufio.Writer
	header      replayHeader
	keepaliveMs int64
	seq         uint64
	last        *protocol.State
	lastTs      int64
	written     int
	lastFlush   time.Time
	on          bool

	// clk is the clock lastFlush is measured against, nil meaning the wall clock. The filename and Recorded stay on
	// the wall clock: they end up in a file someone reads, and names are deduplicated against the real filesystem.
	clk coreClock
}

// flushClock never assigns, like Core.clk: it runs under rec.mu.
func (r *recorder) flushClock() coreClock {
	if r.clk == nil {
		return wallClock{}
	}
	return r.clk
}

// recordLocal is the tap, called with every non-nil frame the adapter offers before anything else happens to it; one
// atomic load when nothing is armed.
func (c *Core) recordLocal(state *protocol.State) {
	if atomic.LoadUint32(&c.tapArmed) == 0 {
		return
	}
	ts := c.nowMs()
	st := *state
	st.PlayerID = ""
	st.Prev = nil
	st.Timestamp = ts

	c.rec.mu.Lock()
	writeFailed := false
	if c.rec.on {
		unchanged := c.rec.last != nil && sameSentState(c.rec.last, &st) && ts-c.rec.lastTs < c.rec.keepaliveMs
		if !unchanged {
			if err := c.rec.writeLocked(st); err != nil {
				log.Printf("core: recording stopped: %v", err)
				c.rec.closeLocked()
				writeFailed = true
			}
		}
	}
	c.rec.mu.Unlock()

	// A failed write stopped the recording, so the adapter is told, as on every other stop, or its indicator stays
	// lit. After the unlock: both calls take c.rec.mu, and pushRecordingState takes c.mu, never held under it.
	if writeFailed {
		c.rearmTap()
		c.pushRecordingState()
	}

	// A drained ring is renumbered from 1 in its own file; the chaser never reads seq.
	c.ring.add(st)
	// The chaser runs on gameplay time: a frame taken while frozen is recorded but never offered, and what is offered
	// carries a gameplay stamp, so a freeze is no gap to its seam check.
	if gs, ok := c.gameplayStamp(ts); ok {
		// At most one sample per chaserOfferIntervalMs, so the history's sizing holds whatever rate the adapter sends.
		if gs-c.lastChaserOfferMs >= chaserOfferIntervalMs {
			c.lastChaserOfferMs = gs
			st.Timestamp = gs
			c.offerChasers(st)
		}
	}
}

// writeLocked appends one sample, opening the file and writing the header on the first. Caller holds rec.mu.
func (r *recorder) writeLocked(st protocol.State) error {
	if r.f == nil {
		if err := os.MkdirAll(r.dir, 0o755); err != nil {
			return fmt.Errorf("create %s: %w", r.dir, err)
		}
		f, err := os.OpenFile(r.path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
		if err != nil {
			return fmt.Errorf("create %s: %w", r.path, err)
		}
		r.f = f
		// bufio on top of gzip, so deflate sees 64KiB at a time rather than a line per frame.
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
	r.seq++
	st.Seq = r.seq
	out := roundedForFile(st)
	if r.delta {
		full := out.Extras
		out.Extras = extrasDelta(r.prevExtras, full)
		r.prevExtras = full
	}
	if err := writeReplayLine(r.w, out); err != nil {
		return err
	}
	kept := st
	r.last = &kept
	r.lastTs = st.Timestamp
	r.written++
	// Flushed on a clock, not per line: a crash loses at most a second, and the game's frame never waits on the disk.
	if r.flushClock().Since(r.lastFlush) >= time.Second {
		r.lastFlush = r.flushClock().Now()
		return r.flushLocked()
	}
	return nil
}

// flushLocked pushes everything buffered to the file. gzip.Writer.Flush emits a sync point, so a crashed recording
// stays a decodable prefix.
func (r *recorder) flushLocked() error {
	if err := r.w.Flush(); err != nil {
		return err
	}
	if r.gz != nil {
		return r.gz.Flush()
	}
	return nil
}

func (r *recorder) closeLocked() (path string, written int, err error) {
	path, written = r.path, r.written
	if r.f != nil {
		if ferr := r.w.Flush(); ferr != nil {
			err = ferr
		}
		// Close, not Flush: the gzip footer (CRC and length) is written here; without it the file is corrupt.
		if r.gz != nil {
			if gerr := r.gz.Close(); gerr != nil && err == nil {
				err = gerr
			}
		}
		if cerr := r.f.Close(); cerr != nil && err == nil {
			err = cerr
		}
	}
	r.f, r.gz, r.w, r.last, r.prevExtras = nil, nil, nil, nil, nil
	r.on = false
	r.seq, r.written, r.lastTs = 0, 0, 0
	return path, written, err
}

// Rounding applied to every float on its way into a file: json.Marshal's 17-digit tails are binary noise, not
// information. 3 decimals of a position unit is 10 micrometres in the one 3D game here, and 1e-6 radians is a fifth
// of an arcsecond.
const (
	replayPosDigits    = 3
	replayOrientDigits = 6
	replayExtraDigits  = 3
)

func roundTo(v float64, digits int) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return v
	}
	p := math.Pow(10, float64(digits))
	return math.Round(v*p) / p
}

// roundedForFile returns st with its floats trimmed for writing. It copies the position and extras: the same State
// goes to the ring and the chasers, and rounding in place would change what a live ghost renders.
func roundedForFile(st protocol.State) protocol.State {
	if len(st.Position) > 0 {
		pos := make([]float64, len(st.Position))
		for i, v := range st.Position {
			pos[i] = roundTo(v, replayPosDigits)
		}
		st.Position = pos
	}
	if len(st.Orientation) > 0 {
		// Opaque by contract, so decoded as generic JSON and re-encoded; anything not numeric is left as it arrived.
		var v any
		if err := json.Unmarshal(st.Orientation, &v); err == nil {
			if b, err := json.Marshal(roundValue(v, replayOrientDigits)); err == nil {
				st.Orientation = b
			}
		}
	}
	if len(st.Extras) > 0 {
		ex := make(map[string]any, len(st.Extras))
		for k, v := range st.Extras {
			ex[k] = roundValue(v, replayExtraDigits)
		}
		st.Extras = ex
	}
	return st
}

func roundValue(v any, digits int) any {
	switch t := v.(type) {
	case float64:
		return roundTo(t, digits)
	case []any:
		out := make([]any, len(t))
		for i := range t {
			out[i] = roundValue(t[i], digits)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(t))
		for k := range t {
			out[k] = roundValue(t[k], digits)
		}
		return out
	}
	return v
}

// extrasDelta returns cur without the keys unchanged since prev. Per key, not per line: a few keys jitter every frame,
// so whole lines almost never repeat. A key that disappears is kept as an explicit null, since absent means unchanged.
func extrasDelta(prev, cur map[string]any) map[string]any {
	if len(prev) == 0 {
		return cur
	}
	out := make(map[string]any, len(cur))
	for k, v := range cur {
		if old, ok := prev[k]; !ok || !sameExtra(old, v) {
			out[k] = v
		}
	}
	for k := range prev {
		if _, still := cur[k]; !still {
			out[k] = nil
		}
	}
	return out
}

// sameExtra compares two decoded JSON values with a switch over the shapes json.Unmarshal produces, cheaper than
// reflect.DeepEqual on every recorded frame.
func sameExtra(a, b any) bool {
	switch x := a.(type) {
	case float64:
		y, ok := b.(float64)
		return ok && x == y
	case string:
		y, ok := b.(string)
		return ok && x == y
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case nil:
		return b == nil
	case []any:
		y, ok := b.([]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !sameExtra(x[i], y[i]) {
				return false
			}
		}
		return true
	case map[string]any:
		y, ok := b.(map[string]any)
		if !ok || len(x) != len(y) {
			return false
		}
		for k := range x {
			if !sameExtra(x[k], y[k]) {
				return false
			}
		}
		return true
	}
	return false
}

func writeReplayLine(w *bufio.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if _, err := w.Write(b); err != nil {
		return err
	}
	return w.WriteByte('\n')
}

// replayStat is os.Stat as a variable, so a test can fail it as a disconnected share or a denied folder does, which no
// test can produce on demand on Windows.
var replayStat = os.Stat

// replayNameAttempts bounds the suffix search: one core writes one recording at a time, so past a handful of
// same-second collisions the answers are not to be believed.
const replayNameAttempts = 100

// replayFileName is rec-YYYYMMDD-HHMMSS.ndjson, or last-... for a save-last file; a same-second collision gets a -2,
// -3 suffix. Any Stat error but not-exist ends the search: this runs under c.rec.mu, which recordLocal takes on every
// frame.
func replayFileName(dir, prefix string, at time.Time, gz bool) (string, error) {
	ext := ".ndjson"
	if gz {
		ext += ".gz"
	}
	base := prefix + "-" + at.Format("20060102-150405")
	path := filepath.Join(dir, base+ext)
	for n := 2; n < replayNameAttempts+2; n++ {
		_, err := replayStat(path)
		if errors.Is(err, os.ErrNotExist) {
			return path, nil
		}
		if err != nil {
			return "", fmt.Errorf("check %s: %w", path, err)
		}
		path = filepath.Join(dir, fmt.Sprintf("%s-%d%s", base, n, ext))
	}
	return "", fmt.Errorf("no free name for a recording in %s after %d tries", dir, replayNameAttempts)
}

// StartRecording arms the state recording and, when ReplayInputs is on, the input track beside it, both carrying the
// same recording_id. The path is decided now; the file appears at the first sample. Two calls, not one body: the
// state half holds c.rec.mu throughout, and the input half takes c.mu, which must never be taken under it.
func (c *Core) StartRecording() (string, error) {
	path, err := c.startStateRecording()
	if err != nil {
		return path, err
	}
	if ipath, ierr := c.StartInputRecording(recordingIDFor(path)); ierr != nil {
		// The state recording is the artefact the player asked for; a lost input track is a line, not a failure.
		log.Printf("core: input track could not start: %v", ierr)
	} else if ipath != "" {
		// The launch path's only sign the track is on; the hotkey path has describeStart.
		log.Printf("core: input track to %s (the file appears at the first input edge)", ipath)
	}
	return path, nil
}

// startStateRecording refuses an empty ReplayDir, so nothing is ever written beside the exe by accident.
func (c *Core) startStateRecording() (string, error) {
	if c.replayDir() == "" {
		return "", errors.New("no replay folder configured")
	}
	c.mu.Lock()
	game, version := c.adapterGameID, c.adapterGameVersion
	if game == "" {
		game = c.relayGame
	}
	if c.GameVersion != "" {
		version = c.GameVersion
	}
	keepalive := c.IdleKeepalive
	c.mu.Unlock()

	c.rec.mu.Lock()
	defer c.rec.mu.Unlock()
	if c.rec.on {
		return c.rec.path, errors.New("already recording to " + c.rec.path)
	}
	c.rec.dir = c.replayDir()
	c.rec.gzip = c.replayGzip()
	c.rec.delta = c.replayDelta()
	c.rec.prevExtras = nil
	// An unanswerable name is refused now, not at the first sample with the indicator already lit.
	path, err := replayFileName(c.replayDir(), "rec", time.Now(), c.rec.gzip) // wall-clock: a filename, checked on disk
	if err != nil {
		return "", err
	}
	c.rec.path = path
	c.rec.header = c.replayHeaderFor(game, version, time.Now()) // wall-clock: an artefact timestamp
	// After the header is built: replayHeaderFor returns a fresh one.
	c.rec.header.Delta = c.replayDelta()
	c.rec.header.RecordingID = recordingIDFor(path)
	c.rec.keepaliveMs = keepalive.Milliseconds()
	c.rec.clk = c.timeSrc
	c.rec.on = true
	atomic.StoreUint32(&c.tapArmed, 1)
	c.rec.startedUnixMs = time.Now().UnixMilli() // wall-clock: read by the adapter, not by the core
	log.Printf("core: recording to %s (the file appears at the first in-game sample)", c.rec.path)
	// The adapter draws the indicator, so it is told the moment this flips. The values variant, because c.rec.mu is
	// held here and the plain one asks the recorder for its state.
	c.pushRecordingStateValues(true, c.rec.startedUnixMs)
	return c.rec.path, nil
}

// StopRecording closes the file. written is 0 when no sample ever arrived, and then no file exists and path is "".
func (c *Core) StopRecording() (path string, written int, err error) {
	c.rec.mu.Lock()
	on := c.rec.on
	path, written, err = c.rec.closeLocked()
	c.rec.mu.Unlock()
	c.rearmTap()
	c.pushRecordingState()
	// After the state half is closed and its mutex released, never under it.
	if ipath, iwritten, ierr := c.StopInputRecording(); ierr != nil {
		log.Printf("core: input track stopped with an error: %v", ierr)
	} else if iwritten > 0 {
		log.Printf("core: input track stopped: %d edge(s) in %s", iwritten, ipath)
	}
	if !on {
		return "", 0, nil
	}
	if written == 0 {
		log.Printf("core: recording stopped before any in-game sample arrived; nothing written")
		return "", 0, err
	}
	log.Printf("core: recording stopped: %d sample(s) in %s", written, path)
	return path, written, err
}

// Recording says whether the file tap is armed.
func (c *Core) Recording() bool {
	c.rec.mu.Lock()
	defer c.rec.mu.Unlock()
	return c.rec.on
}

// SetRingSpan turns the recent-sample ring that SaveLast drains on (span > 0) or off.
func (c *Core) SetRingSpan(span time.Duration) {
	c.ring.setSpan(span)
	c.rearmTap()
}

// rearmTap recomputes the one atomic the per-frame tap checks.
func (c *Core) rearmTap() {
	c.rec.mu.Lock()
	on := c.rec.on
	c.rec.mu.Unlock()
	c.ring.mu.Lock()
	ring := c.ring.span > 0
	c.ring.mu.Unlock()
	c.chaserMu.Lock()
	pack := len(c.chasers) > 0
	c.chaserMu.Unlock()
	if on || ring || pack {
		atomic.StoreUint32(&c.tapArmed, 1)
	} else {
		atomic.StoreUint32(&c.tapArmed, 0)
	}
}

// SaveLast writes what the ring holds, the last SaveLastSpan of play, to replay/last-YYYYMMDD-HHMMSS.ndjson with a
// recording's header: the "do a trick, then press the key" mode, independent of a running recording.
func (c *Core) SaveLast() (string, int, error) {
	if c.replayDir() == "" {
		return "", 0, errors.New("no replay folder configured")
	}
	samples := c.ring.snapshot()
	if len(samples) == 0 {
		// The span the ring kept, not the one asked for, which may have been clamped.
		kept := c.saveLastSpan()
		if kept > maxRingSpan {
			kept = maxRingSpan
		}
		return "", 0, errors.New("nothing to save yet: no in-game samples in the last " + kept.String())
	}
	c.mu.Lock()
	game, version := c.adapterGameID, c.adapterGameVersion
	if game == "" {
		game = c.relayGame
	}
	if c.GameVersion != "" {
		version = c.GameVersion
	}
	c.mu.Unlock()

	if err := os.MkdirAll(c.replayDir(), 0o755); err != nil {
		return "", 0, fmt.Errorf("create %s: %w", c.replayDir(), err)
	}
	path, err := replayFileName(c.replayDir(), "last", time.Now(), c.replayGzip()) // wall-clock: a filename, as above
	if err != nil {
		return "", 0, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return "", 0, fmt.Errorf("create %s: %w", path, err)
	}
	// abandon closes and removes the half-written file: replayLast picks the newest file in the folder, and a .gz cut
	// before its footer is refused whole.
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
	hdr := c.replayHeaderFor(game, version, time.Now()) // wall-clock: an artefact timestamp
	hdr.Delta = c.replayDelta()
	// Recorded is when the clip starts, back-dated from virtual sample stamps: harmless in a string nobody compares.
	hdr.Recorded = time.Now().Add(-time.Duration(samples[len(samples)-1].Timestamp-samples[0].Timestamp) * time.Millisecond).UTC().Format(time.RFC3339) // wall-clock: an artefact timestamp
	if err := writeReplayLine(w, hdr); err != nil {
		abandon()
		return "", 0, err
	}
	var prevExtras map[string]any
	for i := range samples {
		samples[i].Seq = uint64(i + 1)
		out := roundedForFile(samples[i])
		if c.replayDelta() {
			full := out.Extras
			out.Extras = extrasDelta(prevExtras, full)
			prevExtras = full
		}
		if err := writeReplayLine(w, out); err != nil {
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
	span := time.Duration(samples[len(samples)-1].Timestamp-samples[0].Timestamp) * time.Millisecond
	log.Printf("core: saved the last %s (%d samples) to %s", span.Round(time.Millisecond), len(samples), path)
	// The input half of the same key press, best-effort: the state clip is written either way.
	if ipath, iedges, ierr := c.SaveLastInputs(recordingIDFor(path)); ierr != nil {
		log.Printf("core: could not save the last inputs: %v", ierr)
	} else if iedges > 0 {
		log.Printf("core: saved the last %d input edge(s) to %s", iedges, ipath)
	}
	return path, len(samples), nil
}

// armRing sizes the ring to SaveLastSpan when the adapter attaches.
func (c *Core) armRing() {
	span := c.saveLastSpan()
	if span > 0 {
		// Said out loud, or a save-last file shorter than the config asks for would have nothing to explain it.
		if span > maxRingSpan {
			log.Printf("core: replay save_last asks for %s of recent play; keeping %s (the most the ring holds)", span, maxRingSpan)
		}
		c.SetRingSpan(span)
	}
}

// flushRecordingIfOpen pushes whatever the recorder has buffered to disk, for the replay-last hotkey, which may pick
// the file still being written. A no-op when nothing is recording.
func (c *Core) flushRecordingIfOpen() {
	c.rec.mu.Lock()
	defer c.rec.mu.Unlock()
	if !c.rec.on || c.rec.w == nil {
		return
	}
	if err := c.rec.flushLocked(); err != nil {
		log.Printf("core: could not flush the recording before reading it: %v", err)
	}
}
