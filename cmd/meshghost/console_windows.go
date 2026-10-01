package main

import (
	"io"
	"os"
	"syscall"
)

// runningUnderWine reports whether this is a Windows binary running on Wine (Proton, CrossOver) rather than on
// Windows. Wine's ntdll exports wine_get_version and Windows has no equivalent, the check the Wine FAQ gives under
// "How can I detect Wine?". It only decides what the client says about show_console, so a false negative is harmless.
func runningUnderWine() bool {
	ntdll, err := syscall.LoadLibrary("ntdll.dll")
	if err != nil {
		return false
	}
	defer syscall.FreeLibrary(ntdll)
	_, err = syscall.GetProcAddress(ntdll, "wine_get_version")
	return err == nil
}

// consoleWriter gives this process a console window and returns a writer to it, or nil if it couldn't get one. An
// autostarted client is spawned with CREATE_NO_WINDOW and has no console, so nothing flashes; show_console allocates
// one afterwards. AllocConsole fails when a console already exists (a terminal), and then stderr is that console.
func consoleWriter() io.Writer {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	if r, _, _ := kernel32.NewProc("AllocConsole").Call(); r == 0 {
		return nil
	}
	// CONOUT$ is the new console whatever the inherited, invalid, standard handles point at; os.Stdout writes nowhere.
	f, err := os.OpenFile("CONOUT$", os.O_WRONLY, 0)
	if err != nil {
		return nil
	}
	return f
}
