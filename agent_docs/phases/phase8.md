# Phase 8 — Emerald, dedicated (post-Phase-5.5 ongoing work)

**Status: in progress**, started 2026-08-14. Numbered next in sequence rather than folded back
into 1–5.5 (which bundled Emerald's adapter work together with building the server/client/core
themselves, since Emerald was the first game) — renumbering 1–5.5 would break the many existing
citations to them across `verified.md`/`pitfalls.md`/`status.md`/`risks.md` for no real gain, so
they stay as-is. Phase 6 (TEVI) and Phase 7 (Pseudoregalia) are unrelated games and keep their
own numbers; this phase is specifically "Emerald keeps getting worked on, on its own, after
5.5 closed" — decided 2026-08-14, see `adapters/pokemon/emerald/README.md`'s "How this adapter
was built"/"Further work" sections for the reader-facing summary this phase file backs.

## Purpose

A dedicated home for Emerald-specific work that happens after Phase 5.5's "good enough"
milestone (2026-08-11) — real bugs found via live testing, Archipelago-compatibility work, and
future scoped investigations (surf/bike/fishing movement support, the VRAM/sprite-injection
idea) — instead of that work living homeless across `status.md`'s running log with no phase
file of its own, which is what was happening before this file existed.

## Tasks

- [x] **2026-08-14 review/refactor sweep, Lua side**: partial-line receive, partial send,
      dead-socket-after-hard-error detection, a `pcall` guard around the main loop, and
      control-character JSON escaping — real socket-framing and crash-safety bugs, not
      hypothetical. Live-verified via loopback (a real relay/core round trip, ghost spawn and
      clean despawn on client kill). See `agent_docs/verified.md`'s "Emerald Lua adapter sweep
      fixes, live-verified via loopback" and `agent_docs/pitfalls.md`'s partial-send/receive
      NDJSON-framing entry.
- [x] **Real non-loopback two-peer test** — two real BizHawk instances, two real cores, one
      real relay, closing the sweep's "Emerald not yet live-verified outside loopback" gap.
      Along the way, diagnosed a real launch-time mistake (double-clicking `EmuHawk.exe`
      directly skips `MESHGHOST_BRIDGE_PORT`, so a second instance silently shares the first
      core's bridge) rather than a code bug — see `agent_docs/pitfalls.md`'s "Running two
      instances of the same emulator/game silently collide on a shared default port". See
      `agent_docs/verified.md`'s "Real two-peer Emerald test, non-loopback" entry.
- [x] **Archipelago ROM compatibility investigation** — this adapter had only ever been
      verified against a vanilla ROM; a real Archipelago-patched ROM broke it in four distinct,
      separately-found-and-fixed ways, all confirmed live and cited to the exact ROM-diff/
      memory-scan evidence in `agent_docs/verified.md`:
      1. `CB2_Overworld` recompiles to a different address under Archipelago's patch, closing a
         "ghost never renders" gap (`avatar_scan_probe.lua`/`battle_probe.lua`).
      2. Brendan/May sprite tile and palette data also relocates (a different offset from (1) —
         found by direct ROM-byte comparison, not assumed to share one shift).
      3. `gObjectEvents`/`gPlayerAvatar` also relocate — found via a four-stage live
         investigation (`avatar_scan_probe.lua` → `avatar_hexdump_probe.lua` →
         `avatar_array_probe.lua` → `avatar_verify_probe.lua`, all now committed as a reusable
         template for a future address shift).
      4. A timing bug in the fix for (3): resolving the address shift once at script load could
         permanently latch onto the wrong (vanilla) offset if the script loaded during the
         intro cutscene, before the player's object event existed yet — fixed by retrying every
         frame until found instead of once.
      Each of the four has its own dated `agent_docs/verified.md` entry (search
      "Archipelago-recompiled CB2_Overworld", "decode to garbage", "Archipelago-relocated
      gObjectEvents", "avatar-detection timing bug").
- [x] **Gender-read timing gap**: `readLocalGender()` resolved gender once per session, gated
      only on a save pointer being non-null — not on character creation actually having
      finished, since every prior test happened to run against an already-created save. Fixed
      by also gating on `inOverworld()`. See `agent_docs/verified.md`'s "Gender read correctly
      deferred past character creation on a fresh save".
- [x] **Local dev/testing tuned for instant feedback**: `dev-scripts/run-core-*.bat` (all
      three games) changed from a 200ms interpolation delay to `-interp=0ms -min-send=10ms` —
      local loopback testing has no real network jitter to smooth over, and delay was actively
      hiding real timing bugs (see the next item). A new `-min-send`/`min_send` flag was added
      to `cmd/meshghost` (`Core.MinSendInterval` already existed as a field, just wasn't
      exposed). `run-core-emerald-trail.bat` keeps a real 200ms delay specifically for the
      exact-trail loopback mode, which needs visible lag or the ghost renders invisibly on top
      of the player. See `dev-scripts/README.md`.
- [x] **Sub-tile glide bug, found once the network buffer above stopped hiding it**: live
      measuring each step's glide duration (an Emerald-only mechanism, self-correcting since
      2026-08-11) conflated ordinary tap-then-pause play with genuine slow steps, and a
      same-day attempt to gate that on matching `anim` was itself disproven by live data.
      Reverted to plain fixed per-anim constants (16 walking / 8 running frames), justified by
      a per-frame raw-position trace showing zero real variance across dozens of steps. A
      parallel dead end in the same investigation — `playerScreenPos()` appearing frozen across
      a walked tile — turned out to be pokeemerald's real screen-locked-player/scrolling-world
      camera behavior, not a stale address. See `agent_docs/verified.md`'s "Emerald walk/run
      sub-tile glide" entry and `agent_docs/pitfalls.md`'s "Reconstructing continuous motion
      from discrete, throttled position samples" entry for the full three-attempt history.
- [x] **Loopback ghost offset/exact-trail modes**, generalized to TEVI and Pseudoregalia's own
      remote-ghost placement the same day — see each adapter's own README/pitfalls entries.
- [ ] **Surf, Mach Bike, Acro Bike, ledges, and Mach Bike rail sections**: the ghost snaps badly
      on all of these today, since `getLocalState()`'s anim classification and
      `STEP_DURATION_FRAMES` only cover walking/running/idle. Real, cited detection source
      found (not yet live-verified): `pokeemerald`'s `include/global.fieldmap.h:288-295` —
      `PLAYER_AVATAR_FLAG_MACH_BIKE`/`_ACRO_BIKE`/`_SURFING`/`_FORCED_MOVE` are bits on the same
      `PlayerAvatar.flags` byte already read for the dash bit, so no new address is needed, and
      the shift should carry over from the already-working `avatarAddrOffset` detection — still
      needs an on-screen bitfield check per this project's own rule. Real per-tile timing for
      each mode still needs live measurement. A combined probe
      (`adapters/pokemon/emerald/surf_bike_probe.lua`) is ready; not yet run. Fishing rod (a
      stationary action, not a movement speed) is a separate, smaller follow-up.
- [ ] **VRAM/sprite injection investigation** (`agent_docs/ideas.md`) — draw-via-VRAM-write
      instead of `gui.drawPixel` overlay, found via the `GBA-PK-multiplayer` reference project
      (CC BY-NC 4.0, `licensing.md`). A 5-stage test plan is agreed; Stage 1 (read-only vanilla
      probe) not started. Per `agent_docs/ideas.md`'s own stated convention, an idea is
      committed by moving it into `agent_docs/plans.md` with a phase number, not directly into
      a phase file's task list — this item is listed here as a forward-looking note for what
      Phase 8 will pick up next, not a claim that it has already graduated.

## Notes

- Every fact cited above already has its own `agent_docs/verified.md` entry with the real
  source/citation — this file doesn't re-derive anything, it's the phase-level index pointing
  at that evidence, matching how Phase 6/7 cite `verified.md` rather than duplicating it.
