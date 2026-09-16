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

// TestAWhitespaceClipCannotBeReadWithoutLimit is pass 5's PM-3: a blank line
// costs no sample and no byte of the memory budget, so a clip of megabytes of
// whitespace ending in one valid sample was read end to end and ACCEPTED --
// and a gzip of whitespace is thousands to one. Reading is bounded by the
// same byte budget now.
func TestAWhitespaceClipCannotBeReadWithoutLimit(t *testing.T) {
	defer func(v int) { replayMaxBytes = v }(replayMaxBytes)
	replayMaxBytes = 1 << 20

	var b bytes.Buffer
	b.Write(clipBytes(nil, nil)) // the header line
	blank := strings.Repeat(" ", 4000) + "\n"
	for b.Len() < 3<<20 {
		b.WriteString(blank)
	}
	b.Write(clipBytes(nil, walkStates(1, 50))[len(clipBytes(nil, nil)):])

	if _, err := parseReplay(bytes.NewReader(b.Bytes()), "whitespace.ndjson"); err == nil {
		t.Fatalf("a %d MB clip that is all whitespace but one sample was read to the end and accepted, under a %d MB budget",
			b.Len()>>20, replayMaxBytes>>20)
	}
}

// TestAZipEntryThatFailsStillSpendsWhatItRead: an entry of whitespace errors
// out as "no samples", and an entry that errored spent nothing, so one zip
// could repeat the scan once per entry. Two entries of just over half the
// budget each: the second must find the budget spent.
func TestAZipEntryThatFailsStillSpendsWhatItRead(t *testing.T) {
	defer func(v int) { replayMaxBytes = v }(replayMaxBytes)
	replayMaxBytes = 1 << 20

	dir := t.TempDir()
	path := filepath.Join(dir, "blank.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	body := func() []byte {
		var raw bytes.Buffer
		raw.Write(clipBytes(nil, nil))
		for raw.Len() < (1<<20)*6/10 {
			raw.WriteString(strings.Repeat(" ", 4000) + "\n")
		}
		var gz bytes.Buffer
		w := gzip.NewWriter(&gz)
		_, _ = w.Write(raw.Bytes())
		_ = w.Close()
		return gz.Bytes()
	}
	for _, name := range []string{"a.ndjson.gz", "b.ndjson.gz"} {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(body()); err != nil {
			t.Fatal(err)
		}
	}
	// And a real clip last, so the archive is not refused for having none.
	w, err := zw.Create("c.ndjson")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write(clipBytes(nil, walkStates(4, 50))); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()

	all, err := loadReplayAll(path, false)
	if err == nil && len(all) > 0 {
		t.Fatalf("two whitespace entries of %d%% of the budget each were read in full and the clip after them still loaded: a failed entry spent nothing", 60)
	}
}
