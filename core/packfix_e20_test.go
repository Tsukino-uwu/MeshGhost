package core

// Shutting a pack down must not hold the attach path open.
//
// StopChasers and StopReplays run on the bridge's hello goroutine, and both
// joined their members one at a time with a fresh one-second timeout each.
// The chaser count has been uncapped since 2026-09-06, and the pack that
// misses its joins is the starved one -- an adapter that cannot keep up is
// exactly what starves these goroutines -- so the wait scaled with the count
// while the game had been told bridge_ready and nothing since. What the
// player saw: a relaunched game hanging on attach with no error.
//
// Reviewed 2026-09-08. The members here are deliberately goroutine-less, so
// none of them will ever close done: that is the starved case at its limit,
// and it is what makes the total wait observable. A member that HAS finished
// is still joined, which the second half of each subtest pins.

import (
	"sync/atomic"
	"testing"
	"time"
)

// stopJoinBudget is the one-second wall-clock budget both stop paths share.
// A pack of this many starved members took packMembers seconds before the
// fix, so the assertion has room for a slow machine and still fails loudly on
// a per-member wait.
const (
	packMembers   = 4
	stopJoinBound = 2 * time.Second
)

func TestStopChasersJoinsTheWholePackWithinOneBudget(t *testing.T) {
	c := New()
	pack := make([]*chaser, packMembers)
	for i := range pack {
		pack[i] = &chaser{
			c:    c,
			id:   localPeerChaserPrefix + string(rune('1'+i)),
			stop: make(chan struct{}),
			done: make(chan struct{}),
		}
	}
	c.chaserMu.Lock()
	c.chasers = pack
	c.chaserMu.Unlock()

	started := time.Now()
	c.StopChasers()
	if took := time.Since(started); took > stopJoinBound {
		t.Fatalf("StopChasers on %d starved chasers took %v; the whole pack shares one second, so a bigger pack must not cost more", packMembers, took)
	}
	// Halted regardless: a chaser left to exit on its own does so at its next
	// read of ch.stop, and the wait budget must never be what closes it.
	for _, ch := range pack {
		select {
		case <-ch.stop:
		default:
			t.Fatalf("%s was never halted", ch.id)
		}
	}

	// A pack that IS finished is still joined rather than skipped: the budget
	// is shared, not removed.
	done := make([]*chaser, packMembers)
	for i := range done {
		ch := &chaser{c: c, id: localPeerChaserPrefix + string(rune('1'+i)), stop: make(chan struct{}), done: make(chan struct{})}
		close(ch.done)
		done[i] = ch
	}
	c.chaserMu.Lock()
	c.chasers = done
	c.chaserMu.Unlock()
	started = time.Now()
	c.StopChasers()
	if took := time.Since(started); took > 250*time.Millisecond {
		t.Fatalf("StopChasers on %d finished chasers took %v; a closed done channel is an immediate join", packMembers, took)
	}
}

func TestStopReplaysJoinsEveryPlayerWithinOneBudget(t *testing.T) {
	c := New()
	players := make(map[string]*replayPlayer, packMembers)
	for i := 0; i < packMembers; i++ {
		id := localPeerReplayPrefix + string(rune('a'+i)) + ".ndjson"
		p := newReplayPlayer(c, id, &replayClip{})
		// running() without a goroutine: the player is as far behind as a
		// starved one ever gets, and done is never closed.
		atomic.StoreUint32(&p.started, 1)
		players[id] = p
	}
	c.replayMu.Lock()
	c.replays = players
	c.replayMu.Unlock()

	started := time.Now()
	c.StopReplays()
	if took := time.Since(started); took > stopJoinBound {
		t.Fatalf("StopReplays on %d starved players took %v; the whole set shares one second", packMembers, took)
	}
	for id, p := range players {
		if !p.stopped() {
			t.Fatalf("%s was never halted", id)
		}
	}
}
