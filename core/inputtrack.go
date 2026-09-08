package core

// Reading an input track back (ADR 0056).
//
// NOTHING IN THIS SLICE PLAYS ONE. This exists anyway, and deliberately: the
// moment one person sends another a track, the file is a stranger's bytes, and
// a parser written later under the pressure of a feature is a parser written
// without this file's caution. It also gives the round-trip test something to
// assert against, which is what makes the format-stability promise checkable
// rather than a claim.
//
// Same defensive posture as parseReplay, for the same reasons and in the same
// order: the line cap applied BEFORE decoding, a hard sample ceiling, a
// tolerated half-written FINAL line and nothing else tolerated, and every edge
// re-validated against the bounds the bridge would have applied.

import (
	"bufio"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"

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
// No zip case, unlike loadReplay. A replay zip exists because people send each
// other clips to watch; nothing plays a track yet, so an archive format would
// be a shared-budget problem (replayMaxSamplesPerArchive's OOM, 2026-09-08)
// taken on for no user today.
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
		if len(track.edges) > inputMaxEdges {
			return nil, fmt.Errorf("%s: over %d edges", name, inputMaxEdges)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	return track, nil
}
