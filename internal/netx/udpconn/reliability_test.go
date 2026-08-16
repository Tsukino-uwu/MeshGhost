package udpconn

import (
	"net"
	"sync"
	"testing"
	"time"
)

// lossyProxy sits between a client and a Listener and drops datagrams on
// demand, so the reliability layer can be tested against real packet loss
// without waiting for a real network to misbehave.
//
// Loss is armed explicitly rather than applied at random or to every Nth
// datagram. Both of those looked simpler and were worse: a fixed stride
// lines up with the handshake's own alternating request/response pattern
// and can starve one message type completely, and randomness would make a
// failure here impossible to reproduce. Arming it after the connection is
// up tests exactly the property in question — a reliable payload survives
// its first N datagrams being lost — and does so identically every run.
type lossyProxy struct {
	front  *net.UDPConn // faces the client
	back   *net.UDPConn // faces the real listener
	target *net.UDPAddr

	mu         sync.Mutex
	client     *net.UDPAddr
	dropToSrv  int
	sentToSrv  int
	droppedSum int
}

func newLossyProxy(t *testing.T, target string) *lossyProxy {
	t.Helper()
	ta, err := net.ResolveUDPAddr("udp", target)
	if err != nil {
		t.Fatalf("resolve target: %v", err)
	}
	front, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("proxy front: %v", err)
	}
	back, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		front.Close()
		t.Fatalf("proxy back: %v", err)
	}
	p := &lossyProxy{front: front, back: back, target: ta}
	t.Cleanup(func() { front.Close(); back.Close() })
	go p.pumpClientToServer()
	go p.pumpServerToClient()
	return p
}

func (p *lossyProxy) addr() string { return p.front.LocalAddr().String() }

// dropNextToServer arms the next n client-to-server datagrams to be
// discarded.
func (p *lossyProxy) dropNextToServer(n int) {
	p.mu.Lock()
	p.dropToSrv = n
	p.mu.Unlock()
}

func (p *lossyProxy) stats() (sent, dropped int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.sentToSrv, p.droppedSum
}

func (p *lossyProxy) pumpClientToServer() {
	buf := make([]byte, 2048)
	for {
		n, from, err := p.front.ReadFromUDP(buf)
		if err != nil {
			return
		}
		p.mu.Lock()
		p.client = from
		drop := p.dropToSrv > 0
		if drop {
			p.dropToSrv--
			p.droppedSum++
		} else {
			p.sentToSrv++
		}
		p.mu.Unlock()
		if drop {
			continue
		}
		if _, err := p.back.WriteToUDP(buf[:n], p.target); err != nil {
			return
		}
	}
}

func (p *lossyProxy) pumpServerToClient() {
	buf := make([]byte, 2048)
	for {
		n, _, err := p.back.ReadFromUDP(buf)
		if err != nil {
			return
		}
		p.mu.Lock()
		client := p.client
		p.mu.Unlock()
		if client == nil {
			continue
		}
		if _, err := p.front.WriteToUDP(buf[:n], client); err != nil {
			return
		}
	}
}

// connectThroughProxy brings up a validated connection whose traffic runs
// through p, with no loss armed yet.
func connectThroughProxy(t *testing.T, l *Listener, p *lossyProxy) (client, server net.Conn) {
	t.Helper()
	type accepted struct {
		c   net.Conn
		err error
	}
	ch := make(chan accepted, 1)
	go func() {
		c, err := l.Accept()
		ch <- accepted{c, err}
	}()

	client, err := Dial(p.addr(), testTimeout)
	if err != nil {
		t.Fatalf("dial through proxy: %v", err)
	}
	t.Cleanup(func() { client.Close() })

	select {
	case a := <-ch:
		if a.err != nil {
			t.Fatalf("accept: %v", a.err)
		}
		t.Cleanup(func() { a.c.Close() })
		return client, a.c
	case <-time.After(testTimeout):
		t.Fatal("timed out establishing a connection through the proxy")
		return nil, nil
	}
}

// TestReliableWriteSurvivesPacketLoss is the core reliability property, and
// the reason lifecycle messages do not ride the unreliable path. A dropped
// leave would strand a ghost on another player's screen forever, and a
// dropped welcome would mean the client never joins at all — neither is
// recoverable at a higher layer, because nothing above here knows a
// datagram went missing.
//
// This fails without the retransmit loop: the payload is written once,
// discarded by the proxy, and never arrives.
func TestReliableWriteSurvivesPacketLoss(t *testing.T) {
	l := listenTest(t)
	p := newLossyProxy(t, l.Addr().String())
	client, server := connectThroughProxy(t, l, p)

	const line = `{"type":"leave"}` + "\n"
	p.dropNextToServer(3)
	if _, err := client.Write([]byte(line)); err != nil {
		t.Fatalf("write: %v", err)
	}

	if err := server.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	buf := make([]byte, MaxDatagramBytes)
	n, err := server.Read(buf)
	if err != nil {
		t.Fatalf("reliable payload never arrived despite retransmission: %v", err)
	}
	if string(buf[:n]) != line {
		t.Errorf("read %q, want %q", buf[:n], line)
	}
	if _, dropped := p.stats(); dropped < 3 {
		t.Errorf("proxy dropped %d datagrams, expected the 3 that were armed", dropped)
	}
}

// TestReliableWriteIsDeliveredOnlyOnce covers the other half: retransmission
// means the far end can receive the same payload several times, so it must
// deduplicate. Without that, a retried join would be delivered twice and
// the relay would act on it twice.
func TestReliableWriteIsDeliveredOnlyOnce(t *testing.T) {
	l := listenTest(t)
	p := newLossyProxy(t, l.Addr().String())
	client, server := connectThroughProxy(t, l, p)

	// Losing the acks (not the data) is what forces the sender to retry a
	// payload the receiver has already seen — the exact duplicate case.
	const line = `{"type":"join"}` + "\n"
	if _, err := client.Write([]byte(line)); err != nil {
		t.Fatalf("write: %v", err)
	}

	if err := server.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	buf := make([]byte, MaxDatagramBytes)
	if _, err := server.Read(buf); err != nil {
		t.Fatalf("first read: %v", err)
	}

	// Anything further within a couple of retry intervals would be a
	// duplicate delivery.
	if err := server.SetReadDeadline(time.Now().Add(3 * retryInterval)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	n, err := server.Read(buf)
	if err == nil {
		t.Fatalf("payload delivered twice; second delivery was %q", buf[:n])
	}
}

// TestUnreliableWriteIsDroppedNotRetried is the deliberate other side of
// the design. State samples must NOT be retransmitted: the plane is
// latest-wins, so a resent sample would arrive stale and out of order,
// which is worse than the gap it fills. This proves the opt-out genuinely
// opts out rather than quietly inheriting reliability.
func TestUnreliableWriteIsDroppedNotRetried(t *testing.T) {
	l := listenTest(t)
	p := newLossyProxy(t, l.Addr().String())
	client, server := connectThroughProxy(t, l, p)

	uw, ok := client.(interface {
		WriteUnreliable(p []byte) (int, error)
	})
	if !ok {
		t.Fatal("udpconn.Conn does not implement WriteUnreliable")
	}

	p.dropNextToServer(2)
	for i := 0; i < 2; i++ {
		if _, err := uw.WriteUnreliable([]byte(`{"type":"state"}` + "\n")); err != nil {
			t.Fatalf("unreliable write: %v", err)
		}
	}

	if err := server.SetReadDeadline(time.Now().Add(4 * retryInterval)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	n, err := server.Read(make([]byte, MaxDatagramBytes))
	if err == nil {
		t.Fatalf("a dropped unreliable payload was retransmitted (%d bytes arrived); "+
			"state must be fire-and-forget", n)
	}
}

// TestReliablePayloadIsNotAckedWhenItCannotBeDelivered covers the ordering
// bug that made the reliability layer silently unreliable.
//
// Delivery into a Conn is non-blocking and drops when the queue is full —
// correct for the lossy state plane, fatal for a reliable one if the ack
// goes out first. The sender would have its ack, so it would never
// retransmit, and the dedup record would suppress the retransmit even if it
// did: a join, leave or welcome could vanish while Write reported success.
//
// The asserted property is the precise, deterministic one: **an
// undeliverable payload must not be acknowledged**. It saturates the
// receiver's queue directly, then checks the sender still has the message
// outstanding. An earlier version drove the same idea through the public
// API by flooding and draining, and quietly PASSED against the buggy code
// because the queue was not reliably full at the deciding instant — which
// is why this one reaches into the queue rather than approximating it.
func TestReliablePayloadIsNotAckedWhenItCannotBeDelivered(t *testing.T) {
	l := listenTest(t)
	client, server := dialAndAccept(t, l)

	srv := server.(*Conn)
	cli := client.(*Conn)

	// Saturate the receiver so the next delivery attempt cannot succeed.
	for len(srv.in) < cap(srv.in) {
		srv.in <- []byte("{\"filler\":true}\n")
	}

	const important = "{\"type\":\"leave\"}\n"
	if _, err := cli.Write([]byte(important)); err != nil {
		t.Fatalf("write: %v", err)
	}

	// Long enough for the datagram to arrive and be processed, and for an
	// ack to have come back if one was ever going to.
	time.Sleep(retryInterval + 250*time.Millisecond)

	cli.relMu.Lock()
	outstanding := len(cli.pending)
	cli.relMu.Unlock()
	if outstanding == 0 {
		t.Fatal("the sender considers a reliable payload acknowledged that the receiver never " +
			"accepted — it was acked before delivery, so it will never be retransmitted and is lost")
	}

	// And once the reader catches up, the retransmission must land.
	for len(srv.in) > 0 {
		<-srv.in
	}
	deadline := time.Now().Add(8 * time.Second)
	buf := make([]byte, MaxDatagramBytes)
	for time.Now().Before(deadline) {
		if err := server.SetReadDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
			t.Fatalf("deadline: %v", err)
		}
		n, err := server.Read(buf)
		if err != nil {
			continue
		}
		if string(buf[:n]) == important {
			return
		}
	}
	t.Fatal("the retransmitted payload never arrived after the receive queue drained")
}
