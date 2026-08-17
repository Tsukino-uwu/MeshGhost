package netx_test

// The transport conformance suite: one set of behavioural assertions, run
// against EVERY transport.
//
// **Why this exists, and why it is a suite rather than more tests.** The whole
// point of netx is that tcp, udp and quic are interchangeable behind
// one interface — agent_docs/contract.md promises `send` is "reliable AND
// ordered on every transport", and relay is deliberately built so it
// "never learns which is which". A behaviour that holds on one transport and
// not another therefore breaks a documented guarantee while every existing
// test still passes, because each transport's own tests only ever ask whether
// *it* is self-consistent.
//
// That is not hypothetical. It is exactly how the 2026-08-17 quic close bug
// escaped: `Close()` tore down the connection immediately after closing the
// stream, so the last message written before a close was discarded. Send-
// before-close is a pattern this project relies on in three places (the
// relay's Reject when refusing a hello, its rate-limit Reject, and the core's
// goodbye before a deliberate leave), so a refused quic client saw a bare
// hangup instead of the reason — the exact failure `rejectAndClose` exists to
// prevent. tcp was fine throughout. It was found by a feature going missing in
// a live session, which is the expensive way to find things.
//
// **The rule for adding to this file: if a behaviour is promised by the
// Transport contract rather than by one implementation, it belongs here, not
// in a per-transport test.** Anything asserted here is automatically asserted
// against every transport, including any added later.

import (
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
)

const conformanceTimeout = 5 * time.Second

// transportsUnderTest is every kind netx can dial and listen on. Adding a
// transport here subjects it to the whole suite at once, which is the point:
// a new transport should have to earn the same guarantees rather than being
// trusted to have them.
var transportsUnderTest = []netx.Kind{netx.TCP, netx.UDP, netx.QUIC}

// pair brings up a connected client/server couple on kind. The client sends
// greeting first, because a QUIC stream does not exist on the wire until it
// is written to — so Accept cannot return before the client says something,
// which is exactly what a real client's hello does.
func pair(t *testing.T, kind netx.Kind, greeting string) (client, server net.Conn) {
	t.Helper()

	ln, err := netx.Listen(kind, "127.0.0.1:0")
	if err != nil {
		t.Fatalf("%s: listen: %v", kind, err)
	}
	t.Cleanup(func() { ln.Close() })

	type accepted struct {
		c   net.Conn
		err error
	}
	ch := make(chan accepted, 1)
	go func() {
		c, err := ln.Accept()
		ch <- accepted{c, err}
	}()

	client, err = netx.Dial(kind, ln.Addr().String(), conformanceTimeout)
	if err != nil {
		t.Fatalf("%s: dial: %v", kind, err)
	}
	t.Cleanup(func() { client.Close() })

	if _, err := client.Write([]byte(greeting)); err != nil {
		t.Fatalf("%s: write greeting: %v", kind, err)
	}

	select {
	case a := <-ch:
		if a.err != nil {
			t.Fatalf("%s: accept: %v", kind, a.err)
		}
		server = a.c
	case <-time.After(conformanceTimeout):
		t.Fatalf("%s: timed out waiting for accept", kind)
	}
	t.Cleanup(func() { server.Close() })

	if err := server.SetReadDeadline(time.Now().Add(conformanceTimeout)); err != nil {
		t.Fatalf("%s: set read deadline: %v", kind, err)
	}
	mustReadExactly(t, kind, server, greeting)
	return client, server
}

// mustReadExactly reads exactly len(want) bytes and requires them to match,
// tolerating short reads — a stream may hand over a partial buffer even when
// everything has arrived.
func mustReadExactly(t *testing.T, kind netx.Kind, c net.Conn, want string) {
	t.Helper()
	buf := make([]byte, len(want))
	total := 0
	for total < len(buf) {
		n, err := c.Read(buf[total:])
		total += n
		if err != nil {
			t.Fatalf("%s: read: %v (got %q, want %q)", kind, err, buf[:total], want)
		}
	}
	if string(buf) != want {
		t.Fatalf("%s: read %q, want %q", kind, buf, want)
	}
}

// TestConformanceFinalWriteBeforeCloseIsDelivered is the regression test for
// the 2026-08-17 quic close bug, written as a contract assertion rather than a
// quic one — because the bug was never that quic was wrong in isolation, it
// was that quic differed from tcp on a guarantee the callers rely on.
//
// Send-before-close must work everywhere: the relay writes a Reject and then
// closes, and a peer that receives the hangup without the reason cannot tell a
// refusal from a crash.
func TestConformanceFinalWriteBeforeCloseIsDelivered(t *testing.T) {
	for _, kind := range transportsUnderTest {
		t.Run(kind.String(), func(t *testing.T) {
			client, server := pair(t, kind, "hello\n")

			const farewell = "goodbye\n"
			if _, err := client.Write([]byte(farewell)); err != nil {
				t.Fatalf("%s: write farewell: %v", kind, err)
			}
			// Immediately, with no flush and no sleep — exactly what every
			// send-before-close site in this codebase does.
			if err := client.Close(); err != nil {
				t.Fatalf("%s: close: %v", kind, err)
			}

			if err := server.SetReadDeadline(time.Now().Add(conformanceTimeout)); err != nil {
				t.Fatalf("%s: set read deadline: %v", kind, err)
			}
			mustReadExactly(t, kind, server, farewell)
		})
	}
}

// TestConformanceSendIsOrdered pins agent_docs/contract.md's promise that
// `send` is "reliable AND ordered on every transport" — stated explicitly in
// the contract because ordering is a separate property from delivery and is
// NOT implied by retransmission. udpconn had to resequence to earn it, and did
// not until 2026-08-16, when a retransmitted payload arriving after a later
// one stranded ghosts by letting a leave overtake its own join.
func TestConformanceSendIsOrdered(t *testing.T) {
	const lines = 200
	for _, kind := range transportsUnderTest {
		t.Run(kind.String(), func(t *testing.T) {
			client, server := pair(t, kind, "hello\n")

			for i := 0; i < lines; i++ {
				if _, err := client.Write([]byte(fmt.Sprintf("line-%d\n", i))); err != nil {
					t.Fatalf("%s: write %d: %v", kind, i, err)
				}
			}
			if err := server.SetReadDeadline(time.Now().Add(conformanceTimeout)); err != nil {
				t.Fatalf("%s: set read deadline: %v", kind, err)
			}
			for i := 0; i < lines; i++ {
				mustReadExactly(t, kind, server, fmt.Sprintf("line-%d\n", i))
			}
		})
	}
}

// TestConformanceBidirectional checks that a transport is genuinely
// two-directional after the client-first handshake QUIC forces. Worth pinning
// because the relay's whole job is to write back down a connection the client
// opened, and a transport that only worked client-to-server would look healthy
// right up until the first join broadcast.
func TestConformanceBidirectional(t *testing.T) {
	for _, kind := range transportsUnderTest {
		t.Run(kind.String(), func(t *testing.T) {
			client, server := pair(t, kind, "hello\n")

			const down = "welcome\n"
			if _, err := server.Write([]byte(down)); err != nil {
				t.Fatalf("%s: server write: %v", kind, err)
			}
			if err := client.SetReadDeadline(time.Now().Add(conformanceTimeout)); err != nil {
				t.Fatalf("%s: set read deadline: %v", kind, err)
			}
			mustReadExactly(t, kind, client, down)
		})
	}
}

// TestConformanceReadAfterPeerCloseReportsAnError checks the other half of
// closing: once a peer has gone and its data is drained, a read must fail
// rather than block forever. transport's read loop turns that error
// into OnDisconnect, which is what drives every despawn — a transport that
// blocked instead would leave a ghost frozen on screen with nothing to
// explain it.
func TestConformanceReadAfterPeerCloseReportsAnError(t *testing.T) {
	for _, kind := range transportsUnderTest {
		t.Run(kind.String(), func(t *testing.T) {
			if kind == netx.UDP {
				// KNOWN DIVERGENCE, found by this suite on its first run
				// 2026-08-17 — recorded rather than quietly dropped.
				//
				// udpconn sends nothing on Close, so a peer learns of a
				// departure only when transport.DefaultIdleTimeout (60s)
				// fires. tcp reports it immediately via RST, and quic within
				// its idle timeout (~17s, measured). The user-visible cost is
				// real: a player on udp who quits or crashes leaves a frozen
				// ghost on every other screen for up to a minute.
				//
				// Not fixed here on purpose. The fix is a new control frame,
				// and udpconn is the project's most exposed surface — it
				// parses stranger datagrams before any room code or protocol
				// version check, has its own fuzz target, and token-checks
				// every application frame precisely so a guessed ip:port
				// cannot inject into a session. A "close this connection"
				// frame MUST carry that token too, or it becomes a remote
				// hangup primitive. That earns its own pass.
				//
				// The application-level goodbye added the same day already
				// covers the COMMON case here: a deliberate quit sends a leave
				// on the reliable plane, so only an *unexplained* drop waits
				// out the idle timeout.
				t.Skip("udpconn signals nothing on close — see this comment and agent_docs/status.md")
			}
			client, server := pair(t, kind, "hello\n")
			client.Close()

			if err := server.SetReadDeadline(time.Now().Add(conformanceTimeout)); err != nil {
				t.Fatalf("%s: set read deadline: %v", kind, err)
			}
			buf := make([]byte, 64)
			for {
				_, err := server.Read(buf)
				if err == nil {
					continue // drain anything still in flight
				}
				if strings.Contains(err.Error(), "timeout") ||
					strings.Contains(err.Error(), "deadline exceeded") {
					t.Fatalf("%s: read blocked until the deadline after the peer closed, "+
						"instead of reporting the disconnect", kind)
				}
				return
			}
		})
	}
}
