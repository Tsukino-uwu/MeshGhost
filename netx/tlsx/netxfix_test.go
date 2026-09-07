package tlsx_test

import (
	"errors"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

// Regressions for the 2026-09-08 review finding F9: the sniffing listener
// returned from its accept loop on the FIRST error of any kind and delivered
// it exactly once, so relay.Serve's deliberate temporary-error retry (added
// 2026-09-02 for descriptor exhaustion) parked on a channel nothing would ever
// send to again. The relay logged one "retrying" line and then accepted no tcp
// for the life of the process while existing rooms kept working, so nothing
// about it looked broken. tls=auto is the shipped default, so this wrapper is
// in that path for every relay.

// tempAcceptError is what the kernel hands back as EMFILE/ENFILE: a net.Error
// that says "not right now", which is the whole reason relay.Serve retries.
type tempAcceptError struct{}

func (tempAcceptError) Error() string   { return "tlsx test: temporary accept error" }
func (tempAcceptError) Timeout() bool   { return false }
func (tempAcceptError) Temporary() bool { return true }

// flakyListener returns one temporary error from Accept before behaving
// exactly like the listener it wraps.
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
		Mode: tlsx.Auto,
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

	// The error itself is still reported, because the backoff-and-log policy
	// belongs to the caller (relay.Serve), not to this wrapper.
	if _, err := ln.Accept(); err == nil {
		t.Fatal("want the temporary error reported to the caller, got nil")
	}

	// The retry. This is the half that hung.
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
	if _, err := client.Write([]byte("{\"type\":\"hello\"}\n")); err != nil {
		t.Fatalf("write: %v", err)
	}

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

	// Kill the inner listener under the wrapper, the way a closed socket or a
	// revoked binding would. The caller must be told, and told again: a
	// permanent error that is reported once and then silently becomes a hang
	// is the same defect in a different shape.
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
