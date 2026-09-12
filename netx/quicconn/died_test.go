package quicconn

import (
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

// A quic connection that DIES must say what of (P1d-4, 2026-09-12).
//
// streamLoop ends when the scanner stops, and sc.Err() is the whole account of
// why: nil for a clean FIN, and otherwise the quic-level cause -- an idle
// timeout, a CONNECTION_CLOSE from the peer, a path that stopped working -- or
// bufio.ErrTooLong from this package's own 64 KiB line limit, which a peer can
// trip with no way to learn the limit exists. That error was discarded, and the
// bare Close() left Read answering net.ErrClosed, which transport.fail
// suppresses from OnError as a local close.
//
// So on quic, every disconnect that was not a deliberate hangup looked exactly
// like one. Found by the transports cell of the third adversarial review.

// TestAPeerThatKillsTheConnectionIsNotReportedAsALocalClose is the assertion.
// The peer aborts at the quic layer rather than closing the stream politely,
// which is what a crashed process, a killed VM or a broken path all look like
// from here.
func TestAPeerThatKillsTheConnectionIsNotReportedAsALocalClose(t *testing.T) {
	l := listenTest(t)
	client, server := connect(t, l, "hello\n")

	sc, ok := server.(*Conn)
	if !ok {
		t.Fatalf("accepted conn is %T, want *Conn", server)
	}
	// Not sc.Close(): that is the polite path, and the polite path is the one
	// that already worked. This is the connection simply ceasing to be.
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
	// NOT an errors.Is(err, net.ErrClosed) assertion, and that is worth saying
	// out loud: quic-go's *quic.ApplicationError answers true to it deliberately,
	// so that generic code treats a dead connection as a closed one. This layer
	// therefore cannot make a terminal failure distinguishable BY IDENTITY --
	// what it can do is carry the cause instead of discarding it, which is what
	// is asserted here. The decision about whether anyone hears it is
	// transport.fail's, on a flag rather than on an error value; its own half of
	// this fix is transport/closereason_test.go.
	if err.Error() == net.ErrClosed.Error() {
		t.Fatalf("read reported a bare %v, so the cause streamLoop had in hand was thrown away", err)
	}
	// The wording is quic-go's to choose, so this asks only that the peer's own
	// code survived the trip rather than pinning a message string.
	if !strings.Contains(err.Error(), "7") {
		t.Errorf("read reported %v, which does not carry the peer's application error code", err)
	}
}

// TestADeliberateCloseIsStillJustAClose keeps the other half honest, the same
// way netx/udpconn's namesake does: naming causes must not turn every hangup
// this project performs on purpose into an error line. Close() carries no
// reason, so Read still answers net.ErrClosed and transport still suppresses it.
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
