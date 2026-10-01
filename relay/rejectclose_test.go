package relay

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// A refused hello's Reject must arrive behind client data the relay never reads: closing a socket with unread data
// sends a reset, which discards the Reject from the client's receive buffer. Raw sockets, so nothing else buffers.
func TestARefusedHelloDeliversItsRejectBehindUnreadData(t *testing.T) {
	addr := startServer(t)

	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	// A protocol-version mismatch is refused without needing a room, a code or another client.
	hello, err := json.Marshal(protocol.Envelope{
		Type:    protocol.TypeHello,
		Payload: mustJSON(t, protocol.Hello{ProtocolVersion: protocol.MinProtocolVersion - 1, GameID: "emerald", Room: "r", DisplayName: "alice"}),
	})
	if err != nil {
		t.Fatalf("marshal hello: %v", err)
	}
	if _, err := conn.Write(append(hello, '\n')); err != nil {
		t.Fatalf("write hello: %v", err)
	}

	// Legal lines the relay never reads, together far more than its receive buffer will have consumed.
	junk := []byte(`{"type":"ping","payload":{}}` + "\n")
	wedge := strings.Repeat(string(junk), 4000)
	_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	// A short write is expected once the peer stops reading; the bytes only need to be in flight.
	_, _ = conn.Write([]byte(wedge))
	_ = conn.SetWriteDeadline(time.Time{})

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		t.Fatalf("reading the Reject failed (%v) -- a reset behind unread data threw it away; the handshake close must be graceful", err)
	}
	var env protocol.Envelope
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &env); err != nil {
		t.Fatalf("first line is not an envelope (%q): %v", line, err)
	}
	if env.Type != protocol.TypeReject {
		t.Fatalf("first line is %q, want %q", env.Type, protocol.TypeReject)
	}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}
