package tlsx_test

import (
	"crypto/tls"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

// The refusals ARE the attack (P1b-2, 2026-09-12).
//
// Both lines this listener writes about a stranger -- a plaintext connection,
// and a handshake that failed -- were one line per
// attempt, from an unauthenticated source, on a port that exists to be reached
// from the internet. A machine opening connections in a loop therefore turned a
// connection flood into a disk flood, with the host's own log as the amplifier.
//
// `netx.limitListener` and `netx/quicconn`'s `notePendingRefusal` both cap the
// same class at one line a second with a running count, and both say why in a
// comment. This listener was the one place in the project that did not, which is
// what the parity cell of a review is for.
//
// The count is the half that makes throttling honest: an operator watching a
// flood needs to know how big it is, and "42 refused so far" once a second says
// that where 42 identical lines only say it by being counted.

// floodListener stands up a sniffing listener whose Logf records every line, so
// a test can flood it and count what came out.
func floodListener(t *testing.T) (addr string, lines func() int) {
	t.Helper()

	cfg, _, err := tlsx.ServerConfig(testALPN)
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	var mu sync.Mutex
	n := 0
	ln, err := tlsx.NewListener(raw, tlsx.ListenConfig{
		TLS:              cfg,
		HandshakeTimeout: testTimeout,
		Logf: func(string, ...any) {
			mu.Lock()
			n++
			mu.Unlock()
		},
	})
	if err != nil {
		raw.Close()
		t.Fatalf("NewListener: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	return raw.Addr().String(), func() int {
		mu.Lock()
		defer mu.Unlock()
		return n
	}
}

// attempts is well above the one-per-second cap and small enough to run in
// well under a second on any machine, which is the whole shape of the
// assertion: if these all land inside one window, at most one line may appear.
const attempts = 40

func TestPlaintextRefusalsDoNotFloodTheLog(t *testing.T) {
	addr, lines := floodListener(t)

	for i := 0; i < attempts; i++ {
		c, err := net.DialTimeout("tcp", addr, testTimeout)
		if err != nil {
			t.Fatalf("dial %d: %v", i, err)
		}
		// A plaintext first byte, which is what the sniffer refuses. 'n' is not tlsRecordHandshake (0x16).
		_, _ = c.Write([]byte("n"))
		c.Close()
	}

	got := waitForAtLeast(t, lines, 1)
	if got > 2 {
		t.Fatalf("%d refusals produced %d log lines; the cap is one a second, so a stranger "+
			"opening connections in a loop writes the host's disk full", attempts, got)
	}
}

func TestFailedHandshakesDoNotFloodTheLog(t *testing.T) {
	addr, lines := floodListener(t)

	for i := 0; i < attempts; i++ {
		// A real TLS ClientHello that cannot succeed: the ALPN does not match,
		// so the server refuses during the handshake rather than during the
		// sniff. That is the second of the two lines, and it is the expensive
		// one -- a handshake is real CPU an unauthenticated stranger can spend.
		c, err := tls.DialWithDialer(
			&net.Dialer{Timeout: testTimeout}, "tcp", addr,
			&tls.Config{InsecureSkipVerify: true, NextProtos: []string{"not-meshghost"}, MinVersion: tls.VersionTLS13},
		)
		if err == nil {
			c.Close()
			t.Fatal("a handshake with a mismatched ALPN succeeded")
		}
	}

	got := waitForAtLeast(t, lines, 1)
	if got > 2 {
		t.Fatalf("%d failed handshakes produced %d log lines; the cap is one a second", attempts, got)
	}
}

// waitForAtLeast gives the per-connection goroutines a moment to run -- the
// sniff and the handshake happen off the Accept path on purpose (see
// NewListener), so the last few lines can trail the last dial. It returns the
// count once it stops moving, so "at most two" is measured against everything
// that was going to be written rather than against a snapshot taken too early.
func waitForAtLeast(t *testing.T, lines func() int, want int) int {
	t.Helper()
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		if lines() >= want {
			// One more settle, so a late line is counted against the cap
			// rather than missed.
			time.Sleep(100 * time.Millisecond)
			return lines()
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("no line was written at all after the flood; a refusal must still be REPORTED, "+
		"just not once each (got %d, want at least %d)", lines(), want)
	return 0
}
