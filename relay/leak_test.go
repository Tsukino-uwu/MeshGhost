package relay

import (
	"fmt"
	"runtime"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// awaitWelcome insists the Welcome is the first message: Client.holdUntilWelcome makes anything earlier a regression.
func awaitWelcome(t *testing.T, tc *testClient) {
	t.Helper()
	if env := tc.next(timeout); env.Type != protocol.TypeWelcome {
		t.Fatalf("the first message on a new connection was %q, not the Welcome -- "+
			"Client.holdUntilWelcome exists to make that impossible, and a client that "+
			"reads a Join or a Leave before its own Welcome rebuilds its roster from a "+
			"Welcome that then erases what it just learned", env.Type)
	}
}

// waitForGoroutines polls, since teardown is asynchronous on both sides of a connection, and returns the last count.
func waitForGoroutines(want int, timeout time.Duration) int {
	deadline := time.Now().Add(timeout)
	for {
		runtime.GC()
		got := runtime.NumGoroutine()
		if got <= want || time.Now().After(deadline) {
			return got
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestNoGoroutineLeakAcrossManyConnections churns far more connections than the tolerance, so a per-connection leak
// cannot hide in the noise. A disconnect test would pass with the handler goroutine still parked.
func TestNoGoroutineLeakAcrossManyConnections(t *testing.T) {
	srv := NewServer()
	srv.MaxClients = 64
	addr := startServerWith(t, srv)

	// Let startup goroutines settle, so the baseline is not an undercount.
	waitForGoroutines(0, 200*time.Millisecond)
	baseline := runtime.NumGoroutine()

	const rounds, perRound = 20, 8
	for r := 0; r < rounds; r++ {
		clients := make([]*testClient, 0, perRound)
		for i := 0; i < perRound; i++ {
			tc := dialTestClient(t, addr, "leakgame", "leakroom", fmt.Sprintf("p%d-%d", r, i))
			awaitWelcome(t, tc)
			clients = append(clients, tc)
		}
		for _, tc := range clients {
			tc.conn.Close()
		}
	}

	// The runtime keeps goroutines of its own; a per-connection leak would be 160 here, far outside the band.
	const tolerance = 10
	if got := waitForGoroutines(baseline+tolerance, 10*time.Second); got > baseline+tolerance {
		buf := make([]byte, 1<<16)
		n := runtime.Stack(buf, true)
		t.Fatalf("goroutines did not return to baseline after %d connections: baseline=%d got=%d\n%s",
			rounds*perRound, baseline, got, buf[:n])
	}
}

// TestNoSlotLeak: a MaxClients slot released on some disconnect paths but not others would refuse joins while the
// relay looks healthy.
func TestNoSlotLeak(t *testing.T) {
	srv := NewServer()
	srv.MaxClients = 4
	addr := startServerWith(t, srv)

	// Past the cap: one leaked slot per connection would refuse the fifth join.
	for i := 0; i < 24; i++ {
		tc := dialTestClient(t, addr, "slotgame", "slotroom", fmt.Sprintf("p%d", i))
		awaitWelcome(t, tc)
		tc.conn.Close()

		// The slot is released when the relay notices the hangup.
		deadline := time.Now().Add(2 * time.Second)
		for {
			srv.mu.Lock()
			count := srv.clientCount
			srv.mu.Unlock()
			if count == 0 || time.Now().After(deadline) {
				if count != 0 {
					t.Fatalf("after closing connection %d, relay still holds %d slot(s)", i, count)
				}
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
}

// TestRoomIsDroppedEvenWhenItHeldAWorld: a world outlives its lease and writer by design, so MaxWorldKeysPerRoom is
// a cap only if the room still goes when its last member leaves.
func TestRoomIsDroppedEvenWhenItHeldAWorld(t *testing.T) {
	s := NewServer()

	r, _ := worldRoom(t, worldFeatures, "p1")
	r.key = roomKey(r.GameID, r.Name)
	s.mu.Lock()
	s.rooms[r.key] = r
	s.mu.Unlock()

	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "alive")
	r.mu.Lock()
	entities := len(r.world)
	r.mu.Unlock()
	if entities != 1 {
		t.Fatalf("world held %d entities before the leave, want 1", entities)
	}

	s.finishLeave(r, "p1")

	s.mu.Lock()
	_, present := s.rooms[r.key]
	s.mu.Unlock()
	if present {
		t.Fatal("the room outlived its last member because it was still holding a world -- " +
			"MaxWorldKeysPerRoom is only a cap if the room itself is still dropped")
	}
}
