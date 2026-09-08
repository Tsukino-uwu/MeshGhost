# Pseudoregalia probes

Every script here is a **development tool**, not part of the shipped adapter — the release ships
`main.dll` built from `MeshGhostPseudo/`, and nothing from these folders. They are kept because
they are the record of *how each fact was established*: the pawn/position/rotation discovery, the
auto-possess diagnosis, and the whole socket-capability answer in `agent_docs/phases/phase7.md`
were each settled by something in this list.

**Where they live: `probes/`, one UE4SS mod directory per probe.** UE4SS loads a Lua mod from a
fixed `<ModName>/Scripts/main.lua`, so each probe has to be its *own mod directory* and is deployed
as one; since 2026-09-06 those directories sit together under `probes/` (the user's call, to keep
the adapter root readable — they were loose at the root before, so a record dated earlier that says
`adapters/pseudoregalia/probe_x/` means `adapters/pseudoregalia/probes/probe_x/`). This index stays
at the adapter root because it is one of the adapter's files, not a probe. Twenty-three directories,
thirty-seven scripts, one index (2026-09-08 count, measured not incremented — `ls probes` and a `find`
for `*.lua`; six directories and nine scripts when this was written
2026-08-25 — before that the directories had no index at all, which `../_template/README.md` had
mandated since it was written). Three arrived on 2026-08-29, when `CLAUDE.md` made
Lua-plus-hot-reload the default way to ask this game a question; `probe_menuwatch/` and
`probe_slashvfx/` followed on 2026-08-31 and 2026-09-01, `probe_frozen/` and `probe_outline/` on
2026-09-05.

## Every probe here is READ-ONLY, with the exceptions named here

None writes game memory and none writes a save. The two that touch anything outside the process
are the socket stages, and they only open a local TCP connection to our own bridge.

**The exceptions are named here so the claim above stays true.** `probe_strip/` (2026-09-06) switches a ghost's components on and off through the engine's setters and writes three reflected bools, on ghost pawns only. `probe_audiofix/` (2026-09-04)
calls one native UFunction on the live `PlayerController` to put the audio
attenuation listener back on the player's capsule — a fix being tested before it is built into the
C++ mod, at the user's request (*"try with lua first, so we actually test the fix before making
it"*). `probe_outline/` (2026-09-05) has two writing stages: `hooks.lua` restores custom depth on
the player's body and sword, but ONLY when a trigger file appears, and `stencil.lua` writes stencil
values and custom depth onto ghost meshes for as long as it runs. None of the three writes a save,
game state or memory. **Unload them before judging anything
else**: `../../agent_docs/checklists/before-a-probe.md` — a writing probe left armed is a suspect
in every later report.

The one thing to be careful of is the opposite of a write: **`probe_ghost/Scripts/main.lua` is a
full working adapter**, not a diagnostic. Running it alongside the real C++ mod would put two
things on the bridge at once.

## `probes/probe/` — where the player actually lives (Phase 7.1; the first probe, named before there was a second)

- **`Scripts/main.lua`** (92) — the first read-only discovery probe, before any C++ existed.
  Confirmed on screen where Pseudoregalia's local player pawn, position, rotation and level name
  are, so the real adapter could be written against measured facts instead of reflection guesses.

## `probe_ghost/` — the ghost, and why it kept stealing the player

- **`Scripts/diagnose.lua`** (151) — **the entry worth reading.** Written after three straight
  fix-and-retest cycles each failed to stop the player being dragged around by the ghost. Instead
  of guessing a fourth time it gathers evidence, and it found the cause: `BP_PlayerGoatMain_C`
  has Auto Possess Player set, so spawning a second instance hands the controller to it. This is
  the worked example behind `../CLAUDE.md`'s "two guessed fixes failing the same way is a signal".
- **`Scripts/main.lua`** (849) — Phase 7.5's **complete Lua adapter**: real local state every
  tick, a real bridge connection, the re-possess fix and the `SetViewTargetWithBlend` hook that
  fights the game's camera rig back to the player. Superseded by the C++ mod, kept because it is
  the last version where the whole adapter is readable in one file.

**Its camera fight-back is the one thing in here not to copy.** That file's header still describes
a `SetViewTargetWithBlend` hook forcing the view target back whenever a ghost spawn makes the game
re-target. The approach was deleted 2026-08-16 for blocking every legitimate camera change forever
after; what ships instead refuses only a switch to a rig whose `OwningActor` is a ghost, because
the ghost bringing its own camera rig was the actual cause. See `BANDAGES.md` and `VERIFIED.md`.
The file is history, and history includes the parts that were wrong.

## `probe_socket/` — can UE4SS's Lua reach a socket at all?

Three deliberately staged scripts, each only run after the previous one came back safe. UE4SS
always loads `Scripts/main.lua`, so **Stages 2 and 3 are run by copying them over `main.lua`**,
not by being wired in.

- **`Scripts/main.lua`** (26) — Stage 1, SAFE: does `package.loadlib` even exist and is it
  callable? Loads no DLL.
- **`Scripts/stage2_loadlib.lua`** (94) — Stage 2, riskier: actually load vendored LuaSocket into
  UE4SS's embedded Lua and *create* a TCP socket. Never connects.
- **`Scripts/stage3_roundtrip.lua`** (129) — Stage 3: a real bind/connect/send/receive round trip
  against the bridge protocol — the one thing Stage 2 deliberately left untested.

**The staging is the method, not caution theatre.** Each stage answers exactly one question and
stops, so a crash names its own cause. `agent_docs/verified.md` and `phase7.md` carry the answers.

## `probe_nametag/` — which material renders coloured text (2026-08-29)

- **`Scripts/main.lua`** (747) — the first probe written to the Lua-and-hot-reload rule, and the
  reason that rule exists: twelve rounds of material candidates in one game session, where the
  same investigation had cost a relaunch per experiment in C++ the day before. Each round's
  screen verdict is kept in the file's own header, so the losing candidates are readable next to
  the winner. Ships nothing; the answer it found is in `VERIFIED.md`.
- **Leave it at `PROBE_ENABLED = false`.** It spawns a row of text actors, and one was still
  appearing during somebody else's test on 2026-08-29.

## `probe_reloader/` — the hot-reload loop itself

- **`Scripts/main.lua`** (73) — a resident watcher that calls `RestartMod` when a trigger file
  changes, so a probe restarts inside the running game with no keystroke and no window focus.
  Deliberately dumb and never edited during an iteration: a syntax error in the probe being
  iterated cannot take the reload loop down with it. `../CLAUDE.md` has the protocol.

## `probe_dustlight/` — the landing dust and the ascendant light (2026-08-29)

> **DISABLED — this probe CRASHED THE GAME TWICE during a live session, and must not be loaded
> again until its class list is cut down.** `EXCEPTION_ACCESS_VIOLATION` inside UE4SS's Lua
> machinery; localised to the `ChildActorComponent` pass, which walks every child actor in the
> world and calls a UFunction on each. Its `enabled.txt` is deliberately absent from the deployed
> copy. It DID deliver the light answer before dying — two output lines — which is exactly why the
> world-wide enumeration was never needed. Full account: `UNVERIFIED.md`,
> `../../agent_docs/pitfalls/by-lesson.md`.
>
> **It deliberately ships WITHOUT an `enabled.txt`**, unlike every other probe here. That file
> is what makes UE4SS load a mod, so a probe known to crash the game must not carry one --
> copying this folder into an install would otherwise arm it. Create one by hand once the
> class list has been cut down.

- **`Scripts/main.lua`** — the two cosmetics the user watched and called wrong, both open in
  `UNVERIFIED.md` with nothing measured. One run answers both: a **light census** naming every
  light component and child actor on the player and on each ghost (attributed up BOTH the outer
  and the attach chain, because a light inside a ChildActorComponent is invisible to an outer
  walk alone), then a **landing timeline** putting every Niagara/Cascade component's first
  appearance on the same clock as every character's MovementMode transition.
- **The timeline is the point, not the catalogue.** The user's report is that the dust fires when
  the *player* lands rather than when the *ghost* does, which is a claim about when — so the run
  is built to catch a dust burst on an instance whose own character never left the ground.

## `probe_lightcheck/` — does the ghost's light STAY off? (2026-08-29)

The readback half of `GHOST_HOLD_LIGHT_OFF`. The shipping mod announces a lit ghost light once
per component and is silent afterwards, so a light the game re-lights every frame and the hold
re-darkens is indistinguishable in `UE4SS.log` from one fixed on the first sweep. `../../CLAUDE.md`
forbids reading back the value you wrote with the thing that wrote it; this is the separate
instrument.

- **`Scripts/main.lua`** (134 — it has roughly doubled from the ~70 lines this row first
  recorded, so re-read it before calling it minimal) — once a second, one line per
  `PointLightComponent`: full name and `Intensity`. Stops itself after 60 samples. A ghost steady
  at 0 means the write took and nothing fights it; a ghost flickering 0 ↔ 5000 means the hold is
  earning its per-tick cost.
- **It began as the smallest instrument that answers the question**, and that is the whole
  lesson its ancestor above paid for: no UFunction call on anything, one property read, one class
  enumerated. `FindAllOf` still returns class-default objects — reading a property off one is
  survivable, and calling into one is the line `probe_dustlight/` crossed.
- **A new mod folder cannot be hot-reloaded in.** `probe_reloader/` calls `RestartMod`, which
  answers *"Could not find mod to reinstall"* for anything UE4SS did not load at launch (measured
  2026-08-29). It ships disarmed (no `enabled.txt`); create one and it arms itself on the NEXT game
  start — or drop the script into `probe_scratch/`'s slot to run it in the current one.

## `probe_namecensus/` — the census that ended the glow hunt (2026-08-29, evening)

Grew stage by stage through the session that found `BP_DynamicVertexLight_C` and `LightMesh`
(`UNVERIFIED.md`, the CAUSE FOUND section). Read-only, named reads and `GetFullName()` only —
never a UFunction — so it has been reloaded into a live two-instance session dozens of times
without incident. One census 3s after each (re)load; write the reloader trigger to re-run it.

- **`Scripts/main.lua`** — world inventories by class (`TextRenderComponent`, `NiagaraComponent`
  with each `Asset`, lights, decals, `ChildActorComponent`, `MaterialParameterCollection`), the
  `MPC_PlayerRelated` parameter list, and for every pawn: `PlayerLight` → its `ChildActor`, and
  `WeaponMesh`/`VisualMesh`/`LightMesh` with materials, MID parents, MID parameters, visibility
  flags, `CustomPrimitiveData` and `OverlayMaterial`.
- **The lesson it proved:** the glow was invisible to every light/material/post-process read
  because the mechanism was a vertex-painting ACTOR and a separate aura MESH — a census of what
  EXISTS, dumped unfiltered, found in one evening what eleven targeted eliminations could not.
- **Never trigger a full UE4SS hot reload (Ctrl+R) to pick up a new probe in a live multiplayer
  rig** — it reinstalls every Lua mod, orphans the adapter's spawned ghosts, and broke the session
  it was tried in (camera stolen, duplicate ghosts). Deploy the folder, relaunch the game once,
  and use `probe_reloader/` from then on.

## `probe_swordthrow/` — the two-peer sword-throw investigation (2026-09-01)

- **`Scripts/main.lua`** — the passive capture: pawn weapon flags on change, loose-weapon/
  projectile flight tracks per sample. Safe shape; ran clean on both clients.
- **`Scripts/equip_carrier_test.lua` / `montage_carrier_test.lua`** — one-shot carrier tests
  that exonerated `changeEquippedWeapon`-on-ghost and `CustomPlayMontage`(throw)-on-ghost by
  sampling the player's own flags through each call. Both clean, both negatives recorded.
- **`Scripts/bounce_capture.lua`** — named the wall-bounce VFX (`NS_WallKickHit` at the contact
  point) and the real sword's constant mesh offset (roll+90) in one flight capture.
- **`Scripts/shadow_sit_capture.lua`** — caught the game flipping `BlobShadow.bVisible` on the
  chair sit/stand edges; the shadow mirror is built on that flag.
- **`Scripts/shadow_prop_name.lua`** — candidate-name tester. A sibling Lua function-census
  (`meshsetter_census.lua`) never worked (`ForEachFunction` nil on this build) and was DELETED
  rather than left armed -- preflight refuses blind reflection walks in armed probes; the C++
  `dump_component_functions` is the working tool for that question.
- **`Scripts/prop_carrier_test.lua` — CRASHED a live client (2026-09-01) and must not be re-run
  as written.** Two suspects, in order: `GetClass()` on a pawn's `weaponRef` (a pointer the game
  keeps AFTER pickup and can leave stale — a UFunction call on an object nobody owns, the exact
  line `probe_dustlight/` crossed), and `World:SpawnActor` of a gameplay-bearing Blueprint from
  Lua. The split it wanted now lives in the adapter as `skip_ghost_weapon_state.txt`, with the
  C++ guards. It is not `main.lua`, so it never auto-loads — and the folder itself is PARKED:
  `probe_swordthrow/enabled.txt.off` is the convention `probe_slashvfx/` later copied; rename it
  back to `enabled.txt` to arm the folder's `main.lua` on the next game start. (This line said the
  folder was armed until 2026-09-06; the filesystem said otherwise.)

## `probe_menuwatch/` — the reset-world fingerprint (2026-08-31)

**The question:** spawning a pawn into a world made by "reset to last save" kills the game, while
the same spawn after a ZONE CHANGE is fine — so what differs about the world a reset makes?
Prints a fingerprint of the world every 2s and on change, so a zone-change world and a reset
world can be diffed line for line. Property reads and cheap lookups only — no UFunction calls
into the Blueprint VM, which is where the fault lives. Quiet unless something changes. Ships
disarmed (no `enabled.txt`). Its findings fed the reset-crash root-cause (`UNVERIFIED.md`,
`VERIFIED.md` 2026-09-01).

## `probe_slashvfx/` — what a melee swing actually spawns (2026-09-01)

**The question, the user's:** a ghost playing the attack montage shows none of the *"curved slash
ish going outward"* VFX. Logs every Niagara/Cascade component APPEARING or ACTIVATING — asset,
attach point, offset — exactly the fields a `MIRRORED_EFFECTS` row needs; activations are
labelled separately because pooled components reactivate rather than appear. Safe shape per the
dustlight post-mortem: named property reads only, no UFunction calls on `FindAllOf` results, two
classes at 5Hz, and it reports its own coverage every 10s so "no events" is distinguishable from
"not looking". **Its question is ANSWERED — the slash ships as the `NS_PlayerSlash` row in
`MIRRORED_EFFECTS`, and the user calls it fixed (2026-09-01)** — so its `enabled.txt` is parked
as `.off`, same convention as `probe_swordthrow/`; rename it back to re-measure on a new build.

## `probe_audiocensus/` — is the ghost noisy, or is it spending the player's voices? (2026-09-04)

**The question, the user's:** *"think ghosts are eating up the players sound, like sfx is not
doing anything when the player does things, but ghosts had them."* Two shapes fit it — a ghost
playing sounds the silence clause never covered, or Unreal's sound CONCURRENCY refusing the
player's cue because a ghost already holds the instances — and they want different fixes.

- **`Scripts/main.lua`** — every `AudioComponent` appearance, START and STOP, attributed to the
  player or to a ghost by name containment, with the cue each carries; then, once per distinct
  cue, that sound asset's own concurrency settings (`bOverrideConcurrency`, `MaxCount`,
  `ResolutionRule`, `bLimitToOwner`). **The concurrency dump is the decisive half:** it says
  whether the mechanism for the second shape exists at all, and no ear is needed to read it.
- **It states its own blind spots in its header, and they matter here.** A sound started by
  `PlaySoundAtLocation`/`PlaySound2D` creates no component and is invisible to this — which is
  the usual shape of an anim-notify footstep — and concurrency is resolved on the audio device's
  active-sound list, so a component reading active is not evidence the player was audible. A
  quiet ghost in this log means quiet *through the component path*, and nothing wider.
- Safe shape: named property reads inside `pcall` only, never a UFunction on a `FindAllOf`
  result, two classes at 5Hz, a coverage line every 10s carrying the pawn list and how the
  player/ghost split was decided. Every property name is reported as it resolved or as
  `UNRESOLVED`, so a name this build does not have can never be read as a zero.
- **Grown live through the 2026-09-04 session, by hot reload, without a relaunch** — the whole
  point of the Lua-first rule. It now also logs the VIEW TARGET and the player's position on
  change, a CONTROLLER census (how many, and which pawn each drives), the game's SOUND CLASS
  volumes, and hooks the six `GameplayStatics` sound-mix statics this build has. Each was added
  because the previous reading eliminated a hypothesis: components, then the listener, then the
  local player, then the audio device.
- **Its two failures are in its own header and are the transferable part.** The first pawn
  discriminator called a possessed pawn the player -- **a ghost here reads as possessed**, so
  every ghost was labelled PLAYER, and the coverage line printing its evidence is the only
  reason that was caught rather than believed. And a `string.format` on a non-vector threw out
  of the sample loop and stopped the probe for four minutes, which in the log is
  indistinguishable from a game doing nothing; the loop now pcalls and reports once.
- **`prop()` reporting `resolved` is not proof a read WORKED.** The controller's
  listener-override fields each returned a fresh UObject wrapper at a different address every
  sample. A value that changes every 200ms is the tell.
- **PARKED (`enabled.txt.off`) 2026-09-04, question answered** (`VERIFIED.md`: the stolen audio
  listener). It is a heavy probe -- 5Hz whole-world enumerations plus ten function hooks -- so it
  does not stay armed through somebody else's test.

## `probe_audiofix/` — the fix for the stolen listener, tested before it is built (2026-09-04)

**WRITES. The only one here that does** — see the exception above.

- **`Scripts/main.lua`** — when a new ghost appears, calls
  `SetAudioListenerAttenuationOverride` on the live `PlayerController` with the LOCAL player's own
  capsule, undoing what the ghost's `BeginPlay` just did. The component is name-checked against
  `CollisionCylinder`, the shape the game itself passes, rather than assumed from `RootComponent`.
- **Why it exists:** `probe_audiocensus/` found that every ghost steals the player's attenuation
  listener, and the user's call was to prove the fix in Lua before spending a rebuild on it. If it
  holds, the same call goes into the C++ ghost-decouple pass.
- **A NEW probe folder cannot be hot-loaded** — UE4SS reads mod folders at launch and `RestartMod`
  answers *"Could not find mod to reinstall"* (measured 2026-08-29, and again 2026-09-04). So that
  day's test ran the same code hosted temporarily inside
  the census probe, which WAS loaded; this folder arms itself on the next game start.
- **PARKED (`enabled.txt.off`) at the end of 2026-09-04, in the repo and in both installs, and it
  matters more than usual for this one:** it applies the same fix the DLL now carries, so an armed
  copy would make the shipped fix untestable -- the run would pass whether or not the C++ works.
  Rename it back only to re-measure the Lua version.
## `probe_pickup/` — what a Dream Breaker pickup does to the state we SEND (2026-09-04)

**Two user reports, one event, so one run answers both.** A replay ghost wears the Dream Breaker
from a clip recorded BEFORE the pickup; and *"recordings look a bit weird as if you are just
floating in the air/frozen for a bit"* when picking an item up.

**The first question is answered by the probe's very first block.** Reading had already cleared the
show/hide path (`UNVERIFIED.md`), leaving the SEND side: `PLAYER_FIELDS.md:264` records that
`weaponEquipped?` means the sword is IN HAND rather than owned, and nothing established what it
reads before the pickup. The probe prints a BASELINE census as soon as a pawn exists — if
`weaponEquipped?` is already `true` on a fresh save, that is the whole diagnosis and the adapter is
sending a wrong value in good faith.

**The second is the per-sample TRACK line** across the pickup: position, `horizontalSpeed`,
`verticalSpeed`, `moveState`, `actionState`, `CapsuleHalfHeight` — exactly the fields the adapter
puts on the wire, so a "frozen/floating" clip can be read back against what was sampled while it
was recorded.

**No window to hit.** Everything logs on change, with ~3s of per-sample context after each one.
Stand around a moment, then go and get the sword; take as long as you like.

**What it CANNOT see, stated because an enumeration is only as wide as its filter.** It reads a
NAMED list and nothing else — `ForEachProperty` is banned in an armed probe (`preflight.ps1`; a
blind walk crashed three live sessions on 2026-08-29). So it cannot FIND an "owns the sword" flag,
only prove whether `weaponEquipped?` is the wrong signal. If it is, the next instrument is the mod's
own `OBJECT_REFLECTION_DUMP`, which `Plugin.cpp:848` already names as the right tool rather than
guessing a second name list. It also reports, in a `COVERAGE:` line, any named field that never
resolved.

**Cost:** one object-space walk per sample over one class at 10Hz — cheaper than
`probe_swordthrow/`'s three-class 250ms walk. Read-only. **Unload it before judging anything**: a
loaded probe is a suspect in every later report.

## `probe_frozen/` — the game's own "player is frozen" signal, for the chaser's clock (2026-09-05)

**The question (ADR 0053).** The chaser's clock now stops on a `player_frozen` message, and
`probe_pickup/` had proved nothing the adapter samples marks a freeze. So what does the game itself
set? Three families read by NAME at 10Hz, no UFunction on anything `FindAllOf` returned, no
`ForEachProperty`: the engine's pause (`WorldSettings.PauserPlayerState`, `TimeDilation`), the
controller's input gates, and a census of every live `UserWidget` with its `Visibility`, printed as a
DIFF on change. Every named field that does not resolve is listed in a COVERAGE line rather than
skipped.

**Measured 2026-09-05, two live runs (the record is in `UNVERIFIED.md`):**

- **The PAUSE MENU and the ITEM POPUP are both the engine's own pause.** `WorldSettings.PauserPlayerState`
  goes from empty to the player's `PlayerState` on the sample the menu widget (`UI_PauseMenu_C`) or
  the popup widget (`UI_NewUpgradePrompt_C`) appears, and back to empty on the sample it closes.
  Held across the options submenu; caught on every edge of a 100ms open/close spam; a 19-second
  popup read as one span. **That field is the adapter's `player_frozen` signal.** The mouse cursor
  flag follows it for the menu and lags it by 5s for the popup (the prompt's button arming), so
  the cursor is NOT the signal.
- **The intro CUTSCENE is not a freeze but a scripted possession, and it has no edge in anything
  Lua can read here.** The game drove the pawn itself (full run speed, two jumps, then a hold) with
  the engine pause off, `TimeDilation` and `CustomTimeDilation` at 1.0 and `bBlockInput` false
  throughout. A `UI_CutsceneSkipListener_C` widget is created on the sample the cutscene starts
  and is only collected ~12s after it ends, so its lifetime marks the start and not the end. The
  five controller input gates, the fields a cutscene most plausibly sets, do not resolve through
  UE4SS's Lua property read on this build (an invalid object wrapper comes back) but ARE readable
  from the C++ mod through the `FBoolProperty` path it already uses for the cursor flag — that is
  the next instrument if the cutscene ever needs an edge. The chaser does not need one: a pawn
  the cutscene moves is a pawn that moves.
- **Zone transition:** not measured as its own event; the pawn swap on a save load
  (`pc.Pawn` changing) is visible and nothing pause-related fires around it.
- **Not an event, but worth knowing:** the game rebuilds `UI_HUD_C` plus eight `UI_Heart_C` every
  ~9s and lets garbage collection sweep the copies; every pause-menu open leaves a full copy too.

**Three probe faults fixed live, each one a lesson already filed:** a value that is a fresh wrapper
every read is not a change (stringify by TYPE, not by address); `GetFullName`'s first token is the
CLASS, so a match inside the path named every widget after the engine object that outers them; and
three hundred widgets make a full signature unreadable, so print the diff. Hot-reloaded through
`probe_scratch/`'s slot via `probe_reloader/`; the stub was restored afterwards.


## `probe_outline/` — who turns the PLAYER's through-walls outline on and off (2026-09-05)

**Ships WITHOUT an `enabled.txt`** -- two of its stages walk reflection and one writes, so the folder must never arm itself; each stage is copied over the scratch slot by hand.

Three stages, each hot-loaded through the scratch slot, that found and then proved the cause of the
blue silhouette stuck to the player's sword (`VERIFIED.md`, 2026-09-05). The method they add:
**hook the engine setter pre AND post with owner attribution**, then **restore through the same
setter and watch the screen**.

- **`Scripts/main.lua`** (stage 1, read-only) — flags on the named meshes of the player and every
  ghost, on change; a cross-owner walk of a ghost's object properties; afterimage attribution. Found
  the pawn had been recreated mid-run and 113 afterimages alive; its cross-owner filter was wrong
  (a missing property reads back as a placeholder object, not nil).
- **`Scripts/hooks.lua`** (stage 2, writes ONLY on a trigger file) — `RegisterHook` on
  `SetRenderCustomDepth` and `SetCustomDepthStencilValue`, pre and post, each call labelled PLAYER /
  GHOST / AFTERIMAGE by its outer chain; a census of EVERY mesh component the player owns; a one-shot
  dump of an afterimage's object properties with the owner of each value (named `cachedMesh`); and
  RESTORE: `SetRenderCustomDepth(true)` on the body and sword when `outline_resync.txt` appears. The
  restore made the silhouette vanish on screen; the next attack brought it back.
- **`Scripts/weapon.lua`** (read-only, 2026-09-05, same folder for the shared idioms) — the hand sword's asset
  under three candidate property names, its attach parent, socket and relative transform, the pawn's
  `weaponRef`/`weaponEquipped?`, the loose weapons in the world, and every pawn function naming weapon/
  sword/equip; on change, so a live weapon swap prints one line. Established that a weapon mod is an asset
  swap on `WeaponMesh` and nothing else (`documentation.md`), and that a peer's modded sword is not mirrored.
- **`Scripts/stencil.lua`** (stage 3, WRITES to ghost meshes while it runs) — ghosts on stencil 1,
  then 255, with custom depth on (arm `keep_custom_depth.txt` first). Answer: the outline pass
  ignores stencil; ghosts writing custom depth show through walls. The user chose to keep them stripped.

## `probe_scratch/` — the always-registered EMPTY slot (2026-09-04)

**Not a probe. A permanently enabled, deliberately empty mod folder, so a NEW probe can be
hot-loaded at all.**

**The gap it closes, found live and confirmed as a repeat.** UE4SS knows only the mods that were
enabled when the game STARTED, so `RestartMod` — the whole mechanism behind
[`probe_reloader/`](probes/probe_reloader/) — answers *"Could not find mod to reinstall"* for a folder
created since launch. Hot reload therefore covered iterating a probe that already existed and never
covered writing a new one, which is the case that comes up first. The user, 2026-09-04: *"should we
make a temp/reusable probe for things like this? its not the first time we can't load a new one"*.

**How to use it:** write your probe over
`ue4ss\Mods\MeshGhostScratch\Scripts\main.lua`, then trigger the reloader with `MeshGhostScratch`.
Confirm in `UE4SS.log`, never from the copy succeeding.

**Restore the stub when done.** A probe left in a slot whose NAME describes nothing is the worst
version of the standing "a loaded probe is a suspect in every later report" rule. The pristine stub
is in this repo at `probe_scratch/Scripts/main.lua`.

**Cost when idle: none by construction** — no `LoopAsync`, no `FindAllOf`, no reads. An always-on
slot that measured anything would tax every session for a convenience it was not using.

## `probe_bladeglow/` — which component is the blade aura, and whose child is it (2026-09-04)

**The question.** A ghost holding the Dream Breaker wore the ascendant-light blade aura on a save
with `obtainedLight? = false` (user, 2026-09-04). The suspect was the agent's OWN change from the
same day — the weapon-mesh mirror — because `call_set_visibility` writes SetVisibility's
`bPropagateToChildren` as 1 for every caller, so showing `WeaponMesh` could show whatever hangs off
it.

**What it reads:** every `BP_PlayerGoatMain_C` pawn at 2Hz — player and ghosts in the same pass —
and for `VisualMesh`, `WeaponMesh` and `LightMesh`: `bVisible`, `bHiddenInGame`, the component's own
name, and its `AttachParent`. Census first, then on change only. Named reads exclusively; no
`ForEachProperty`, no UFunction on anything `FindAllOf` returned.

**What it established:** the chain is `CollisionCylinder -> VisualMesh -> WeaponMesh -> LightMesh`,
so the aura IS a child of the weapon, and the propagating write was the cause. The A/B needed no
extra run — the ghost whose sword the mirror hid read `LightMesh.bVisible = false`, the one it
showed read `true`.

**A DEFECT IN THIS PROBE, kept because it is the reusable lesson.** Its first version reused
`probe_pickup/`'s `short()` for component names, and that helper matches the ACTOR pattern
`[%w_]+_C_%d+` first — so every `AttachParent` printed as the pawn, and the attach chain, which was
the entire question, was invisible while the output looked complete. It now prints each component's
own name beside its parent's, so the two collapsing into one is visible rather than silent.

**What it CANNOT see:** `bVisible`/`bHiddenInGame` are stock engine bools, and `PLAYER_FIELDS.md`
records that this game's stock bools can read as garbage through a byte-wide reflection read — both
are printed so they can disagree out loud. It reads three NAMED meshes, so an aura living on a
fourth component nobody has named would leave three clean readings and the glow still on screen.

**Cost:** one object-space walk over one class at 2Hz. Read-only. Unload it before judging anything.

## `probe_strip/` — switch a live GHOST's parts on and off, one at a time, to price each (2026-09-06)

**A WRITING probe** — the exceptions paragraph at the top of this file names it. It calls the
engine's own setters (`SetComponentTickEnabled`, `Activate`/`Deactivate`, `SetVisibility`,
`SetHiddenInGame`, `SetActorTickEnabled`) and writes three reflected bools (`bPauseAnims`,
`bNoSkeletonUpdate`, `bEnableUpdateRateOptimizations`) on GHOST pawns only — a pawn whose
Controller is an AIController and not being destroyed — never on the player's. Components are found
by name containment under the pawn's full name.

**The user's ask, in two steps.** First *"can we do a test with these disabled? ... no ghost vs 1
ghost ... and afterwards no ghost vs 50?"* for the six parts a ghost has no use for; then *"can you
do individual checks for all parts a model has? like spawn ghosts with only that thing and nothing
else"*. A pawn cannot be spawned with one component, so the probe does the equivalent: `off=all`,
then `on=<one part>`, sample, `off=<part>`, next. Thirteen parts: `springarms`, `dialoguecam`,
`charmove`, `niagara`, `aicontroller`, `animdriver` (CharacterMesh0's animation blueprint + IK),
`visualmesh`, `weaponmesh`, `shadow`, `nametag`, `capsule`, `pawntick`, and `uro` (the engine's
update-rate throttle on the three skeletal meshes — a lever, not a part). Frame-time sampler and
console-command request as in `census.lua`; the driver is `matrix50.ps1`-shaped: 50 fake peers,
two 10s samples per configuration, cap lifted. Results: `UNVERIFIED.md` 2026-09-06.

**It crashed the game once, and the fix is in the file.** `Activate()` on a ghost's `DialogueCam`
camera component — re-activating what `off=all` had deactivated, on 50 ghosts at once — aborted the
process ("Abort signal received", 14:12:32); every other part's ON had already passed. A camera
that becomes active is a view-target candidate, and both the game's camera code and our
SetViewTarget guard act on that. The camera part is tick-only now; a camera is never activated from
a probe (`pitfalls/by-lesson.md`, 2026-09-06).

## `probe_dump/` — any live object's reflected properties as JSON, without crashing the game (2026-09-06)

**The user's ask:** a tester compares objects with the UE4SS GUI console's object dump; the user
wanted the same from a probe, *"especially if it avoids us to kinda dump things without crashing the
game"*, and as the tool for vetting a ghost's components one at a time.

**Why it does not crash, when every earlier reflection walk here did.** The four crashes from walks
(three on 2026-08-29, one on 2026-09-05) all came from DEREFERENCING an object-valued property —
stringifying the pointee, `GetFullName` on it, a UFunction on it — and a `pcall` does not catch an
access violation. This dump never touches a pointee: an object property is written as the pointer's
address plus the property's DECLARED class (metadata on the property itself). Scalars in full; known
structs (Vector, Rotator, Quat, Vector2D, LinearColor, Color) by field; arrays by element up to 32;
delegates, maps, sets by type name only. The only objects it follows are the target's OWN components,
through the arrays the actor owns (`RootComponent`, `BlueprintCreatedComponents`,
`InstanceComponents`, each scene component's `AttachChildren`) — a live actor's owned components are
live. Keys are `Class.Property` and sorted, so two dumps `diff` cleanly.

**Request:** `dump_request.txt` beside the mod, `path=<full object path>` or
`class=<ClassName>` (+ `name=<substring>`), `components=1`, `out=<label>`. Output
`dumps/<label>-<HHMMSS>.json`; the log line carries the coverage (walked / read / refs / errors /
skipped types) so an empty dump and a broken walk cannot be confused.

**First run, 2026-09-06, through the scratch slot:** the local pawn with `components=1` — 3,015
properties walked, 3,015 read, 166 object references, 0 errors, 28 components, 266 KB, game
untouched. Unreal/UE4SS only; a future Unreal game copies the folder as is.

## `probe_leakcount/` — does anything stay resident after a ghost leaves (2026-09-04)

**The question, and it is the user's:** the ground looks clean after a ghost despawns, *"but might
be the same like ghosts being stuck in garbagecollection after leaving?"*

**Why a population count is the right instrument and our own log is not.** The adapter's despawn
cleanup hides, stops, then destroys each world-spawned effect, and **hiding is what removes a thing
from the screen** — so a clean floor proves the first step ran and says nothing about the third. The
adapter's own counter reported `0 destroyed` while the user watched a ring vanish, which is exactly
the case where our bookkeeping is the thing in doubt. So ask the ENGINE how many objects exist:
`FindAllOf` on a class, once a second, printing current / peak / trough.

**Peak AND trough travel with every line, deliberately.** A single current value cannot show a leak:
what a leak does is push the peak up and stop the trough from coming back. One number hides both.

**How it is driven, with no game restart:** kill `meshghost.exe`. The adapter respawns it, the
replays reload, and every ghost despawns and respawns — one despawn per ghost per cycle. Three
cycles is enough to see a trend.

**What it measured on its first run** (three cycles, then 90 seconds idle): `NiagaraComponent`
61 -> 74 -> 67, `BP_PlayerGoatMain_C` 1 -> 4 -> 1. **The pawns collect; the effects do not** — about
two per despawn. Full entry in `UNVERIFIED.md`.

**What it CANNOT see:** it counts a CLASS, not ownership, and the game spawns its own effects
constantly — so the baseline is one instant, not a measured floor, and a single reading proves
nothing. It also cannot say WHICH component is ours; if it says "leak", the next instrument names
them. UE frees on its own schedule, so a count that stays high for seconds is not yet a leak — one
that stays high across several cycles is.

**Cost:** two `FindAllOf` calls a second, read-only, printing only on change. **It was the first
probe to load through `probe_scratch/`'s slot** — written, deployed and answering inside a running
game in about a minute, which is the loop that slot exists to make possible.

- **`Scripts/verbs.lua`** — the folder's second file (2026-09-04): asks which teardown verbs
  (`DestroyComponent` and its relatives) actually RESOLVE on a `NiagaraComponent` in this build,
  and prints the answer. It never calls any of them — a named lookup only — because the adapter's
  own log had reported `0 destroyed` on a despawn the user watched come out clean, and this build
  was already known to lack `DeactivateImmediate`. Read-only, same as `main.lua`.

- **`Scripts/census.lua`** — the folder's third file (2026-09-06), and the one that found the
  leak: a FULL object walk (`ForEachUObject`, every UObject bucketed by class, diffed against the
  first walk, new objects named with their outer chain and their `bIsActive`/`bHiddenInGame`
  flags), plus a frame-time sampler (`GetWorldDeltaSeconds` 20x/s for 10s: mean / median / p95 /
  worst), `FindAllOf` counts of seven watch classes, and a console-command request (used only to
  send `t.MaxFPS 0` with the user's go-ahead, because at the 144 cap a leaked tick is invisible).
  Four request files beside the mod, each consumed once. **The walk is why `main.lua`'s two-class
  count was the wrong instrument**: it counted the classes it was told to, and the leftover was a
  class nobody had named — `BP_PlayerCam_C`, the camera rig every ghost pawn spawns for itself.
  **The walk also crashed the game once** ("Abort signal received"): `ForEachUObject` calls the Lua
  callback from inside a C++ lambda, so a Lua error raised in there aborts the process past any
  pcall — it fired on the walk's second load of the session, with the frame-time sampler's own
  game-thread callbacks interleaved. Now the callback only appends to a list (every read happens
  after the walk returns), one loop services all requests so nothing overlaps, and the walk is a
  fresh-launch instrument: never hot-reload a changed copy and then walk (`pitfalls/by-lesson.md`,
  2026-09-06). The measurements: `UNVERIFIED.md`, 2026-09-06.

## `probe_inputcensus/` — which way of reading what the player PRESSED works here (2026-09-08)

The adapter half of ADR 0056 starts with a question nobody had measured: `Plugin.cpp` reads no input
at all, so which reflected API is reachable was unknown. One file, two stages through the scratch
slot, both run inside one game session while the user held each input ~3 s at keyboard then gamepad.

- **Stage 1 (read-only, no UFunction on anything):** a census to a file of EVERY function (flags,
  parameters) and property on the PlayerController's, its `PlayerInput`'s and the pawn's class
  chains, every loaded `InputAction`, every `InputMappingContext` with its key->action table, and
  the legacy `InputSettings` lists -- unfiltered, grepped afterwards; then a 20 Hz on-change log of
  every bool on the pawn plus the named input vectors, so each button names the field it moves.
- **Stage 2 (the calls):** per sample, `GetBoundActionValue` for every action and
  `IsInputKeyDown` / `GetInputAnalogKeyState` for every mapped key with an FKey built from a Lua
  table; each path disarms itself on its first Lua error. Separate from stage 1 because a struct
  marshalled wrong is a native fault no `pcall` sees, and stage 1's file is already on disk by then.
- **Also a class count** of what a ghost brings (pawn, camera rig, AI controller, Niagara, nametag),
  so a reload after a pack despawns answers "did anything stay?" on the same file.

**What it found:** the FKey-by-table call works end to end; `GetBoundActionValue` is callable and
safe but its `FInputActionValue` is opaque to Lua (no reflected fields -- an empty table), so its
VALUE is a C++ question; the pawn's own fields cover jump, cling, move, crouch and throw and nothing
for look, interact, guard, lock-on or power; `EnhancedPlayerInput.ActionInstanceData` IS reflected on
this UE 5.1 build though the current engine docs omit it. Vocabulary, key table and the verdict:
`UNVERIFIED.md`, the 2026-09-08 census entry. Cost 3-4.8 ms a sample at 20 Hz -- a census, not a ship.

**Two things it cost, kept in the file's own header.** Its first run returned ONE function and ONE
property per class: the `ForEachFunction` / `ForEachProperty` callbacks ended in `return false`, and
UE4SS stops a walk on ANY returned value -- the docs' "return true to stop" reads as if `false` were
safe. And a class count is not a leftover count: 34 pawns where 4 were live, the other 30 flagged
`bActorIsBeingDestroyed` and waiting for the engine's purge. The census logs themselves are not in
the repo (a class-schema dump is expression); the facts derived from them are.

## `probe_hudindicator/` — the recording indicator as a screen-space widget, judged live before the C++ (2026-09-08)

The user's two complaints about the world-space indicator (hidden behind geometry; drifting with
the field of view) are both properties of a TextRenderComponent in the camera's frame, and a
tester's MIT mod had shown a UMG widget built at runtime paints in this game. This probe built
the same square-and-clock that way -- two UserWidgets with Border roots, a TextBlock in the
clock's -- and let the user judge it beside the old one in one session, every number live
through `hud_indicator.txt`.

- **It dumps the widget classes' function lists first** (`hud_census-*.log`; UserWidget, Widget,
  Border, TextBlock, WidgetTree and their parents), because the engine's API pages refused the
  fetch tool that day and the running game is the reference this repo prefers anyway. Every call
  it makes is by a name in that dump, and one that raises is reported once and skipped.
- **Four rounds, all from the log and the user's screen.** (1) In viewport, every call succeeding,
  nothing painted: a control widget built the tester's exact way DID paint, which isolated the
  difference. (2) Anchored placement (top-right anchors, read back correctly) is what put it
  off-screen; positive top-left offsets from `GetViewportSize` fixed it. (3) A box sized for four
  glyphs spilled at 10:00; a Border auto-sizes to its text once you stop forcing it. (4) The
  square sized to the box's laid-out height (`GetDesiredSize`), flush with its top: *"pixel
  perfect as well checked with sharex"*. Reset-to-save, a zone change and the main menu each took
  the widgets (the viewport drops them, the collector follows); the probe rebuilds on loss.
- **What it did not judge:** the real recording state (its clock is seconds since load). The C++
  port (`REC_INDICATOR_SCREEN_SPACE`) reads the core's start stamp and pins the pair in the root
  set; `UNVERIFIED.md`.

## `probe_inputnodes/` — which pawn input event is the PRESS and which the RELEASE (2026-09-08)

D0 of the driven-ghost plan (ADR 0057; `agent_docs/ideas.md`, the INPUT plane entry). The drive
will fire the pawn's own `InpActEvt_IA_*` nodes on a ghost the way `GHOST_CROUCH_INPUT_CALL`
already fires crouch's `_16`/`_15`, and the census had listed 24 nodes without saying which of a
pair is which. **No hooks** -- a Blueprint UFunction is never hooked and a Lua `RegisterHook` is a
freeze suspect -- so the probe CALLS each node on a GHOST pawn (a replay ghost; the active clip is
set to loop so one is always present) with a zero `ActionValue` and reads the pawn's own fields
back: every BoolProperty on the chain by name, the census's scalars and vectors, the actor's Z.
Two rounds per action, ascending then descending index, 3 s per call, a 600 ms per-frame window
and a 2.5 s late read each. Skips Pause, MenuAdvance, QuickMap, PerspectiveToggle (UI, camera)
and Interact (the world). Move (`_19`) is not called: its value cannot be passed from Lua.

- **Runs from the scratch slot**, autonomous; the log is `input_nodes-<HHMMSS>.log` at the slot's
  root. Nothing is asked of the person at the game beyond keeping the ghost on screen if they
  want to see the calls land. **Unload afterwards** -- it fires input events on a pawn.

Three helpers beside it, all hot-loaded over the scratch slot during the 2026-09-08/09 drive work:
`attack_loop.lua` (fires the three attack nodes in blocks on the first AI-steered ghost; every block
was silent with a zero value, which is what sent the census to C++), `grant_attack.lua` (set
`obtainedAttack?` on the ghost -- a clone has class defaults; superseded by the rig's ability copy),
and `sit_watch.lua` (READ-ONLY on the player's pawn: the fields around a chair sit on change; it
showed a real stand-up is the rising edge of movement input while `Interaction Target` is never
cleared, and that the table glitch is the same sequence with the input already held).

## `probe_pawndiff/` — what differs between the PLAYER's pawn and a ghost's, field by field (2026-09-09)

The instrument for "the ghost does X differently and the value I fixed is already equal": with
`CurrentHp` reading 80 on the driven ghost's own private game instance and the chair sit STILL the
hurt variant, the question was what else a sit could read. `main.lua` (hot-loaded over the scratch
slot, read-only) snapshots every 4 s for 120 s: every plain-valued property (bool, int, float,
double, byte, enum, name, string) of the player's pawn class, read on the player and on every
OTHER pawn of that class, plus the same on the object each holds as `As MV Game Instance Ref`; the
ones that DIFFER go in full to `pawndiff-<HHMMSS>.log` beside the mod, and `UE4SS.log` gets one
line per ghost per snapshot (controller class, `moveState`/`actionState`, the counts, whether the
instance is shared or private). Nothing filtered before the file. Named reads only; the one
dereference is the game-instance ref (the adapter's own object or the game's singleton, both live).

First run (00:29, `pawndiff-002922.log`): 248 plain-valued of 389 pawn properties, 47 of 75 on
the instance. The driven ghost differed from the player in the SAVE's upgrade set --
`healUpgrades` 2/0, `damageUpgrades` 1/0, `powerBuildUpgrades` 2/0, `powerMeterUpgrades` 3/0,
`bonusAirKicks` 4/0, `healAmountPerDing` 20/10, `canMoveHeal?`, `canDoAirRecovery?` -- the damage
numbers the adapter zeroes on purpose, and camera/replication config; its private instance in
four save-name STRINGS only. Also seen: FIVE pawns of the class with one player -- two flagged
`bActorIsBeingDestroyed` that stayed through every snapshot, one of them still seated
(`moveState` 8) on the chair; see `UNVERIFIED.md`. `copy_config.lua` is the follow-up WRITING
probe: the eight upgrade fields written from the player onto every driven pawn (AIController +
private instance + not being destroyed), read back per write, re-applied on each loop's new pawn.
Restore the stub after either; the writer is a suspect in every later report while loaded.
