//go:build meshghost_devudp

package udpconn

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

// TestWriteUnreliableDoesNotAllocatePerCall: the relay calls WriteUnreliable once per recipient per state, so it
// frames into a buffer the connection keeps. An allocation count, because a benchmark only reports a regression if
// somebody runs it and reads it.
func TestWriteUnreliableDoesNotAllocatePerCall(t *testing.T) {
	l := listenTest(t)
	rawClient, server := dialAndAccept(t, l)
	client, ok := rawClient.(*Conn)
	if !ok {
		t.Fatalf("Dial returned %T, wanted *Conn", rawClient)
	}

	// Drain, so a full socket buffer cannot end the measurement with a write error. One deadline, set before the
	// measurement: a SetReadDeadline per read allocates, and AllocsPerRun counts the whole process.
	done := make(chan struct{})
	_ = server.SetReadDeadline(time.Now().Add(testTimeout))
	go func() {
		defer close(done)
		buf := make([]byte, MaxDatagramBytes)
		for {
			if _, err := server.Read(buf); err != nil {
				return
			}
		}
	}()
	t.Cleanup(func() {
		_ = server.Close()
		<-done
	})

	payload := []byte(`{"type":"state","payload":{"position":[1,2]}}`)
	// One warm-up so the buffer reaches its size before counting.
	if _, err := client.WriteUnreliable(payload); err != nil {
		t.Fatalf("warm-up write: %v", err)
	}

	// The minimum over several batches: AllocsPerRun counts every allocation in the process, so a stray one from
	// another goroutine lands in some batches, while a regression here allocates in every batch.
	got := testing.AllocsPerRun(200, func() {
		if _, err := client.WriteUnreliable(payload); err != nil {
			t.Fatalf("write: %v", err)
		}
	})
	for i := 0; i < 4; i++ {
		if again := testing.AllocsPerRun(200, func() {
			if _, err := client.WriteUnreliable(payload); err != nil {
				t.Fatalf("write: %v", err)
			}
		}); again < got {
			got = again
		}
	}
	// Below one, not at most one: a fresh framing buffer per call measures exactly 1.00, the real code 0.00.
	t.Logf("WriteUnreliable: %.2f allocations per call (minimum of 5 batches)", got)
	if got >= 1 {
		t.Fatalf("WriteUnreliable allocated %.2f times per call (minimum of 5 batches), want 0 "+
			"-- the framing buffer is meant to be reused, not allocated per call", got)
	}
}

// TestConcurrentWriteUnreliableKeepsDatagramsIntact: the lock covers the write itself, not merely the framing, so a
// second caller cannot overwrite a datagram still being sent. It catches that under -race.
func TestConcurrentWriteUnreliableKeepsDatagramsIntact(t *testing.T) {
	l := listenTest(t)
	rawClient, server := dialAndAccept(t, l)
	client, ok := rawClient.(*Conn)
	if !ok {
		t.Fatalf("Dial returned %T, wanted *Conn", rawClient)
	}

	const writers = 8
	const each = 40

	// Every payload is a distinct, self-describing line, so a torn or interleaved datagram is recognisable.
	want := make(map[string]bool, writers*each)
	var mu sync.Mutex
	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		for i := 0; i < each; i++ {
			s := fmt.Sprintf(`{"w":%d,"i":%d,"pad":"%s"}`, w, i, "xxxxxxxxxxxxxxxx")
			want[s] = true
		}
	}

	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < each; i++ {
				s := fmt.Sprintf(`{"w":%d,"i":%d,"pad":"%s"}`, w, i, "xxxxxxxxxxxxxxxx")
				if _, err := client.WriteUnreliable([]byte(s)); err != nil {
					mu.Lock()
					t.Errorf("write: %v", err)
					mu.Unlock()
					return
				}
			}
		}(w)
	}
	wg.Wait()

	// UDP may drop, so loss is fine; everything that arrives must be one exact payload, never a splice of two.
	buf := make([]byte, MaxDatagramBytes)
	seen := 0
	for {
		_ = server.SetReadDeadline(time.Now().Add(250 * time.Millisecond))
		n, err := server.Read(buf)
		if err != nil {
			break
		}
		got := string(buf[:n])
		if !want[got] {
			t.Fatalf("received a datagram that was never sent as a unit: %q", got)
		}
		seen++
	}
	if seen == 0 {
		t.Fatal("no datagrams arrived at all; the test proved nothing")
	}
}
