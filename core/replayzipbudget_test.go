package core

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// writeClipZip builds a zip of n clips, each with samplesPerClip samples.
func writeClipZip(t *testing.T, dir string, n, samplesPerClip int) string {
	t.Helper()
	path := filepath.Join(dir, "pack.zip")
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create zip: %v", err)
	}
	defer f.Close()
	zw := zip.NewWriter(f)
	for i := 0; i < n; i++ {
		w, err := zw.Create(string(rune('a'+i)) + ".ndjson")
		if err != nil {
			t.Fatalf("create entry: %v", err)
		}
		if _, err := w.Write(clipBytes(nil, walkStates(samplesPerClip, 50))); err != nil {
			t.Fatalf("write entry: %v", err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("close zip: %v", err)
	}
	return path
}

// TestAZipSpendsOneSampleBudgetAcrossAllItsEntries: a zip's clips together cost no more than one clip may. Clips are
// shared between players, and StartReplays loads everything in replay/active/ the moment the adapter attaches.
func TestAZipSpendsOneSampleBudgetAcrossAllItsEntries(t *testing.T) {
	dir := t.TempDir()
	const perClip = 4
	path := writeClipZip(t, dir, 3, perClip)

	// The control: without it the subtests below could pass on a broken zip rather than a bounded one.
	t.Run("a generous budget loads every clip", func(t *testing.T) {
		defer restoreArchiveBudget(replayMaxSamplesPerArchive)
		replayMaxSamplesPerArchive = 1000
		all, err := loadReplayAll(path, true)
		if err != nil {
			t.Fatalf("loadReplayAll: %v", err)
		}
		if len(all) != 3 {
			t.Fatalf("loaded %d clips, want 3 -- the archive itself is wrong, so the "+
				"budget assertion below would prove nothing", len(all))
		}
	})

	t.Run("an exhausted budget stops the archive", func(t *testing.T) {
		defer restoreArchiveBudget(replayMaxSamplesPerArchive)
		// Exactly one clip's worth: the first entry consumes it all.
		replayMaxSamplesPerArchive = perClip
		all, err := loadReplayAll(path, true)
		if err != nil {
			t.Fatalf("loadReplayAll: %v", err)
		}
		if len(all) != 1 {
			t.Fatalf("loaded %d clips on a %d-sample budget, want 1: an archive must not "+
				"be able to spend the per-clip cap once per entry", len(all), perClip)
		}
		if got := len(all[0].clip.samples); got != perClip {
			t.Fatalf("the one loaded clip has %d samples, want %d", got, perClip)
		}
	})

	t.Run("a partial budget refuses the clip that would not fit", func(t *testing.T) {
		defer restoreArchiveBudget(replayMaxSamplesPerArchive)
		// Enough for the first clip and one sample of the second.
		replayMaxSamplesPerArchive = perClip + 1
		all, err := loadReplayAll(path, true)
		if err != nil {
			t.Fatalf("loadReplayAll: %v", err)
		}
		if len(all) != 1 {
			t.Fatalf("loaded %d clips, want 1 -- the second clip does not fit in the "+
				"remaining budget and must be skipped, not truncated", len(all))
		}
	})
}

func restoreArchiveBudget(v int) { replayMaxSamplesPerArchive = v }

func TestALooseClipIsNotBoundedByTheArchiveBudget(t *testing.T) {
	defer restoreArchiveBudget(replayMaxSamplesPerArchive)
	replayMaxSamplesPerArchive = 1

	dir := t.TempDir()
	path := filepath.Join(dir, "one.ndjson")
	if err := os.WriteFile(path, clipBytes(nil, walkStates(10, 50)), 0o600); err != nil {
		t.Fatalf("write clip: %v", err)
	}
	all, err := loadReplayAll(path, true)
	if err != nil {
		t.Fatalf("a loose clip was refused by the ARCHIVE budget: %v", err)
	}
	if len(all) != 1 || len(all[0].clip.samples) != 10 {
		t.Fatalf("loose clip loaded %d clips / %d samples, want 1 / 10", len(all), len(all[0].clip.samples))
	}
}

// TestTheArchiveBudgetCannotRaiseThePerFileCap: parseReplayLimited clamps whatever budget it is handed to
// replayMaxSamples.
func TestTheArchiveBudgetCannotRaiseThePerFileCap(t *testing.T) {
	clip, err := parseReplayLimited(bytes.NewReader(clipBytes(nil, walkStates(3, 50))), "x", replayMaxSamples*10)
	if err != nil {
		t.Fatalf("parseReplayLimited with an over-large budget: %v", err)
	}
	if len(clip.samples) != 3 {
		t.Fatalf("got %d samples, want 3", len(clip.samples))
	}

	// A budget of 2 refuses a 3-sample clip: the plumbing the zip path depends on.
	if _, err := parseReplayLimited(bytes.NewReader(clipBytes(nil, walkStates(3, 50))), "x", 2); err == nil {
		t.Fatal("a 3-sample clip was accepted on a 2-sample budget")
	}
}
