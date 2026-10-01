package quicconn

import (
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

// TestAPeerThatKillsTheConnectionIsNotReportedAsALocalClose: a peer aborting at the quic layer (a crashed process, a
// broken path) reaches Read as its cause, not as the bare net.ErrClosed transport.fail suppresses as a local close.
func TestAPeerThatKillsTheConnectionIsNotReportedAsALocalClose(t *testing.T) {
	l := listenTest(t)
	client, server := connect(t, l, "hello\n")

	sc, ok := server.(*Conn)
	if !ok {
		t.Fatalf("accepted conn is %T, want *Conn", server)
	}
	// Not sc.Close(): the polite path already worked; this is the connection simply ceasing to be.
	if err := sc.qc.CloseWithError(7, "the peer went away"); err != nil {
		t.Fatalf("abort the peer's connection: %v", err)
	}

	if err := client.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	_, err := client.Read(make([]byte, 1024))
	if err == nil {
		t.Fatal("read succeeded after the peer aborted the connection")
	}
	if strings.Contains(err.Error(), "deadline") {
		t.Fatalf("read blocked to its deadline instead of noticing the peer had gone: %v", err)
	}
	// Not errors.Is(err, net.ErrClosed): quic-go's *quic.ApplicationError answers true to it deliberately, so this
	// layer can only carry the cause, never change its identity.
	if err.Error() == net.ErrClosed.Error() {
		t.Fatalf("read reported a bare %v, so the cause streamLoop had in hand was thrown away", err)
	}
	// The wording is quic-go's; only the peer's code is pinned.
	if !strings.Contains(err.Error(), "7") {
		t.Errorf("read reported %v, which does not carry the peer's application error code", err)
	}
}

// TestADeliberateCloseIsStillJustAClose: Close() carries no reason, so a deliberate hangup still reads as
// net.ErrClosed and transport still suppresses it.
func TestADeliberateCloseIsStillJustAClose(t *testing.T) {
	l := listenTest(t)
	client, _ := connect(t, l, "hello\n")

	go func() {
		time.Sleep(20 * time.Millisecond)
		_ = client.Close()
	}()

	if err := client.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	_, err := client.Read(make([]byte, 64))
	if !errors.Is(err, net.ErrClosed) {
		t.Fatalf("a deliberate Close() reported %v; it must stay net.ErrClosed", err)
	}
}
