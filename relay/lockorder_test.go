package relay

// F15 of the 2026-09-08 review. introspect.go's Snapshot states that nothing in
// this package locks a room while still holding Server.mu, and goes out of its
// way not to be the first thing that does -- so that a future r.mu-then-s.mu
// path stays a free choice rather than a deadlock. dropIfEmpty contradicted it:
// it took s.mu and then called r.size(), which takes r.mu. Latent, not live,
// and a stated invariant nobody enforces is how the next reader gets it wrong.

import (
	"testing"
	"time"
)

// TestDropIfEmptyDoesNotTakeARoomLockWhileHoldingTheServerLock holds r.mu and
// asks dropIfEmpty to run: it must finish anyway. Failing this means s.mu and
// r.mu are nested again, which is a deadlock the moment anything takes them the
// other way round.
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

// TestTheMemberCountDropIfEmptyReadsTracksTheRoster is the other half: the
// lock-free count is only worth reading if it equals len(members) at every
// point a member joins, is replaced by a resume, or leaves. A count that drifts
// high leaks a room table entry for the life of the server; one that drifts low
// sweeps a room with players still in it, and they go on talking to a room
// nobody else can reach.
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

	// A resume swaps a fresh Client onto an existing id: the map's size does
	// not move and neither may the count.
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
