package netx_test

// The transport conformance suite: one set of behavioural assertions, run against every transport, because each
// transport's own tests only ask whether it is self-consistent, and a behaviour that holds on one and not another
// breaks the contract while they all pass. A behaviour the Transport contract promises belongs here, not in a
// per-transport test.

import (
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

const conformanceTimeout = 5 * time.Second

// pair brings up a connected client/server couple on kind. The client sends greeting first, because a QUIC stream
// does not exist on the wire until it is written to, so Accept cannot return before the client speaks.
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

	// quic has no unverified dial, and this suite is about framing, not identity, so it trusts any certificate.
	if kind == netx.QUIC {
		client, err = netx.DialWithTLS(kind, ln.Addr().String(), conformanceTimeout,
			netx.TLSOptions{Verify: tlsx.TrustAnyCertificate})
	} else {
		client, err = netx.Dial(kind, ln.Addr().String(), conformanceTimeout)
	}
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

// mustReadExactly reads exactly len(want) bytes and requires them to match, tolerating short reads.
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

// TestConformanceFinalWriteBeforeCloseIsDelivered: the relay writes a Reject and then closes, and a peer that gets
// the hangup without the reason cannot tell a refusal from a crash.
func TestConformanceFinalWriteBeforeCloseIsDelivered(t *testing.T) {
	for _, kind := range transportsUnderTest {
		t.Run(kind.String(), func(t *testing.T) {
			client, server := pair(t, kind, "hello\n")

			const farewell = "goodbye\n"
			if _, err := client.Write([]byte(farewell)); err != nil {
				t.Fatalf("%s: write farewell: %v", kind, err)
			}
			// No flush and no sleep, as every send-before-close site does.
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

// TestConformanceSendIsOrdered: send is reliable and ordered on every transport, and ordering is not implied by
// retransmission.
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

// TestConformanceBidirectional: after the client-first handshake QUIC forces, the relay must still be able to write
// back down the connection the client opened.
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

// TestConformanceReadAfterPeerCloseReportsAnError: once a peer has gone and its data is drained, a read must fail
// rather than block, because transport turns that error into the OnDisconnect that despawns a ghost.
func TestConformanceReadAfterPeerCloseReportsAnError(t *testing.T) {
	for _, kind := range transportsUnderTest {
		t.Run(kind.String(), func(t *testing.T) {
			if kind == netx.UDP {
				// udpconn sends nothing on Close, so a dropped peer is noticed only at transport's idle timeout. A
				// close frame would have to carry the session token, or it becomes a remote hangup primitive.
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
