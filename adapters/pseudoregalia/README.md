# Pseudoregalia

**Status: Phase 7, 7.0–7.8 done. 7.7 (real two-player test) confirmed 2026-08-16** — two players
on two machines. First release package cut 2026-08-13, still marked experimental/pre-release
because that is one session on one pair of machines, not broad testing. See
[agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) and
`packaging/release/games/pseudoregalia/README.txt`.

- Unreal Engine 5, small movement-focused 3D platformer. Worst starting point (no source, no
  BepInEx) but best genre fit for ghost co-op, per the brief.
- **How the game is read: runtime reflection only — no readable source exists anywhere.** A Shipping
  build with Blueprints compiled to bytecode, so there is no decompilation, no symbols, and no
  source text even in the one reference mod available (it is Blueprint-only). Every property, class
  and function is a **name string resolved live** through UE4SS, and a wrong name does not fail to
  compile — it returns nothing, or something plausible. Everything had to be discovered by
  enumerating the running game, which is why this adapter is far and away the largest and hardest of
  the three, and why it produced most of the project's tooling and lessons. See
  [agent_docs/access-models.md](../../agent_docs/access-models.md) and
  [agent_docs/effect-investigation.md](../../agent_docs/effect-investigation.md).
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
polish; Phase 7.7 (a real two-player test) was confirmed 2026-08-16. Started in Lua, then had to
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
24. Stopped the ghost sinking into the floor mid-slide: the same shrink drops the capsule's
    origin by 43 units, so a full-height ghost placed there sat 43 under the floor. Compensated
    the render height instead of mirroring the capsule. Superseded by step 44. (7.6)
25. Added the cling-gem (wall-ride) VFX by calling the pawn's own wall-run function on the ghost,
    with the paired sound suppressed — ghosts are a visual-only layer. (7.6)
26. Synced the trail colour, modded colours included. The ultra hop's blue trail turned out to be
    a separate mechanism and is parked — it isn't derivable from any polled state. (7.6)
27. Fixed enemies damaging a ghost hurting and killing the *real* player, by moving the ghost's
    capsule off the collision channel enemy targeting queries. Ghost collision is now kept ON as a
    deliberate feature; whether it's actually fun is still an open keep-or-axe call. (7.6)
28. Two negatives worth not re-walking: hooking Blueprint functions crashes this build (native
    ones are fine), and the empty-hand recall glow needs a real thrown-weapon actor to exist
    before it will do anything — you can only trigger the game's own systems when their
    preconditions are state you can write. (7.6)

29. Fixed the sword *throw* animation, which step 21 didn't cover: the throw isn't a state the
    ghost could mirror at all, it's an animation montage. The game's own "play montage" function
    silently does nothing on a ghost, but the engine's own one underneath it works — so the ghost
    now plays whatever montage the real player plays, throw included. (7.6)
30. Proved the ghost re-starts animations *on its own*: with every montage call in the mod
    compiled out, it still began the ledge-grab montage by itself. It turned out our own state
    sync drives the game's animation graph, which is the system working as intended — a ghost
    just can't *finish* a montage, having no controller, so the peer now corrects it. (7.6)
31. Checked the animations nobody had ever triggered by playing them straight onto the ghost,
    which sidesteps not knowing how to trigger them in-game. All 8 worked with no new code —
    guarding, getting up, summoning, channelling, and the map-reading idle. (7.6)
32. Added the bubble's yellow flash, after mistaking it for two other effects first: an
    afterimage trail, then an eye-blink timeline. It is neither — the game has its own
    `StartBubbleJumpFlash`, and its own flag saying how long it lasts, so the ghost now asks the
    game instead of counting. Every wrong guess was caught by watching, never by a log. (7.6)
33. Made the *thrown* sword real on a ghost — flying, bouncing off walls, planted in the ground
    with its glow. It's a separate actor, so the ghost now spawns its own copy per throw and
    replays the peer's position; the bounces come free, since the peer's game already worked them
    out. Collision stays off, or you could walk into a peer's sword and pick it up. (7.6)
34. Fixed that copy sinking through the floor, after two wrong fixes. The giveaway was that
    nothing in its position ever changed — because the check was reading the position back right
    after writing it, which can't see anything that moves between frames. Reading it *before*
    showed plain gravity: the sword's own movement component, still falling. (7.6)
35. Gave the ghost the glow you get when empty-handed near a save crystal. Instead of working out
    the rule — nobody had guessed the crystal part — the mod just checks whether the real effect is
    showing and copies that, so any condition we never noticed comes along for free. Found by
    playing all 58 of the game's effects onto the ghost until one was recognised. (7.6)
36. Worked out where the ultra hop's blue trail comes from, after it had been written off as
    unsolvable. It was never a particle effect at all — an afterimage is a posed copy of the
    character, and each one carries its own colour. Switched back off at the time; see steps 37–40
    for why, and for how long it then took to actually land. (7.6)
37. Broke the slide trail and spent most of a night finding out we'd done it ourselves: the very
    probes measuring it were spawning extra afterimages and stalling the game, so the real ones got
    cut short. Every measurement said the ghost matched the player, because the images that survived
    *were* right. Comparing old commits found it in three builds — a first for this project. (7.6)
38. Got the ultra hop's blue trail actually working on the ghost — **the hardest single thing to
    sync in this adapter, and the longest.** Perfect-timing hops trail blue instead of yellow, and
    copying that one colour turned out to touch nearly everything about how afterimages work. It was
    never really one feature: the blue sat on top of the trail system, so it kept becoming the
    trail's other problems instead — what makes a burst fire, how the game recycles the images,
    how many the ghost ends up drawing. Step 37's regression and this project's first commit
    bisection were both hit on the way here. (7.6)
39. Five rounds to land it, each fixing a real bug that only exposed the next one. The colour was
    read and then thrown away; then it arrived a whole slide late; then it bled into the slide
    afterwards; then the ghost drew two blue images where the game drew one. Every round the ghost
    was wrong in a new way, and every answer came from a log line rather than a theory — twice the
    fix that looked obvious would have hidden the cause instead of fixing it, which is worse,
    because it would have looked right on the day. (7.6)
40. What finally worked was giving up on predicting the game. Each fix swapped a guess for something
    observed: read the colour off the afterimage itself rather than off the player, trail when the
    game really spawns images rather than when we reckon it should, and check that an image was born
    where the player is, so a recycled one isn't counted as a new one. The last of those is the same
    trigger question as step 23, rebuilt a fourth time — three earlier attempts all re-derived a
    rule that was never ours to own. (7.6)
41. Fixed the ghost trailing when the real player doesn't — a mistimed slide or hop is meant to leave
    you neutral, and the ghost trailed anyway. Same cause as step 40's third guess: our trigger fired
    on the move being *attempted*, the game's fires on what it decided to draw. Switching to the
    game's own spawns also closed a separate complaint nothing was aimed at — the ghost had been
    drawing 1-2 more afterimages than the player, which turned out to be the same bug seen from the
    other side. Player and ghost are now indistinguishable, trailing and not trailing alike. (7.6)

42. Made the mod start MeshGhost itself, so there's nothing to run before the game. A speedrunner
    who tried this said the separate client exe defeated the point — the good encounters were the
    unplanned ones, and nobody launches a second program for those. The mod now spawns it hidden
    when it finds nothing on the bridge, which also means a client that's already running gets used
    rather than duplicated. It passes no relay settings, only a working directory, so the core still
    reads its own config and the adapter still knows nothing about the relay. (7.7)

43. Stopped a sliding ghost sinking into the floor — the quick way, and the wrong object. A slide
    halves the character's capsule and drops its centre by the same amount, so a ghost teleported to
    that lowered position buried itself 43 units. Raising the ghost's render Z by exactly that
    amount looked perfect immediately, and it was still a compensation: it moved the whole actor to
    fix a mesh problem, so the ghost's position became a lie that anything reading it inherited. It
    did, once — the thrown-sword prop picked up the same bug. It also handled a stationary crouch
    correctly by pure accident, because a crouch shrinks the same capsule. (7.8)

44. Replaced it with the game's own crouch path, which took ~15 live test cycles and was the
    adapter's hardest fix alongside the ultra hop. Nine plausible levers each applied cleanly and
    changed nothing — the capsule, `bIsCrouched`, `bWantsToCrouch`, the mesh offset itself. What
    finally worked came from dumping all 473 of the pawn's functions instead of a filtered subset,
    which revealed the slide is driven by a Blueprint Timeline whose update handler can be called
    directly. The fix needs five mechanisms **together**, every one of which tests negative alone:
    mirror the peer's capsule, drive the timeline with the peer's own curve position (a new
    `slide_t` field), fire the crouch input and crouch events, and set/clear `bIsCrouched` on the
    peer's edges. The ghost now poses itself the way the game poses the player, its position is
    honest again, and the compensation is deleted. (7.8)

> **Steps 38–41 and 43–44 are deliberately longer than the rest of this list — please leave them
> that way.**
> The house style for these steps is 2–4 lines each (see `CLAUDE.md`), and that rule is a good one:
> it exists because steps 19–22 once grew to 15–20 dense lines and made the list unreadable. These
> are the intentional exceptions, at the user's request: 38–41 because the ultra-hop blue trail was
> the hardest and longest-running piece of work in the adapter, and 43–44 because the slide pose is
> its equal and only makes sense told as a pair — the easy fix that looked perfect, then the real
> one that replaced it. Trimming them back to match the others would be a reasonable-looking edit
> that loses the point on purpose.

See [agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) for the detailed, dated
log, and [agent_docs/pitfalls.md](../../agent_docs/pitfalls.md) for the transferable lessons
pulled out of this saga (auto-possession on spawn, camera/view-target
ownership, runtime-spawned actors not rendering, the `on_update()`-isn't-the-game-thread bug,
the LuaSocket corruption bug behind the Lua-to-C++ rewrite, and the UE5 `FRotator` marshaling
bug behind the facing-direction fix).

### Further work past "good enough"

The ghost passed "good enough" around step 18; steps 19–44 are all polish past that line. Still
open as of 2026-08-17 — [agent_docs/status.md](../../agent_docs/status.md) is the authoritative
list:

- A sword thrown near a save crystal. Provably synced; loopback puts the ghost beside the
  geometry, so a second player is needed to judge it. (Pole rotation, same suspicion, came back
  fine on the two-machine session.)
- Ghost vanishes while a peer is on a climbing pole, then returns stuck in a climb pose.
- Duplicate ghost spawn on every level load — two ghosts per peer, leaving an orphaned pawn.
- Suspected: the mod may not clear ghosts when the bridge drops.
- A `Fatal Error!` on game exit, seen once, never root-caused.

## Dev tools

Six scripts across three folders, none of which ships — the release contains the compiled
`MeshGhostPseudo` DLL and nothing from here. They are kept because they are the record of how each
capability was established, and because two of them answer questions that would otherwise be
re-asked from scratch. Every one is a UE4SS **Lua** mod, which is what makes them cheap to run
against a live game without a rebuild; the shipped adapter is C++.

**UE4SS loads `Scripts/main.lua` and only that**, so a probe with stages swaps files rather than
taking a flag — copy the stage over `main.lua` to run it, and put the original back afterwards.

| Script | What it is for |
| --- | --- |
| `probe/Scripts/main.lua` | **Read-only.** The first thing that ran: confirms live on screen where the local player pawn, its position, its rotation and the level name actually live, before any of it was ported into C++. Writes nothing, touches no network. |
| `probe_socket/Scripts/main.lua` | **Stage 1, safe.** Asks only whether `package.loadlib` exists and is callable under UE4SS's embedded Lua. It exists because UE4SS's own API docs list no networking at all and RE-UE4SS has zero LuaSocket references — which proves nothing about `loadlib` itself, and the whole adapter's shape depended on the answer. |
| `probe_socket/Scripts/stage2_loadlib.lua` | **Stage 2, riskier.** Actually loads the vendored LuaSocket core and *creates* — deliberately does not connect — a TCP socket object. Run only after stage 1 passes. |
| `probe_socket/Scripts/stage3_roundtrip.lua` | **Stage 3.** A real bind/connect/send/receive round trip against the bridge protocol, the one thing stage 2 left untested. The staging is the point: each stage is the smallest step that could fail, which is why a crash in one of them named its own cause. |
| `probe_ghost/Scripts/diagnose.lua` | **A diagnostic, explicitly not a fix.** Written after three straight fix-and-retest cycles failed to stop the player being dragged around by a spawned ghost — the moment `CLAUDE.md`'s "two guessed fixes failing the same way is a signal" applied. It gathers evidence for the `AutoPossessPlayer` theory instead of guessing a fourth time, and that is what found the cause. |
| `probe_ghost/Scripts/main.lua` | **Superseded — a complete 849-line Lua adapter, kept for history.** This was the real Phase 7.5 adapter: local state every tick, the bridge protocol, spawned ghosts, the camera hook. It was replaced by the C++ mod after a LuaSocket corruption bug made the Lua host untenable (`pitfalls.md`), and the C++ `BridgeClient` and spawn path were ported *from* it — `MIN_PLAUSIBLE_DISTANCE` still cites it by name. Read it to see where a piece of `Plugin.cpp` came from; do not run it as the adapter. |

**Its camera fight-back is the one thing in here not to copy.** `probe_ghost/Scripts/main.lua`'s
header still describes a `SetViewTargetWithBlend` hook that forces the view target back whenever a
ghost spawn makes the game re-target. That approach was deleted 2026-08-16 for blocking every
legitimate camera change forever after, and replaced by refusing only a switch to a rig whose
`OwningActor` is a ghost — see [BANDAGES.md](BANDAGES.md) and `agent_docs/verified.md`. The file is
history, and history includes the parts that were wrong.
