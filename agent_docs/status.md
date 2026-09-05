# Current status

**Active phase: 9 — Crystal, with Emerald reopened for Fly and the boat.** This file is an index of what
is open right now: **one line per item, each carrying the date it was last re-checked, and an item dated
more than 2 days before this file's last commit fails preflight** — at this project's pace, 2026-08-31 is
already not current on 2026-09-02 (user's call). At the start of a session re-date what is still current and move the rest to `plans.md`,
`ideas.md`, the adapter's `UNVERIFIED.md` or `risks.md`; a quiet repo does not go red, because age is
measured against this file's own last commit. Records are never listed here — `verified.md`, the phase
files and each `VERIFIED.md` hold them. Why one line and a date, not a total cap: `claude-md-cap.md`.

## Open now

- 2026-09-04 **The vanishing player SFX are FIXED: every ghost stole the player's audio attenuation listener (cause and Lua fix user-confirmed); the shipped C++ rewrites the call instead and is UNWATCHED** -- `pseudoregalia/VERIFIED.md`, `UNVERIFIED.md`.
- 2026-09-04 **Ghosts are AUDIBLE and should not be: confirmed by ear, parked as future work by the user's call -- silent by default with an opt-in setting; the silence clause covers one sound today** -- `ideas.md`, the SILENCE CLAUSE.
- 2026-09-04 **Pseudoregalia CONFIRMED on screen: a display name with quotes reaches the nametag whole (the JSON escape fix), and a zip of two recordings plays as two ghosts; the title-screen gate from the same session is still unwatched** — `pseudoregalia/VERIFIED.md`, `UNVERIFIED.md`.
- 2026-09-03 **Pseudoregalia: the player's own SFX go quiet while a ghost is audible (user-reported, not diagnosed) — the ghost is a real player pawn, so both a missed silence-clause path and Unreal sound CONCURRENCY stealing the player's voices fit** — `pseudoregalia/UNVERIFIED.md`.
- 2026-09-04 **v1.1.0 SHIPPED. Three things wait on the user's eyes in Pseudoregalia: a 3s chaser should now LOOK 3s behind (ADR 0049), a recording should start at the first real frame rather than in the menu, and the player's own SFX going quiet near a ghost is OPEN and undiagnosed** — `pseudoregalia/UNVERIFIED.md` is the queue, newest first.
- 2026-09-03 **`FuzzEverything` fails locally on Windows within ~15s of a real campaign — ephemeral-port exhaustion in the harness, reproduced on an unmodified tree; the corpus file it writes is noise, not a finding** — `testing.md` Traps.
- 2026-09-03 **Emerald: a peer on a bike shows only when YOU are on one too — the spawned tier wears the LOCAL player's graphic, because the peer-graphic path is off pending a 32px OAM/subsprite fix; reads as intermittent, is deterministic** — `emerald/UNVERIFIED.md`, `emerald/FLAGS.md`.
- 2026-09-03 **Both Pokemon adapters' JSON decoders were fixed from measurement and are UNWATCHED: Emerald gained a depth cap (it followed 5000 levels), Crystal now decodes `\uXXXX` instead of substituting `?`** — each adapter's `UNVERIFIED.md`; `phases/phase8.md`, `phase9.md`.
- 2026-09-04 — **All four adapter fuzzers now exist and are path-filtered per adapter.** Pseudoregalia's found that a whole-string key search is shadowable three ways (raw `orientation`, `prev`+omitempty, sorted map keys); fixed by scoped reads, plus ten unguarded narrowings bounded — `agent_docs/phases/phase7.md`, 2026-09-04.
- 2026-09-04 — **OPEN, unconfirmed:** chaser ghosts may spawn/despawn unintentionally -- cycling back/forth on ghosts 4-7 while the player WALKED IN A CIRCLE (second-hand; not a cap, and not the area filter). First fork is free: diff the core's admit/drop log against the adapter's spawn/release — `adapters/pseudoregalia/UNVERIFIED.md`.
- 2026-09-05 — **The recording indicator's shapes are CONFIRMED pixel-aligned (ShareX zoom) and BAKED as defaults; one look left: a launch with no tuning file draws the same** — `pseudoregalia/VERIFIED.md`, `UNVERIFIED.md`; the nametag's numbers are live-tunable too now.
- 2026-09-05 — Replay hotkeys: chords-only is the open half; the indicator half shipped 2026-09-05 (ADR 0052) — `ideas.md`.
- 2026-09-05 — **A property write changes what a component HOLDS, not what it DRAWS**: this build has no `SetText`/`MarkRenderStateDirty`, and nametags only work because they rewrite their transform every tick — `agent_docs/pitfalls/by-lesson.md`.
- 2026-09-04 — **FIXED, built and deployed, UNWATCHED: a ghost's sword is now mirrored from the peer's flag**, so a clip recorded before the pickup should show none — `adapters/pseudoregalia/UNVERIFIED.md`.
- 2026-09-04 — **FIXED, UNWATCHED:** world-spawned VFX (glow, dust, bursts) are destroyed at release instead of stranded; a `VFXOFFSET` log now measures the offset-poisoning half — same queue.
- 2026-09-04 — A FROZEN-PLAYER state (item popup, pause menu, likely any modal) freezes the pawn but not the fields we send: 110s of `h=550 v=-290` measured, so a ghost run-falls on the spot AND a chaser converges onto the frozen player. No sampled field marks the state, and the chaser half needs the signal to reach the CORE (so, an ADR). **Blocks `chaser_contact`** (ADR 0047): with contact on, a pause menu would park the player inside a damaging ghost — same queue.
- 2026-09-04 — Pseudoregalia's DLL was rebuilt with 42 reworked call sites and is **UNWATCHED**; nothing should look different, which is why it needs a look — `adapters/pseudoregalia/UNVERIFIED.md`.
- 2026-09-03 **The virtual clock is partly in: root, recorder flush and send-rate converted, `awaitTick` interruptible, preflight ratchet armed; the due-wait SLEEPS are still wall-clock pending an advance-until-quiescent helper** — `phases/phase10.md`, `ideas.md`.
- 2026-09-03 **Phase 11 replays: recording, playback and the chaser pack CONFIRMED ON SCREEN in Pseudoregalia (first time any of it has been watched); that session ran the pre-`73615c56` client, so the cosmetic-flag fix is NOT covered by it** — `verified.md`, `phases/phase11.md`, ADR 0047/0048.
- 2026-09-03 **Phase 11 follow-ons still unwatched: split times, anchors, adapter-side contact damage, an offline client mode, and replay/chaser on the other three adapters** — `phases/phase11.md`.
- 2026-09-03 **Two shipped settings do nothing: `ghost_collision` reaches no adapter, nametags reach one of four. SEEN LIVE on Emerald in a two-client session — a spawned ghost is solid and blocks the player**; for that game the mechanism already exists (`freeGhostCollision`, behind a dev flag) and only the `session_policy` wiring is missing — `plans.md`, "Settings: defined once, honoured everywhere".
- 2026-09-05 **RUNNING: the Pseudoregalia rig is up and left up by the user's call** — relay on `127.0.0.1:7777`, two fake peers (parchment default, red), the game closed between looks; rig setups and savestate slots: `running-the-rig.md`, "Rig notes".

## Where the rest lives

What the user has not confirmed, per game: each adapter's `UNVERIFIED.md`, whose "This run" block is
what to watch next. Known gaps and assumptions: `risks.md`. Unscheduled ideas: `ideas.md`. The roadmap:
`plans.md`. The running log per phase: `phases/README.md`. Confirmed facts: `verified.md` and each
`VERIFIED.md`. Lessons: `checklists/`, filed via `pitfalls.md`.
