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

// A refused hello's Reject must reach the client even when the client has
// written bytes the relay will never read -- which is every real client, since
// it goes on sending while it waits for an answer.
//
// The mechanism, and why a plain Close is not enough: closing a socket that
// still holds unread data answers with a RESET rather than a FIN, and a reset
// discards what is sitting unread in the CLIENT's receive buffer, including the
// Reject written a moment earlier. The relay's rate-limit path was fixed for
// exactly this on 2026-09-05; the HANDSHAKE path was not, and on 2026-09-06
// CI's Linux race job caught the consequence in the core: a permanent
// game_version mismatch arrived as a bare EOF, was classified as a transient
// drop ("the relay connection dropped before the welcome arrived"), and the
// core retried instead of telling the player and closing the bridge
// (core.TestBridgeHelloGameVersionReachesRelay).
//
// This test writes the hello and then a wedge of lines the relay never reads,
// because it rejects and stops reading at the hello. Raw sockets throughout:
// the point is what the kernel does with the close, so nothing may be doing its
// own buffering or draining on top.
func TestARefusedHelloDeliversItsRejectBehindUnreadData(t *testing.T) {
	addr := startServer(t)

	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	// A protocol-version mismatch: refused by rejectAndClose without needing a
	// room, a code or another client.
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

	// The wedge: complete, legal lines the relay will never read, because it
	// has already stopped reading this connection. Small enough each to be a
	// valid line, together far more than the relay's receive buffer will have
	// consumed.
	junk := []byte(`{"type":"ping","payload":{}}` + "\n")
	wedge := strings.Repeat(string(junk), 4000)
	_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	// A short write here is fine and expected once the peer stops reading; what
	// matters is that the bytes are in flight, not that all of them arrive.
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
