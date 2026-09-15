# Chaser contact damage (Pseudoregalia), closing the ghost-attack leaks, freezing during dialogue

Planned 2026-09-15. **Status as of 2026-09-15 (evening): Part D is DONE and committed (`e546d38c`,
ADR 0068). Parts A, B, C and E are NOT started; each begins with a probe in a running game, and Part
A's instrument is written and parked at `adapters/pseudoregalia/probes/probe_hitlist/` (never loaded).
The next session starts at Part A step 1. This file is deleted when the last part lands.**

## Context

Chaser ghosts (`core/chaser.go`) follow the player the way Badeline chases Madeline in Celeste. Right
now, touching one does nothing. The goal is an opt-in config toggle that makes a touch hurt or kill,
which turns the chaser into a game mode.

Chasers are local only and never go on the network, so the toggle only ever affects the player's own
game.

The contract already reserves this exact hook: `session_policy.chaser_contact` (`contract.md`,
ADR 0047). The contract calls it "the ONE effect a cosmetic ghost may ever have". It needs a per-game
ADR and the user's on-screen confirmation, and no adapter builds it yet.

A second problem is already live and breaks the contract. Cosmetic ghosts must never damage or
interact with anything (`contract.md`). Today only the sword swings are stopped, by
`GHOST_PREHIT_PLAYER` in `Plugin.cpp`. That flag pre-fills the ghost's `hitActorsArray` with the
player. The user still sees the following:

- **Sunsetter** hurts the player and other ghosts.
- **Strikebreak** hurts the player and other ghosts.
- Ghost attacks **hit switches and levers**.

This leak gets fixed first. Otherwise "chaser contact off" isn't actually harmless, and a chaser's own
Sunsetter becomes a second damage path that nothing controls.

Decisions made with the user:

- `chaser.contact` becomes `"off" | "hurt" | "kill"`.
- **hurt** is exactly what an enemy's touch does in-game.
- **kill** is a guaranteed death.
- Chasers also freeze during NPC dialogue and note reading, the same way they do for the pause menu
  and item pickups.

## Corrections after checking the code (2026-09-15, later the same day)

Three premises below were stale when written; the parts that rest on them start from these facts:

- **`player_frozen` IS sent** by the C++ mod (`Plugin.cpp`, from `PauserPlayerState`, since
  2026-09-05) for the pause menu and the item-pickup popup. The `UNVERIFIED.md` "blocker" entry of
  2026-09-04 predates that. Part E's "first confirm the adapter sends it" is answered; what stays
  open is the I6 watch item (pause about ten seconds with a chaser running, unpause, it resumes
  where it left off).
- **`render_remote.cosmetic` IS emitted** by the core on every chaser and replay frame. The adapter
  parses neither it nor `session_policy` at all; Part E's step 1 is a new handler, not a fix.
- **No grace window exists** in the core, and none is needed there: a seam is a `despawn_remote` and
  a fresh spawn the adapter already sees, and a player respawn is the adapter's own fact. The window
  is adapter-side (ADR 0068).

## Part A: make every ghost attack inert (bug fix, first)

1. **Measure each leak.** The instrument is written and parked: `probes/probe_hitlist/Scripts/main.lua`
   (read-only; loads over the MeshGhostScratch slot, `PROBES.md`). It has never run, so its first run
   is also its self-check; read `/write-a-probe` and `checklists/before-a-probe.md` before loading it.
   Put a loopback ghost 2 tiles to the side. For Sunsetter, for Strikebreak and for a lever hit, find:
   - which actor performs the query (the ghost pawn, a spawned hitbox, or a projectile actor);
   - which array or flag records the victims;
   - how a switch or lever receives the hit.

   Start from the hitActorsArray mechanism in `documentation.md`. The hypothesis to test is that these
   attacks use a separate actor or array that `GHOST_PREHIT_PLAYER` never touches. The probe reads
   every pawn's `hitActorsArray` and both health locations; "no array changed and the health moved
   anyway" is itself the answer, and the next instrument is then `probe_leakcount`'s class census at
   the moment of the hit.
2. **Fix the cause, one path at a time.** Extend the pre-mark idea to that actor or array, covering the
   player, every other ghost and interactables. Use the game's own attack-owner check instead, if one
   exists. Never skip the attack montages: the user wants all animations (`BANDAGES.md`).
3. **Record it.** Add one flag row per new mechanism in `adapters/pseudoregalia/FLAGS.md`, and put the
   measurements in `UNVERIFIED.md`. The user confirms each leak is closed on screen: no HP loss, no
   hurt reaction on the other ghost, and the lever stays unmoved.

## Part B: find how the game hurts and kills the player (measure, no code yet)

1. **Probe an enemy's contact hit on the player** and find what actually lowers HP. Calling
   `BPI_PerformDamageResponse` only plays the reaction; HP didn't move around it.
   - Settle where `CurrentHp` lives. The docs disagree: one place says the GameInstance, a later one
     says the pawn's `BP_HpHitable`.
   - **Lead from a tester (unmeasured, goes to `UNVERIFIED.md` until probed):** everything
     health-related is handled through `BP_HpHitable`, and every other health value is only a copy
     kept for convenience. If that holds, the GameInstance `CurrentHp` is a mirror. Hurt and kill
     would then go through a `BP_HpHitable` function, never a field write.

     Test it in this order:
     1. Dump `BP_HpHitable_C`'s UFunctions with `probes/probe_dump/`.
     2. On an enemy contact hit, check whether the component's HP changes first and the
        GameInstance copy follows a tick later.
     3. Check whether the ghost's own `BP_HpHitable`, which `GHOST_DECOUPLE_SHARED_STATE` stashes,
        is what Sunsetter and Strikebreak hit on other ghosts.
   - Record the i-frames after a hit.
2. **Probe the death path.** Find what runs at HP 0, and whether the game has its own kill path (a
   hazard or instakill volume) that "kill" can trigger. Let the game do the work: trigger its own
   damage and death, and never write HP directly.

## Part C: freeze the chaser during NPC dialogue and note reading

Today `player_frozen` (ADR 0053) covers the pause menu and item pickups. Talking to an NPC or reading a
note doesn't count, so chasers keep closing in. With contact on, they would hit a player who can't
move.

1. **Probe what marks these states on the player pawn.** Candidates to test:
   - `DialogueCam` becoming the active view target;
   - a dialogue or reading flag;
   - an input or movement lock the game sets.

   Measure the start and end of both an NPC conversation and a note. Check each against the pause and
   item signals the adapter already uses.
2. **Feed the measured signal into the same `player_frozen` path.** The core needs no change, because
   gameplay time simply stops.
3. **The user confirms on screen:** during a conversation and a note, chasers stop in place. They
   resume when the player regains control, with no hit on resume.

## Part D: the contract revision (Go side) — DONE 2026-09-15, commit `e546d38c`

What shipped, so the adapter work reads the right shape:

- ADR 0068 (`agent_docs/adr/0068-...`), indexed in `architecture.md`. `chaser.contact` is
  `"off" | "hurt" | "kill"`; a legacy bool `true` reads as `"hurt"`, `false` as `"off"`; any other
  value is refused (the flag exits at launch, a saved file keeps its old value and says so).
- `session_policy.chaser_contact` carries `"hurt"` or `"kill"` and is absent when off or when the
  chaser is disabled. `"enabled"` is retired; no adapter ever read it.
- The grace window is **adapter-side**, no wire change: it starts from the chaser spawn the adapter
  already sees (a seam is a despawn plus a fresh spawn) and from the player's own respawn. Its
  length is measured in Part E.
- Root `CLAUDE.md` unchanged (the user's call): the ADR explains that contact triggers the game's own
  damage path exactly as an enemy does and writes no state.
- `core.ChaserContact` (`core/chaser.go`), the string flag, the bool-or-word file reader
  (`cmd/meshghost/main.go`), hot reload, the policy push, the five shipped `config.json` files,
  `contract.md`, `bridge.go`, the template `PROTOCOL.md`/`README.md`, `docs/config.md`.
- Tests green including race and the two e2e runs; the e2e chaser test starts the real binary with
  `-chaser-contact kill` and asserts the word arrives.

## Part E: the Pseudoregalia adapter

1. **Read the policy.** Parse `render_remote.cosmetic` and `session_policy.chaser_contact` in
   `Plugin.cpp`. Neither is read anywhere today (five handlers, none for `session_policy`; the
   message arrives in the same TCP segment as `bridge_ready`, `Plugin.cpp` ~27968). The value is the
   word `"hurt"` or `"kill"`, or the field is absent. Hot reload must update both.
2. **Contact test.** Each tick on the game thread, test the player capsule against each chaser's last
   applied position, using the capsule's radius and height. This is an overlap, never collision, so
   chaser collision stays off.
   - Only chasers (`chaser:` ids) qualify, never real peers or replays.
   - Skip while `player_frozen` is set (pause, items, dialogue, notes).
   - Skip during the grace window after a chaser spawn and after the player's respawn; its length
     is measured here, not fixed by the ADR.
   - Skip during the player's i-frames or death.
   - `player_frozen` IS sent (see the corrections above); the one open item is I6 in `UNVERIFIED.md`
     (pause about ten seconds with a chaser running, unpause, it resumes where it left off).
3. **Apply the damage** through the path measured in Part B:
   - hurt calls the game's own contact hit;
   - kill uses the game's own death or instakill path.

   Gate it behind a compiled flag plus a `chaser_contact` dev toggle file for the hot-reload loop.
   Build with `dev-scripts/build-pseudoregalia.bat` and deploy to the live installs.
4. **Records:**
   - an `FLAGS.md` row;
   - the mechanism in `SYNCED.md` and `documentation.md`;
   - `UNVERIFIED.md` until the user confirms;
   - a README build-story step once confirmed;
   - how the leaks were found, in `pitfalls.md`;
   - back-port to `adapters/_template/README.md` the lesson that cosmetic ghost attacks must be inert
     on every attack path, interactables included;
   - a phase-file entry.

## Verification

- **Go side (verified by Claude): done 2026-09-15** — build, vet, gofmt, the package tests, the race
  run and the two e2e tests, all green on the committed tree. CI runs when the user pushes.
- **Live (the user confirms on screen):** Claude starts the relay, core and scaffolding hidden, and
  asks before launching Pseudoregalia. The checks are small steps, in order:
  1. A loopback ghost uses Sunsetter, Strikebreak and swings next to the player, another ghost and a
     lever: no damage, no reaction, and the lever doesn't move.
  2. With `contact: "off"` and a chaser, a touch does nothing.
  3. With `"hurt"`, a touch looks exactly like an enemy's touch (reaction, HP loss, i-frames), with
     no repeated hits.
  4. With `"kill"`, the game's own death and respawn play, with no instant re-hit on respawn.
  5. In the pause menu, NPC dialogue and note reading, the chaser freezes while closing in and deals
     no damage.

  Afterwards, close every process Claude started and verify they are gone.
