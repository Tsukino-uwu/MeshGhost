package core

// A bridge adapter that drains at a bounded rate. The fake adapters here read as fast as Go can, and
// TestADeadAdapterSocketFreesTheCoreForTheReconnect covers one that stops reading outright; a real adapter drains its
// socket once a frame and parses what it can, and a core writing past that is the case no count of fast readers
// reproduces. throttledConn lets FuzzEverything fuzz the drain rate as an axis of its own.

import (
	"net"
	"sync"
	"time"
)

// throttledConn wraps the adapter's end of a bridge connection and lets it read at most perInterval bytes every
// interval. Per frame, not per second: a bytes-per-second bucket would let a stalled adapter catch up in one burst,
// which a real one cannot. Reads are clamped rather than delayed byte by byte, so over the unbuffered net.Pipe a slow
// reader becomes a blocked writer on the core's side, the pressure being modelled.
type throttledConn struct {
	net.Conn

	mu          sync.Mutex
	perInterval int
	interval    time.Duration
	budget      int
	nextRefill  time.Time
}

// newThrottledConn caps c at perInterval bytes every interval. A perInterval of 0 or less means no limit and returns c
// untouched, so a fuzzed rate passes straight through.
func newThrottledConn(c net.Conn, perInterval int, interval time.Duration) net.Conn {
	if perInterval <= 0 || interval <= 0 {
		return c
	}
	return &throttledConn{Conn: c, perInterval: perInterval, interval: interval, budget: perInterval}
}

func (c *throttledConn) Read(p []byte) (int, error) {
	c.mu.Lock()
	if c.budget <= 0 {
		now := time.Now() // wall-clock: models a real adapter's frame, which no virtual clock drives
		if c.nextRefill.IsZero() {
			c.nextRefill = now
		}
		if wait := c.nextRefill.Sub(now); wait > 0 {
			c.mu.Unlock()
			time.Sleep(wait)
			c.mu.Lock()
		}
		c.nextRefill = time.Now().Add(c.interval)
		c.budget = c.perInterval
	}
	if len(p) > c.budget {
		p = p[:c.budget]
	}
	c.mu.Unlock()

	n, err := c.Conn.Read(p)

	c.mu.Lock()
	c.budget -= n
	c.mu.Unlock()
	return n, err
}
