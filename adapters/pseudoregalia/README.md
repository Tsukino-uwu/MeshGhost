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

## Custom features

- Outfit/costume mod support, if you have the same mod installed as another player it will get
  synced for you.
- Trail (afterimage) colour, including modded colours — the colour is read live off the real
  player and sent, rather than hardcoded, so a peer running a colour mod shows up with their own
  trail colour on your screen.

Both work for the same reason: nothing hardcodes the list of outfits or colours, so anything a mod
changes about them syncs for free between two peers who both have that mod.

## How this adapter was built

Third game, and by far the hardest: roughly 15-20 hours to reach "good enough" — a ghost that
follows, animates, and faces the right way (the end of step 18 below). Everything after that is
polish, and Phase 7.7 (a real two-player test) still hasn't happened. Started in Lua, then had to
be substantially remade in C++ partway through once Lua proved unable to reliably send everything
the adapter needed.

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
    real player's own character too. (7.6) **Reversed 2026-08-15 — collision is now ON as a
    deliberate feature and the run-ending half of this danger is fixed; see step 27.**
15. Figured out how to drive the ghost's facing direction — found via a forced test rotation
    (to tell "the write is dead" apart from "the write lands wrong") that it was landing as
    ≈0; traced to a marshaling bug in the vendored UE4SS SDK that only affects `FRotator` on UE
    5.0+, worked around with a local, version-aware helper rather than patching the
    (un-committable) submodule. (7.6)
16. Fixed the ghost getting stuck in a falling animation. (7.6)
17. Fixed the ghost getting stuck in a ledge-hang animation. (7.6)
18. Ghosts can't actually be deleted on this build, so a leaving ghost is moved into the void
    instead, until the next stage transition clears it out. (7.5)
19. Went after the remaining visual gaps (weapon, outfit, ability VFX) by rebuilding a
    generalized reflection dumper and turning on UE4SS's own console/actor-dumper mods, then
    mapping every in-game ability to real internal field names — and a follow-up live *value*
    trace to sort genuinely live fields from persistent "obtained" flags and static constants.
    (7.6 — see [PLAYER_FIELDS.md](PLAYER_FIELDS.md))
20. Found a reusable diagnostic along the way: diff a 0%-completion save against a 100% one.
    Dumping every reflected property's *value* at the moment that matters on both saves, then
    diffing, finds the field that actually differs without guessing names first — here, 1 real
    field out of 230, plus proof that the suspected mesh component never differs at all. (7.6)
21. Fixed the Dream Breaker (sword) appearing on the ghost after a throw — the code wrote the
    raw property *before* calling the functions meant to trigger the transition, so they always
    saw old==new and silently did nothing. A pure reorder fixed it. (7.6)
22. Added outfit/costume sync — the outfit is just a mesh asset swap, sent as an object path and
    resolved by name on the other side. A raw property write T-posed the ghost; calling the
    engine's own setter first fixed that. Modded outfits work for free as a side effect. (7.6)
23. Added the slide/ultra-hop trail (afterimages), triggered off the player capsule physically
    shrinking rather than an animation-state enum — three enum-based triggers were each disproven
    live, because the enums overlap between different moves and the shrink doesn't. (7.6)
24. Fixed the ghost sinking into the floor mid-slide: the same shrink drops the capsule's origin
    by 43 units, so a full-height ghost placed there sat 43 under the floor. Mirroring the ghost's
    capsule provably didn't work; compensating its render height did. (7.6)
25. Added the cling-gem (wall-ride) VFX by calling the pawn's own wall-run function on the ghost,
    with the paired sound suppressed — ghosts are a visual-only layer. (7.6)
26. Synced the trail colour, modded colours included. The ultra hop's blue trail turned out to be
    a separate mechanism and is parked — it isn't derivable from any polled state. (7.6)
27. Fixed enemies damaging a ghost hurting and killing the *real* player, by moving the ghost's
    capsule off the collision channel enemy targeting queries. Ghost collision is now kept ON as a
    deliberate feature; whether it's actually fun stays open until a real two-player test. (7.6)
28. Two negatives worth not re-walking: hooking Blueprint functions crashes this build (native
    ones are fine), and the empty-hand recall glow needs a real thrown-weapon actor to exist
    before it will do anything — you can only trigger the game's own systems when their
    preconditions are state you can write. (7.6)

See [agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) for the detailed, dated
log, and [agent_docs/pitfalls.md](../../agent_docs/pitfalls.md) for the transferable lessons
pulled out of this saga (auto-possession on spawn, camera/view-target
ownership, runtime-spawned actors not rendering, the `on_update()`-isn't-the-game-thread bug,
the LuaSocket corruption bug behind the Lua-to-C++ rewrite, and the UE5 `FRotator` marshaling
bug behind the facing-direction fix).

### Further work past "good enough"

The ghost passed "good enough" around step 18; steps 19–28 are all polish past that line. Still
open as of 2026-08-15 — [agent_docs/status.md](../../agent_docs/status.md) is the authoritative
list:

- 7.7 itself, two real players. Also gates the keep-or-axe call on ghost collision.
- The sword *throw* animation (pickup was fixed by step 21; throw is separately blocked).
- The blue ultra-hop trail (step 26) and the empty-hand recall glow (step 28).
- Ghost vanishes while a peer is on a climbing pole, then returns stuck in a climb pose.
- A `Fatal Error!` on game exit, seen once, never root-caused.
