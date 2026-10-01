//go:build meshghost_devudp

package udpconn

import (
	"net"
	"sync"
	"testing"
	"time"
)

// TestListenerCloseRacesConnCloseWithoutDeadlocking races the two closes, which take l.mu and c.once in opposite
// orders unless Listener.Close snapshots first. It fails on a timeout rather than hanging, so a regression reports as
// a failed test, not as a package timeout whose cause is only in a stack dump.
func TestListenerCloseRacesConnCloseWithoutDeadlocking(t *testing.T) {
	for attempt := 0; attempt < 50; attempt++ {
		l, err := Listen("127.0.0.1:0")
		if err != nil {
			t.Fatalf("listen: %v", err)
		}

		// Accepted Conns registered with the listener, which both close paths contend over.
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
