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

// TestARotationThatCannotRenameStopsRetrying is review G1 (2026-09-08). A
// rotation that cannot rename used to leave size over the cap, so the cap test
// in Write was true again on the very next line and every line after it: a
// Close+Rename+OpenFile+Stat per log line for the life of the process, with no
// backoff and nothing said. The trigger is ordinary -- two copies of one game
// run from the same folder share meshghost.log, and Go opens without
// FILE_SHARE_DELETE -- and the same writer is the relay's disk bound (ADR
// 0044), where the log rate belongs to whoever is connecting.
//
// A directory sitting in the .1 slot is how the rename is made to fail here:
// os.Rename onto a directory is refused on both Windows and Linux, so the test
// runs the same way on the CI matrix as on the dev machine, with no locking
// tricks and no second process.
//
// The assertion is on the number of attempts, not on the log's contents,
// because the storm is invisible in the file: every line it costs is still
// written. Not dropping them is half the fix.
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
	// Past the cap, and then a further 512 KiB -- eight more writes that each
	// used to be a rotation of their own.
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

// TestRotationResumesOnceTheRenameCanSucceedAgain is the other half of G1: the
// backoff must not be a one-way latch. The blocking .1 going away is the other
// game closing, and nobody restarts a client for that -- so the next attempt,
// one MaxLogBytes later, has to rotate normally.
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
	// Bounded: 64 MiB of writes is far more than the two rotations this needs,
	// and a loop keyed on the counter can otherwise never end if the backoff
	// stops working, which is the failure the sibling test is about.
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
