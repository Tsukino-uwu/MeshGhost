# Chaser contact damage (Pseudoregalia), closing the ghost-attack leaks, freezing during dialogue

Planned 2026-09-15.

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

## Part A: make every ghost attack inert (bug fix, first)

1. **Measure each leak.** Use a Lua probe through the MeshGhostScratch slot with hot reload
   (`/write-a-probe`, `agent_docs/checklists/before-a-probe.md`). Put a loopback ghost 2 tiles to the
   side. For Sunsetter, for Strikebreak and for a lever hit, find:
   - which actor performs the query (the ghost pawn, a spawned hitbox, or a projectile actor);
   - which array or flag records the victims;
   - how a switch or lever receives the hit.

   Start from the hitActorsArray mechanism in `documentation.md`. The hypothesis to test is that these
   attacks use a separate actor or array that `GHOST_PREHIT_PLAYER` never touches.
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

## Part D: the contract revision (Go side)

1. **Write a new ADR** in `agent_docs/adr/`, indexed in `architecture.md`. It covers:
   - `chaser.contact` changes from a bool to `"off"|"hurt"|"kill"`;
   - `session_policy.chaser_contact` carries `"hurt"` or `"kill"`, and stays absent when off;
   - a legacy bool `true` maps to `"hurt"`;
   - a grace window after a chaser seam or respawn, so a chaser that reappears on the player doesn't
     hit instantly;
   - how this carve-out fits root `CLAUDE.md`'s "nothing that ships writes game state". Either reword
     that rule or add a pointer, **only with the user's yes** and within the 200-line cap.
2. **Code changes:**
   - `core/core.go`: the `ChaserContact` type.
   - `core/settings.go` and `cmd/meshghost/reload.go`: hot reload.
   - `cmd/meshghost/main.go`: the `-chaser-contact` flag and its help text.
   - `core/bridgeserve.go`: emit the mode.
   - `bridge/bridge.go`: the field doc.
   - `packaging/release/games/pseudoregalia/config.json`: `"contact": "off"`.
   - `contract.md`: document the mode.
3. **Tests:**
   - bool-to-mode config parsing, including a legacy `true`;
   - the policy is absent when contact is off or the chaser is disabled;
   - extend `internal/e2e/chaser_e2e_test.go`;
   - keep the existing "contact ships off" test.

   `dev-scripts/run-gotests.bat` must be green, plus `run-gotests-race.bat` if settings reload is
   touched.

## Part E: the Pseudoregalia adapter

1. **Read the policy.** Parse `render_remote.cosmetic` and `session_policy.chaser_contact` in
   `Plugin.cpp`. Neither is read anywhere today. Hot reload must update both.
2. **Contact test.** Each tick on the game thread, test the player capsule against each chaser's last
   applied position, using the capsule's radius and height. This is an overlap, never collision, so
   chaser collision stays off.
   - Only chasers (`chaser:` ids) qualify, never real peers or replays.
   - Skip while `player_frozen` is set (pause, items, dialogue, notes).
   - Skip during the post-seam grace window.
   - Skip during the player's i-frames or death.
   - First confirm the adapter really sends `player_frozen`. The README says it does, but
     `UNVERIFIED.md` still lists it as the blocker.
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

- **Go side (verified by Claude):**
  - `run-gotests.bat` green, plus the race run if concurrency is touched;
  - check CI with `gh run list -L 5` after the commit.
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
