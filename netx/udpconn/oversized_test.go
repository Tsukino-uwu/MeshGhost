package udpconn

import (
	"net"
	"testing"
	"time"
)

// An oversized datagram is one whose payload exceeds MaxDatagramBytes. Nothing
// in this package ever sends one (TestOversizedWriteIsRefusedNotFragmented),
// but anyone on the internet can, to a relay's udp port or to a player's
// ephemeral port, from any source address, with no handshake — and on Windows
// a ReadFromUDP into a buffer smaller than the datagram returns WSAEMSGSIZE
// as an error alongside the truncated bytes. Until 2026-09-02 both read loops
// treated any error as the socket dying and closed the listener (and with it,
// via cmd/meshghost-relay's fatal-on-serve-error, the whole relay process) or
// the dialed connection. One spoofable packet, no cookie, whole relay gone.
// Found by the 2026-09-02 adversarial review; confirmed against the real
// binary before the fix. Linux truncates silently, which is why no test and no
// CI run had ever seen it.
//
// Both tests send the oversized datagram FIRST and then prove the endpoint
// still works — the property is liveness, not silence.

func sendRaw(t *testing.T, to net.Addr, payload []byte) {
	t.Helper()
	raw, err := net.Dial("udp", to.String())
	if err != nil {
		t.Fatalf("raw dial: %v", err)
	}
	defer raw.Close()
	if _, err := raw.Write(payload); err != nil {
		t.Fatalf("raw write of %d bytes: %v", len(payload), err)
	}
	// Let the receiving read loop see it before the liveness check races
	// past it; on the broken code the loop is already dead by then.
	time.Sleep(50 * time.Millisecond)
}

func TestListenerSurvivesAnOversizedDatagram(t *testing.T) {
	l := listenTest(t)

	oversized := make([]byte, MaxDatagramBytes+1)
	oversized[0] = ctrlPrefix
	oversized[1] = ctrlHello
	sendRaw(t, l.Addr(), oversized)
	// And a much larger one, near the IPv4 maximum, in case the buffer
	// were merely raised rather than the error handled.
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
