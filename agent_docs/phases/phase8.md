# Phase 8 — Emerald, dedicated (post-Phase-5.5 ongoing work)

> **A dated record. Package paths here predate the 2026-08-17 module move** — read any
> `internal/X` as `X/`. Why, and what became of `internal/README.md`: [../README.md](../README.md).
> **Adapter paths predate the 2026-08-25 folder rename** — read any `adapters/bizhawk/` as
> `adapters/emulator/`. Left as written for the same reason: a phase file records what was true
> while the phase ran.

**Status: LIVE — Emerald's whole running log, appended every session that touches it.** The user
called Emerald **feature complete on 2026-08-21** (`adapters/emulator/pokemon/emerald/VERIFIED.md`):
every way this game moves a character and every field effect it hangs off one is mirrored on all
three tiers — a playable-state milestone, not the end of the work; every adapter here stays open
(the user, 2026-09-06). Fly was taken up again on 2026-08-26 and is built, bandaged and confirmed in
one case; the boat is built and unwatched; rails are not built; the ladder spawned → OAM → drawn
became the shipped default on 2026-09-02. What is open now is in that adapter's `UNVERIFIED.md` and
`agent_docs/status.md`, never here. (This header read "PARKED" until 2026-08-27 and "in progress,
but the peer-state work is closed / REOPENED" until 2026-09-06; the entries below are as written.)

Started 2026-08-14. Numbered next in sequence rather than folded back
into 1–5.5 (which bundled Emerald's adapter work together with building the server/client/core
themselves, since Emerald was the first game) — renumbering 1–5.5 would break the many existing
citations to them across `verified.md`/`pitfalls.md`/`status.md`/`risks.md` for no real gain, so
they stay as-is. Phase 6 (TEVI) and Phase 7 (Pseudoregalia) are unrelated games and keep their
own numbers; this phase is specifically "Emerald keeps getting worked on, on its own, after
5.5 closed" — decided 2026-08-14, see `adapters/bizhawk/pokemon/emerald/README.md`'s "How this adapter
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
      `agent_docs/verified.md`'s "Real two-peer Emerald test, non-loopback" entry. Also cleaned up
      `dev-scripts/`: removed the tracked `run-bizhawk1.bat`/`run-bizhawk2.bat` (couldn't ship real
      personal EmuHawk/ROM paths in a public repo) and the redundant `run-core.bat`, renamed
      `run-core1.bat`/`run-core2.bat` to `run-core-emerald.bat`/`run-core-emerald2.bat` for
      consistency with the TEVI/Pseudoregalia naming, and added two gitignored `.local.bat`
      BizHawk launchers (real paths, set the bridge port explicitly) so this exact mistake can't
      recur silently.
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
- [x] **Relay-safety hardening pass (2026-08-14)** — set as the next priority once TEVI's 6.6/6.7
      wrapped up; not Emerald-specific, but logged here per this file's role as the home for
      cross-cutting infrastructure work done during Phase 8. Full record: the ADR in
      `agent_docs/architecture.md` (search "room-code/version ADR"), `internal/README.md`'s "What
      changed" section, and `agent_docs/plans.md`'s "Room codes / relay safety" section. Short
      version:
      - **Room-code auth**: `hello` carries an optional `room_code`, constant-time-checked
        against the relay's own configured `Server.RoomCode`; empty (still the default) means
        auth stays off. A refused `hello` (bad version, wrong code, game/version mismatch, full
        room) now gets a `reject` message with a reason before the connection closes, instead of
        a bare hangup.
      - **Peer game-version check**: `hello` carries an optional `game_version`, sticky per room
        the same way `game_id` already is. Each shipped adapter reports its own adapter/mod
        version (Emerald `"phase5.5"`, TEVI's BepInEx `PluginVersion`, Pseudoregalia `"phase7.6"`)
        — not a real game/DLC build number, since no cited memory address exists for one in any
        of the three games. Real gap this still leaves open for TEVI specifically: two peers on
        different Steam patch levels or DLC states still aren't caught — see `risks.md`.
        (Those two version strings are the 2026-08-14 values and have since been bumped, as
        designed: Emerald reported `"phase8"` and Pseudoregalia `"phase7.7"` as of 2026-08-17;
        Emerald is `"phase8-spawn"` as of 2026-08-18, bumped with the spawn renderer —
        `ADAPTER_VERSION` in each adapter is the live source, not this line.)
      - **Malicious-peer hardening**: a real remote-OOM in `internal/transport` (unbounded read
        buffer, fixed via `bufio.Scanner` with a real max-token-size enforced during the read),
        read/write deadlines and a relay hello-timeout (none existed before), `Room.Forward` no
        longer holding its lock across a potentially-blocking `Send`, and `internal/core` keeping
        its own roster (from `welcome`/`join`/`leave`) and dropping `state` for any `player_id` it
        never saw announced. New size/length caps on `orientation`, `area_id`, `anim`, and every
        `hello` string field.
      - **Live-confirmed**, not just `go test`: real relay + real client through the actual
        shipped `packaging/release/config.json`, correct-code accept and wrong-code reject both
        confirmed via each process's own log output — see `verified.md`.
      - **Explicit limits recorded, not glossed over**: no TLS (`risks.md`) — a room code crosses
        the wire in plaintext. And a stale (pre-2026-08-14) relay binary silently provides zero
        protection regardless of what a client sends — `packaging/README.md`/
        `packaging/release/README.txt` say plainly that room-code auth needs the relay itself to
        be current.
      - **Same-day follow-up, from user questions**: a rejection previously reached nobody but the
        client's own log — the relay now logs join/leave/reject; `internal/core` logs a connect
        failure once per distinct message, not once per retry. `cmd/meshghost`'s eager `-game`
        path no longer crashes via `log.Fatalf` on the first failed dial — it retries with backoff
        (1s→15s) instead, routed through `ConnectRelayOnAdapterHello`/`relayConnectMu` so a real
        adapter connecting concurrently can't race it into a duplicate dial. A genuinely permanent
        rejection (wrong code, version mismatch) still exits loudly. **Confirmed live**: real
        `meshghost.exe` started before any relay existed, retried silently across ~15s of real
        backoff, then connected the instant a real `meshghost-relay.exe` came up — see
        `verified.md` and the ADR in `architecture.md`.
- [x] **2026-08-14 review/refactor sweep** — a full review/refactor pass across `internal/`,
      `cmd/`, and all three adapters. See the ADR in `architecture.md` (search "same-day
      review/refactor sweep") for the four original behavior-changing decisions and the full fix
      list, plus a follow-up ADR (search "found during live testing of the sweep above") for a
      relay-auto-reconnect gap found live. `pitfalls.md` has the partial-send/receive NDJSON-
      framing pattern found independently in Emerald's Lua and Pseudoregalia's C++, and the "move
      offscreen, never destroy" ghost-lifecycle pitfall. The Lua/Emerald side of this sweep is its
      own task item above; the rest:
      - **Go (`internal/`, `cmd/`)**: all sweep fixes applied, plus a same-day follow-up fix found
        during live testing — a relay that drops *after* a successful connect (crash, restart,
        network blip) previously had no path back to "connected" short of a full client restart;
        `Core` now auto-retries in the background. New regression test
        (`TestRelayDisconnectAutoReconnects`). Live-verified via real binaries (kill relay →
        client retries → new relay → client reconnects automatically) — see `verified.md`.
        **Important operational note, also found live**: `meshghost.exe`/`meshghost-relay.exe`/
        `meshghost-fakeadapter.exe` at the repo root are NOT kept fresh by `go build ./...`/
        `go vet`/`go test` — those compile-check packages but don't overwrite the named binaries
        `dev-scripts/*.bat` launches. Always `go build -o meshghost.exe ./cmd/meshghost` (and the
        other two) explicitly before testing via the `.bat` files.
      - **Pseudoregalia (C++)**: all fixes applied, rebuilt, hash-diff-confirmed deployed to both
        the in-repo packaging copy and the live Steam install. **Live-confirmed working**: ghost
        spawn/follow/animate, no crashes. Unrelated to this sweep, found live during the same
        test: a possible ghost→real-player combat interaction (ghost landing hits despite
        `GHOST_COLLISION_ENABLED = false`, its value on that date; it has been `true` since
        2026-08-15) — logged as a new data point on the existing
        ghost-collision open question in `risks.md`, low priority, not yet investigated.
      - **TEVI (C#)**: all fixes applied (stale-thread generation guard, `TcpClient` disposal,
        real `Destroy()` on ghost/marker despawn, `OnDestroy`/`OnApplicationQuit` bridge close,
        `room_x`/`room_y` range check, `TryGetValue` in place of unguarded `JObject` casts).
        Rebuilt via `dev-scripts\build-tevi.bat`, deployed to both the Steam install and the
        standalone `tevi-14778703` build, hash-diff-confirmed. Two dedicated dual-instance dev
        scripts added: `dev-scripts\run-core-tevi.bat` (port 7778) / `run-core-tevi2.bat` (port
        7779). **Live two-instance testing found and fixed a real bug**: a peer's ghost went
        permanently invisible after the traveling player returned to a zone — root cause was
        `CreateRealGhostVisual` cloning a live character's visual hierarchy mid-transition,
        inheriting a disabled `basesprite` renderer with nothing to ever re-enable it. Fixed
        (`basesprite.enabled` forced true on recreate) and live-confirmed. See `verified.md` and
        `pitfalls.md`'s "Level/scene transitions invalidating cached references" entry.
      - **Docs**: this entry, both ADRs above, and the `pitfalls.md`/
        `adapters/_template/PROTOCOL.md` updates (Pseudoregalia added to the adapter list,
        `extras` documented as load-bearing, `orientation` shown as opaque any-JSON, a
        peer-controlled-data warning added, the TEVI ghost-invisibility entry) are done.
      - **Pseudoregalia despawn-visual/area-transition live-verified, two more real bugs found and
        fixed**: (1) closing the client left a ghost frozen/visible instead of despawning —
        `on_update()` never detected its own bridge connection dying (same bug class as Emerald's
        Phase 3 fix, never ported here); fixed via `release_all_ghosts_parked`, armed by a
        connected→disconnected edge check and drained on the game thread. (2) a core with no
        adapter attached sent nothing to the relay, hit the 60s idle timeout, and the sweep's own
        auto-reconnect kept reconnecting it under a brand-new player id every ~60s — every peer
        would see a leave+join/despawn-respawn cycle once a minute. Fixed via `Core.sendHeartbeats`
        (a 20s `Ping`). Both confirmed live, `main.dll` rebuilt and hash-diff-deployed to both the
        in-repo packaging copy and the live Steam install. See `verified.md`'s three new entries.
      - **This closed every item from the 2026-08-14 sweep's "Not started" list.**
- [~] **Surf/bike/fishing IDENTIFICATION is solved, 2026-08-18 — it is one byte, not a
      classifier.** `sPlayerAvatarGfxIds` gives every special state its own `graphicsId` per
      gender (normal 0/89, Mach Bike 1/90, Acro Bike 63/91, surfing 2/92, underwater 111/112,
      field move 3/93, fishing 137/138, watering 191/192), so the state is readable directly from
      the player's object event rather than guessed from anim plus per-mode step timings.
      Confirmed live for fishing (`probes/fishing_probe.lua`, gfx 89 -> 138 -> 89, with
      take-out-rod / put-away-rod / hooked all playing out in the sprite's `animNum`) — see
      `verified.md`. **What remains is RENDERING it**: a ghost borrows the player's sprite, so it
      can only show the graphic the local player is using; showing a surfing peer while you walk
      needs the sprite built from `gObjectEventGraphicsInfoPointers[gfxId]` (own images/anims/OAM,
      own tiles sized from that entry, palette resolved not inherited). One mechanism for all
      eight states. The original item follows.
- [ ] **Surf, Mach Bike, Acro Bike, ledges, and Mach Bike rail sections**: the ghost snaps badly
      on all of these today, since `getLocalState()`'s anim classification and
      `STEP_DURATION_FRAMES` only cover walking/running/idle. Real, cited detection source
      found (not yet live-verified): `pokeemerald`'s `include/global.fieldmap.h:288-295` —
      `PLAYER_AVATAR_FLAG_MACH_BIKE`/`_ACRO_BIKE`/`_SURFING`/`_FORCED_MOVE` are bits on the same
      `PlayerAvatar.flags` byte already read for the dash bit, so no new address is needed, and
      the shift should carry over from the already-working `avatarAddrOffset` detection — still
      needs an on-screen bitfield check per this project's own rule. Real per-tile timing for
      each mode still needs live measurement. A combined probe
      (`adapters/bizhawk/pokemon/emerald/probes/surf_bike_probe.lua`) is ready; not yet run. Fishing rod (a
      stationary action, not a movement speed) is a separate, smaller follow-up.
- [ ] **VRAM/sprite injection investigation** (`agent_docs/ideas.md`) — draw-via-VRAM-write
      instead of `gui.drawPixel` overlay, found via the `GBA-PK-multiplayer` reference project
      (CC BY-NC 4.0, `licensing.md`). A 5-stage test plan is agreed; Stage 1 (read-only vanilla
      probe) ran 2026-08-14 and is written up in `agent_docs/environment.md`; Stages 2-5 not
      started. Per `agent_docs/ideas.md`'s own stated convention, an idea is
      committed by moving it into `agent_docs/plans.md` with a phase number, not directly into
      a phase file's task list — this item is listed here as a forward-looking note for what
      Phase 8 will pick up next, not a claim that it has already graduated.

## For the README write-up: the workflow arc is part of this phase's story

**Written into `adapters/bizhawk/pokemon/emerald/README.md` as steps 15-17 of its build story
(2026-08-21).** Kept here in full because the README carries the short version. Noted originally at
the user's request 2026-08-18, in their words: *"emerald loading manually, crystal having better probes, and
now emerald solving it all together with automation. we have improved the workflow a lot by going
back/forth and learning new things"*.

The arc across three adapters, which is a real result and not just process trivia:

1. **Emerald, first time**: every probe revision meant a manual emulator relaunch and re-opening a
   script by hand. The work got done, slowly, and the cost was invisible because there was nothing
   to compare it to.
2. **Crystal**: the probes themselves got better — timestamped log files beside each script, a
   heartbeat so a quiet room reads as quiet, logging what a proposed gate WOULD have decided,
   dumping the neighbours rather than the thing being debugged. The method improved; the loop did
   not.
3. **Emerald again, 2026-08-18**: `dev-scripts/bizhawk-dev-loader.lua` closed the loop. One script
   attached at launch, then attach/swap/drop any script by writing one line to a file — no
   relaunch, no GUI, the game undisturbed. Plus `bizhawk-syntax-check.lua`, because a machine with
   no standalone Lua had no way to answer "does this even parse".

**Why it belongs in the build story rather than only in `environment.md`:** the speed-up is not
the agent getting better at Emerald. It is the human leaving the mechanical half of the loop — and
what remains for them, watching the screen and saying what looks wrong, is exactly where every
real bug of that session was caught (the ghost mirroring the player, the console window flashing,
the ghost not appearing). Automating the wrong half would have cost the bugs.

## Notes

- Every fact cited above already has its own `agent_docs/verified.md` entry with the real
  source/citation — this file doesn't re-derive anything, it's the phase-level index pointing
  at that evidence, matching how Phase 6/7 cite `verified.md` rather than duplicating it.

## 2026-08-18 — the spawn session, in full

The longest single session this phase has had: Emerald stopped drawing its ghost and started
spawning one, and roughly half the day's value ended up being the **method and the mistakes**
rather than the feature. Recorded here as the index; each item points at where the detail lives.

### What was built

1. **The adapter spawns instead of draws.** A peer is a real `ObjectEvent` plus a `Sprite`, and
   Emerald's engine draws, animates and walks it — no drawing code. Hidden behind the pause menu,
   correct gender and palette for free. `verified.md`, `README.md` steps 15-21.
2. **A whole test toolchain**, most of it discovered by asking what BizHawk already had:
   the dev loader (attach/swap/drop scripts live, several at once), savestates (10 slots),
   controller input, screenshots the agent can read, a Lua syntax checker, a forward-reference
   checker, ROM swapping, a cheat survey, and a test kit that writes items/badges/repel.
   All in `environment.md`.
3. **World editing.** `probes/watertile.lua` turns a tile into real water on demand, which is what
   makes surf/fishing testable without walking across the region.
4. **Structure.** `adapters/bizhawk/pokemon/`, probes and logs in subfolders, screenshots per game.

### The six bugs the USER found by watching — every one with a healthy log

Listed together because the pattern is the point: **not one of them was visible in the data.**

1. The ghost wore the *player's* animation frames — it had no VRAM tiles of its own, so both
   sprites read the same tiles.
2. Talking to a ghost launched the **slot-machine minigame** — a synthesised object has no script
   template, so the lookup returned garbage and the game ran it.
3. The ghost took one step and froze — the engine sets `heldMovementFinished` but leaves
   `heldMovementActive` set; clearing is the caller's job.
4. It kept up with a run while visibly *walking* — `WALK_FAST` reuses walking frames;
   `PLAYER_RUN` is a different action.
5. It sat a few pixels off the grid — a sprite's screen position is computed once and then driven
   by camera deltas, so it must be placed with the camera at rest.
6. It leaked one **solid** ghost per route crossing — a route boundary is a *connection*, which
   changes the map without rebuilding the world, so a map-based identity check declared a live
   ghost dead. Left alone it would have walled off the route.

### The mistakes I made, and what each taught

These are in `probes.md` and `pitfalls.md` in full; the list matters because several repeated.

- **Assumed instead of checking**, three times in one hour: what a message meant, that being
  blocked proved a tile was water, and that a collision bit was the right way to make water. The
  third *was the thing preventing the feature from working*, and it passed my own test.
- **Misread silence as a result**, four ways: a screenshot taken before the adapter connected; a
  probe that never loaded (a lost backslash); the emulator paused; and then the same misreading
  again an hour after writing it up. A dead probe and a quiet game look identical.
- **Scripted a menu blind** for four rounds and finished on the SAVE dialog — because I inferred
  the screen instead of screenshotting it. Menus vary in *contents* (a fresh save has no
  Pokédex/Pokémon entries) and remember their *cursor* between openings.
- **Left the game in a menu** and ran the next test into it.
- **Wrote a rule down and broke it four minutes later** — documenting is not implementing; change
  the script in the same pass.
- **Lost backslashes through shell heredocs** four times, twice silently enough that a script
  never loaded at all.
- **Overstated a bandage rationale** (`gSprites` "unmeasured" when this adapter's own README said
  otherwise) and **re-opened a settled decision** (treating loopback as second-best when the
  project had settled that in August). Both corrected in place rather than in conversation.

### What is open

- Surf blob: spawned and engine-driven, but offset and mis-coloured. Peer graphics gated off.
- Fishing/underwater companions: unanswered; the rig is set up and needs a minute of play.
- Archipelago: still on the overlay; one run on a patched seed would settle it, blocked only by
  the absence of a save for one.
- Everything from this session that a person has to see: `unverified.md`.

---

## 2026-08-19/20 — peer states finished, and what the two days actually taught

Emerald's peer states are done and user-confirmed: **fishing, surfing, the Mach Bike and the Acro
Bike**, on both tiers, plus ledge hops, the muddy slope, and walk-through ghosts. Per-item evidence
is in `verified.md`; the open leftovers are in `unverified.md`; the traps are in `pitfalls.md`. This
section is the retrospective — the shape of the work, for whoever picks up Crystal, which has none
of it.

### The one rule, stated once

**Every guess was wrong. Every measurement was right first time.** That is not a figure of speech —
it held for the reflection geometry, the bike speeds, the grass, the occlusion, the collision and
the shadow. The measurements that worked all had the same shape: **read what the ENGINE does for the
player, then make the ghost match it.** The guesses that failed all had the same shape too: reason
about what the code ought to do, change it, and ask the user to look.

### Where the time actually went

Not in writing the features. It went into these, and each has an entry in `pitfalls.md`:

1. **A rule that is right for one graphic and wrong for another.** Letting the engine animate a
   moving ghost is correct for walking and wrong for a bike. Scoping a rule to "while moving" was
   scoping it to the wrong thing.
2. **A range that reads as one block and behaves as two.** `0x64..0x8B` interleaves in-place and
   travelling actions. Cut short at `0x83`, or held as one, it broke movement twice.
3. **A value that changes nothing when changed is not a wrong value.** Two rounds of adjusting a
   clip that was never being read. A deliberately-wrong build settles that in one look.
4. **A measurement taken in ONE condition can support two rules.** The engine's grass sprites were
   captured walking downward, which equally supported "the lower tile draws in front" and "the tile
   being entered draws in front". Both were adopted; both were wrong.
5. **A counter placed inside a gated block measures nothing.** 71 laps of riding produced an empty
   column because the counter sat inside a branch gated on the peer standing still.
6. **A consistency check that shares an input with the thing it checks proves only that.** The
   screen-to-tile self-check agreed perfectly while the grid was 8px out.
7. **"Stable" and "correct" are different properties.** `bikeSpeed` is authoritative while riding
   and deliberately zeroed by the muddy slope's own code.

### Three speed sources, none generalising

Worth knowing before touching movement in any Game Freak title: this one game keeps a rider's speed
in three unrelated places — `gPlayerAvatar.bikeSpeed` (Mach), `movementActionId` as `WALK_FAST` (the
slope's forced movement, while bikeSpeed reads 0), and `movementActionId` as **`RIDE_WATER_CURRENT`**
(the Acro Bike, which `AcroBikeTransition_Moving` genuinely moves with `PlayerRideWaterCurrent`).

### What a painted tier costs, in full

The spawned tier gets all of this free by being a real object event. The painted tier needed each
one found and reproduced separately, and finishing one looked exactly like finishing the job:

occlusion behind scenery (BG layers, by OAM priority) · water reflection (flip, negated bob, an
affine ripple read live from `gOamMatrices`, per-pixel metatile coverage) · **tall grass (a SPRITE,
not scenery)** · the surf blob · landing dust · jump shadows.

**That list is the argument for the spawned tier.** Anything the engine can be persuaded to do for a
ghost — the surf blob, the elevation collision rule — is worth real effort, because the alternative
is reproducing it by hand, per effect, for ever.

### Tools that paid for themselves

- `slide=/paused=` in the status line: found three animation faults nothing else could see.
- The stuck-action watchdog: turned "the ghost sometimes freezes" into three named action ids.
- `probes/bikeloop_probe.lua`, `bikeline_probe.lua`, `grasswalk.lua`: scripted riding, counted in
  TILES not frames — a frame-timed route drifts across the map and rides into trainers.
- `probes/goto_map.lua`: warp anywhere, so reaching a state costs nobody's time.

## 2026-08-21 — the OAM tier, and the resource lifetimes it exposed

**Backfilled 2026-09-11 from the commit log.** This file had no entry for its own largest day — 36
commits against this adapter, `7d2fe07f` through `f74a6b87`. The write-ups of the time went to
`status.md` (since curated away), `pitfalls.md`, `verified.md`, `unverified.md` and the README's
steps 27–36, so every fact survived and the day's *shape* did not. Nothing below is remembered;
each item traces to a commit or to an existing `VERIFIED.md` entry.

**The shape is the reusable part: the renderer was built early and worked, and nearly every entry
after it is a fault in something the renderer had to OWN** — tile ranges, sprite slots, engine
handles. A new tier does not fail at drawing. It fails at lifetimes.

### The tier: measured first, then built

- **`7d2fe07f` priced all three tiers before anything was built** — same count, same map, nobody
  moving. At 16 peers all three read 60.0 avg, indistinguishable from a bare emulator, so the tier
  choice is a crowd question and nothing else. At 56: OAM 60.0, painted 39.6. At 150: 10.4 painted.
  **Two invalid attempts came first and both were convincing** — one measured a relay refusing every
  peer at `-max-clients=8` (`drawn=0` printed in the status line throughout, read past twice), the
  other rode a route while synthetic peers orbited a fixed map coordinate, so the painted peers were
  off-screen and nearly free. `fpshold.lua` is what that produced; `fpsride` is the wrong instrument
  for putting two renderers side by side.
- **`97dee809` built the middle rung**: peers with no object slot get a real hardware sprite entry in
  `gMain.oamBuffer[64..119]`, above `gOamLimit`, which the engine's layout pass never writes and its
  VBlank transfer carries to the hardware regardless. Two of the file's own warnings fired before the
  emulator did: five new file-scope locals pushed the main chunk past **Lua's 200-local ceiling**
  (a parse failure, not a runtime one — `bizhawk-syntax-check.lua` caught it on the first compile),
  and the screen anchor had to be *extracted and shared* rather than copied, because it is stateful
  and a second copy puts the same peer in two places. Shipped OFF.

### The comparison harness was wrong before either renderer was

- **`532a0214` — "the choppiness was never the new tier."** Facing was inverted (Emerald has no
  east-facing art; east is west plus the hardware flip, at bit 22 of the animation command). The lag
  was the interesting half: the **shared** glide filter measured peer speed between consecutive
  frames against a stream that arrives in bursts, so it read zero on most frames and collapsed to a
  0.02 tiles/frame floor — unable to follow a player running at 0.25. Measured over an eight-frame
  window instead, using the ring the delay line already kept. **All three non-engine renderers shared
  that filter, so the painted tier had shipped with the same defect and nobody had caught it** — in
  compare mode the painted copy is pinned to the spawned ghost's sprite, which is precisely what
  stopped it showing. Only a third column made it visible.
- **`e92f7e95` pinned the compare copy and stopped judging the renderer by the pipeline.** The
  second "still trailing" report was correct and the histogram put a number on it (aligned for 1243
  standing frames, up to 30px behind mid-run) — but the glide pipeline carries a *deliberate*
  trailing delay reproducing the engine's own step-machine lag, so a copy placed from the glide is
  eight frames behind by design. Position came out of the comparison entirely; what remains
  different on screen is the renderer. See also `d3d1ac9b`: a fixed peer cannot be walked behind a
  building, so it cannot test occlusion.

### Then the lifetimes, four of them, each found live

- **`43843ca9` — a DOUBLE FREE of an OBJ tile range**, and the user-confirmed fix (*"i didn't see
  any of the orange/glitchy things anymore"*, plus 3172 frames of their own recipe scanned with no
  orange spike). Several despawn paths could queue the same range; the first free released our bits,
  the engine allocated that run for the show-mon picture, and the second free cleared the bits out
  from under it. Queueing is idempotent now and the service point refuses to free a range not
  currently marked allocated. **Three earlier theories were measured and rejected first**; what
  found it was logging each gate component per frame rather than reasoning about them.
- **`c10734ed` — never re-use a despawned sprite's tiles same-tick.** The sprite-copy queue executes
  at VBlank, so a copy queued the frame before a despawn still lands *after* it: tiles freed at
  despawn and re-claimed in the same tick get the dead sprite's frame stamped over the new owner's
  load, once, with nothing to reload it. The hardware body did exactly that and rendered as a corner
  of the surf blob. Frees are deferred through the same queue now. Noted in the commit as **the
  fourth meeting with the OAM-lag class that day**, fenced the same way each time.
- **`dd09a996` — the dive black screen was ours**, and it is the day's most quotable result. The
  game hung black with every palette zeroed while the adapter's own logs read perfectly healthy
  underwater. **The bisect is the method and it is cheap**: adapter dropped, fine; spawned tier off,
  fine; blob and bobber off, fine; blob ON bobber OFF, fine; bobber ON, black. Five runs, no theory.
  The cause was our faithful copy of the engine's underwater bobber — a dummy sprite that holds
  another sprite's **index** and nudges it every fourth frame. Safe for the engine, which owns every
  lifetime involved; unsafe for us, who own none. Once the slot was reused it wrote into the
  show-mon's picture. There is no bobber now: a diver's bob is the peer's own offset, already on the
  wire. **This is where `adapters/CLAUDE.md`'s "reproduce the EFFECT, never adopt a handle the engine
  can recycle" comes from.**
- **`06630dab`, `511d5cc8`, `f028a6ca`, `1892f12c`** are the same theme on the surf blob: an orphan a
  mid-surf savestate restores, telling a dismount from a mount by ORDER rather than age, blobs born
  at the destination and parked through jumps, and the hardware tier getting the mount-park its twin
  already had.

### The evening: two hardware effects, one fixable and one not

- **`e200c7bf` — ice, user-confirmed on all three tiers.** A slide is a movement that does not
  animate: `disableAnim` is the bit that survives a movement (`spaused` does not), and **three
  separate things were each undoing it**. The engine also has two reflection kinds and we had one —
  `MB_ICE` is `REFL_TYPE_ICE` with `stillReflection` TRUE, a plain vertical flip with nothing to
  shimmer. (The mechanism named here was corrected 2026-08-27, `8af2364e`: Emerald ice runs
  `ForcedMovement_Slip`, not `_Slide` — right screen, wrong function.)
- **`ea40ddb3` — a dark cave is Window 0, not an overlay.** The engine DMAs each scanline's lit span
  to `REG_WIN0H` every HBlank, so real sprites are clipped for free and only the painted tier — drawn
  after the PPU has finished, where windows no longer exist — shone through. **The gate mattered more
  than the clip**: an inactive buffer reads as all zeroes, "nothing lit anywhere", which would have
  erased the tier on every ordinary map rather than in the cave that motivated it. Confirmed at
  source instead (`gScanlineEffect.dmaDest` must be `REG_WIN0H`, non-zero state). Also recorded:
  `WIN0H`, `WIN0V` and `BLDY` are **write-only and return convincing garbage** while their neighbours
  read fine — the fog investigation nearly built an argument on `BLDY`.
- **The distinction worth carrying forward, and it is the reason both are in one entry**: the flash
  circle is readable data, so it was fixable; the fog is a priority we cannot win, so the OAM tier
  stands down and its peers are painted. **Ask which kind an effect is before assuming either.**

### And the instrument was costing what it measured

**`399f9a4a` — a log line cost four frames, every second, in BOTH Lua adapters.** The whole session
was spent saying the game felt choppy while the frame-rate average read 59.7fps, and both were true:
a per-second mean cannot see a hitch, because ten frames lost inside one second still averages 58.
Measuring the frame-to-frame **gap** found it immediately — and found it in the instrument, where a
probe whose only per-second work was one log line produced one 63–83ms stall every second.
`console.log` appends to BizHawk's GUI console on the emulator's own thread, and every write was
followed by a flush. Buffered and throttled, the same configuration reads 0 hitches, worst gap 17ms.
**This was shipping code, not instrumentation** — and `probes.md` had said "buffer, and flush in
batches" since the drawn tier was built. Both adapters shipped without doing it. *The rule was
written down and then not followed, which is worth more than the fix.*

### Closed at the end of it

`4718a878` **feature complete, in one voice across the docs**, and `ddf41827` parked the adapter with
**the ferry and the rails recorded as assumptions rather than as open work** — a distinction that did
not survive contact on 2026-08-26 (`8af2364e` later corrected the pair to the boat and Fly).
`c0fea4bb` had finished the Acro Bike earlier the same day; `c4017f7d` read every doc against the
code and wrote down the days this story had already missed, which is the ancestor of this entry.

## 2026-08-22 — the adapter did not compile, and nothing would have said so

One commit, `d551da12`, and it is filed here because the failure mode is the expensive part.
`meshghost_emerald.lua` as committed failed with `too many local variables (limit is 200)` — 202
declared names. **In a real session that is a silent non-load**: the adapter never starts, the game
runs with no ghosts, and it reads as a networking fault. `status.md` had the count at 198 and had
asked for consolidation before the next feature; the next feature happened first (`97dee809`, the
previous day, spent five). Fixed by folding seven constants onto two tables — the pattern the file
already used and already documented — back to 197 with headroom. **Compiling is not working**: this
touched live surf-blob code and was queued for a surf before Emerald was next relied on.

## 2026-08-23 — repo-wide, and it reached this adapter's prose

`01cd8e85`, the no-invented-durations rule — the user's call that day was that a vague span of time
never needs saying at all, because everything here is logged against real dates anyway. (Their exact
words are in that commit, and are not quoted here: the phrasing enumerates the banned forms, so
reproducing it trips the very gate the commit installed.) Emerald's own measured figure — "about 10
hours" to the end of Phase 5.5 — is the user's and stays;
vague is the defect, not durations. Logged here because 40 hits were swept repo-wide and this
adapter's files were among them.

## 2026-08-25 — the restructure, as it touched Emerald

Thirteen commits, almost all repo-wide mechanism rather than adapter code; the header at the top of
this file records the rename itself. What actually changed under this adapter: `73936944`
(`adapters/bizhawk/` → `adapters/emulator/`, and three hosts get a rules file — the reason every
path in the entries above reads `bizhawk`), `1b015338` and `c9ceb659` (the 10,174-line `verified.md`
and its queue split per game, which is where this adapter's `VERIFIED.md`/`UNVERIFIED.md` come
from), `8646a7e5` (every verified record gets an index and preflight fails an entry not in it),
`8dfa68da` (every `.lua` file gated on parsing — the mechanical answer to 2026-08-22 above),
`d3c28ca2` (probes and dev scripts resolve their own directory rather than a developer's checkout)
and `10065065` (six live switches that were not in a flag register).

## Catch-up record, written 2026-09-01 — the body the REOPENED header never got

The header above says "REOPENED 2026-08-26 for Fly and the boat" and the file recorded nothing
after it. Backfilled from the commit log; evidence in
`adapters/emulator/pokemon/emerald/VERIFIED.md`, `BANDAGES.md` (entry 4) and `UNVERIFIED.md`.

Its three bullets were given their own dated headings on 2026-09-11 — the day they covered was
findable only by reading this section, which is how Fly came to look absent from its own phase file.
The 08-26 entry is expanded from the commits at the same time; 08-27 and 08-28 are as written.

## 2026-08-26 — Fly, and the assumption that did not survive contact

**Backfilled 2026-09-01, expanded 2026-09-11 from the commits.** Emerald was parked on 2026-08-21
with the boat and Fly recorded as **assumptions** rather than open work (`ddf41827`) — deliberately,
so they could not quietly become a memory of having checked. They could not have been more wrong:
nine faults, end to end (`330c6d7`, `ea4b0b6`, `29ad111`, `58ea70c`, `7074055`, `c22da7c`,
`6f91538`, `87ff6ba`, `983f78f`).

**Fly is not an overworld event at all**, which is the root of most of it: the character is taken
off the map and a bird sprite flies the arc in SCREEN coordinates. Four results worth keeping:

- **`ea4b0b64` — every ROM address Fly needs is shifted on a patched ROM, and none of them fail
  loudly.** The task function pointers, the bird's sprite template and the arc callback are all
  compared or written raw, so on an Archipelago seed every comparison simply never matches: no
  peer ever appears to fly, no boat ever appears, **and nothing in any log says why.** Same
  silent-nil shape the graphics pointer table had before `genderFrames.romOffset`. All five sites
  go through it now; the show-mon banner scan still does not, and that stays a named gap.
- **`29ad1114` — three bugs, each hiding the next.** The bird was spawned and destroyed on *every
  frame* of a departure: the engine's arc callback sets "done" past 0x80 and keeps incrementing,
  because in the real game the task tears the sprite down — and there is no task here. Retiring on
  done, finding the peer still flying, and spawning a fresh one seeded past the end is one loop
  that produced BOTH reported symptoms (the blink, and the passenger not following). Latched: 0
  visibility flips against 43. Underneath it, the bird started at arc position 80 of 128, because
  **a bird and its passenger are two different events** — the engine's swoops down EMPTY and is
  handed the character about twenty frames later. Underneath THAT, a stale `fly==1` branch still
  retired the bird, so the descent spawned one and destroyed it the same frame.
- **`70740553` — the arc was anchored at screen centre**, found *by finally looking at the screen*
  rather than at struct fields. `StartFlyBirdSwoopDown` parks the bird at (120,0) and hangs the
  whole cosine off it — correct for the engine, which flies exactly one character: the player, who
  **is** the centre. A ghost is not, so a peer's departure dragged the ghost to the watcher's own
  feet before lifting it. Also: **a carried sprite was never put back.** The bird writes its
  passenger in screen coordinates with the scroll bit clear, and nothing on the engine's side ever
  recomputes a sprite position from map coordinates — so every carry ended with the sprite parked
  where the arc let go. That is the user's *"3 tiles left, 4 tiles up"* and the teleport after.
- **`58ea70c3` — the frame nobody wrote, and the savestate that decides whether the bug exists.**
  A ghost was handed `graphicsInfo(wantedGfx)` to load its first frame, and `wantedGfx` is nil in
  the ordinary case; nil info makes `loadGhostFrameNow` take its early return, leaving the ghost
  drawing from VRAM **nobody has written**. Grey rubbish. It survived because something usually
  repaints a ghost within a frame or two — and a landing is exactly where that stops being true,
  which is why the report was always "broken sprite AFTER landing" and never during. **The method
  half matters as much**: a landing can only be watched from the town the flyer arrives in, so a
  watcher in the wrong town sees the departure, never the arrival, **and reports success.** Two
  paired runs came back clean while the bug was still there.

**It ships bandaged, not finished** — the user's call, *"good nuff for now"* and *"not properly
working fully yet"*; four compensations in `BANDAGES.md` §4, one confirmed case (a same-town fly
watched from a second instance). **The boat is built and still never watched; rails were never
built.** README step 38.

## 2026-08-27 — the flag register disagreed with its own code, in both directions

Ice was the wrong function (`8af2364`) — Emerald's ice runs `ForcedMovement_Slip`, not `_Slide`;
right screen, wrong mechanism, and it stops being right the moment a character is pushed a way it
is not facing. The flag register was found disagreeing with its own code **in both directions at
once** (`2da653e`, `067ee12`) — the audit that produced the register-completeness rule in
`_template/FLAGS.md`.

## 2026-08-28 — a session at 5fps, because the fix had been written in the other game

`583647a3`: Emerald ran a whole session at 5fps because its own fix had been written in Crystal —
the cross-adapter shape this repo keeps re-learning, and the reason `_template/` back-ports in the
same pass. All four adapters started reading the bridge-port config that day, **two of them having
read no config at all** (`15b2715`). The release-files run that became README step 41 is this date
too, recorded 2026-09-10.

## 2026-09-02 — the documentation pass, as it touched Emerald's files

No adapter code changed. The repo-wide pass (`agent_docs/doc-history.md`, 2026-09-02) reworked the
documentation mechanisms; this is what it did to this adapter's files, logged here because a phase file
is the complete running log and preflight now fails one that falls behind its adapter.

- `UNVERIFIED.md`: every entry tagged READY/OPEN/DONE (21/1/0), a "This run" block added; the Fly/boat items lead it.
- `probes/README.md` renamed `PROBES.md` (one name for every adapter, the user's call) and its links fixed in `README.md`, `FLAGS.md`; `emulator/CLAUDE.md` trimmed for the stack budget and pointed at the Lua and probe checklists; the Archipelago risk narrative moved from `risks.md` into the pitfalls record.
- The Fly rig's setup and savestate slots moved from `status.md` to `agent_docs/running-the-rig.md`.

## 2026-09-02 (evening) — pointer: the day's three Emerald commits are logged in phase9

`32a0a32` (spawned -> OAM -> drawn ships; three tile leaks and a double-free found with a crowd), `5863aff`
(the gender guard watched on a female save) and `a13858e` (the interp ladder: 250ms stands) were run as
part of the cross-game post-review check and are recorded in
[phase9.md](phase9.md), "2026-09-02 (afternoon and evening)". Their outcomes live in
`adapters/emulator/pokemon/emerald/UNVERIFIED.md` and `VERIFIED.md`. Entry added so this file stays the
complete log for its adapter (preflight's phase-lag check).

## 2026-09-02 (late) — pointer: Emerald's night is logged in phase9

The full session is [phase9.md](phase9.md), "2026-09-02 (late)". What touched this adapter: the launcher
rule mirrored into `startCore` with the spawn port riding on `coreSpawnFrame` (`e3c11dc`); two instances
whose cores restarted together then chased each other's fresh cores and the every-frame sweep of blocking
connects put the emulator at 3fps, so the sweep now waits on its own child, forgets it only on busy, and
runs every 30 frames (`9b79429`); the interp ladder on the worst-case proxy, 375 then 450ms, watched by the
user (`0cd52a9`, `emerald/VERIFIED.md`); 450ms shipped for every game (ADR 0046).

## 2026-09-02 (late) — pointer: Emerald's own config.json

The script now points the core it starts at a `config.json` beside itself when one exists (own folder first,
the release root's otherwise, the choice logged), staged from the root `config.json`'s client block like every
other game's; `plans.md` "Settings" step 3. Unwatched: the Lua Console line naming the path is the check.

## 2026-09-03 — `"autostart"` moves into config.json (Emerald)

The user's ask, the morning after the config restructure: the "don't start a client" switch was an
environment variable, and *"even me that is somewhat tech savvy, has no clue what 'an environment
variable' means"*. All four launchers now read `"autostart"` from the config.json the client will read,
the variable still counts, the READMEs are rewritten around the key. Built and deployed, unwatched
(`UNVERIFIED.md`). The user's follow-on thought -- game-specific settings in the same file instead of
in-game menus -- is filed in `ideas.md`.

## 2026-09-03 — the bridge JSON decoder had no depth cap, and a harness now says so on every push

Building the adapter-fuzzer entry from `ideas.md`. No game involved: this is offline work against the
shipped file, and both findings are queued in `UNVERIFIED.md` rather than claimed.

**The harness** is `adapters/emulator/tests/json_fuzz.lua`. It loads this adapter's REAL `jsonDecode`
without editing anything, by taking the file prefix up to the end of that function — which is pure
declarations — and running it under a stub `_ENV`. The cut point is found structurally, so an edit to
the decoder cannot silently point it at the wrong text; that was proved immediately, when the fix below
moved the prefix end from 943 to 952 and the harness kept working. Each decode runs inside a coroutine
with an instruction-count hook, so a runaway loop is a reported failure rather than a hung CI job —
which is the whole point, because the 2026-08-25 incident was a hang and `pcall` cannot catch one.

**What it found here:** this decoder followed nesting **5000 levels deep**. Crystal's has refused past
64 since its own 2026-08-25 fix; the two copies had drifted, each missing the other's guard. It is
reachable input, not a theoretical one — `security-design.md` measured 490 levels fitting inside the
1KB `extras` cap, and nothing between here and a peer bounds SHAPE.

**The fix** threads `depth` as a parameter through `decodeValue`/`decodeObject`/`decodeArray` rather
than adding a file-scope local, because `emulator/CLAUDE.md` records this file at 199 of Lua's
200-local ceiling and a counter would have spent the last one. `luac -p` still passes.

Now in CI as a second job in `lua.yml`, path-filtered on `**.lua` like the parse job, so a Go-only push
pays nothing for it. Its header says plainly what a green tick does not mean: desktop Lua 5.4 is not
BizHawk's, and the harness reaches the decoder only, never the dispatch.

**Waiting on the user:** that the adapter still loads, connects and renders a ghost. Batched with the
rest of the session's adapter work rather than asked for on its own.

## 2026-09-03 (evening, second) — two clients confirmed, and the spawned tier is still solid

**The decoder change is confirmed on screen.** The user, after a two-client session: *"i tested
pokemon emerald, 2 clients still work and connect properly"*. The session's own logs agree — sprite
decode at the vanilla address, the port walk landing on 7779 after 7778 answered `busy: this core
already has a game attached`, cross-map ghosts armed instantly from the cached map groups, and
`in game -- now sending local state` on both. Ghosts rendered too, which is not an inference from the
log: the same session produced the collision observation below, and a ghost has to exist to block you.

That closes the load/connect half of the depth-cap entry in `UNVERIFIED.md`. The cap itself stays
unconfirmable on screen by construction — it refuses input no peer sends, and nothing looks different
when it works.

**Logged from the same session: the spawned tier still has collision.** The user: *"we are not
disabling collission on the spawned ghost tier"*. Known in the general case since 2026-08-19 — no
adapter handles `session_policy`, so `ghost_collision` dead-ends at the bridge in every game — but
worth recording here because it re-prices the fix for THIS game.

**The mechanism is already built and proven; only the wiring is missing.** `freeGhostCollision` makes
a spawned ghost walk-through using the engine's own rule: `AreElevationsCompatible` never reports a
collision between two non-zero DIFFERENT elevations, and it is re-applied every frame because
`ObjectEventUpdateElevation` rewrites the value from the map tile on every step. Only the low nibble
is touched, so draw order is untouched. It sits behind `MESHGHOST_EMERALD_NO_COLLISION`, a dev probe
flag that announces `PROBE FLAG IN USE` at startup — so the shipped default is a solid ghost that
blocks the player and can be talked to.

So the work is "let `session_policy` reach the switch that already exists", plus the once-at-startup
honest-fallback log `bridge.go` already asks for. Not "find the mechanism". Details and the same
shape in Crystal's `GHOSTS_PASSABLE`: `plans.md`, "Settings: defined once, honoured everywhere".

## 2026-09-04 — pointer: a replay finding that widened this adapter's queue

**Backfilled 2026-09-11.** `6047c6f2` is Pseudoregalia's ([phase7.md](phase7.md)) and is noted here
because it re-priced an entry in every adapter's queue, this one included. The user asked whether
backward/forward could hit the dust fault; checked in the core rather than guessed, and the answer
widened it twice. `replayPlayer.seam` (`core/replay.go:522`) is drop-peer → wait a render tick →
re-admit, and a despawn is the **precondition** for the offset poisoning — so all four callers are
candidates, including **a recorded loading screen or long menu, which seams during ordinary playback
with nobody touching a key.** That is why a tester hit it where a deliberate test had not. A rewind
is the cheapest deliberate trigger. Recorded there in full; here so this file is not silent on a day
its adapter's queue moved.

## 2026-09-05 — queue-only: two open halves moved in from `status.md`, nothing built or watched

No Emerald work this session (it was a Pseudoregalia day — `phase7.md`, 2026-09-05). The three
commits since the last entry here are `bba6fa56` (the bike issue filed as deterministic, logged
above under 2026-09-03), `6047c6f2` (a replay-seam finding, Pseudoregalia's, that touched this
adapter's queue in passing) and `e968507e`, the `status.md` curation: the 2026-09-02 items whose
detail lived nowhere but `status.md` got one line each in `UNVERIFIED.md`'s "This run" block —
the interp verdict here was judged on the BROKEN relay (the limiter hid `WriteUnreliable` until
`341a768`) and wants a re-run on the fixed one; and after the spawned -> OAM -> drawn ship, the
attach NAMETAG BURST, rung churn and drawn clipping under a text box are unexercised. Both OPEN,
neither new; this entry exists so the log stays complete.

## 2026-09-06 — TCP_NODELAY on this adapter's bridge socket

**Backfilled 2026-09-11, and the omission is the point.** `55bf77d8` edited
`meshghost_emerald.lua` and logged itself in [phase7.md](phase7.md) and Pseudoregalia's queue only,
because the fault that motivated it was found in a tester's replay files on that game. This file
carried a 2026-09-06 entry for the same date — the documentation fact check below — so **nothing
ever looked missing, and no freshness gate could fire**: the day was claimed by a heading that did
not mention the code change.

What it does: `tryPort` now sets `tcp-nodelay` on the bridge socket, `pcall`'d because `setoption`
is a luasocket extension and a vendored build lacking it must not take the adapter down over a
tuning flag. The bridge writes one small line per frame, and Nagle holds each write until the
previous is acknowledged — **a 40ms floor on Linux**, measured as 46ms delivery bunches in a
tester's files. Every bridge socket in the project got the same treatment in that commit. Unwatched
on this game; the Emerald half has no separate confirmation.

## 2026-09-06 — the documentation fact check, as it touched Emerald's files

No adapter code changed. The repo-wide pass (`agent_docs/doc-history.md`, 2026-09-06) found that the
2026-09-02 ladder ship had reached `FLAGS.md` and nothing else here.

- `README.md`: both overflow rungs described as OFF/opt-in in two places, now ON since 2026-09-02; steps 39 (the ladder as the shipped default, watched with the 24-peer crowd, three tile leaks; two clients on screen 2026-09-03) and 40 (450ms, `VERIFIED.md` 2026-09-02); the header frames "feature complete 2026-08-21" as a playable-state marker and lists what is open, including the bike defect; four `pitfalls.md` pointers now reach `pitfalls/by-lesson.md` and `checklists/`; the dev-loader paragraph names the per-instance target files and the `--lua=` requirement; `logs/` documented.
- `FLAGS.md`: rows for `MESHGHOST_EMERALD_HW_COMPARE_DX/_DY`; the dead `#diagnostic-methodology` anchor now points at `checklists/before-declaring-a-fix.md`.
- `BANDAGES.md`: the drawn-tier entry's "off by default" passages updated for 2026-09-02.
- `UNVERIFIED.md`: the "This run" block holds ten READY entries as promised (it held 16 mixed bullets); the `[DONE]` "shipped 250ms stands" heading marked SUPERSEDED by 450ms the same day; fourteen `[READY] Pending —` headings normalised.
- This file's header: "in progress, but the peer-state work is closed / REOPENED" replaced with the live-log framing (the user, 2026-09-06).

## 2026-09-07 — the stale-fact sweep reaches Emerald's docs

No adapter code changed. Part of a repo-wide correctness pass over what the docs assert
(`phase10.md` carries its full record); this entry covers only what it touched here.

**The one worth remembering is a fabricated measurement.** `BANDAGES.md`'s OAM-pool entry gave the
engine's back-to-front order as *"reflection 152, ripple 151, blob 150, shadow 148, the character,
dust 135"*. The source comment it paraphrases (`meshghost_emerald.lua:8384-8386`) is explicitly
labelled **measured 2026-08-21**, and it lists only reflection 152, surf blob 150, shadow 148 and
landing dust 135 — no ripple, and no 151. The pool itself is real (12 entries, in the table right
below), but its subpriority was never taken; `151` was interpolated because it *fits* between 152
and 150.

**That is worse than a gap, and it is worth naming why.** A number in a list labelled "measured"
carries the authority of a measurement. Anyone later reading it would have had no reason to re-take
it, and no way to tell it apart from the four beside it that were genuinely read off the engine.
The repo's rule against addresses-from-memory exists for exactly this shape, and a doc paraphrasing
its own source is a place it can slip in without anyone writing a line of code. The entry now says
where ripple sits (by where it has to draw) and states plainly that its subpriority is unmeasured.

**The rest were ordinary drift.** `README.md:70` named `phase5_5_sprite.lua` without saying it
lives in `probes/`, in the one bullet whose whole job is telling a reader which file is the shipped
one — misleading by omission rather than by wording. And `FLAGS.md` gained rows for the two
`config.json` keys the adapter genuinely reads, `"autostart": false` (`:1090`) and
`"local_game_bridge"` (`:618`): preflight asserts every `MESHGHOST_*` in source is named in a
register, but it cannot check the reverse and cannot see a switch that is not an environment
variable at all, so both keys had been live and unregistered. Its preamble said everything but
`MESHGHOST_NO_AUTOSTART` was development-only; there are three supported player settings now.

## 2026-09-10 — the build story gains its missing beat, and a confirmation leaves the queue

Emerald's build story stopped at step 40 while one confirmed thing had never been written down:
**running the whole adapter from the release files with nothing configured** (2026-08-28,
`VERIFIED.md`). It mattered because the relay had just started filtering cross-area state
(ADR 0041, 2026-08-28) and briefly broke cross-map ghosts — Emerald asks for `render_all_areas`, so
the relay is obliged to forward everything, and its own introspection reported nothing filtered
against a room where most of the bytes crossed areas. Every earlier check had gone through
`dev-scripts`. That is now step 41. Crystal's step 27 had carried the same fact for Crystal since
the day it happened; Emerald's list simply never got it.

**A build-story step was resting on the queue.** Step 39 cited *"two real clients were then
confirmed on screen (2026-09-03)"* against an `UNVERIFIED.md` entry. The confirmation was real,
dated and in the user's own words — *"i tested pokemon emerald, 2 clients still work and connect
properly"* — but it had never been migrated, so the step pointed at the file whose whole meaning is
"not yet confirmed". Drained to `VERIFIED.md` with the log evidence beside it; the queue entry is
now `[DONE]` and says where it went. This is the same class of fault the TEVI drain found the same
day, and the cause is the same: the queue only drains when somebody does it.

**`documentation.md` said the Fly section "was never watched".** A same-town Fly was watched from a
second instance on 2026-08-26 (`VERIFIED.md`), and the build story's own step 38 said so — the
provenance note at the top had simply not been updated when the confirmation landed. The boat half
of that sentence stands and is now the only thing it claims.

**Added the closing known-unknowns section** the template prescribes and this file lacked, including
one cross-game question worth having written down: whether Emerald's sprite priority under a text
window behaves like Crystal's, where a text box turned out not to hide characters at all
(`crystal/documentation.md`, rewritten the same day). Emerald's equivalent has never been exercised
— `UNVERIFIED.md` lists drawn clipping under a text box as unexercised — so it is a question, not a
claim.

## 2026-09-11 — Emerald's share of the review backlog (full record in phase10.md)

Six findings, **UNWATCHED**; `UNVERIFIED.md` carries what to watch. The one that mattered most:

- **I30 (HIGH):** the dispatch admitted a peer on truthiness alone, and every tier below does
  `playerId:match()`, which RAISES on a number in Lua 5.4 with no guard above the first one.
  `guardedFrame`'s pcall swallowed it, so every tier past that point stopped **for the rest of the
  session**, with one throttled line every 300 frames and no despawn ever sent.
- **I32:** the savestate OAM sweep wrote slots 64..119 with none of the three gates the hardware
  tier enforces — and the SLOT MACHINE owns exactly that range, so a state loaded inside one
  blanked the reels. `MESHGHOST_EMERALD_HW_OVERFLOW=0` did not stop it: that flag gates
  `tiering.hw.on`, which this path never asked about.
- **I47:** `tonumber("ZZ", 16) % 256` raises, and `jsonDecode`'s pcall turned that into a dropped
  line — so one malformed `\u` escape in a peer's extras cost the whole message. The path a
  peer name containing `&`, `<` or `>` actually takes.
- **I33, I34, I35** and the reject-code change: see phase10.md.
- **D3:** ghosts honour the room's `ghost_collision` now, driving the walk-through mechanism this
  adapter already had. **This is the one change that alters what the player sees.**

Full session record, including what was NOT done and why: [phase10.md](phase10.md), 2026-09-11.

## 2026-09-11 (later) — four Emerald builds at once, and the painted tier made 2.4x faster by measuring instead of arguing

**The session ran four Emerald builds against one relay** — vanilla, an Archipelago seed, SPEEDCHOICE
1.2.2 and EX SPEEDCHOICE 0.4.0 — then added vanilla Crystal V1.1 alongside for comparison. Five
emulators, one machine.

### Three defects found before any performance work started

- **D3's collision policy was a nil global.** The `session_policy` handler stored the flag on
  `tiering`, a file-scope local declared ~900 lines BELOW the bridge dispatch, so the first policy
  message a room ever sent would have raised inside the dispatch. **The fifth bite of the
  forward-reference trap this adapter documents in its own source**, caught by `preflight.ps1`'s
  Lua-globals check — not by a test, and not by a reading. The feature had never executed anywhere.
- **A save-block pointer was checked for being non-zero, never for being a POINTER.** Ten deref
  sites, all guarded `== 0` alone. On EX SPEEDCHOICE that address holds `F9F9F7F6`, so every guard
  passed and the adapter read through it once per frame per site; BizHawk answers an out-of-range
  read with a WARNING, so nothing failed and nothing stopped — the console filled and the emulator
  visibly lagged, which is how the user found it. Fixed as a reader returning 0 for anything
  outside EWRAM, so the ten existing guards start working.
- **`MESHGHOST_EMERALD_HW_OVERFLOW` cannot be flipped mid-session**, though `FLAGS.md` said a
  loader script could. It is read in a table constructor at file load. A tier-cost ladder run on
  that claim reported `hw=16 drawn=0` while believing it was pricing the painted tier.

### The cross-gender ghost, diagnosed and filed

A peer of the opposite gender is drawn as a copy of YOUR player, confirmed on screen: *"both male
on vanilla, both female on ap"*. The adapter had been printing the fault about itself since the status dump gained that line
(`gfx: ghost drawn as 0, peer reports 89`). The graphicsId crosses the wire intact; the spawn path
discards it, because a ghost borrows the player's loaded palette slot and refuses any graphic with
a different `paletteTag` — and Brendan and May are exactly such a pair. **The guard that makes bikes
and surfing work across peers is the one that makes gender fail across them.** Filed unfixed: the
clean repair writes palette RAM, wider than the object-RAM surface the 2026-08-18 ADR cleared, and
that boundary is the user's to move.

### The painted tier, and the method that got there

The user's question was why Emerald's drawn tier is demanding when Crystal's is preferred. **Three
answers were offered before one was measured, and two were wrong.**

1. *Colour depth fragments the rows* — refuted by decoding both ROMs offline: **113 runs a frame
   against Crystal's 94**, 1.2x, not the 4-6x that story needed.
2. *Route the cross-gender case through the painted tier, it is cheapest* — the user corrected it:
   in Emerald that is the EXPENSIVE rung, which this adapter's own README states plainly.
3. *The per-run logic around each draw call* — half right, and not the half that mattered.

**The ladder** (`fpshold.lua`, 1800 samples a rung, painted count verified from `drawn=`, both games
idle, indoors, away from water at the user's request):

| painted | Emerald before | Emerald after | Crystal |
|---|---|---|---|
| 16 | 60.0 | 60.0 | 60.0 |
| 32 | 45.4 | **59.8** | 60.0 |
| 64 | 19.5 | **29.3** | 59.9 |

**The attribution, in three steps, each one narrowing the last:** the profiler put 94% of the frame
in the painter; a pass/run counter showed exactly ONE pass per ghost (killing the "extra passes"
theory); and `guicost_probe.lua` timed the same 8,000 gui calls with no adapter logic at **6.1ms**,
proving **88% of the cost was ours and only 12% BizHawk's**. Then a timer inside `reflectiveSpans`
found it: **37.6ms of a 62.9ms painter, 56% of the whole frame**, in the occlusion check.

**Two structural faults there, and two more allocations found the same way afterwards — all four
the same mistake in different clothes: the right work at the wrong FREQUENCY.**

1. `reflectiveSpans` asked `metatileAt`/`coverMask` once per PIXEL row when the metatile changes
   every 16 rows, and walked all 16 bits of a cover mask when one is almost always entirely
   covering or entirely open. **37.6ms -> ~2.1ms.**
2. The reflection's water-clip ran for every peer, every frame, **indoors**, where the result is
   discarded — found by breaking the occlusion call count down by caller and reading
   `occlBy[reflection=64.0 sprite=64.0]` in a house.
3. `glideRemote` allocated a table per peer per FRAME for a 32-slot ring.
4. `reflectPalFor` rebuilt a six-slot row on every tile change, constantly for a moving crowd.

**Final: 67ms -> 21ms of Lua a frame at 64 peers, 19.5 -> 39.4fps, and 32 painted back to a flat
60.0.** `spans/frame` held at 8,034-8,045 throughout — same picture, a third of the work.

**The regression check is the profiler's own `spans/frame`** — the count of painted pieces — which
held at 8,035-8,045 across every run before and after. Same count, 6.4x less work. **It is not
proof of the same picture, which is why it sits in `UNVERIFIED.md` as the thing to watch.**

**Instrument faults caught along the way, all of which would have produced confident wrong
numbers:** a rung that inherited the previous crowd measured `drawn=32` while asking for 16 (the
contaminated sample read ~16fps where the clean one reads 45.4 — the difference between "it falls
over at 32" and "cost scales with count"); a timing closure allocated per call in the hottest path
in the tier, which is the GC pressure the caller-owned scratch buffers exist to prevent; and the
pass counter itself took the **sixth** bite of the forward-reference trap, referencing `tiering`
from a function ~480 lines above its declaration, which made the whole tier render nothing while
the log said only "unrendered".

Records: `emerald/VERIFIED.md` (the ladder, the attribution, the refuted hypothesis),
`emerald/UNVERIFIED.md` (what to watch), `dev-scripts/README.md` (the two new dev scripts).

## 2026-09-11 (later still) — autostart stops being something an install gets without asking

**The player docs were rewritten first**, and the autostart change fell out of one sentence in
them. Describing the pieces for a reader, the new "How it fits together" section in
`docs/getting-started.md` said the mod "starts and stops" the client for you. The user's
correction: *"can start, not 'starts'"*, because *"autostart is not the default, its opt in if you
drag the exe into the mod folder"*.

That was true of TEVI and Pseudoregalia and **not** of this adapter. `findCoreExe` searched three
places — beside the script, the release root three levels up, a source checkout four up — so an
install that had never copied an exe anywhere still had a core started for it from the root. The
opt-in was not an opt-in.

**Removed both `../` fallbacks; the search is the script's own folder, after `MESHGHOST_CORE_DIR`.**
Crystal's adapter got the identical change. The user's rule: *"everything should either be 'run exe
manually from root' or 'place exe in mod folder for autostart, toggle on/off in config'. not both
at once"*, and the reasoning that settled it — autostart is *"a qol people can have but not a
requirement"*, and *"what might trigger antivirus things"*. One program starting another is exactly
what an antivirus flags, so getting it unasked is the wrong default. Reasoning, cost and the
reversed 2026-09-10 decision: [ADR 0061](../adr/0061-2026-09-11-autostart-is-opt-in-and-looks-only-beside-the-mod.md).

**The dev loop needed the escape hatch to survive it.** Nine of the eighteen local BizHawk
launchers relied on the four-up fallback to autostart against the repo-root build; the other nine
already set `MESHGHOST_NO_AUTOSTART=1`. The nine now set `MESHGHOST_CORE_DIR=%~dp0..`, which is why
that variable is kept ahead of the mod folder rather than dropped with the `../` paths — the same
name and position TEVI's `CoreSearchDirs` has had all along.

**UNWATCHED in either game**, and the check is three loads of the script rather than a reading: no
exe beside it must now start nothing even with one in the release root, a copy beside it must still
start one hidden, and `"autostart": false` must still override that. `emerald/UNVERIFIED.md`.

Docs carrying the old behaviour were corrected in the same pass: `getting-started.md` (four
places), `troubleshooting.md` (three), `packaging/README.md`, the release `README.txt` and both
Pokémon `README.txt` files in the zip.

**Not written up here: the three painted-tier commits that precede this entry** (`04044fcb`,
`4badbf8c`, `6960c96f` — the timer strip, the vertical-merge measurement, and the user's on-water
confirmation). They were the user's own session; their records are those commit messages and the
`[PARTLY CONFIRMED]` entry in `emerald/UNVERIFIED.md`, and a fuller account is theirs to add.

## 2026-09-11 (later still) — drawn-only, and all FOUR Emerald builds seeing each other

**The user's two asks: make male/female work, and make every ghost show up for every other.** Both
done, both confirmed on screen, and the first turned out to be a consequence of the second decision
rather than a fix of its own.

### Drawn-only is the shipped ladder (the user's call)

*"lets make drawn the default and only tier for emerald now (keeping spawned & OAM dev), same as we
did for crystal. drawn with good performance allows us to do more custom things/bypass hardware
limitations."* The spawn cap defaults to 0 and the OAM tier defaults off; both flags still turn them
back on. **It was only available because of the morning's work** — the painted tier had gone from
67ms to 21ms a frame at 64 peers that day.

**It fixed the cross-gender ghost for free**, which had been filed as needing a palette-RAM write
boundary the user would have had to approve: vanilla now shows the Archipelago player as female
while the vanilla player is male. Every ENGINE tier borrows the palette slot loaded for the local
player and so cannot show a peer of the other gender; the painted tier reads the peer's own graphic
from the cartridge and never had the limit. **A correction worth keeping: the OAM tier does not
carry 64 peers** — its 56 entries are split five ways since 2026-08-21 and bodies get 26, so past
roughly 37 characters everything was already being painted.

### It immediately broke Archipelago, which is the interesting part

The painted tier consults the map for occlusion and the spawn tier never did, so AP had never
exercised that path. **Its gMapHeader is relocated**: 0x02037318 holds 0x03FF03FF, every tileset
lookup failed, every metatile read as unknown — and unknown deliberately means "covers everywhere"
so that an undecodable tile never causes a ghost to paint over scenery. **128 runs in, 0 spans out,
no error anywhere.**

An unknown METATILE still hides things; an unreadable MAP now means do not clip at all. The first
guess (that the map itself was unreadable) was WRONG and the check written for it passed 0x03FF03FF
happily; `probes/occlusion_probe.lua` settled it by printing every link of the chain on both builds
and diffing them.

### SPEEDCHOICE and EX SPEEDCHOICE, from unsupported to bidirectional

Six anchors on EX, at six different offsets — **a build does not move as one piece**, and two of
those offsets are 0x10 apart, which is close enough that applying one to the other looks right:

| | SPEEDCHOICE | EX SPEEDCHOICE |
|---|---|---|
| ROM sprite data | +0x6408 | +0x9CB78 |
| ROM graphics table | +0x6408 | **+0x1E6DBC** (a different shift) |
| gObjectEvents | +0xA4 | +0xC80 |
| gSprites | +0x4 | +0x20 |
| gSaveBlock1Ptr | 0 | -0x10E0 |
| camera block | 0 | -0x10D0 |

Every one measured and corroborated; the method per anchor is in `emerald/PROBES.md`, which now has
the set and the order to use it in.

### Three lessons, each of which cost time

- **A probe with a private copy of a constant can be wrong about a build, and it never looks like
  that.** `gsprites_scan_probe.lua` carried its own gObjectEvents bases and CB2 gate, so it said "no
  player object event", then "the player did not walk far enough" three runs running — which reads
  exactly like a character standing somewhere awkward. **The user saying "its in the middle of town,
  with some houses around it" is what made the gate a suspect.**
- **Build the instrument sooner.** BizHawk answers an out-of-range read with a console warning and a
  zero: no error, no stack, nothing greppable, thousands of lines a second, 4fps. Three plausible
  guesses were spent before `dev-scripts/read-guard-emerald.lua` was written — and then it named
  each of two faults in one 25-second run, with a traceback.
- **Both final faults were a read that skipped the helper written to make it safe**: gSaveBlock2Ptr
  read raw instead of through `session.saveBlockPtr`, and `attrAt` accepting any non-zero
  gMapHeader. Adding a guarded reader does not help the call sites that do not use it.

**Known gap: EX SPEEDCHOICE has no occlusion** — its gMapHeader is unlocated, so its ghosts paint
unclipped. It logs that once. Everything else on that build works.

## 2026-09-12 — the same session, past midnight: records and the two open watch items

No new work — the session above ran past midnight and its records landed on this date. The two things it left open are filed in `emerald/UNVERIFIED.md`: **land occlusion behind scenery** (water is user-confirmed, scenery is not) and **EX SPEEDCHOICE having no occlusion at all** because its `gMapHeader` is unlocated. The porting method for a fifth build is in `emerald/PROBES.md`.
