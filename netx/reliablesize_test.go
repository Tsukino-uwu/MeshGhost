package netx_test

// A reliable send the transport REFUSES must fail the message, not the
// connection (added 2026-09-12).
//
// conformance_test.go's rule is that a behaviour promised by the Transport
// contract rather than by one implementation belongs in this suite, and this is
// one: `Send` returning an error is a documented outcome, and every caller in
// the project treats it as one — relay/outbox.go logs it and moves on,
// core/sending.go counts it. None of them expect the session to end.
//
// It did end, on udp, until 2026-09-12. transport.Send closes the connection on
// ANY write error, for a reason that is right for the case it was written for:
// a write deadline can expire with a line half-written, and NDJSON cannot
// resynchronize after that, so the 2026-09-01 150-peer incident left one client
// on a permanently mis-framed stream that looked alive. But udpconn's
// checkWritable produces its error BEFORE a byte reaches the wire, so there is
// nothing to resynchronize and nothing wrong with the connection — and closing
// it turned a message the relay could simply have skipped into a hangup with no
// Reject, no reason and no log on the client's side.
//
// Not a theoretical size, either: measured 2026-09-12, a Welcome for a room of
// 16 players with maximal display names is 1195 bytes on the wire, against the
// 1182 a udp reliable payload can carry. udp is the shipped default transport.
// See the companion fix in relay (boundWelcomeRoster's budget).
//
// The refusal itself is deliberately NOT asserted, for the same reason
// conformancefix_test.go declines to pin oversized unreliable sends: whether a
// given size is refused is a per-transport limit, and freezing it into a
// contract file would make a transport's own MTU choice a protocol change. What
// is asserted is only what the connection is worth afterwards.
//
// Found by the transports cell of the third adversarial review (P1d-3).

import (
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/transport"
)

func TestConformanceARefusedReliableSendLeavesTheConnectionUsable(t *testing.T) {
	// Comfortably above any single-datagram budget a transport here has, and
	// far below transport.DefaultMaxLineBytes, so the only thing that can
	// refuse it is the transport's own datagram limit.
	oversized := []byte(strings.Repeat("x", 4000))

	for _, kind := range transportsUnderTest {
		t.Run(kind.String(), func(t *testing.T) {
			rawClient, rawServer := pair(t, kind, "hello\n")
			// readLoop sets its own per-iteration deadline; an already-expired
			// one left by pair would race its first read.
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

			// The connection is only "usable" if something actually crosses it.
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
					// tcp and quic carried the big line happily; skip past it.
				case <-deadline:
					t.Fatalf("%s: the send after a refused one never arrived", kind)
				}
			}
		})
	}
}
