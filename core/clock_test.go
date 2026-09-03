package core

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// fakeClock is the test-side coreClock: time moves only when a test says so.
//
// THE EPOCH IS DELIBERATELY NOT THE ZERO TIME. Several guards in this package
// read a stored timestamp's IsZero() as "this has never happened yet" --
// sending.go's rate limiter is the clearest, treating a zero lastSendAt as
// "always allow the first send". A fake starting at time.Time{} makes those
// guards fire on values that were legitimately recorded, which looks like a
// logic bug in the code under test rather than a broken clock.
type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func newFakeClock() *fakeClock {
	return &fakeClock{now: time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)}
}

func (f *fakeClock) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

func (f *fakeClock) Since(t time.Time) time.Duration { return f.Now().Sub(t) }

// Advance moves the clock forward. Locked because the core reads its clock from
// several goroutines and a test advancing it from another is the normal case --
// without this the race detector reports the harness, not the code.
func (f *fakeClock) Advance(d time.Duration) {
	f.mu.Lock()
	f.now = f.now.Add(d)
	f.mu.Unlock()
}

// TestTheClockIsInjectableAndTheWallIsStillTheDefault is the smallest slice of
// the virtual-clock work that proves the design, and it was chosen as the first
// one for that reason: one struct, three lines of production code, no goroutine
// and no lock interaction.
//
// The recorder flushes on a one-second timer so a crash loses at most a second
// of samples. Testing that boundary honestly used to mean waiting a second. Here
// it costs nothing, and the assertion is about bytes reaching the disk rather
// than about a duration.
//
// It also pins the thing that makes the whole conversion safe: lastFlush and
// every reader of it moved TOGETHER. Convert the writes and leave the
// time.Since, and this test would still pass at the wall clock while the fake
// one silently compared a virtual stamp against real time.
func TestTheClockIsInjectableAndTheWallIsStillTheDefault(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk
	c.ReplayDir = filepath.Join(t.TempDir(), "replay")
	c.mu.Lock()
	c.adapterGameID = "emerald"
	c.adapterGameVersion = "v1"
	c.mu.Unlock()

	path, err := c.StartRecording()
	if err != nil {
		t.Fatal(err)
	}

	sample := func(i int) {
		c.forwardLocalState(&protocol.State{
			Timestamp: int64(1000 + i*16), AreaID: "a",
			Position: []float64{float64(i), 0}, Anim: "run",
		})
	}

	size := func() int64 {
		t.Helper()
		fi, err := os.Stat(path)
		if err != nil {
			return 0
		}
		return fi.Size()
	}

	// The first sample CREATES the file, but the header and every sample after it
	// sit in the 64KB buffer until the flush timer fires -- so the file is real
	// and empty, which is exactly the state the once-a-second flush exists to
	// bound.
	sample(0)
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("no file after the first sample: %v", err)
	}
	for i := 1; i < 20; i++ {
		sample(i)
	}
	if got := size(); got != 0 {
		t.Fatalf("the file holds %d bytes with no time passing: something flushed that should have been buffered", got)
	}

	// Cross the one-second boundary WITHOUT waiting a second. This is the whole
	// point of the exercise.
	clk.Advance(1100 * time.Millisecond)
	sample(20)
	if got := size(); got == 0 {
		t.Fatal("the file is still empty after advancing past the flush interval: the recorder is not reading the injected clock")
	}

	if _, _, err := c.StopRecording(); err != nil {
		t.Fatal(err)
	}
}

// TestACoreWithNoClockUsesTheWall pins the fallback, which every shipped path
// takes and which a dozen tests depend on by building &Core{} literals that
// never set the field. The accessor must also never ASSIGN -- it is called from
// under c.mu and from outside it, so a lazy initialiser would be either a data
// race or the reentrancy deadlock nowMsLocked documents.
func TestACoreWithNoClockUsesTheWall(t *testing.T) {
	var c Core
	if _, ok := c.clk().(wallClock); !ok {
		t.Fatalf("a Core with no clock set returned %T, want the wall clock", c.clk())
	}
	if c.timeSrc != nil {
		t.Fatal("reading the clock assigned the field -- it must be a pure read (see clock.go)")
	}

	var r recorder
	if _, ok := r.flushClock().(wallClock); !ok {
		t.Fatalf("a recorder with no clock returned %T, want the wall clock", r.flushClock())
	}

	// And the fake must not start at the zero time, or every IsZero "has this
	// happened yet" guard in the package misfires.
	if newFakeClock().Now().IsZero() {
		t.Fatal("the fake clock starts at the zero time; see its doc comment")
	}
}
