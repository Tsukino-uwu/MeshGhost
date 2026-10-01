package core

import (
	"archive/zip"
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// zipWith writes a zip holding the named entries, contents as given.
func zipWith(t *testing.T, path string, entries map[string][]byte, order []string) {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, name := range order {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(entries[name]); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

func gzipped(t *testing.T, b []byte) []byte {
	t.Helper()
	var out bytes.Buffer
	gz := gzip.NewWriter(&out)
	if _, err := gz.Write(b); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

// TestAZipOfThreeClipsIsThreeGhosts: everything in replay/active/ becomes a ghost, so a zip there behaves like a
// folder and every clip in it plays.
func TestAZipOfThreeClipsIsThreeGhosts(t *testing.T) {
	c, fa := replayCore(t)
	dir := filepath.Join(c.ReplayDir, "active")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	one := clipBytes(map[string]any{"name": "PB"}, walkStates(20, 10))
	two := clipBytes(map[string]any{"name": "Second"}, walkStates(20, 10))
	three := clipBytes(map[string]any{"name": "Third"}, walkStates(20, 10))
	zipWith(t, filepath.Join(dir, "pack.zip"), map[string][]byte{
		"a.ndjson":       one,
		"b.ndjson":       two,
		"c.ndjson.gz":    gzipped(t, three),
		"readme.txt":     []byte("not a clip, and must not stop the others loading"),
		"screenshot.png": {0x89, 'P', 'N', 'G'},
	}, []string{"a.ndjson", "b.ndjson", "c.ndjson.gz", "readme.txt", "screenshot.png"})

	if n := c.StartReplays(); n != 3 {
		t.Fatalf("StartReplays loaded %d, want 3 -- one per clip inside the zip", n)
	}
	// Each ghost is named for the archive and the entry, so clips from different zips never collide.
	for _, want := range []string{"replay:pack.zip/a.ndjson", "replay:pack.zip/b.ndjson", "replay:pack.zip/c.ndjson.gz"} {
		c.replayMu.Lock()
		_, ok := c.replays[want]
		c.replayMu.Unlock()
		if !ok {
			t.Errorf("no replay with id %q", want)
		}
	}
	pumpUntil(t, fa, func() bool {
		_, ok := fa.renderMsgOf("replay:pack.zip/b.ndjson")
		return ok
	}, "the second clip inside the zip to render as its own ghost")
}

func TestAZipWithOneClipBehavesLikeThatClip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "run.zip")
	zipWith(t, path, map[string][]byte{
		"rec-20260904-010101.ndjson": clipBytes(map[string]any{"name": "PB", "speed": 2.0}, walkStates(30, 10)),
	}, []string{"rec-20260904-010101.ndjson"})

	all, err := loadReplayAll(path, true)
	if err != nil {
		t.Fatalf("loadReplayAll: %v", err)
	}
	if len(all) != 1 {
		t.Fatalf("got %d clips, want 1", len(all))
	}
	if len(all[0].clip.samples) != 30 || all[0].clip.header.Name != "PB" || all[0].clip.speed != 2 {
		t.Fatalf("the clip did not survive the zip: %d samples, name %q, speed %v",
			len(all[0].clip.samples), all[0].clip.header.Name, all[0].clip.speed)
	}
}

// TestAZipWithNothingPlayableSaysSo, and one bad entry does not condemn the good ones beside it.
func TestAZipWithNothingPlayableSaysSo(t *testing.T) {
	dir := t.TempDir()
	empty := filepath.Join(dir, "empty.zip")
	zipWith(t, empty, map[string][]byte{"notes.txt": []byte("hello")}, []string{"notes.txt"})
	_, err := loadReplayAll(empty, true)
	if err == nil || !strings.Contains(err.Error(), "no .ndjson inside") {
		t.Fatalf("loadReplayAll on a zip with no clip = %v, want a 'no .ndjson inside' error", err)
	}

	mixed := filepath.Join(dir, "mixed.zip")
	zipWith(t, mixed, map[string][]byte{
		"broken.ndjson": []byte("{\"this\":\"is not a replay header\"}\n"),
		"good.ndjson":   clipBytes(map[string]any{"name": "Good"}, walkStates(10, 10)),
	}, []string{"broken.ndjson", "good.ndjson"})
	all, err := loadReplayAll(mixed, true)
	if err != nil {
		t.Fatalf("a zip with one bad entry and one good one failed entirely: %v", err)
	}
	if len(all) != 1 || all[0].clip.header.Name != "Good" {
		t.Fatalf("got %d clips, want just the good one", len(all))
	}
}
