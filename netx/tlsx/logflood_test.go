package tlsx_test

import (
	"crypto/tls"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

// The refusals are the attack: both lines the listener writes about a stranger (a plaintext connection, a failed
// handshake) are capped at one a second with a running count, so a connection flood cannot become a disk flood and
// an operator still learns how big it is.

// floodListener stands up a sniffing listener whose Logf counts every line.
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

// attempts is well above the cap and runs in well under a second, so they land in about one window.
const attempts = 40

func TestPlaintextRefusalsDoNotFloodTheLog(t *testing.T) {
	addr, lines := floodListener(t)

	for i := 0; i < attempts; i++ {
		c, err := net.DialTimeout("tcp", addr, testTimeout)
		if err != nil {
			t.Fatalf("dial %d: %v", i, err)
		}
		// 'n' is not tlsRecordHandshake (0x16), so the sniffer refuses it.
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
		// A real ClientHello with a mismatched ALPN, refused during the handshake rather than the sniff.
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

// waitForAtLeast waits for want lines, then settles once more: the sniff and handshake run off the Accept path, so the
// last lines can trail the last dial, and the cap is judged against all of them.
func waitForAtLeast(t *testing.T, lines func() int, want int) int {
	t.Helper()
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		if lines() >= want {
			time.Sleep(100 * time.Millisecond)
			return lines()
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("no line was written at all after the flood; a refusal must still be REPORTED, "+
		"just not once each (got %d, want at least %d)", lines(), want)
	return 0
}
