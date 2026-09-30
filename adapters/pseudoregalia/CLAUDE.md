# Unreal / UE4SS adapters — host rules

<!-- line-cap: 175 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**Loaded automatically** the first time this session reads or edits anything under
`adapters/pseudoregalia/`. Per-game facts live in this adapter's own `documentation.md`, `FLAGS.md`,
`BANDAGES.md` and `SYNCED.md`. **These are host rules at game scope for now**: a second Unreal game
creates `adapters/unreal/` and this file moves into it; nothing below is about Pseudoregalia.

**Capped, and part of this session's rule stack** (`agent_docs/claude-md-cap.md`): before adding, what
comes out? Evidence for each rule: `agent_docs/pitfalls/` (the stories moved out of this file: by-lesson.md,
"The stories behind the rule files"). **Before spawning or touching an actor, read
`agent_docs/checklists/before-spawning-in-unreal.md`.**

## Probe in Lua, iterate by hot reload; the C++ mod is for shipping only

**Ask this game a question with a Lua mod under `adapters/pseudoregalia/probes/`** (`probe_nametag/` is
the worked example), deployed as its own folder in the install's `ue4ss\Mods\` and reloaded into the
running game (user, 2026-08-29). **A fix is proven in Lua too, before its C++ is written** (user,
2026-09-04). UE4SS Lua has the full reflection surface (FindAllOf, StaticFindObject, ForEachProperty,
LoadAsset, UFunction calls); C++ is only needed for hooks and perf-critical paths.

- **Reload without touching the game window:** deploy `probe_reloader/` (once), then write `<ModName>
  <nonce>` to `ue4ss\Mods\MeshGhostProbeReloader\reload_request.txt`; a resident watcher calls
  `RestartMod`, so a broken probe can't kill the loop. The Ctrl+R keybind
  (`dev-scripts\pseudo-hotreload.ps1`) is the fallback and misses whenever the game lacks focus.
  **Confirm every reload in `UE4SS.log`, never from the send.**
- **A new probe folder cannot be hot-loaded** (UE4SS knows only mods enabled at launch). **Write it
  over `ue4ss\Mods\MeshGhostScratch\Scripts\main.lua` (`probe_scratch/`) and reload that**; preflight
  fails a slot left non-empty (`PROBES.md`).
- **Check `EnableHotReloadSystem = 1` in the install's `UE4SS-settings.ini` before a session that will
  iterate** (user's rule, 2026-08-31).
- **A `Mod/src` edit is not done until `dev-scripts/build-pseudoregalia.bat` has run** (CI cannot build
  it; `packaging/README.md`); the sources are LF-pinned, so normalize before building. Preflight's
  DLL-vs-source, deployed-copies and LF checks each catch a miss.

## `on_update()` is not the game thread

`CppUserModBase::on_update()` runs on UE4SS's own thread. Touching actor state from there is a data
race against the engine that presents as intermittent corruption, so it survives testing. Marshal
work onto the game thread before touching an actor.

## Never hook a Blueprint UFunction: hook native, or poll

RE-UE4SS's `RegisterPre/PostHook` swaps the `UFunction`'s own executor pointer: fine on native
functions, **crashes** on Blueprint ones. **Before a UFunction hook on any UE target, check whether the
function is native or Blueprint**; if Blueprint, poll. Don't trade a confirmed-working mechanism for an
unproven tidier one until the tidier one has been watched.

**`UObjectGlobals::FindAllOf` walks the entire object array with a superclass compare per object (~1 ms
in a lived-in world): never per ghost, never on a short cadence.** A list of "every X" is an
`ObjectRegistry` (seeded once, fed by the construction callback, re-seeded on a slow belt).

**Native is not always enough: `NiagaraFunctionLibrary:SpawnSystemAtLocation`/`SpawnSystemAttached`
hang the game thread when hooked from Lua or C++.** "Every new object of class X" comes from
`Hook::RegisterStaticConstructObjectPostCallback` (`ObjectRegistry`), never a hook on the function that
spawns it.

## The vendored SDK marshals `FRotator` as `float`, whatever the engine uses

On a UE5 game that stores rotator components as `double`, every rotation written through
`K2_SetActorLocationAndRotation` and its neighbours is silently wrong: an ABI mismatch whose values look
plausible. **A vendored SDK's idea of a struct layout is a claim to verify against the actual build**;
check any struct you marshal across that boundary.

## Reflection lies in three specific ways

- **A UFunction the bundled headers describe may simply not exist** on this build. Availability is a
  runtime question; ask it before building on the answer.
- **`FindFirstOf` can return the wrong instance**, especially for UI-adjacent lookups. Validate what
  came back before using it.
- **Writing a property directly, then calling a function that also sets it, loses the write.** Decide
  which of the two is the authority (`../CLAUDE.md`, "two writers on one field").

## A transition invalidates every cached reference, including the pawn's identity

A level transition can nil out a cached actor reference between the check and the use, and it produces
an **entirely new pawn instance**. Treat any cached actor pointer as invalid immediately after a
transition and re-acquire it, rather than re-validating what you stored.

**A hook-cleared cache only covers level teardown: an actor the game frees mid-level has no hook, and a
raw pointer to one is a crash with a delay on it.** Before caching any raw `UObject*`, answer "can the
game free this within a level?" If yes, or if unknown, hold `FWeakObjectPtr` and `Get()` per use.
Preflight enforces the `stale-safe:` annotation that says which case it is.

## Spawning a player Blueprint takes the player's control and camera

A second copy of the player's own controllable Blueprint auto-possesses, and the camera follows the new
actor. Both have to be explicitly prevented for a ghost; `pitfalls.md` has the two mechanisms.

## A runtime-spawned actor may not render at all

Rendering is not implied by a successful spawn (a `StaticMeshActor` spawned through the engine's own
API never appeared); confirm the actor reaches the screen before building on it.

## A destroy call that fails silently looks exactly like one that worked

Confirm the actor is gone rather than trusting the call (`K2_DestroyActor()` once no-opped on the ghost
pawn; check the build, don't assume either way).

## An actor that spawns with a visual already on cannot be fixed reactively

Anything running after the world tick (`on_update`, an engine-tick post callback, the next tick) runs
after that frame's rendering is enqueued, so a visual the actor is born with gets one rendered frame.
The signature: each reactive improvement makes the artifact briefer but never gone. **Intercept the
call that turns the visual on instead** (a native-function `RegisterPreHook` rewriting the argument
buffer, the same shape as the camera/fade/damage guards). If the data you attribute by is not yet
written at that moment, refuse-then-restore in the direction whose failure is invisible.

## Never call a UFunction on something `FindAllOf` handed you without owning it

`FindAllOf` returns every object of a class in memory, class-default objects and half-torn-down ones
included. Reading a named property off one is usually survivable; **calling a UFunction on one
dereferences state that may not be there, and a Lua `pcall` does not catch an access violation in
native code**, so wrapping the call buys nothing.

**"Named" is load-bearing**: `ForEachProperty` plus a read of every property it names is not a named
read, since stringifying an object-valued one dereferences its pointee. **Enumerate what you can name,
never what an object happens to hold**; grow a written list between runs. **The safe dump exists:
`probes/probe_dump/`** (object values as address plus declared class, never a pointee touched); reach
for it before writing another walk.

**Scope the enumeration to the object you are asking about.** `FindAllOf` answers "does this build have
any of these", never "what does this actor have".

## Attribute a component to a character up both the outer and the attach chain

A component's `GetOuter()` reaches its owning actor, but a `ChildActorComponent` spawns a separate
actor whose own outer is the level, so anything inside one reports as belonging to nobody (the player's
light is that shape). Follow `AttachParent` as well. **When in doubt use name containment**, the one
test that has never failed here: a component's full name carries its owning chain.
