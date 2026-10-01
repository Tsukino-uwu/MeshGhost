//go:build meshghost_devudp

package udpconn

import (
	"net"
	"testing"
	"time"
)

// Anyone can send a datagram over MaxDatagramBytes, to a relay's port or a player's, from any source and with no
// handshake, and on Windows a read into a smaller buffer returns WSAEMSGSIZE alongside the truncated bytes. Both tests
// send one first and then prove the endpoint still works: the property is liveness, not silence.

func sendRaw(t *testing.T, to net.Addr, payload []byte) {
	t.Helper()
	raw := dialRaw(t, to)
	defer raw.Close()
	if _, err := raw.Write(payload); err != nil {
		t.Fatalf("raw write of %d bytes: %v", len(payload), err)
	}
	// Let the read loop see it before the liveness check races past it.
	time.Sleep(50 * time.Millisecond)
}

func TestListenerSurvivesAnOversizedDatagram(t *testing.T) {
	l := listenTest(t)

	oversized := make([]byte, MaxDatagramBytes+1)
	oversized[0] = ctrlPrefix
	oversized[1] = ctrlHello
	sendRaw(t, l.Addr(), oversized)
	// And one near the IPv4 maximum, in case the buffer were merely raised rather than the error handled.
	sendRaw(t, l.Addr(), make([]byte, 60000))

	client, server := dialAndAccept(t, l)
	if _, err := client.Write([]byte(`{"after":"oversized"}` + "\n")); err != nil {
		t.Fatalf("client write: %v", err)
	}
	if got := readOne(t, server); got != `{"after":"oversized"}`+"\n" {
		t.Errorf("server read %q", got)
	}
}

func TestDialedConnSurvivesAnOversizedDatagram(t *testing.T) {
	l := listenTest(t)
	client, server := dialAndAccept(t, l)

	oversized := make([]byte, MaxDatagramBytes+1)
	oversized[0] = ctrlPrefix
	sendRaw(t, client.LocalAddr(), oversized)
	sendRaw(t, client.LocalAddr(), make([]byte, 60000))

	if _, err := server.Write([]byte(`{"still":"here"}` + "\n")); err != nil {
		t.Fatalf("server write: %v", err)
	}
	if got := readOne(t, client); got != `{"still":"here"}`+"\n" {
		t.Errorf("client read %q", got)
	}
}
