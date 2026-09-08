package core

// Reading an input track back (ADR 0056), and finding a clip's track (ADR 0057).
//
// Written a day before anything played one, and deliberately: the moment one
// person sends another a track, the file is a stranger's bytes, and a parser
// written later under the pressure of a feature is a parser written without
// this file's caution. Since ADR 0057 a replay streams its track to an adapter
// that asked (replayinputs.go); this file still only READS.
//
// Same defensive posture as parseReplay, for the same reasons and in the same
// order: the line cap applied BEFORE decoding, a hard sample ceiling, a
// tolerated half-written FINAL line and nothing else tolerated, and every edge
// re-validated against the bounds the bridge would have applied.

import (
	"bufio"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// inputMaxEdges bounds memory the way replayMaxSamples does: a whole track is
// held as a slice, so the ceiling is what stands between a hand-made file and
// the process.
const inputMaxEdges = 2_000_000

// inputTrack is a parsed track: its header, and its edges in order.
type inputTrack struct {
	file   string
	header inputHeader
	edges  []inputEdgeLine
}

// loadInputTrack reads one .ndjson or .ndjson.gz track from disk.
//
// No zip case HERE: a track only ever travels inside its clip's zip, and
// loadReplayAll routes such an entry to parseInputTrackLimited under the
// archive's own edge budget (ADR 0057).
func loadInputTrack(path string) (*inputTrack, error) {
	name := filepath.Base(path)
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
	return parseInputTrack(r, name)
}

// parseInputTrack is loadInputTrack on a stream, and the fuzz target's entry.
func parseInputTrack(r io.Reader, name string) (*inputTrack, error) {
	return parseInputTrackLimited(r, name, inputMaxEdges)
}

// parseInputTrackLimited is parseInputTrack with the edge cap supplied, so a
// zip can spend one budget across all the tracks it holds (loadReplayAll,
// ADR 0057) the way it does for its clips.
func parseInputTrackLimited(r io.Reader, name string, maxEdges int) (*inputTrack, error) {
	if maxEdges > inputMaxEdges {
		maxEdges = inputMaxEdges
	}
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
	var hdr inputHeader
	if err := json.Unmarshal(sc.Bytes(), &hdr); err != nil {
		return nil, fmt.Errorf("%s: line 1 is not an input-track header: %w", name, err)
	}
	// The check that makes a misplaced file fail with a sentence. A replay clip
	// handed to this parser has no meshghost_inputs key and is refused here,
	// exactly as a track handed to parseReplay is refused there for having no
	// meshghost_replay key.
	if hdr.Format == 0 {
		return nil, fmt.Errorf("%s: line 1 has no meshghost_inputs key -- not an input track", name)
	}
	if hdr.Format > inputFormatVersion {
		log.Printf("core: input track %s is format %d, this build reads %d -- reading what it understands",
			name, hdr.Format, inputFormatVersion)
	}
	// A label table longer than the mask is wide names buttons no edge can
	// ever set, so the file disagrees with itself about its own shape.
	if len(hdr.Labels) > bridge.MaxInputLabels {
		return nil, fmt.Errorf("%s: %d labels, over the %d the mask has bits for",
			name, len(hdr.Labels), bridge.MaxInputLabels)
	}

	track := &inputTrack{file: name, header: hdr}
	line := 1
	for sc.Scan() {
		line++
		raw := sc.Bytes()
		if len(strings.TrimSpace(string(raw))) == 0 {
			continue
		}
		var e inputEdgeLine
		if err := json.Unmarshal(raw, &e); err != nil {
			// A half-written FINAL line is not a broken file -- the writer
			// flushes on a clock, so a track read while it is still being
			// written ends mid-line. Only the last one, and only a decode
			// failure: anything after a bad line means a corrupt file.
			if !sc.Scan() {
				log.Printf("core: input track %s: line %d is incomplete and was dropped -- the file "+
					"was still being written, or the game that wrote it did not close it", name, line)
				break
			}
			return nil, fmt.Errorf("%s: line %d: %w", name, line, err)
		}
		// Every edge meets the bounds the bridge would have applied, whatever
		// wrote the file. ValidateInputSample is reused rather than reimplemented
		// so a file and a batch can never be held to different rules.
		if !bridge.ValidateInputSample(bridge.InputSample{
			Edges: []bridge.InputEdge{{F: e.F, T: e.T, M: e.M, Ax: e.Ax}},
		}) {
			return nil, fmt.Errorf("%s: line %d: %s", name, line,
				bridge.InputSampleRejectReason(bridge.InputSample{
					Edges: []bridge.InputEdge{{F: e.F, T: e.T, M: e.M, Ax: e.Ax}},
				}))
		}
		if e.Ts < 0 {
			return nil, fmt.Errorf("%s: line %d: ts %d is before the epoch", name, line, e.Ts)
		}
		// Ordering is the property a reader is allowed to trust absolutely, so
		// it is enforced on the way in rather than assumed. Checked on ts as
		// well as on the adapter's own counters: a track whose core stamps go
		// backwards would put a later edge earlier in any correlation with the
		// state recording.
		if n := len(track.edges); n > 0 {
			prev := track.edges[n-1]
			if e.Ts < prev.Ts || e.F < prev.F || e.T < prev.T {
				return nil, fmt.Errorf("%s: line %d: goes backwards (ts %d/frame %d/t %d after %d/%d/%d)",
					name, line, e.Ts, e.F, e.T, prev.Ts, prev.F, prev.T)
			}
		}
		track.edges = append(track.edges, e)
		if len(track.edges) > maxEdges {
			return nil, fmt.Errorf("%s: over %d edges", name, maxEdges)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	return track, nil
}

// inputIndexScanMax bounds how many tracks a lookup will open. A header read
// each is cheap; ten thousand of them on the hello goroutine is not, and
// nobody has a folder that size yet. Newest first, so the ones that matter
// are inside the bound.
const inputIndexScanMax = 2000

// loadInputTrackHeader reads only a track's first line -- what the lookup by
// recording_id needs, without paying for the edges.
func loadInputTrackHeader(path string) (inputHeader, error) {
	var hdr inputHeader
	f, err := os.Open(path)
	if err != nil {
		return hdr, err
	}
	defer f.Close()
	var r io.Reader = f
	if strings.HasSuffix(strings.ToLower(path), ".gz") {
		gz, err := gzip.NewReader(f)
		if err != nil {
			return hdr, err
		}
		defer gz.Close()
		r = gz
	}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 4096), protocol.MaxLineBytes)
	if !sc.Scan() {
		if err := sc.Err(); err != nil {
			return hdr, err
		}
		return hdr, fmt.Errorf("empty file")
	}
	if err := json.Unmarshal(sc.Bytes(), &hdr); err != nil {
		return hdr, err
	}
	if hdr.Format == 0 {
		return hdr, fmt.Errorf("no meshghost_inputs key")
	}
	return hdr, nil
}

// inputTrackIndex maps recording_id -> track path for every track in
// replay/inputs/, newest file first so a duplicate id resolves to the most
// recent take. Built per replay load, on demand, and only for an adapter
// that asked for tracks (ADR 0057) -- StartReplays never calls it otherwise,
// which TestReplayTrackIsNeverSentToAnAdapterThatDidNotAsk pins through the
// inputTrackScans counter.
//
// NO ON-DISK INDEX, deliberately: one header read per file is a fraction of
// a second at a thousand tracks nobody has, while an index file would add a
// write path, a staleness case and a corruption case for that saving.
func (c *Core) inputTrackIndex() map[string]string {
	atomic.AddUint32(&c.inputTrackScans, 1)
	dir := c.inputsDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("core: input tracks folder %s: %v", dir, err)
		}
		return nil
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
		if !strings.HasSuffix(lower, ".ndjson") && !strings.HasSuffix(lower, ".ndjson.gz") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		cands = append(cands, cand{e.Name(), info.ModTime()})
	}
	sort.Slice(cands, func(i, j int) bool { return cands[i].mod.After(cands[j].mod) })
	if len(cands) > inputIndexScanMax {
		log.Printf("core: %s holds %d input tracks; only the newest %d are looked at for a replay's track",
			dir, len(cands), inputIndexScanMax)
		cands = cands[:inputIndexScanMax]
	}
	idx := make(map[string]string, len(cands))
	for _, cd := range cands {
		// The listing's own name, joined and cleaned: nothing in a file
		// chooses a path.
		path := filepath.Join(dir, filepath.Base(cd.name))
		hdr, err := loadInputTrackHeader(path)
		if err != nil || hdr.RecordingID == "" {
			continue
		}
		if _, dup := idx[hdr.RecordingID]; dup {
			continue // newest wins; the listing is sorted that way
		}
		idx[hdr.RecordingID] = path
	}
	return idx
}

// attachTrackFromIndex finds and attaches a clip's track, logging what it
// found either way -- silence here would be a ghost with no inputs and
// nothing anywhere saying why.
func (c *Core) attachTrackFromIndex(clip *replayClip, name string, idx map[string]string) {
	path, ok := idx[clip.header.RecordingID]
	if !ok {
		log.Printf("core: replay %s: no input track for recording_id %q in %s", name, clip.header.RecordingID, c.inputsDir())
		return
	}
	tr, err := loadInputTrack(path)
	if err != nil {
		log.Printf("core: replay %s: input track refused: %v", name, err)
		return
	}
	clip.attachTrack(tr)
	log.Printf("core: replay %s: input track %s (%d edges inside the clip)", name, filepath.Base(path), len(clip.track.edges))
}
