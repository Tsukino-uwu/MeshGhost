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
- 2026-09-04 — Replay hotkeys: an in-game RECORDING INDICATOR is designed (red dot, top right, config-toggled) and unbuilt; needs a core->adapter state message, so an ADR — `ideas.md`. Chords-only is the other open half. The third complaint, that the log did not say whether a record toggle STARTED or STOPPED, is fixed: `ReplayControl` returns what it did.
- 2026-09-04 — **OPEN, user- and tester-reported:** dust VFX land in wrong positions after a replay ghost SEAMS — every seek (restart/rewind/fast-forward), a loop, and a recorded gap all drop and re-admit the peer (`core/replay.go`'s `seam`), *"somewhat related to the height of ghost sybil when it despawns"*. Lead, unmeasured: the ghost-effect exclusion dies with the `remotes` entry while the component outlives it, so a despawning ghost's dust can poison the file-scope `observed_world_offset_z` — `adapters/pseudoregalia/UNVERIFIED.md`.
- 2026-09-04 — Pseudoregalia's DLL was rebuilt with 42 reworked call sites and is **UNWATCHED**; nothing should look different, which is why it needs a look — `adapters/pseudoregalia/UNVERIFIED.md`.
- 2026-09-03 **The virtual clock is partly in: root, recorder flush and send-rate converted, `awaitTick` interruptible, preflight ratchet armed; the due-wait SLEEPS are still wall-clock pending an advance-until-quiescent helper** — `phases/phase10.md`, `ideas.md`.
- 2026-09-03 **Phase 11 replays: recording, playback and the chaser pack CONFIRMED ON SCREEN in Pseudoregalia (first time any of it has been watched); that session ran the pre-`73615c56` client, so the cosmetic-flag fix is NOT covered by it** — `verified.md`, `phases/phase11.md`, ADR 0047/0048.
- 2026-09-03 **Phase 11 follow-ons still unwatched: split times, anchors, adapter-side contact damage, an offline client mode, and replay/chaser on the other three adapters** — `phases/phase11.md`.
- 2026-09-02 **The post-review run is DONE on all four games; Crystal's and Emerald's interp verdicts were judged on the broken relay and want a re-run on the fixed one** — each queue's "This run" block; ADR 0044.
- 2026-09-02 **The review's connection limiter hid `WriteUnreliable`: every relayed quic/udp state rode the reliable stream until `341a768`; watched fixed on TEVI, Pseudoregalia and the Pokemon games unwatched since** — `verified.md`, "The limiter hid WriteUnreliable".
- 2026-09-02 **Emerald Fly is bandaged, not finished; the boat is built and never watched; rails are unbuilt** — `emerald/BANDAGES.md` §4, `emerald/UNVERIFIED.md`.
- 2026-09-02 **Emerald ships spawned -> OAM -> drawn (user's call); three tile leaks and a double-free found and fixed with a crowd, watched clean; OPEN: the attach nametag burst (core never prunes names, adapter hello times out), rung churn, drawn clipping under a text box unexercised** — `emerald/UNVERIFIED.md`.
- 2026-09-02 **Crystal's next run: hop a ledge THEN cast a rod in one session (shared vtile `$fc`); reproduce the savestate-load crash; Teleport is the last unbuilt action class** — `crystal/UNVERIFIED.md`.
- 2026-09-03 **Two shipped settings do nothing: `ghost_collision` reaches no adapter, nametags reach one of four. SEEN LIVE on Emerald in a two-client session — a spawned ghost is solid and blocks the player**; for that game the mechanism already exists (`freeGhostCollision`, behind a dev flag) and only the `session_policy` wiring is missing — `plans.md`, "Settings: defined once, honoured everywhere".
- 2026-09-02 **The port walk's dead end (a live child on a port the walk left): fixed in all four launchers and the template; reproduced and recovered on TEVI, UNWATCHED on Pseudoregalia, Emerald and Crystal** — each adapter's `UNVERIFIED.md`.
- 2026-09-02 **Pseudoregalia open faults: the sword's mid-air snap, the black flash on spawn, two unattributed crashes, `curve catmull-rom` crashing both instances** — `pseudoregalia/UNVERIFIED.md`.
- 2026-09-02 **Pseudoregalia crowds: step 2 (reflection cache, −59% tick) and the re-run ladder are UNWATCHED; `ls_rest` is the next split** — `crowd-limits.md`.
- 2026-09-02 **`DefaultSendHz` is 15 everywhere; watched on Pseudoregalia, Crystal and TEVI; the INTERP ladder on the WORST-CASE proxy (the only one that counts since 2026-09-02): 450ms CONFIRMED on TEVI, Pseudoregalia and Emerald, and on Crystal by the user's explicit exception; 450ms ships everywhere (ADR 0046) (their earlier numbers were milder links or the broken relay)** — each adapter's `UNVERIFIED.md`.
- 2026-09-02 **Relay cross-area filtering is UNWATCHED on screen; Emerald seam crossings are the check** — ADR 0041, `emerald/UNVERIFIED.md`.
- 2026-09-02 **Loss cover (ADR 0045) WATCHED on Crystal: A/B on one netsim seed, cover off is worse, no teleport at any interp; shipped 250ms stands (loopback overstates by one-way latency), 275–300ms to be re-judged with two real clients** — `crystal/UNVERIFIED.md`.
- 2026-09-02 **Go side: the `internal/e2e` port reservation TOCTOU flakes under `-race`; `encoding/json` is ~58% of relay per-state CPU; `curve catmull-rom` bends on uneven spacing** — `testing.md` Traps, `scaling.md`, `core/curvespacing_test.go`.
- 2026-09-02 **Crystal is AT Lua's 200-local ceiling (`luac` refused a 201st on 2026-09-02; new switches ride on existing tables) and Emerald is 1 from it; modules are the fix** — `emulator/CLAUDE.md`, `ideas.md`.
- 2026-09-02 **Nothing is running** — every rig was verified down at the end of 2026-09-02 (relay, proxy, cores, both emulators; the temporary root `config.json` deleted); rig setups and savestate slots: `running-the-rig.md`, "Rig notes".
- 2026-09-02 **The 2026-09-02 doc pass is DONE, parts A–D; what changed, what was measured and what was left alone: `doc-history.md`.** Ages out of here on its own.

## Where the rest lives

What the user has not confirmed, per game: each adapter's `UNVERIFIED.md`, whose "This run" block is
what to watch next. Known gaps and assumptions: `risks.md`. Unscheduled ideas: `ideas.md`. The roadmap:
`plans.md`. The running log per phase: `phases/README.md`. Confirmed facts: `verified.md` and each
`VERIFIED.md`. Lessons: `checklists/`, filed via `pitfalls.md`.
