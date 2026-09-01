package udpconn

import (
	"net"
	"sync"
	"testing"
	"time"
)

// TestListenerCloseRacesConnCloseWithoutDeadlocking is the regression test for
// the lock-ordering deadlock found 2026-09-01 in a goroutine dump from a test
// binary that had hung for ten minutes:
//
//	Conn.Close     takes c.once, then calls Listener.forget -> wants l.mu
//	Listener.Close took  l.mu,   then called c.once.Do      -> wants c.once
//
// Opposite orders, so a peer disconnecting exactly as the listener closes
// wedged both goroutines forever — a relay that never finishes shutting down.
// Before the fix this test hangs (and the package times out); after it, the
// two paths interleave freely.
//
// Deliberately fails on a timeout rather than hanging: a deadlock regression
// must report itself as a failed test, not as a ten-minute package timeout
// whose cause is only visible in a stack dump.
func TestListenerCloseRacesConnCloseWithoutDeadlocking(t *testing.T) {
	for attempt := 0; attempt < 50; attempt++ {
		l, err := Listen("127.0.0.1:0")
		if err != nil {
			t.Fatalf("listen: %v", err)
		}

		// A handful of accepted Conns registered with the listener — these
		// are the ones both close paths contend over.
		var conns []*Conn
		for i := 0; i < 8; i++ {
			c := &Conn{
				pc:     l.pc,
				remote: &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 40000 + i},
				owner:  l,
				closed: make(chan struct{}),
			}
			l.mu.Lock()
			l.conns[c.remote.String()] = c
			l.mu.Unlock()
			conns = append(conns, c)
		}

		done := make(chan struct{})
		go func() {
			defer close(done)
			var wg sync.WaitGroup
			wg.Add(1)
			go func() { defer wg.Done(); _ = l.Close() }()
			for _, c := range conns {
				wg.Add(1)
				go func(c *Conn) { defer wg.Done(); _ = c.Close() }(c)
			}
			wg.Wait()
		}()

		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Fatalf("attempt %d: Listener.Close and Conn.Close deadlocked -- the lock ordering regressed (see Listener.Close's comment)", attempt)
		}
	}
}
