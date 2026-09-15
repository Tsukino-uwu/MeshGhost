// Package throttle is one rule, shared: a log line that a stranger can
// cause is printed at most once a second, with a running count.
//
// WHY. The relay's log file is 1 MiB with one rotated copy
// (internal/cfg), which bounds the disk but not the history: any line an
// unauthenticated party can trigger per connection is, across a few
// thousand cycling connections, a way to roll the startup banner and every
// join off the end of the log in seconds. netx.LimitListener, netx/tlsx and
// netx/quicconn each had the rule; the relay's own refusal lines did not
// (fourth adversarial review, 2026-09-13, finding A4). One helper so the
// next such line gets the rule by construction rather than by copying it.
//
// The shape is netx/tlsx's: a compare-and-swap on the last-printed time,
// safe from any number of goroutines, and the count is kept so the one
// line that prints says how many it stands for.
package throttle

import (
	"sync/atomic"
	"time"
)

// Line is one throttled log line's state. The zero value is ready to use.
type Line struct {
	count atomic.Int64
	last  atomic.Int64 // unix nanos of the last line let through
}

// Interval is how often a Line lets a line through.
const Interval = time.Second

// Allow counts one occurrence and reports whether this one should be
// printed. n is the total so far, including this one, for the line's
// "(%d so far)" -- the count is right whether or not this one prints.
func (l *Line) Allow() (n int64, ok bool) {
	n = l.count.Add(1)
	now := time.Now().UnixNano()
	prev := l.last.Load()
	if now-prev < int64(Interval) {
		return n, false
	}
	return n, l.last.CompareAndSwap(prev, now)
}

// Count is the total so far, for tests and status lines.
func (l *Line) Count() int64 { return l.count.Load() }
