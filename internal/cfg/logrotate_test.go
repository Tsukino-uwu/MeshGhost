package cfg

import (
	"bytes"
	"io"
	"os"
	"testing"
)

// TestLogRotatesWhileRunning: a write that would carry the file past MaxLogBytes rotates it, so a long-running relay's
// log stays bounded under a connection flood.
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

// TestARotationThatCannotRenameStopsRetrying: a rotation whose rename fails backs off by MaxLogBytes instead of
// retrying on every line, and drops nothing. A directory in the .1 slot makes the rename fail on Windows and Linux
// alike; the test counts attempts because the retry storm is invisible in the file.
func TestARotationThatCannotRenameStopsRetrying(t *testing.T) {
	t.Chdir(t.TempDir())
	if err := os.Mkdir("t.log.1", 0o755); err != nil {
		t.Fatalf("mkdir the blocking .1: %v", err)
	}

	w := OpenLogFile("t.log", "test")
	if w == nil {
		t.Fatal("OpenLogFile returned nil")
	}
	defer w.(io.Closer).Close()
	r, isRotating := w.(*rotatingLog)
	if !isRotating {
		t.Fatalf("OpenLogFile returned a %T, want the rotating writer", w)
	}

	chunk := bytes.Repeat([]byte("x"), 64*1024)
	total := 0
	for total < MaxLogBytes+8*len(chunk) {
		n, err := w.Write(chunk)
		if err != nil {
			t.Fatalf("write: %v", err)
		}
		if n != len(chunk) {
			t.Fatalf("short write: %d of %d -- a log line must never be dropped for a failed rotation", n, len(chunk))
		}
		total += len(chunk)
	}

	if r.rotations != 1 {
		t.Fatalf("rotation was attempted %d times while the rename could not succeed, want 1 -- "+
			"every write past the cap is retrying it", r.rotations)
	}
	fi, err := os.Stat("t.log")
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if fi.Size() < int64(total) {
		t.Fatalf("t.log is %d bytes after %d written -- output was lost rather than appended", fi.Size(), total)
	}
	if r.rotateAt <= MaxLogBytes {
		t.Fatalf("rotateAt is %d, want it pushed past MaxLogBytes (%d) so the next attempt is a MiB away, not a line away", r.rotateAt, MaxLogBytes)
	}
}

// TestRotationResumesOnceTheRenameCanSucceedAgain: the backoff is not a latch. Once the .1 slot clears, as when the
// other game closes, the next attempt rotates normally.
func TestRotationResumesOnceTheRenameCanSucceedAgain(t *testing.T) {
	t.Chdir(t.TempDir())
	if err := os.Mkdir("t.log.1", 0o755); err != nil {
		t.Fatalf("mkdir the blocking .1: %v", err)
	}

	w := OpenLogFile("t.log", "test")
	if w == nil {
		t.Fatal("OpenLogFile returned nil")
	}
	defer w.(io.Closer).Close()
	r := w.(*rotatingLog)

	chunk := bytes.Repeat([]byte("x"), 64*1024)
	// Bounded, so a broken backoff fails the test instead of hanging it.
	writeUntilRotation := func(want int) {
		t.Helper()
		for i := 0; i < 1024 && r.rotations < want; i++ {
			if _, err := w.Write(chunk); err != nil {
				t.Fatalf("write: %v", err)
			}
		}
		if r.rotations < want {
			t.Fatalf("rotations = %d after 64 MiB of writes, want %d", r.rotations, want)
		}
	}
	writeUntilRotation(1)
	if r.rotations != 1 {
		t.Fatalf("rotations = %d after the first failed attempt, want 1", r.rotations)
	}

	if err := os.Remove("t.log.1"); err != nil {
		t.Fatalf("remove the blocking .1: %v", err)
	}
	writeUntilRotation(2)

	fi, err := os.Stat("t.log")
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if fi.Size() > MaxLogBytes {
		t.Fatalf("t.log is %d bytes, cap is %d -- rotation never resumed after the block cleared", fi.Size(), MaxLogBytes)
	}
	if _, err := os.Stat("t.log.1"); err != nil {
		t.Fatalf("no t.log.1 after the block cleared: %v", err)
	}
}
