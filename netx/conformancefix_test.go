package netx_test

// The unreliable half of the transport conformance suite. Delivery on the unreliable plane is promised by nothing, so
// no test here asserts an unreliable payload arrives; what is asserted is that it never splices, truncates or
// reorders the reliable stream beside it (both datagram transports share a socket between the planes), and that
// tcp's fallback delivers in stream order. Whether an oversized unreliable payload errors is a deliberate
// per-transport difference and is not pinned here.
//
// The tests run through transport.NDJSONConn because the tcp fallback is a type assertion inside SendUnreliable,
// which the netx layer alone cannot see.

import (
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// unreliableExchange wraps a pair on kind in the real NDJSON framer, sends three reliable lines with an unreliable
// one between each, and returns every line the server received up to the last reliable one. The interleaving is the
// point: the planes can only write over each other while both are in flight.
func unreliableExchange(t *testing.T, kind netx.Kind) (got []string, reliable, unreliableSent []string) {
	t.Helper()

	rawClient, rawServer := pair(t, kind, "hello\n")

	// readLoop sets its own per-iteration deadline; an already-expired one left by pair would race its first read.
	if err := rawServer.SetReadDeadline(time.Time{}); err != nil {
		t.Fatalf("%s: clear read deadline: %v", kind, err)
	}

	lines := make(chan string, 16)
	server := transport.FromConn(rawServer)
	t.Cleanup(func() { server.Close() })
	server.OnReceive(func(payload []byte) { lines <- string(payload) })

	client := transport.FromConn(rawClient)
	t.Cleanup(func() { client.Close() })

	reliable = []string{"reliable-0", "reliable-1", "reliable-2"}
	unreliableSent = []string{"unreliable-0", "unreliable-1"}

	for i := 0; i < len(reliable); i++ {
		if err := client.Send([]byte(reliable[i])); err != nil {
			t.Fatalf("%s: send %s: %v", kind, reliable[i], err)
		}
		if i < len(unreliableSent) {
			// A failure to write is a defect on every transport, even though a failure to deliver is not.
			if err := client.SendUnreliable([]byte(unreliableSent[i])); err != nil {
				t.Fatalf("%s: send unreliable %s: %v", kind, unreliableSent[i], err)
			}
		}
	}

	// Waiting for the last reliable line is not a timing guess; an unreliable line not in by then may never arrive.
	deadline := time.After(conformanceTimeout)
	for {
		select {
		case line := <-lines:
			got = append(got, line)
			if line == reliable[len(reliable)-1] {
				return got, reliable, unreliableSent
			}
		case <-deadline:
			t.Fatalf("%s: timed out waiting for the last reliable line; got %q", kind, got)
		}
	}
}

// TestConformanceAnUnreliableSendDoesNotDisturbTheReliableStream: every reliable line arrives in order, and every
// delivered line is byte-for-byte one that was sent. Whether an unreliable line arrived is not asserted.
func TestConformanceAnUnreliableSendDoesNotDisturbTheReliableStream(t *testing.T) {
	for _, kind := range transportsUnderTest {
		t.Run(kind.String(), func(t *testing.T) {
			got, reliable, unreliableSent := unreliableExchange(t, kind)

			known := map[string]bool{}
			for _, s := range append(append([]string{}, reliable...), unreliableSent...) {
				known[s] = true
			}
			var gotReliable []string
			for _, line := range got {
				if !known[line] {
					t.Fatalf("%s: server delivered %q, which was never sent — the unreliable "+
						"plane corrupted the framing of the reliable one (all lines: %q)",
						kind, line, got)
				}
				switch line {
				case reliable[0], reliable[1], reliable[2]:
					gotReliable = append(gotReliable, line)
				}
			}

			if fmt.Sprint(gotReliable) != fmt.Sprint(reliable) {
				t.Fatalf("%s: reliable lines arrived as %q, want %q (all lines: %q)",
					kind, gotReliable, reliable, got)
			}
		})
	}
}

// TestConformanceTheTCPFallbackForSendUnreliableActuallyDelivers: on tcp SendUnreliable is exactly Send, so this is
// the one legitimate unreliable delivery assertion. The fallback is a type assertion, so a wrapper or refactor could
// turn it into a silent drop of the whole state plane on tcp.
func TestConformanceTheTCPFallbackForSendUnreliableActuallyDelivers(t *testing.T) {
	got, reliable, unreliableSent := unreliableExchange(t, netx.TCP)

	want := []string{
		reliable[0], unreliableSent[0],
		reliable[1], unreliableSent[1],
		reliable[2],
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("tcp: server received %q, want %q — on tcp SendUnreliable IS Send, "+
			"so every line must arrive and in the order it was written", got, want)
	}
}
