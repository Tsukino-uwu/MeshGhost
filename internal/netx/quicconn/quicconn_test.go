package quicconn

import (
	"crypto/tls"
	"encoding/json"
	"meshghost/internal/protocol"
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

// TestFinalWriteBeforeCloseIsDelivered is the regression test for a defect
// that silently broke every send-before-close in the project on quic.
//
// Close() used to close the stream and tear down the whole QUIC connection in
// the same breath. Closing a stream only signals FIN — the bytes still have to
// be delivered, and they cannot be once the connection is gone, so the peer got
// CONNECTION_CLOSE instead of the last message.
//
// This is not a hypothetical pattern. The relay writes a Reject and then closes
// when it refuses a hello, so a client with a wrong room code saw a bare
// hangup rather than the reason — precisely what rejectAndClose exists to
// prevent — and the same shape carries the rate-limit Reject and the core's
// goodbye before a deliberate leave. Found 2026-08-17 when the goodbye went
// missing on quic while working perfectly on tcp.
func TestFinalWriteBeforeCloseIsDelivered(t *testing.T) {
	l := listenTest(t)
	client, server := connect(t, l, "hello\n")
	defer server.Close()

	// Drain the handshake line connect() sent, so the assertion below reads
	// the farewell rather than what was already in flight ahead of it.
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
	// Immediately, with no flush, no sleep and no handshake — exactly what
	// every send-before-close site in this codebase does.
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

// TestMaximalWorldStateFitsAQuicDatagram is the quic half of the world plane's
// size derivation, and it exists because **quic is the default transport** while
// the bounds were derived against udpconn.
//
// SendUnreliable here is a REAL datagram path (RFC 9221), not a fallback to the
// stream, and quic-go refuses a datagram larger than the connection's current
// path MTU rather than fragmenting it. That limit is dynamic and can sit below
// udpconn.MaxDatagramBytes, so "it fits a 1200-byte datagram" does not by itself
// prove a lossy world write is deliverable over quic. A refusal surfaces to the
// caller as an error that internal/relay only logs, so an undersized path would
// make lossy writes quietly stop working while reliable ones (which ride the
// stream and have no such limit) kept going.
//
// Round-tripped rather than merely size-checked, because the number that matters
// is the one quic-go itself accepts.
func TestMaximalWorldStateFitsAQuicDatagram(t *testing.T) {
	l := listenTest(t)
	client, server := connect(t, l, `{"type":"hello"}`+"\n")
	readOne(t, server)

	// The largest single-entry world message the protocol permits, built the way
	// the relay builds it. Kept in step with internal/netx/udpconn's
	// TestMaximalWorldStateFitsAUDPDatagram, which owns the udp arithmetic.
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
