# Phase 8 — Emerald, dedicated (post-Phase-5.5 ongoing work)

> **A dated record. Package paths here predate the 2026-08-17 module move** — read any
> `internal/X` as `X/`. Why, and what became of `internal/README.md`: [../README.md](../README.md).
> **Adapter paths predate the 2026-08-25 folder rename** — read any `adapters/bizhawk/` as
> `adapters/emulator/`. Left as written for the same reason: a phase file records what was true
> while the phase ran.

**Status: in progress, but the PEER-STATE work inside it is closed — Emerald is FEATURE COMPLETE
as of 2026-08-21, the user's call** (`verified.md`): every way this game moves a character and
every field effect it hangs off one is mirrored on all three tiers. **REOPENED 2026-08-26** for the
two states that call was made without: Fly is built, bandaged and confirmed in one case only, and
the boat is built and unwatched. Rails are not built at all. What remains beyond those is polish
and custom features. `adapters/emulator/pokemon/emerald/UNVERIFIED.md` and `BANDAGES.md` §4.
(This header read "the adapter is PARKED" until 2026-08-27 — the fourth doc carrying that after the
2026-08-26 session, alongside `plans.md`, `risks.md` and `phases/README.md`.)

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

## Catch-up record, written 2026-09-01 — the body the REOPENED header never got

The header above says "REOPENED 2026-08-26 for Fly and the boat" and the file recorded nothing
after it. Backfilled from the commit log; evidence in
`adapters/emulator/pokemon/emerald/VERIFIED.md`, `BANDAGES.md` (entry 4) and `UNVERIFIED.md`.

- **2026-08-26 — the Fly session, nine faults end to end** (`330c6d7`, `ea4b0b6`, `29ad111`,
  `58ea70c`, `7074055`, `c22da7c`, `6f91538`, `87ff6ba`, `983f78f`): ROM addresses shifted on a
  patched ROM, the bird's arc anchored to the screen rather than the world, and three renderers
  showing three different fly faults. Fly is registered as a bandage where it compensates.
- **2026-08-27** — Ice was the wrong function (`8af2364`), and the flag register was found
  disagreeing with its own code in both directions at once (`2da653e`, `067ee12`) — the audit
  that produced the register-completeness rule in `_template/FLAGS.md`.
- **2026-08-28** — Emerald spent a session at 5fps because its own fix had been written in
  Crystal (`583647a`); all four adapters started reading the bridge-port config, two having read
  no config at all (`15b2715`).

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
