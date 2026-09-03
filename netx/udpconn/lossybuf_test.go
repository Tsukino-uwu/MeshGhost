package udpconn

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

// WriteUnreliable is the state plane's write, so the relay calls it once per
// RECIPIENT for every state a room carries -- the one allocation on that path
// that genuinely scaled with room size, since everything else is per message.
// It now frames into a buffer the connection keeps.
//
// Pinned as an allocation count rather than left to a benchmark, because a
// benchmark reports a regression only if somebody runs it and reads it.
func TestWriteUnreliableDoesNotAllocatePerCall(t *testing.T) {
	l := listenTest(t)
	rawClient, server := dialAndAccept(t, l)
	client, ok := rawClient.(*Conn)
	if !ok {
		t.Fatalf("Dial returned %T, wanted *Conn", rawClient)
	}

	// Drain, so the socket buffer filling up cannot turn into a write error
	// that ends the measurement early.
	// One deadline for the whole drain, set BEFORE the measurement: a
	// SetReadDeadline per read allocates a time value on this goroutine, and
	// testing.AllocsPerRun counts the whole process, so the drain itself was
	// contributing to the number it exists to keep out of the way.
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

	// The MINIMUM over several batches, not one batch. AllocsPerRun counts
	// every allocation in the process during its window -- the listener's
	// goroutines, the runtime, whatever the scheduler lets run -- and under
	// whole-suite load one batch reported 4.0 twice on 2026-09-03 while the
	// same test passed 40 of 40 on its own. A regression in WriteUnreliable
	// allocates on EVERY call and so in every batch; a stray allocation from
	// somewhere else lands in some batches and not others. The minimum tells
	// those apart, which a single batch never could.
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
	// Below one, not "at most one". The regression this pins -- a fresh
	// framing buffer per call -- measures exactly 1.00, and the real code
	// 0.00 (measured 2026-09-03 by removing the reuse on purpose); the old
	// "got > 1" therefore let the very thing it was written for pass. The
	// minimum over batches is what makes a strict bound safe: a stray
	// allocation from another goroutine cannot turn every batch's 0 into 1.
	t.Logf("WriteUnreliable: %.2f allocations per call (minimum of 5 batches)", got)
	if got >= 1 {
		t.Fatalf("WriteUnreliable allocated %.2f times per call (minimum of 5 batches), want 0 "+
			"-- the framing buffer is meant to be reused, not allocated per call", got)
	}
}

// The buffer is shared state on a path the relay drives concurrently, so the
// lock has to cover the write itself and not merely the framing -- otherwise a
// second caller can overwrite a datagram that is still being sent. This is the
// test that would catch that, under -race, which is how it is run in CI.
func TestConcurrentWriteUnreliableKeepsDatagramsIntact(t *testing.T) {
	l := listenTest(t)
	rawClient, server := dialAndAccept(t, l)
	client, ok := rawClient.(*Conn)
	if !ok {
		t.Fatalf("Dial returned %T, wanted *Conn", rawClient)
	}

	const writers = 8
	const each = 40

	// Every payload is a distinct, self-describing line so a torn or
	// interleaved datagram is recognisable rather than merely suspicious.
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

	// UDP may legitimately drop, so this asserts that everything which ARRIVES
	// is one of the exact payloads sent -- never a splice of two. Loss is fine
	// here; corruption is not.
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
