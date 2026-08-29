# Unreal / UE4SS adapters — host rules

<!-- line-cap: 175 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**Loaded automatically** the first time this session reads or edits anything under
`adapters/pseudoregalia/`. Per-game facts live in this adapter's own `documentation.md`,
`FLAGS.md`, `BANDAGES.md` and `PLAYER_FIELDS.md`.

**These are HOST rules, sitting at game scope for now.** Pseudoregalia is the only Unreal game
here, so per `../CLAUDE.md`'s create-a-level-on-demand rule there is no `adapters/unreal/` yet —
a second Unreal game is what creates one, and this file is what moves up into it. Nothing below is
about Pseudoregalia specifically; it is about UE5 and RE-UE4SS.

**Capped at 175 lines, for the reason the root `CLAUDE.md` is capped** — this file loads without
being asked, so it spends the same instruction budget (`agent_docs/claude-md-cap.md`). Before
adding: what comes out? **It never restates the root `CLAUDE.md` or `../CLAUDE.md`.**

Each rule below is the imperative; the symptom→diagnosis→cause→fix evidence stays in
`agent_docs/pitfalls.md`, which is its one home.

## Probe in LUA, iterate by hot reload — the C++ mod is for SHIPPING only

**The default way to ask this game a question is a Lua mod under `adapters/pseudoregalia/`
(`probe_nametag/` is the worked example), deployed as its own folder in the install's
`ue4ss\Mods\`, and reloaded INTO THE RUNNING GAME.** A C++ change costs a rebuild and a full
game relaunch per attempt; a Lua reload costs seconds. The 2026-08-28 nametag session iterated
the C++ adapter and paid a relaunch per experiment; 2026-08-29 re-ran the same investigation in
Lua at ~5 rounds in one game session. User: make this the default (2026-08-29).

**Reload without touching the game window:** deploy `probe_reloader/` (once), then write
`<ModName> <nonce>` to `ue4ss\Mods\MeshGhostProbeReloader\reload_request.txt` — it calls
`RestartMod` from a resident watcher, so a broken probe can't kill the loop. The Ctrl+R
keybind (`dev-scripts\pseudo-hotreload.ps1`) is the fallback and MISSES whenever the game
lacks focus — three sent reloads landed nowhere on 2026-08-29 while the user was typing chat.
Confirm every reload in `UE4SS.log`, never from the send. UE4SS Lua has the full reflection
surface (FindAllOf, StaticFindObject, ForEachProperty, LoadAsset, UFunction calls) — C++ is
only needed for hooks/perf-critical paths, i.e. the shipping adapter.

## `on_update()` is NOT the game thread

`CppUserModBase::on_update()` runs on UE4SS's own thread. Anything touching actor state from
there is a data race against the engine, and it presents as intermittent corruption rather than
a crash — so it survives testing. Marshal work onto the game thread before touching an actor.
Found 2026-08-13; `pitfalls.md`.

## Never hook a Blueprint UFunction — hook native, or poll

RE-UE4SS's `RegisterPre/PostHook` installs itself by swapping the `UFunction`'s own executor
pointer, which works on native functions and **crashes** on Blueprint ones. Two Blueprint hooks on
the player took the game down on 2026-08-15.

**Before reaching for a UFunction hook on any UE target, check whether the function is native or
Blueprint.** If it is Blueprint, poll instead. And note the process lesson recorded alongside it:
that change also swapped out a *confirmed-working* mechanism for an unproven one — don't trade a
thing that works for a thing that is tidier until the tidier one has been watched.

## The vendored SDK marshals `FRotator` as `float`, whatever the engine uses

RE-UE4SS's bundled SDK marshals `FRotator` components as `float` regardless of the engine
version, so on a UE5 game that stores them as `double` every rotation written through
`K2_SetActorLocationAndRotation` and its neighbours is silently wrong. This is an ABI mismatch,
not a logic bug — the values look plausible. `pitfalls.md`, 2026-08-13.

**Generalises:** a vendored SDK's idea of a struct layout is a claim to verify against the actual
build, not a fact. Check any struct you marshal across that boundary.

## Reflection lies in three specific ways

- **A UFunction the bundled headers describe may simply not exist** on this build. Availability
  is a runtime question; ask it before building on the answer.
- **`FindFirstOf` can return the wrong instance**, especially for UI-adjacent lookups. Validate
  what came back before using it.
- **Writing a property directly, then calling a function that also sets it, loses the write.**
  Decide which of the two is the authority and let the other stop — the same "two writers on one
  field" rule `../CLAUDE.md` states for effects.

## A transition invalidates every cached reference — including the pawn's identity

A level transition can nil out a cached actor reference between the check and the use, and it
produces an **entirely new pawn instance**, not a re-initialised old one. Treat any cached
actor pointer as invalid immediately after a transition and re-acquire it, rather than
re-validating what you stored.

## Spawning a player Blueprint takes the player's control and camera

Spawning a second copy of the player's own controllable Blueprint auto-possesses it, and the
camera follows the new actor. Both have to be explicitly prevented for a ghost — a ghost is a
character the player never drives. `pitfalls.md` has the two mechanisms.

## A runtime-spawned actor may not render at all

A `StaticMeshActor` spawned through the engine's own spawn API never appeared. Rendering is not
implied by a successful spawn; confirm the actor reaches the screen before building on it.
This is the concrete case behind `../CLAUDE.md`'s "a clean instrument plus a symptom the user
still sees means widen the subsystem".

## Destroying the ghost pawn: check the build, don't assume either way

`K2_DestroyActor()` silently no-opped on the ghost pawn on one build, which produced the
park-it-offscreen bandage (`BANDAGES.md`). **That was reversed on 2026-08-18 — it is not a
constraint any more.** Recorded because the shape recurs: a destroy call that fails silently
looks exactly like one that worked, so confirm the actor is gone rather than trusting the call.

## An actor that spawns with a visual already ON cannot be fixed reactively

Anything running after the world tick — `on_update`, an engine-tick post callback, the next
tick — runs after that frame's rendering is enqueued, so a visual the actor is born with gets
one rendered frame no matter how early in your own code the reaction sits. The signature that
you are in this trap: each reactive improvement makes the artifact briefer but never gone.
Intercept the call that turns the visual on instead (a native-function `RegisterPreHook`
rewriting the argument buffer — the same shape as the camera/fade/damage guards). If the data
you attribute by is not yet written at that moment (measured: `copyActor` is set AFTER the
custom-depth enable), refuse-then-restore in the direction whose failure is invisible.
Afterimage outline case, 2026-08-27; `pitfalls.md`.

## Never call a UFunction on something `FindAllOf` handed you without owning it

`FindAllOf` returns every object of a class in memory, class-default objects and half-torn-down
ones included. Reading a NAMED property off one is usually survivable; **calling a UFunction on
one dereferences state that may not be there, and a Lua `pcall` does not catch an access violation
in native code** — so wrapping the call buys nothing. Crashed a live session twice on 2026-08-29.

**"Named" is load-bearing, and it cost a third crash the same day.** `ForEachProperty` plus a read
of every property it names is not a named read: an object-valued one hands you a pointer, and
stringifying it dereferences whatever that was. **Enumerate what you can name, never what an object
happens to hold** — grow a written list between runs instead.

**Scope the enumeration to the object you are asking about.** `FindAllOf` answers "does this build
have any of these"; it is the wrong tool for "what does this actor have", and reaching for it there
is what put a whole-world walk in a probe that only ever needed two pawns' components.

## Attribute a component to a character up BOTH the outer and the attach chain

A component's `GetOuter()` reaches its owning actor — but a `ChildActorComponent` spawns a separate
actor whose own outer is the LEVEL, so anything living inside one is invisible to an outer walk and
reports as belonging to nobody. Follow `AttachParent` as well. This is not hypothetical: the
player's light is exactly that shape.
