package netx

import (
	"net"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/srclimit"
)

// TestLimitListenerCapsOpenConnectionsPerSource: with a per-source table the
// limiter refuses the connection past one ADDRESS's cap while the listener
// as a whole has room, frees the slot on Close, and still forwards the
// datagram plane (the wrapper is unchanged; TestLimitListenerKeepsTheUnreliableWrite
// covers that separately). Without the table every dial here is from one
// loopback address and all of them are accepted -- which is the finding.
func TestLimitListenerCapsOpenConnectionsPerSource(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	table := srclimit.New(srclimit.Options{MaxOpenPerSource: 2})
	var lines []string
	logf := func(format string, args ...any) { lines = append(lines, format) }
	ln := LimitListenerWith(raw, LimitOptions{Max: 64, Sources: table, Logf: logf}).(*limitListener)
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
			t.Fatal("connection under the per-source cap was not accepted")
			return nil
		}
	}

	dial()
	first := waitAccepted()
	dial()
	waitAccepted()

	// Third from the same address: refused although the listener has 62 slots left.
	third := dial()
	_ = third.SetReadDeadline(time.Now().Add(2 * time.Second))
	if n, err := third.Read(make([]byte, 1)); err == nil {
		t.Fatalf("a third connection from one address was not closed (read %d bytes)", n)
	}
	select {
	case <-accepted:
		t.Fatal("a connection past the per-source cap was handed to Accept")
	case <-time.After(100 * time.Millisecond):
	}
	if got := ln.Open(); got != 2 {
		t.Fatalf("open = %d, want 2: the refused connection must not count", got)
	}
	refusedOpen, _, _ := table.Counts()
	if refusedOpen != 1 {
		t.Fatalf("table counted %d per-source refusals, want 1", refusedOpen)
	}

	// The slot is freed on Close -- through the release closure that captured
	// the address at Accept time.
	_ = first.Close()
	dial()
	waitAccepted()
	if got := ln.Open(); got != 2 {
		t.Fatalf("open after release = %d, want 2", got)
	}
}

// TestPerSourceRefusalLogsNoAddress: the throttled line carries a count and
// never the address -- docs/security.md's privacy section is what makes the
// per-source table acceptable at all.
func TestPerSourceRefusalLogsNoAddress(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	table := srclimit.New(srclimit.Options{MaxOpenPerSource: 1})
	logged := make(chan string, 8)
	ln := LimitListenerWith(raw, LimitOptions{Max: 64, Sources: table, Logf: func(format string, args ...any) {
		logged <- format
		for _, a := range args {
			if s, ok := a.(string); ok && s != "" {
				logged <- s
			}
			if a, ok := a.(net.Addr); ok {
				logged <- a.String()
			}
		}
	}})
	defer ln.Close()
	go func() {
		for {
			if _, err := ln.Accept(); err != nil {
				return
			}
		}
	}()
	for i := 0; i < 2; i++ {
		c, err := net.Dial("tcp", raw.Addr().String())
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		defer c.Close()
	}
	select {
	case line := <-logged:
		if containsAny(line, "127.0.0.1", "127.0.0.1:") {
			t.Fatalf("the refusal line names the address: %q", line)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the per-source refusal was never logged")
	}
}

func containsAny(s string, subs ...string) bool {
	for _, sub := range subs {
		if len(sub) > 0 && len(s) >= len(sub) && indexOf(s, sub) >= 0 {
			return true
		}
	}
	return false
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
