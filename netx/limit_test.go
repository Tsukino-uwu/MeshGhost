package netx

import (
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// TestLimitListenerClosesConnectionsPastTheCap: the cap counts connections
// from Accept until Close, the one past it is closed at once (its far end
// reads EOF promptly, rather than sitting until a timeout), and closing an
// accepted connection frees its slot.
func TestLimitListenerClosesConnectionsPastTheCap(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	// Written from the accept goroutine, read here: atomic, or the race
	// detector (CI, first push) rightly objects.
	var logged atomic.Int32
	ln := LimitListener(raw, 2, func(string, ...any) { logged.Add(1) }).(*limitListener)
	defer ln.Close()

	accepted := make(chan net.Conn, 8)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			accepted <- c
		}
	}()

	dial := func() net.Conn {
		t.Helper()
		c, err := net.Dial("tcp", raw.Addr().String())
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		t.Cleanup(func() { c.Close() })
		return c
	}
	waitAccepted := func() net.Conn {
		t.Helper()
		select {
		case c := <-accepted:
			return c
		case <-time.After(2 * time.Second):
			t.Fatal("connection under the cap was not accepted")
			return nil
		}
	}

	dial()
	first := waitAccepted()
	dial()
	waitAccepted()
	if got := ln.Open(); got != 2 {
		t.Fatalf("open = %d, want 2", got)
	}

	// Third: refused. Its far end must see EOF quickly.
	third := dial()
	_ = third.SetReadDeadline(time.Now().Add(2 * time.Second))
	if n, err := third.Read(make([]byte, 1)); err == nil {
		t.Fatalf("connection past the cap was not closed (read %d bytes)", n)
	}
	select {
	case <-accepted:
		t.Fatal("connection past the cap was handed to Accept")
	case <-time.After(100 * time.Millisecond):
	}
	if n := logged.Load(); n != 1 {
		t.Fatalf("refusal logged %d times, want 1", n)
	}

	// Free one slot; the next dial is accepted again.
	_ = first.Close()
	dial()
	waitAccepted()
	if got := ln.Open(); got != 2 {
		t.Fatalf("open after release = %d, want 2", got)
	}
}
