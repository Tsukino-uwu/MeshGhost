package netx_test

// The unreliable half of the transport conformance suite (added 2026-09-08).
//
// conformance_test.go's own stated rule is "if a behaviour is promised by the
// Transport contract rather than by one implementation, it belongs here" — and
// until this file existed the suite never sent a single byte on the unreliable
// plane, which is the MOST implementation-divergent promise in
// agent_docs/contract.md. The three transports do three genuinely different
// things for one method call: quic writes an RFC 9221 datagram beside its
// stream, udpconn writes an unsequenced datagram beside its own ack/resequence
// machinery, and tcp has no unreliable mode at all and falls through to Send.
// Three code paths, one contract, zero conformance coverage — while the state
// plane, the hottest path in the project at 15 Hz per peer, is the only caller.
//
// **What these tests pin, and what they deliberately do NOT.** Delivery on the
// unreliable plane is not promised by anything, so no test here may assert that
// an unreliable payload arrives — on udp and quic it is free to be dropped, and
// a test that assumed otherwise would be a loopback-only truth that fails the
// day it meets a real network. What IS promised, and what is asserted below:
//
//  1. Framing integrity. A datagram written on the unreliable plane must never
//     be spliced into, truncate, or reorder the RELIABLE stream running beside
//     it. This is the property with teeth: both datagram transports share one
//     socket between the two planes, and udpconn shares a scratch buffer
//     between them too (conn.go's lossyBuf). A regression there would show up
//     in a game as a peer whose join or leave was mangled by its own position
//     updates — a stranded ghost, diagnosed at the wrong layer.
//  2. tcp's fallback genuinely delivers, in stream order with the reliable
//     lines around it. transport.SendUnreliable documents "over TCP there is
//     nothing to give up"; TestSendUnreliableMatchesSendOverTCP in
//     transport/transport_test.go asserts the write shape against a fake
//     net.Conn, and nothing asserted end-to-end delivery over a real socket.
//
// Not pinned here, on purpose: whether an oversized unreliable payload errors.
// It genuinely diverges (udpconn returns ErrDatagramTooLarge above
// MaxDatagramBytes, tcp accepts any size), that divergence is documented and
// deliberate, and pinning it here would freeze a per-transport limit into a
// contract file.
//
// These tests run through transport.NDJSONConn rather than calling
// WriteUnreliable on the net.Conn directly, because SendUnreliable is where the
// contract lives: the tcp fallback is a type assertion inside that method, and
// asserting on the netx layer alone could not see it. That is also the exact
// stack the core uses in production (netx.Dial, then transport.FromConn).

import (
	"fmt"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// unreliableExchange is the shared body of both tests below: it brings up a
// pair on kind, wraps both ends in the real NDJSON framer, then sends three
// reliable lines with an unreliable one between each pair, and returns every
// line the server received up to and including the last reliable one.
//
// The interleaving matters. A single unreliable send before or after a quiet
// stream would prove almost nothing; the failure mode worth catching is the two
// planes writing over each other, which only happens when both are in flight at
// once.
func unreliableExchange(t *testing.T, kind netx.Kind) (got []string, reliable, unreliableSent []string) {
	t.Helper()

	rawClient, rawServer := pair(t, kind, "hello\n")

	// Clear the read deadline pair left on the server conn: readLoop sets its
	// own per-iteration deadline, but it reads MaxLineBytes/IdleTimeout at
	// start-up, and an already-expired deadline would race the first read.
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

	// reliable-0, unreliable-0, reliable-1, unreliable-1, reliable-2.
	for i := 0; i < len(reliable); i++ {
		if err := client.Send([]byte(reliable[i])); err != nil {
			t.Fatalf("%s: send %s: %v", kind, reliable[i], err)
		}
		if i < len(unreliableSent) {
			// A failure to WRITE is a defect on every transport, even though a
			// failure to DELIVER is not. SendUnreliable returning an error for
			// a 12-byte payload on a healthy connection would mean the state
			// plane is dead on that transport and the game would silently stop
			// moving for everyone else.
			if err := client.SendUnreliable([]byte(unreliableSent[i])); err != nil {
				t.Fatalf("%s: send unreliable %s: %v", kind, unreliableSent[i], err)
			}
		}
	}

	// Collect until the last reliable line lands. It is reliable, so waiting
	// for it is not a timing guess — and anything the unreliable plane chose to
	// deliver on a datagram transport has either arrived by then or is entitled
	// to never arrive at all.
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

// TestConformanceAnUnreliableSendDoesNotDisturbTheReliableStream is the
// framing-integrity assertion described in this file's header, run against
// every transport.
//
// It pins two things and no more: every reliable line arrives, in the order it
// was sent, with unreliable writes interleaved between them; and every line the
// server delivers is byte-for-byte one of the payloads that was actually sent,
// so nothing was spliced, merged or truncated. It does NOT assert that either
// unreliable line arrived — on udp and quic nothing promises that, and asserting
// it would be a test of loopback rather than of the contract.
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

// TestConformanceTheTCPFallbackForSendUnreliableActuallyDelivers is the one
// unreliable-plane delivery assertion that IS legitimate, and it is legitimate
// only on tcp: transport.SendUnreliable's own doc comment says "over TCP there
// is nothing to give up: the stream is reliable whether or not anyone asks, so
// this is exactly Send".
//
// The regression this catches is a plausible one. SendUnreliable reaches the
// fallback through a type assertion against an unexported interface, so any
// wrapper that grows a WriteUnreliable method — or any refactor that turns the
// fallback into a drop — makes the whole state plane vanish on tcp with no
// error anywhere. That is the same class of wrapper bug the netx limiter hit
// twice (2026-09-02 and the CloseWrite case on 2026-09-05), and tcp is the
// transport a player falls back to when quic is blocked, so the failure would
// land on exactly the people with the worst networks.
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
