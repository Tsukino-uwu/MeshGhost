//go:build meshghost_devudp

package udpconn

import (
	"errors"
	"net"
	"testing"
	"time"
)

// TestAVanishedPeerIsReportedAsOneNotAsALocalClose: retry exhaustion, the only way UDP notices a vanished peer,
// reaches Read as ErrPeerUnresponsive rather than the net.ErrClosed that transport.fail suppresses.
func TestAVanishedPeerIsReportedAsOneNotAsALocalClose(t *testing.T) {
	l := listenTest(t)
	client, _ := dialAndAccept(t, l)
	c := client.(*Conn)

	// An expired write deadline stands in for a vanished peer: it lands in the same place, a reliable payload queued
	// and never acked.
	if err := c.SetWriteDeadline(time.Now().Add(-time.Hour)); err != nil {
		t.Fatalf("set write deadline: %v", err)
	}
	if _, err := c.Write([]byte(`{"type":"hello"}`)); err == nil {
		t.Fatal("want the write to fail against an expired deadline")
	}

	// Wind the retry counter to its last tick rather than waiting out the budget: exhaustion is under test, not its
	// length.
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

// TestADeliberateCloseIsStillJustAClose: a Close() this side decided on carries no reason, so it still reads as
// net.ErrClosed and an ordinary hangup grows no error line.
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

// TestListenerCloseIsAlsoJustAClose: Listener.Close closes each Conn's once directly, never through Conn.Close, so it
// sets no reason, and a relay shutting down prints no per-connection error.
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
