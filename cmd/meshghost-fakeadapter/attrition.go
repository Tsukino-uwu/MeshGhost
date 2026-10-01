package main

import (
	"fmt"
	"log"
	"sync"
	"time"
)

// peerSampleInterval is far finer than any despawn it would catch, at one mutex read per client per sample.
const peerSampleInterval = time.Second

// peerWatch samples how many peers each client renders, as a player would see them rather than as the relay counts
// them. The peak is sampled during the run because the end state alone cannot tell "never arrived" from "arrived and
// were lost".
type peerWatch struct {
	adapters []*circleAdapter

	mu    sync.Mutex
	peak  []int
	final []int
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
			// Counted at the stop signal: during shutdown every client stops sending at once, so a later count
			// measures the teardown rather than the run.
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

// at reports this client's peak and its count when the run was stopped; ok is false if the run never reached the
// stop signal.
func (w *peerWatch) at(i int) (peak, final int, ok bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.final == nil {
		return 0, 0, false
	}
	return w.peak[i], w.final[i], true
}

// checkAttrition reports a violation for any client that ended the run seeing fewer peers than at its peak: a peer
// that vanished mid-soak is a wrong despawn or a dead connection. It skips offline runs and a lone client (whose
// peer may be a real game a player closes). Churn and several areas move clients apart on purpose, so there a drop
// cannot be told from a loss and is only logged.
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

// attritionMessage is separate so a test can assert it names the client, how many were lost and where to look.
func attritionMessage(client, peak, final int) string {
	return fmt.Sprintf("client %d ended the run seeing %d peers, having seen %d at its peak -- "+
		"%d peer(s) joined and were lost. A soak that quietly sheds peers and exits 0 is the "+
		"failure this check exists for: look for a despawn with no leave, a relay drop that "+
		"never resumed, or the aged-out roster",
		client, final, peak, peak-final)
}
