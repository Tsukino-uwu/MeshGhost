//go:build !windows

package main

import (
	"errors"
	"syscall"
)

// parentGone reports whether the process with this pid has exited. Signal 0 checks existence without delivering
// anything: ESRCH means gone, and EPERM means the process exists under another user, so it is alive. A native client
// beside a game under Proton cannot be spawned or killed by the Windows mod, so it watches a pid on its own terms.
//
// Unlike the Windows half there is no consecutive-failure rule or creation-time check: kill(pid, 0) has no handle to
// exhaust and no hook in the way, and POSIX pids climb to a large maximum before wrapping rather than being reissued.
func parentGone(pid int) bool {
	err := syscall.Kill(pid, 0)
	if err == nil {
		return false
	}
	return !errors.Is(err, syscall.EPERM)
}
