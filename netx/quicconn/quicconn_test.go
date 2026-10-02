package quicconn

import (
	"crypto/tls"
	"encoding/json"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"net"
	"strings"
	"testing"
	"time"
)

const testTimeout = 5 * time.Second

func listenTest(t *testing.T) *Listener {
	t.Helper()
	l, err := Listen("127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { l.Close() })
	return l
}

// connect brings up a client and its accepted server. The client writes first: a QUIC stream does not exist on the
// wire, so Accept cannot return, until something is written to it.
func connect(t *testing.T, l *Listener, firstLine string) (client, server net.Conn) {
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

	client, err := DialWith(l.Addr().String(), testTimeout, tlsx.TrustAnyCertificate)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { client.Close() })

	if _, err := client.Write([]byte(firstLine)); err != nil {
		t.Fatalf("write first line: %v", err)
	}

	select {
	case a := <-ch:
		if a.err != nil {
			t.Fatalf("accept: %v", a.err)
		}
		t.Cleanup(func() { a.c.Close() })
		return client, a.c
	case <-time.After(testTimeout):
		t.Fatal("timed out waiting for Accept")
		return nil, nil
	}
}

func readOne(t *testing.T, c net.Conn) string {
	t.Helper()
	if err := c.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	buf := make([]byte, 64*1024)
	n, err := c.Read(buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return string(buf[:n])
}

func TestStreamRoundTrip(t *testing.T) {
	l := listenTest(t)
	client, server := connect(t, l, `{"type":"hello"}`+"\n")

	if got := readOne(t, server); got != `{"type":"hello"}`+"\n" {
		t.Errorf("server read %q", got)
	}
	if _, err := server.Write([]byte(`{"type":"welcome"}` + "\n")); err != nil {
		t.Fatalf("server write: %v", err)
	}
	if got := readOne(t, client); got != `{"type":"welcome"}`+"\n" {
		t.Errorf("client read %q", got)
	}
}

// TestDatagramRoundTrip covers the unreliable path, without which quic would buy nothing over tcp but encryption.
func TestDatagramRoundTrip(t *testing.T) {
	l := listenTest(t)
	client, server := connect(t, l, `{"type":"hello"}`+"\n")
	readOne(t, server) // consume the hello

	uw, ok := client.(interface {
		WriteUnreliable(p []byte) (int, error)
	})
	if !ok {
		t.Fatal("quicconn.Conn does not implement WriteUnreliable")
	}
	if _, err := uw.WriteUnreliable([]byte(`{"type":"state"}` + "\n")); err != nil {
		t.Fatalf("write datagram: %v", err)
	}
	if got := readOne(t, server); got != `{"type":"state"}`+"\n" {
		t.Errorf("server read %q from a datagram", got)
	}
}

// TestStreamAndDatagramsDoNotCorruptEachOther: heavily interleaved stream lines and datagrams reach Read as whole
// lines, never a datagram spliced into half a stream line.
func TestStreamAndDatagramsDoNotCorruptEachOther(t *testing.T) {
	l := listenTest(t)
	client, server := connect(t, l, `{"n":0}`+"\n")

	uw := client.(interface {
		WriteUnreliable(p []byte) (int, error)
	})
	const rounds = 20
	go func() {
		for i := 1; i <= rounds; i++ {
			_, _ = client.Write([]byte(`{"stream":` + itoa(i) + `}` + "\n"))
			_, _ = uw.WriteUnreliable([]byte(`{"datagram":` + itoa(i) + `}` + "\n"))
		}
	}()

	if err := server.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("deadline: %v", err)
	}
	seen := 0
	buf := make([]byte, 64*1024)
	for seen < rounds {
		n, err := server.Read(buf)
		if err != nil {
			t.Fatalf("read after %d lines: %v", seen, err)
		}
		chunk := string(buf[:n])
		if chunk[len(chunk)-1] != '\n' {
			t.Fatalf("chunk %q does not end at a line boundary — framing was corrupted", chunk)
		}
		for _, line := range splitLines(chunk) {
			if line == "" {
				continue
			}
			if line[0] != '{' || line[len(line)-1] != '}' {
				t.Fatalf("line %q is not a whole JSON object — a datagram was spliced into a stream line", line)
			}
			seen++
		}
	}
}

func splitLines(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	if start < len(s) {
		out = append(out, s[start:])
	}
	return out
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for i > 0 {
		b = append([]byte{byte('0' + i%10)}, b...)
		i /= 10
	}
	return string(b)
}

// TestHandshakeIsTLS13 pins that the connection is encrypted at TLS 1.3 with this package's ALPN.
func TestHandshakeIsTLS13(t *testing.T) {
	l := listenTest(t)
	client, _ := connect(t, l, `{"type":"hello"}`+"\n")

	qc, ok := client.(*Conn)
	if !ok {
		t.Fatalf("client is %T, want *Conn", client)
	}
	st := qc.TLSConnectionState()
	if st.Version != tls.VersionTLS13 {
		t.Errorf("TLS version = %x, want TLS 1.3 (%x)", st.Version, tls.VersionTLS13)
	}
	if st.NegotiatedProtocol != alpn {
		t.Errorf("ALPN = %q, want %q", st.NegotiatedProtocol, alpn)
	}
	// Logged, not failed: nothing that ships exports keying material.
	if _, err := st.ExportKeyingMaterial("meshghost-test", nil, 32); err != nil {
		t.Logf("NOTE: ExportKeyingMaterial is NOT available on a quic-go connection: %v", err)
		t.Logf("      the room-code channel-binding follow-up would need another mechanism")
	}
}

// TestFinalWriteBeforeCloseIsDelivered: a line written just before Close arrives. Closing the stream only signals FIN,
// so the connection must outlive it until the bytes are delivered.
func TestFinalWriteBeforeCloseIsDelivered(t *testing.T) {
	l := listenTest(t)
	client, server := connect(t, l, "hello\n")
	defer server.Close()

	// Drain connect()'s line, so the assertion below reads the farewell.
	if err := server.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	greeting := make([]byte, len("hello\n"))
	if _, err := readFull(server, greeting); err != nil {
		t.Fatalf("read greeting: %v", err)
	}

	const farewell = "goodbye\n"
	if _, err := client.Write([]byte(farewell)); err != nil {
		t.Fatalf("write farewell: %v", err)
	}
	// Immediately, with no flush and no sleep, as every send-before-close site does.
	if err := client.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	if err := server.SetReadDeadline(time.Now().Add(testTimeout)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	buf := make([]byte, len(farewell))
	n, err := readFull(server, buf)
	if err != nil {
		t.Fatalf("the last message written before Close never arrived: %v (got %q)", err, buf[:n])
	}
	if string(buf[:n]) != farewell {
		t.Fatalf("received %q, want %q", buf[:n], farewell)
	}
}

// readFull reads len(buf) bytes, tolerating short reads — a QUIC stream may
// hand over a partial buffer even when everything has arrived.
func readFull(c net.Conn, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		n, err := c.Read(buf[total:])
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// TestMaximalWorldStateFitsAQuicDatagram: the largest world message a relay sends arrives intact through
// WriteUnreliable on quic, the default transport. A line too large for a datagram rides the stream, so this proves
// delivery, not that the message fit one datagram.
func TestMaximalWorldStateFitsAQuicDatagram(t *testing.T) {
	l := listenTest(t)
	client, server := connect(t, l, `{"type":"hello"}`+"\n")
	readOne(t, server)

	// Built the way the relay builds it; kept in step with udpconn's TestMaximalWorldStateFitsAUDPDatagram.
	blob := json.RawMessage(`"` + strings.Repeat("x", protocol.MaxWorldBlobBytes-2) + `"`)
	payload, err := json.Marshal(protocol.WorldState{
		Authority: strings.Repeat("a", protocol.MaxLeaseKeyLen),
		Holder:    strings.Repeat("p", 16),
		Seq:       ^uint64(0),
		Reason:    protocol.WorldSnapshot,
		Entries:   []protocol.WorldEntry{{Key: strings.Repeat("k", protocol.MaxWorldKeyLen), Blob: blob}},
	})
	if err != nil {
		t.Fatalf("marshal world_state: %v", err)
	}
	line, err := json.Marshal(protocol.Envelope{Type: protocol.TypeWorldState, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	line = append(line, '\n')

	uw, ok := client.(interface {
		WriteUnreliable(p []byte) (int, error)
	})
	if !ok {
		t.Fatal("quicconn.Conn does not implement WriteUnreliable")
	}
	if _, err := uw.WriteUnreliable(line); err != nil {
		t.Fatalf("a maximal world_state (%d bytes) was refused as a quic datagram: %v -- lossy "+
			"world writes would silently stop working on the default transport", len(line), err)
	}
	if got := readOne(t, server); got != string(line) {
		t.Errorf("server read %d bytes from the datagram, want %d", len(got), len(line))
	}
}

// TestAnUnreliableWriteTooLargeForADatagramRidesTheStream: quic-go refuses a datagram larger than the path allows
// rather than fragmenting it, so such a line goes on the stream, whole.
func TestAnUnreliableWriteTooLargeForADatagramRidesTheStream(t *testing.T) {
	l := listenTest(t)
	client, server := connect(t, l, `{"type":"hello"}`+"\n")
	readOne(t, server)

	line := `{"type":"state","pad":"` + strings.Repeat("x", 3000) + `"}` + "\n"
	uw := client.(interface {
		WriteUnreliable(p []byte) (int, error)
	})
	if n, err := uw.WriteUnreliable([]byte(line)); err != nil || n != len(line) {
		t.Fatalf("WriteUnreliable(%d bytes) = %d, %v; want the whole line accepted", len(line), n, err)
	}
	var got strings.Builder
	for !strings.HasSuffix(got.String(), "\n") {
		got.WriteString(readOne(t, server))
	}
	if got.String() != line {
		t.Fatalf("server read %d bytes, want the %d-byte line intact", got.Len(), len(line))
	}
}
