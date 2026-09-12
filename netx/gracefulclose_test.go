package netx_test

// CloseGracefully must actually half-close, on every transport (2026-09-12).
//
// conformance_test.go's rule is that a behaviour promised by the Transport
// contract belongs in this suite, and this is one of the strongest promises the
// project makes to itself. Three places rely on "write the reason, then hang
// up, and the reason still arrives": the relay's Reject for a refused hello,
// its Reject for a rate-limited client, and the core's goodbye before a
// deliberate leave. CloseGracefully is the method that keeps it -- it stops
// writing, keeps READING for a bounded window so the peer's unread traffic is
// consumed rather than reset, and lets the read loop close the socket when the
// peer's own FIN arrives or the drain ends.
//
// Except that it asserts for CloseWrite and silently degrades to a hard Close
// for a connection that cannot half-close -- and until 2026-09-12 that was two
// of the three transports. On udp the degradation is strictly worse than the
// tcp reset the method exists to avoid: Close ends the retry loop, so the
// Reject goes out as ONE datagram with nothing behind it, and it unregisters
// the connection from its listener, so the drain reads nothing at all. A client
// with a wrong room code that loses that one packet sees a silence it cannot
// tell from a network fault, treats a permanent refusal as transient, and
// reconnects for as long as the game is left running. On quic the Reject
// survived anyway (closeLinger covers it by another route), which is exactly
// why nobody noticed the drain was not happening there either.
//
// Found by the transports cell of the third adversarial review (P1d-1).

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// TestConformanceCloseGracefullyKeepsReadingDuringTheDrain asserts the half
// that is invisible from the outside and that both datagram transports were
// skipping. The peer is still talking when we hang up -- which is the whole
// premise of the rate-limit case, where most of a flood is unread server-side
// at the moment the Reject goes out.
func TestConformanceCloseGracefullyKeepsReadingDuringTheDrain(t *testing.T) {
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

			// rejectAndClose's exact shape.
			if err := server.Send([]byte(`{"type":"reject","reason":"bad room code"}`)); err != nil {
				t.Fatalf("%s: send the reject: %v", kind, err)
			}
			server.CloseGracefully(2 * time.Second)

			// The peer had not finished talking, and had no way to know we were
			// about to stop.
			//
			// A RAW WRITE, not one through transport: an NDJSONConn on this end
			// would see tcp's FIN, close ITSELF, and fail this write -- which is
			// correct behaviour for a client and a race for a test (it flaked on
			// the second -count run and passed on the first). A flooding client
			// is not politely watching for our FIN anyway; its bytes are already
			// in the socket, which is the case the drain exists for.
			const late = `{"type":"state","seq":9}`
			if _, err := rawClient.Write([]byte(late + "\n")); err != nil {
				t.Fatalf("%s: the peer could not write after our half-close: %v", kind, err)
			}

			select {
			case got := <-lines:
				if got != late {
					t.Fatalf("%s: drained %q, want %q", kind, got, late)
				}
			case <-time.After(conformanceTimeout):
				t.Fatalf("%s: nothing was read during the drain window -- CloseGracefully "+
					"degraded to a hard close, so the peer's in-flight traffic was discarded "+
					"and (on udp) the reject it just wrote will never be retransmitted", kind)
			}
		})
	}
}

// TestConformanceTheRejectStillArrivesAfterCloseGracefully is the visible half,
// and it is here rather than in conformance_test.go's send-before-close test
// because that one uses Close: this is the same promise through the method the
// relay actually calls.
func TestConformanceTheRejectStillArrivesAfterCloseGracefully(t *testing.T) {
	for _, kind := range transportsUnderTest {
		t.Run(kind.String(), func(t *testing.T) {
			rawClient, rawServer := pair(t, kind, "hello\n")
			if err := rawClient.SetReadDeadline(time.Time{}); err != nil {
				t.Fatalf("%s: clear read deadline: %v", kind, err)
			}

			lines := make(chan string, 8)
			client := transport.FromConn(rawClient)
			t.Cleanup(func() { client.Close() })
			client.OnReceive(func(payload []byte) { lines <- string(payload) })

			server := transport.FromConn(rawServer)
			t.Cleanup(func() { server.Close() })

			const reject = `{"type":"reject","reason":"bad room code"}`
			if err := server.Send([]byte(reject)); err != nil {
				t.Fatalf("%s: send the reject: %v", kind, err)
			}
			server.CloseGracefully(2 * time.Second)

			select {
			case got := <-lines:
				if got != reject {
					t.Fatalf("%s: client received %q, want the reject", kind, got)
				}
			case <-time.After(conformanceTimeout):
				t.Fatalf("%s: the client never saw the reject, so a refusal is indistinguishable "+
					"from a crash -- which is the whole of what rejectAndClose exists to prevent", kind)
			}
		})
	}
}
