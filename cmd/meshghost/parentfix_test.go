//go:build windows

// Windows-only because parentWatch, parentProbe and the whole
// consecutive-failure rule live in parent_windows.go: the failure they answer --
// a transiently unaskable process handle, and a recycled pid -- is a Windows
// shape, and parent_unix.go says why it has neither. The build tag is what keeps
// this compiling on Linux CI: the file is excluded there rather than referring to
// identifiers that do not exist. `GOOS=windows go vet ./cmd/meshghost/` is what
// compiles it from a Linux box.

package main

import "testing"

// alive is a probe of a process that answered: running, same process as before.
func alive(created uint64) parentProbe { return parentProbe{createdAt: created} }

// unaskable is a probe whose QUERY failed -- OpenProcess or GetExitCodeProcess
// returned an error. Shaped exactly as probeParent builds it.
func unaskable() parentProbe { return parentProbe{gone: true, uncertain: true} }

// TestOneTransientProcessQueryDoesNotKillTheCore is review G5 (2026-09-08).
//
// A single failed OpenProcess used to end the process. Handle exhaustion under
// a heavy game, a session or desktop boundary, or an anti-cheat hook sitting on
// OpenProcess made every 2s poll a coin flip on the player's session: the core
// exits, every ghost in the room vanishes mid-run, and the console it would have
// said so in ships hidden.
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
	// And the counter reset: a failure two polls after a recovered one is not
	// the second of a pair.
	if w.seenGone(unaskable()) {
		t.Fatal("a failure after a successful poll counted as consecutive")
	}
}

// TestTwoConsecutiveFailedQueriesStillReapTheOrphan is the other half: leniency
// must not become "alive forever". A pid that cannot be asked about twice
// running is a pid this core cannot watch, and an unwatched core with no console
// holds the bridge port so the next launch of the game cannot listen.
func TestTwoConsecutiveFailedQueriesStillReapTheOrphan(t *testing.T) {
	var w parentWatch
	if w.seenGone(unaskable()) {
		t.Fatal("the first failed query should not be acted on")
	}
	if !w.seenGone(unaskable()) {
		t.Fatalf("%d consecutive failed queries did not reap the core; parentQueryFailuresBeforeGone is %d", 2, parentQueryFailuresBeforeGone)
	}
}

// TestAnExitedParentIsGoneOnTheFirstPoll: an exit code is an ANSWER, not a
// failed query, so it is never subject to the two-poll rule. The orphan path
// this whole mechanism exists for is not slowed down by the G5 fix.
func TestAnExitedParentIsGoneOnTheFirstPoll(t *testing.T) {
	var w parentWatch
	if !w.seenGone(parentProbe{gone: true}) {
		t.Fatal("a parent that reported an exit code was not treated as gone")
	}
}

// TestARecycledParentPidDoesNotKeepAnOrphanAlive is the reverse direction G5
// names and the one that was wholly unhandled: Windows reuses pids, so a crashed
// game whose number is handed to some later process left the core alive for the
// rest of the session holding the bridge port -- and the next launch of the game
// could not listen, with no window anywhere to explain it.
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

// TestAnUnreadableCreationTimeIsNotTakenAsRecycling: GetProcessTimes failing
// leaves createdAt 0, and a zero must never be compared against the baseline --
// that would read as "the parent changed" and kill a running session on a
// missing optional field.
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
