package quicconn

import (
	"context"
	"crypto/tls"
	"testing"
	"time"

	"github.com/quic-go/quic-go"

	"github.com/Tsukino-uwu/MeshGhost/netx/srclimit"
)

// TestPendingConnectionsAreCappedPerSourceAndDrain is the per-address half
// of TestAHandshakedConnectionThatOpensNoStreamIsBounded, and it asserts
// the part that test never did: the count DRAINS when the held connections
// close, so a refused source is admitted again. The listener-wide cap stays
// at its shipped value; only one address's cap is small, so a refusal here
// can only come from the per-source table.
func TestPendingConnectionsAreCappedPerSourceAndDrain(t *testing.T) {
	table := srclimit.New(srclimit.Options{MaxOpenPerSource: 2})
	l, err := ListenWith("127.0.0.1:0", Options{Sources: table})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { l.Close() })

	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{alpn},
	}
	dial := func() (*quic.Conn, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		return quic.DialAddr(ctx, l.Addr().String(), tlsConf, &quic.Config{EnableDatagrams: true})
	}
	pending := func() int {
		l.pendingMu.Lock()
		defer l.pendingMu.Unlock()
		return l.pending
	}
	waitPending := func(want int) {
		t.Helper()
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			if pending() == want {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatalf("pending = %d, want %d", pending(), want)
	}

	// Two from this address: handshake, open nothing.
	var held []*quic.Conn
	for i := 0; i < 2; i++ {
		qc, err := dial()
		if err != nil {
			t.Fatalf("dial %d: %v", i, err)
		}
		held = append(held, qc)
	}
	waitPending(2)

	// The third from the same address is closed by the listener after its
	// handshake; the listener-wide cap (256) is nowhere near.
	third, err := dial()
	if err == nil {
		defer third.CloseWithError(0, "")
		select {
		case <-third.Context().Done():
		case <-time.After(3 * time.Second):
			t.Fatal("a third pending connection from one address was neither refused nor closed")
		}
	}
	refusedOpen, _, _ := table.Counts()
	if refusedOpen != 1 {
		t.Fatalf("table counted %d per-source refusals, want 1", refusedOpen)
	}
	if got := pending(); got != 2 {
		t.Fatalf("pending = %d after the refusal, want 2: a refused connection must not be counted", got)
	}

	// DRAIN: close the held ones and the count returns to zero -- the
	// assertion the earlier test lacked (fourth review, E4).
	for _, qc := range held {
		_ = qc.CloseWithError(0, "")
	}
	waitPending(0)

	// And the address is admitted again.
	again, err := dial()
	if err != nil {
		t.Fatalf("dial after drain: %v", err)
	}
	defer again.CloseWithError(0, "")
	waitPending(1)
}
