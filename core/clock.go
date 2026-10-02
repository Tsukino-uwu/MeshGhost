package core

import "time"

// coreClock is the core's injectable clock, so a test can cross a time boundary (a flush, a stale window, a chaser
// delay) without spending it. It carries Since as well as Now because a stored time and its reader elsewhere on
// different clocks compute nonsense with no crash: convert a field together with every reader of it. Anything whose
// other end is a socket, a process or a person stays on the wall clock.
type coreClock interface {
	Now() time.Time
	Since(t time.Time) time.Duration
}

type wallClock struct{}

func (wallClock) Now() time.Time                  { return time.Now() }
func (wallClock) Since(t time.Time) time.Duration { return time.Since(t) }

// clk returns this Core's clock, or the wall clock when none was set. It never assigns: it runs both under c.mu and
// outside it, and tests build &Core{} literals, so a lazy initialiser would race or deadlock. Set timeSrc before the
// Core starts and never again.
func (c *Core) clk() coreClock {
	if c.timeSrc == nil {
		return wallClock{}
	}
	return c.timeSrc
}
