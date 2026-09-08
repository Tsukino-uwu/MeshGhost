package main

import "syscall"

// processQueryLimitedInformation is PROCESS_QUERY_LIMITED_INFORMATION, which
// package syscall does not define. It is deliberately narrower than
// PROCESS_QUERY_INFORMATION (which syscall does define): it is enough to read a
// process's exit code, and it is granted across integrity levels where the wider
// right is not -- so watching a game launched with different privileges than this
// client still works. Value from the Win32 process security and access rights
// documentation.
const processQueryLimitedInformation = 0x1000

// stillActive is STILL_ACTIVE, the exit code GetExitCodeProcess reports for a
// process that has not exited yet. Also absent from package syscall.
const stillActive = 259

// parentQueryFailuresBeforeGone is how many CONSECUTIVE failed queries it takes
// before a pid that cannot be asked about is treated as gone.
//
// Two, at parentPollInterval, so four seconds of "cannot ask" -- not two.
// Until 2026-09-08 (review G5) a single failed OpenProcess ended the process:
// the doc comment below reasoned that an error in the lenient direction is the
// expensive one and then took the aggressive one, so any one-off failure at any
// 2s poll -- handle exhaustion under a heavy game, a session or desktop
// boundary, an anti-cheat or EDR hook sitting on OpenProcess -- killed the core
// while the player was holding a controller. What they see is every ghost in
// the room vanishing mid-run, with the console hidden and nothing on screen to
// say why; the fix is to quit and relaunch the game.
//
// Requiring a second failure costs one extra poll on the orphan path this
// mechanism exists for, and only in the case where the game's pid became
// unaskable rather than merely exited -- an exited pid is still openable and is
// answered by its exit code, not by an error.
const parentQueryFailuresBeforeGone = 2

// parentProbe is one raw sample of a pid: whether it looks gone, and whether
// that answer came from the PROCESS (an exit code, a creation time) or from a
// failed query. Separating the two is the whole of the G5 fix -- "it exited" and
// "I could not ask" are different facts and used to return the same bool.
type parentProbe struct {
	gone      bool
	uncertain bool // the query itself failed; gone is a guess, not an answer
	// createdAt is the process's creation time as a FILETIME, 0 when unknown.
	// See parentWatch.seenGone for what it is for.
	createdAt uint64
}

// parentWatch is the state watchParentPID's single goroutine carries between
// polls. One instance backs parentGone; the type exists so a test can drive the
// state machine with a scripted probe instead of a real process to kill.
//
// Not guarded by a mutex, and must not be: watchParentPID runs exactly one
// watcher (main.go's single `go watchParentPID`), and every field here is
// touched only from inside seenGone.
type parentWatch struct {
	failures int
	// created is the parent's creation time from the first poll that could read
	// one. Zero means "not learned yet".
	created uint64
}

// seenGone folds one probe into the watcher's state and answers the question
// watchParentPID actually asks.
//
// PID RECYCLING, the reverse failure and the one this mechanism exists to
// prevent: Windows reuses pids freely, so a crashed game whose pid is handed to
// some later process leaves an orphan core alive indefinitely, holding the
// bridge port -- and the next launch of the game cannot listen, with no window
// anywhere to explain it (watchParentPID's own comment). A pid alone cannot tell
// those apart, but a pid PLUS a creation time can: the pair is unique for as
// long as the process lives. The first successful poll records the creation
// time; any later poll that reads a DIFFERENT one is looking at a stranger
// wearing the parent's number, and that is gone.
//
// What this does NOT close, stated plainly: the baseline is learned at the first
// poll, not at launch, so a parent that dies and has its pid recycled inside the
// first parentPollInterval is adopted as if it had always been the parent. The
// clean fix is for the spawning adapter to hand over the creation time it
// already holds, which is a bridge/contract change and is not this review item.
// Rarity is not the argument -- the argument is that the residual window is 2
// seconds wide instead of the whole session.
func (w *parentWatch) seenGone(p parentProbe) bool {
	if p.uncertain {
		w.failures++
		return w.failures >= parentQueryFailuresBeforeGone
	}
	w.failures = 0
	if p.gone {
		return true
	}
	if p.createdAt != 0 {
		if w.created == 0 {
			w.created = p.createdAt
			return false
		}
		if w.created != p.createdAt {
			return true
		}
	}
	return false
}

// probeParent takes one sample of a pid.
//
// "Gone" deliberately means GONE, not "exited but a handle is still open": a
// process that has exited still has a valid handle until every holder closes it,
// and OpenProcess on it succeeds. Asking for its exit code is what distinguishes
// the two -- STILL_ACTIVE means running, anything else means it finished. An
// error in the lenient direction is the expensive one here: the client would
// decide the game is gone while the player is still holding a controller.
//
// A failed query is reported as UNCERTAIN rather than as gone, and the caller
// decides. A pid we can never open is still a pid we cannot watch, and treating
// it as alive forever is exactly the invisible orphan this mechanism exists to
// prevent -- so repeated failures still end the process; see
// parentQueryFailuresBeforeGone.
//
// GetProcessTimes is asked for alongside the exit code because
// PROCESS_QUERY_LIMITED_INFORMATION already grants it: the creation time costs
// one more call on a handle that is open anyway and is what makes a recycled pid
// visible (seenGone). A failure to read it is not uncertainty -- the exit code
// answered the question -- so it degrades to createdAt 0 and the recycling check
// simply does not run that poll.
func probeParent(pid int) parentProbe {
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return parentProbe{gone: true, uncertain: true}
	}
	defer syscall.CloseHandle(h)

	var code uint32
	if err := syscall.GetExitCodeProcess(h, &code); err != nil {
		return parentProbe{gone: true, uncertain: true}
	}
	if code != stillActive {
		return parentProbe{gone: true}
	}

	var creation, exit, kernel, user syscall.Filetime
	if err := syscall.GetProcessTimes(h, &creation, &exit, &kernel, &user); err != nil {
		return parentProbe{}
	}
	return parentProbe{createdAt: uint64(creation.HighDateTime)<<32 | uint64(creation.LowDateTime)}
}

// theParentWatch is the state parentGone carries between calls. Package-level
// because watchParentPID takes a plain func(int) bool and there is exactly one
// watcher per process; tests use their own parentWatch rather than this one.
var theParentWatch parentWatch

// parentGone reports whether the process with this pid has exited, been replaced
// by a pid-recycled stranger, or gone unaskable twice running. See
// watchParentPID for why the client watches a pid at all, and parent_unix.go for
// the other half of this seam.
func parentGone(pid int) bool {
	return theParentWatch.seenGone(probeParent(pid))
}
