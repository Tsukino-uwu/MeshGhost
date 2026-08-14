# Dev scripts

Developer/testing launchers used while building MeshGhost itself — not what an end user
wanting to play needs. If you just want to play with friends, use the pre-built release
instead: see [packaging/README.md](../packaging/README.md) and the repo's Releases page.

These assume `meshghost.exe`, `meshghost-relay.exe`, and `meshghost-fakeadapter.exe` are
built at the repo root (e.g. `go build -o meshghost.exe ./cmd/meshghost`, run from the repo
root) — each script references them as `..\<name>.exe`.

- `run-relay.bat` — a single relay, default settings.
- `run-core-emerald.bat` / `run-core-emerald2.bat` — two Emerald core clients on distinct
  bridge ports (7778 / 7779), for real two-player testing (see
  [agent_docs/phases/phase4.md](../agent_docs/phases/phase4.md)). `run-core-emerald.bat` alone
  also doubles as the solo/self-test core — pair it with `run-relay-loopback.bat` below instead
  of `run-relay.bat` to see your own ghost trail yourself with only one BizHawk instance
  running. Defaults to `-interp=0ms -min-send=10ms` (changed 2026-08-14, was `200ms`) — as
  close to instant/unsmoothed as the relay's 120 msg/sec cap allows, since local dev testing has
  no real network jitter to smooth over and artificial delay only makes it harder to tell
  whether a remote ghost's animation genuinely matches the real player frame-for-frame. The
  same TEVI/Pseudoregalia core launchers below share this default. **Exception:**
  `run-core-emerald-trail.bat` below intentionally keeps a real delay for pairing with the
  loopback-trail BizHawk launcher.
- `run-bizhawk-emerald.local.bat` / `run-bizhawk-emerald2.local.bat` — **not tracked** (see
  `.gitignore`; EmuHawk/ROM paths are personal and this repo is public). Per-machine BizHawk
  launchers, real paths from `agent_docs/environment.md`, pairing with the two cores above
  (instance 2 sets `MESHGHOST_BRIDGE_PORT=7779` before launch — the Lua adapter reads it,
  defaulting to 7778 to match instance 1). Exist specifically because launching EmuHawk
  directly (double-click, no env var) silently defaults both instances to the same bridge
  port with no error — found live 2026-08-14, cost a full debugging session to diagnose (see
  `agent_docs/phases/phase4.md`'s real-two-peer-retest entry). Recreate these two files
  yourself (they're gitignored, not shipped) if starting fresh on a new machine — see
  `agent_docs/environment.md` for the real `EmuHawk.exe`/ROM paths to put in them.
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
- `run-relay-loopback.bat` — a relay that echoes a lone client's own state back as
  `<id>-ghost`. Pair with any single core (`run-core-emerald.bat`, `run-core-tevi.bat`,
  `run-core-pseudoregalia.bat`) to see a real network round trip and your own ghost with only
  one game instance running — see
  [agent_docs/phases/phase3.md](../agent_docs/phases/phase3.md) and
  [agent_docs/phases/phase6.md](../agent_docs/phases/phase6.md).
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
