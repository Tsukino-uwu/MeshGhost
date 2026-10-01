//go:build windows

// Windows-only, like parentWatch and parentProbe; `GOOS=windows go vet ./cmd/meshghost/` compiles it from Linux.

package main

import "testing"

// alive is a probe of a process that answered: running, same process as before.
func alive(created uint64) parentProbe { return parentProbe{createdAt: created} }

// unaskable is a probe whose query failed, shaped exactly as probeParent builds it.
func unaskable() parentProbe { return parentProbe{gone: true, uncertain: true} }

// TestOneTransientProcessQueryDoesNotKillTheCore: one failed query must not end the core, and a failure after a
// recovered poll does not count as the second of a pair.
func TestOneTransientProcessQueryDoesNotKillTheCore(t *testing.T) {
	var w parentWatch
	if w.seenGone(alive(1000)) {
		t.Fatal("a running parent read as gone on the first poll")
	}
	if w.seenGone(unaskable()) {
		t.Fatal("ONE failed process query ended the core -- the G5 regression: the player is still holding a controller")
	}
	if w.seenGone(alive(1000)) {
		t.Fatal("the parent answered again and was still called gone")
	}
	if w.seenGone(unaskable()) {
		t.Fatal("a failure after a successful poll counted as consecutive")
	}
}

// TestTwoConsecutiveFailedQueriesStillReapTheOrphan: leniency must not become alive forever, or an unwatched core
// holds the bridge port and the game's next launch cannot listen.
func TestTwoConsecutiveFailedQueriesStillReapTheOrphan(t *testing.T) {
	var w parentWatch
	if w.seenGone(unaskable()) {
		t.Fatal("the first failed query should not be acted on")
	}
	if !w.seenGone(unaskable()) {
		t.Fatalf("%d consecutive failed queries did not reap the core; parentQueryFailuresBeforeGone is %d", 2, parentQueryFailuresBeforeGone)
	}
}

// TestAnExitedParentIsGoneOnTheFirstPoll: an exit code is an answer, not a failed query, so the two-poll rule does
// not apply.
func TestAnExitedParentIsGoneOnTheFirstPoll(t *testing.T) {
	var w parentWatch
	if !w.seenGone(parentProbe{gone: true}) {
		t.Fatal("a parent that reported an exit code was not treated as gone")
	}
}

// TestARecycledParentPidDoesNotKeepAnOrphanAlive: a live pid with a different creation time is a later process
// wearing the parent's number, so the parent is gone.
func TestARecycledParentPidDoesNotKeepAnOrphanAlive(t *testing.T) {
	var w parentWatch
	if w.seenGone(alive(0x1234_5678)) {
		t.Fatal("the first poll of a live parent read as gone")
	}
	if w.seenGone(alive(0x1234_5678)) {
		t.Fatal("the same process, unchanged, read as gone on the second poll")
	}
	if !w.seenGone(alive(0x9999_0000)) {
		t.Fatal("the pid is alive but is a DIFFERENT process than the parent -- a recycled pid kept the orphan alive")
	}
}

// TestAnUnreadableCreationTimeIsNotTakenAsRecycling: a failed GetProcessTimes leaves createdAt 0, which must never be
// compared against the baseline and read as a changed parent.
func TestAnUnreadableCreationTimeIsNotTakenAsRecycling(t *testing.T) {
	var w parentWatch
	w.seenGone(alive(4242))
	if w.seenGone(parentProbe{}) {
		t.Fatal("a poll with no readable creation time was treated as a recycled pid")
	}
	if w.seenGone(alive(4242)) {
		t.Fatal("the baseline was lost after a poll with no creation time")
	}
}
