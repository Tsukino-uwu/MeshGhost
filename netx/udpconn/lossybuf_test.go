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
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, MaxDatagramBytes)
		for {
			_ = server.SetReadDeadline(time.Now().Add(testTimeout))
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

	got := testing.AllocsPerRun(200, func() {
		if _, err := client.WriteUnreliable(payload); err != nil {
			t.Fatalf("write: %v", err)
		}
	})
	// Not asserted as exactly zero: the write syscall itself may allocate
	// inside the runtime on some platforms, and this test is about the framing
	// buffer, which was one guaranteed allocation on every single call.
	if got > 1 {
		t.Fatalf("WriteUnreliable allocated %.1f times per call, want at most 1 "+
			"(the reusable framing buffer should account for none of them)", got)
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
