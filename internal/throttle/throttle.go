// Package throttle prints a log line a stranger can cause at most once a second, with a running count. The relay's log
// is bounded on disk but not in history: a line an unauthenticated party can trigger per connection would roll the
// startup banner and every join off the log in seconds. A compare-and-swap on the last-printed time makes it safe from
// any goroutine.
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

// Allow counts one occurrence and reports whether this one should be printed. n is the total so far, including this
// one, for the line's "(%d so far)".
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
