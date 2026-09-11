package main

// A SOAK THAT LOSES HALF ITS PEERS USED TO EXIT 0.
//
// summarize catches total silence -- a world plane that wrote nothing, a credit
// model that never ratcheted -- because a checker reporting success for a run it
// never started is worse than no checker. It caught nothing in between: peers
// that JOINED and then went away. A run that started with 24 and ended with 11
// printed "no invariant violations", exited 0, and read as a pass, which is the
// same failure one level up (review H18).
//
// What is measured is each client's own view of the room: how many other peers
// it is rendering. The peak is sampled while the run is going, because the end
// state alone cannot distinguish "they never arrived" (a configuration or a
// capacity refusal, which the connect path already reports) from "they arrived
// and were lost" (the thing a soak is FOR).
//
// Deliberately not measured from the relay's introspection: this is what the
// CLIENT can see, which is the same thing a player sees, and a rig that agreed
// with the relay while every client disagreed would be the exact blind spot.

import (
	"fmt"
	"log"
	"sync"
	"time"
)

// peerSampleInterval is how often each client's visible-peer count is read. A
// second is far finer than any despawn this would be catching -- the relay's
// own grace window is measured in seconds -- and costs one mutex read per
// client per second.
const peerSampleInterval = time.Second

type peerWatch struct {
	adapters []*circleAdapter

	mu    sync.Mutex
	peak  []int
	final []int // taken when the run is told to stop -- see run
}

func newPeerWatch(adapters []*circleAdapter) *peerWatch {
	return &peerWatch{adapters: adapters, peak: make([]int, len(adapters))}
}

func (w *peerWatch) run(stop <-chan struct{}) {
	t := time.NewTicker(peerSampleInterval)
	defer t.Stop()
	for {
		select {
		case <-stop:
			// THE FINAL COUNT IS TAKEN HERE, at the moment the run is told to
			// stop, and not after everything has been waited on: during a
			// shutdown every client stops sending at once, so a count read
			// afterwards measures the teardown rather than the run.
			w.sample()
			w.mu.Lock()
			w.final = make([]int, len(w.adapters))
			for i, a := range w.adapters {
				w.final[i] = a.liveCount()
			}
			w.mu.Unlock()
			return
		case <-t.C:
			w.sample()
		}
	}
}

func (w *peerWatch) sample() {
	w.mu.Lock()
	defer w.mu.Unlock()
	for i, a := range w.adapters {
		if n := a.liveCount(); n > w.peak[i] {
			w.peak[i] = n
		}
	}
}

// at reports this client's peak and its count when the run was stopped. ok is
// false if the run never reached the stop signal -- a crash, or a duration so
// short the watcher never ran -- in which case there is nothing to judge.
func (w *peerWatch) at(i int) (peak, final int, ok bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.final == nil {
		return 0, 0, false
	}
	return w.peak[i], w.final[i], true
}

// checkAttrition reports a violation for any client that ended the run seeing
// fewer peers than it saw at its best moment.
//
// It is a violation rather than a warning for the reason the zero-writes check
// is: the run cannot tell you it was pointless, so the rig has to. A peer that
// vanished mid-soak is either a despawn that should not have happened or a
// connection that died, and both are what this program exists to catch.
//
// NOT run offline (nothing can arrive, so nothing can be lost), and not for a
// single client (it has no peers of its own to lose -- a Tier 2 run with one
// synthetic client beside a real game is a legitimate shape, and its peer is
// the game, which stops when the user stops it).
//
// NOT run under churn or multiple areas either, and that is a real limitation
// rather than a tidy exemption: both move clients out of each other's area on
// purpose, so a client legitimately ends a run seeing fewer peers than it saw
// at its peak and there is no way to tell that from a loss at this level. The
// counts are still printed there, so a run that sheds peers under churn is
// visible to a reader even though nothing fails.
func checkAttrition(adapters []*circleAdapter, w *peerWatch, online, expectedToVary bool) {
	if !online || len(adapters) < 2 {
		return
	}
	for i := range adapters {
		peak, final, ok := w.at(i)
		if !ok || final >= peak {
			continue
		}
		if expectedToVary {
			log.Printf("meshghost-fakeadapter: %s (not failed: this run moves clients between "+
				"areas on purpose, so a drop here cannot be told from a loss)",
				attritionMessage(i, peak, final))
			continue
		}
		reportViolation(attritionMessage(i, peak, final))
	}
}

// attritionMessage is separate so a test can assert what a lost peer is
// reported AS -- a message that does not say which client, how many, or what it
// probably means is a verdict nobody can act on.
func attritionMessage(client, peak, final int) string {
	return fmt.Sprintf("client %d ended the run seeing %d peers, having seen %d at its peak -- "+
		"%d peer(s) joined and were lost. A soak that quietly sheds peers and exits 0 is the "+
		"failure this check exists for: look for a despawn with no leave, a relay drop that "+
		"never resumed, or the aged-out roster",
		client, final, peak, peak-final)
}
