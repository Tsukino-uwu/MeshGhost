package udpconn

import (
	"errors"
	"net"
	"testing"
	"time"
)

// A peer that has GONE must be reported as gone, not as a hangup (P1d-4,
// 2026-09-12).
//
// UDP has no disconnect signal, so retry exhaustion is the only way this
// transport ever notices that the far end has stopped existing -- a player's
// router rebooted, their wifi dropped, the process was killed. That discovery
// is the single most useful thing this package can tell anybody, and it was
// thrown away: Read answered net.ErrClosed, and transport.fail deliberately
// suppresses net.ErrClosed from OnError because on tcp only a local Close()
// can produce it. So the relay logged a plain leave and the player's core
// logged nothing at all, for the one failure mode this transport can detect.
//
// The rule in transport was right; its premise was a tcp fact applied to a
// datagram transport. The fix is here, where the cause is known.

// TestAVanishedPeerIsReportedAsOneNotAsALocalClose is the assertion, and it
// asserts on Read because Read is where transport's own loop learns of it.
func TestAVanishedPeerIsReportedAsOneNotAsALocalClose(t *testing.T) {
	l := listenTest(t)
	client, _ := dialAndAccept(t, l)
	c := client.(*Conn)

	// An expired write deadline stands in for a peer that has vanished: it is
	// the failure this package can produce on demand, and it lands in exactly
	// the same place -- a reliable payload that is queued, never delivered and
	// therefore never acked. (Same stand-in as
	// TestATransientWriteErrorDoesNotAbandonTheRetries, for the same reason.)
	if err := c.SetWriteDeadline(time.Now().Add(-time.Hour)); err != nil {
		t.Fatalf("set write deadline: %v", err)
	}
	if _, err := c.Write([]byte(`{"type":"hello"}`)); err == nil {
		t.Fatal("want the write to fail against an expired deadline")
	}

	// Wind the retry counter to its last tick rather than waiting out all
	// maxRetries at retryInterval, which is six seconds of nothing. The
	// behaviour under test is what happens AT exhaustion, not how long the
	// budget is -- reliability_test.go owns that.
	c.relMu.Lock()
	if len(c.pending) == 0 {
		c.relMu.Unlock()
		t.Fatal("the failed write left nothing pending, so exhaustion can never fire")
	}
	for _, m := range c.pending {
		m.attempts = maxRetries
	}
	c.relMu.Unlock()

	if err := c.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	_, err := c.Read(make([]byte, 64))
	if err == nil {
		t.Fatal("read succeeded on a connection whose peer stopped acking")
	}
	if errors.Is(err, ErrPeerUnresponsive) {
		return
	}
	if errors.Is(err, net.ErrClosed) {
		t.Fatalf("read reported %v, which transport.fail suppresses from OnError as a local "+
			"close -- so the one disconnect this transport can actually diagnose reaches "+
			"nobody. Want ErrPeerUnresponsive.", err)
	}
	t.Fatalf("read reported %v, want ErrPeerUnresponsive", err)
}

// TestADeliberateCloseIsStillJustAClose is the other half, and it is the half
// that keeps transport's suppression rule worth having: naming causes must not
// turn every ordinary hangup into an error line. A Close() this side decided on
// carries no reason, so it still reads as net.ErrClosed and is still
// suppressed.
func TestADeliberateCloseIsStillJustAClose(t *testing.T) {
	l := listenTest(t)
	client, _ := dialAndAccept(t, l)

	go func() {
		time.Sleep(20 * time.Millisecond)
		_ = client.Close()
	}()

	if err := client.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	_, err := client.Read(make([]byte, 64))
	if !errors.Is(err, net.ErrClosed) {
		t.Fatalf("a deliberate Close() reported %v; it must stay net.ErrClosed, or every "+
			"hangup this project performs on purpose grows a scary second log line", err)
	}
}

// TestListenerCloseIsAlsoJustAClose covers the path that does not go through
// Conn.Close at all -- Listener.Close reaches into each Conn's once directly
// (it must: the lock-ordering deadlock of 2026-09-01) and so never sets a
// reason. A relay shutting down is a local close for every one of its
// connections, and must not print a per-connection error on the way out.
func TestListenerCloseIsAlsoJustAClose(t *testing.T) {
	l := listenTest(t)
	_, server := dialAndAccept(t, l)

	go func() {
		time.Sleep(20 * time.Millisecond)
		_ = l.Close()
	}()

	if err := server.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	_, err := server.Read(make([]byte, 64))
	if !errors.Is(err, net.ErrClosed) {
		t.Fatalf("a listener shutdown reported %v on an accepted conn; want net.ErrClosed", err)
	}
}
