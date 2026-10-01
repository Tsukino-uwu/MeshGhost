package relay

import (
	"testing"
	"time"
)

// TestDropIfEmptyDoesNotTakeARoomLockWhileHoldingTheServerLock holds r.mu while dropIfEmpty runs. Nothing may lock
// a room while holding Server.mu, so that a path taking them the other way round stays free of deadlock.
func TestDropIfEmptyDoesNotTakeARoomLockWhileHoldingTheServerLock(t *testing.T) {
	s := NewServer()
	r := newRoom("emerald", "", "room1", nil)
	s.rooms[r.key] = r

	r.mu.Lock()
	done := make(chan struct{})
	go func() {
		s.dropIfEmpty(r)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(timeout):
		r.mu.Unlock()
		t.Fatal("dropIfEmpty blocked on the room lock while holding the server lock -- " +
			"that is the s.mu-then-r.mu nesting introspect.go's Snapshot says does not exist")
	}
	r.mu.Unlock()

	s.mu.Lock()
	_, still := s.rooms[r.key]
	s.mu.Unlock()
	if still {
		t.Fatal("the empty room was not swept")
	}
}

// TestTheMemberCountDropIfEmptyReadsTracksTheRoster: a lock-free count that drifts high leaks a room table entry; one
// that drifts low sweeps a room with players still in it.
func TestTheMemberCountDropIfEmptyReadsTracksTheRoster(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	check := func(when string) {
		t.Helper()
		r.mu.Lock()
		n := len(r.members)
		r.mu.Unlock()
		if got := r.memberCount.Load(); got != int64(n) {
			t.Fatalf("%s: memberCount = %d, roster holds %d", when, got, n)
		}
	}

	r.tryAdd(&Client{PlayerID: "p1", Conn: &recordingTransport{}})
	r.tryAdd(&Client{PlayerID: "p2", Conn: &recordingTransport{}})
	check("after two joins")

	// A resume swaps a fresh Client onto an existing id, so the count must not move.
	r.mu.Lock()
	r.putMemberLocked(&Client{PlayerID: "p1", Conn: &recordingTransport{}})
	r.mu.Unlock()
	check("after a resume replaced p1")

	r.remove("p1")
	check("after one leave")
	// A leave for someone who already left must not decrement twice.
	r.remove("p1")
	check("after a repeated leave")
	r.remove("p2")
	check("after the room emptied")
	if r.memberCount.Load() != 0 {
		t.Fatalf("the emptied room counts %d members, so dropIfEmpty would never sweep it",
			r.memberCount.Load())
	}
}
