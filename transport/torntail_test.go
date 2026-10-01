package transport

import (
	"net"
	"testing"
	"time"
)

// TestATornFinalLineIsNeverDelivered pins the reader's EOF rule: a stream that ends without a newline ends
// mid-message, and that fragment is dropped, never handed to OnReceive as a line.
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
		// One whole line, the front half of a second, then the close: what a write deadline expiring mid-line leaves.
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
