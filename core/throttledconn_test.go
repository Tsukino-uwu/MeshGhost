package core

// A bridge adapter that drains at a BOUNDED rate -- the case between the two
// this package already had.
//
// Every fake adapter here reads in a callback off transport's read loop, so it
// drains as fast as Go can; TestADeadAdapterSocketFreesTheCoreForTheReconnect
// covers the other end, an adapter that stops reading outright. A real one is
// neither. It drains its socket once a frame and parses what it can, and the
// defect this exists for lives entirely in that middle: a tester's 512-chaser
// pack put ~350 ghosts on screen, the core wrote 92,160 render lines a second
// at 380 bytes each -- 35 MB/s -- into an adapter parsing a fraction of that,
// and the write deadline expired with a line half-written.
//
// Nothing in the suite could produce that. A Go reader never falls behind, so
// no count, however large, ever reproduced the failure headlessly: it was
// found by a tester, twice, and could only be confirmed in a running game.
// throttledConn is the missing dial, and it is what lets FuzzEverything fuzz
// the drain rate as an axis of its own (the user's ask, 2026-09-07: "higher/
// lower rates than the intended one").

import (
	"net"
	"sync"
	"time"
)

// throttledConn wraps the ADAPTER's end of a bridge connection and lets it
// read at most perInterval bytes every interval.
//
// PER-FRAME, NOT PER-SECOND, because that is what an adapter actually does: it
// drains the socket once during its frame and gets on with the game. A plain
// bytes-per-second token bucket would let a stalled adapter catch up in one
// burst, which is the one thing a real one cannot do.
//
// Reads are clamped rather than delayed byte by byte, so the wrapped
// connection still blocks and unblocks like the real thing -- over net.Pipe,
// which is unbuffered, a slow reader turns straight into a blocked writer on
// the core's side, which is exactly the pressure being modelled.
type throttledConn struct {
	net.Conn

	mu          sync.Mutex
	perInterval int
	interval    time.Duration
	budget      int
	nextRefill  time.Time
}

// newThrottledConn caps c at perInterval bytes every interval. A perInterval
// of 0 or less means "no limit" and hands the connection back untouched, so a
// caller can pass a fuzzed rate straight through without special-casing the
// unlimited one.
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
