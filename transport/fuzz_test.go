package transport

import (
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// FuzzReadLoopNeverExceedsItsLineLimit drives arbitrary bytes through the framing in front of every parser: whatever
// the input, no payload past the line limit is delivered, and none is buffered during the read.
//
// Longer campaign:
//
//	go test ./transport -run=Fuzz -fuzz=FuzzReadLoopNeverExceedsItsLineLimit -fuzztime=60s
func FuzzReadLoopNeverExceedsItsLineLimit(f *testing.F) {
	f.Add([]byte("{}\n"))
	f.Add([]byte("{\"a\":1}\r\n{\"b\":2}\n"))
	f.Add([]byte("no newline at all"))
	f.Add([]byte("\n\n\n"))
	f.Add(make([]byte, 300)) // long, unterminated: the exhaustion shape
	f.Add([]byte{0x00, 0xff, 0xfe})

	// Small, so a fuzzer-sized input can cross it.
	const maxLine = 128

	// The probe sees every split call's buffer length, which a check on delivered payloads alone cannot.
	var peak atomic.Int64
	probe := func(n int) {
		for {
			cur := peak.Load()
			if int64(n) <= cur || peak.CompareAndSwap(cur, int64(n)) {
				return
			}
		}
	}
	bufferProbe.Store(&probe)
	f.Cleanup(func() { bufferProbe.Store(nil) })

	f.Fuzz(func(t *testing.T, data []byte) {
		client, server := net.Pipe()

		// Idle timeout disabled: closing the client end ends the read loop, and a deadline would only add flakiness.
		nd := FromConnWithLimits(server, maxLine, -1, time.Second)

		oversized := make(chan int, 1)
		done := make(chan struct{})
		nd.OnReceive(func(payload []byte) {
			if len(payload) > maxLine {
				select {
				case oversized <- len(payload):
				default:
				}
			}
		})
		nd.OnDisconnect(func(error) { close(done) })

		// The read loop stops on an over-long line and net.Pipe is unbuffered, so without a deadline this Write could
		// block forever.
		_ = client.SetWriteDeadline(time.Now().Add(2 * time.Second))
		_, _ = client.Write(data)
		_ = client.Close()

		select {
		case <-done:
		case <-time.After(5 * time.Second):
			nd.Close()
			t.Fatal("read loop did not terminate after the peer hung up")
		}
		nd.Close()

		select {
		case n := <-oversized:
			t.Fatalf("delivered a %d-byte payload past the %d-byte line limit", n, maxLine)
		default:
		}
		if n := peak.Load(); n > maxLine {
			t.Fatalf("the read loop buffered %d bytes of one line, past the %d-byte limit", n, maxLine)
		}
	})
}
