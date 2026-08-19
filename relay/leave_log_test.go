package relay

import (
	"bytes"
	"log"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// logCapture redirects the standard logger into a buffer for the duration of
// one test. Guarded, because the relay logs from the connection goroutine that
// notices a drop, not from the test's own.
type logCapture struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (c *logCapture) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.Write(p)
}

func (c *logCapture) String() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.String()
}

func captureLog(t *testing.T) *logCapture {
	t.Helper()
	c := &logCapture{}
	flags := log.Flags()
	log.SetOutput(c)
	t.Cleanup(func() {
		log.SetOutput(os.Stderr)
		log.SetFlags(flags)
	})
	return c
}

// TestALeaveIsLogged is a regression test for a gap that made a live session
// unreadable on 2026-08-19: the relay logged seventeen joins and not one
// departure, so its own log could not answer "who is still in this room" or
// "is anything leaking". Join was printed at the join site; leave was never
// printed anywhere, even though the join line's comment describes the two as a
// pair of lifecycle events.
//
// The assertion is deliberately about the LOG rather than about membership —
// membership already has tests, and what was missing was the operator's view.
func TestALeaveIsLogged(t *testing.T) {
	logs := captureLog(t)

	addr := startServer(t)
	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	w2 := c2.expectWelcome(timeout)

	// Drop bob and wait for the relay to have finished with it. Polling the
	// log is what the test is about; there is no other observable that says
	// "the departure has been recorded" rather than "has begun".
	c2.conn.Close()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if strings.Contains(logs.String(), "left room") {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	got := logs.String()
	if !strings.Contains(got, "left room") {
		t.Fatalf("no leave was logged after a client disconnected; log was:\n%s", got)
	}
	if !strings.Contains(got, w2.PlayerID) {
		t.Fatalf("the leave log does not name the player that left (%s); log was:\n%s",
			w2.PlayerID, got)
	}
	if !strings.Contains(got, "joined room") {
		t.Fatalf("expected the join lines this test's premise depends on; log was:\n%s", got)
	}
}
