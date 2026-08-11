# Current status

## Active status

- `Active phase:` Phases 1 and 2 are both complete (2026-08-11, folded into
  `agent_docs/plans.md`) — see `agent_docs/verified.md`. Phase 2 confirmed
  `adapters/emerald/phase2_ghost.lua` renders and tracks the local player correctly, including
  at a real camera-pinned map edge, with no unexplained flicker. Three transient-rendering
  quirks were found and traced to already-understood causes rather than new bugs: (1) the
  sprite-slot-based screen-position read breaks during battle — resolved as a design decision
  (skip all ghost drawing during local battle; the data side already doesn't need a `nil`
  return, so a remote player's ghost just holds still, not despawns — implementation deferred
  to whichever phase first has `render_remote` calls to gate), (2) a brief jitter crossing
  seamless route/town connections and (3) a brief dip-then-correct on door warps, both
  plausibly the same `gSaveBlock1Ptr`-relocation glitch Phase 1 already found in raw position
  data, now visible in rendering too. Only loose ends: bike/surf flags (deferred, not
  blocking) and the `coordOffsetEnabled` assumption (unverified but low-risk, cheap to revisit
  if a non-centered-camera area is ever found that contradicts it).
- `Current focus:` Phase 3 (loopback) is **complete** (2026-08-11) — see
  `agent_docs/phases/phase3.md`. Confirmed on screen: a ghost trails the player ~200ms behind,
  `TILE = 16` correct, holding steady across walking/running and route/house transitions, no
  flicker, over the real relay/core/bridge round trip (`-loopback` flag, not a same-process
  shortcut). Three real bugs were found via live testing and fixed, all now covered by
  `verified.md` entries: `internal/core` didn't despawn remotes when its own relay connection
  dropped (fixed: `Core.dropAllRemotes`, wired into `OnDisconnect`, regression test added); the
  Lua adapter didn't detect its own bridge connection dying (fixed: `drainBridge`'s error
  handling inverted to treat only `"timeout"` as harmless); and — the one that made both of
  those look worse than they actually were — BizHawk's `gui.*` overlay does not auto-clear
  between frames, contradicting a wrong assumption `contract.md`'s tick model had stated since
  Phase 2 (now corrected there). Two Lua environment gotchas also found and fixed along the
  way: `debug.getinfo` can't recover a script's own path in BizHawk (scripts load as in-memory
  string chunks, not files — `io.popen("cd")` works instead), and the vendored LuaSocket binary
  needed `lua54.dll` explicitly pre-loaded by full path before it would load.
- `Next step:` **Phase 4 (two players) is complete** (2026-08-11) — see
  `agent_docs/phases/phase4.md`. Two real BizHawk/Emerald instances, distinct `-bridge`/`-name`
  cores, one relay without `-loopback`: confirmed on screen each client renders the other's
  ghost, a join is visible to the earlier client, a clean peer-leave (core process closes)
  despawns the ghost while an adapter-only disconnect correctly does not, an unclean leave
  (Task Manager kill) also despawns correctly, and no flicker/drift with two independently
  moving real players. `internal/core`'s `dropAllRemotes`/despawn work and the Lua adapter's
  disconnect-handling fixes from Phase 3 — previously only exercised via loopback — are now
  confirmed to generalize to a real second peer. Two more bugs found live and fixed in the same
  session: (1) a client's ghost-anchor read broke while *that client's own* player was in
  battle or in any full-screen pause-menu submenu (Pokédex/Bag/Card/Options) — fixed via a real,
  cited `pokeemerald` signal (`gMain.callback2` vs `CB2_Overworld`), confirmed live to hide/reshow
  ghosts correctly and strictly per-viewer, with NPC dialogue correctly left ungated; (2) remote
  ghosts rendered one tile too high (sprite-anchor vs. tile-position mismatch) — fixed with a
  `GHOST_Y_CORRECTION` constant, confirmed on screen. See `agent_docs/verified.md` for full
  entries. Any future Archipelago-coexistent adapter work will still need to re-derive
  `gPlayerAvatar`/`gObjectEvents`-equivalent addresses for a patched ROM rather than reusing the
  vanilla-decomp ones. One small deferred item from Phase 3: `internal/core` logs a noisy
  `send state to relay failed` error every frame after a relay disconnect — harmless, worth
  quieting opportunistically. Deferred idea from Phase 4 testing (not scheduled): rendering
  ghosts across a seamless route/town connection instead of just hiding them like any other
  different `area_id` — see `agent_docs/plans.md`.
- `Current focus:` **Phase 5 (extract the template) is complete** (2026-08-11) — see
  `agent_docs/phases/phase5.md`. Added `Core.RunAdapter`, an in-process driver for the
  already-existing (but previously unused) `core.Adapter` Go interface, sharing its tick-model
  diff logic with the existing bridge-wire path rather than duplicating it. Confirmed live:
  `cmd/meshghost-fakeadapter` (two instances, `dev-scripts/run-fakeadapter1.bat`/
  `run-fakeadapter2.bat`),
  each driving a circle-motion fake ghost with no game and no `adapters/` import, correctly
  exchanged and rendered each other's continuously-moving position over a real relay — user
  watched both console windows directly. `adapters/_template/` is now frozen
  (`README.md` + `PROTOCOL.md`), written language-agnostically since Phase 6's target (TEVI) is
  Unity/C#, not Lua. `TestRunAdapterInProcess` in `internal/core/core_test.go` covers the same
  path as an automated regression test.
- `Current focus:` **Phase 5.5 (real Emerald ghost sprite) is complete** (2026-08-11) — see
  `agent_docs/phases/phase5_5.md`. User pushed back on moving to Phase 6 while Emerald ghosts
  still rendered as a magenta placeholder box; scoped to three items, all done and confirmed
  live with two real peers: real decoded Brendan/May sprite renders (`gui.drawPixel`, fixed a
  wrong assumption about its color format along the way), `extras.gender` in the schema with
  gender-correct rendering confirmed both directions (male-save client sees May, female-save
  client sees Brendan), and every Phase 1/2 address re-verified on a real female save —
  `agent_docs/risks.md`'s male-only-tested gap is now closed. Facing direction and both
  walk/run animation are correct, including a genuinely separate running pose (found live —
  running is not a faster walk cycle, it uses its own pic table with asymmetric per-pose
  timing). Beyond the original three items, testing with a real detailed sprite (instead of the
  old placeholder box) surfaced and fixed real bugs: sub-tile position smoothing for a
  choppy/wobbly remote-ghost movement bug (real measured constants: 16 frames/tile walking, 8
  running, locked in per-step to avoid mid-glide snapping) and a stale-remotes-on-core-restart
  bug. Ledge jumps/Mach Bike/Acro Bike/Surfing confirmed out of scope, added to the existing
  bike/surf deferred item.
- `Current focus:` The repo is now public on GitHub — a cleanup pass fixed the stale README,
  removed hardcoded personal paths, and added a `CLAUDE.md` rule against that recurring. Since
  then, a real release pipeline was added (2026-08-11, not a numbered phase — see
  `agent_docs/plans.md`'s "Release packaging" entry): `cmd/meshghost`/`cmd/meshghost-relay`
  both load an optional `config.json`, and `.github/workflows/release.yml` builds/zips two
  downloadable packages (`packaging/relay/`, `packaging/emerald-player/`), triggered manually
  from the Actions tab (deliberately not automatic on a tag push) — confirmed working via a
  real local dry run (actual relay + client processes, config-only, no flags) before
  committing, though the GitHub Actions workflow itself is still untested end-to-end (the dry
  run proved the packaging logic, not the CI YAML). All 8 dev/testing `.bat` launchers also
  moved from the repo root into `dev-scripts/` for a cleaner public root, alongside
  `packaging/`'s end-user-facing scripts. No open next task right now — next real milestone is
  Phase 6 (TEVI), the post-Phase-4 room-codes work, or actually running the release workflow
  for the first time, whichever gets picked up first.

## Go networking layer (2026-08-11)

Built and tested ahead of the BizHawk blocker, since it doesn't require a game or emulator:

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
  arrived at the other side with correct data. This is not a Phase 3 completion (see above)
  because no real adapter and no on-screen ghost were involved, but it is real evidence the
  plumbing works end-to-end.
- What's still missing before this layer is exercised for real: a BizHawk Lua adapter that
  dials the bridge and speaks `local_state`/`render_remote`/`despawn_remote` — that adapter is
  Phase 2+ work and needs Phase 1's memory addresses first.

## Update guidance

- Update this file whenever the active phase changes.
- Keep entries short; this is a one-screen summary, not a log.
