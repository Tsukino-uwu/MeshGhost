# Phase 6 — Second game (TEVI)

**Status: in progress**, started 2026-08-11. Per `agent_docs/README.md`'s convention: a phase
earns a file when it's live, folded back into `agent_docs/plans.md` once done. Kept here for
the task-by-task record.

## Purpose

Repeat phases 1–4 for TEVI (Unity/Mono, 2D platformer/metroidvania) using the frozen
`adapters/_template/`, and find out whether the contract holds up outside Emerald — the real
point of picking a second, structurally different game.

## Tasks

- [x] Confirm TEVI's IL2CPP vs Mono status before assuming any tooling applies — the literal
      first task per `plans.md`/`adapters/tevi/README.md`, previously unconfirmed. **Confirmed
      Mono** (2026-08-11) via direct filesystem inspection of this machine's install
      (`C:\Program Files (x86)\Steam\steamapps\common\TEVI`): `TEVI_Data\Managed\
      Assembly-CSharp.dll` present, no `GameAssembly.dll` anywhere in the install,
      `doorstop_config.ini` has a `[UnityMono]` section (not `[UnityIL2CPP]`). BepInEx/Harmony
      tooling applies directly — no IL2CPP interop/unhollowing step needed. Bonus finding:
      BepInEx 5.4.23.3 is already installed on this TEVI copy from prior unrelated use and
      confirmed working — `LogOutput.log` shows it chainloading a third-party plugin
      (`Randomizer 1.4.3`) under Unity v2021.3.25.6876972. See `agent_docs/environment.md`'s
      Unity/TEVI section for the full evidence.
- [x] 6.0 — Licensing gate: added BepInEx (LGPL-2.1), Harmony (MIT), and `Tevi_Randomizer`
      (MIT, own repo/license, not Archipelago's) to `agent_docs/licensing.md`, all verified via
      GitHub API + reading the actual `LICENSE` file. Read `Tevi_Randomizer.csproj` for build
      approach (facts/approach only, no code copied) — see the reference-findings note in
      `agent_docs/plans.md`'s history and the plan file. Closed the now-resolved IL2CPP risk in
      `agent_docs/risks.md`; added two new risks surfaced by TEVI (no game-version check between
      peers; BepInEx/Harmony coexistence with the already-installed Randomizer).
- [x] 6.0.5 — Environment re-baseline: user updated TEVI and the Randomizer (was stale, ~1 year
      behind — `TEVI.exe` now 2026-07-16, Randomizer now 1.6.1). Re-confirmed Mono status against
      the current build (unchanged). Unity version confirmed `2021.3.25f1` directly from
      `UnityPlayer.dll`'s own metadata. Clean baseline launch confirmed BepInEx 5.4.23.3
      chainloads cleanly with no errors. All recorded in `agent_docs/environment.md`.
- [x] 6.1 — Hello-world plugin: `adapters/tevi/MeshGhostTevi` (netstandard2.0, `BepInEx.Core`
      + `UnityEngine.Modules 2021.3.25` via NuGet, `bepinex.dev` feed). Built with
      `dotnet build -c Release`, deployed to `BepInEx/plugins/MeshGhostTevi/`, confirmed live in
      `BepInEx/LogOutput.log`: `MeshGhost v0.1.0 loaded` logs cleanly, Randomizer 1.6.1 still
      loads right after with no conflict. See `agent_docs/verified.md`.
- [x] 6.2 — Real local player state confirmed via `ilspycmd` decompile of this machine's
      `Assembly-CSharp.dll`: `EventManager.Instance.mainCharacter` (`CharacterBase`) →
      `.t.position` (world pos), `.direction` (`Character.Direction`: LEFT/RIGHT/TOPLAYER/
      NOTTOPLAYER), `.aniStatus` (`Character.PlayerAniState`: IDLE/JUMPING/DJUMPING/FALLING/
      FALLING2/RUNNING/DAMAGE/BREAKING/SLOPED — chosen over the ~100-value combat
      `PlayerLogicState` as a ghost-appropriate `anim` tag set); `WorldManager.Instance.Area`
      (`byte`) for the area/scene id. Logging confirmed live: direction correlates exactly with
      position delta, anim transitions correctly with real movement/jump/fall, area changed
      `48`→`1` on a real Randomizer-practice-area teleport. See `agent_docs/verified.md`.
      (the `48`→`1` jump was a real in-game teleport-back item, not a bug). Console spam fixed
      along the way: switched from fixed-interval to change-triggered logging (was 120 of 137
      console lines on the first run, mostly identical repeated idle state).
      **Not yet tested with the Randomizer disabled** (coexistence risk in `risks.md`) — carry
      forward, not blocking.
- [x] 6.3 — Fake ghost in-engine, no network. Settled Spine-vs-sprite by decompiling
      `PixelCharacter.cs`: plain `SpriteRenderer` + Unity `Animator`, zero Spine references
      (Spine is used only by ~14 boss/environment files, not the player) — easier than Emerald,
      no manual pixel/palette decoding needed. Placeholder ghost (translucent magenta square,
      fixed offset from local player, no networking) confirmed live by the user: tracks through
      movement/jumping, survives room transitions (recreated lazily after scene-unload). Two
      real bugs found and fixed via actual testing, not assumed from a clean build: ghost was
      initially invisible (`pixelsPerUnit` mismatch vs. the real `charHeight = 65f` field) and
      the console was spammed 7324 lines in one session (position-change epsilon sat at the real
      per-frame movement noise floor — measured and fixed, not guessed). See
      `agent_docs/verified.md`.
- [x] 6.4/6.5 — Done, confirmed live. `BridgeClient.cs` (NDJSON bridge client, non-blocking
      connect on a background thread, sends on the main thread) plus per-`player_id` remote
      ghosts (cyan, distinct from 6.3's fixed-offset magenta local one) wired into `Plugin.cs`.
      Tested against a real `cmd/meshghost -game=tevi` core and `cmd/meshghost-relay -loopback`
      (`dev-scripts/run-core-tevi.bat` / `run-relay-loopback.bat`, added this session). First
      attempt hit the predicted 120 msg/sec relay disconnect for real (TEVI's `Update()` runs
      uncapped well above that) — fixed in `internal/core` (`Core.MinSendInterval`, 20Hz
      default), not the adapter, with a regression test and an ADR in `architecture.md`. Retest
      after the fix: user confirmed the loopback-echoed cyan ghost tracks smoothly through
      movement, jumping, and area transitions, no disconnect. See `agent_docs/verified.md`'s two
      Phase 6.4/6.5 entries. Also fixed along the way (not confirmed as the cause of a one-time
      window-move crash, but a real risk regardless): `BridgeClient`'s background thread now
      queues log lines instead of calling BepInEx's logger directly from a non-main thread.
      **Confirmed not a bug:** the magenta local ghost staying visible after closing the core
      and relay — expected, it has no network dependency at all.
- [x] Real character-visual ghost rendering (not in the original 6.1-6.6 outline — added because
      it's fully solo-testable via loopback, no second player needed). The remote ghost is now a
      real clone of the player's own visual object, not a placeholder box: correct body-anchored
      position (real offset measured, not guessed — see `verified.md`), correct left/right
      facing with all five sprite layers (base/outline/effect/flash/support) kept in sync, and
      real animation playback via the actual clip name sent over the wire
      (`SpriteAnimation.GetAnimationTrueName()`) instead of an invented enum-to-animation
      mapping. User confirmed "all combat animations & everything" plays correctly, not just
      idle/run/jump. Three real bugs found and fixed live getting here — see
      `agent_docs/verified.md`'s Phase 6 real-visual entry for the full list.
- [x] Confirmed the ghost does not visually intrude on TEVI's full-screen menus (Characters,
      Map pages tested), unlike Emerald's `gui.drawImage` overlay which needed an explicit
      `inOverworld()` gate. Structural, not luck: the ghost is a world-space `GameObject`
      rendered by the game's own camera, and TEVI's menus are a UI layer drawn on top, so the
      world (ghost included) naturally ends up underneath with no adapter-side gating needed.
      **Only resolves the visual half** of the still-open "don't send this frame" question —
      state is still sent to the network while a menu is open; whether a remote's ghost should
      visibly freeze during a peer's menu is a separate question. **Decision (2026-08-12):**
      leave current behavior (always send, no menu gating) as-is deliberately, not as an
      oversight — it can't be meaningfully evaluated without a second real peer to watch react
      to it, so revisit only if real 6.6 testing shows it's actually a problem, rather than
      guessing at a fix for something not yet observed to need one. See `agent_docs/verified.md`.
- [ ] 6.6 — Next: two real players. **Blocked, confirmed 2026-08-12 by the user attempting it:
      Steam will not run two simultaneous TEVI instances.** Needs a second machine (a friend, or
      another PC) rather than two local instances — see the Notes section below. Everything
      solo-testable via loopback (bridge, rendering, animation, facing, menu non-intrusion) is
      now done; what's left genuinely needs a second real peer: cross-area filtering (loopback
      always echoes your own area — `internal/core` currently sends every known remote
      regardless of area, and the TEVI adapter doesn't filter either, a real unaddressed gap,
      not just untested) and the real join/leave/disconnect flow. **No longer blocked on
      distribution** (2026-08-12): TEVI now ships in the single release zip (see
      `packaging/README.md`'s TEVI section), marked experimental/prerelease — the remaining
      blocker is purely "find a second real player," not "no way to hand them a build."

## Notes

- **TEVI cannot run two simultaneous instances via Steam** — confirmed by the user attempting it
  directly (2026-08-12), not assumed. Steam blocks the second launch. This doesn't block 6.4
  (bridge) or 6.5 (loopback, which proves ghost rendering using the relay's `-loopback` echo
  against a single real client — no second instance needed, same approach as Emerald's Phase 3).
  It does block 6.6 (two real players) until a workaround is found — likely a second machine
  (a friend, or another PC on this network) rather than two local instances. Not solved yet;
  revisit when 6.6 is actually reached.

- **Dev-only toggle, remember to revert:** `BepInEx/config/BepInEx.cfg`'s
  `[Logging.Console] Enabled` was flipped `false` → `true` on this machine (2026-08-12) so a
  console window shows live log output while building/testing the TEVI adapter. This is a local
  config file, not something MeshGhost ships or touches programmatically — but note it here so a
  future session doesn't mistake it for a MeshGhost-caused change, and so it gets turned back off
  once Phase 6 dev work settles down (not urgent, not user-facing, just noise otherwise).

- **Packaging landed (2026-08-12):** the one-zip rework (`plans.md`'s "Release packaging",
  `packaging/README.md`) shipped with TEVI support built in from the start —
  `packaging/release/games/tevi/MeshGhostTevi.dll` is a committed build output (CI can't build
  it, see `packaging/README.md`), produced by `dev-scripts/build-tevi.bat` and guarded by a
  staleness check in `release.yml`. Anyone editing `Plugin.cs`/`BridgeClient.cs`/the `.csproj`
  must re-run that script and commit the result, or the release workflow fails on purpose.
