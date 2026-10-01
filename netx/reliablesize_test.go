package netx_test

// A reliable send the transport refuses before writing a byte must fail the message, not the connection: every caller
// treats a Send error as an outcome, and with nothing half-written there is nothing to resynchronize. Whether a size
// is refused is a per-transport limit and is not asserted; only what the connection is worth afterwards is.

import (
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/transport"
)

func TestConformanceARefusedReliableSendLeavesTheConnectionUsable(t *testing.T) {
	// Above any single-datagram budget here and below transport.DefaultMaxLineBytes, so only a datagram limit refuses
	// it.
	oversized := []byte(strings.Repeat("x", 4000))

	for _, kind := range transportsUnderTest {
		t.Run(kind.String(), func(t *testing.T) {
			rawClient, rawServer := pair(t, kind, "hello\n")
			// readLoop sets its own per-iteration deadline; an already-expired one left by pair would race its
			// first read.
			if err := rawServer.SetReadDeadline(time.Time{}); err != nil {
				t.Fatalf("%s: clear read deadline: %v", kind, err)
			}

			lines := make(chan string, 8)
			server := transport.FromConn(rawServer)
			t.Cleanup(func() { server.Close() })
			server.OnReceive(func(payload []byte) { lines <- string(payload) })

			client := transport.FromConn(rawClient)
			t.Cleanup(func() { client.Close() })

			sendErr := client.Send(oversized)
			if client.IsClosed() {
				t.Fatalf("%s: Send of %d bytes returned %v and CLOSED the connection; a message "+
					"the transport refused before writing a byte must fail the message, not the session",
					kind, len(oversized), sendErr)
			}

			const after = `{"type":"ping"}`
			if err := client.Send([]byte(after)); err != nil {
				t.Fatalf("%s: the send after a refused one failed: %v", kind, err)
			}
			deadline := time.After(conformanceTimeout)
			for {
				select {
				case got := <-lines:
					if got == after {
						return
					}
					// tcp and quic carry the big line; skip past it.
				case <-deadline:
					t.Fatalf("%s: the send after a refused one never arrived", kind)
				}
			}
		})
	}
}
