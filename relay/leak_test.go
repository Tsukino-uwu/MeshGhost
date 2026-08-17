package relay

import (
	"fmt"
	"runtime"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The relay spawns a goroutine per accepted connection (Serve) plus one read
// loop inside each transport.NDJSONConn. Nothing in relay_test.go asserts
// those ever go away: the disconnect tests check that peers observe a Leave,
// which they would even if the handler goroutine stayed parked forever. A
// relay is a long-lived process holding sessions for hours, so a goroutine
// that outlives its connection is a slow leak that only shows up in
// production.

// awaitWelcome waits for this client's Welcome, skipping anything that
// arrives ahead of it.
//
// relay_test.go's expectWelcome insists the Welcome is the *first* message,
// which is right for tests that join a quiet room but wrong here. These tests
// deliberately churn connections through one busy room, and a client is added
// to the room before its Welcome goes out — so a peer departing at that
// instant can have its Leave forwarded to the new client first. Nothing is
// broken when that happens: core ignores a Leave for a player it
// never knew about. But it made these two tests fail on CI (all three -race
// runs, 2026-08-16) while passing locally, purely on timing.
func awaitWelcome(t *testing.T, tc *testClient) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if env := tc.next(time.Until(deadline)); env.Type == protocol.TypeWelcome {
			return
		}
	}
	t.Fatal("no welcome arrived before the deadline")
}

// waitForGoroutines polls until the count drops to at most want, or the
// deadline passes, and reports the final count. Polling rather than a single
// check because teardown is asynchronous on both sides of a connection —
// the relay notices a hangup, fires its callbacks, and only then does the
// read loop return.
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

// TestNoGoroutineLeakAcrossManyConnections is the load-shaped version: churn
// far more connections than the goroutine tolerance, so a per-connection leak
// cannot hide inside the noise band the way it could with a handful.
func TestNoGoroutineLeakAcrossManyConnections(t *testing.T) {
	srv := NewServer()
	srv.MaxClients = 64
	addr := startServerWith(t, srv)

	// Let the accept loop and any lazily-started runtime goroutines settle
	// before sampling, so the baseline isn't an undercount that turns
	// ordinary startup into a fake leak.
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

	// Tolerance, not equality: the runtime keeps a few goroutines of its own
	// and the last round's teardown may still be in flight. A real
	// per-connection leak would be 160 here, far outside this band.
	const tolerance = 10
	if got := waitForGoroutines(baseline+tolerance, 10*time.Second); got > baseline+tolerance {
		buf := make([]byte, 1<<16)
		n := runtime.Stack(buf, true)
		t.Fatalf("goroutines did not return to baseline after %d connections: baseline=%d got=%d\n%s",
			rounds*perRound, baseline, got, buf[:n])
	}
}

// TestNoSlotLeak covers the other resource a connection holds: one of the
// server's global MaxClients slots. A slot released on some disconnect paths
// but not others would let a relay drift into permanently refusing joins
// while looking healthy — and unlike a goroutine leak, the symptom lands on
// the next player to try to join, not on the host.
func TestNoSlotLeak(t *testing.T) {
	srv := NewServer()
	srv.MaxClients = 4
	addr := startServerWith(t, srv)

	// Churn well past the cap: if a single slot were leaked per connection,
	// the fifth join here would already be refused.
	for i := 0; i < 24; i++ {
		tc := dialTestClient(t, addr, "slotgame", "slotroom", fmt.Sprintf("p%d", i))
		awaitWelcome(t, tc)
		tc.conn.Close()

		// The slot is released when the relay notices the hangup, so give
		// each iteration a moment rather than racing that.
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

// TestRoomIsDroppedEvenWhenItHeldAWorld pins the inverse of world custody's
// "never tie world lifetime to lease lifetime".
//
// A world deliberately outlives its authority lease and the client that wrote
// it, so that a successor can adopt it. The cap that keeps that from being a
// leak (protocol.MaxWorldKeysPerRoom) is only a cap if the ROOM still goes away
// when its last member leaves — otherwise a long-lived relay accumulates one
// pinned room per session that ever used the plane, each holding up to ~58KB,
// and it keeps serving clients perfectly while it does. That is the shape the
// first real relay DoS would take, and no liveness probe can see it.
//
// Deterministic on purpose: this was first written as an assertion inside
// FuzzRelaySurvivesArbitraryPostJoinMessages and does not belong there — see
// that target's own note on why both a per-iteration deadline and a cumulative
// ceiling were unusable. Here it is exact.
func TestRoomIsDroppedEvenWhenItHeldAWorld(t *testing.T) {
	s := NewServer()

	r, _ := worldRoom(t, worldFeatures, "p1")
	r.key = roomKey(r.GameID, r.Name)
	s.mu.Lock()
	s.rooms[r.key] = r
	s.mu.Unlock()

	// A held authority and a populated world: exactly the state that must not
	// pin the room.
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
