package quicconn

import (
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

// A write followed by Close must survive loss, not only a clean loopback.
//
// The Windows CI run of 2026-09-23 (35802463324) failed
// TestConformanceTheRejectStillArrivesAfterCloseGracefully on quic alone: the
// client never saw the reject. Close used to tear the connection down a fixed
// 250 ms after closing the stream, and CONNECTION_CLOSE discards whatever is
// still unacknowledged -- so any loss that pushed the retransmission past that
// window (a busy runner dropping loopback UDP; on the internet, the 1 s
// blackouts the netsim rig models) lost the last message for good. That last
// message is the relay's Reject and the core's goodbye. TCP does not have this
// hole: the kernel keeps delivering a closed socket's queued bytes.
//
// This blacks out every server-to-client packet for 2 s from the moment of the
// Close. With the fixed linger the connection is gone before the blackout ends;
// the write must still arrive after it.
func TestAWriteBeforeCloseSurvivesABlackout(t *testing.T) {
	l := listenTest(t)
	proxy := newLossyProxy(t, l.Addr().String())

	type accepted struct {
		c   net.Conn
		err error
	}
	ch := make(chan accepted, 1)
	go func() {
		c, err := l.Accept()
		ch <- accepted{c, err}
	}()
	client, err := DialWith(proxy.addr(), testTimeout, tlsx.TrustAnyCertificate)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { client.Close() })
	if _, err := client.Write([]byte("hello\n")); err != nil {
		t.Fatalf("write hello: %v", err)
	}
	var server net.Conn
	select {
	case a := <-ch:
		if a.err != nil {
			t.Fatalf("accept: %v", a.err)
		}
		server = a.c
	case <-time.After(testTimeout):
		t.Fatal("timed out waiting for Accept")
	}

	const last = "reject\n"
	proxy.dropToClient.Store(true)
	if _, err := server.Write([]byte(last)); err != nil {
		t.Fatalf("server write: %v", err)
	}
	server.Close()
	time.AfterFunc(2*time.Second, func() { proxy.dropToClient.Store(false) })

	if err := client.SetReadDeadline(time.Now().Add(10 * time.Second)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	buf := make([]byte, 64)
	n, err := readFull(client, buf[:len(last)])
	if got := string(buf[:n]); got != last {
		t.Fatalf("the client received %q (err %v), want %q: the connection was torn down "+
			"before the retransmission could land", got, err, last)
	}
}

// lossyProxy forwards UDP between one client and a server, and drops every
// server-to-client packet while dropToClient is set.
type lossyProxy struct {
	front        *net.UDPConn
	dropToClient atomic.Bool
}

func newLossyProxy(t *testing.T, serverAddr string) *lossyProxy {
	t.Helper()
	front, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("proxy listen: %v", err)
	}
	sa, err := net.ResolveUDPAddr("udp", serverAddr)
	if err != nil {
		t.Fatalf("proxy resolve: %v", err)
	}
	back, err := net.DialUDP("udp", nil, sa)
	if err != nil {
		t.Fatalf("proxy dial: %v", err)
	}
	t.Cleanup(func() { front.Close(); back.Close() })
	p := &lossyProxy{front: front}

	var clientAddr atomic.Pointer[net.UDPAddr]
	go func() {
		buf := make([]byte, 64*1024)
		for {
			n, from, err := front.ReadFromUDP(buf)
			if err != nil {
				return
			}
			clientAddr.Store(from)
			_, _ = back.Write(buf[:n])
		}
	}()
	go func() {
		buf := make([]byte, 64*1024)
		for {
			n, err := back.Read(buf)
			if err != nil {
				return
			}
			if to := clientAddr.Load(); to != nil && !p.dropToClient.Load() {
				_, _ = front.WriteToUDP(buf[:n], to)
			}
		}
	}()
	return p
}

func (p *lossyProxy) addr() string { return p.front.LocalAddr().String() }
