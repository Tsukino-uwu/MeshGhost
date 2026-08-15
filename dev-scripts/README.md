# Dev scripts

Developer/testing launchers used while building MeshGhost itself — not what an end user
wanting to play needs. If you just want to play with friends, use the pre-built release
instead: see [packaging/README.md](../packaging/README.md) and the repo's Releases page.

These assume `meshghost.exe`, `meshghost-relay.exe`, and `meshghost-fakeadapter.exe` are
built at the repo root (e.g. `go build -o meshghost.exe ./cmd/meshghost`, run from the repo
root) — each script references them as `..\<name>.exe`. The one exception is
`run-loopback-in-release-folder.bat` below, which is written to be copied *out* of here into a
downloaded release folder and run against its `meshghost-server.exe` instead.

- `run-relay.bat` / `run-relay-loopback.bat` — a single relay, `-send-hz=100`. Deliberately NOT
  the relay's own 20Hz default: since the send/receive rate-control feature (see the ADR in
  agent_docs/architecture.md), a relay's advertised send_hz is prescriptive — a Core adopts it
  unless it has its own slower explicit `-min-send`, and the SLOWER of the two always wins. Left
  at 20Hz, this relay would silently override every `run-core-*.bat` script's own fast
  `-min-send` (below) back down to 50ms. 100Hz keeps this relay out of the way entirely, so
  each core's own `-min-send` is what actually governs local test timing, same as before this
  feature existed.
- `run-core-emerald.bat` / `run-core-emerald2.bat` — two Emerald core clients on distinct
  bridge ports (7778 / 7779), for real two-player testing (see
  [agent_docs/phases/phase4.md](../agent_docs/phases/phase4.md)). `run-core-emerald.bat` alone
  also doubles as the solo/self-test core — pair it with `run-relay-loopback.bat` below instead
  of `run-relay.bat` to see your own ghost trail yourself with only one BizHawk instance
  running. Defaults to `-interp=0ms -min-send=10ms` (changed 2026-08-14, was `200ms`) — as
  close to instant/unsmoothed as the relay's per-client flood cap allows (paired with
  `-send-hz=100` above), since local dev testing has no real network jitter to smooth over and
  artificial delay only makes it harder to tell whether a remote ghost's animation genuinely
  matches the real player frame-for-frame. The same TEVI/Pseudoregalia core launchers below
  share this default. **Exception:** `run-core-emerald-trail.bat` below intentionally keeps a
  real delay for pairing with the loopback-trail BizHawk launcher.
- `run-bizhawk-emerald.local.bat` / `run-bizhawk-emerald2.local.bat` — **not tracked** (see
  `.gitignore`; EmuHawk/ROM paths are personal and this repo is public). Per-machine BizHawk
  launchers, real paths from `agent_docs/environment.md`, pairing with the two cores above
  (instance 2 sets `MESHGHOST_BRIDGE_PORT=7779` before launch — the Lua adapter reads it,
  defaulting to 7778 to match instance 1). Exist specifically because launching EmuHawk
  directly (double-click, no env var) silently defaults both instances to the same bridge
  port with no error — found live 2026-08-14, cost a full debugging session to diagnose (see
  `agent_docs/phases/phase8.md`'s "Real non-loopback two-peer test" entry). Recreate these two
  files
  yourself (they're gitignored, not shipped) if starting fresh on a new machine — see
  `agent_docs/environment.md` for the real `EmuHawk.exe`/ROM paths to put in them.

  **Before diagnosing any two-instance local test** (Emerald, TEVI, or Pseudoregalia), confirm
  each process actually logged a distinct bridge port — launch every second instance through
  its `.local.bat`/`run-core-*2.bat` pair, never by double-clicking the game exe directly.
  Found live 2026-08-14: both instances silently shared one bridge port with no error, and a
  long pipeline trace confirmed the code was fine the whole time — the test setup was the bug.
  See `agent_docs/pitfalls.md`'s "Running two instances of the same emulator/game silently
  collide on a shared default port" entry.
- `run-bizhawk-emerald-loopback-trail.local.bat` — **not tracked**, same shape as
  `run-bizhawk-emerald.local.bat` above but also sets `MESHGHOST_LOOPBACK_TRAIL=1`. Pair with
  `run-relay-loopback.bat` below AND `run-core-emerald-trail.bat` specifically, not the plain
  `run-core-emerald.bat` — see that launcher's own entry for why. By default (the plain
  BizHawk launcher above), a loopback session's ghost renders a couple tiles to the side of the
  real player, for visually comparing rendering/animation quality side by side without the two
  overlapping — found live 2026-08-14 that an exact overlap made this hard to judge. This
  variant forces the ghost back to sitting exactly on your real position instead, for the other
  real use case: verifying the ghost actually tracks position precisely, which the offset would
  obscure. Same create-it-yourself note as the plain launcher above; see
  `meshghost_emerald.lua`'s `LOOPBACK_GHOST_OFFSET_TILES_X` comment for the full rationale, and
  the same pattern applies to Pseudoregalia's/TEVI's own loopback-ghost offset if/when they get
  an equivalent launcher.
- `run-core-emerald-trail.bat` — pairs specifically with
  `run-bizhawk-emerald-loopback-trail.local.bat` above. Unlike the instant-by-default
  `run-core-emerald.bat`, this keeps a real `-interp=200ms` (the same value Phase 3 confirmed
  live — see `agent_docs/phases/phase3.md`) because the trail launcher's zero render offset
  means a ghost with no interpolation delay sits exactly on top of you with nothing visible at
  all — the delay is what makes it a visible trailing ghost instead of an invisible overlap.
- `run-fakeadapter1.bat` / `run-fakeadapter2.bat` — two headless `cmd/meshghost-fakeadapter`
  instances (circle-motion fake ghosts, no game) for testing the core/relay without BizHawk at
  all — see [agent_docs/phases/phase5.md](../agent_docs/phases/phase5.md).
- `run-loadtest-relay.bat` / `run-loadtest-peers.bat` / `run-ghostload-pseudoregalia.bat` — the
  synthetic-peer load rig, for answering "how many players can this actually hold?". The
  shipped `max_clients` of 8 is a policy default, not a technical limit (see
  `internal/relay/limits.go`), and there are three separate ceilings behind it:

  1. **Relay fan-out**, which grows with the *square* of room size — `Room.Forward` sends every
     state to every other member. Measured on the real structs, one Pseudoregalia state line is
     597 bytes, so a 16-seat room at the default 20Hz is ~2.7 MB/s of relay upload (~9.6 GB an
     hour) against ~175 KB/s down per player; a 32-seat room is ~11.3 MB/s up (~40 GB/hour).
     The host carries the quadratic term, which is why raising the cap is their bandwidth bill.
  2. **Per-client receive**, which grows linearly and won't be what breaks.
  3. **Adapter render cost** — almost certainly the one that actually binds, and the only one
     that can't be measured without a game running.

  `run-loadtest-relay.bat` + `run-loadtest-peers.bat [count]` cover tiers 1–2 headlessly (no
  game at all): N peers in one process, each a real `Core` with its own relay connection. The
  `client0_remotes` line is the rig's self-check — it is a *lower* bound (`>=N-1`), because in
  the tier-3 rig a real game client is in the room too.

  `run-ghostload-pseudoregalia.bat [count]` is tier 3: the same synthetic peers, but wearing a
  real game's `game_id`/`area_id` so **one** running copy of Pseudoregalia renders N ghosts. It
  needs `MG_AREA` and `MG_CENTER` set from a live session first — `area_id` is matched by
  equality in `internal/core`, so a wrong value renders nothing and looks exactly like a broken
  rig rather than a mismatch. Ramp the count and read a real frame-time number (`stat unit`)
  off the game each step; add `-churn-every` to exercise ghost spawn/despawn (a full pawn-clone
  construction each time), which may cost more than steady-state rendering. Note this is a
  *rendering* load test only — synthetic peers say nothing about whether two real game
  instances can run at once, which is Phase 7.7's separate question.

  `meshghost-fakeadapter.exe` knows nothing about any game: the per-game specifics live in
  these launchers and in `loadtest-extras-pseudoregalia.json`, passed via `-extras`.
- `run-relay-loopback.bat` — a relay that echoes a lone client's own state back as
  `<id>-ghost`. Pair with any single core (`run-core-emerald.bat`, `run-core-tevi.bat`,
  `run-core-pseudoregalia.bat`) to see a real network round trip and your own ghost with only
  one game instance running — see
  [agent_docs/phases/phase3.md](../agent_docs/phases/phase3.md) and
  [agent_docs/phases/phase6.md](../agent_docs/phases/phase6.md).
- `run-loopback-in-release-folder.bat` — **the only script here meant to leave this folder.**
  Same loopback idea as above, but for someone who downloaded a release zip rather than built
  the repo: they copy this one file next to `meshghost.exe`/`meshghost-server.exe` and run it
  instead of `meshghost-server.exe`, and see a ghost of themselves with no second player and no
  second PC. Hand it out on request — it is deliberately **not** bundled into the release
  (`.github/workflows/release.yml` only zips `packaging/release/*`, so nothing here ships), and
  the release stays a clean two-exe folder with no dev-only flag sitting in it.

  Two deliberate differences from `run-relay-loopback.bat`, both from the release layout rather
  than preference: the release renames the relay to `meshghost-server.exe` and puts it in the
  *same* folder as the script rather than one level up, and there is no `-send-hz=100` override
  — that exists only to keep a dev relay out of the way of the `run-core-*.bat` scripts' own
  fast `-min-send`, so in a release folder it would just silently override the user's own
  `config.json`. It `cd /d "%~dp0"` first (the relay reads `config.json` from the working
  directory, which differs between double-clicking, dragging onto a cmd window, and Run as
  administrator) but still launches via the full `"%~dp0meshghost-server.exe"` path: cmd's
  usual "search the current directory for a command" lookup is disabled wherever
  `NoDefaultCurrentDirectoryInExePath` is set, and a bare exe name then fails with "not
  recognized as an internal or external command" while sitting right there — found live while
  testing this script. Dropped in the wrong folder it says so in plain language and exits
  rather than failing cryptically.

  **Status: confirmed on screen in a running game (2026-08-15)** — user ran it from a real
  release folder with Pseudoregalia attached and saw their own ghost standing beside them; see
  [agent_docs/verified.md](../agent_docs/verified.md)'s entry for what was observed. Fine to
  hand out. Agent-side checks cover the details underneath: `config.json` and
  `meshghost-server.log` both resolving to the release folder when launched from an unrelated
  working directory, the wrong-folder guard exiting cleanly, and a `render_remote p1-ghost`
  round trip driven by `meshghost-fakeadapter.exe`.

  **Expect it to look less smooth than the dev loopback — that's the point, not a bug.** Since
  this script omits `-send-hz=100`, the relay runs at the release `config.json`'s own `send_hz`
  (20 by default), which is what a real session actually looks like; the dev scripts' 100Hz is
  the artificial one. The difference is clearly visible side by side and was the first thing
  noticed on the live run. Rate and smoothing are tuned in `config.json` (`send_hz`, `interp`),
  the same knobs a real player has — resist adding `-send-hz` back to this script.

  Still unconfirmed: Emerald and TEVI. TEVI in particular has no loopback offset constant in
  its source, so its ghost may sit directly on top of the player rather than beside it.

  The loopback ghost renders a short distance to the side of the real player rather than
  exactly on top of it, so the two can be compared without overlapping — that offset is
  adapter-side, not in this script: `LOOPBACK_GHOST_OFFSET_TILES_X` in
  `meshghost_emerald.lua`, `LOOPBACK_GHOST_OFFSET_X` in Pseudoregalia's `Plugin.cpp`.
- `run-core-tevi.bat` / `run-core-tevi2.bat` — two TEVI core clients on distinct bridge ports
  (7778 / 7779), for real two-TEVI testing with a normal (non-loopback) `run-relay.bat` — same
  shape as the Emerald pair above, but for `-game=tevi`. Pair each with its own TEVI install
  (e.g. the Steam copy on 7778, a standalone build like `C:\dev\tevi-14778703` on 7779 — see
  [agent_docs/environment.md](../agent_docs/environment.md)); the standalone install's own
  `BepInEx/config/dev.meshghost.tevi.cfg` needs its `BridgePort` set to match (7779), since
  Steam already owns the default. See
  [agent_docs/phases/phase6.md](../agent_docs/phases/phase6.md)'s 6.6 entry.
- `build-tevi.bat` — not a launcher, a build step: compiles the TEVI BepInEx plugin and stages
  the result into `packaging/release/games/tevi/` for the release zip. Re-run and commit the
  result whenever `adapters/tevi/MeshGhostTevi/{Plugin.cs,BridgeClient.cs,*.csproj}` change —
  see [packaging/README.md](../packaging/README.md)'s TEVI section for why this one output is
  committed at all.
- `run-core-pseudoregalia.bat` — a single core client wired for Pseudoregalia
  (`-game=pseudoregalia`, bridge port 7778) — see
  [agent_docs/phases/phase7.md](../agent_docs/phases/phase7.md).
- `build-pseudoregalia.bat` — not a launcher, a build step: compiles the Pseudoregalia UE4SS
  C++ mod (`main.dll`) via its local CMake build tree and stages it into
  `packaging/release/games/pseudoregalia/`. Re-run and commit the result whenever
  `adapters/pseudoregalia/MeshGhostPseudo/Mod/src/*` or its `CMakeLists.txt` change — same
  staleness-gate pattern as `build-tevi.bat`, but CI can't build this one at all (needs the
  private UEPseudo dependency), so the build tree must already be configured locally — see
  [agent_docs/phases/phase7.md](../agent_docs/phases/phase7.md)'s 7.2 entry.
- `stage-ue4ss-runtime.bat` — stages the RE-UE4SS runtime (UE4SS.dll, settings, stock Mods)
  from the pinned `adapters/pseudoregalia/MeshGhostPseudo/RE-UE4SS` submodule into
  `packaging/release/games/pseudoregalia/`, alongside whatever `build-pseudoregalia.bat` has
  staged. Re-run whenever the RE-UE4SS submodule pin changes; requires the build tree already
  built once.
