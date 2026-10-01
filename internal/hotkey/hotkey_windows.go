//go:build windows

package hotkey

// The Windows half, per Microsoft's page for each call. RegisterHotKey with a NULL window posts WM_HOTKEY (wParam is
// the id) to the calling thread's queue, and UnregisterHotKey frees only what the calling thread registered, so
// register, loop and unregister share one locked OS thread. GetMessageW returns -1 on error. PostThreadMessageW needs
// the thread's queue to exist, hence PeekMessage first; the stop message is WM_APP+1, since WM_QUIT must not be posted
// from outside.

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
