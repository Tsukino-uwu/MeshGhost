package tlsx_test

import (
	"errors"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

// The sniffing listener must survive a temporary Accept error, which relay.Serve retries, and report a permanent one
// to every later caller rather than hang: it sits in the tcp path of every relay.

// tempAcceptError stands in for EMFILE or ENFILE: a net.Error that says "not right now".
type tempAcceptError struct{}

func (tempAcceptError) Error() string   { return "tlsx test: temporary accept error" }
func (tempAcceptError) Timeout() bool   { return false }
func (tempAcceptError) Temporary() bool { return true }

// flakyListener returns one temporary error from Accept, then behaves like the listener it wraps.
type flakyListener struct {
	net.Listener
	mu    sync.Mutex
	fired bool
}

func (f *flakyListener) Accept() (net.Conn, error) {
	f.mu.Lock()
	first := !f.fired
	f.fired = true
	f.mu.Unlock()
	if first {
		return nil, tempAcceptError{}
	}
	return f.Listener.Accept()
}

func sniffing(t *testing.T, inner net.Listener) net.Listener {
	t.Helper()
	cfg, _, err := tlsx.ServerConfig(testALPN)
	if err != nil {
		t.Fatalf("ServerConfig: %v", err)
	}
	ln, err := tlsx.NewListener(inner, tlsx.ListenConfig{
		TLS:  cfg,
		Logf: func(string, ...any) {},
	})
	if err != nil {
		t.Fatalf("NewListener: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln
}

func TestATemporaryAcceptErrorDoesNotStopTheListener(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ln := sniffing(t, &flakyListener{Listener: raw})

	// The error is still reported: the backoff policy belongs to the caller.
	if _, err := ln.Accept(); err == nil {
		t.Fatal("want the temporary error reported to the caller, got nil")
	}

	type result struct {
		c   net.Conn
		err error
	}
	done := make(chan result, 1)
	go func() {
		c, err := ln.Accept()
		done <- result{c, err}
	}()

	client, err := net.Dial("tcp", raw.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer client.Close()
	// The listener hands the connection up only once the handshake completes.
	go func() {
		secure, err := tlsx.Client(client, testALPN, tlsx.TrustAnyCertificate, testTimeout)
		if err == nil {
			_, _ = secure.Write([]byte("{\"type\":\"hello\"}\n"))
		}
	}()

	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("Accept after a temporary error: %v", r.err)
		}
		r.c.Close()
	case <-time.After(testTimeout):
		t.Fatal("Accept never returned after a temporary error — the accept loop stopped and every later Accept blocks forever")
	}
}

func TestAPermanentAcceptErrorReachesEveryLaterCaller(t *testing.T) {
	raw, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ln := sniffing(t, raw)

	// A permanent error must be reported to every later Accept, not once and then a hang.
	raw.Close()

	for i := 0; i < 3; i++ {
		got := make(chan error, 1)
		go func() {
			_, err := ln.Accept()
			got <- err
		}()
		select {
		case err := <-got:
			if err == nil {
				t.Fatalf("Accept %d after the inner listener closed: want an error, got nil", i)
			}
			if errors.Is(err, tempAcceptError{}) {
				t.Fatalf("Accept %d: want the real error, got %v", i, err)
			}
		case <-time.After(testTimeout):
			t.Fatalf("Accept %d blocked forever after a permanent error", i)
		}
	}
}
