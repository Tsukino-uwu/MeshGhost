package core

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// fakeClock is the test-side coreClock: time moves only when a test says so. Its epoch is not the zero time, because
// several guards read IsZero() as "never happened yet" (sending.go's rate limiter treats a zero lastSendAt as "allow
// the first send").
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

// Advance moves the clock forward. Locked because the core reads its clock from several goroutines while a test
// advances it from another.
func (f *fakeClock) Advance(d time.Duration) {
	f.mu.Lock()
	f.now = f.now.Add(d)
	f.mu.Unlock()
}

// TestTheClockIsInjectableAndTheWallIsStillTheDefault crosses the recorder's one-second flush boundary without waiting
// a second, asserting bytes reaching the disk. It also pins that lastFlush and every reader of it moved to the clock
// together: a time.Since left behind would compare a virtual stamp against real time.
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

	// The first sample creates the file, but the header and every sample sit in the 64KB buffer until the flush timer
	// fires, so the file is real and empty: the state the once-a-second flush exists to bound.
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

	// Cross the one-second boundary without waiting a second.
	clk.Advance(1100 * time.Millisecond)
	sample(20)
	if got := size(); got == 0 {
		t.Fatal("the file is still empty after advancing past the flush interval: the recorder is not reading the injected clock")
	}

	if _, _, err := c.StopRecording(); err != nil {
		t.Fatal(err)
	}
}

// TestACoreWithNoClockUsesTheWall pins the fallback every shipped path takes, as does every &Core{} literal in the
// tests. The accessor must never assign: called both under c.mu and outside it, a lazy initialiser would race or
// deadlock.
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

// TestAwaitTickGivesUpWhenItsCallerIsShuttingDown: awaitTick runs inside the replay and chaser goroutines halt()
// interrupts, so it must give up on stop, or a test that never advances a virtual clock parks them forever. The
// five-second deadline makes a regression take five seconds rather than milliseconds.
func TestAwaitTickGivesUpWhenItsCallerIsShuttingDown(t *testing.T) {
	c := New()

	stop := make(chan struct{})
	close(stop)

	start := time.Now()
	got := c.awaitTick(c.tickCount(), 5*time.Second, stop)
	elapsed := time.Since(start)

	if got {
		t.Error("awaitTick reported a tick that never happened")
	}
	if elapsed > time.Second {
		t.Fatalf("awaitTick took %v with its stop channel already closed: it is not watching the channel, so halt() cannot interrupt it", elapsed)
	}

	// A nil stop channel, as every caller with nothing to cancel passes, must still respect the deadline.
	start = time.Now()
	if c.awaitTick(c.tickCount(), 40*time.Millisecond, nil) {
		t.Error("awaitTick reported a tick that never happened (nil stop)")
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("awaitTick with a nil stop channel took %v: a nil channel blocks in select, so the deadline must still be checked", elapsed)
	}
}

// TestTheRelayClockRunsOnTheInjectedClock covers the root conversion: nowMsLocked is where every outgoing timestamp,
// render time and replay or chaser due time comes from. Its payoff is crossing a window measured in hours at no cost,
// which a compressed clock cannot do once the window is shorter than the machine's scheduling jitter.
func TestTheRelayClockRunsOnTheInjectedClock(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk

	first := c.nowMs()
	if second := c.nowMs(); second != first {
		t.Fatalf("nowMs moved from %d to %d with no time passing: it is not reading the injected clock", first, second)
	}

	clk.Advance(1500 * time.Millisecond)
	if got, want := c.nowMs(), first+1500; got != want {
		t.Fatalf("after advancing 1.5s nowMs is %d, want %d", got, want)
	}

	// Eight hours, instantly. A real sleep here would be a test nobody runs.
	before := time.Now()
	clk.Advance(8 * time.Hour)
	if got, want := c.nowMs(), first+1500+8*60*60*1000; got != want {
		t.Fatalf("after advancing 8h nowMs is %d, want %d", got, want)
	}
	if spent := time.Since(before); spent > time.Second {
		t.Fatalf("advancing eight hours took %v of real time -- something is still on the wall clock", spent)
	}

	// And the monotonic clamp still holds against a clock that goes backwards.
	high := c.nowMs()
	clk.Advance(-time.Hour)
	if got := c.nowMs(); got < high {
		t.Fatalf("nowMs went backwards to %d from %d when the clock stepped back: the clamp is not holding", got, high)
	}
}
