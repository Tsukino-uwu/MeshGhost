//go:build !windows

package main

import (
	"errors"
	"syscall"
)

// parentGone reports whether the process with this pid has exited. See
// watchParentPID for why the client watches a pid at all, and parent_windows.go
// for the other half of this seam.
//
// Signal 0 is the portable POSIX existence check: it performs the permission and
// existence checks without delivering anything. ESRCH means no such process --
// gone. EPERM means the process exists but belongs to someone else, which is
// still an answer: it is alive, so the client keeps running.
//
// This matters beyond the Windows-game case: MeshGhost's client and server are
// meant to build for Linux and macOS (README.md), and the Linux story for a
// Windows game under Proton includes a NATIVE client that a Windows mod inside
// the prefix can never spawn or kill -- so the native binary has to be able to
// watch a pid on its own terms.
func parentGone(pid int) bool {
	err := syscall.Kill(pid, 0)
	if err == nil {
		return false
	}
	return !errors.Is(err, syscall.EPERM)
}
