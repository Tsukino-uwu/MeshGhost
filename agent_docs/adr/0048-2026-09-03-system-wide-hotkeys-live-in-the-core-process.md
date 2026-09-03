# 2026-09-03 — System-wide hotkeys live in the core process, not in the adapters

<!-- ADR 0048. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** the handful of actions that must happen mid-play — record start/stop, save the last
  N seconds, replay the last recording, restart / rewind / fast-forward a replay — are bound to
  **system-wide hotkeys registered by `meshghost.exe` itself**, in a new `internal/hotkey` package
  that `cmd/meshghost` wires to `core.ReplayControl`. Everything else about replays is config
  (ADR 0047). The user's call, 2026-09-03: "default to just having things in the config, and then
  per-adapter hotkeys need to be done if they are needed" — and a core-owned key "makes sure it
  works for any/all adapters, and then the extra work is on the adapters themselves".
- **Status:** built 2026-09-03 (`internal/hotkey`, wired in `cmd/meshghost`); a synthetic
  ctrl+shift+F9 against the real binary started a recording (`phases/phase11.md`, Stage 5). The stop
  message is `WM_APP+1` posted with `PostThreadMessageW`, not `WM_QUIT` — its page says not to post
  that from outside — and the loop's queue is created with `PeekMessageW` first, per that page's recipe.
- **Why the core process and not the adapter:** one implementation serves every game, including
  ones with no adapter yet, and the key works with the game focused because the registration is
  system-wide. An adapter that wants an in-game binding shown in its own settings sends
  `replay_control` over the bridge and the core does the same thing the global key would — an
  addition, never a replacement, so an adapter can skip it and the feature still works there.
- **Why `internal/hotkey` and not `core`:** the core is game-blind *and* OS-blind; `internal/gameblind`
  lets library packages import only stdlib, this module, quic-go and `golang.org/x/`. The package
  uses `syscall.NewLazyDLL` from the standard library, the same pattern as
  `cmd/meshghost/console_windows.go`, and `core` never imports it.
- **The Windows API, cited (the hard rule: no APIs from memory).** Read on learn.microsoft.com
  2026-09-03, and re-read before the struct layouts were written (Stage 5, same day):
  - `RegisterHotKey` — https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registerhotkey
    With a NULL window, `WM_HOTKEY` is posted to the **calling thread's** message queue and must
    be processed in a message loop. Modifiers `MOD_ALT 0x0001`, `MOD_CONTROL 0x0002`,
    `MOD_SHIFT 0x0004`, `MOD_WIN 0x0008`, `MOD_NOREPEAT 0x4000`. Fails if another application
    already registered the combination. Ids `0x0000`–`0xBFFF`. **F12 is reserved for the debugger**
    and is refused by our parser with that reason.
  - `GetMessageW` — https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmessagew
    Returns `-1` on error, `0` on `WM_QUIT`, nonzero otherwise; the loop checks `-1` explicitly.
  - `WM_HOTKEY` = `0x0312` — https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-hotkey
    `wParam` is the hotkey id; `lParam` low word the modifiers, high word the virtual key.
  - `UnregisterHotKey` — https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-unregisterhotkey
    Frees a hot key registered by the **calling thread** — so register, loop and unregister all run
    on one goroutine under `runtime.LockOSThread()`.
  - `PostThreadMessageW` — https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-postthreadmessagew
    How the loop is stopped: a private `WM_APP+1` posted to that thread. It fails unless the thread
    already has a message queue, which the system creates on the thread's first User call; the
    page's own recipe, `PeekMessage(PM_NOREMOVE)` first, is what `Run` does before reporting ready.
  - `WM_QUIT` = `0x0012` — https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-quit
    "Do not post the WM_QUIT message using the PostMessage function" — hence the private message.
  - `WM_USER` = `0x0400`, `WM_APP` = `0x8000` — https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-user
    `WM_APP` through `0xBFFF` is the range "available for use by applications".
  - `PeekMessageW`, `PM_NOREMOVE` = `0x0000` — https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-peekmessagew
  - `GetCurrentThreadId` (kernel32) — https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getcurrentthreadid
  - Virtual-key codes — https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
  - `MSG` — https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-msg
- **Off Windows:** `hotkey_other.go` (`//go:build !windows`) logs once that hotkeys are
  Windows-only and blocks until stopped, so CI's linux/darwin cross-compiles stay green and a
  non-Windows client simply has no hotkeys. Wine/Proton behaviour is unverified.
- **Failure modes, all logged and none fatal:** a chord already owned by another program fails
  *that* registration only; Win-key chords are OS-reserved; an adapter that registers the same chord
  as the core will lose, which `_template/README.md` says. Every registration logs the chord and
  the outcome, so "the key does nothing" answers itself from the log.
- **Bindings** are config keys under `hotkeys` (`ctrl+shift+F9` and friends, parsed
  case-insensitively, order-insensitively); an empty binding is simply not registered.
