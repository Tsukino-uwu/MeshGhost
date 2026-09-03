package core

import "time"

// AN INJECTABLE CLOCK FOR THE CORE.
//
// The point is testing time without spending it. Several of this package's behaviours are defined
// in seconds or minutes -- a recorder that flushes once a second, a stale window, a chaser queue
// measured in hours -- and a test that wants to cross one of those boundaries currently has to
// either wait, or shorten a per-Core field until the boundary is milliseconds away. The second
// trick is what the schedule fuzzers already do (the "compressed clock"), and it has a floor: once
// a window is shorter than the machine's own scheduling jitter, the test stops testing the code and
// starts testing the scheduler. A virtual clock has no floor, and "advance eight hours" costs
// nothing.
//
// THE INTERFACE CARRIES Since, NOT JUST Now, AND THAT IS THE WHOLE LESSON FROM DESIGNING IT.
// The obvious shape is a single `now func() time.Time`. It is a trap. Every duration in this
// package is a time.Time FIELD plus a reader somewhere else -- `lastSendAt` written in one place
// and read by `time.Since` in two others, `lastFlush` likewise. Convert the writer and leave the
// reader, and the code computes `wallNow - virtualStored`: with a fake clock at any epoch but the
// real one, that is either an enormous positive (a rate limiter that never limits) or a negative
// (one that never sends). Nothing crashes and no test necessarily names the cause.
//
// So THE UNIT OF CONVERSION IS A FIELD PLUS EVERY READER OF IT, never a call site. Adding Since
// here is what makes that possible to do completely.
//
// WHAT STAYS ON THE WALL CLOCK. Anything whose other end is a socket, a process, or a human:
// transport discovery, the relay session's dial backoff and timeouts, the ping/RTT pairing (it
// MEASURES the network -- a virtual clock would measure nothing), the one-second goroutine joins in
// StopReplays and StopChasers (virtualising a shutdown timeout turns a leak into a hang), and the
// recorder's filename and header timestamps, which are written into a file somebody reads and are
// deduplicated against the real filesystem. Those sites are deliberate and stay as they are.
type coreClock interface {
	// Now is the current time. Only ever compared against other values from the
	// same clock.
	Now() time.Time
	// Since is Now().Sub(t), and exists so a stored timestamp and its reader
	// cannot end up on different clocks. See the note above.
	Since(t time.Time) time.Duration
}

// wallClock is the shipped implementation: the real clock, no indirection worth
// measuring. It holds no state, so the zero value is usable and every Core that
// never sets one shares this behaviour.
type wallClock struct{}

func (wallClock) Now() time.Time                  { return time.Now() }
func (wallClock) Since(t time.Time) time.Duration { return time.Since(t) }

// clk returns this Core's clock, falling back to the wall clock when none was
// set.
//
// A PURE READ THAT NEVER ASSIGNS, and that is a hard requirement rather than a
// style choice. Two reasons, both load-bearing:
//
//   - It is called from under c.mu (nowMsLocked) and from outside it
//     (storeRemoteState's log throttle reads the clock ten lines before it takes
//     the lock). A lazy initialiser would therefore be either an unsynchronised
//     write -- a data race the race detector will find -- or would have to take
//     c.mu itself, which deadlocks the moment nowMsLocked calls it, exactly the
//     reentrancy fault documented at online.go's nowMsLocked that froze two
//     games on 2026-08-28.
//   - New() is not the only way a Core is built. A dozen tests use &Core{...}
//     literals directly (transport_test.go, rejectreason_test.go and others), so
//     the field is nil in all of them and a constructor default would not cover
//     it.
//
// Returning a fresh zero-size value costs nothing and cannot race.
//
// THE ONE RULE FOR A CALLER: set the field BEFORE the Core is started, and never
// again. It is read from several goroutines and from StartRecording without
// c.mu, so it is safe as a write-once-at-construction value and is a data race
// as anything else. Nothing shipped writes it at all; only tests do, and they do
// it beside the other fields, before ServeBridge or ConnectRelay.
func (c *Core) clk() coreClock {
	if c.timeSrc == nil {
		return wallClock{}
	}
	return c.timeSrc
}
