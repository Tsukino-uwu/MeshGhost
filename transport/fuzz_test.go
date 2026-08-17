package transport

import (
	"net"
	"testing"
	"time"
)

// FuzzReadLoopNeverExceedsItsLineLimit drives arbitrary bytes through the
// framing layer that sits in front of every parser in this project.
//
// The property under test is the one DefaultMaxLineBytes exists for: a peer
// that streams bytes with no newline must not be able to make the reader
// buffer without bound. The old bufio.Reader.ReadBytes implementation grew
// its buffer until it found a '\n', so any length check applied to the
// delivered payload ran too late to prevent the growth. This asserts the
// limit holds during the read itself — no delivered payload may exceed it,
// whatever the input looks like.
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

	// Deliberately small so a fuzzer-sized input can actually cross it;
	// the production value is 4KiB-64KiB and would need huge inputs to test.
	const maxLine = 128

	f.Fuzz(func(t *testing.T, data []byte) {
		client, server := net.Pipe()

		// Idle timeout disabled (< 0): closing the client end is what ends
		// the read loop here, and a real deadline would only add flakiness.
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

		// The read loop stops on an over-long line, and net.Pipe is
		// unbuffered — without a deadline our own Write would then block
		// forever, turning a caught bug into a hung fuzz run.
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
	})
}
