# Pseudoregalia

**Status: Phase 7, 7.0–7.6 done, 7.7 (real two-player test) not started.** First release
package cut 2026-08-13, marked experimental/pre-release pending 7.7. See
[agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) and
`packaging/release/games/pseudoregalia/README.txt`.

- Unreal Engine 5, small movement-focused 3D platformer. Worst starting point (no source, no
  BepInEx) but best genre fit for ghost co-op, per the brief.
- Tooling: **confirmed 2026-08-12** — UE 5.1 (`++UE5+Release-5.1-CL-23901901`, read from
  `pseudoregalia-Win64-Shipping.exe`); UE4SS **v3.0.1 Beta, Git SHA `733e5969`**, installed
  under the newer `Binaries\Win64\ue4ss\` layout. See
  [agent_docs/environment.md](../../agent_docs/environment.md)'s Unity/TEVI, UE5/Pseudoregalia
  section for the full record, including a note that the install was updated mid-Phase-7 from
  an older v2.5.2 — re-check before assuming this is still current.
- **Adapter language plan, decided 2026-08-12:** Lua for discovery (no build step, fast
  iteration, used only to find and confirm the real player-state fields), C++ for the
  shipping adapter (UE4SS Lua has no socket support — zero `luasocket` references in
  RE-UE4SS and no networking in its Lua API docs — but the already-installed `AP_Randomizer`
  C++ mod proves a UE4SS C++ mod can hold a real TLS/websocket connection in this exact
  game). See [agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) and
  [agent_docs/plans.md](../../agent_docs/plans.md)'s Phase 7 entry. **Revised by what actually
  happened (7.5):** Lua sockets turned out to be possible after all (`package.loadlib` +
  vendored LuaSocket), and worked under light testing — the real reason C++ became mandatory
  was a receive-side memory corruption bug in that combo that only surfaced under sustained
  real traffic, not "Lua can't do sockets" as first assumed. See build-log step 5 below and
  `agent_docs/pitfalls.md`'s "Host-embedded scripting runtimes" section for the full
  diagnostic trail.
- The Archipelago randomizer for this game
  ([pseudoregalia-archipelago](https://github.com/pseudoregalia-modding/pseudoregalia-archipelago))
  was checked into [agent_docs/licensing.md](../../agent_docs/licensing.md) 2026-08-12: **no
  LICENSE file, all rights reserved.** Consulted for facts only (its `.gitmodules` UE4SS pin,
  its general mod structure) — no source copied, per the standing "facts, never code" rule.
- No source is or will be copied from any randomizer or modding project without checking
  its license first — see [agent_docs/licensing.md](../../agent_docs/licensing.md).
- [PLAYER_FIELDS.md](PLAYER_FIELDS.md) — reference doc: which player fields MeshGhost actually
  syncs today, plus a map from every in-game ability to the internal field names behind it,
  found via a real reflection dump.

## How this adapter was built

Third game, and by far the hardest so far: roughly 15-20 hours in and still not fully done
(the ghost follows and animates, but Phase 7.7 — a real two-player test — hasn't happened
yet). Started in Lua, then had to be substantially remade in C++ partway through once Lua
proved unable to reliably send everything the adapter needed.

All of this is one phase, [agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) —
the sub-numbers below (7.1, 7.4,
etc.) are that file's own task headings, called out here for anyone jumping straight to the
detailed log instead of reading the whole thing top to bottom. It reads as a much smoother
line than it actually was — the file itself has dozens of individual live-test cycles behind
several of these steps (the camera fight alone took over twenty), condensed here into what
actually mattered.

Roughly in order:

1. Dropped an unanimated model into the level, not moving. (7.1/7.4)
2. Building a real UE4SS C++ mod turned out to be blocked: the core `UE4SS` CMake target
   needs a private submodule (`UEPseudo`) with no public access and no prebuilt substitute
   available anywhere. Rather than chase that down (a GitHub issue later found, not acted on
   at the time, says linking a GitHub account to an Epic Games account unlocks it), pivoted to
   Lua-for-discovery / C++-for-shipping instead. (7.2)
3. Made that model follow the player as a ghost. (7.4)
4. Fought the game's camera, which kept snapping back onto the ghost instead of staying on
   the player. (7.4 — the fix that finally worked: hooking the game's own camera-retarget call
   and forcing it back, not toggling a property on the ghost's camera.)
5. Tried making a statue already present in the stage follow the player, as an alternative
   to spawning a new actor — this is also what proved runtime-`SpawnActor`'d actors weren't
   rendering at all on this build, while hijacking an existing level object did. (7.4)
6. Hit a wall where Lua wasn't reliably sending everything required over the socket — a
   binary-compatibility bug between the vendored LuaSocket build and UE4SS's own embedded Lua
   that only showed up under real sustained traffic, not light testing. (7.5)
7. Remade the networking (and much of the rest of the adapter) in C++, once the C++/UE4SS
   build toolchain access that had been blocking that path got unblocked. (7.5)
8. Tried spawning something not already in the stage (new statues, etc.), then decided
   against it and went back to duplicating the player / reusing an object already in the
   stage — same finding as step 5, re-confirmed in C++: spawned actors could be destroyed but
   never re-rendered cleanly. (7.5 — later reversed, see step 11.)
9. Tested with static objects, and had to move rendering/follow logic onto the right thread
   to get it to actually follow instead of stutter or freeze — the mod's own update loop
   wasn't running on the real game thread. (7.5)
10. Fought the camera a second time, now in C++ — the previous hook approach silently never
    fired, because this game calls the camera-retarget function natively, bypassing the normal
    event dispatch entirely. Found by reading UE4SS's own hook implementation directly and
    switching to the lower-level hook it offers for native functions. (7.6)
11. Retested spawning on the correct game thread (step 9's fix) and found step 8's "must
    hijack, can't spawn" verdict was an artifact of running off-thread, not a fact about this
    build — spawn-based ghosts (a real player-model clone, not a hijacked prop) work fine once
    driven from the game thread. This is the shipping design. (7.6)
12. Fixed a real crash: an access violation inside the camera hook, caused by a cached raw
    pointer that a level transition had already freed out from under it. (7.6)
13. Got the ghost animating at all — it had been gliding stiffly with no animation since the
    `anim` field was still a hardcoded placeholder from early on; fixed by mirroring the real
    pawn's movement-state fields onto the ghost's own AnimBP instance. (7.6)
14. Tried enabling ghost collision, found it genuinely dangerous, reverted — it didn't make
    the ghost solid, but let the real player accidentally kill it in melee, which killed the
    real player's own character too. (7.6)
15. Figured out how to drive the ghost's facing direction — found via a forced test rotation
    (to tell "the write is dead" apart from "the write lands wrong") that it was landing as
    ≈0; traced to a marshaling bug in the vendored UE4SS SDK that only affects `FRotator` on UE
    5.0+, worked around with a local, version-aware helper rather than patching the
    (un-committable) submodule. (7.6)
16. Fixed the ghost getting stuck in a falling animation. (7.6)
17. Fixed the ghost getting stuck in a ledge-hang animation. (7.6)
18. Ghosts can't actually be deleted on this build, so a leaving ghost is moved into the void
    instead, until the next stage transition clears it out. (7.5)
19. Started chasing the Dream Breaker (weapon), ability VFX (cling gem, sword glow), and outfit
    gaps — restored a generalized reflection dumper (`dump_object_reflection`, gated behind
    `OBJECT_REFLECTION_DUMP`) in the C++ mod, deleted as dead diagnostics after the falling-pose/
    ledge-hang investigation and rebuilt for this new discovery pass, plus turned on UE4SS's own
    already-vendored `ConsoleCommandsMod`/`ActorDumperMod` for live, no-rebuild-needed lookups. A
    real capture session mapped every ability on the game's own trending-pages list to real
    internal field names, several only after correcting an initial name-based guess against
    actual gameplay knowledge (the code's own name for "Cling Gem" isn't "glide" anywhere, and
    "Solar Wind" turned out to be a passive stat upgrade with no unlock flag of its own, not a
    flip move). A follow-up live-*value* trace (`ABILITY_FIELD_TRACE`) then separated real
    findings from guesses: `weaponEquipped?`/`canFlipJump?` turned out to be persistent
    "obtained" flags, not moment-to-moment triggers; `currentPower`/`powerLevel` are genuinely
    live; `chargeAttackHoldTime` is a static tuning constant, not a live timer; and
    `hasGroundPound` never once went true across 616 samples despite deliberately testing every
    interaction — a real negative result, not a sampling gap, since a similarly brief flag
    (`wallRideHeld?`) still got caught 14 times at the same cadence. See
    [PLAYER_FIELDS.md](PLAYER_FIELDS.md) for the full field map and
    [agent_docs/verified.md](../../agent_docs/verified.md) for the dated, evidence-cited entries.
    **Stale as of the same day**: `weaponEquipped?`/`animEquippedWeapon` were subsequently wired
    into the actual sync path (`RemoteGhost::target_weapon_equipped`) — shipped, live-tested, and
    still not visually correct after a real throw (five straight fix attempts, root cause
    unresolved; see `verified.md`'s "Dream Breaker weapon-visibility sync" entry and
    `PLAYER_FIELDS.md`). The rest of the mapped fields (cling-gem/VFX, outfit) remain unwired.
20. **New reusable testing method, found this same investigation: comparing a genuine 0%-completion
    save against a 100%-completion save.** An inversion test (deliberately syncing the ghost the
    *opposite* of the real player's state) had already confirmed the ghost's weapon/outfit visual
    is a spawn-time snapshot, not driven by any sync code — but that only proves the sync code
    isn't the lever, not what actually is. Loading two saves with maximally different progression
    within the same running game process, dumping every reflected property's real *value* (not
    just its name/type — the existing `dump_object_reflection` schema dumper was extended into a
    new `dump_object_property_values`) right at ghost spawn on both, then diffing the two dumps
    (after normalizing out per-instance object IDs and level-path noise) turned a guessing game
    into an exhaustive, evidence-based search: it found the *one* field that actually differs
    between an armed and unarmed spawn (`animEquippedWeapon` on `animBPref`) out of 230 properties
    checked, and separately proved `WeaponMesh`'s own component state is provably identical in
    both saves across all 250 of its properties — ruling it out as a suspect entirely, not just
    the four properties anyone had thought to check by name. **General technique, not
    weapon-specific**: whenever two known game states produce a visibly different result and the
    responsible field isn't obvious, load a save representing each extreme, dump every reflected
    property's value at the moment that matters, and diff — this finds the field(s) that actually
    differ without having to guess field names first. Diagnostic code:
    `dump_object_property_values` in `Plugin.cpp`, gated behind `DUMP_GHOST_SPAWN_VALUES`. See
    `verified.md`'s two "cross-save" entries for the full evidence.
21. **Dream Breaker held/thrown visibility bug FIXED, 2026-08-15 — root cause was a call-order
    bug, not a missing property or function.** Step 20's diff found `animEquippedWeapon` as the
    one field that actually correlates with sword-equipped state, on `animBPref`. But the
    ghost-write code had been setting that raw property directly, unconditionally, every tick —
    *before* the edge-gated `changeEquippedWeapon`/`updateWeaponEquip` calls that were meant to be
    the real trigger. So by the time either function ran on a real throw, the property had already
    been overwritten to the new value on that same tick; if either function's own Blueprint graph
    does the ordinary "only play the transition if the value changed" comparison, it would always
    see old==new and do nothing — explaining why both function calls had failed identically
    despite both being confirmed to fire. **Fix: reorder so the function calls run first, while
    the ghost's property still holds the old value, with the property write kept afterward as a
    safety-net.** No new function or property needed — both candidates from step 19 were right all
    along. **Confirmed live**: user watched the ghost's sword disappear on a real throw. See the
    fix itself in `Plugin.cpp`'s `tickRenders` (Dream Breaker block) and
    `agent_docs/verified.md`'s "Dream Breaker weapon-visibility: animBPref cross-save diff" entry
    for the full before/after evidence; also written up as a general UE4SS/Blueprint-reflection
    lesson in `agent_docs/pitfalls.md`'s "Engine reflection / API availability" section
    ("Writing a property directly before calling a function that also sets that property can
    silently defeat the function").
22. **Outfit/costume sync FIXED, same day.** Unlike weapon, no boolean flag or `animBPref`
    indirection at all — a live value-diff straddling real costume swaps in the in-game menu found
    `VisualMesh`'s own `SkeletalMesh`/`SkinnedAsset` properties swap directly to a different mesh
    asset per outfit; `AnimClass` and skeleton stay constant across every variant, so a plain
    mesh-asset reference is the whole mechanism. Sent as the asset's real object path; the ghost
    resolves it via `StaticFindObject` (grounded in RE-UE4SS's own official C++ mod guide). First
    live attempt (a raw property write) T-posed the ghost instead of showing the new costume — the
    mesh reference stuck (readback confirmed) but the engine never re-bound the anim instance
    against it. A live function-name dump of `VisualMesh` found `SetSkeletalMeshAsset` as the one
    real candidate this build's reflection exposes (no `SetSkeletalMesh`/`InitAnim`/
    `MarkRenderStateDirty`); calling it *before* the property write — applying step 21's ordering
    lesson proactively this time, not after another failed test — fixed the T-pose. **Confirmed
    live**: user screenshot, ghost correctly wearing the swapped costume, no T-pose. Two follow-up
    hardening passes, reasoned through rather than hit by a live bug: a class-type check before
    applying (the resolved object is peer-controlled data, and an unchecked `StaticFindObject`
    match could otherwise write a non-mesh object into the mesh property slot), and a retry
    throttle (a target that fails to resolve — e.g. a peer's outfit mod this machine lacks — would
    otherwise retry and re-log a warning every single tick forever). **Notable emergent property,
    not a deliberate feature**: because nothing here hardcodes which outfits exist — it just reads
    and sends whatever asset is actually equipped — any *modded* outfit works automatically between
    two peers who both have that mod installed, no per-mod code required. A peer without it simply
    keeps seeing their own default outfit on that ghost rather than breaking (the ghost is a clone
    of the *receiving* peer's own pawn, so it already starts dressed as them before any sync runs).
    See `agent_docs/verified.md`'s two "Outfit/costume sync" entries for the full evidence and the
    untested edge cases (asset must be loaded into memory, not just installed, to resolve).

See [agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) for the detailed, dated
log, and [agent_docs/pitfalls.md](../../agent_docs/pitfalls.md) for the transferable lessons
pulled out of this saga (auto-possession on spawn, camera/view-target
ownership, runtime-spawned actors not rendering, the `on_update()`-isn't-the-game-thread bug,
the LuaSocket corruption bug behind the Lua-to-C++ rewrite, and the UE5 `FRotator` marshaling
bug behind the facing-direction fix).

### Further work past "good enough"

Not reached yet — Phase 7.7 (a real two-player test) is still outstanding. Add entries here
once work continues past that point.
