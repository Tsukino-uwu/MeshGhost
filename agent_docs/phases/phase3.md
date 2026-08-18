# Phase 3 — Loopback

Folded back into `agent_docs/plans.md` as complete (2026-08-11); kept here for the detailed
task-by-task record. Per `agent_docs/README.md`'s rule: a phase earns a file when it's live,
and gets folded back once it's done. Phase 4 (two players) is also complete — see
`agent_docs/phases/phase4.md`.

## Purpose

Connect the two halves that have never met: the Go networking layer (`internal/transport`,
`internal/relay`, `internal/core`, `internal/bridge` — built and tested ahead of the BizHawk
blocker, see "Go networking layer" below) and a real BizHawk Lua adapter. Visible outcome: a
ghost follows the player around Littleroot Town roughly a fifth of a second behind, having made
the full round trip Lua → bridge → core → relay → core → bridge → Lua. This is also the phase
where `agent_docs/contract.md`'s "Limits" section becomes enforced rather than just documented.

## Go networking layer (built 2026-08-11, ahead of the BizHawk blocker)

Built and tested before any real BizHawk adapter existed, since it doesn't require a game or
emulator:

- `internal/transport` — real NDJSON-over-TCP framing (`Dial`/`FromConn`, `Send`, lifecycle
  callbacks). 3 tests.
- `internal/relay` — a real `Server`: hello/welcome handshake, room/roster tracking, forwards
  `state` to the rest of a room, broadcasts `join`/`leave`, rejects a mismatched `game_id` per
  room. `cmd/meshghost-relay` runs it. 4 tests.
- `internal/bridge` — added envelope framing so `local_state`/`render_remote`/
  `despawn_remote` are distinguishable on the wire (was missing from the Phase 0 skeleton).
- `internal/core` — a real `Core`: relay handshake, per-remote interpolation buffer (linear
  position lerp, opaque fields held from the older sample, clamped at buffer edges — no
  extrapolation), and a bridge listener where each adapter frame call triggers forwarding
  local state out and pushing interpolated `render_remote`/`despawn_remote` back. `cmd/
  meshghost` runs it. 9 tests.
- Verified beyond `go test`: built both binaries, ran a real relay + two real core processes,
  and drove one over a raw TCP socket standing in for an adapter — confirmed `render_remote`
  arrived at the other side with correct data. This was not itself a Phase 3 completion (a real
  adapter and an on-screen ghost were still needed — that's the rest of this phase) but it was
  real evidence the plumbing worked end-to-end before any Lua code existed.

## Decisions made this phase (see `agent_docs/architecture.md` for the full ADR)

- **LuaSocket, not BizHawk's built-in `comm.*`.** Both were inspected against the real
  installed BizHawk 2.11 build before choosing. `comm.*` uses length-prefixed framing and a
  blocking request/response model; adopting it would have pushed a second framing mode into
  the Go bridge that every future adapter (Unity, UE5) would then have to speak. LuaSocket
  keeps the bridge as plain NDJSON. Vendored: `adapters/pokemon/emerald/lib/x64/socket-windows-5-4.dll`
  (MIT, see `agent_docs/licensing.md`) — the same binary already proven working against this
  exact BizHawk/Lua-5.4 build by the unrelated Archipelago project, reused rather than
  independently rebuilt from source to avoid a silent Lua-ABI mismatch with no error to catch
  it.
- **Loopback is a relay-side `-loopback` flag**, not a core-side or third-process echo: a lone
  client's own `state` is echoed back to it under a synthetic `"<id>-ghost"` player_id
  (`internal/relay/relay.go`'s `Server.Loopback`). Exercises a real core→relay→core round trip
  and real interpolation with zero changes to `internal/core` — its existing
  "ignore my own player_id" guard stays correct because the ghost carries a different id. Dev
  only; ignored starting Phase 4.

## Tasks

- [x] License BizHawk and LuaSocket in `agent_docs/licensing.md` before writing any code that
      depends on either (`CLAUDE.md`'s standing rule) — including reading BizHawk's own
      `LuaLibraries.cs` source to confirm `debug.getinfo` is available (no library stripped),
      rather than assuming BizHawk's Lua sandbox from memory.
- [x] Vendor the LuaSocket binary + MIT license notice.
      `adapters/pokemon/emerald/lib/x64/socket-windows-5-4.dll` + `luasocket.LICENSE.txt`.
- [x] `internal/relay`: add the `-loopback` echo, enforce the contract's Limits (line length,
      `extras` size, `position` length, per-client rate limit, room capacity), and stamp
      `player_id` server-side rather than trusting the client's payload. New tests:
      `TestLoopbackEchoesGhost`, `TestNoLoopbackNoEcho`, `TestServerStampsPlayerID`,
      `TestOversizedPositionDropped`, `TestOversizedLineClosesConnection`,
      `TestRoomFullRejectsExtraClient`. `go build`/`go vet`/`go test ./...` all clean.
- [x] `internal/core`: make `InterpolationDelay` a per-`Core` field (was a package const),
      settable via a new `-interp` flag on `cmd/meshghost`, defaulting unchanged.
- [x] Write `adapters/pokemon/emerald/probes/phase3_loopback.lua`: real state reading (same addresses as
      `phase1_probe.lua`), a hand-written minimal JSON encoder/decoder (no vendored JSON lib —
      the wire is either our own construction or our own Go's canonical output, not untrusted
      input), a non-blocking LuaSocket connection to the bridge, the adapter-owned
      upsert/despawn remote-ghost set per the tick model, and ghost placement via
      player-screen-anchor + tile-delta offset (reuses Phase 2's verified anchor rather than
      re-deriving camera math for a second time).
      Every BizHawk/LuaSocket API behavior relied on (non-blocking connect's "already
      connected"/"timeout" results, `receive()`'s internal partial-line buffering, `debug`
      library availability) was checked against real source (LuaSocket's own `pierror.h`/
      `usocket.c`, BizHawk's `LuaLibraries.cs`, Archipelago's `connector_bizhawk_generic.lua`)
      before being relied on — none assumed from memory.
- [x] Update `agent_docs/contract.md`'s Limits section with the actual chosen numbers (were
      placeholders since Phase 0) and note the one known gap: `MaxLineBytes` is checked only
      after a line is fully buffered, not enforced by `internal/transport` itself.
- [x] Start `meshghost-relay -loopback`, then `meshghost -game=emerald -interp=200ms`;
      confirm the round trip over a raw socket before trusting any Lua-side decoding. Done via
      a Python script sending exactly the bridge shapes `phase3_loopback.lua` sends — confirmed
      a `render_remote` for `p1-ghost` arrives with correct `area_id`/`orientation`/`anim` and
      an interpolated position.
- [x] **First live BizHawk attempt failed** loading `socket-windows-5-4.dll`:
      `NLua.Exceptions.LuaScriptException: ... The specified module could not be found.`
      Diagnosed and fixed (not guessed) — see the Phase 3 ADR's follow-up finding in
      `architecture.md`: the DLL depends on `lua54.dll`, which Windows' plain `LoadLibrary`
      cannot find via the standard search order (confirmed by reproducing the exact failure
      outside BizHawk). Fix: vendor a byte-identical copy of the `lua54.dll` already running
      inside the user's BizHawk (`adapters/pokemon/emerald/lib/x64/lua54.dll`) and pre-load it by full
      path before loading the socket core. Confirmed against the real vendored files with a
      direct `LoadLibrary` test (PowerShell) before asking for a second live retry.
- [x] **Second live attempt also failed**, same symptom, now at the `socket-windows-5-4.dll`
      load itself. Root cause was actually a *different* bug the first fix didn't touch:
      `scriptDir()` used `debug.getinfo(1, "S").source`, but BizHawk loads scripts as an
      in-memory string chunk named literally `"main"` (confirmed via `LuaLibraries.cs`:
      `_lua.LoadString(File.ReadAllText(file), "main")`), not via a file path — so `source` was
      just `"main"`, no `@` prefix, and every path in the script silently resolved to `"./"`.
      This is also why the error showed as `[string "main"]:N:` rather than a real file path —
      Lua's own standard formatting for an undecorated chunk name. Fixed by switching to the
      same technique the cited reference script (Archipelago's `socket.lua`) already uses for
      the identical documented reason ("for some reason `./` isn't working"): `io.popen("cd")`.
      Confirmed BizHawk does set the real Win32 CWD to the script's directory before running it
      (`LuaSandbox.cs` → `CWDHacks.Set` → real `SetCurrentDirectoryW`, read directly, not
      assumed) and confirmed `cmd /c cd` prints exactly that directory. The original
      `lua54.dll`-dependency fix was independently real and still needed — verified with a
      clean `LoadLibrary` test using correct absolute paths, separate from this bug.
- [x] Third live attempt: **script connected and ran successfully.** Console showed
      "MeshGhost Phase 3: connected to bridge.", ghost visible tracking the player.
  - [x] Walk-around trailing test: confirmed a ghost consistently trails ~1 tile behind,
        holding steady whether walking or running, and across route/house transitions (the
        exact case Phase 1/2 found transient glitches in previously) — no drift, no
        overshoot. `TILE = 16` confirmed correct by this test (a wrong value would show as
        drift or overshoot, per the checklist item this replaces).
  - [x] No-flicker check: confirmed smooth, stable tracking; user noted it's hard to be fully
        certain with a placeholder box vs. a real sprite, but nothing looked like a redraw
        glitch.
  - [x] **Kill-relay-mid-session check FAILED on first try, root cause fixed:** the ghost
        froze at its last known map position instead of despawning — screenshot showed it
        sitting at a fixed world coordinate, scrolling with the camera, no longer tracking the
        player. Root cause: `internal/core`'s relay `OnDisconnect` handler only logged; nothing
        cleared `c.remotes`, and `remoteBuffer.at()` holds the newest sample forever once
        `renderTime` passes it (no extrapolation), so the existing per-frame despawn logic
        never had a reason to fire — a *peer* leaving triggers a `Leave` message that drives
        it, but there's no `Leave` possible once the relay itself is gone. Fixed:
        `Core.dropAllRemotes()`, wired into `OnDisconnect`, clears the map so the very next
        adapter frame sees every remote vanish from `remoteStatesAt` at once and the existing
        rendered-vs-current diff turns that into real `despawn_remote` calls — no wire-protocol
        change. Covered by new test `TestOwnRelayDisconnectDespawnsRemotes` in `core_test.go`.
        `go build`/`go vet`/`go test ./...` clean; both binaries rebuilt.
  - [x] **Relay-kill retest passed** against the rebuilt binaries (implied by the user moving
        on to test closing the core next — no regression reported).
  - [x] **Second bug found: closing the core (bridge) also left the ghost frozen forever**,
        with zero new Lua console output — a *different* bug from the relay one, this time
        entirely in `phase3_loopback.lua`, not `internal/core`. Root cause:
        `drainBridge()`'s error handling special-cased `err == "closed"` as the only trigger
        for cleanup and silently treated every other error string as a harmless "timeout" —
        so whatever LuaSocket actually reports for this disconnect path (a forcibly-terminated
        peer process, not necessarily the same as a graceful close) fell through unnoticed,
        `connected` stayed `true`, and the stale `remotes` entry kept being redrawn forever.
        Fixed by inverting the check: `"timeout"` is now the only case treated as harmless;
        everything else is treated as fatal (matching the pattern `sendLine`'s error handling
        already used correctly). Also added a console log line on disconnect, previously
        silent either way, which made this bug harder to diagnose from the user's side.
  - [x] Relay-kill retest with the drainBridge fix: ghost now visibly tied to/near the player
        rather than stuck at a distant world coordinate — but see the third bug below, this
        was still not fully correct (the underlying image simply wasn't being cleared).
  - [x] **Third bug found — the real root cause behind both "frozen ghost" symptoms:**
        `contract.md`'s tick model claimed "BizHawk's `gui.*` overlay is cleared every frame,"
        used as the stated reason redraw-every-frame avoids flicker. Confirmed live this is
        wrong: drawn images persist until explicitly cleared or overwritten — confirmed against
        BizHawk's own `gui.d.lua` doc (`gui.clearGraphics` exists specifically to do this,
        which would be pointless if the overlay auto-cleared) and real precedent in BizHawk's
        own bundled scripts. `drawRemotes()` never called it, and worse, was gated behind
        `if connected then`, so a ghost never got cleared once disconnected regardless of
        whether `remotes` was correctly emptied. Fixed: `gui.clearGraphics()` called
        unconditionally at the top of every frame, before the connect/send/draw logic — see
        the correction in `contract.md`'s tick model section. This is very likely what made
        *both* the relay-kill and core-kill tests look broken even after the two earlier Go/Lua
        state-tracking fixes were already correct — those fixes stopped new draw calls from
        happening, but nothing had ever cleared what was already on screen.
  - [x] **Retest passed, all three fixes confirmed together:** relay-kill → ghost disappears
        instantly (client log shows `core: relay disconnected`, matching the `dropAllRemotes`
        fix firing correctly). Core-kill → ghost disappears instantly too, Lua console logs
        "bridge connection lost, will retry connecting." (matching the `drainBridge` fix).
        Normal tracking unaffected by the unconditional `gui.clearGraphics()` — no new flicker
        across the whole retest session.
  - [x] Map/camera edge case, satisfied by evidence already gathered rather than a separate
        small-room retest: during the pre-fix frozen-ghost test, the ghost scrolled fully
        off-screen as the player walked away and became visible again on walking back —
        confirmed it's tracked as a real world coordinate that BizHawk's own viewport culling
        naturally hides/reveals, not something glued to the player's screen position. This is
        a stronger version of Phase 2's small-room test (which only showed the player
        off-center, not an object leaving and re-entering the viewport entirely), and combined
        with Phase 2 already separately proving the reused player-anchor formula holds at a
        true camera-pinned edge, covers the risk that check existed for: the offset math is
        anchor-relative and doesn't care where on screen the anchor itself happens to sit.
- [x] Record every confirmed (or corrected) fact in `agent_docs/verified.md` — append-only,
      human-gated, done only after the user watched each behavior happen. Nine entries added:
      the `debug.getinfo`/`io.popen` path-resolution finding, the `lua54.dll` dependency fix,
      the `gui.clearGraphics` persistence correction, the two disconnect-handling bugs and
      fixes (`internal/core` and the Lua adapter), and the full loopback round trip itself.

## Deferred, deliberately

- **Battle-skip gating**, deferred by Phase 2 to "whichever phase first has `render_remote`
  calls to gate" (this one). Needs its own unverified `pokeemerald`-cited battle-detection
  address and its own on-screen test; a misplaced ghost during battle is cosmetic and already
  fully understood from Phase 2. Not attempted this phase — moves to Phase 4 if it needs more
  than a quick follow-up.
- **Archipelago-patched ROM.** Vanilla only this phase; `agent_docs/risks.md` already records
  the `gPlayerAvatar`/`gObjectEvents` invalidation and its planned `dx`/`dy` mitigation,
  explicitly deferred until after the vanilla path is proven.
- **The event plane and `features`.** Reserved here; both built 2026-08-17, along with leases,
  escrow and world custody on top of them (`architecture.md`).
- **`internal/transport`-level line-size cap** (the one known gap in the Limits work above) —
  real risk only once Phase 4 puts untrusted peers on the wire.
- **Noisy `core: send state to relay failed` log spam after a relay disconnect.** `onAdapterFrame`
  keeps calling `c.sendState` every frame even after the relay connection is known dead,
  logging an error each time. Harmless (doesn't affect correctness — `dropAllRemotes` already
  handles the actual despawn), just noisy. Found live during the relay-kill retest; small
  enough to fix opportunistically in Phase 4 rather than block this phase on it.

## Success criteria

- A ghost is observed on screen trailing the local player by ~200ms, having made the real
  round trip through a real relay (loopback flag on), not a simulated or same-process shortcut.
- `TILE` is confirmed, not assumed, against real on-screen movement.
- No flicker, and correct behavior at a map edge.
- Every claim above is in `agent_docs/verified.md`, watched by the user, not inferred from a
  clean build or a script that "ran without erroring."

## Links

- `agent_docs/contract.md` — the tick model and Limits section this phase implements for real.
- `agent_docs/architecture.md` — the Phase 3 ADR (LuaSocket vs `comm.*`, loopback design).
- `agent_docs/licensing.md` — BizHawk and LuaSocket entries added this phase.
- `agent_docs/phases/phase2.md` — the screen-position anchor this phase's ghost placement
  builds on.
- `agent_docs/verified.md` — where confirmed facts land, after live verification.
