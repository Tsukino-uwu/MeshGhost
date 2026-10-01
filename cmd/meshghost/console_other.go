//go:build !windows

package main

import "io"

// consoleWriter is a no-op off Windows, where a process started from a terminal already has a console. show_console
// is accepted and ignored so one config.json works on every platform.
func consoleWriter() io.Writer { return nil }

// runningUnderWine is always false off Windows: a native build is not a Windows binary under Wine.
func runningUnderWine() bool { return false }
