package quicconn

import (
	"context"
	"crypto/tls"
	"testing"
	"time"

	"github.com/quic-go/quic-go"
)

// A HANDSHAKED CONNECTION THAT OPENS NO STREAM IS STILL A CONNECTION.
//
// netx.LimitListener bounds what Accept RETURNS, and a quic connection does not
// reach Accept until it has opened a stream -- so the relay's MaxOpenConns
// counted none of the connections sitting in awaitStream's ten-second window.
// Each one is a goroutine, quic connection state and a UDP 4-tuple, and nothing
// bounded how many a single machine could hold there.
//
// Without the pending cap this test hangs at the last dial's stream (the
// listener happily holds every one of them) instead of being refused.
func TestAHandshakedConnectionThatOpensNoStreamIsBounded(t *testing.T) {
	restore := maxPending
	maxPending = 2
	t.Cleanup(func() { maxPending = restore })

	l, err := Listen("127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { l.Close() })

	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{alpn},
	}
	// Fill the pending window: handshake, open nothing.
	var held []*quic.Conn
	for i := 0; i < maxPending; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		qc, err := quic.DialAddr(ctx, l.Addr().String(), tlsConf, &quic.Config{EnableDatagrams: true})
		cancel()
		if err != nil {
			t.Fatalf("dial %d: %v", i, err)
		}
		held = append(held, qc)
	}
	t.Cleanup(func() {
		for _, qc := range held {
			_ = qc.CloseWithError(0, "")
		}
	})

	// Give the listener's accept loop time to have taken all of them.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		l.pendingMu.Lock()
		n := l.pending
		l.pendingMu.Unlock()
		if n >= maxPending {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	// One more. The handshake still completes -- it is the listener that
	// refuses, after it -- so the refusal shows up as the connection being
	// closed rather than as a dial error.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	qc, err := quic.DialAddr(ctx, l.Addr().String(), tlsConf, &quic.Config{EnableDatagrams: true})
	if err != nil {
		// Refused during the handshake is also a refusal, and an acceptable one.
		return
	}
	defer qc.CloseWithError(0, "")

	select {
	case <-qc.Context().Done():
		// Closed by the listener: the bound held.
	case <-time.After(3 * time.Second):
		t.Fatal("a connection past the pending cap was neither refused nor closed -- it is " +
			"holding a goroutine, quic state and a UDP 4-tuple outside every bound the relay has")
	}
}
