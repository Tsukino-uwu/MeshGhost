package transport

import (
	"net"
	"testing"
	"time"
)

// TestATornFinalLineIsNeverDelivered pins the reader's EOF rule: a stream
// that ends without a newline ends mid-message, and that fragment is dropped,
// not handed to OnReceive as if it were a line.
//
// bufio.ScanLines returns the unterminated remainder at EOF as a token, and
// before 2026-09-08 the read loop delivered it. The sender side already
// guarantees the shape this produces: Send closes the connection the moment
// a write fails, and a write that fails on its deadline has usually put the
// front of the line on the wire first -- so the peer sees "half a message,
// then FIN". The core's FuzzEverything reproduced it on CI through a
// throttled adapter (core/testdata/fuzz/FuzzEverything/f131a0858b74689b):
// the fake adapter's decoder reported "unexpected end of JSON input" on a
// payload the core never sent.
//
// Fails without the fix: got receives two payloads, the second being `{"b":`.
func TestATornFinalLineIsNeverDelivered(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()

	conn := FromConn(client)
	defer conn.Close()

	got := make(chan string, 4)
	gone := make(chan struct{})
	conn.OnReceive(func(payload []byte) { got <- string(payload) })
	conn.OnDisconnect(func(error) { close(gone) })

	go func() {
		// One whole line, then the front half of a second one, then the
		// close -- exactly what a write deadline expiring mid-line leaves
		// on the wire.
		_, _ = server.Write([]byte("{\"a\":1}\n{\"b\":"))
		server.Close()
	}()

	select {
	case p := <-got:
		if p != `{"a":1}` {
			t.Fatalf("first payload = %q, want the whole first line", p)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the complete first line was never delivered")
	}
	select {
	case <-gone:
	case <-time.After(2 * time.Second):
		t.Fatal("OnDisconnect never fired after the peer closed")
	}
	select {
	case p := <-got:
		t.Fatalf("the torn tail %q was delivered as a message -- a line without its newline was never sent", p)
	default:
	}
}
