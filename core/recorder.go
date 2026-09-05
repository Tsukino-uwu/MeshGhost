package core

// The recorder: the adapter's own state stream, written to a file (ADR 0047).
//
// A recording is what this core's adapter reports about the player, one
// protocol.State per line, taken at the TOP of forwardLocalState -- before the
// send-rate limit and before the relay-or-not check -- so it is the densest
// copy that exists and it works with no relay at all. The first line is a
// header (replayHeader); the rest are samples with Timestamp stamped in this
// core's nowMs domain and a recorder-local Seq, PlayerID left empty.
//
// WHAT A RECORDING IS, the user's line (2026-09-03): 1:1 with the GAMEPLAY,
// from the moment the player is in the world to the moment they quit. The
// file's first state is the first non-nil sample -- the adapter already sends
// nothing in the main menu -- and after that nothing is trimmed: a watched
// cutscene is a standstill of the same length, a pause is a pause. The one
// thing dropped is an IDENTICAL consecutive sample inside the keepalive window,
// which playback cannot distinguish (a receiver holds the last sample anyway)
// and which is what keeps standing still at 100Hz from being 50MB an hour.
//
// The same tap feeds a time-bounded ring of recent samples, which is what
// "save the last N seconds" drains and what the chaser reads. The ring and the
// file are independent: either may be on without the other.

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

// replayFormatVersion is the value of the header's meshghost_replay key. Bumped
// only if a reader could not make sense of an older file at all; adding keys
// does not bump it (an older file simply lacks them and gets the defaults).
const replayFormatVersion = 1

// replayHeader is the first line of a replay file. The first group is what a
// player may edit; the second is what the recorder wrote and playback reads for
// a warning only (compatibility is "latest version assumed, older files play
// with what they have").
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
	// Delta says the sample lines carry only the extras that CHANGED since
	// the line before, with everything else carried forward at load time.
	// Written by the recorder; a file without it is read as it always was.
	Delta bool `json:"delta,omitempty"`

	Game            string `json:"game"`
	GameVersion     string `json:"game_version"`
	ProtocolVersion int    `json:"protocol_version"`
	Recorded        string `json:"recorded"`
}

// defaultReplayHeader is what a fresh recording carries: every player-editable
// key at its default, spelled out so a player opening the file sees what can
// be changed without reading a doc.
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

// replayHeaderFor is defaultReplayHeader with this Core's own labelling
// applied, so a recording is BORN NAMED rather than needing its header edited
// afterwards. That matters more since recordings ship gzipped (ReplayGzip): the
// header is the one line anyone hand-edits, and editing it inside a .gz means
// decompressing and recompressing a file just to give a clip a name.
//
// ReplayName/ReplayColor win; with neither set it falls back to the player's
// own display name and colour, since a recording of your own run labelled with
// your own name is what you would have typed anyway. Both empty stays empty,
// which is the previous behaviour and renders no tag at all.
func (c *Core) replayHeaderFor(game, version string, at time.Time) replayHeader {
	h := defaultReplayHeader(game, version, at)
	h.Name, h.Color = c.ReplayName, c.ReplayColor
	if h.Name == "" {
		h.Name, h.Color = c.DisplayName, c.NameColor
	}
	return h
}

// sampleRing keeps the last `span` milliseconds of stamped samples. Trimmed by
// the newest sample's own timestamp rather than by wall clock, so a game that
// stops sending (a menu) freezes the ring rather than draining it.
type sampleRing struct {
	mu   sync.Mutex
	span int64
	buf  []protocol.State
}

func (r *sampleRing) setSpan(span time.Duration) {
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
	if drop > 0 {
		// Copy down rather than reslice forever: a reslice keeps the whole
		// backing array alive and growing for as long as the ring is on.
		n := copy(r.buf, r.buf[drop:])
		r.buf = r.buf[:n]
	}
}

// snapshot copies what the ring holds, oldest first.
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

// recorder is the file half of the tap. The file is opened lazily at the first
// sample, so a recording armed in the main menu leaves nothing behind if the
// game is quit before play starts, and `recorded` is the first sample's time.
type recorder struct {
	// Wall-clock start of the current recording, in unix milliseconds, for the
	// adapter's on-screen elapsed time (bridge.RecordingState). Wall clock and
	// not the core's own timeSrc: the adapter is a separate process that has no
	// access to that clock, and both are on this machine by construction.
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

	// clk is the clock lastFlush is measured against. Set alongside the rest of
	// the recorder in StartRecording; nil means the wall clock, so a recorder
	// built by a test literal still behaves.
	//
	// It covers lastFlush ONLY. The filename and the header's Recorded stamp
	// stay on the wall clock deliberately -- both end up in a file somebody
	// reads, and replayFileName deduplicates against the real filesystem at
	// second granularity, so a virtual clock would write a fabricated time into
	// an artefact and collide every recording in a test onto one name.
	clk coreClock
}

// flushClock is the recorder's clock, or the wall clock when none was set. Same
// pure-read rule as Core.clk, and for the same reason: this runs under rec.mu.
func (r *recorder) flushClock() coreClock {
	if r.clk == nil {
		return wallClock{}
	}
	return r.clk
}

// recordLocal is the tap: called with every non-nil frame the adapter offers,
// before anything else happens to it. One atomic load when nothing is armed,
// which is the shipped state.
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
	if c.rec.on {
		unchanged := c.rec.last != nil && sameSentState(c.rec.last, &st) && ts-c.rec.lastTs < c.rec.keepaliveMs
		if !unchanged {
			if err := c.rec.writeLocked(st); err != nil {
				log.Printf("core: recording stopped: %v", err)
				c.rec.closeLocked()
			}
		}
	}
	c.rec.mu.Unlock()

	// The ring stamps its own seq: what it drains becomes a file of its own,
	// numbered from 1 there, and the chaser never looks at seq at all.
	c.ring.add(st)
	// The chaser alone runs on GAMEPLAY time (ADR 0053): a frame taken while
	// the adapter says the player is frozen is recorded above, as it always
	// was, and never offered here -- the chaser's clock is stopped, so the
	// sample would only pile up to be replayed all at once on resume. What IS
	// offered carries a gameplay stamp, so a freeze between two samples is no
	// gap to the chaser's seam check.
	if gs, ok := c.gameplayStamp(ts); ok {
		st.Timestamp = gs
		c.offerChasers(st)
	}
}

// writeLocked appends one sample, opening the file (and writing the header)
// on the first. Caller holds rec.mu.
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
		// bufio ON TOP of gzip, not under it: lines are batched before they
		// reach the compressor, so deflate sees 64KiB at a time rather than
		// ~1KiB per frame. Flushing means both, innermost last.
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
	// Flushed on a clock rather than per line: a crash loses at most a second,
	// and the game's frame never waits on the disk.
	if r.flushClock().Since(r.lastFlush) >= time.Second {
		r.lastFlush = r.flushClock().Now()
		return r.flushLocked()
	}
	return nil
}

// flushLocked pushes everything buffered out to the file. gzip.Writer.Flush
// emits a sync point, so a crashed recording stays a decodable prefix rather
// than an unreadable stream -- the same promise the plain writer already made.
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
		// Close, not Flush: the gzip footer (CRC and length) is written here,
		// and a stream without it is what makes `gzip -t` call a file corrupt.
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

// Rounding applied to every sample on its way into a file. The 17-digit tails
// json.Marshal prints for a float64 -- "550.0000000000016", "-492.6911072143106"
// -- are an artefact of binary floating point, not information: 3 decimals of a
// position unit is 10 micrometres in the one 3D game here, and 1e-6 radians is
// about a fifth of an arcsecond. Measured on a real 3-minute Pseudoregalia clip
// (scaling.md): 7% smaller before compression, and it strips the highest-entropy
// bytes in the file, so gzip does better on top.
//
// NOT applied to timestamp or seq, which are integers and carry the schedule.
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

// roundedForFile returns st with its floats trimmed for writing. It COPIES the
// position slice and the extras map rather than rounding in place: the same
// State goes to the ring and to every chaser, and rounding what they hold would
// make the recorder change what a live ghost renders.
func roundedForFile(st protocol.State) protocol.State {
	if len(st.Position) > 0 {
		pos := make([]float64, len(st.Position))
		for i, v := range st.Position {
			pos[i] = roundTo(v, replayPosDigits)
		}
		st.Position = pos
	}
	if len(st.Orientation) > 0 {
		// Opaque by contract (scalar, vector or quaternion), so this decodes
		// it as generic JSON and re-encodes; anything that is not numeric is
		// left exactly as it arrived.
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

// roundValue rounds every float inside a decoded JSON value, leaving strings,
// bools and nulls alone.
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

// extrasDelta returns the extras of st with every key whose value is UNCHANGED
// since prev removed, and reports whether anything was dropped.
//
// WHY PER KEY AND NOT PER LINE, which is the intuitive version and is worth
// almost nothing: on a real 3-minute Pseudoregalia recording only 274 of 15,761
// lines carried an extras block identical to the one before it, because
// h_speed, v_speed and slide_t jitter every single frame -- while every OTHER
// one of the 40 keys changed on 117 lines or fewer. Dropping unchanged KEYS is
// 4.4x; dropping unchanged LINES is 2%. Measured, agent_docs/scaling.md.
//
// A key that DISAPPEARS between two samples is kept as an explicit JSON null,
// because "absent" already means "unchanged" and the two must not collide --
// an adapter that stops reporting a field would otherwise have its last value
// carried forward forever.
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

// sameExtra compares two decoded JSON values. Deliberately structural rather
// than reflect.DeepEqual: the values here come from json.Unmarshal (floats,
// strings, bools, nil, and arrays/maps of those), and a cheap switch over
// exactly those shapes runs on every recorded frame.
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

// replayFileName is rec-YYYYMMDD-HHMMSS.ndjson, or last-... for a save-last
// file; a same-second collision gets a -2, -3 suffix rather than O_EXCL failing.
func replayFileName(dir, prefix string, at time.Time, gz bool) string {
	ext := ".ndjson"
	if gz {
		ext += ".gz"
	}
	base := prefix + "-" + at.Format("20060102-150405")
	path := filepath.Join(dir, base+ext)
	for n := 2; ; n++ {
		if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
			return path
		}
		path = filepath.Join(dir, fmt.Sprintf("%s-%d%s", base, n, ext))
	}
}

// StartRecording arms the file tap. The path is decided now and returned, but
// the file is created at the first sample (see recorder). ReplayDir must be
// set; an empty one is refused so nothing is ever written "beside the exe" by
// accident.
func (c *Core) StartRecording() (string, error) {
	if c.ReplayDir == "" {
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
	c.rec.dir = c.ReplayDir
	c.rec.gzip = c.ReplayGzip
	c.rec.delta = c.ReplayDelta
	c.rec.prevExtras = nil
	c.rec.path = replayFileName(c.ReplayDir, "rec", time.Now(), c.rec.gzip) // wall-clock: a filename, deduplicated against the real filesystem
	c.rec.header = c.replayHeaderFor(game, version, time.Now())             // wall-clock: an artefact timestamp
	// After the header is built, not before: replayHeaderFor returns a fresh
	// one and would otherwise wipe this.
	c.rec.header.Delta = c.ReplayDelta
	c.rec.keepaliveMs = keepalive.Milliseconds()
	c.rec.clk = c.timeSrc
	c.rec.on = true
	atomic.StoreUint32(&c.tapArmed, 1)
	// The adapter compares this against its OWN clock in another process, which cannot see
	// c.clk(); the bridge is loopback-only, so the two are on one machine and a wall clock is
	// the only shared one. Nothing inside the core reads it.
	c.rec.startedUnixMs = time.Now().UnixMilli() // wall-clock: read by the adapter, not by the core
	log.Printf("core: recording to %s (the file appears at the first in-game sample)", c.rec.path)
	// The adapter draws the indicator, so it has to be told the moment this
	// flips -- see pushRecordingState for why a console line was not enough.
	//
	// The VALUES variant, because c.rec.mu is held here by the defer above and
	// the plain one would ask the recorder for state it cannot answer for while
	// locked. That deadlock is what the first version of this line caused.
	c.pushRecordingStateValues(true, c.rec.startedUnixMs)
	return c.rec.path, nil
}

// StopRecording closes the file. written is 0 when no sample ever arrived, in
// which case no file exists and path is "".
func (c *Core) StopRecording() (path string, written int, err error) {
	c.rec.mu.Lock()
	on := c.rec.on
	path, written, err = c.rec.closeLocked()
	c.rec.mu.Unlock()
	c.rearmTap()
	c.pushRecordingState()
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

// SetRingSpan turns the recent-sample ring on (span > 0) or off. The ring is
// what SaveLast drains and what the chaser reads; each caller asks for the span
// it needs and the ring keeps the longest.
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

// SaveLast writes what the ring holds -- the last SaveLastSpan of play -- to
// replay/last-YYYYMMDD-HHMMSS.ndjson with the same header a recording gets.
// Independent of a running recording: the ring is fed by the same tap either
// way. The "do a trick, then press the key" mode: nothing is ever armed from
// the player's point of view, and the file is written after the fact.
func (c *Core) SaveLast() (string, int, error) {
	if c.ReplayDir == "" {
		return "", 0, errors.New("no replay folder configured")
	}
	samples := c.ring.snapshot()
	if len(samples) == 0 {
		return "", 0, errors.New("nothing to save yet: no in-game samples in the last " + c.SaveLastSpan.String())
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

	if err := os.MkdirAll(c.ReplayDir, 0o755); err != nil {
		return "", 0, fmt.Errorf("create %s: %w", c.ReplayDir, err)
	}
	path := replayFileName(c.ReplayDir, "last", time.Now(), c.ReplayGzip) // wall-clock: a filename, as above
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return "", 0, fmt.Errorf("create %s: %w", path, err)
	}
	var sink io.Writer = f
	var gz *gzip.Writer
	if c.ReplayGzip {
		gz = gzip.NewWriter(f)
		sink = gz
	}
	w := bufio.NewWriterSize(sink, 64*1024)
	hdr := c.replayHeaderFor(game, version, time.Now()) // wall-clock: an artefact timestamp
	hdr.Delta = c.ReplayDelta
	// recorded is when the clip STARTS, which for a save-last file is the
	// oldest sample's moment, not the key press.
	// wall-clock: an artefact timestamp, back-dated from sample timestamps that ARE virtual.
	// Mixed on purpose and harmless: the result is a human-readable string in a file header,
	// never compared against anything.
	hdr.Recorded = time.Now().Add(-time.Duration(samples[len(samples)-1].Timestamp-samples[0].Timestamp) * time.Millisecond).UTC().Format(time.RFC3339) // wall-clock: an artefact timestamp
	if err := writeReplayLine(w, hdr); err != nil {
		f.Close()
		return "", 0, err
	}
	var prevExtras map[string]any
	for i := range samples {
		samples[i].Seq = uint64(i + 1)
		out := roundedForFile(samples[i])
		if c.ReplayDelta {
			full := out.Extras
			out.Extras = extrasDelta(prevExtras, full)
			prevExtras = full
		}
		if err := writeReplayLine(w, out); err != nil {
			f.Close()
			return "", 0, err
		}
	}
	if err := w.Flush(); err != nil {
		f.Close()
		return "", 0, err
	}
	if gz != nil {
		if err := gz.Close(); err != nil {
			f.Close()
			return "", 0, err
		}
	}
	if err := f.Close(); err != nil {
		return "", 0, err
	}
	span := time.Duration(samples[len(samples)-1].Timestamp-samples[0].Timestamp) * time.Millisecond
	log.Printf("core: saved the last %s (%d samples) to %s", span.Round(time.Millisecond), len(samples), path)
	return path, len(samples), nil
}

// armRing sizes the ring for every consumer that needs recent samples: the
// save-last key wants SaveLastSpan. (The chaser adds its own need later; the
// ring keeps the longest.) Called when the adapter attaches.
func (c *Core) armRing() {
	span := c.SaveLastSpan
	if span > 0 {
		c.SetRingSpan(span)
	}
}

// flushRecordingIfOpen pushes whatever the recorder has buffered out to disk,
// so a reader looking at the file right now sees complete lines up to this
// moment. A no-op when nothing is recording.
//
// Exists for the replay-last hotkey, which reads the newest file in the folder
// and will happily pick the one still being written.
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
