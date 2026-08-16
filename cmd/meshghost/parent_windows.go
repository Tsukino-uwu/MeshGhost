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

// parentGone reports whether the process with this pid has exited (or was never
// ours to see). See watchParentPID for why the client watches a pid at all.
//
// "Gone" deliberately means GONE, not "exited but a handle is still open": a
// process that has exited still has a valid handle until every holder closes it,
// and OpenProcess on it succeeds. Asking for its exit code is what distinguishes
// the two -- STILL_ACTIVE means running, anything else means it finished. An
// error in the lenient direction is the expensive one here: the client would
// decide the game is gone while the player is still holding a controller.
//
// A failed OpenProcess is reported as gone. A pid we cannot open is a pid we
// cannot watch, and the alternative -- treating it as alive forever -- is exactly
// the invisible orphan process this mechanism exists to prevent.
func parentGone(pid int) bool {
	h, err := syscall.OpenProcess(processQueryLimitedInformation, false, uint32(pid))
	if err != nil {
		return true
	}
	defer syscall.CloseHandle(h)

	var code uint32
	if err := syscall.GetExitCodeProcess(h, &code); err != nil {
		return true
	}
	return code != stillActive
}
