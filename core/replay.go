package core

// Playback: a recorded run as a local fake peer. Every file in <ReplayDir>/active/ is loaded when the adapter attaches
// and starts at the player's first in-game frame, so a ghost lines up with the run. Each sample is rebased onto nowMs
// (the first at start plus start_delay, then the recorded spacing divided by speed) and fed to feedLocalPeer when due;
// after that it is the ordinary peer path, rendered cosmetic.
//
// Seams: the buffer blends across any gap in one area, so whatever must look like a jump (the loop's end to start, a
// recorded gap over replayGapSeamMs, a cut skip_gaps made) is a leave and a rejoin, with one render tick between so the
// despawn reaches the adapter.
//
// A file is as trusted as a stranger's packets and enters by the same door: every sample passes ValidateState in
// storeRemoteState, lines are capped at the wire's limit before decoding, the header's name and colour are sanitized,
// speed and durations are clamped, and nothing in a file becomes a path.

import (
	"archive/zip"
	"bufio"
	"bytes"
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
	// replayGapSeamMs: a recorded gap longer than this is a seam, not a blend.
	replayGapSeamMs = 1500
	// replayMaxSamples bounds how many samples one file holds (memory is replayMaxBytes' job): ~11 hours at 50Hz.
	replayMaxSamples = 2_000_000
	replaySpeedMin   = 0.1
	replaySpeedMax   = 4.0
	replayMaxDelay   = time.Hour
	// replayBackstepMs: nowMs can step back when a relay session is forgotten mid-replay; a step this large is a seam
	// and the clip is re-based, never fed out of order.
	replayBackstepMs = 500
)

// replayMaxSamplesPerArchive bounds one zip as replayMaxSamples bounds one file: an archive may hold any number of
// clips, and together they may cost no more than one clip. A var so a test can shrink it.
var replayMaxSamplesPerArchive = replayMaxSamples

// replayMaxBytes is what one clip, and one archive, may cost in held samples. A sample count is no memory bound: what a
// line costs to hold tracks its decoded nodes, not its length (a short line of nested extras costs far more than a long
// flat one), so the cost is charged per node. A var so a test can shrink it.
var replayMaxBytes = 256 << 20

const (
	// replaySampleBaseCost is a held protocol.State with nothing in it: 126 B measured, rounded up so the estimate errs
	// high.
	replaySampleBaseCost = 128
	// replayContainerCost is one decoded map or slice: a two-entry Go map measures ~340 B all-in.
	replayContainerCost = 384
	// replayEntryCost is one key/value inside a container (interface header, key string, bucket slot): ~46 B measured
	// across a 90-key map.
	replayEntryCost = 64
	// replayCostWalkLimit stops the walk on a pathological tree, returning the budget-busting figure: an estimate that
	// gave up must never read as cheap.
	replayCostWalkLimit = 4096
)

// replaySampleCost estimates what holding st costs, in bytes. An over-estimate on purpose: it is a refusal threshold,
// and the failure that matters is letting something through.
func replaySampleCost(st *protocol.State) int {
	n := replaySampleBaseCost + len(st.AreaID) + len(st.Anim) + len(st.Orientation)
	nodes := 0
	n += replayValueCost(st.Extras, &nodes)
	return n
}

// replayValueCost walks one decoded JSON value. nodes carries the budget across the whole tree, so a wide and shallow
// shape is bounded as well as a deep one.
func replayValueCost(v any, nodes *int) int {
	*nodes++
	if *nodes > replayCostWalkLimit {
		return replayMaxBytes
	}
	switch t := v.(type) {
	case map[string]any:
		n := replayContainerCost + len(t)*replayEntryCost
		for k, e := range t {
			n += len(k) + replayValueCost(e, nodes)
		}
		return n
	case []any:
		n := replayContainerCost + len(t)*replayEntryCost
		for _, e := range t {
			n += replayValueCost(e, nodes)
		}
		return n
	case string:
		return len(t)
	default:
		// A number, bool or null, already paid for by its container's entry cost.
		return 0
	}
}

// replayClip is a loaded file: the sanitized header, the samples after trim, and the seams skip_gaps introduced.
type replayClip struct {
	file       string // base name, for ids and logs
	header     replayHeader
	samples    []protocol.State
	t0         int64
	speed      float64
	startDelay time.Duration
	loop       bool
	forcedSeam map[int]bool // sample index -> a gap was cut before it

	// What applyTrim and applySkipGaps did, kept so attachTrack can put a track through the same: the raw stamps of the
	// first and last surviving sample, and every gap cut in order.
	trimFirst, trimLast int64
	gapCuts             []gapCut
	// track is the clip's input track, mapped into the clip's own stamp domain, or nil for a clip that has none or an
	// adapter that did not ask.
	track *inputTrack
}

// duration returns the clip's length at speed 1.
func (rc *replayClip) duration() time.Duration {
	if len(rc.samples) == 0 {
		return 0
	}
	return time.Duration(rc.samples[len(rc.samples)-1].Timestamp-rc.t0) * time.Millisecond
}

// loadReplay reads one file: a plain .ndjson, a .ndjson.gz, or a .zip holding one of those. The recorder never writes a
// zip; reading one saves the recipient of a zipped clip a step. Nothing is extracted to disk, and parseReplay bounds
// line length and size whatever the stream claims.
func loadReplay(path string, wantTracks bool) (*replayClip, error) {
	name := filepath.Base(path)
	if strings.HasSuffix(strings.ToLower(path), ".zip") {
		return loadReplayZip(path, name, wantTracks)
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

// loadedClip is one clip and its name: the file's own, or "<archive>/<entry>" for one from a zip.
type loadedClip struct {
	name string
	clip *replayClip
}

// loadReplayAll reads every clip in one file. A zip of three clips is three ghosts: replay/active/ means everything in
// it plays, so a zip behaves like a folder.
func loadReplayAll(path string, wantTracks bool) ([]loadedClip, error) {
	name := filepath.Base(path)
	if !strings.HasSuffix(strings.ToLower(path), ".zip") {
		clip, err := loadReplay(path, wantTracks)
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
	// One budget for the whole archive, spent as entries are read: each may be a full clip, but not the hundredth.
	budget := replayMaxSamplesPerArchive
	// The same budget in bytes, the unit that bounds memory.
	byteBudget := replayMaxBytes
	// A zip may carry its clips' input tracks: an entry whose first line is an input header is matched to a clip by
	// recording_id once every entry is read, under its own budget.
	trackBudget := replayMaxTrackEdgesPerArchive
	var tracks []*inputTrack
	// The archive's own order, as the person made it. An entry that is not a clip (a readme, a screenshot) is skipped,
	// not refused.
	for _, entry := range zr.File {
		if entry.FileInfo().IsDir() {
			continue
		}
		lower := strings.ToLower(entry.Name)
		if !strings.HasSuffix(lower, ".ndjson") && !strings.HasSuffix(lower, ".ndjson.gz") {
			continue
		}
		inner := name + "/" + filepath.Base(entry.Name)
		if isTrack, err := zipEntryIsInputTrack(entry); err != nil {
			log.Printf("core: replay skipped: %s: %v", inner, err)
			continue
		} else if isTrack {
			// An adapter that never asked for input tracks is not given one; refusing here also saves the parse.
			if !wantTracks {
				continue
			}
			if trackBudget <= 0 {
				log.Printf("core: replay: %s holds more than %d input edges in total -- "+
					"the remaining tracks are not loaded", name, replayMaxTrackEdgesPerArchive)
				continue
			}
			tr, err := readZipInputTrack(entry, inner, trackBudget)
			if err != nil {
				log.Printf("core: replay: input track skipped: %v", err)
				continue
			}
			trackBudget -= len(tr.edges)
			tracks = append(tracks, tr)
			continue
		}
		if budget <= 0 || byteBudget <= 0 {
			// Said once: an archive built to exhaust this has plenty of entries left to flood the log.
			log.Printf("core: replay: %s is past the whole-archive budget (%d samples or %d MB) -- "+
				"the rest of it is not loaded (one zip may cost as much memory as one clip, no more)",
				name, replayMaxSamplesPerArchive, replayMaxBytes>>20)
			break
		}
		// The clip count is bounded too, by the roster: every clip is a goroutine and a seat, and N one-sample clips
		// cost the budgets almost nothing.
		if len(out) >= protocol.MaxRosterSize {
			log.Printf("core: replay: %s holds more than %d clips -- the rest are not loaded, "+
				"because every clip takes one of the seats replays and chasers share",
				name, protocol.MaxRosterSize)
			break
		}
		clip, spent, err := readZipEntry(entry, inner, budget, byteBudget)
		if err != nil {
			// One bad entry does not condemn the archive; what it read is still spent.
			log.Printf("core: replay skipped: %v", err)
			byteBudget -= spent
			continue
		}
		budget -= len(clip.samples)
		byteBudget -= spent
		out = append(out, loadedClip{name: inner, clip: clip})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%s: no .ndjson inside", name)
	}
	// Match by recording_id. Unmatched either way is said: a track with no clip is the wrong pair zipped, and a clip
	// with no track predates one.
	for _, tr := range tracks {
		matched := false
		for _, lc := range out {
			if tr.header.RecordingID != "" && lc.clip.header.RecordingID == tr.header.RecordingID {
				lc.clip.attachTrack(tr)
				matched = true
			}
		}
		if !matched {
			log.Printf("core: replay: %s: input track %s matches no clip in the archive (recording_id %q)",
				name, tr.file, tr.header.RecordingID)
		}
	}
	return out, nil
}

// zipEntryIsInputTrack peeks an entry's first line for the input header's key; a clip's has meshghost_replay, and
// anything else is refused by whichever parser gets it.
func zipEntryIsInputTrack(entry *zip.File) (bool, error) {
	rc, err := entry.Open()
	if err != nil {
		return false, err
	}
	defer rc.Close()
	var r io.Reader = rc
	if strings.HasSuffix(strings.ToLower(entry.Name), ".gz") {
		gz, err := gzip.NewReader(rc)
		if err != nil {
			return false, fmt.Errorf("not a gzip file: %w", err)
		}
		defer gz.Close()
		r = gz
	}
	// The wire's line cap: a longer first line is not a header of either kind.
	head := make([]byte, protocol.MaxLineBytes)
	n, _ := io.ReadFull(r, head)
	head = head[:n]
	if i := bytes.IndexByte(head, '\n'); i >= 0 {
		head = head[:i]
	}
	return bytes.Contains(head, []byte(`"meshghost_inputs"`)), nil
}

func readZipInputTrack(entry *zip.File, name string, maxEdges int) (*inputTrack, error) {
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
	return parseInputTrackLimited(r, name, maxEdges)
}

func readZipEntry(entry *zip.File, name string, maxSamples, maxBytes int) (*replayClip, int, error) {
	rc, err := entry.Open()
	if err != nil {
		return nil, 0, fmt.Errorf("%s: %w", name, err)
	}
	defer rc.Close()
	var r io.Reader = rc
	if strings.HasSuffix(strings.ToLower(entry.Name), ".gz") {
		gz, err := gzip.NewReader(rc)
		if err != nil {
			return nil, 0, fmt.Errorf("%s: not a gzip file: %w", name, err)
		}
		defer gz.Close()
		r = gz
	}
	// What this entry read is charged to the archive whether or not it became a clip, or an entry that errors
	// (whitespace, say) could be repeated for free.
	counted := &scanCappedReader{r: r, left: maxBytes}
	clip, spent, err := parseReplayWithin(counted, name, maxSamples, maxBytes)
	if counted.read > spent {
		spent = counted.read
	}
	return clip, spent, err
}

// errReplayScanBudget is what scanCappedReader returns past its budget.
var errReplayScanBudget = errors.New("the replay read budget is spent")

// scanCappedReader reads at most left bytes from r, then fails with errReplayScanBudget, and counts what it read.
type scanCappedReader struct {
	r    io.Reader
	left int
	read int
}

func (s *scanCappedReader) Read(p []byte) (int, error) {
	if s.left <= 0 {
		return 0, errReplayScanBudget
	}
	if len(p) > s.left {
		p = p[:s.left]
	}
	n, err := s.r.Read(p)
	s.left -= n
	s.read += n
	return n, err
}

// loadReplayZip reads the first clip in a zip, for the one caller that plays exactly one file (the replay-last hotkey).
func loadReplayZip(path, name string, wantTracks bool) (*replayClip, error) {
	all, err := loadReplayAll(path, wantTracks)
	if err != nil {
		return nil, err
	}
	return all[0].clip, nil
}

// parseReplay is loadReplay on a stream, and the fuzz target's entry.
func parseReplay(r io.Reader, name string) (*replayClip, error) {
	return parseReplayLimited(r, name, replayMaxSamples)
}

// parseReplayLimited takes the sample cap, so a zip can spend one budget across all its entries.
func parseReplayLimited(r io.Reader, name string, maxSamples int) (*replayClip, error) {
	clip, _, err := parseReplayWithin(r, name, maxSamples, replayMaxBytes)
	return clip, err
}

// parseReplayWithin also takes the memory budget and returns what the clip spent, so an archive can subtract. The two
// budgets are spent together because neither implies the other.
func parseReplayWithin(r io.Reader, name string, maxSamples, maxBytes int) (*replayClip, int, error) {
	if maxSamples > replayMaxSamples {
		maxSamples = replayMaxSamples
	}
	if maxBytes > replayMaxBytes {
		maxBytes = replayMaxBytes
	}
	spent := 0
	// The bytes read are bounded too: a blank line costs no sample, so a gzip of whitespace was unbounded scanning on
	// the bridge's hello handler. The cap is the memory budget, since a line costs more to hold than to read.
	sc := bufio.NewScanner(&scanCappedReader{r: r, left: maxBytes})
	// The wire's line cap, before decoding: a longer line is refused, never allocated for.
	sc.Buffer(make([]byte, 0, 4096), protocol.MaxLineBytes)

	if !sc.Scan() {
		if err := sc.Err(); err != nil {
			return nil, 0, fmt.Errorf("%s: %w", name, err)
		}
		return nil, 0, fmt.Errorf("%s: empty file", name)
	}
	var hdr replayHeader
	if err := json.Unmarshal(sc.Bytes(), &hdr); err != nil {
		return nil, 0, fmt.Errorf("%s: line 1 is not a replay header: %w", name, err)
	}
	if hdr.Format == 0 {
		return nil, 0, fmt.Errorf("%s: line 1 has no meshghost_replay key -- not a replay file", name)
	}
	if hdr.Format > replayFormatVersion {
		log.Printf("core: replay %s is format %d, this build reads %d -- playing what it understands", name, hdr.Format, replayFormatVersion)
	}

	clip := &replayClip{file: name, forcedSeam: map[int]bool{}}
	clip.header = sanitizeReplayHeader(hdr)
	clip.speed = clip.header.Speed
	clip.loop = clip.header.Loop
	clip.startDelay = parseReplayDuration(clip.header.StartDelay)

	// Delta files carry only what changed: an absent extras key means unchanged, an explicit null that the key went
	// away. Reconstructed here, before validation, so everything downstream sees the samples a non-delta file would
	// give. The carry-forward is a running value, so deleting a line by hand loses only that line's changes.
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
			// A half-written last line is a recording still being written, or one whose process was killed, and the
			// rest still plays. Only the last line and only a decode failure: a bad line with anything after it is a
			// corrupt file.
			if !sc.Scan() {
				log.Printf("core: replay %s: line %d is incomplete and was dropped -- the file was "+
					"still being written, or the game that wrote it did not close it", name, line)
				break
			}
			return nil, 0, fmt.Errorf("%s: line %d: %w", name, line, err)
		}
		st.PlayerID = ""
		st.Prev = nil
		if hdr.Delta {
			st.Extras = mergeCarriedExtras(carried, st.Extras)
			carried = st.Extras
		}
		// The caps a relay packet meets, which also keep a hand-edited file from reaching the adapter malformed.
		if !protocol.ValidateState(st) {
			return nil, 0, fmt.Errorf("%s: line %d: %s", name, line, protocol.StateRejectReason(st))
		}
		if len(clip.samples) > 0 && st.Timestamp < clip.samples[len(clip.samples)-1].Timestamp {
			return nil, 0, fmt.Errorf("%s: line %d: timestamp %d goes backwards (previous %d)", name, line, st.Timestamp, clip.samples[len(clip.samples)-1].Timestamp)
		}
		if len(clip.samples) >= maxSamples {
			return nil, 0, fmt.Errorf("%s: more than %d samples", name, maxSamples)
		}
		// The memory budget, charged from the decoded sample: what a line costs to hold has little to do with its
		// length.
		spent += replaySampleCost(&st)
		if spent > maxBytes {
			return nil, 0, fmt.Errorf("%s: line %d takes it past %d MB of samples -- "+
				"a clip is bounded by what it costs to hold, not only by how many lines it has",
				name, line, maxBytes>>20)
		}
		clip.samples = append(clip.samples, st)
	}
	if err := sc.Err(); err != nil {
		if errors.Is(err, bufio.ErrTooLong) {
			return nil, 0, fmt.Errorf("%s: line %d is longer than %d bytes", name, line+1, protocol.MaxLineBytes)
		}
		if errors.Is(err, errReplayScanBudget) {
			return nil, 0, fmt.Errorf("%s: more than %d MB to read -- %w", name, maxBytes>>20, err)
		}
		return nil, 0, fmt.Errorf("%s: %w", name, err)
	}
	if len(clip.samples) == 0 {
		return nil, 0, fmt.Errorf("%s: header only, no samples", name)
	}

	clip.applyTrim()
	clip.applySkipGaps()
	if len(clip.samples) == 0 {
		return nil, 0, fmt.Errorf("%s: trim left no samples", name)
	}
	clip.t0 = clip.samples[0].Timestamp
	return clip, spent, nil
}

// mergeCarriedExtras applies one delta line's extras onto the running value. A nil result stays nil rather than
// becoming an empty map, so a clip whose game sends no extras at all loads as a non-delta one would.
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
			// An explicit null is the key going away; absence already means unchanged.
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

// sanitizeReplayHeader clamps every player-editable key. The recorder-written keys are passed through: they are read
// for a warning and nothing else.
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

// parseReplayDuration is time.ParseDuration clamped to [0, replayMaxDelay]; anything unparseable is 0.
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

// applyTrim drops samples before trim_start (or, for "auto", before the position first changes) and after the last
// sample minus trim_end.
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
	if len(rc.samples) > 0 {
		rc.trimFirst = rc.samples[0].Timestamp
		rc.trimLast = rc.samples[len(rc.samples)-1].Timestamp
	}
}

// applySkipGaps collapses every gap longer than skip_gaps to one millisecond and marks a forced seam there, so cut
// time is a jump and never a blend.
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
			rc.gapCuts = append(rc.gapCuts, gapCut{from: orig - gap, to: orig, shift: shift})
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
	// ctrl carries seeks from ReplayControl, buffered so a key held down never blocks the caller.
	ctrl    chan replayCmd
	started uint32

	split splitState
	// in is the input track cursor (replayinputs.go); touched only by run().
	in inputStream

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

// replayWaitFor turns the milliseconds until the next sample into one sleep. Clamped in milliseconds before the
// conversion: multiplied by 1e6 first, a span reachable from a file (speed's 0.1 floor multiplies a validated span by
// ten) wraps negative, time.After returns at once, and the caller's loop hot-spins on c.mu.
func replayWaitFor(ms int64) time.Duration {
	if ms > 50 {
		ms = 50
	}
	if ms < 0 {
		ms = 0
	}
	return time.Duration(ms) * time.Millisecond
}

// sleepUntil waits for the clock to reach due, in slices short enough that a stop or a seek is noticed promptly. It
// returns a command if one arrived first; stopped means halted.
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
		wait := replayWaitFor(due - now)
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
	// One render tick that began after the drop carries the despawn (see ticksBegun). Bounded: an adapter in a menu
	// sends no frames, and a replay must not hang on it.
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
	// The track's cursor starts at the top with the ghost; every later admit re-aims it.
	p.inputReset(0)
	if clip.track != nil {
		log.Printf("core: replay %s: streaming its input track %s (%d edges) beside the frames",
			clip.file, clip.track.file, len(clip.track.edges))
	}
	delay := clip.startDelay
	if delay == 0 {
		p.c.mu.Lock()
		delay = p.c.replayStartDelay()
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
	// seek applies a control command: the ghost jumps to the new clip time through a seam. False means the clip is over
	// (a fast-forward past the end of a non-looping clip).
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
		if !p.seam(tag) {
			return false
		}
		p.inputReset(pos)
		return true
	}

	prevNow := p.c.nowMs()
	i := 0
	for {
		if i >= len(clip.samples) {
			if !clip.loop {
				// Hold the last sample long enough to be drawn: a ghost this core invented renders
				// LocalInterpolationDelay behind, and the deferred drop would otherwise despawn it first. A seek during
				// the hold still works.
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
			p.inputReset(0)
			continue
		}
		s := clip.samples[i]
		if i > 0 && (clip.forcedSeam[i] || s.Timestamp-clip.samples[i-1].Timestamp > replayGapSeamMs) {
			if !p.seam(tag) {
				return
			}
			// Edges past the gap may already have gone out ahead of it, and the adapter dropped them with the pawn:
			// send them again from here, behind a reset.
			p.inputReset(s.Timestamp - clip.t0)
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
			// The clock stepped back (a relay session reset mid-replay): re-base so this sample is due now, and make it
			// a seam so the buffer never sees time run backwards.
			setStart(now - (due - start))
			due = now
			if !p.seam(tag) {
				return
			}
			p.inputReset(s.Timestamp - clip.t0)
		}
		prevNow = now
		st := s
		st.Timestamp = due
		if !p.c.feedLocalPeer(p.id, st) {
			// Dropped from outside (StopReplays) or refused by a full roster after a reconnect; the player stops.
			if p.stopped() {
				return
			}
			log.Printf("core: replay %s: sample refused (roster full?), stopping", clip.file)
			return
		}
		p.mu.Lock()
		p.idx = i
		p.mu.Unlock()
		// After the sample, never before: a seam above has re-admitted the ghost by now, so the reset this may carry
		// lands behind the despawn.
		p.streamInputs(start, now)
		i++
	}
}

// StartReplays loads every file in <ReplayDir>/active/ and arms them to start at the player's first in-game frame.
// Called when the adapter attaches; safe to call again (running players are stopped first). Returns how many loaded.
func (c *Core) StartReplays() int {
	c.StopReplays()
	if c.replayDir() == "" {
		return 0
	}
	dir := filepath.Join(c.replayDir(), "active")
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
	wantTracks := c.adapterWantsInputTracks
	c.mu.Unlock()
	// Built lazily, once per call, and only for an adapter that asked: it reads a header per track on disk.
	var trackIndex map[string]string
	findTrack := func(clip *replayClip, name string) {
		if !wantTracks || clip.track != nil || clip.header.RecordingID == "" {
			return
		}
		if trackIndex == nil {
			trackIndex = c.inputTrackIndex()
		}
		c.attachTrackFromIndex(clip, name, trackIndex)
	}

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
			// Said out loud: a player who put one here is waiting for a ghost that will never come.
			log.Printf("core: replay %s ignored: only .ndjson, .ndjson.gz and .zip are read -- re-zip it as .zip", e.Name())
		}
	}
	sort.Strings(names)

	c.replayMu.Lock()
	defer c.replayMu.Unlock()
	c.pruneFinishedReplaysLocked()
	for _, name := range names {
		// The listing's own name, joined and cleaned: nothing inside a file chooses a path.
		path := filepath.Join(dir, filepath.Base(name))
		loaded, err := loadReplayAll(path, wantTracks)
		if err != nil {
			log.Printf("core: replay skipped: %v", err)
			continue
		}
		for _, lc := range loaded {
			name, clip := lc.name, lc.clip
			if game != "" && clip.header.Game != "" && clip.header.Game != game {
				log.Printf("core: replay %s skipped: recorded for game %q, this is %q", name, clip.header.Game, game)
				continue
			}
			if clip.header.Game == "" && game != "" {
				log.Printf("core: replay %s names no game; assuming it is for %q", name, game)
			}
			findTrack(clip, name)
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

// launchPendingReplays is the hook forwardLocalState calls on every non-nil frame: one atomic load, and on the first
// frame after StartReplays every loaded player starts.
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

// pruneFinishedReplaysLocked drops every player whose run has ended from c.replays, which otherwise keeps them, so the
// map counts live ghosts. Callers hold replayMu.
func (c *Core) pruneFinishedReplaysLocked() {
	for id, p := range c.replays {
		select {
		case <-p.done:
			delete(c.replays, id)
		default:
		}
	}
}

// StopReplays halts every player and drops its ghost. Called when the adapter detaches, so a relaunched game starts
// every replay from the top.
func (c *Core) StopReplays() {
	atomic.StoreUint32(&c.replaysPending, 0)
	c.replayMu.Lock()
	players := c.replays
	c.replays = nil
	c.replayMu.Unlock()
	for _, p := range players {
		p.halt()
	}
	// One second for all the players together, not one each: this runs on the bridge's hello goroutine, across the
	// attach path. Past the budget a straggler exits on its next read of the stop channel, and its ghost goes either
	// way.
	budget := time.NewTimer(time.Second) // wall-clock: a shutdown join -- virtual would turn a leak into a hang
	defer budget.Stop()
	spent := false
	for _, p := range players {
		if p.running() {
			if spent {
				select {
				case <-p.done:
				default:
				}
			} else {
				select {
				case <-p.done:
				case <-budget.C:
					spent = true
				}
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
