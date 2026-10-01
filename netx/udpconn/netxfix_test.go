//go:build meshghost_devudp

package udpconn

import (
	"bytes"
	"errors"
	"net"
	"os"
	"testing"
	"time"
)

// TestAFullAcceptQueueDoesNotStallTheDemultiplexer: with the accept queue full, one more admission must not park the
// read loop that serves every connection on the socket. The probe is a plain hello from an uninvolved socket:
// answering it is the cheapest thing the read loop does, so silence means the loop is not running.
func TestAFullAcceptQueueDoesNotStallTheDemultiplexer(t *testing.T) {
	l := listenTest(t)

	// Fill the accept queue and never call Accept, which is what a relay busy
	// with its hello handling looks like from down here.
	for i := 0; i < cap(l.accept); i++ {
		c, err := Dial(l.Addr().String(), testTimeout)
		if err != nil {
			t.Fatalf("dial %d of %d: %v", i+1, cap(l.accept), err)
		}
		t.Cleanup(func() { c.Close() })
	}

	// One more admission, with nowhere to go: it is dropped, but the listener must not go deaf.
	overflow := make(chan struct{})
	go func() {
		defer close(overflow)
		if c, err := Dial(l.Addr().String(), 500*time.Millisecond); err == nil {
			c.Close()
		}
	}()
	time.Sleep(200 * time.Millisecond) // let the confirm reach admit

	probe, err := net.ListenUDP("udp", nil)
	if err != nil {
		t.Fatalf("probe socket: %v", err)
	}
	defer probe.Close()
	ua, err := net.ResolveUDPAddr("udp", l.Addr().String())
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if _, err := probe.WriteToUDP([]byte{ctrlPrefix, ctrlHello}, ua); err != nil {
		t.Fatalf("probe hello: %v", err)
	}
	_ = probe.SetReadDeadline(time.Now().Add(testTimeout))
	buf := make([]byte, MaxDatagramBytes)
	n, _, err := probe.ReadFromUDP(buf)
	if err != nil {
		t.Fatalf("the listener answered no hello while its accept queue was full — the read loop is parked in admit and every live connection on this socket is deaf: %v", err)
	}
	if n < 2+cookieLen || buf[0] != ctrlPrefix || buf[1] != ctrlCookie {
		t.Fatalf("want a cookie, got % x", buf[:n])
	}
	<-overflow
}

// TestTheHandshakeIgnoresDatagramsFromAnyoneButTheRelay: a forged cookie and token from another source, sent first,
// are ignored during the handshake. The attacker is given the client's exact port, so this fails deterministically
// without the source check.
func TestTheHandshakeIgnoresDatagramsFromAnyoneButTheRelay(t *testing.T) {
	relay, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("relay socket: %v", err)
	}
	defer relay.Close()
	attacker, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("attacker socket: %v", err)
	}
	defer attacker.Close()

	realCookie := bytes.Repeat([]byte{0xA1}, cookieLen)
	realToken := bytes.Repeat([]byte{0xB2}, tokenLen)
	badCookie := bytes.Repeat([]byte{0x11}, cookieLen)
	badToken := bytes.Repeat([]byte{0x99}, tokenLen)

	echoed := make(chan []byte, 1)
	go func() {
		buf := make([]byte, MaxDatagramBytes)
		for {
			n, src, err := relay.ReadFromUDP(buf)
			if err != nil {
				return
			}
			if n < 2 || buf[0] != ctrlPrefix {
				continue
			}
			switch buf[1] {
			case ctrlHello:
				// The attacker gets in first, every time.
				_, _ = attacker.WriteToUDP(append([]byte{ctrlPrefix, ctrlCookie}, badCookie...), src)
				_, _ = attacker.WriteToUDP(append([]byte{ctrlPrefix, ctrlReady}, badToken...), src)
				time.Sleep(50 * time.Millisecond)
				_, _ = relay.WriteToUDP(append([]byte{ctrlPrefix, ctrlCookie}, realCookie...), src)
			case ctrlConfirm:
				if n >= 2+cookieLen {
					select {
					case echoed <- append([]byte(nil), buf[2:2+cookieLen]...):
					default:
					}
				}
				_, _ = attacker.WriteToUDP(append([]byte{ctrlPrefix, ctrlReady}, badToken...), src)
				time.Sleep(50 * time.Millisecond)
				_, _ = relay.WriteToUDP(append([]byte{ctrlPrefix, ctrlReady}, realToken...), src)
			}
		}
	}()

	conn, err := Dial(relay.LocalAddr().String(), testTimeout)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	c, ok := conn.(*Conn)
	if !ok {
		t.Fatalf("Dial returned %T, want *Conn", conn)
	}
	if !bytes.Equal(c.token[:], realToken) {
		t.Fatalf("the client adopted a token from a source that is not the relay: got % x, want % x — "+
			"every datagram it sends from here is dropped by the real relay", c.token[:], realToken)
	}

	select {
	case got := <-echoed:
		if !bytes.Equal(got, realCookie) {
			t.Fatalf("the client echoed a cookie from a source that is not the relay: got % x, want % x", got, realCookie)
		}
	case <-time.After(testTimeout):
		t.Fatal("no confirm reached the relay")
	}
}

// TestOneConnsWriteDeadlineDoesNotReachAnother: accepted Conns share the listener's socket, so an expired write
// deadline on one must not fail an unrelated connection's write that has none.
func TestOneConnsWriteDeadlineDoesNotReachAnother(t *testing.T) {
	l := listenTest(t)
	_, serverA := dialAndAccept(t, l)
	_, serverB := dialAndAccept(t, l)

	const rounds = 2000
	payload := []byte("{\"type\":\"state\"}")

	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case <-stop:
				return
			default:
			}
			// Already expired: A's own writes are supposed to fail.
			_ = serverA.SetWriteDeadline(time.Now().Add(-time.Hour))
			_, _ = serverA.Write(payload)
		}
	}()

	for i := 0; i < rounds; i++ {
		_, err := serverB.(*Conn).WriteUnreliable(payload)
		if err != nil {
			close(stop)
			<-done
			if errors.Is(err, os.ErrDeadlineExceeded) {
				t.Fatalf("write %d on a connection with NO deadline failed as expired: %v — "+
					"another Conn's deadline is reaching this socket", i, err)
			}
			t.Fatalf("write %d: %v", i, err)
		}
	}
	close(stop)
	<-done
}

// TestATransientWriteErrorDoesNotAbandonTheRetries: a failed resend must not end retryLoop, whose maxRetries
// exhaustion is how a vanished peer is noticed. An expired write deadline stands in for the transient failure because
// this package can produce it on demand; ENOBUFS reaches the same line.
func TestATransientWriteErrorDoesNotAbandonTheRetries(t *testing.T) {
	l := listenTest(t)
	client, _ := dialAndAccept(t, l)
	c := client.(*Conn)

	// Every write from here fails, including the retransmits.
	_ = c.SetWriteDeadline(time.Now().Add(-time.Hour))
	if _, err := c.Write([]byte("{\"type\":\"hello\"}")); err == nil {
		t.Fatal("want the first write to fail against an expired deadline")
	}

	// Three ticks is enough to tell "kept counting" from "stopped at one",
	// and far cheaper than waiting out all maxRetries.
	const want = 3
	deadline := time.Now().Add(testTimeout)
	for {
		attempts := 0
		c.relMu.Lock()
		for _, m := range c.pending {
			if m.attempts > attempts {
				attempts = m.attempts
			}
		}
		c.relMu.Unlock()
		if attempts >= want {
			return
		}
		if !time.Now().Before(deadline) {
			t.Fatalf("the retry loop stopped after %d attempt(s) of %d — one failed resend ended it, so "+
				"maxRetries exhaustion can never fire and a vanished peer is never noticed", attempts, want)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
