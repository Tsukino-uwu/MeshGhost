package core

// StopChasers and StopReplays run on the bridge's hello goroutine, so a pack shares one join budget rather than one
// per member. The members here have no goroutine and never close done: the starved case at its limit.

import (
	"sync/atomic"
	"testing"
	"time"
)

// stopJoinBound leaves a slow machine room over the shared one-second budget, while a per-member wait takes
// packMembers seconds.
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
	// Halted whatever the budget did: a straggler exits at its next read of ch.stop.
	for _, ch := range pack {
		select {
		case <-ch.stop:
		default:
			t.Fatalf("%s was never halted", ch.id)
		}
	}

	// A finished pack is still joined rather than skipped: the budget is shared, not removed.
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
		// running() without a goroutine, as far behind as a starved player gets: done is never closed.
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
