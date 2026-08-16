package quicconn

import (
	"crypto/tls"
	"net"
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

// connect brings up a client and its accepted server counterpart. Note the
// order: a QUIC stream does not exist on the wire until it is written to,
// so the client must send something before Accept can return — which is
// exactly what a real client does with its hello.
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

	client, err := Dial(l.Addr().String(), testTimeout)
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

// TestStreamRoundTrip is the reliable path.
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

// TestDatagramRoundTrip covers the unreliable path, which is the entire
// reason QUIC is worth having here: without datagrams a single reliable
// stream head-of-line blocks exactly like TCP, and the transport would buy
// nothing but encryption.
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

// TestStreamAndDatagramsDoNotCorruptEachOther is the framing hazard this
// package's line-buffering exists to prevent. Stream bytes and datagrams
// are merged into one byte stream for Read, so if a datagram were spliced
// in while only half a JSON line had arrived on the stream, the result
// would be unparseable. Interleaving the two heavily and checking every
// line survives intact is the only way to catch that.
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

	// Every delivered chunk must be one or more whole lines: no partial
	// line, and nothing spliced into the middle of another.
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

// TestHandshakeIsTLS13 pins that the connection really is encrypted, and at
// the version the room-code channel-binding work would need. Without a
// completed TLS 1.3 handshake, ExportKeyingMaterial is not usable and that
// follow-up would be blocked — so this is the check that keeps the door
// open rather than a decorative assertion.
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
	// The finding the shelved room-code binding work depends on: whether
	// keying material can actually be exported from a quic-go connection.
	// Recorded as a real check rather than an assumption — see
	// agent_docs/ideas.md's transport-security section.
	if _, err := st.ExportKeyingMaterial("meshghost-test", nil, 32); err != nil {
		t.Logf("NOTE: ExportKeyingMaterial is NOT available on a quic-go connection: %v", err)
		t.Logf("      the room-code channel-binding follow-up would need another mechanism")
	}
}
