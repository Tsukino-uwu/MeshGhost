package main

import (
	"strings"
	"testing"
)

// fakeLive gives an adapter a peer count without a relay: circleAdapter.live is
// what liveCount reads, and these tests are about the WATCHER, not about how a
// peer gets into that map.
func fakeLive(n int) *circleAdapter {
	a := &circleAdapter{live: map[string]bool{}}
	for i := 0; i < n; i++ {
		a.live[string(rune('a'+i))] = true
	}
	return a
}

func (a *circleAdapter) setLive(n int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.live = map[string]bool{}
	for i := 0; i < n; i++ {
		a.live[string(rune('a'+i))] = true
	}
}

// A RUN THAT SHEDS PEERS MUST FAIL. Before this check, a soak that started with
// every client seeing its siblings and ended with half of them gone printed "no
// invariant violations" and exited 0 -- summarize catches a plane that did
// NOTHING, and caught nothing in between.
func TestLosingPeersFailsTheRun(t *testing.T) {
	a, b := fakeLive(3), fakeLive(3)
	w := newPeerWatch([]*circleAdapter{a, b})
	w.sample() // the peak: both see three

	a.setLive(1) // two of a's peers went away
	stop := make(chan struct{})
	close(stop)
	w.run(stop) // records the final counts

	before := violations.Load()
	checkAttrition([]*circleAdapter{a, b}, w, true, false)
	if violations.Load() == before {
		t.Fatal("a client that lost two of its three peers did not fail the run -- this is the " +
			"soak that quietly sheds peers and exits 0")
	}
}

// AND A HEALTHY RUN MUST NOT. A check that cries wolf on a clean soak gets
// ignored, which costs the run it exists for.
func TestAStableRunReportsNoAttrition(t *testing.T) {
	a, b := fakeLive(2), fakeLive(2)
	w := newPeerWatch([]*circleAdapter{a, b})
	w.sample()
	stop := make(chan struct{})
	close(stop)
	w.run(stop)

	before := violations.Load()
	checkAttrition([]*circleAdapter{a, b}, w, true, false)
	if violations.Load() != before {
		t.Fatal("a run where nobody lost a peer was reported as attrition")
	}
}

// A RUN THAT MOVES CLIENTS BETWEEN AREAS ON PURPOSE CANNOT BE JUDGED THIS WAY,
// so it is reported and not failed -- churn and -areas both end with clients
// legitimately out of each other's view.
func TestChurnIsReportedRatherThanFailed(t *testing.T) {
	a, b := fakeLive(3), fakeLive(3)
	w := newPeerWatch([]*circleAdapter{a, b})
	w.sample()
	a.setLive(0)
	stop := make(chan struct{})
	close(stop)
	w.run(stop)

	before := violations.Load()
	checkAttrition([]*circleAdapter{a, b}, w, true, true)
	if violations.Load() != before {
		t.Fatal("a churn run was failed for a peer count that churn moves on purpose")
	}
}

// NOTHING IS JUDGED OFFLINE OR WITH ONE CLIENT: nothing can arrive, so nothing
// can be lost, and a single synthetic client beside a real game is a legitimate
// shape whose only peer stops when the user stops it.
func TestOfflineAndSoloRunsAreNotJudged(t *testing.T) {
	a := fakeLive(3)
	w := newPeerWatch([]*circleAdapter{a})
	w.sample()
	a.setLive(0)
	stop := make(chan struct{})
	close(stop)
	w.run(stop)

	before := violations.Load()
	checkAttrition([]*circleAdapter{a}, w, true, false)  // one client
	checkAttrition([]*circleAdapter{a}, w, false, false) // offline
	if violations.Load() != before {
		t.Fatal("an offline or single-client run was judged for attrition")
	}
}

// THE MESSAGE HAS TO BE ACTIONABLE: which client, how many were lost, and where
// to look. A verdict nobody can act on is a verdict nobody reads.
func TestTheAttritionMessageSaysWhatToLookFor(t *testing.T) {
	msg := attritionMessage(2, 7, 3)
	for _, want := range []string{"client 2", "3 peers", "7 at its peak", "4 peer(s)"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("the message does not contain %q:\n%s", want, msg)
		}
	}
}
