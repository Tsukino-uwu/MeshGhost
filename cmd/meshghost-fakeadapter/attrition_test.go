package main

import (
	"strings"
	"testing"
)

// fakeLive gives an adapter a peer count without a relay, by filling the map liveCount reads.
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

func TestLosingPeersFailsTheRun(t *testing.T) {
	a, b := fakeLive(3), fakeLive(3)
	w := newPeerWatch([]*circleAdapter{a, b})
	w.sample()

	a.setLive(1)
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

// TestChurnIsReportedRatherThanFailed: churn and -areas both end with clients legitimately out of each other's view.
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

func TestTheAttritionMessageSaysWhatToLookFor(t *testing.T) {
	msg := attritionMessage(2, 7, 3)
	for _, want := range []string{"client 2", "3 peers", "7 at its peak", "4 peer(s)"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("the message does not contain %q:\n%s", want, msg)
		}
	}
}
