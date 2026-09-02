package cfg

import (
	"bytes"
	"io"
	"os"
	"testing"
)

// TestLogRotatesWhileRunning: until 2026-09-02 the cap was checked once, at
// open, so a long-running relay grew its log without bound -- under a
// connection flood, until the disk was full. The 2026-09-02 adversarial review
// named it. Now the writer rotates itself the moment a write would carry the
// file past MaxLogBytes, keeping one older generation, exactly as the startup
// check does.
func TestLogRotatesWhileRunning(t *testing.T) {
	t.Chdir(t.TempDir())

	w := OpenLogFile("t.log", "test")
	if w == nil {
		t.Fatal("OpenLogFile returned nil")
	}
	defer w.(io.Closer).Close()
	chunk := bytes.Repeat([]byte("x"), 64*1024)
	total := 0
	for total < MaxLogBytes+MaxLogBytes/2 {
		if _, err := w.Write(chunk); err != nil {
			t.Fatalf("write: %v", err)
		}
		total += len(chunk)
	}

	fi, err := os.Stat("t.log")
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if fi.Size() > MaxLogBytes {
		t.Fatalf("t.log is %d bytes after %d written; cap is %d and it was never rotated", fi.Size(), total, MaxLogBytes)
	}
	old, err := os.Stat("t.log.1")
	if err != nil {
		t.Fatalf("no t.log.1 after writing past the cap: %v", err)
	}
	if old.Size()+fi.Size() != int64(total) {
		t.Fatalf("t.log (%d) + t.log.1 (%d) != %d written -- bytes were lost in the rotation", fi.Size(), old.Size(), total)
	}
}
