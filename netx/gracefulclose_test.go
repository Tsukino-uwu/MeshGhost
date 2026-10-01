package netx_test

// CloseGracefully must actually half-close on every transport: it stops writing and keeps reading for a bounded
// window, so the reason written before a hang-up (a Reject, the core's goodbye) arrives rather than being reset. It
// degrades to a hard Close without CloseWrite, and on loopback the reject can still arrive, so only the drain test
// catches a transport missing it.

import (
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// TestConformanceCloseGracefullyKeepsReadingDuringTheDrain asserts the half invisible from outside: the peer is
// still talking when the server hangs up, as a flooding client is when its rate-limit Reject goes out.
func TestConformanceCloseGracefullyKeepsReadingDuringTheDrain(t *testing.T) {
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

			// rejectAndClose's exact shape.
			if err := server.Send([]byte(`{"type":"reject","reason":"bad room code"}`)); err != nil {
				t.Fatalf("%s: send the reject: %v", kind, err)
			}
			server.CloseGracefully(2 * time.Second)

			// A raw write: an NDJSONConn here would see tcp's FIN, close itself and fail the write, which is right for
			// a client and a race for a test. A flooding client's bytes are already in the socket anyway.
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

// TestConformanceTheRejectStillArrivesAfterCloseGracefully is the visible half: send-before-close through the method
// the relay actually calls, not Close.
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
