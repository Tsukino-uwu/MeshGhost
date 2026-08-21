package main

import (
	"io"
	"os"
	"syscall"
)

// consoleWriter gives this process a real console window and returns a writer to
// it, or nil if it couldn't get one.
//
// It exists because autostart hides the client on purpose: an adapter spawns it
// with CREATE_NO_WINDOW, which means no console is ever created and there is no
// window to flash. That is the right default -- the whole point is that MeshGhost
// feels like part of starting the game rather than a third thing to run -- but
// "is it actually running?" is a fair question on a first install, and the answer
// should not have to be "open a log file". show_console in config.json opts back
// in.
//
// Allocating a console after the fact, rather than never hiding one, is what
// keeps the default flash-free: a process spawned with CREATE_NO_WINDOW has no
// console to hide, so there is no window that briefly appears and vanishes.
//
// AllocConsole fails when the process already has one (a developer running this
// from a terminal, or a double-click). That is not an error worth reporting: the
// caller already writes to stderr, which in that case is the existing console.
// runningUnderWine reports whether this process is a Windows binary running on
// Wine (so: Proton on Linux, or CrossOver/Wine on macOS) rather than on real
// Windows.
//
// Detected by resolving wine_get_version in ntdll, which Wine's own ntdll
// exports and real Windows has no equivalent of. This is the documented
// documented way to ask, not a guess -- see the Wine FAQ's "How can I detect
// Wine?" entry and dlls/ntdll/version.c in Wine's source.
//
// Used only to decide whether the console defaults to visible; nothing about
// how MeshGhost behaves on the wire depends on the answer. A false negative
// (some future Wine that stops exporting it) just means the old default, which
// is why this needs no fallback probe.
func runningUnderWine() bool {
	ntdll, err := syscall.LoadLibrary("ntdll.dll")
	if err != nil {
		return false
	}
	defer syscall.FreeLibrary(ntdll)
	_, err = syscall.GetProcAddress(ntdll, "wine_get_version")
	return err == nil
}

func consoleWriter() io.Writer {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	if r, _, _ := kernel32.NewProc("AllocConsole").Call(); r == 0 {
		return nil
	}
	// CONOUT$ addresses the console we just allocated regardless of what the
	// inherited (and here, invalid) standard handles point at -- opening
	// os.Stdout would write nowhere.
	f, err := os.OpenFile("CONOUT$", os.O_WRONLY, 0)
	if err != nil {
		return nil
	}
	return f
}
