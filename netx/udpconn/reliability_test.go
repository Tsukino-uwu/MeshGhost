//go:build meshghost_devudp

package udpconn

import (
	"net"
	"sync"
	"testing"
	"time"
)

// lossyProxy sits between a client and a Listener and drops client-to-server datagrams on demand. Loss is armed
// explicitly: a fixed stride lines up with the handshake's request/response pattern and can starve one message type,
// and random loss would make a failure impossible to reproduce.
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

// TestReliableWriteSurvivesPacketLoss: a reliable payload arrives though its first three datagrams are lost. Nothing
// above this layer knows a datagram went missing, so a dropped leave or welcome would never be recovered.
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

// TestReliableWriteIsDeliveredOnlyOnce: a reliable payload is not delivered again within a few retry intervals. It
// arms no loss, so it does not force a retransmit of a payload the receiver has already seen.
func TestReliableWriteIsDeliveredOnlyOnce(t *testing.T) {
	l := listenTest(t)
	p := newLossyProxy(t, l.Addr().String())
	client, server := connectThroughProxy(t, l, p)

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

	// Anything further within a few retry intervals would be a duplicate delivery.
	if err := server.SetReadDeadline(time.Now().Add(3 * retryInterval)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	n, err := server.Read(buf)
	if err == nil {
		t.Fatalf("payload delivered twice; second delivery was %q", buf[:n])
	}
}

// TestReliableWritesArriveInOrderUnderLoss: a payload whose first datagram is lost is not overtaken by the next.
// core applies lifecycle messages in arrival order, so a leave overtaking its own join would strand a ghost.
// TestConformanceSendIsOrdered owns the same claim at the contract level.
func TestReliableWritesArriveInOrderUnderLoss(t *testing.T) {
	l := listenTest(t)
	p := newLossyProxy(t, l.Addr().String())
	client, server := connectThroughProxy(t, l, p)

	const first = `{"type":"join"}` + "\n"
	const second = `{"type":"leave"}` + "\n"

	// Only the first payload's initial datagram is lost, so the second reaches the far end while the first waits on
	// its retransmit.
	p.dropNextToServer(1)
	if _, err := client.Write([]byte(first)); err != nil {
		t.Fatalf("write first: %v", err)
	}
	if _, err := client.Write([]byte(second)); err != nil {
		t.Fatalf("write second: %v", err)
	}

	buf := make([]byte, MaxDatagramBytes)
	read := func(what string) string {
		t.Helper()
		if err := server.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
			t.Fatalf("deadline: %v", err)
		}
		n, err := server.Read(buf)
		if err != nil {
			t.Fatalf("%s read: %v", what, err)
		}
		return string(buf[:n])
	}

	got := []string{read("first"), read("second")}
	want := []string{first, second}

	if got[0] == got[1] {
		t.Fatalf("the same payload was delivered twice: %q", got[0])
	}
	if got[0] != want[0] || got[1] != want[1] {
		t.Errorf("reliable payloads were delivered out of order.\n got: %q then %q\nwant: %q then %q",
			got[0], got[1], want[0], want[1])
	}
}

// TestUnreliableWriteIsDroppedNotRetried: state samples are never retransmitted, since the plane is latest-wins and a
// resent sample would arrive stale. The opt-out must not quietly inherit reliability.
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

// TestReliablePayloadIsNotAckedWhenItCannotBeDelivered: delivery drops on a full queue, so a payload that cannot be
// delivered must not be acked, or the sender never retransmits it. It fills the queue directly, because flooding
// through the public API does not reliably have it full at the deciding instant.
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

	// Once the reader catches up, the retransmission must land. The filler drains through the same Read loop, so a
	// resend arriving mid-drain still counts instead of being swallowed as filler.
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
