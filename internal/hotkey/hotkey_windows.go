//go:build windows

package hotkey

// The Windows half: RegisterHotKey with a NULL window, a GetMessageW loop on
// the registering thread, UnregisterHotKey on the way out. Every call and
// constant is from learn.microsoft.com, read 2026-09-03 (ADR 0048):
//
//   - RegisterHotKey: hWnd NULL posts WM_HOTKEY to the CALLING THREAD's queue,
//     "and must be processed in the message loop"; ids 0x0000-0xBFFF; fails
//     if another application already registered the chord.
//   - UnregisterHotKey: frees a hot key "previously registered by the calling
//     thread" -- so register, loop and unregister all run on one OS thread,
//     which runtime.LockOSThread guarantees for this goroutine.
//   - GetMessageW: -1 on error, 0 on WM_QUIT, nonzero otherwise; the loop
//     checks -1 explicitly, as the page insists.
//   - WM_HOTKEY (0x0312): wParam is the hotkey id.
//   - PostThreadMessageW: fails unless the thread has a message queue, which
//     the system creates on the thread's first User call; the page's own
//     recipe is PeekMessage(PM_NOREMOVE) first, then signal ready. The stop
//     message is WM_APP+1 (0x8001): the WM_QUIT page says not to post WM_QUIT
//     from outside, and WM_APP through 0xBFFF is the range "available for
//     use by applications" (the WM_USER page).
//   - MSG: hwnd, message, wParam, lParam, time, POINT pt, DWORD lPrivate.

import (
	"errors"
	"fmt"
	"runtime"
	"syscall"
	"unsafe"
)

const (
	wmHotkey   = 0x0312
	wmApp      = 0x8000
	wmStop     = wmApp + 1
	pmNoRemove = 0x0000
)

// msg mirrors the MSG structure (winuser.h).
type msg struct {
	hwnd     uintptr
	message  uint32
	wParam   uintptr
	lParam   uintptr
	time     uint32
	pt       struct{ x, y int32 }
	lPrivate uint32
}

var (
	user32                = syscall.NewLazyDLL("user32.dll")
	kernel32              = syscall.NewLazyDLL("kernel32.dll")
	procRegisterHotKey    = user32.NewProc("RegisterHotKey")
	procUnregisterHotKey  = user32.NewProc("UnregisterHotKey")
	procGetMessageW       = user32.NewProc("GetMessageW")
	procPeekMessageW      = user32.NewProc("PeekMessageW")
	procPostThreadMessage = user32.NewProc("PostThreadMessageW")
	procGetCurrentThread  = kernel32.NewProc("GetCurrentThreadId")
)

func run(actions []Action, fire func(name string), report func(Result), stop <-chan struct{}) error {
	if len(actions) == 0 {
		<-stop
		return nil
	}
	if err := procRegisterHotKey.Find(); err != nil {
		return fmt.Errorf("hotkeys unavailable: %w", err)
	}

	ready := make(chan uint32, 1)
	done := make(chan error, 1)
	go func() {
		// Everything below happens on ONE OS thread: RegisterHotKey binds
		// the chord to the calling thread's queue and UnregisterHotKey only
		// frees what the calling thread registered.
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()

		// Force the queue into existence before anyone can post to it.
		var m msg
		procPeekMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, wmApp, wmApp, pmNoRemove)
		tid, _, _ := procGetCurrentThread.Call()

		registered := make([]int, 0, len(actions))
		for i, a := range actions {
			id := i + 1 // 0x0001.. is inside the application range
			r, _, callErr := procRegisterHotKey.Call(0, uintptr(id), uintptr(a.Binding.Mods|ModNoRepeat), uintptr(a.Binding.VK))
			res := Result{Name: a.Name, Binding: a.Binding}
			if r == 0 {
				res.Err = fmt.Errorf("RegisterHotKey failed (another program may already own this chord): %v", callErr)
			} else {
				registered = append(registered, id)
			}
			if report != nil {
				report(res)
			}
		}
		ready <- uint32(tid)

		var loopErr error
		for {
			r, _, callErr := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
			if int32(r) == -1 {
				loopErr = fmt.Errorf("GetMessageW: %v", callErr)
				break
			}
			if r == 0 || m.message == wmStop {
				break
			}
			if m.message == wmHotkey {
				idx := int(m.wParam) - 1
				if idx >= 0 && idx < len(actions) {
					fire(actions[idx].Name)
				}
			}
		}
		for _, id := range registered {
			procUnregisterHotKey.Call(0, uintptr(id))
		}
		done <- loopErr
	}()

	tid := <-ready
	select {
	case <-stop:
		if r, _, callErr := procPostThreadMessage.Call(uintptr(tid), wmStop, 0, 0); r == 0 {
			return errors.Join(fmt.Errorf("PostThreadMessageW: %v", callErr), <-done)
		}
		return <-done
	case err := <-done:
		return err
	}
}
