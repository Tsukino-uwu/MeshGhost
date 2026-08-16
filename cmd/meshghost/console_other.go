//go:build !windows

package main

import "io"

// consoleWriter is a no-op off Windows: there is no console to allocate, and a
// process started from a terminal already has one. show_console is accepted and
// ignored rather than rejected, so the same config.json works on every platform
// (and so a Windows user's file doesn't fail on a native Linux client). See
// console_windows.go for what it does where it means something.
func consoleWriter() io.Writer { return nil }

// runningUnderWine is always false off Windows: a native Linux or macOS build
// is not a Windows binary being emulated, it just IS the platform. The Wine
// question only exists for the .exe running inside a Proton prefix.
func runningUnderWine() bool { return false }
