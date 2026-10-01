package main

import "syscall"

// processQueryLimitedInformation is PROCESS_QUERY_LIMITED_INFORMATION, which package syscall does not define. It
// is enough to read an exit code and, unlike PROCESS_QUERY_INFORMATION, is granted across integrity levels, so a game
// launched with different privileges can still be watched. Value from the Win32 process security and access rights
// documentation.
const processQueryLimitedInformation = 0x1000

// stillActive is STILL_ACTIVE, the exit code GetExitCodeProcess reports for a process that has not exited; package
// syscall lacks it too.
const stillActive = 259

// parentQueryFailuresBeforeGone is how many consecutive failed queries make a pid that cannot be asked about count as
// gone. One transient failure (handle exhaustion, a session boundary, an anti-cheat hook on OpenProcess) must not end
// the core and every ghost with it; an exited pid is answered by its exit code, so the orphan path is not slowed.
const parentQueryFailuresBeforeGone = 2

// parentProbe is one sample of a pid: whether it looks gone, and whether that answer came from the process or from a
// failed query, because "it exited" and "I could not ask" are different facts.
type parentProbe struct {
	gone      bool
	uncertain bool // the query itself failed; gone is a guess, not an answer
	// createdAt is the process's creation time as a FILETIME, 0 when unknown.
	createdAt uint64
}

// parentWatch is the state watchParentPID's single goroutine carries between polls, a type so a test can drive it
// with scripted probes. No mutex: there is one watcher, and only seenGone touches the fields.
type parentWatch struct {
	failures int
	// created is the parent's creation time from the first poll that read one, 0 until then.
	created uint64
}

// seenGone folds one probe into the watcher's state and reports whether the parent is gone. Windows reuses pids, and
// a crashed game's pid handed to a later process would keep an orphan core holding the bridge port; a pid plus its
// creation time is unique while the process lives, so a different creation time is a stranger and the parent is gone.
//
// The baseline is learned at the first poll, not at launch, so a pid recycled within the first parentPollInterval is
// still adopted; closing that needs the spawning adapter to hand over the creation time, a bridge contract change.
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

// probeParent takes one sample of a pid. An exited process can still be opened while any handle to it is held, so
// the exit code decides: STILL_ACTIVE means running. A failed query is reported as uncertain and the caller decides.
// A failed GetProcessTimes is not uncertainty, since the exit code answered; createdAt stays 0 and the recycling
// check skips that poll.
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

// theParentWatch is package-level because watchParentPID takes a plain func(int) bool and there is one watcher per
// process; tests use their own parentWatch.
var theParentWatch parentWatch

// parentGone reports whether the process with this pid has exited, been replaced by a pid-recycled stranger, or gone
// unaskable twice running.
func parentGone(pid int) bool {
	return theParentWatch.seenGone(probeParent(pid))
}
