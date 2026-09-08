# Pseudoregalia

**Status: FEATURE COMPLETE, declared by the user 2026-08-27** — *"i think we can consider
pseudoregalia 'feature complete' at this point as well"*. **That declaration has a written scope**,
recorded the same day in [VERIFIED.md](VERIFIED.md) along with what it explicitly does *not* cover,
so a later session cannot quietly widen it. [UNVERIFIED.md](UNVERIFIED.md) is the live queue of what
is built but unwatched.

- Mod Compatability: Archipelago, AttireUiOverhaul(outfits,weapons,after image color)
  - Should also hopefully work together with any other mods

Still marked **experimental/pre-release** in the shipped package, which is a different claim: the
features are there, the breadth of testing is not. Phase 7 (7.0–7.8) is done and 7.7, a real
two-player test on two machines, was confirmed 2026-08-16; first release package cut 2026-08-13.
Work after 2026-08-17 has no phase sub-number — `phase7.md`'s task list ends at 7.8, and this
adapter's own `VERIFIED.md`/`UNVERIFIED.md` are where everything since is recorded. See
[agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) and
`packaging/release/games/pseudoregalia/README.txt`.

**This adapter's files**, since there are now seven and nothing introduced them:

| File | Answers |
| --- | --- |
| [documentation.md](documentation.md) | How does *the game* do X? |
| [PLAYER_FIELDS.md](PLAYER_FIELDS.md) | Which fields exist, which we sync, how to promote one |
| [FLAGS.md](FLAGS.md) | What every compile-time switch does, and which are recorded negatives |
| [BANDAGES.md](BANDAGES.md) | Where we compensate instead of reproducing the mechanism |
| [PROBES.md](PROBES.md) | The dev-only Lua probes (twenty-one folders as of 2026-09-06), what each was for |
| [VERIFIED.md](VERIFIED.md) | Dated, user-confirmed evidence — append-only |
| [UNVERIFIED.md](UNVERIFIED.md) | Believed working, nobody has watched it yet |

- Unreal Engine 5, small movement-focused 3D platformer. Worst starting point (no source, no
  BepInEx) but best genre fit for ghost co-op, per the brief.
- **How the game is read: runtime reflection only — no readable source exists anywhere.** A Shipping
  build with Blueprints compiled to bytecode, so there is no decompilation, no symbols, and no
  source text even in the one reference mod available (it is Blueprint-only). Every property, class
  and function is a **name string resolved live** through UE4SS, and a wrong name does not fail to
  compile — it returns nothing, or something plausible. Everything had to be discovered by
  enumerating the running game, which is why this adapter is far and away the largest and hardest of
  the four, and why it produced most of the project's tooling and lessons. See
  [agent_docs/access-models.md](../../agent_docs/access-models.md) and
  [agent_docs/effect-investigation.md](../../agent_docs/effect-investigation.md).
- Tooling: **confirmed 2026-08-12** — UE 5.1 (`++UE5+Release-5.1-CL-23901901`, read from
  `pseudoregalia-Win64-Shipping.exe`); UE4SS **v3.0.1 Beta, Git SHA `733e5969`**, installed
  under the newer `Binaries\Win64\ue4ss\` layout. **That UE4SS line is known stale, not merely
  at risk of being**: a 2026-08-13 `AP_Randomizer` reinstall silently rewrote the *shared*
  `UE4SS.dll`/`dwmapi.dll`/`UE4SS-settings.ini` to a different build, and the log banner the
  version above was read from predates that swap — so it does not identify what is installed
  now. Re-read `ue4ss\UE4SS.log`'s banner fresh before trusting it for real work. Full record,
  including the mid-Phase-7 update from an older v2.5.2:
  [agent_docs/environment.md](../../agent_docs/environment.md)'s Unity/TEVI, UE5/Pseudoregalia
  section.
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
  real traffic, not "Lua can't do sockets" as first assumed. See build-log step 6 below and
  `agent_docs/pitfalls/by-host.md`'s "Host-embedded scripting runtimes" section for the full
  diagnostic trail (`pitfalls.md` itself is now an index over that folder).
- The Archipelago randomizer for this game
  ([pseudoregalia-archipelago](https://github.com/pseudoregalia-modding/pseudoregalia-archipelago))
  was checked into [agent_docs/licensing.md](../../agent_docs/licensing.md) 2026-08-12: **no
  LICENSE file, all rights reserved.** Consulted for facts only (its `.gitmodules` UE4SS pin,
  its general mod structure) — no source copied, per the standing "facts, never code" rule.
- No source is or will be copied from any randomizer or modding project without checking
  its license first — see [agent_docs/licensing.md](../../agent_docs/licensing.md).

## Custom features

- Outfit/costume mod support, if you have the same mod installed as another player it will get
  synced for you.
- Weapon model mod support, the same way (2026-09-05): a peer's sword model is sent by asset name
  and shows on their ghost if you have that weapon mod installed; the thrown sword follows.
- Trail (afterimage) colour, including modded colours — the colour is read live off the real
  player and sent, rather than hardcoded, so a peer running a colour mod shows up with their own
  trail colour on your screen.
- Custom nametags above players

## Performance, and how it scales with a crowd

Measured 2026-09-01, the day a peer-ladder session (0 → 150 synthetic peers) found and removed
three scaling ceilings in one afternoon — a relay message that grew with room size and killed
every joiner above ~100, a connection-framing bug under write pressure, and a game-thread drain
that replayed queued history instead of keeping the newest state per player. Before any of this,
on 2026-08-30, **a single ghost cost the game half its frame rate** (144fps → 70) because of four
whole-world scans running per tick; those were found with a per-subsystem frame timer and scoped
to what a ghost actually owns. After all of it:

| Peers | 2026-09-01 | 2026-09-06 (mean / median fps) | Adapter's own tick |
|---|---|---|---|
| 0 | ~143 | 144 / 144 | 0.16 ms |
| 4 | ~133 | 144 / 144 | 0.57 ms |
| 8 | ~124 | 143 / 144 | 0.77 ms |
| 16 | ~82 | 143 / 144 | 1.25 ms |
| 32 | ~53 | 96 / 106 | 2.47 ms |
| 100 | ~12 | 30 / 33 | 7.6 ms |
| 150 | ~4.5 | 17 / 14 | 15.8 ms |

The 2026-09-06 column is the same ladder after a day of measuring what a ghost costs (`VERIFIED.md`
and `UNVERIFIED.md`, that date): the adapter's own per-ghost work cut, its fixed cost with no ghosts
gone, a leak closed, and the per-spawn light repair off. Player idle in the dungeon, cap on, each
count held a minute before a 10 s sample. For 100 and 150 the synthetic peers had to be throttled
(the relay fanning out at 20 Hz, each fake client rendering 5 times a second) or the rig itself
churned; they run on the same machine as the game and take CPU from it, so those two rows are a
floor, not the adapter's ceiling.

So a **~16-player room costs nothing you can see, ~30 stays above 90fps** on the test machine — and 150
ghosts *work*, in the sense that every one spawns, animates and wears its nametag, degrading into
a stable slideshow rather than a freeze, and recovering within seconds of the crowd leaving. The
caveats and the exact per-ghost numbers live in
[agent_docs/crowd-limits.md](../../agent_docs/crowd-limits.md) (the cross-game home for "how many
ghosts can a game hold", alongside Emerald's and Crystal's measured ceilings); what remains on
the table — the per-ghost redraw span that dominates the cost, instrumented and waiting — is
filed in [UNVERIFIED.md](UNVERIFIED.md).

## How this adapter was built

Third game, and by far the hardest: roughly 15-20 hours to reach "good enough" — a ghost that
follows, animates, and faces the right way (the end of step 18 below). Everything after that is
polish, and it runs a long way: a real two-player test was confirmed 2026-08-16, and the adapter
was called feature complete on 2026-08-27 (step 53). Started in Lua, then had to be substantially
remade in C++ partway through once Lua proved unable to reliably send everything the adapter
needed.

Most of this is one phase, [agent_docs/phases/phase7.md](../../agent_docs/phases/phase7.md) —
the sub-numbers below (7.1, 7.4,
etc.) are that file's own task headings, called out here for anyone jumping straight to the
detailed log instead of reading the whole thing top to bottom. **They stop at step 44**: that
file's task list ends at 7.8, and steps 45 onward belong to no phase number at all. Their
evidence is in this folder's own [VERIFIED.md](VERIFIED.md), one dated entry per step. It reads
as a much smoother
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
   the player. Hooked the game's own camera-retarget call and forced it back. (7.4)
   **That fight-back was deleted 2026-08-16 and is not what ships** — it blocked every
   legitimate camera change for the rest of the session, and the real cause turned out to be
   the ghost bringing its own camera rig. See step 10 and `BANDAGES.md`.
5. Tried making a statue already present in the stage follow the player, as an alternative
   to spawning a new actor — this is also what seemed to prove runtime-`SpawnActor`'d actors
   weren't rendering at all on this build, while hijacking an existing level object did — a
   verdict later overturned; see step 11. (7.4)
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
    switching to the lower-level hook it offers for native functions. (7.6) **The native hook
    is what ships; forcing the camera back through it is not.** On 2026-08-16 the ghost was
    found to bring its **own camera rig**, and that rig is what the game was switching to — so
    the hook now refuses exactly one thing, a switch to a rig whose `OwningActor` is a ghost,
    and lets every other camera change through. `VERIFIED.md`, `BANDAGES.md`.
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
    real player's own character too. (7.6) **On, then off again: collision was turned back ON
    2026-08-15 as a deliberate feature (step 27), and OFF again 2026-08-27 at the user's
    request. Ghosts are not solid today** — `FLAGS.md`'s `GHOST_COLLISION_ENABLED` is the
    register, and it gates the work, not just the decision.
15. Figured out how to drive the ghost's facing direction — found via a forced test rotation
    (to tell "the write is dead" apart from "the write lands wrong") that it was landing as
    ≈0; traced to a marshaling bug in the vendored UE4SS SDK that only affects `FRotator` on UE
    5.0+, worked around with a local, version-aware helper rather than patching the
    (un-committable) submodule. (7.6)
16. Fixed the ghost getting stuck in a falling animation. (7.6)
17. Fixed the ghost getting stuck in a ledge-hang animation. (7.6)
18. A leaving ghost was moved into the void rather than deleted, because `K2_DestroyActor`
    appeared to silently no-op — a property of the *hijacked* actor, not of the build. Since the
    ghost became one we spawn, it is destroyed properly; parking is only the fallback. (7.5)
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
    the render height instead of mirroring the capsule. The same compensation is told in full as
    step 43; superseded by step 44. (7.6)
25. Added the cling-gem (wall-ride) VFX by calling the pawn's own wall-run function on the ghost,
    with the paired sound suppressed — ghosts are a visual-only layer. (7.6)
26. Synced the trail colour, modded colours included. The ultra hop's blue trail turned out to be
    a separate mechanism and is parked — it isn't derivable from any polled state. (7.6)
27. Fixed enemies damaging a ghost hurting and killing the *real* player, by moving the ghost's
    capsule off the collision channel enemy targeting queries. (7.6) **Dead code today**: the
    keep-or-axe call went the other way on 2026-08-27 and collision is off, so this whole fix
    compiles out with it. It stays because it is the answer if collision ever comes back — and
    because the cling-gem VFX (step 25) was only ever confirmed with collision ON, which makes
    it the thing most likely to have quietly regressed. `UNVERIFIED.md`.
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
    cycling the game's Niagara catalog onto the ghost — 58 systems, narrowed to 10 by a name
    filter — until one was recognised. (7.6)
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
    rather than duplicated. It passes no relay settings — only the bridge port and its own
    process id, with the core reading its own config out of the working directory — so the
    adapter still knows nothing about the relay.

43. Stopped a sliding ghost sinking into the floor — the quick way, and the wrong object. A slide
    shrinks the character's capsule half-height from 65 to 22 and drops its centre by the same 43
    units, so a ghost teleported to
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

45. Fixed the player's health bar sitting permanently full whenever a ghost was around. It was
    never the health — a ghost is a clone of the player's own character, so it runs the same
    startup and builds **its own health bar**, full, on top of the real one. Removing the ghost's
    copy fixed it. Two earlier fixes failed the same way and taught the same thing: a reference is
    not the thing, and a widget belongs to its parent rather than to whoever points at it.

46. Fixed the ghost's shadow sticking to its feet in mid-air instead of falling to the ground.
    The shadow hangs off a spring arm whose length is how far it may drop before it finds floor —
    5000 on the player, and 100 on the ghost because nothing had ever set it. Mirroring the real
    player's own value fixed it. Calling the game's own shadow function was tried first and did
    nothing; the readback is what caught that, rather than the user.

47. Fixed a ghost's healing effect appearing in the wrong place, after two wrong placements. The
    game does not attach the heal's waves to the character at all — it drops them at a world
    position, at the top of the model. The third attempt read that height off the real player's
    own effect as it fired instead of choosing a number that looked right.

48. Stopped a ghost's attacks damaging the local player — **the only non-cosmetic bug this adapter
    ever had**, and the one thing the project forbids outright. Mirroring a peer's attack animation
    runs the game's real attack code on the ghost, which finds the player and hurts them. The fix
    is the game's own already-hit list: the player is marked as already hit before the ghost's
    first swing, which is why only the *first* attack ever landed in the first place. Six other
    candidates were each closed by a live run and left in the code as recorded negatives.

49. Made the mod's autostart actually fire (step 42's feature, which a developer with a client
    already running would never have seen fail). It was looking for a free port by connecting and
    waiting to be refused — and on this machine a closed port is never refused, the connection is
    simply dropped. It now asks the OS instead: a free port is one it can bind.

50. Mirrored a peer's ranged shot, after holding the game's own projectile actor crashed the game.
    A thrown sword rests where it lands and is ours to keep; a projectile belongs to the game,
    which destroys it on impact. The ghost now replays the shot's *effect* along the peer's sampled
    path and holds nothing. It still fired only once until a second discovery: this game pools
    those actors, so a spent one keeps existing and "it exists" never meant "it is in flight".

51. Gave a ghost death, the pit, the hurt flinch and the respawn — four effects, all found by
    measuring rather than by guessing names. The death flash turned out not to be a particle effect
    at all but an animated material, which no particle watcher could have found; a promising-looking
    `startBlink` shipped as a fix first and did nothing, because it is the character's eyes.

52. Stopped a ghost's afterimages drawing through walls, at zero frames rather than one. Every
    reactive version made the flicker briefer and never gone, because an afterimage is born with
    the outline already on and the frame is drawn before any of our code runs. The fix refuses the
    outline at the moment the game switches it on. It has to decide before the game says whose the
    image is, so an unattributable one is refused and given the outline back a tick later if it
    turns out to be the player's — wrong in the direction nobody can see.

53. **The user called the adapter feature complete** (2026-08-27): *"i think we can consider
    pseudoregalia 'feature complete' at this point as well"*. The scope was written down the same
    day rather than left implied — body and motion, the whole effect set, the correctness fixes
    above, and the plumbing that starts the client — **together with what it does not cover**: the
    black flash when a ghost appears, two uncaught crash reports, the port walk's second-instance
    case, and anything confirmed only in loopback. [VERIFIED.md](VERIFIED.md) has both halves.

54. Fixed three bugs the same evening, all one family: state that outlives a level and is never
    dropped before the level's teardown. The VFX mirror's component map crashed "retry last save";
    the camera fallback pointer crashed starting a new game; and the hurt mirror's health baseline
    made the ghost flinch on every save-file swap. All three fixes are the same move — clear it in
    the LoadMap PRE hook, where the ghost pointer has always been kept safe. A fourth finding fell
    out for free: health carrying over between save files is the base game's own behaviour, proven
    by the user's no-ghost control run.

55. Gave each peer a nametag, then gave it a colour — as a plate, not as coloured text. Text
    itself cannot be coloured on this build (the default text material ignores every parameter,
    the translucent one is not cooked, vertex colour reaches nothing), so the name is drawn twice:
    black glyphs in front, and behind them the same string through a colourable opaque material,
    which renders as solid blocks the exact width of the name. Opaque matters — the game's black
    room dividers draw over anything translucent, at any sort priority. Confirmed with three
    instances at once, one per case: name with colour, name without, and neither.

56. Put out the light a ghost brought with it. Every spawned pawn carries the Blueprint's default
    5000-intensity ascendant light plus a camera rig nobody looks through, additively brightening
    the room per peer; both are now held dark/neutral, and after every spawn the level's own
    light repair (`FixAllLights`) ran — the same call a light transition makes. Watched by the
    user, 2026-08-30. **The repair no longer runs by default**: on 2026-09-06 it measured 18 ms
    per ghost and the spawn-tick light kill had already made it unnecessary, so it is off behind
    `ghost_fixlights_on.txt` (`FLAGS.md`); step 65.

57. Root-caused the reset crash to stale nametag pointers and fixed it — a world made by "reset
    to last save" freed objects our components still referenced, so the next spawn died in the
    engine. Found with the minidump reader and the world-fingerprint probe, confirmed by the user
    2026-09-01. The spawn also now waits for a stable local pawn (`SPAWN_DELAY_TICKS`).

58. Made a crowd affordable: 150 ghosts live in one room, roughly 30 above 50fps, after removing
    per-ghost whole-world scans (per-ghost cost 6283 → 309 us) and unarming flag-gated sweeps
    that ran with no toggle present. The same ladder fed the project-wide 15Hz send-rate default,
    acquitted by a blind 15-vs-20 A/B the user scored at chance. Measured 2026-09-01; the
    2026-09-06 ghost-cost work superseded these figures, and the re-run table above is the current
    picture (32 peers went from ~53 to 96/106 fps). `VERIFIED.md` and
    `agent_docs/crowd-limits.md`.

59. Rebuilt the thrown sword as our own flyer component after the game's own class kept claiming
    the watcher's player (`create_ghost_weapon_flyer` — pose, glow, bounce effects and blob
    shadow driven from the peer's samples), and confirmed it on two real peers, 2026-09-01. The
    peer-named-asset catalog gate landed the same day: a peer's asset name resolves only through
    the local game's own loaded assets.

60. **Gave the player their sound effects back** (2026-09-04): every ghost, being a clone of the
    player pawn, re-pointed the game's audio listener at its own capsule on spawn, so once it
    despawned every spatialized sound attenuated to nothing while the music played on. Proven in
    Lua first at the user's request, then built: the mod corrects the call AFTER the engine has
    applied it, because in front of it the ghost's value simply overwrote the fix. Both silences
    (despawn, zone crossing) confirmed gone. [VERIFIED.md](VERIFIED.md); the game fact is in
    [documentation.md](documentation.md).
61. **A recording indicator, and the shapes tuned live** (2026-09-04/05): a red square and an
    elapsed clock in the top right while the core records, parented to the view. Every number
    was judged through a tuning file the mod re-reads while the game runs, then baked as the
    defaults once the user pixel-peeped it; the whole thing is plates, because coloured text draws
    black here. [VERIFIED.md](VERIFIED.md), both entries dated 2026-09-05.
62. **The reset-to-save crash, closed by removing our own hook** (2026-09-05): three symbolized
    dumps in one night showed the pause menu's Reset click reading null with the mod's pre-hook
    armed, whatever the hook did -- including nothing. The hook was a 2026-08-30 mitigation that
    only ever armed by accident; it is gone, resets release ghosts at LoadMap PRE, eleven resets
    clean by the user's spam recipe. [VERIFIED.md](VERIFIED.md).
63. **The chaser holds through a pause, and stops blinking** (2026-09-05): the adapter sends
    `player_frozen` from the world's pauser field (the pause menu and the item popup both use the
    engine's pause -- a Lua probe found it, `PROBES.md`) and the core's chaser clock stands still
    while it is set. The same night, eight chasers reproduced the despawn/respawn cycle: the
    core's chaser queue was sized for 100 samples a second and this adapter sends ~180; the tap
    now thins to 100. Both confirmed on screen. [VERIFIED.md](VERIFIED.md), ADR 0053.
64. **The blue outline that stuck to the player's sword** (2026-09-05): the afterimage sweep
    stripped custom depth from everything an afterimage referenced, and an afterimage's
    `cachedMesh` is the player's own body -- so a player afterimage attributed to a ghost turned the
    body's outline off for good, and the sword drew through it. Found with three hot-loaded Lua
    probes (flags, a pre/post hook on the engine setter with owner attribution, a restore call);
    fixed by making both strips prove ownership first. The outline on the player behind a ghost
    stays, by the user's call: the pass ignores stencil, and a ghost writing custom depth shows
    through walls. Confirmed on screen. [VERIFIED.md](VERIFIED.md), `probes/probe_outline/`.
    (Steps 61-64 were numbered 54-57 and sat above 54-59 until 2026-09-06, and step 60 is new;
    `phase7.md`'s 2026-09-05 entry cites the outline fix as "step 57" — it is this one.)

65. **A ghost's cost, cut where it actually was (2026-09-06).** A day of measuring with 8-50 ghosts:
    the adapter's own per-ghost tick was half the bill and is a third cheaper (cached lookups, one
    shared enumeration per tick); the fixed cost with no ghosts at all was five whole-world scans on
    short cadences and is now ~0.2 ms (object registries fed by UE4SS's construction callback); a
    leak of one-shot effects that never auto-destroyed is closed; and the spike at every spawn was
    an 18 ms light repair per ghost that the spawn-tick light kill had already made unnecessary --
    off, spawns spaced one per two ticks. Eight idle ghosts hold the 144 fps cap at the same p95 as
    none. `UNVERIFIED.md` and `VERIFIED.md`, the 2026-09-06 entries.
66. **Distance tiers at the user's own marks (2026-09-06).** Full fidelity to 6,500 units, reduced
    animation rate to 8,500, frozen pose to 10,500, dormant beyond -- model hidden, ticks off, only
    the nametag left so someone knows a player is there. The numbers come from an anchor ghost and a
    walk down a castle hall, not from a guess; three config keys, re-read live.
67. **The nametag knows the outfit, and modded swords reach ghosts (2026-09-06).** The tag sits a
    fixed gap above the outfit asset's own declared top (clamped to a sane window for an asset that
    lies), so it moves with every outfit swap; and the weapon-mesh sync no longer waits on a flag
    this build does not reflect, which had silently kept every modded sword off every ghost.

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
log up to 2026-08-17 and [VERIFIED.md](VERIFIED.md) for everything after it, and
[agent_docs/pitfalls/](../../agent_docs/pitfalls/) for the transferable lessons pulled out of this
saga (auto-possession on spawn, camera/view-target ownership, runtime-spawned actors not
rendering, the `on_update()`-isn't-the-game-thread bug, the LuaSocket corruption bug behind the
Lua-to-C++ rewrite, and the UE5 `FRotator` marshaling bug behind the facing-direction fix).

### What is still open

The ghost passed "good enough" around step 18, and everything after it is polish; the user called
the adapter feature complete on 2026-08-27. That is not the same as finished, and the difference is
kept in two places rather than here, because a list in a README goes stale without anything
noticing — this one did, for ten days, and it is the reason this section is now three lines of
pointer instead of five bullets:

- **[UNVERIFIED.md](UNVERIFIED.md)** — this adapter's own queue, and the first place to look. What
  is built, believed working, and not yet watched by anybody.
- **[agent_docs/status.md](../../agent_docs/status.md)** — the cross-cutting items that are not
  only this adapter's, and the ones waiting on a second machine.

The shape of what remains, so this section says something (re-checked 2026-09-06): one crash
family at a new engine fault site, reported by testers on v1.1.7 with the weapon-model apply on one
of the stacks — a hardened DLL is deployed and unproven, and if it recurs that feature ships off;
one visual defect nobody has explained (a black flash the moment a ghost appears, with two
mechanisms ruled out by measurement); the frame-rate residue after a despawn, root-caused
2026-09-06 to the ghost's own orphaned `BP_PlayerCam_C` camera rig and fixed in the DLL —
instrument-watched on all three despawn paths, still waiting on a session of the user's own
(`UNVERIFIED.md`); an audit of the remaining plain-byte bool reads for
the bitfield trap, first item for the next session; several things confirmed only in loopback that
a real second player would judge differently; and a handful of built-but-unwatched changes.
Nothing outstanding is a ghost failing to do something the player can do.

68. **The input track: what the player pressed, beside what their character did (2026-09-08).**
    The mod now sends the core every CHANGE of the player's input -- 11 actions as a bitmask, the
    two sticks as axes -- and the core writes them to `replay/inputs/` beside the clip, sharing its
    recording id (ADR 0056; `replay.inputs` in config.json turns it on). Three reads were tried in
    one afternoon, each chosen by a measurement: Enhanced Input's bound action value turned out to
    answer only for what the Blueprint value-binds (the move stick), so the buttons read the
    controller's own key state once per key the game's APPLIED mapping table binds to each action
    (a loaded context is not an applied one -- the factory-default context stays in memory beside
    the live bindings), and look reads the vector key state of the keys bound to it. Every offset
    comes from reflection and a jump edge is checked live against the pawn's own `jumpButtonHeld?`;
    the third run read back as the user's sequence in frames with zero disagreements. The same
    evening the track gained the camera's absolute yaw and pitch as two more axes, because a ghost
    driven from the track later (ADR 0057) needs the frame the stick was pushed in, and the look
    deltas cannot give it. The first build read the controller's rotation and a full circle of the
    camera left it unmoved: this game drives its own camera rig, so the axes come from the camera
    manager, the same read that places the recording indicator.

69. **The recording indicator as a screen-space widget (2026-09-08).** The world-space one hid
    behind geometry and drifted with the field of view, both properties of text placed in the
    camera's frame. It is two UMG widgets now, constructed at runtime from reflection with no
    asset (a border each; the clock's holds a text block), added to the viewport and placed from
    the top-left off the engine's own viewport size -- anchored placement went off-screen on this
    build. Prototyped in Lua in one session, ShareX-checked against the old look, then the same
    calls in C++. The one thing the port had to learn: the SDK's weak pointer cannot hold an
    object this mod constructs (no engine-assigned serial number), so these live in a handle that
    validates through the object array instead. [VERIFIED.md](VERIFIED.md) 2026-09-08.
70. **An on-screen input history (2026-09-08).** A fighting-game-style list beside the game: one
    row per change of what is held, the direction as one arrow, a letter per action, and a count
    in hundredths of a second, milliseconds or frames -- several at once if wanted. Fed by the
    input track's own per-frame read, so it costs one text rewrite per row change, and gated by
    the `input_display` section of config.json, shipped off. The ghost half followed the same
    night: the mod asks the client for a replay's input track in its hello, the client streams
    it half a second ahead with the moment each press is due on the ghost's own render clock,
    and the mod holds the edges per ghost and applies each one on the frame the ghost's rendered
    state reaches it -- the first time this adapter reads a render's timestamp -- then draws the
    result on a second panel of the same code, on the other side. A restart or a loop clears it
    with the ghost. Seen filling beside the ghost across seven restarts of a 22 s recording.

## Dev tools

Thirty-five dev-only Lua probe scripts across twenty-one mod folders under [probes/](probes/)
(2026-09-06 count — each probe is its own UE4SS mod directory), **indexed in
[PROBES.md](PROBES.md)** — that file is
their one home; this section says only why they exist and what to be careful of. None of them ships:
the release contains the compiled `MeshGhostPseudo` DLL plus a bundled UE4SS runtime to load it, and
nothing from these folders. They are kept because they are the record of how each capability was
established, and because two of them answer questions that would otherwise be re-asked from scratch.
Being Lua is what makes them cheap to run against a live game without a rebuild; the shipped adapter
is C++.

Two things worth knowing before running any of them:

- **UE4SS loads `Scripts/main.lua` and only that**, so a probe with stages swaps files rather than
  taking a flag — copy the stage over `main.lua` to run it, and put the original back afterwards.
  It is also why each probe has to be its own mod directory. The index stays at the adapter root
  as `PROBES.md` because it is one of the adapter's files, not a probe.
- **`probes/probe_ghost/Scripts/main.lua` is a complete working Lua adapter, not a diagnostic.** Running it
  alongside the real C++ mod puts two things on the bridge at once. It is Phase 7.5's real adapter,
  kept because it is the last version where the whole thing is readable in one file, and because the
  C++ `BridgeClient` and spawn path were ported *from* it — `MIN_PLAUSIBLE_DISTANCE` still cites it
  by name. Read it to see where a piece of `Plugin.cpp` came from; do not run it as the adapter.

That file's camera fight-back is the one thing in the probes not to copy, and
[PROBES.md](PROBES.md) says why.
