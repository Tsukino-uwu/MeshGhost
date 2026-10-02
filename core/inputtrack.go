package core

// Reading an input track back, and finding a clip's track. A track someone sent is a stranger's bytes, so this keeps
// parseReplay's posture: the line cap before decoding, a hard edge ceiling, only a half-written final line tolerated,
// and every edge re-validated against the bridge's bounds.

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

// inputMaxEdges bounds memory: a whole track is held as a slice.
const inputMaxEdges = 2_000_000

type inputTrack struct {
	file   string
	header inputHeader
	edges  []inputEdgeLine
}

// loadInputTrack reads one .ndjson or .ndjson.gz track. There is no zip case: a track travels only inside its clip's
// zip, which loadReplayAll parses under the archive's edge budget.
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

// parseInputTrackLimited takes the edge cap, so a zip can spend one budget across all its tracks.
func parseInputTrackLimited(r io.Reader, name string, maxEdges int) (*inputTrack, error) {
	// Bounded by bytes read as well as edges kept: a blank line costs neither.
	r = &scanCappedReader{r: r, left: replayMaxBytes}
	if maxEdges > inputMaxEdges {
		maxEdges = inputMaxEdges
	}
	sc := bufio.NewScanner(r)
	// The wire's line cap, before decoding: a longer line is refused, never allocated for.
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
	// A replay clip has no meshghost_inputs key, so a misplaced file is refused with a sentence.
	if hdr.Format == 0 {
		return nil, fmt.Errorf("%s: line 1 has no meshghost_inputs key -- not an input track", name)
	}
	if hdr.Format > inputFormatVersion {
		log.Printf("core: input track %s is format %d, this build reads %d -- reading what it understands",
			name, hdr.Format, inputFormatVersion)
	}
	// More labels than the mask has bits names buttons no edge can set.
	if len(hdr.Labels) > bridge.MaxInputLabels {
		return nil, fmt.Errorf("%s: %d labels, over the %d the mask has bits for",
			name, len(hdr.Labels), bridge.MaxInputLabels)
	}
	// The header's tables get the bridge's own check, which the per-edge validation below never applies to them.
	if !bridge.ValidateInputSample(bridge.InputSample{
		Labels: hdr.Labels, Axes: hdr.Axes, Source: hdr.Source,
		// One inert edge: a sample with no edges and no tables is refused by a wire rule, not a header one.
		Edges: []bridge.InputEdge{{}},
	}) {
		return nil, fmt.Errorf("%s: line 1: %s", name, bridge.InputSampleRejectReason(bridge.InputSample{
			Labels: hdr.Labels, Axes: hdr.Axes, Source: hdr.Source,
			Edges: []bridge.InputEdge{{}},
		}))
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
			// A half-written final line is a track still being written (the writer flushes on a clock); anything
			// after a bad line is corruption.
			if !sc.Scan() {
				log.Printf("core: input track %s: line %d is incomplete and was dropped -- the file "+
					"was still being written, or the game that wrote it did not close it", name, line)
				break
			}
			return nil, fmt.Errorf("%s: line %d: %w", name, line, err)
		}
		// The bridge's own validator, so a file and a batch can never be held to different rules.
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
		// Ordering is enforced, not assumed, on ts as well as the adapter's counters: backwards core stamps would
		// misplace an edge against the state recording.
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

// inputIndexScanMax bounds how many headers a lookup opens on the hello goroutine; newest first, so the ones that
// matter are inside it.
const inputIndexScanMax = 2000

// loadInputTrackHeader reads only a track's first line, for the lookup by recording_id.
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

// inputTrackIndex maps recording_id to track path for every track in replay/inputs/, newest first so a duplicate id
// resolves to the latest take. Built per replay load, only for an adapter that asked for tracks. There is no on-disk
// index: it would add a write path, a staleness case and a corruption case to save a header read per file.
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
		// The listing's own name, joined and cleaned: nothing in a file chooses a path.
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

// attachTrackFromIndex finds and attaches a clip's track, logging either way: silence would leave a ghost with no
// inputs and nothing saying why.
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
