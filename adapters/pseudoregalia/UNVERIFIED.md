# Unverified — Pseudoregalia's queue waiting on the user

**What this is.** [`VERIFIED.md`](VERIFIED.md) is the append-only record of what is *confirmed*.
This is its waiting room: things the agent believes work, has self-tested as far as it can, and
**the user has not seen yet**. It exists so work can continue while the user is away without
either losing track of what still needs checking or quietly drifting into calling it done.

**The rule it serves** (`../../agent_docs/testing.md`, `../../agent_docs/environment.md`): the agent
verifies the Go client/server with tools; **anything about a running game needs the user to watch
it**. A screenshot the agent took is not a substitute, and neither is a healthy log. *"nothing is
considered done/fixed until i actually confirm it as such."*

**How to use it.**

- The agent adds an item the moment it believes something works, with **what to look at** and
  **what correct looks like** — enough that the user can judge it without re-deriving anything.
- The user works down the list and answers each **confirm** or **decline**. Decline is a normal
  answer, not a failed handover.
- **On confirm:** move it to [`VERIFIED.md`](VERIFIED.md) with the date, and delete it here.
- **On decline:** it goes back to being work. Note what was actually seen — that is usually the
  most valuable line in the whole file.
- Nothing here is cited as established anywhere else while it sits here.

**Created 2026-08-27.** Pseudoregalia had no queue, and three files said that was fine because "an
adapter with nothing pending does not need an empty one" — while `../../agent_docs/status.md` was
carrying Pseudoregalia items nobody had watched. The premise was wrong, not the rule: the user's
call is that **every adapter carries this file**, and `preflight.ps1` now requires it. The entries
below were moved here from `status.md` rather than invented.

**This queue drains.** Confirmed items move to `VERIFIED.md` with the date and are deleted here;
declined ones go back to being work. An entry still here has not been confirmed. Sibling queues:
`../emulator/pokemon/crystal/UNVERIFIED.md`, `../emulator/pokemon/emerald/UNVERIFIED.md`,
`../tevi/UNVERIFIED.md`.

---

## This run — watch these first

**The READY entries below, newest first, at most ten.** Each says what to look at and what correct looks
like; answer each with a plain yes or no at the end of the run. Every entry in this file carries
**READY** (built, waits for your eyes), **OPEN** (not fixed, parked as work) or **DONE** (kept for its
mechanism; nothing to confirm) — the rule is [`../_template/UNVERIFIED.md`](../_template/UNVERIFIED.md), and `dev-scripts/preflight.ps1` fails an
entry without one.

- READY — no state is sent from the title screen, so a recording starts at your first real frame; built and deployed 2026-09-04, unwatched — **set up for the 2026-09-04 run**
- READY — the SFX fix now ships in the DLL (the ghost stole the player's audio attenuation listener; CAUSE AND FIX CONFIRMED in Lua 2026-09-04, `VERIFIED.md`) -- the C++ version rewrites the call instead of answering it, built and deployed, UNWATCHED
- OPEN — a ghost is audible at all; the user's call is silent by default with an optional setting (2026-09-04), not started
- READY — a chaser set to 3s should now LOOK 3s behind, not 3.45s, and a split time should match the ghost you can see (ADR 0049), unwatched — **not the 2026-09-04 run: the chaser is at 60s there to give the audio A/B a ghost-free first minute**
- READY — `"autostart": false` in config.json now stops the mod starting a client (the old MESHGHOST_NO_AUTOSTART still counts), built and deployed 2026-09-03, unwatched
- MEASURED 2026-09-02 (logs) — the launcher forgets a child the port walk has moved off: cross-wire provoked on one port base, recovered; then both copies walked normally from 7778
- Pending — three input bounds from the 2026-09-02 adversarial review, built and deployed, unwatched
- Pending — every peer-named asset now resolves through the CATALOG GATE, built and unwatched (2026-09-01)
- Pending — the WALL-KICK mirror v1: watched once, hedged, with two stated limits (2026-09-01)
- The ghost's FACING is now interpolated, and nobody has watched it (2026-08-30)
- Pending — the PERFORMANCE WORK: what it bought, what it broke, and what is unwatched (2026-08-30)
- The RENDER SWEEP on netsim: the interp ladder, the rate axis, and what was NOT taken (2026-08-30)
- Pending — `bb`, `hw` and `hew` got the one-shot counter treatment and were never watched (2026-08-29)
- BUILT 2026-08-29, NEVER WATCHED — the ghost's light is now held at 0
- Pending — the bridge port walk's SECOND-INSTANCE case is still unwatched (2026-08-27)
- Pending — ghost collision turned OFF again (2026-08-27), and it may cost the cling-gem VFX

## [READY] a chaser looks like its own delay, and a split time matches the ghost you SEE (2026-09-04), unwatched

**The defect this fixes shipped and was found by reading, not by watching** (ADR 0049): a ghost this
core invents was drawn one full `interp` behind its own schedule on top of that schedule, because
local ghosts share the interpolation buffer with relay peers and nothing subtracted the delay back.
At the shipped 450ms that made **a chaser configured for 3s appear at 3.45s**, and it made the split
time describe a ghost 450ms ahead of the one on screen -- in the one feature racing a ghost is for.

**What to watch, and both halves want a stopwatch rather than an impression:**

- Set `chaser.enabled: true` with `chaser.delay: "3s"`. Walk a straight line, stop, and count how
  long until the chaser reaches where you stopped. Three seconds, not three and a half. The old
  behaviour is 15% late, which is the kind of thing that reads as "feels a bit off" rather than as a
  number, so compare against a clock rather than a memory.
- With a replay ghost and `replay.split_times: true`, stand exactly where the ghost is drawn. The
  tag should read about `0.0s` there. Before this it read `0.0s` when you stood where the ghost's
  RECORDING was at that moment, which is a spot the ghost had not visibly reached yet.

**Everything measurable is already measured** -- the Go tests pin both numbers, and each one was run
against a deliberately reintroduced defect to prove it fails (the end-to-end one reads 637ms where
200 is wanted). What no test can answer is whether it now looks right, which is the whole reason
this entry exists.

## [READY] the title screen no longer reports a player (2026-09-04), unwatched

**Found in the user's own recording:** every `record_on_launch` clip opened with a stack of
`TitleScreen` samples at [0,0,0], 250ms apart, which is the keepalive cadence for a state that is
not changing. The core promises the opposite (`bridgeserve.go`'s `record_on_launch` comment) and
cannot deliver it, being forbidden from knowing what a menu is -- and this adapter's existing "no
pawn, send null" branch never fired, because Pseudoregalia's title screen is a real level with a
real player pawn standing at the origin. The gate now matches the level name against a list of
non-gameplay maps, currently just `TitleScreen`.

**What to watch:** start with `record_on_launch` on, sit in the menu a while, then play. Correct is
a recording whose first sample is your first real frame in a real level, with no `TitleScreen`
lines at the top of the file. Worth noticing while there: no peer standing at the origin while you
are both in menus.

**If another non-gameplay map exists** (credits, a loading map), it needs adding to the same list,
and it will look exactly like this bug did.

**MEASURED 2026-09-04 on the user's own run, and still theirs to confirm on screen:** the game came
up at 11:58:19 and `rec-20260904-115825.ndjson` opens its first sample at 11:59:15 — **56 seconds
of menu with nothing recorded** — in `ZONE_LowerCastle`, at a real position. `TitleScreen` appears
**0 times** in the whole 6.8MB file, against a stack of them at the top of every clip before the
fix. That is the file half of the entry; what is left for eyes is that the menu behaved normally
while it recorded nothing.

## [READY] the SFX fix in the DLL, unwatched -- the diagnosis trail that got there is kept below (2026-09-03 -> 2026-09-04)

**WHAT TO WATCH, and it is the only thing left here:** the fix was proven in Lua and confirmed by
the user (`VERIFIED.md`, 2026-09-04), then rewritten as production C++ in a DIFFERENT and better
shape -- `register_audio_listener_guard` rewrites the argument of
`SetAudioListenerAttenuationOverride` in a pre-hook, so the engine's own call uses the player's
capsule and no second call is made. **A different implementation is a different thing to watch.**
Built with `build-pseudoregalia.bat` and deployed to both installs on 2026-09-04; it takes effect
on the next game start.

Correct is: play with the chaser on, let ghosts spawn and despawn repeatedly, and cross zones with
one alive -- your own SFX never drop out. The log carries the first five corrections
(`audio listener: a call pointed the attenuation listener at ... -- redirected`) and then goes
quiet on purpose, so a silent log after five is the healthy state, not a stopped guard.


**The user, after a session with a replay ghost running:** *"think ghosts are eating up the players
sound, like sfx is not doing anything when the player does things, but ghosts had them."* Logged at
their request rather than chased -- nothing here has been reproduced or measured by the agent, and
no fix has been attempted.

**Why this is plausible rather than surprising, and where to start.** The ghost is a real
`BP_PlayerGoatMain_C`, so triggering the pawn's own systems gets its AUDIO for free -- which the
project already knows and already has a rule about: `ideas.md`'s SILENCE CLAUSE (2026-08-15), *"ghosts
should be silent"*, with the suppression meant to happen immediately after the call that starts a
sound. Two shapes fit what was reported, and they want different fixes:

- **A ghost is playing sounds it should not** -- the silence clause is not covering some path (a new
  effect, the replay/chaser feed, or a sound started by the animation rather than by our trigger).
  That alone would explain "ghosts had them".
- **Concurrency, which would explain the other half.** Unreal sounds carry concurrency limits, and a
  common setting is a small per-sound cap that STEALS the oldest instance. If a ghost plays the same
  cue the player is about to, the player's own can be refused or cut -- the ghost is not merely noisy,
  it is spending the player's voices. This is the shape that matches "the player's SFX do nothing".

**First measurement when this is picked up**, cheapest first, and none of it needs a fix in hand:
play with NO ghost (no replay in `replay/active/`, chaser off) and confirm the player's SFX are
normal -- that separates a ghost-caused fault from an unrelated audio regression. Then one ghost, and
listen for whether the player's sound is missing only while the ghost is doing something. A Lua probe
can enumerate live `AudioComponent`s and their owners (`../CLAUDE.md`: probe in Lua, hot reload) --
who owns them and whether the ghost's are active is the question, and the answer picks between the
two shapes above.

**Not a regression from today's work, as far as anything shows:** nothing in the 2026-09-03 session
touched audio. It may well predate the replay feature entirely; the replay ghost is simply the first
time a ghost has been reliably present and doing things while the user listened.

**The instrument is built, 2026-09-04, and the run is set up but not yet run.**
`probe_audiocensus/` (indexed in `PROBES.md`) logs every `AudioComponent` appearance, START and
STOP, attributed to the player or a ghost by name containment, and dumps each distinct cue's own
CONCURRENCY settings the first time it is seen — that dump is what decides the second shape
without needing an ear, because a cue that caps itself and resolves by stopping the oldest
instance IS the mechanism. Deployed armed to both installs. **It is blind to
`PlaySoundAtLocation`/`PlaySound2D`**, which create no component and are the usual shape of an
anim-notify footstep, and blind to whether an active component was actually audible — both stated
in its header, and both mean a quiet log is not an acquittal.

**The A/B is built into the session rather than asked of the user**, so there is nothing to time
and no window to hit: the chaser is configured to 60s, so the first minute of play has NO ghost
at all and the second minute has a ghost repeating the same actions in the same place. Do the
noisy things (jump, land, slash, dash, cling) in both halves and listen to your OWN sound. The
probe marks the boundary itself with a `GHOSTCOUNT 0 -> 1` line. Both installs also carry
`record_on_launch: true` and `offline: true` for this run.

### RUN 2026-09-04: reproduced, and the trigger is GHOST PRESENCE, not the zone change

**The user's rule, arrived at across three attempts in one session, each one narrowing it:** *"I
lost the player sfx after moving to another zone, it was working in the first zone before & after
the ghost"*, then *"moving back and forth between the zones fixed it"*, then — the isolating
one, with the zone held constant — *"both the player & ghost had sounds while it was spawned, but
the sfx went away once the ghost despawned"*. **A ghost alive means you can hear yourself; the
moment it despawns your own SFX are gone; the next chaser spawn brings them back.** The zone
change was never the cause: a transition destroys the ghost, which is the same event.

**The user also hears MUSIC throughout, and *"any player related sfx is completly silent"* — not
faint — jumping, wall kicks, sliding, backflips.**

**What the log settles, and it turns the diagnosis around** (`UE4SS.log`, the 12:17 cycle):

- **The game never stops playing your sounds.** Your own footstep, land and jump components are
  still created and still go active DURING the silence, seconds after the ghost went. So this is
  not a suppression and not a missed silence clause — the sounds are played and are inaudible.
- **One `MainPlayerController_C`, driving your pawn, unchanged across the whole cycle.** A second
  local player stealing the listener is ruled out by measurement rather than by argument.
- **The view target is stable and tracks the player** — the same `BP_PlayerCam_C` before, during
  and after, moving with you. The camera is not wandering, and the earlier "stale rig from the old
  zone" idea is dead: the rig followed the transition correctly at 12:09:11.
- **This game's sound classes are `SoundClass_SFX`, `SoundClass_Music`, `SoundClass_UI` and
  `Master`** — the split the symptom follows exactly. Their `Properties.Volume` all read 1.00, and
  that read CANNOT close the question: a runtime SoundMix modifier ducks a class inside the audio
  device without writing anything back to the asset.

**The standing hypothesis, and why it fits everything:** a ghost is a CLONE OF THE PLAYER PAWN, so
its BeginPlay and EndPlay run the game's own player-pawn audio setup and teardown against the one
global audio device the player is listening through. A mix pushed when a pawn appears and popped
when one is destroyed produces precisely this — audible while a ghost exists, silent the moment it
goes, music untouched because it is a different class. Hooks on `PushSoundMixModifier`,
`PopSoundMixModifier`, `SetBaseSoundMix`, `ClearSoundMixModifiers` and the two class-override
statics are armed in the probe (all six resolved; `StopAllSounds` is not on this build), so the
next despawn names the call if that is what is happening.

### CAUSE FOUND 2026-09-04: every ghost STEALS the player's audio attenuation listener

**The call, caught twice out of two ghost spawns, ~0.1s before each `GHOSTCOUNT 0 -> 1`:**

```
LISTENERCALL SetAudioListenerAttenuationOverride
  arg1=CapsuleComponent ...PersistentLevel.BP_PlayerGoatMain_C_2147378487.CollisionCylinder
```

and the coverage line names that pawn `BP_PlayerGoatMain_C_2147378487=ghost`. The second spawn did
the same with its own new pawn (`...2147366642`). **`BP_PlayerGoatMain_C` pins the player
controller's audio ATTENUATION listener to its own collision capsule on BeginPlay — and a ghost is
a clone of that pawn, so every ghost that spawns takes the listener with it.**

Attenuation is what decides how loud a spatialized sound is at the ear, so the whole report falls
out of it:

- **Ghost alive:** attenuation is measured from the ghost, which is standing near the player, so
  both are audible — the user's *"both the player & ghost had sounds while it was spawned"*, and
  the original *"ghosts had them"*.
- **Ghost despawns:** the override still names a component that no longer exists, so every
  spatialized sound attenuates to nothing. **Music is 2D and never consults attenuation**, which is
  why it survives, and why the silence is total rather than faint.
- **Next ghost spawns:** its BeginPlay re-points the override and everything returns.
- **A zone change with a ghost present:** the ghost dies with the level. That is the first report,
  and the reason it read as a transition bug across the first three reports of 2026-09-04.

**This is the loose-sword class again** (`VERIFIED.md`, 2026-09-01, the ghost repointing the
watcher's `weaponRef`): a singleplayer game's own code claims *the* player, and a ghost is a real
player pawn, so it claims it too. `../CLAUDE.md` already carries the rule — this is its second
instance, and the first one outside gameplay state.

**Eliminated on the way, each by measurement:** `SetAudioListenerOverride` and its two siblings are
never called; a ghost spawn fires the game instance's own settings pass (`SetBaseSoundMix`, then
four `SetSoundMixClassOverride` — Master `0.2317`, Music/**SFX**/UI all `1.0`); `MySoundMix` has
`Duration=-1` so it never expires; the sound classes' own volumes never change; a despawn fires
none of the ten hooked audio calls.

**THE FIX, not yet built:** the ghost decouple pass that already runs on the spawn tick — the one
clearing the ghost's HUD ref, game-instance ref and damage values — puts the attenuation listener
back on the LOCAL player's capsule after the ghost's BeginPlay has stolen it. **Nothing is watched
yet**: the cause is named from the log, the fix is not written, and neither has been heard.

**Two instrument limits found the hard way today, both recorded because a reader would otherwise
trust the readings:** the controller's listener-override fields (`bOverrideAudioListener`,
`AudioListenerComponent` and neighbours) **do not read on this build** — each handed back a fresh
UObject wrapper at a different address every sample, which `prop()` reports as *resolved* because
the read itself succeeds. And the probe's first pawn discriminator was wrong: **a ghost here reads
as POSSESSED**, so asking each pawn for a Controller labelled every ghost as the player. It asks
the controller which pawn it drives now.

## [OPEN] a ghost is AUDIBLE, and it should be silent by default (user's call, 2026-09-04)

**The user, watching the diagnosis above:** *"think this could be a optional feature maybe, but
ghost audio should be off by default"*. Confirmed on screen the same session — *"both the player &
ghost had sounds while it was spawned"* — and the census names the cues: a ghost's own
`Cue_FootstepGeneric` components appear and go active exactly like the player's.

**This is the SILENCE CLAUSE (`ideas.md`, 2026-08-15, *"ghosts should be silent"*) never having
been implemented past one sound.** The only suppression in the adapter is `call_audio_component_stop`
on a ghost's `wallRideSFX` — everything else a ghost makes comes free with the pawn, because the
ghost IS a player pawn and triggering its systems gets the audio with them.

**Not started, deliberately, so it does not muddy the fault above** — the two are separate, and a
ghost being audible is what makes the other one bearable to test. What it needs when picked up: a
silence that covers every path rather than one named component, and a config key that turns ghost
audio back on for anyone who wants it, defaulting to off.

## [READY] `"autostart"` in config.json replaces the environment variable as the way to say "don't start a client" (2026-09-03), unwatched

The user's call: *"even me that is somewhat tech savvy, has no clue what 'an environment variable' means."*
The launcher reads `"autostart"` out of the same config.json the client will read (own folder first, the
same search order as everything else it resolves), by a hand scan for `"autostart": false`; absent or
anything else means start. `MESHGHOST_NO_AUTOSTART` still counts as a no. `config_disables_autostart()` beside `resolve_bridge_base_port`, checked in the constructor after the variable; the log line is `"autostart": false in config.json -- not starting a core`. **What to watch:**
with `false` in the file, the game comes up with no client started and the log line naming the reason;
with `true` (the shipped value) the client starts exactly as before. Root and per-game READMEs rewritten
around the key ("Turning autostart off").

## [READY] the launcher forgets a child the port walk has moved off — mirrored from TEVI 2026-09-02, unwatched

**Reproduced and recovered here too, the same night (agent, from `UE4SS.log`):** both installs put on one
port base (6700) and launched 3 seconds apart; the main install's core was taken by the Copy, the main
logged `the core this mod started (pid 2292, port 6700) is serving another game -- leaving it to that game
and starting another on port 6701`, then `core on port 6701 accepted us`; both games rendered each other.
The custom bases (6700/6800, the user's 2026-08-30 test numbers) were then removed from both installs --
*"shouldn't those be 7778 as well?"* -- and a relaunch 3 seconds apart walked normally: main on 7778, the
Copy `busy` there and accepted on 7779. What is left for eyes: the two ghosts after such a start.

**Mirrored from TEVI, 2026-09-02, unwatched here.** "My child process is alive" was read as "I have a
core": two copies launched a few seconds apart can each spawn on the base port, one core wins the
bind, the OTHER copy's adapter can reach it first, and the spawner is answered `busy` on its own
child's port and walks on while its launcher never spawns again. Watched on TEVI, reproduced on purpose
there and recovered (`adapters/tevi/UNVERIFIED.md`, "the port walk's dead end"). The fix here is the same
shape: `CoreLauncher.cpp` remembers `last_spawn_port`; a live child on a port the walk has moved off is forgotten (never terminated) and a fresh core starts at the cursor. Built with `build-pseudoregalia.bat`, deployed to both installs. **What to watch:** two instances launched a few seconds apart both reach a ghost, with
nobody killing a core; the log line in the copy that lost the race is `the core this mod started (pid N, port P) is serving another game`.


**REVISED the same night, after Emerald showed the first version's flaw (2026-09-02, ~23:00).** Forgetting the
child whenever the walk moved off its port was too eager: two instances whose cores were restarted
together each spawned on the base port, each adapter's sweep attached to the OTHER's fresh core first,
each then took `busy` on its own child, forgot it, spawned again -- three cores for two games, and the
emulator at 3fps under the connect storm (Emerald's sweep ran every frame, eight blocking 50ms connects
each). The rule is now two-part in all four launchers: **a spawner waits on its own child's port and never
sweeps past it while that child lives; the child is forgotten only when its port answers "busy"**, never
on silence. Emerald's sweep also runs every 30 frames instead of every frame. Built and deployed (TEVI,
Pseudoregalia DLLs; both Lua files); unwatched beyond one Emerald reload that reattached cleanly.

## [OPEN] Pending — BOTH INSTANCES HARD-CRASHED seconds after `curve catmull-rom` was switched on (2026-08-30)

**What happened.** On the two-instance netsim rig (relay 60Hz, both clients interp 250ms,
`predict damped`, through `meshghost-netsim` at 60ms/±25ms/2% loss/2% reorder), the curve was
flipped from `linear` to `catmull-rom` with nothing else changed. Both games ran normally for
~13 seconds and then died within two seconds of each other — 20:28:37 and 20:28:39 — with the
empty `Fatal error!` dialog this adapter's crash family is known for (it dies inside the engine
rather than in our frame).

**The logs are clean right up to the last tick**, which is what makes this worth keeping: both
adapters' bridge counters read `send_fail=0 lines_malformed=0` at 20:28:36.7, and both cores
logged nothing but a normal `pid ... is gone -- exiting`. Nothing reported a problem before the
process vanished.

**The curve is the only variable that changed**, and two independent processes dying at the same
moment points at the data they were both rendering rather than at either machine. That is
suspicion, not attribution.

**MEASURED GO-SIDE, and it does NOT close the case** (`core/curvespacing_test.go`, written for
this): `curved()` picks `p0` and `p3` by INDEX and parameterises the spline UNIFORMLY, while a
real session's spacing is wildly uneven — 60Hz samples ~16ms apart, a `keepalive` re-send 250ms
after the last change, plus the link's own loss and reordering. On a STRAIGHT constant-velocity
run, where a straight line should be exact, a 250ms/16ms spacing mismatch throws the rendered
position **0.45 segment lengths** outside the segment (evenly spaced samples stay under 0.01).
So the curve really does misbehave on this rig's data — but 0.45 of a segment is a wobble, not a
teleport, and **it is not a crash mechanism.** The cause is still unknown.

**A CONFOUND that must be stated, because it was my own rig fault.** At crash time the two games
were CROSS-WIRED: the Copy was attached to the core started for instance 1 (port 6674), while
instance 1 was attached to a stale mod-spawned core on 6672 that neither launch created. Both
mods walk 8 ports from the same base, so whichever core answered first won, and the
kill-all-and-restart loop used for each sweep step reshuffled it every time. **Fixed for the
future** by giving each install its own far-apart base (6700 and 6800), which the walks cannot
overlap. Whether a stale core was serving one game settings from an earlier step is not knowable
after the fact — so this crash sits on a rig that was not clean, and a reproduction attempt has
to happen on the fixed one before it means anything.

**What to do next, in order:**
1. Relaunch both games on the fixed rig at `linear` and confirm a normal session — that this is
   healthy is not currently established.
2. Only then re-enable `catmull-rom` deliberately, watching for the same ~13-second delay. If it
   crashes twice, it is the curve and the next step is the crash dump under
   `pseudoregalia/Saved/Crashes` rather than more theory.
3. If it does not reproduce, this stays open and unattributed rather than being quietly closed —
   an unreproduced simultaneous crash is exactly what an intermittent defect looks like early.

**The curve knob is UNJUDGED as a result** — nobody has yet seen whether it fixes the jump chop it
was enabled to test, because the session ended before either player could look at a jump.

---

## [READY] The RENDER SWEEP on netsim: the interp ladder, the rate axis, and what was NOT taken (2026-08-30)

**The rig**, which is the part that makes the numbers mean anything: **two real game instances**
(the user's call -- *"think i used 2 clients when testing with tevi, also easier to spot that way"*
-- a loopback self-ghost was the first plan and is a weaker read), both clients through
`meshghost-netsim` at **60ms latency / +/-25ms jitter / 2% loss / 2% reorder**, relay at the
shipped 20Hz, `interp` swept in both installs' `config.json`. Same fault profile TEVI's sweep used,
so the two games are comparable.

**Judged CLIMBING from the broken end, on the user's rule:** *"our goal should be to go from low, to
high, not just go high and then low ? so we actually notice when it 'gets good' instead of 'when it
gets bad'"*, and *"easier to notice bad things getting better/perfect, than spotting when something
gets slightly worse"*. The agent had started at the top and had to be corrected twice -- once on
`interp`, then again on the rate axis, where "the bad end" is the opposite direction.

### The interp ladder — walking back and forth past each other

| interp | The user's read |
| --- | --- |
| 0ms | broken, as intended (the floor of the ladder) |
| 175ms | *"still looks choppy/bad when moving back/forward"* |
| 200ms | *"mostly smooth, but i see some chopy/jittery parts like 2-3"* |
| 225ms | *"noticable choppy/jittery in comparison to 235"* — on a SECOND fault sequence, so not a dice roll |
| 235ms | *"i don't think im seeing anything choppy/bad anymore"* |
| 250ms (shipped) | clean |

**The wall sits between 225 and 235ms, and Pseudoregalia therefore keeps the template's 250ms** --
where TEVI settled at 175ms on the identical link. A per-game difference measured rather than
assumed, which is what ADR 0040 exists for.

**A 240ms override was written and then withdrawn the same hour, on the user's call.** They chose
240 first (*"thats still a 10ms win compared to the 250ms we have used before"*) and then
*"actually just put it at 250ms"*. Recorded because the reasoning matters: the user's standing
preference is **the lowest delay that holds, not the safest high one** -- interp is visible lag by
design -- and 240 vs 250 is inside one dice roll of the fault sequence anyway.

### The rate axis — judged on JUMPING, which was the user's idea

**20 -> 30 -> 40 -> 50 -> 60Hz barely moved the jump chop.** *"60 is also choppy"*. Tripling the
rate is the biggest lever the network side has, so **that is a real result: the jump chop is not
sample spacing**, and the shipped 20Hz is vindicated -- there is no reason to spend three times the
bandwidth on a defect it does not fix.

**The user picked the motion per axis, and it mattered:** back-and-forth walking for interp,
jumping for rate. A jump is an ARC; on a straight path `catmull-rom` and `linear` are numerically
identical, so the walking test could never have said anything about curvature.

### What was NOT taken, and why

- **`extrapolate`: not taken.** The user remembered TEVI's outcome correctly and the agent quoted a
  stale line at them: the mid-sweep KNOB winner included prediction, but **TEVI's settled pick is
  175ms / linear / prediction OFF**, because prediction hid the delay and pushed a landing ghost
  through the floor. *"extrapolation felt way more instant/responsive, but it looked visually bad
  in comparison for Tevi."* Pseudoregalia has more airtime, so the sink has more chances, not
  fewer. `dev-scripts/README.md` now carries both lines together so the winner cannot be quoted
  alone again.
- **`curve catmull-rom`: UNJUDGED.** It was enabled to test the jump chop -- an arc drawn as chords
  is the obvious suspect once rate is ruled out -- and **both game instances hard-crashed ~13
  seconds later**, before anyone could look at a jump. See the crash entry below.
- **Measured Go-side afterwards** (`core/curvespacing_test.go`): the curve is uniform-parameterised
  but picks its neighbours BY INDEX, and this session's spacing was wildly uneven (60Hz samples
  ~16ms apart, a 250ms keepalive re-send whenever a player stands still, plus the link's loss and
  reordering). On a straight constant-velocity run, where a straight line should be exact, that
  bends the rendered position **0.45 segment lengths**. Real defect, pinned by a test -- but a
  wobble, not a teleport, so **it does not explain the crash** and was not claimed to.

**So the sweep's remaining question is unchanged: what makes a jumping ghost look choppy at every
rate and every interp?** Not spacing, not delay. The next candidates are the curve (once it is safe
to enable) and the ghost's own animation being driven by arriving state rather than played through.

---

## [READY] Pending — the PERFORMANCE WORK: what it bought, what it broke, and what is unwatched (2026-08-30)

**The problem, user-reported:** one peer took the game from 144fps to 70-80; two real clients the
same; three ~40; four ~30. *"The game becomes unplayable with even just 2-3 players."*

**What it turned out to be:** four whole-world `UObjectGlobals::FindAllOf` scans running on the
tick, none of it rendering. Method, table and the transferable lessons:
`../../agent_docs/pitfalls/method.md`, "A ghost cost half the frame rate".

**Peak measured result, before the safety reverts below:** `tick_total` 9819 -> 2924 us/frame,
per-ghost 6283 -> 309 us, and the user's own reading **70-80fps -> 141-144fps** with a peer
present. Two ghosts measured 606 us total, i.e. linear.

### What SHIPPED and is still in

| Fix | What it was | Worth |
| --- | --- | --- |
| Dev-toggle sweeps gated | `hide_ghost_shadow`/`hide_ghost_nametag`/`hide_ghost_fx` swept the whole world every tick **in normal play, armed or not** | ~3300 us/frame |
| Outline sweep walks the attach tree | was `FindAllOf` over every skeletal + static mesh in the level, every 5th frame | ~500 us/frame |
| Light hold walks the attach tree | was two whole-world light scans **per ghost per tick** | ~6357 us/frame |
| Afterimage sweep on an interval | was `FindAllOf("BP_AfterImage_C")` every tick | ~1200 us/frame |

**The gating was reverted for one A/B run and then restored**, because the invisibility it was
suspected of turned out to be the rig. It is worth ~3300 us/frame and is IN.

### What was REVERTED, and why it must not be retried naively

**A crash appeared, it was attributed to these fixes, AND THAT ATTRIBUTION WAS WRONG.** The user
reloaded a save on the second client and the game died with the empty `Fatal error!` dialog. The
caches were the obvious suspect and the reasoning below is sound in itself -- but **bisecting
settled it the other way**: with the pre-session DLL deployed (commit `b74a1d1`, confirmed live by
zero `PERF` lines in the log), *"reset to last save"* **still crashed client2**. So the crash is
PRE-EXISTING and predates every change made on 2026-08-30. **Closed 2026-09-01 -- it was the
nametag residue; see the CLOSED section below and `VERIFIED.md`.**

The caches were reverted anyway, and should stay reverted, because the lifetime defect described
here is real whether or not it caused this particular crash. Three fixes had cached raw pointers to
level-owned objects between ticks: the local controller, the ghost's light components, the pooled
projectile actors.

- **RELOADING A SAVE INTO THE SAME LEVEL DOES NOT FIRE THE `LoadMap PRE` HOOK** -- the one place
  this file drops every other level-owned pointer. Confirmed from the log: no `LoadMap PRE fired`
  line anywhere near the crash.
- **`IsUnreachable()` IS NOT A VALIDITY TEST.** It dereferences the object being tested, so the
  guard written for a freed pointer is the same crash. The 2026-08-13 entry above the LoadMap hook
  already said this; it was written and then not applied to the two caches that followed.
- Reverted: the controller cache (+1308 us/frame) and the projectile pool cache (+~1200 us/frame).
  Both carry a comment saying the obvious optimisation is a crash and **what it needs first: a
  hook that fires on a same-level reload.** Not a cleverer guard.
- The light fix was KEPT but rebuilt to walk `remote.ghost`'s own attach tree -- same saving, no
  pointers held, and the ghost's lifetime is already managed by this file.

### CLOSED 2026-09-01: the reset-to-save crash, the vanished nametags, and the spawn holds

The two-session hunt that lived here (2026-08-30 -> 09-01: seven configuration runs, four refuted
theories, the causal spawn-tracking experiment, the race finding, the intermittency protocol) is
**resolved and user-confirmed** -- the cause was the nametag trio's stale component pointers,
never cleared by any release path. Confirmed entries: `VERIFIED.md` 2026-09-01. Transferable
lessons and the full method: `agent_docs/pitfalls/by-lesson.md`, "The reset-to-save crash". The
run-by-run hunt log is in this file's history at commit `be2763b`.

**Still open from that closure, filed here so it is not lost:**

- **The two reverted perf caches are UNBLOCKED.** They were reverted pending "a hook that fires
  on a same-level reload" -- the InitGameState PRE hook now IS that hook (it fired on every reset
  in the 2026-09-01 logs). Re-landing the controller cache (+1308 us/frame) and projectile pool
  cache (+~1200 us/frame) with their pointers cleared there is ~2500 us/frame waiting on an
  afternoon. See "What was REVERTED" above.
- **The earlier exe-side fault (+0x1CD9A60, five dumps) was never separately explained.** It is
  ATTRIBUTED to the same residue (a use-after-free crashes wherever the garbage points), and no
  crash of any kind has reproduced since the fix -- but if that address ever returns, it is its
  own bug and the attribution was too generous.
- **A LOG-VOLUME perf audit has never been run (user's standing priority, 2026-09-01: perf is
  high priority on all adapters).** The 2026-09-01 session log shows steady per-event
  `Output::send` traffic in normal play -- `bridge:` stats ~1/s, `CAMERA_TRACE`, per-redraw
  `TRACE remote` lines -- 475 call sites total, cost unmeasured. Measure with `perf_report.txt`
  before touching anything; Emerald's lesson was one line a second costing 7fps (console there,
  file here -- the file may well be fine, which is what the measurement is for).

### The PEER LADDER, first run (2026-09-01): linear to 50, superlinear above, and a wire bug at 150

**The definitive post-fix ladder (same day, all three fixes in, 0-150 with recovery) is in
`agent_docs/crowd-limits.md`'s Pseudoregalia section and the README's performance section — this
section is the first run's record and the findings that came out of it.**

**Rig:** one real client at the standing spot, `meshghost-fakeadapter -clients N` (idle orbiters,
no names), relay at 20Hz / `-max-clients=200`, `perf_report.txt` armed. Rungs 4 / 16 / 50 / 100 /
150. User's read at 50: *"started to drop fps quite a bit, but i guess its still better than what
1-2 ghosts were at before"* (pre-fix, ONE peer cost 144->70).

| peers | tick_total | remotes_loop | per-ghost | frames/2s (~fps) |
| --- | --- | --- | --- | --- |
| 0 | ~1.5 ms | - | - | ~287 (~144) |
| 4 | ~3.1 ms | 1.3 ms | ~330 us | ~276 (~138) |
| 16 | ~7.6 ms | 5.0 ms | ~310 us | ~175 (~87) |
| 50 | ~23 ms | 17.2 ms | ~344 us | ~61 (~30) |
| 100 | 59-94 ms | 43.5 ms | ~435 us | ~20 (~10) |

**Findings, in priority order:**

1. **`loop_tail` (the reflection-driven redraw) is ~80% of per-ghost cost at every rung**
   (~250-350 us/ghost). It is THE target for any crowd work: batching the reflected calls,
   caching resolved FProperty offsets per class, or a cheaper position write would move every
   row of the table at once. Unmeasured which of its calls dominates -- perf-slot it first.
2. **Per-ghost cost RISES with population** (310 us at 16 -> 435 us at 100), and flat subsystems
   grew too (`ls_rest` 0.7 -> 4.4 ms at 100): reflection lookups appear to scale with total
   UObject count. So 150-peer numbers cannot be extrapolated from 16-peer measurements.
3. **150 peers found a REAL wire bug** -- `bufio.Scanner: token too long` on one synthetic core.
   Cause found in `transport.Send`: a write-deadline expiry mid-line left the connection open
   with an unterminated line, and every later Send appended to it. **Fixed 2026-09-01 (a failed
   write closes the stream connection), regression-tested (`TestFailedWritePoisonsConnection`,
   verified to fail against the old code).** The reconnect path takes over; what a 150-peer room
   looks like ACROSS a reconnect has not been watched.
4. **The empty-projectile-pool rescan was refilling at the sample cadence** -- 577 us/frame paid
   in every session where nobody ever fires. Fixed same day (interval-only rescan); the
   post-fix no-peer baseline should read ~950 us/frame and has not been re-measured.
5. **Ladder caveats:** all idle anim, one machine carrying game + relay + 150 cores at once.
   Engine-side pawn cost is inside the fps readings but outside the PERF numbers. (Fake peers DO
   carry nametags -- "fake-ghost-N" -- confirmed on screen at 150, so tag cost is included.)

**LIVE 150 (second attempt, wire fixed) found the next layer down: a DRAIN RUNAWAY (2026-09-01,
fixed in source, UNWATCHED).** With the relay fix in, all 150 peers joined clean -- and the GAME
spiralled: single ticks of 19s -> 33s -> 45s, 0fps, GPU idle. Cause read from the drain loop:
`game_thread_tick` replayed EVERY queued bridge line faithfully, so once one tick ran longer
than the arrival rate (150 peers x 20Hz = 3000 lines/s), the queue compounded -- and the backlog
replayed the whole session's spawn history in order, which the fingerprint probe measured as
**2051 player pawns alive at once** before the queued despawns caught up. Removing the crowd
left ~20fps of GC hangover from the two thousand corpses. The fix: latest-wins collapse -- the
drain now keeps only the NEWEST `render_remote` per player (lifecycle lines all still apply in
order), bounding a tick's work by peer count rather than by how far behind it got. **CONFIRMED
2026-09-01, same session: stable slideshow at 150 (bounded 250ms ticks, rig-starved), recovery
in seconds when the crowd leaves, and a reset-to-save restored max fps -- moved to
`VERIFIED.md`.** Crowd-rig calibration for repeats: ring **z = -545**, radius <= 200 at the
standing spot (pawn-center ground is -733; -650 and -580 both left bodies partly buried).

### The TAIL SPLIT is READ (2026-09-01): `tail_sweeps` owns the redraw, and it is name-based reflection

**`plans.md` "Crowds that PLAY" step 1, done.** One 16-peer rung on the deployed instrumented
build, `perf_report.txt` armed, same rig as the ladder (relay 20Hz / `-max-clients=200` /
`-ghost-collision=disabled`, `meshghost-fakeadapter -clients 16` orbiting the ZONE_LowerCastle
standing spot at ring z=-545 radius 200, idle anim, one machine). Four consecutive 2s report
blocks, all agreeing within a few percent; the table is one of them (15:07:28, 186 frames/2s
= ~93fps).

| slot | us/frame | per ghost | share |
| --- | --- | --- | --- |
| `tick_total` | 6911 | - | 100% |
| `remotes_loop` | 5225 | 327 us | 76% of tick |
| -- `loop_tail` | 4182 | 261 us | **80% of the loop** |
| ---- `tail_sweeps` | 2828 | 177 us | **68% of the tail** |
| ---- `tail_light` | 1349 | 84 us | 32% of the tail |
| ---- `tail_posetrc` | 2 | 0.1 us | ~0 |
| ---- `tail_events` | 0 | 0 us | ~0 |
| `local_state` (flat) | 1252 | - | 18% of tick |

**The four sub-slots sum to `loop_tail` with no unattributed remainder** (4179 vs 4182), so the
split is complete: there is no hidden fifth cost inside that span.

**The finding: two of the four blocks are free and one is the whole target.** Pose-trace and
event mirrors cost nothing measurable; the optimization is `tail_sweeps` (the visibility /
outline / custom-depth sweeps), with `tail_light` a real second at half its size.

**And `tail_sweeps` is exactly the shape the step-2 cache was designed for**: read of
`Plugin.cpp` 17742-18120 shows it is `GetValuePtrByPropertyNameInChain<...>` all the way down --
`bVisible`, `bRenderCustomDepth`, `VisualMesh`/`WeaponMesh`/`LightMesh`, `RootComponent`,
`AttachChildren` -- a name lookup per component per ghost per tick, plus a `TFieldRange`
property walk over each outline target's class. That also explains ladder finding 2 (per-ghost
cost rising with world population): name-based resolution scales with what it has to search.

- **Unwatched by the user; these are the agent's own numbers**, and nothing visual was judged
  while `perf_report.txt` was armed. It is STILL ARMED in the Steam install -- disarm before any
  visual session, re-arm for step 2's before/after.
- **Step 2 is now unblocked and aimed**: cache the resolved (UClass*, name) -> offset, clear it
  where every other cache is cleared (the InitGameState PRE hook). Expect it to move
  `tail_sweeps`, not `tail_light`; verify with a normal 2-ghost session watched for visual
  regressions, then re-run rungs 16/32/100 against this table.

### Step 2, the REFLECTION-PROPERTY CACHE: built, deployed, measured -59% tick -- UNWATCHED (2026-09-01)

**All 376 `GetValuePtrByPropertyNameInChain` call sites now go through a (UClass*, name) ->
FProperty* cache** (`Plugin.cpp`, `g_property_cache` beside the controller/projectile caches,
cleared with them in `release_all_ghosts` -- LoadMap PRE / InitGameState PRE / the Reset click).
Behaviour-preserving by construction: the cached FProperty* is the exact pointer UE4SS's own
chain walk returns, and the miss path calls that same function. Misses are cached too.

**Measured on the same 16-peer rung, minutes apart, same rig and ring** (before = the step-1
table above; after = four agreeing 2s blocks, 15:16-15:18):

| slot | before | after | change |
| --- | --- | --- | --- |
| `tick_total` | 6911 | 2824 | -59% |
| `remotes_loop` | 5225 | 1548 | -70% (327 -> 97 us/ghost) |
| -- `loop_tail` | 4182 | 959 | -77% |
| ---- `tail_sweeps` | 2828 | 829 | -71% |
| ---- `tail_light` | 1349 | 125 | -91% |
| `local_state` | 1252 | 851 | -32% |
| `ls_rest` | 1197 | 803 | -33% |
| frames/2s | 186 (~93fps) | 266 (~133fps) | +43% |

At 16 peers the game now runs ~133fps against a ~143 solo baseline. Log clean over the run: no
warnings, no lookup failures, 16 nametags drawn every frame, `send_fail=0 lines_malformed=0`.

- **The step-1 prediction was HALF WRONG, on the record:** it said the cache would move
  `tail_sweeps` and leave `tail_light` roughly alone. `tail_light` fell hardest (-91%) -- it was
  name-lookup bound too, not doing distinct work. The flat blocks moving (-32/-33%) is why
  converting every call site paid, not just the named block.
- **User's first read, 2026-09-01, after a reset-to-save (which exercises the cache-clear path)
  and a 2-ghost session with perf disarmed: *"think everything look and works fine"*.** Hedged
  with "think", so it sits here until it holds through normal play; the same session immediately
  found the melee-VFX gap below, which is a missing feature, not a cache regression.
- **Rungs 32/100/150 re-run same day: every rung ~2x faster, the population rise halved but
  survived** (97 -> 219 us/ghost across the ladder, was 321 -> 657; 150 rung dirty, ~114 live).
  Table and caveats: `../../agent_docs/crowd-limits.md`, "The property-cache re-run".
- **What the post-cache profile says is left, largest first (16 peers, us/frame):** `ls_rest` 929
  (flat), `tail_sweeps` 823 (the outline attach-tree walk per ghost per tick -- the per-call
  reflection inside it is now cached, the walk itself is not), `loop_pose_xf` 338, `local_state`'s
  other blocks ~50. The remaining `tail_sweeps` is ~51 us/ghost.

### The projectile-pool crash (2026-09-01): FIXED with FWeakObjectPtr, UNWATCHED under a real shot

**The user's game crashed (`EXCEPTION_ACCESS_VIOLATION` in `game_thread_tick`, the projectile
block) four seconds after they fired a charged shot** -- the pool cache re-landed that morning
held raw pointers to actors the game destroys on impact; full account and the new rule:
`../../agent_docs/pitfalls/by-lesson.md` (mid-level frees have no hook) and this adapter's
`CLAUDE.md`. Fixed same hour: the pool holds `FWeakObjectPtr`, `Get()` per use; `preflight` now
requires a `stale-safe:` annotation on every file-scope raw-pointer cache. Deployed to both
installs. **UNWATCHED: needs a session where a real charged shot is fired and hits something --
the exact sequence that crashed -- plus the peer-side projectile still rendering on a ghost.**

### The sword-throw cross-wire: CLOSED same day -- see VERIFIED.md 2026-09-01 (the flyer suite)

**Every symptom in this section was fixed and user-confirmed on two clients the same day**; the
record below stands as the investigation trail. Remaining opens: a throw across a map seam, a
reset mid-throw, and the ring/dust floor-drop (38) on non-flat ground -- none watched.

### (closed) The sword-throw cross-wire: CARRIER FOUND (2026-09-01) -- it was the thrown-weapon PROP path

**The subtraction that settled it: with `skip_ghost_weapon_prop.txt` armed on the WATCHING
client, the player KEPT their sword through a peer's throw+pickup (user-confirmed live).** Four
carriers were exonerated by measurement first: extras-cap state drops (relay drop-logging saw
none), a shared anim instance (identities distinct), `changeEquippedWeapon`-on-ghost and the
throw montage on the ghost (both flag-sampled clean). So the claimer is the mirror spawning a
real `BP_looseWeapon_C` and/or calling the game's `Change Weapon State` on it -- a singleplayer
game with ONE recallable sword keeping global loose-sword state fits exactly.

- **Next split is BUILT: `skip_ghost_weapon_state.txt`** keeps the spawn + position writes and
  silences only the state call. One watched round names the claimer precisely.
- **The stuck-in-air mechanism is CAPTURED numerically** (WEAPON_PROP_TRACE, 16:38): our position
  writes land (READBACK==RENDER) and by the next tick the actor is back at a FIXED point -- the
  spawned prop's own in-flight logic is a second writer fighting ours. TWO WRITERS ON ONE FIELD.
- **The likely endgame fix, not yet decided:** stop borrowing the game's gameplay-bearing class
  as a cosmetic prop -- reproduce the EFFECT (sword mesh, glow, embed pose) on an actor we fully
  own, which retires the cross-wire, the second writer AND the sinking in one move. That is the
  adapters/CLAUDE.md "reproduce the effect, never adopt the structure" rule; decide after the
  state-call split says which half claims.
- **NEW, user-observed: the sword-landing DUST plays at the GHOST instead of where the sword
  landed.** The `dl` one-shot row can only spawn at the ghost; dust born at a sword's landing
  point needs the sword position. Wants either suppression of sword-landing dust from the `dl`
  counter (sender-side attribution) or a positioned one-shot variant.
- **The whole loopback-era sword-throw record is demoted:** every 2026-08-15 "confirmed live"
  was loopback, where the cross-wire writes the player's own values back and is invisible.
  User, 2026-09-01: assume everything sword-throw is unverified with two peers.

### NEW (user, 2026-09-01): a ghost's MELEE ATTACK shows no VFX

**Found on a two-client session the same hour the cache was confirmed: *"we are not doing the a
vfx when using the melee attacks"*.** The ghost plays the attack montage (montage mirroring
ships); whatever the game spawns alongside a swing is not mirrored -- the same shape as the heal
waves and landing dust before their rows existed (`MIRRORED_EFFECTS` covers heal/chg/hw/hew/rsp/
dl/bb; nothing attack-shaped). MEASURED same hour (`probe_slashvfx`, six swings, all
identical): **`NS_PlayerSlash`, world-spawned at the player's x/y, +30 above the actor origin** --
and the same capture found `NS_FootstepDust` (world-spawned at the feet) equally unmirrored, filed
as a candidate, not added. **CONFIRMED on two clients, user 2026-09-01: "the slash works"
-- moved to `VERIFIED.md`.** Direction was not separately called out; the size-checked Rotation
write is the first suspect if a wrong-facing arc is ever reported. `NS_FootstepDust` stays here
as the filed candidate.

### The OPEN defect: ghosts freeze and vanish, one side only

**User-observed, twice, and NOT explained.** With two clients plus a synthetic peer:

- **Client1's view:** client2's ghost frozen; the fake peer still moving normally.
- **Client2's view:** client1's ghost frozen; the fake peer **not visible at all**.
- Trigger, in the user's words: *"it seems to happen when i move around a lot and do different
  stuffs on client2"*. Earlier in the same session: *"the ghosts also look really slow/laggy"* --
  that half was the rig, see below.

**So client2 stopped RECEIVING while client1 kept receiving.** A one-sided stall, not a rendering
bug.

**The mechanism for the flicker is known**, and it is not itself the bug: `core/remotes.go`'s
`tickRenders` renders whoever `remoteStatesAt(renderTime)` returns and **despawns everyone else**.
A peer whose samples stop arriving -- even briefly -- is despawned, and respawned when data
resumes. Client2's adapter logged **44 spawn/despawn cycles of the fake peer**, ~20/second. So the
flicker is a faithful report of a stream that keeps stopping; the question is why the stream stops.

**A relay failure mode exists that fits, but the one in the log was self-inflicted:**
`relay: pN is not draining its connection (256 messages queued) -- disconnecting it`. The instance
of it that night came from the agent killing cores, so it is a CANDIDATE, not the finding.

**What was NOT the cause, ruled out:** the cross-area filter (both sides reported byte-identical
`area_id`), and the relay dropping either client (both stayed joined throughout the observation).

**RESOLVED THE SAME EVENING, and it was the rig.** Reproduced on a clean rig -- shipped 20Hz relay,
no netsim, no stale cores, one synthetic peer, then both clients -- and it did not happen: the user
confirmed *"the ghosts didn't disappear for client1 this time"*, the adapters logged **0 and 1**
spawn/despawn cycles against 44 before, and the relay logged no stall. Run twice, once with the
dev-sweep gating off and once with it back on, so the gating is EXONERATED too.

**So the cause was the polluted session, not the code**: `meshghost-netsim` still in the path with
2% loss, and dead cores left in the room by the agent's own restarts (four members at one point,
two of them dead, rendering as frozen ghosts). Both are recorded under RIG HYGIENE below. The
mechanism note above still stands and is worth keeping -- a stalling stream really does read as
spawn/despawn churn -- but nothing here is a live defect.

### RIG HYGIENE -- three ways the agent's own rig corrupted the evidence

Written down because each one produced a symptom the user then had to judge:

1. **Both mods walk 8 bridge ports from the same base**, so a kill-and-restart loop reshuffled
   which game got which core, and stray mod-spawned cores appeared in the gaps. At one point the
   two games were CROSS-WIRED. Fixed by giving each install its own far-apart base (6700 / 6800).
2. **Killing cores mid-session leaves the dead sessions in the room** until the relay times them
   out -- at one point four members, two of them dead, showing as frozen duplicate ghosts. Any
   judgement made in that window is worthless.
3. **`meshghost-netsim` stayed in the path from 18:02 until 22:00 on 2026-08-30**, long after
   the interp sweep it was started for had ended (60ms latency,
   +/-25ms jitter, 2% loss), because the install configs still pointed at `127.0.0.2`. That is the
   whole explanation for *"the ghosts also look really slow/laggy"*, and it was the agent's fault
   for not resetting the rig when the task changed.

### What needs the user's eyes, none of it confirmed

1. **That the crash is gone** -- reload a save on a second client, the exact thing that died.
2. **That the freeze/vanish is gone, or reproducible**, on the clean rig.
3. **A ghost must still not glow** -- the light hold was rewritten under a confirmed fix.
4. **A ghost must not draw through walls during an attack** -- the outline sweep now walks the
   attach tree instead of scanning the level.
5. **The peer's thrown sword and ranged shot still appear** -- that block was edited and reverted.
6. **A hypothesis that is unproven and worth testing when the gating goes back in:** the ungated
   dev sweep called `call_set_visibility(component, true)` on anything of the ghost's it found
   hidden, so it may have been acting as an accidental per-tick RE-SHOW. If ghosts stop vanishing
   with the gating reverted, that is the answer -- and the fix is a cheap attach-tree restore, not
   a whole-world sweep.

---

## [OPEN] Pending — a NAMETAG SAT TOO LOW on a friend's machine, never reproduced here (2026-08-30)

**Reported second-hand**, which is the most important fact about this entry: *"nametag sitting too
low, it works fine on my machine. but on a friends machine they had one of the nametags appear
lower than intended"*. Nobody in this repo has seen it, and the person who did see it is not the
person reporting it — so both the symptom and the conditions are one retelling away from the
source.

**What is NOT a plausible cause, and can be ruled out by reading the code.** The tag is placed in
WORLD space: `tag_z = ghost actor Z + NAMETAG_HEIGHT_ABOVE_GHOST` (110 units, ~88 of which is the
standing capsule half). It is not a screen-space widget, so **resolution, DPI, UI scale, aspect
ratio and window mode cannot move it** — the usual "works on my machine" suspects are all
excluded by construction. That is worth stating up front, because it is exactly where an
investigation would otherwise start.

**So the height is only ever wrong if the GHOST'S ACTOR Z is wrong**, and this adapter has a fully
worked precedent for that: the slide, where the engine's own CROUCH path moves the mesh by
`-(capsuleHalf + 1)`. A ghost in a crouch/slide state, or one whose capsule differs from the
standing 88, puts the tag exactly this kind of low. A pawn mid-landing is the other shape.

**Questions the report has to answer before anything is measured** — each points at different code,
and guessing picks the wrong instrument:

1. **Whose tag was low** — the friend's own ghost as seen by them, or another player's?
2. **Was that character doing something** at the time (sliding, crouching, mid-air, landing), or
   standing normally? If it tracked a state, this is the slide problem again.
3. **Was it low permanently or only for a moment**, and did it correct itself?
4. **How many players were in the room** — "one of the nametags" implies three or more, and whether
   the others were correct at the same instant is the cheapest discriminator there is.

**Do not fix this with an offset.** A constant nudge to `NAMETAG_HEIGHT_ABOVE_GHOST` would hide a
wrong actor Z rather than fix it, and this adapter has removed exactly that bandage once already
(`BANDAGES.md` entry 1). `probe_nametag/` already exists and was what settled the colour work.

### Second report, same friend: RELOADING A SAVE REMOVES A REMOTE'S NAMETAG PERMANENTLY (2026-08-30)

*"after reloading to save it removed the nametag off the remote sybil, movement still replicated
correctly"* — relayed by the user, who read it as the name being **sent only once** and never
re-sent when a ghost despawns and respawns.

**The "sent once" half is true and is NOT the bug.** `remote_name` arrives once per peer, and the
mod stores it in `Plugin::nametags`, keyed by player id and kept deliberately OUTSIDE `remotes`
so it survives a peer having no ghost. A level reload does not touch that map, and the core
re-pushes every known name whenever an adapter attaches (`core/remotenames.go`,
`pushRemoteNames`). So the NAME is still in hand after a reload.

**What is not restored is the COMPONENT, and this is a code read, not a measurement.** The
LoadMap teardown (`release_all_ghosts`, the block that runs before a level is torn down) drops
`weapon_actor`, `vfx_components`, `projectile_component`, `recall_glow_component` and re-arms
every "already synced" latch — and **never touches `nametag_component`, `nametag_plate`,
`nametag_plate_mid`, `nametag_applied_name` or `nametag_create_failed`**. Those are raw pointers
to TextRender components the OLD level owned. After the reload:

- `update_ghost_nametag` opens with `if (!entry.nametag_component) { create... }`. The pointer is
  non-null — it just names freed memory — so **the branch that would build a tag on the new ghost
  never runs, and the peer stays unlabelled for the rest of the session** while movement, which
  goes through the newly spawned ghost, keeps working perfectly. That is exactly the reported
  shape.
- Worse, the tick then keeps CALLING through that stale pointer every frame
  (`set_text_render_string`, the position write). That is the same access-violation family as the
  three crashes this very block was extended to fix, and the comment there already predicted the
  next one: *"per-ghost state that outlived its ghost"*. This may be a live crash risk, not only a
  missing label.

**The fix is the same one-liner family: clear those five fields in that teardown block**, so the
next ghost builds its own tag from the name still sitting in `nametags`. Not written yet — the
netsim render sweep is mid-flight and a rebuild would cost the running session.

**How to confirm it on screen** (this is a claim about a running game, so it is not settled until
watched): two instances, both with names set, reload a save on one of them, and look at whether the
OTHER player's tag comes back over that instance's fresh ghost. The mod's own log line
`pid=N remote <id> nametag = "..."` tells you the name is still known, which separates "the name
was lost" from "the component was lost" without guessing.

**This does not explain the tag sitting LOW above** — different symptom, different mechanism. They
are filed together only because they are the same reporter and the same feature.

---

## [OPEN] Pending — LANDING DUST is not working properly, user-reported (2026-08-30)

**User-reported, live, on the two-instance netsim rig** (relay 20Hz no `-loopback`, both clients
through `meshghost-netsim` at 60ms/±25ms/2% loss/2% reorder, both installs at 250ms interp /
linear / no extrapolation, slerp on): *"landing dust not working properly"*.

**The exact fault is NOT recorded yet** — "not properly" could be absent, late, in the wrong
place, on the wrong character, or firing when nobody landed, and those point at different code.
Asked; this entry gets the answer written into it before anything is measured, because guessing
which one it is would pick the wrong instrument.

**What the row is.** Landing dust is one of the mirrored effect rows: `dl` ->
`/Game/VFX/Systems/NS_DustLand`, spawned on the ghost's `RootComponent` with a deliberate
`-GHOST_STANDING_CAPSULE_HALF` Z offset so it sits at the FEET rather than the actor origin
(`Plugin.cpp`, the mirrored-effect table). It is a **fallback** — a ghost that carries the game's
own dust keeps that instead.

**The two things already known to bite this exact row**, both worth checking before anything new:

- **The echo loop, fixed 2026-08-29 by excluding components we spawned, BY IDENTITY.** `dl` is a
  `world_spawned` row, and those are attributed purely by distance, so dust spawned onto a ghost
  standing near its own player used to be read as that player's own landing and sent straight back
  — *"that other player never jumped"*. If the symptom this time is dust on a character who did not
  land, this is the first suspect and the guard is where to look.
- **The netsim rig itself is new for this game.** Effects coupled to message ARRIVAL look correct
  on a clean loopback and wrong under jitter — that is the whole reason the two-rig doctrine
  exists, and this sighting is on the faulted link. So "it looked fine before" is not evidence
  against it.

**Do NOT start from theory.** `probe_dustlight/` already exists and dumps one census line per
character in a live two-instance session; the settled method for this class of question is to log
what actually spawned, on whom, and when, rather than reasoning from the table.

---

## [READY] The ghost's FACING is now interpolated, and nobody has watched it (2026-08-30)

**What changed.** A ghost's facing used to STEP at the send rate. Orientation is opaque to the
core by contract, so `core/interp.go` never interpolated it — it held the older bracketing
snapshot's value until render time crossed the newer one. At 20Hz that is 20 snaps a second, and
the visible error is angular velocity divided by Hz: a slow pan steps ~2 degrees and is invisible,
a fast spin steps ~18 and is not. That is the user's report exactly — *"a bit choppy/low fps at
20hz and 250ms when turning around fast but super smooth when turning around slow"*.

The core now names the pair it used and the fraction it rendered at (`orientation_from`,
`orientation_to`, `interp_t` on `render_remote` — bridge only, zero bandwidth, ADR 0043) and this
adapter interpolates the degrees triple itself, shortest-arc per component so yaw 350 -> 10
travels +20 rather than -340. `GHOST_ROTATION_SLERP`, shipped `true`.

**What to look at — a side-by-side spin.** Stand still and spin the character with the gamepad,
with a loopback ghost offset beside you (the standing dev setup). **Position never changes in this
test**, which is what makes it a clean read on facing alone.

**What correct looks like: the ghost's facing and the player's are indistinguishable at EVERY spin
speed.** Not "smoother than before" — the bar is 1:1, and the failure this replaces was only ever
visible at speed, so a slow-pan check proves nothing. Three things worth watching for specifically:

- **A spin that briefly goes the LONG way round** near the wrap point would mean the shortest-arc
  fold is wrong, and it is the one bug a plain lerp would give.
- **A facing that lags the body**, or leads it, during fast movement — that would mean rotation
  and position ended up on different clocks, which is the whole reason this uses the same bracket
  rather than the simpler chase-the-newest-value damper.
- **A ghost whose facing drifts while it is standing perfectly still.** Nothing should move.

**A/B is a flag flip:** `GHOST_ROTATION_SLERP = false` compiles the block out and restores the raw
field, byte-for-byte the old behaviour.

**Go side is confirmed with the tools** (full suite twice, `-race`, `internal/e2e`,
`core/orientbracket_test.go`) — that says the right two samples and the right fraction reach the
adapter, and says nothing at all about how it looks.

**A/B RUN 2026-08-30 — POSITIVE, AND DELIBERATELY NOT PROMOTED YET.** Three launches on the
loopback rig (relay `-loopback -send-hz=20 -ghost-collision=disabled`, install config 250ms /
linear / no extrapolation), flag on, off, on, nothing else changed between them. The user, on the
ON run first: *"it actually looks smooth now i think ?"*; then on the OFF run: *"it looked a bit
choppy/low fps in comparison"*; then back ON: *"now when im testing slerp again it just looks
'delayed' not bad/choppy"*, and *"so slerp is for sure doing 'something' better"*.

**Why that stays here rather than moving to `VERIFIED.md`:** every one of those is hedged — *"i
think ?"*, *"something"* in the user's own scare quotes. The bar is 1:1, judged as
indistinguishable from the local character at every spin speed, and *"doing something better"* is
not that. It sits here until the user says it plainly.

**THE FINDING THAT MATTERS MOST IS THE SYMPTOM SWAPPING, and it is not a new defect.** Choppy
became *delayed*. Those are different complaints about different mechanisms: the chop was the
facing STEPPING, which this fixed; the lateness is the 250ms interpolation delay doing exactly its
job, on both runs equally. **Slerp does not add delay — it very slightly REDUCES it.** With the
step, facing showed the older bracket until render time crossed the newer sample, so it was on
average about half a sample interval (~25ms at 20Hz) staler than the interpolated version is. What
changed is that the lateness became LEGIBLE: a choppy motion masks a smooth lag, and removing the
chop is what let the delay be seen at all. Expect this shape again on any future adapter — fixing
a stutter routinely "reveals" a delay that was there the whole time, and treating that as a
regression is how a good fix gets reverted.

**RE-CHECK NEEDED after the 2026-08-30 opt-in change.** The confirmation above was won on a build
where the core sent the bracket to every adapter unconditionally. It is now OPT-IN — the mod asks
with `interpolate_orientation` in its bridge `hello` — plus the core suppresses the bracket when a
peer's two orientations are byte-identical. Neither should be visible (the suppression provably
cannot change a pixel, and the opt-in is asserted end to end over a real bridge socket by
`TestHelloOptInReachesRenderRemoteEndToEnd`), **but the confirmed build and the shipped build are
no longer the same binary, so the confirmation does not automatically carry across.** One spin is
enough. **The tell if the wiring broke: the ghost's facing steps again exactly like the flag was
off** — check the CORE log for `adapter asked for interpolated orientation`, not the mod's own
HELLO line, which only proves it built the string.

**So the next question is a KNOB, not a bug**, and it is the one ADR 0040 shipped for exactly this:
`interp` (250ms here, never swept for this game — TEVI measured 175ms on 2026-08-28) and
`extrapolate`, which is off. Both are config-only in the install's `config.json`, needing a
relaunch and no rebuild. **`extrapolate` now covers rotation too** (`interp_t` above 1, ADR 0043)
and that half has never been on screen in any form.

---

## [DONE] DRAINED 2026-08-27 — the health bar, and the ghost that could damage the player

Both halves of what used to sit here were closed and user-confirmed the same day, so the entry is
gone rather than left to rot. Where each piece went:

- **The health bar stuck full** was the ghost's OWN HUD widget drawn over the player's, removed
  with stock `RemoveFromParent`. `VERIFIED.md`, 2026-08-27. The shared-singleton theory really was
  refuted, exactly as this entry argued — the value was never wrong, only the widget being looked
  at. The control-experiment pair that proved it was the user's own design and is recorded there.
- **The ghost damaging the player** was the game's own `hitActorsArray`, and the six candidates
  this entry had ruled out are each kept as a recorded negative in `FLAGS.md`. `VERIFIED.md`,
  2026-08-27.
- **`CurrentHp`'s own measurements** (max 80, 5 per pit fall, where it lives, why the HUD caches
  nothing) live in `PLAYER_FIELDS.md` and `documentation.md`, which is where a field belongs.

Left here as a one-time marker because the entry was cited from `status.md` while it was open;
delete it freely once nothing points at it.

## [OPEN] Pending — a BLACK FLASH when a ghost appears, cause unknown after two negatives (2026-08-27)

**User-reported:** *"'black flash' on the screen whenever a ghost appears, is this something the
ghost is taking/applying from the player as well when they spawn in? similar to the health hud/ui
thing?"* — the same frame that explained the camera rig, the HUD, the shadow and the damage.

**Not confirmable by eye, on the user's own account** — *"i can't really confirm, as its hard to
see/test"* — which is why both attempts were built to report on themselves rather than rely on
watching.

| Tried | Result |
| --- | --- |
| Stop the ghost's `Timeline_2`/`Timeline_3` (the pawn's fade timelines, named by the fade census) | **REFUTED by its own readback**: `IsPlaying` reported `not playing` on every ghost, every timeline. They were never running, so stopping them was cosmetic. |
| Neutralise a camera fade raised within 10 ticks of a ghost spawn (`GHOST_FADE_GUARD`) | **Armed on `StartCameraFade` and NEVER FIRED.** No camera fade is raised anywhere near a ghost spawn, so the flash is not a camera fade either. |

**Both negatives came from instruments rather than from the user squinting**, which is the part
worth keeping: an unconfirmable symptom was turned into two clean measurements.

**What is left to try**, in order of cheapness:
1. `enterTransition` is a Blueprint function on the pawn and cannot be hooked on this build — but
   what it TOUCHES can be watched. A widget added to the viewport would show up the way the ghost's
   own HUD did.
2. The ghost's `PlayerLight` / `PointLight` ChildActor components fire at spawn and were never
   examined; a light popping on for a frame can read as a flash.
3. Level streaming around the spawn, which nothing has looked at.

## [OPEN] Pending — the ghost FLOATS UP slightly during a melee sword attack — SEEN ONCE, never since (2026-08-27)

**User-reported, live.** While the peer swings the sword, the ghost rises a little.

**NOT REPRODUCED, and the user said so unprompted at the end of the same session:** *"i didn't
see/notice this later on, was just right when i mentioned it. never in any of the other tests or the
thing we tested now last."* Between that first sighting and the end of the day the ghost was watched
across roughly a dozen further runs — the damage A/Bs, the projectile work, the pit-fall captures —
with melee swings throughout, and it was never seen again.

**So the honest status is a single unreproduced sighting, not a live defect**, and it is left open
rather than deleted for two reasons. A one-off that nobody can reproduce is exactly what an
intermittent bug looks like early. And several things changed underneath it that same day —
`GHOST_BLOB_SHADOW_ARM_MIRROR` writes the ghost's spring arm every tick, `GHOST_PREHIT_PLAYER`
touches its hit list, and the collision experiments came and went — so it may well have been fixed
incidentally by one of them, which would be worth knowing.

**If it recurs, do NOT start from theory**: get the ghost's mesh Z and capsule half logged through a
melee montage first, the same measurement that settled the slide.

Not investigated. The specific thing to look at first: this adapter already has a fully worked
precedent for a ghost's Z going wrong during an animation — the slide, where the answer turned out
to be the engine's own CROUCH path moving the MESH by `-(capsuleHalf + 1)`, and where the first fix
was a render-Z bandage that has since been deleted (`BANDAGES.md` entry 1). A melee montage that
changes the capsule, or a mesh Z that is not being maintained while a montage plays, is the same
shape of problem and the same place to measure.

**Do NOT fix this with an offset.** That is precisely the bandage this adapter already removed
once, and the register records what it cost.

## [DONE] RESOLVED — "heal" IS healing; the table row is correctly labelled (2026-08-27)

Asked because `NS_Healing` bracketed every single charge across two runs, which fitted "the charge
has a body aura the game happens to have named NS_Healing" at least as well as it fitted "this is
the heal" — and in this game names have lied before (`AnimGraphNode_Trail` is cloth physics; Cling
Gem has no "glide" string anywhere).

**Answered by the user, who watched it**: the white particle effect appears *while healing*, not
only while charging. So the row is right and the mirror is correctly labelled. **The pairing in the
log was just what they happened to be doing** — heal, then charge — and reading a mechanism into it
would have been a wrong turn.

Worth keeping rather than deleting: the anomaly was real, the two readings needed opposite fixes,
and **the thing that settled it was a question a person could answer without naming an asset**.
That is cheaper than any probe and should be reached for first.

## [READY] Pending — the FRotator float/double fix is generalised, and the ghost transform path moved onto it

`write_struct_triple` + `write_vector_param` / `write_rotator_param` (`Plugin.cpp`) now carry the
version branch and inner-field resolution that the vendored SDK gets wrong for `FRotator`, and
**`call_set_actor_location_and_rotation` was migrated onto them in the same pass** rather than
leaving them unexercised. `BANDAGES.md`'s entry is updated.

**What to look at.** Nothing specific — that is the point. This is the call that puts every ghost
where it stands and points it where it faces, so **a ghost standing in the right place facing the
right way IS the confirmation**, in any session, without testing it on purpose. **What failure
looks like:** ghosts at the wrong position or spinning to a near-zero rotation — the original
denormal symptom — or a new `refusing to call it` warning in the log.

Behaviour-preserving by construction and it compiles, but neither is the standard this project
holds adapter changes to, so it sits here until a ghost is actually seen.

## [READY] Pending — ghost collision turned OFF again (2026-08-27), and it may cost the cling-gem VFX

`GHOST_COLLISION_ENABLED` is `false` again at the user's request, reversing the 2026-08-15
keep-it-on decision. No new evidence prompted it; the feature worked as described. Built and
deployed to the live Steam install the same hour, hash-matched.

**The flag is a real revert, not a decision-only gate** (`../../agent_docs/pitfalls/method.md`):
it turns `SetActorEnableCollision` to `false` and compiles out two `if constexpr` blocks
entirely — the `bCanBeDamaged` hurtbox disable and the Pawn-channel `Block` response. So the
melee-death hazard and the never-tested non-player-damage vector both stop existing while it is
off, rather than merely being unreachable.

**The risk this creates, and it is a real one.** The cling-gem (wall-ride) VFX is a *confirmed
working* ghost visual, and it was confirmed with collision ON. This file's own earlier reasoning
predicted that effect would be structurally blocked without collision, because `doWallRun`
depends on `wallRideHit`, a real geometry hit result a collisionless ghost cannot produce. That
prediction was then beaten — but by a `doWallRun` call made on a ghost that *had* collision. **So
nobody has watched the cling gem on a collisionless ghost, and it is the single most likely thing
to have just regressed.**

**What to look at.** A peer clinging to a wall. **What correct looks like:** the ghost still shows
the cling-gem sparkle, and it still stops when the peer leaves the wall. **What failure looks
like:** no sparkle at all on the ghost while the peer clings — which would mean the effect was
riding on collision the whole time and this is now a trade, not a free revert. Check
`WALLRUN_TRIGGER_TEST`'s `TRACE wallRide ghost` lines: `moveState entered 4, calling doWallRun`
still firing with no visible effect pins it on the precondition rather than the trigger.

Also worth a glance in the same session, for the same reason: the ledge-grab self-start behaviour,
which a 2026-08-15 run showed happens with collision off *too*, so it should be unchanged.

## [READY] Pending — the bridge port walk's SECOND-INSTANCE case is still unwatched (2026-08-27)

The walk itself now runs on every launch and is confirmed: autostart binds 7778 and connects
(`VERIFIED.md`, 2026-08-27), and the sweep's free-port test was rewritten from "did it refuse us" to
"can we bind it" after a measurement showed a closed loopback port on this machine is never refused
at all.

**What is still unwatched is the case the walk exists FOR:** a second game instance finding its own
core one port up while the first keeps 7778. Nothing this session ran two instances. Expect the
second to log `bridge connected on port 7779` with the first unaffected.

## [OPEN] Pending — a hard crash mid-session after the pause menu opened twice (2026-08-17)

**Not root-caused, and not attributable to MeshGhost on the evidence available.** Seen once. It is
here rather than in `VERIFIED.md` because nothing about it is established: not the trigger, not the
cause, and not whether this adapter is involved at all.

**What to look at.** A session with the pause menu opened and closed repeatedly, with a peer
connected. **What would settle it:** the same crash with the mod's `constexpr bool` flags off — and
per `../../agent_docs/pitfalls/method.md`, a flag flip only counts as a revert if it gates the
*work* rather than the decision the work feeds, so check the flag actually disables the cost before
believing an A/B. Bisecting real commits is the method that cannot be fooled here.

Recorded 2026-08-17 in `VERIFIED.md` as an observation, not a finding.

### ROOT-CAUSED for the 2026-08-27 recurrences — a projectile prop pointer, with a stack trace

The crashes during this session were **ours, and they are fixed**. The user captured the trace:

```text
UObject::ProcessEvent()
main.dll!call_destroy_actor()          Plugin.cpp:3928
main.dll!Plugin::release_ghost()       Plugin.cpp:6615
main.dll!Plugin::handle_bridge_line()
main.dll!Plugin::game_thread_tick()
```

The projectile mirror's first version spawned the game's own `PRJ_PlayerCutter_C` as a prop and held
the pointer. A thrown sword rests where it lands and nothing takes it away; **a projectile's
lifetime belongs to the game**, which destroys it on impact — so the release path asked a freed
actor to destroy itself. The mirror now holds only a Niagara component it created, and the user
confirmed *"no crash anymore"* on the same exit path that crashed twice.

**A liveness check does NOT close this class of bug**, and the comment directly above the crashing
line already said so: `IsUnreachable()` is only safe on an object that is still ALLOCATED. One was
added anyway before the redesign — a pointer that must not be held was treated as a pointer that
needs checking.

**The 2026-08-17 sighting predates all of this and is NOT explained by it.** It remains open, and
the probe-suspicion recorded against the earlier recurrence is withdrawn: the user ran menu
back/forth plus a quit on a probe-free build with no crash, and the crashes that did happen are now
attributed to the prop.

## [OPEN] Pending — a `Fatal Error!` on game exit, seen once, never root-caused

Distinct from the 2026-08-16 level-transition crash, which is fixed and confirmed. Seen once on
exit; no repro, no cause, no attribution.

**What to look at.** Whether it recurs at all on a normal quit. **What correct looks like:** the
game closes with no dialog. **If it recurs**, the UE4SS log from that run is the first thing to
read, before any theory — a mod framework's own error log is the cheapest evidence available and
this project has twice gone looking for a rendering bug that was a load failure.

### RECURRED 2026-08-27 — on exiting to the MAIN MENU, not on quitting

User: *"The UE-pseudoregalia Game has crashed and will close / Fatal error!"* — *"got this when i
exited out to the main menu"*. That is a level transition, which makes it adjacent to the
2026-08-16 transition crash (fixed and confirmed) rather than a straight repeat of the exit case
above; "exit" now covers two different actions and the entry should not be allowed to blur them.

**The log was read first, and it says almost nothing** (archived from that session). The last
adapter line is a ghost-spawn census at 18:59:08, then the ordinary bridge-stats line every ~0.7s
until it simply stops at 18:59:34. No warning, no unresolved name, no release path, no `LoadMap PRE`
line for the transition.

**Attribution is genuinely open, and this run is a bad witness.** Three probes were compiled ON
(`SHADOW_COMPONENT_PROBE`, `GHOST_PROJECTILE_WATCH`, `VFX_CATALOG_PROBE`), and the catalog probe
spawns Niagara components onto a ghost — a component whose owner is destroyed at a transition is
exactly the kind of thing that turns a teardown into a crash. But the same class of crash was seen
on 2026-08-17 with none of that on, so **the honest reading is "unattributed, and the next
occurrence must be on a probe-free build to be worth anything"**. Do not record a cause from this
one — `CLAUDE.md`'s rule about numbers gathered while a heavy probe was live applies to crashes as
much as to measurements.

## [OPEN] Pending — every probe under the three UE4SS mod directories predates this queue

`PROBES.md` indexes them (three directories, six scripts). They are the record of how each fact was
established, and several were run before this file existed — so the honest statement is that nothing
in this queue depends on them, and none of their logs is evidence for anything not already in
`VERIFIED.md`.

Kept as an entry so that the *next* probe run has somewhere to land before it is confirmed.

## [DONE] THE SCENE LATCH IS FIXED AND SHIPPED — moved to `VERIFIED.md` 2026-08-30; this section stays for the mechanism and the failed-fix table

**Final state**: all three light fixes are SHIPPED DEFAULTS (globals initialize true; the toggle
files are no longer read and were deleted from both installs). The full acceptance run — latch
gone, ghosts dark, blades clean, and a ghost crossing light-transition volumes disturbing nothing
with the overlap suppression OFF — is quoted in `VERIFIED.md`'s 2026-08-30 entry. What follows is
the mechanism and the night's negatives, kept because they are the record of HOW.

**What the latch actually was, measured down to refuting everything else first.** The glow
FOLLOWS the local player (user walked it: *"yes, even if client2 disconnect it still follows"*),
survives the peer leaving, and lives in NO reflected scalar — a clean latched-vs-baseline diff of
401 fields over the four transitions, the ambience actor, the manager (including its 32-slot
`IlluminatedComponents` count) and every vertex-light actor found ZERO differences. What remains:
the ghost's `BP_DynamicVertexLight_C` **registers with the light manager during `SpawnActor`**
(vocabulary: `Register`, and each light's `LightIndex` — player 0, ghost 1) and NOTHING
unregisters it; the stale registration (Intensity 0.5 / Radius 600, the exact values the destroyed
actor still holds) keeps being rendered at the player's own position, stacked on the player's dim
0.05. A registered-but-dead light is invisible to every actor-level read, which is why eleven
suspects and three whole-state diffs came back clean.

**The subtraction table, because five fixes failed before the one that worked:**

| Attempt | Result |
| --- | --- |
| Destroy ghost's light per-tick / in spawn tick | Ghost goes dark (bug 2 fixed); latch stays |
| Suppress via CDO `PlayerLight` template | NO-OP — `PlayerLight` is null on the CDO (2026-08-29's "latch fired through template suppression" was never a real test) |
| Suppress via `*_GEN_VARIABLE` archetype | NO-OP — no such archetype findable |
| MPC PlayerLocation guard / capsule overlap suppression / far spawn (+5000) | Latch stays through all three |
| Zero Intensity+Radius, push `InitializePrameters`, then destroy | Latch stays — the slot copies its values at Register time, inside `SpawnActor` |
| `FixDynamicLights` post-spawn / live on latched scene | NO visible change |
| **`FixAllLights` live on a latched scene** | **Glow vanished with the user watching, same second** |

**How it was found — the method, worth more than the fix**: when every scalar diff is clean,
stop diffing and dump the class's FUNCTION vocabulary (`LIGHTVOCAB`), then try the game's own
verbs one at a time on the live symptom via an edge-triggered toggle file whose CONTENT names the
function (`call_light_fn.txt`). The night's other permanent wins: `snapshot_scalar_properties`
now reads bitfield bools correctly through `FBoolProperty` (the old byte read printed ~30 manager
bools as uniformly true — the same wrong read suspected behind the two lying subtraction
toggles), and the user cloned the install (`Pseudoregalia - Copy`) so each instance has its OWN
`UE4SS.log`/toggles — simultaneous dumps from one shared log interleave line-by-line and
corrupted a whole sample before that.

**Resolved the same night (all four bullets that stood here):** the three fixes ARE the shipped
defaults (user: *"we should properly implement it"*); the parity question is answered — ghosts
never glow, like the blue outline — with the future mirror filed in `agent_docs/ideas.md`; and
the acceptance run ran with `guard_playerlocation` and `ghost_no_overlap` UNARMED: no latch, and
a ghost walking through light-transition volumes changed nothing, so neither is needed for
lighting and both stay dev-only.

**Still open:**

- The pickup cross-wire (below) is untouched by all of this.
- `FixAllLights` side effects outside `ZONE_Dungeon`'s dark rooms: unwatched (it runs on every
  ghost spawn, in every level).
- Every `<bool>` byte read OUTSIDE `snapshot_scalar_properties` (the `bVisible` sweeps above all)
  is still the bitfield-blind read — convert before trusting any of those subtractions again.

## [DONE] CAUSE FOUND 2026-08-29 (evening session) — BOTH light bugs are the ghost's `BP_DynamicVertexLight_C`, and this supersedes the whole section below it

**The two bugs the section below separates have ONE cause, watched live by the user through a
subtraction toggle.** This game's dark-area lighting is not lights at all: every pawn's
`PlayerLight` ChildActorComponent holds a **`BP_DynamicVertexLight_C`** — retro vertex lighting
that paints brightness into level geometry, invisible to every light/material/post-process census
(which is why eleven suspects died clean). The ghost constructs from the LOCAL save, which owns
the ascendant-light upgrade, so it is born with the whole kit ON. `GHOST_HOLD_LIGHT_OFF` held the
pawn's `PointLightComponent` at 0 the entire time — the wrong object.

- **Bug 2 (glow travels with the ghost): CONFIRMED FIXED on screen** — destroying each ghost's
  vertex-light child actor (`hide_ghost_playerlight.txt`) turned every ghost dark the moment it
  fired, both instances, user watching. Still toggle-gated, not shipped default.
- **Bug 1 (per-client scene latch on connect): the same actor, but destruction is TOO LATE by
  construction.** Measured escalation: per-tick sweep → latch fires; destroy in the SAME TICK as
  `SpawnActor` → latch still fires. The child actor's BeginPlay runs INSIDE `SpawnActor` and the
  scene keeps whatever it did. Current build (deployed, UNWATCHED) nulls the class template's
  `ChildActorClass` around our one `SpawnActor` call and restores it after, so the light actor is
  never created for a ghost. **The next connect-in-darkness run answers it.**
- **The blade shimmer is a THIRD component: `LightMesh`** (`StaticMeshComponent`, `M_SpiritAura`,
  gold 0.88/0.81/0.27) — the ascendant-light blade aura, named by the user's speedrunner contact,
  stuck visible on ghosts for the same born-from-local-save reason. **CONFIRMED gone on screen**
  with `hide_ghost_lightmesh.txt`. Also toggle-gated, not shipped.
- **OPEN — parity gap, user's call pending:** with the kill and the hide armed, a ghost can NEVER
  glow, including a peer who legitimately has the light (item, or post-pickup temp light — the
  user watched exactly that go missing). The proper fix is syncing the peer's actual light state,
  the observation-mirror shape the recall glow uses.
- **OPEN — the pickup CROSS-WIRE: a peer picking up their thrown sword drives the LOCAL player's
  pickup animation (and, pre-kill, the temp light) on the other machine.** Watched FOUR rounds:
  `changeEquippedWeapon` skipped, `updateWeaponEquip` skipped, and BOTH skipped — the cross-wire
  survived every combination, so **neither adapter call is the carrier**. Next suspect: the
  thrown-weapon PROP (a real `BP_looseWeapon_C`) being destroyed on the pickup edge — its own
  destruction/pickup logic reaching "the player". Untested. **Regression while split-testing:
  with EITHER call skipped the ghost's sword no longer leaves its hand on a throw** — the pair is
  load-bearing together (2026-08-15 confirmed them working as a pair); both restored.
- **THE LATCH'S REAL MECHANISM (measured down to the actor, 2026-08-29 late):** destruction at
  any speed failed (per-tick, same-tick, and template-suppressing the vertex light entirely — the
  latch fired through all three), and the MPC theory died the same way: `probe_namecensus` stage
  10 measured the live `MPC_PlayerRelated.PlayerLocation` holding the GHOST's position on both
  instances, a real theft — but a native pre-hook redirecting every write to the local player's
  position (`guard_playerlocation.txt`, watched rewriting 100+ times) did not stop the latch
  either. What is left, and what the stage-12/13 census supports: the level's lighting is run by
  **`BP_LightManager_C`** (an `IlluminatedComponents` map) fed by **`BP_LightTransition_C`
  trigger volumes**, and a pawn fires BeginOverlap for the volume it SPAWNS inside — the ghost
  spawns in the lit zone and transitions the whole scene. **Fix built and deployed, UNWATCHED:**
  `ghost_no_overlap.txt` flips the capsule template's `bGenerateOverlapEvents` off around our
  `SpawnActor` (the same CDO trick as the vertex light, because spawn-time overlaps fire inside
  `SpawnActor`). If confirmed, ghosts also stop firing encounters/hazards/save-point triggers —
  the same singleplayer assumption, everywhere.
- **The MPC PlayerLocation THEFT is real regardless of the latch** — the guard stays armed; what
  visual it owns (if any, now that the vertex light is dead) is unmeasured.
- **OPEN, new observation while testing: the ghost's thrown sword was never seen in the AIR** —
  it appeared only on the ground (glowing there, which matches the real one). May predate today.
- **Method note for the next subtraction that "matches 0":** the nametag toggle armed from BOOT
  works by never CREATING the tags (the updater is skipped), which is how it was finally
  eliminated by absence — while the same toggle flipped mid-session still matches 0 components,
  and the blob-shadow sweep matched 0 of 879 while `LightMesh` (name-containing, visible) sat in
  that class list. The `bVisible` byte read in those sweeps is the suspect. Two subtraction
  toggles still lie; do not trust either until this is fixed.

The census that found all of this is `probe_namecensus/` (deployed as `MeshGhostNameCensus`), and
the reloader can re-run it any time — it prints world inventories by class, `MPC_PlayerRelated`
(one parameter: `PlayerLocation`), per-mesh materials/flags, and the `PlayerLight`/`LightMesh`
pair. `PROBES.md` has the entry.

### This plan ran on 2026-08-30 and is DONE — kept only so its predictions can be checked against what happened

Step 1's latch test FAILED (overlap suppression was not the answer; the registration was), step
2's map read went through the count only (32 slots, unchanged latched-vs-clean — the values were
never needed once the vocabulary dump named `FixAllLights`), step 4's promotion and parity
question are both resolved (shipped defaults; ghosts never glow, mirror filed in `ideas.md`).
**Step 3 — the pickup cross-wire — is the one that remains open.** The toggle files named above
were deleted from both installs; three are no longer even read.

## [DONE] SUPERSEDED by the section above — kept for its measurements (2026-08-29, long session)

**Read the section above before touching the ghost-light problem again.** The entries further down
were written while the cause was still believed to be the ghost's `PointLight`; that belief is now
refuted, and each is kept only for the measurements it records.

### There are TWO bugs wearing the same clothes, and separating them is the session's main result

The user's own words, and the thing that finally made the reports consistent:

1. **A per-client SCENE LATCH.** When a peer's ghost spawns, the local client's whole scene flips
   to a lit state -- *"it got bright around client1 even before i could walk over there"*, from
   across the level. It **survives the peer leaving** and clears only when the player walks out of
   the dark area and back in. Solo play never shows it. The user's constraint: this **predates
   nametags entirely**.
2. **A glow that belongs to each GHOST.** With the local scene repaired by an area transition, each
   ghost is still lit and still lights the wall around it. It **travels with the ghost and dies
   with it** -- *"whenever a ghost disconnect, their glow goes away"* -- so nothing is left behind
   in the world.

Every earlier run confused these, because a subtraction judged while the scene was latched cannot
say anything about the ghost. **The clean setup is: both clients walk out of the dark area and back
in first.** Only then is a ghost-side subtraction worth anything.

### Ruled out by measurement, not by argument

| Suspect | How it was killed |
| --- | --- |
| The ghost's `PointLight` | Held at 0 within **4ms** of spawn (log-timed). `SetIntensity` resolved -- no warning ever printed. Forcing it back to 5000 changed nothing on screen. |
| The game re-lighting it | A per-tick hold with a re-light counter: **never once incremented**. |
| The ghost's model | Hidden entirely, in the clean setup. Walls still lit. |
| Materials / lighting flags | Player and ghost carry the same assets and parents (`MI_n64_Playergoat`, `MI_n64_PlayergoatFace`), same lighting channels, same shadow flags. |
| Material parameters | The only ones the game drives are `DieAmount` and `UVOffset`. |
| `bRenderCustomDepth` (the shading pass) | The single field that DID differ. Subtracted live via a toggle; no visible change. |
| Any other light in the level | A census of `LightComponent` **and every subclass** finds exactly two lights in the map: the two players'. The ghost's reads 0. |
| Camera post-process blend | Every rig not serving the local pawn zeroed, confirmed by log. Still glows. |
| Scalars on the local pawn | Diffed across the spawn: **two uptime timers**, nothing else. |
| Scalars on the shared GameInstance | Diffed across the spawn: **zero fields changed**. |
| The level's own post-process | Diffed across the spawn, struct interior included: **zero fields changed**. |

### NOT eliminated -- and two of them were REPORTED as eliminated when they were not

**This is the part to distrust in the older entries.** Two subtractions logged success and did
nothing, because they attributed components to a ghost by `GetOuterPrivate()`:

- **The nametag** -- reported `0 component(s) of 12` once a count was finally printed, while the
  user watched the tag stay on screen. An earlier version *also* had the nametag updater put the
  components straight back every tick.
- **The ghost's Niagara systems** -- same broken owner test, and that branch printed **no count at
  all**, so "particles are off" was said on the strength of a toggle flag and never measured.
- **The blob shadow** -- same, never actually switched.

`TextRenderComponent` and `NiagaraComponent` do **not** outer to the pawn the way the
property-held meshes do. **Name containment is the attribution that works here**, which is what
`GHOST_HOLD_OUTLINE_OFF` has used since it was written. The build committed at the end of the
session uses it and prints `N of M switched` for every subtraction.

**So the three live suspects are the nametag, the blob shadow and the ghost's particle systems**,
in that order -- the nametag being the brightest thing on a ghost, and the user's own early guess.
Note it cannot explain bug 1, which predates nametags; expect two causes, not one.

### The rig, and how to reproduce in one run

Relay + two instances; the mod starts its own core per instance (the port walk **did** work here --
6672 and 6673, unaided, which contradicts the "NO free port" entry further down). Then:

1. Client 1 into the dark area, client 2 connects and loads in -> bug 1 fires.
2. **Both** clients walk out of the dark and back in -> scene repaired, only bug 2 left.
3. Flip one toggle at a time and read the `N of M switched` line before believing anything.

### Dev toggles that MUST come out before this ships

`GHOST_CUSTOM_DEPTH_DEV_TOGGLE` and `PLAYER_STATE_DIFF_ON_GHOST_SPAWN` are both `true` in the
committed build. They gate `keep_custom_depth.txt`, `ghost_light_on.txt`, `hide_ghost_mesh.txt`,
`hide_ghost_shadow.txt`, `hide_ghost_nametag.txt` and `hide_ghost_fx.txt`, all read from beside the
DLL, plus a property diff on every ghost spawn. Harmless to a player (the files never exist) but
they are instruments, and `../../CLAUDE.md` says instruments ship off.

## [DONE] ONE ghost cosmetic the user saw wrong on screen (2026-08-28) — the LIGHT half only

> **The DUST half of this entry is DONE and user-confirmed (2026-08-29)** — four stacked defects,
> all fixed and watched on screen. It has moved to `VERIFIED.md`, "Landing dust on a ghost".
> Only the light half below is still open.

**These run the opposite way to everything else in this file.** The rest is "the agent believes it
works, the user has not looked yet". These two the user HAS looked at, and they are wrong. They are
here because they are open work with nothing measured yet, and nothing below is established.

**1. Landing dust fires on the wrong character's landing.** SHARPENED BY THE USER 2026-08-29, and
it changes the question: the dust fires *"whenever you land after jumping"*, the ghost *"doesn't
handle it on its own"*, so it *"just happens whenever the player does it, and gets replicated onto
the ghost at wrong times"*. First noticed on a TWO-INSTANCE session.

**So this is not a missing effect — it is an effect fired by the wrong character's landing**, and
the earlier framing here (never spawns it / spawns it invisibly / something strips it) was aimed at
the wrong three possibilities. The shipped `dl` row mirrors `NS_DustLand` as part of the `vfx`
STATE set, attributed to the SENDER by proximity; a one-shot burst delivered as resent state can
only fire when the receiver next reads it, which is not when the ghost is drawn landing (`interp`
is 250ms). Whether that alone accounts for it is the measurement, not the conclusion.

This is the shape `../CLAUDE.md` names outright — *reproduce the WHOLE effect, the animation and its
extras*. A jump is not just a pose, and Emerald's surf blob is the worked precedent: the state
looked done because the animation played, and the thing riders sit ON was a separate sprite nobody
had counted. So the first move is the one that file prescribes: **do the jump in the real game and
count what appears**, rather than reading the ghost's spawn path and reasoning about it.
`../../agent_docs/effect-investigation.md` is the method.

**2. Light / "ascendant light" level is being COPIED onto the ghost, and never should be.** User:
these *"should always be off for a ghost similar to the blue outline things"*.

Located further by the user 2026-08-29: it *"emits from the player itself, or maybe from the
ascendant light upgrade"*, and *"makes the game look a bit too bright when nearby other
ghosts/players"* — so the visible symptom is ADDITIVE. Each ghost carries its own copy of the
emitter and they sum, which means the brightness scales with how many peers are in the room and a
one-peer session understates it.

So this is not a value to mirror more accurately — it is a value to force off, in the same class as
the blue outline, and the outline's own history says how. `GHOST_HOLD_OUTLINE_OFF` in `Plugin.cpp`
is a per-tick **HOLD**, not a spawn-time write, and the comment there records why: the outline was
already disabled at spawn on `VisualMesh` and `WeaponMesh`, and the user still saw blue outlines
mid-attack, because the game re-enabled it. That was the **third** time in one session a spawn-time
write turned out to be the bug, after the blob shadow and the collision disable.

**So whatever writes this must be a hold too**, unless it is measured to be written exactly once —
and "the ghost looked right in one run" is not that measurement. Expect the same trap: set it at
spawn, watch it come back the moment the game touches the level again.

**Neither is diagnosed and neither has a fix.** No probe has been run for either, so there is no
number here to be wrong about later — which is the only good thing about the state of this entry.

**A probe now exists for both and has not yet been run** (2026-08-29): `probe_dustlight/`, indexed
in `PROBES.md`. It answers the light half by census — every light component and child actor on the
player and on each ghost, walked up BOTH the outer and the attach chain — and the dust half by
timeline, putting every Niagara/Cascade component's first appearance on one clock with every
character's `MovementMode` transition. The run is built around the user's own report: one instance
jumps, the other stands still, and a dust burst logged on the still instance is the defect caught
next to the landing that did not happen. Nothing here is measured until that log exists.

## [DONE] MEASURED 2026-08-29 — the ghost's PointLight is at 5000 while the player's is at 0

**This is an agent measurement, so it lives here and not in `VERIFIED.md`.** It was read out of a
live two-instance session in `ZONE_Dungeon` by `probe_dustlight/`, one census line per character:

```
PointLightComponent ... BP_PlayerGoatMain_C_2147482274.PointLight owner=PLAYER
  Intensity=0.0     AttenuationRadius=1000.0 bAffectsWorld=true bVisible=false bIsActive=false
  attach=SkeletalMeshComponent ....WeaponMesh
PointLightComponent ... BP_PlayerGoatMain_C_2147482218.PointLight owner=GHOST1
  Intensity=5000.0  AttenuationRadius=1000.0 bAffectsWorld=true bVisible=false bIsActive=false
  attach=SkeletalMeshComponent ....WeaponMesh
```

**Same class, same component name, same attach point — the local player's is 0 and the ghost's is
5000.** The component is a `PointLight` child actor hanging off `WeaponMesh`, not off the capsule
or the body, which fits Ascendant Light being a property of the weapon.

**This reframes the entry above it.** The value is not being *copied from the player* — if it were,
the ghost would read 0 too, because that is what the player reads. It is the Blueprint's own
DEFAULT, which the ghost is born holding and which nothing ever turns down, while the real player's
gets driven to 0 by the game's own logic. A ghost is spawned from the player's pawn class and then
never runs that logic. **So the fix is not to stop copying something; it is to write the light down
on a ghost that was born bright.**

**One trap visible in the same two lines**, and it is why this is not yet a fix: BOTH report
`bVisible=false` and `bIsActive=false`, including the one that is demonstrably lighting the room.
So neither flag is what makes this light visible, and an implementation that toggles either of them
will read as correct in a log while changing nothing on screen. `Intensity` is the only field that
separates the two characters, and the `ChildActor` beneath it was never inspected — the run died
before reaching the `ChildActorComponent` census.

**Also unmeasured: whether it must be a per-tick HOLD.** The entry above predicts one, by analogy
with `GHOST_HOLD_OUTLINE_OFF`. Nothing here tested it. Write it once, then watch whether the game
puts it back the next time it touches the weapon.

## [READY] BUILT 2026-08-29, NEVER WATCHED — the ghost's light is now held at 0

`GHOST_HOLD_LIGHT_OFF` in `Plugin.cpp`, built straight off the measurement above and deployed to
the Steam install. **Nothing about it has been seen on screen.**

**What it does.** Every `LIGHT_SWEEP_INTERVAL_TICKS` (30, ~5Hz) it takes every
`PointLightComponent` and `SpotLightComponent`, skips any already at `Intensity == 0` without an
engine call, attributes the rest to a character by walking **`AttachParent` upward** as well as
testing the component's own name, and calls the engine's `SetIntensity(0)` on the ones belonging to
one of our ghosts. A HOLD, not a spawn-time write, by analogy with `GHOST_HOLD_OUTLINE_OFF`.

**Three things it deliberately does NOT do**, each from a fact in the entries above:

- It never touches `bVisible` or `bIsActive`. Both characters' lights report both flags false,
  including the one lighting the room, so either toggle would read correct in a log and change
  nothing on screen.
- It never calls a UFunction on a component it has not attributed to a ghost. `FindAllOf` hands
  back class-default and half-torn-down objects, and calling into one is what crashed the session
  twice.
- It does not write `Intensity` directly. Brightness is render-thread state; the engine's own setter
  is what marks the render state dirty.

**What to watch for, and it is not a screenshot of one ghost.** The reported symptom is ADDITIVE —
the room gets too bright *near other ghosts* — so the check is a session with at least two peers
present, comparing how lit the room is against a solo run. A single ghost may never have looked
obviously wrong.

**FIRED on both ghosts, 2026-08-29, agent-measured.** A two-instance session on the user's own
machine (relay + a second core on bridge 6673, both instances in `ZONE_Dungeon`, p1 and p2 seeing
each other) logged it once per ghost:

```
ghost light: 'PointLightComponent ....BP_PlayerGoatMain_C_2147482039.PointLight' was at intensity 5000 -- holding it at 0.
ghost light: 'PointLightComponent ....BP_PlayerGoatMain_C_2147482082.PointLight' was at intensity 5000 -- holding it at 0.
```

So the attach-chain attribution reaches the component, the value it found is exactly the 5000 the
census measured, and neither the local player's light nor the level's was touched. **That is the
mechanism working, not the cosmetic fixed** — nobody has looked at the screen, and the additive
symptom is what the user has to judge.

**The user looked and could NOT tell, 2026-08-29** — *"unsure, its pretty hard to visually tell
where im at right now. i can go to another darker area later and test"*. So this is neither
confirmed nor refuted, and the reason is the test conditions, not the fix: the area the session
happened to be in was lit enough to swallow the difference. **The judgement is deferred to a dark
area, and until it happens this stays here.**

**A straight A/B is not available while the hold runs**, which is worth knowing before anyone tries
to build one. Anything that writes 5000 back for comparison is fighting a per-tick sweep that
re-zeroes it, so the two would just race. The honest A/B is two runs of the DLL — one built with
`GHOST_HOLD_LIGHT_OFF` false — and it costs a relaunch, so ask before assuming the dark-area look
alone is inconclusive.

**The readback is NOT done.** The hold announces once per component and is silent after, so a
light the game re-lights every frame and the hold re-darkens looks identical in the log to one
fixed on the first sweep. `probe_lightcheck/` exists for exactly that and is deployed — but
`RestartMod` cannot introduce a mod UE4SS did not load at launch (*"Could not find mod to
reinstall"*, measured the same day), so it arms itself on the NEXT game start.

**The log line is the other half.** On the first sweep that finds a lit ghost light it prints
`ghost light: '<full name>' was at intensity 5000 -- holding it at 0`, once per component. If that
line never appears, the sweep is not reaching the component and the attach-chain attribution is
where to look; if it appears repeatedly for the same component across a session, the game IS putting
the light back and the hold is doing the work the entry above predicted it might have to.

## [OPEN] THE PROBE CRASHED THE GAME TWICE — `probe_dustlight/` is DISABLED and must not be re-run as-is

**Both crashes were caused by the agent, during the user's session.** `Fatal error!`,
`EXCEPTION_ACCESS_VIOLATION` reading `0x20`, with a callstack ~15 frames deep inside UE4SS's own
Lua/reflection machinery and no game or `MeshGhostPseudo` frame in it.

**The subtraction is what makes it attribution rather than suspicion**, and it is three runs:

| Run | Probe loaded | Result |
| --- | --- | --- |
| 1 — start a new game | yes | crash at LoadMap |
| 2 — same, control | **no** | clean, played fine |
| 3 — hot-reloaded mid-session | yes (hardened) | crash within a second of the census |

**Run 3 localises it precisely.** The census prints one summary line per class in `LIGHT_CLASSES`,
and the log ends on the `LightComponent` summary having never printed a `ChildActorComponent` line
or any `LIGHTPROP` line. The next thing it would have done is walk every `ChildActorComponent` in
the world — reading `ChildActor`/`ChildActorClass` and calling `K2_GetComponentLocation` on each.
**That pass is the suspect, and `ChildActorComponent` should come out of the class list before this
probe is ever loaded again.**

**A guess that failed, recorded so it is not retried.** Between runs 1 and 3 the probe gained a
`usable()` guard that skips class-default objects and revalidates `IsValid`. It did not help. That
is one hardening attempt spent; `../../CLAUDE.md`'s rule applies — the next move is subtraction
(cut the class list down to the two rows that actually answered the question) and not a third guess
at what to guard.

**What the probe must give up to run again**: it went after two questions and a whole-world
enumeration at once, and it only ever needed the pawn's own components. The light answer above came
from two lines of its output. A version that enumerates a CHARACTER's components rather than the
WORLD's would have produced the same answer without ever touching an object it does not own.

## [OPEN] WATCHED LIVE 2026-08-29 and it FAILED — a second instance never starts its own core

**This is the first live look at Pseudoregalia's bridge port walk** (`status.md` had it as "built
but not yet watched"). Two instances of the game, one install, the shipped `config.json`
(`local_game_bridge` 127.0.0.1:6672). **Instance 2 never got a core**, and a human would have
called that "the second window just doesn't work".

The sequence, from `UE4SS.log`, all of it instance 2:

1. `14:09:08` — `using a MeshGhost core that was already running`, then
   `core on port 6672 cannot reach the relay (...) -- waiting on this core rather than walking; it
   retries by itself`. **Correct by design**: a core that cannot reach the relay is not a busy core.
2. `14:10:39` — the relay came up, instance 1's adapter attached first, and 6672 answered
   `busy: this core already has a game attached` — so instance 2 walked, as designed.
3. `14:10:40` onward, once a second, forever:
   `bridge not connected and the sweep found NO free port to start a core on -- every port in the
   range either answered or never refused. Autostart is idle, not broken-silently.`

**Ports 6673–6679 were free the whole time.** Nothing was listening on any of them; the second core
that eventually made the session work was started BY HAND on 6673 and bound it without complaint.

**So `spawnable_port()` said no while a free port sat one number up**, and the branch that prints
this is the one `Plugin.cpp` already calls out as having cost a session once. The 2026-08-27 fix
replaced "did the connect get refused" with "can we BIND it" for exactly this reason, and the
symptom is back in a different shape.

**Not diagnosed — and one structural detail is worth having before anyone guesses.** `BridgeClient`'s
sweep computes `have_spawnable_port` inside the same loop that connects, and **returns the moment
`try_port` succeeds**, so any sweep that finds a core leaves the spawnable answer false. That alone
does not explain step 3, where the busy port is skipped by its cooldown and the loop should reach
6673 — which is why this is written as a symptom, not a cause.

**The next measurement, and it is one line of logging, not a theory**: print per candidate port what
the sweep decided — index, port, `try_port` result, `refused`, `port_is_bindable`. Two instances
reproduce it in under a minute, so this is cheap. Do that before changing anything.

## [READY] Pending — `bb`, `hw` and `hew` got the one-shot counter treatment and were never watched (2026-08-29)

The dust fix moved every `world_spawned` row in `MIRRORED_EFFECTS` from presence-mirroring to a
counter, because they are all one-shot bursts and all lost repeats the same way. **Only `dl` was
watched on screen.** The other three changed behaviour in the same build and nobody has looked:

| Row | Effect | What to watch |
| --- | --- | --- |
| `bb` | `NS_BasicBurst`, the death burst | A peer dying twice in quick succession should burst twice. Note this row's standing risk: the record has it firing ~14x in ordinary combat, so proximity attribution can occasionally put somebody else's hit on a ghost. |
| `hw` | `NS_HealWave` | A peer healing twice in a row. Height is observed from the local player's own heal, so a watcher who has never healed uses the row's fallback (+100). |
| `hew` | `NS_HealEndwave` | Same, fallback +10. |

**What correct looks like:** each repeat produces its own burst, at the same height as before the
change, with no burst appearing on a ghost whose peer did nothing. **What a regression looks like:**
the echo returning on any of these — they share the exclusion set with `dl`, so a fault there would
show on all four.

**Also unwatched: the first-of-session baseline for these three.** Counters are now sent always, so
the first heal/death after joining should fire like any other. That was a real bug for `dl` and is
fixed by the same mechanism, but only `dl` was confirmed.

## [OPEN] LOGGED, NOT BEING FIXED — a ghost may be stiffer than the game's own model ("model wiggle", 2026-08-29)

**The user's own framing, and the reason this is filed as a question rather than a defect:** *"ik
we are doing all animations & vfx, but unsure if a model 'draggin itself out/wiggling a bit'
visually is due to low hz/interp. or actually something we are not syncing. not really visually
noticable as its minor but we might have a more 'static/stiff' model than what the game itself
does"* — and explicitly: *"this is not an issue i currently plan to fix if it is a thing, but just
something i want to log."*

**So the open question is not "how do we fix the wiggle" but "is there one".** Two candidate
readings, and nothing here distinguishes them:

1. **A sampling artifact.** The ghost is drawn from interpolated samples at the send rate, so any
   secondary motion the game produces per-frame is being resampled. That would make the ghost look
   *smoother or stiffer* than the player without anything being unsynced — the renderer's, not the
   adapter's.
2. **Something genuinely not mirrored.** This game's characters carry stock bone-physics dangle
   (`documentation.md` records `AnimGraphNode_Trail` as exactly that — cloth-style secondary motion,
   NOT the afterimage trail). Secondary physics is usually simulated locally per-actor and would
   need the ghost's own simulation running, not a synced value. If it is disabled or never ticks on
   a ghost, the ghost would be stiff while the player is not.

**Reading 2 is the one with a concrete first check**, and it is cheap: compare the player's and a
ghost's bone-physics/anim-dynamics components side by side — do they exist on the ghost, and are
they simulating? That is a census of two actors, which is precisely the scoped-enumeration shape
`probe_dustlight/` should have used and did not.

**Do not chase this by eye.** The user calls it *"not really visually noticable"* and *"minor"*,
which is the regime where a watcher confirms whatever they expect. If it is ever picked up, get the
two models' bone transforms logged over the same motion before forming a theory.

**Deliberately NOT scheduled.** Recorded so it is not rediscovered from scratch, and so that if a
future stiffness report arrives there is a dated note saying it was noticed on 2026-08-29 and left
alone on purpose.

## [READY] Pending — the WALL-KICK mirror v1: watched once, hedged, with two stated limits (2026-09-01)

**What shipped.** A ghost's wall kick now plays both measured systems (six-kick capture via the
`probe_slashvfx` shape, logged in `UE4SS.log` 18:42): `wk` = `NS_WallKickHit`, the impact burst,
world-spawned one-shot on the counter path with observed-height learning (fallback 0 -- the
capture's 0..-72 offsets were measured against a player position logged up to one sample LATE, so
the true at-kick offset is near zero); `ks` = `NS_KickStab`, the flourish, attached to the ghost's
`VisualMesh` at the measured constant rel (10, 100, 85) -- the first attached row with an offset
(`MirroredEffect::attach_offset_*`).

**The user's one look:** *"think wall kicks look good enought now, hard to tell if anything is
wrong"* -- a hedged positive, kept here rather than promoted until it holds through normal play.

**Two limits stated at build time, not discovered later:**
- **`wk` spawns centred on the ghost, not pushed to the wall face** (~40-100 units sideways in
  the capture). Unlike the heal waves that offset IS knowable -- a world-frame delta the sender
  could ship in extras beside the counter -- so if the placement ever reads wrong on screen,
  that wire-carried offset is the upgrade. Do not guess it from the performer's yaw.
- **`ks` is a presence row, so two kicks in one active window re-burst once** on the ghost
  instead of twice -- the same shape the dust had before counters. Promote it to a counter only
  if that is ever seen to matter.

**Also unwatched:** both rows' first-of-session baseline behaviour, and `wk` on a watcher who has
never wall-kicked (fallback height, no learned value).

## [OPEN] OPEN — the thrown sword still SNAPS occasionally mid-arc, cause unattributed (2026-09-01)

Survived every change made tonight, which is what makes it worth its own entry: seen at the old
EMA renderer, at the segment glide, and AFTER `WEAPON_SNAP_DISTANCE` was raised 400 -> 1500 (so
that constant is exonerated as the cause -- it was ALSO wrong, first session to enforce it, but
fixing it did not remove the symptom). Final user state: *"now it just snap/teleport a bit"*,
accepted as good enough for now on the ocean-profile link (5% loss).

Next suspects, in order, none measured: (1) a loss hole longer than the segment's 400ms duration
clamp makes the glide sprint the whole hole's distance in 400ms -- reads as a lurch/snap; (2) the
`weapon_thrown` flag flickering across a suppressed/lost sample re-primes the renderer (a re-prime
IS a deliberate snap); (3) a genuine target jump. A one-line log at the snap site (gap length,
distance, primed state) settles all three in one throw session; measure before theorising.

## [OPEN] FILED — a smooth ghost tumble needs SENDER-side spin data; receiver-side guessing is exhausted (2026-09-01)

Three rotation renderers were watched in one evening (full verdicts: `VERIFIED.md`, the
2026-09-01 evening entry; mechanism comments at the render site in `Plugin.cpp`). The conclusion
is information-theoretic, not a tuning matter: at 15-20Hz a fast tumble turns more than 180
degrees between arrivals, so its direction and turn count are simply not in the data -- shortest
-arc under-rotates and sometimes reverses, unwrapping runs away. If 1:1 spin is ever wanted, the
SENDER must ship the spin (rate or phase) in extras, where it knows it exactly. Until then
write-through is the settled state and matches the game's own deliberately steppy spin.

## [READY] Pending — every peer-named asset now resolves through the CATALOG GATE, built and unwatched (2026-09-01)

**What changed.** The 2026-08-27 ACE audit's "a peer can NAME a thing" gap is closed, and it had
grown since the audit: five resolve sites, not one -- `target_montage` (play + divergence-restore),
`target_outfit_mesh`, `target_weapon_glow`, `target_projectile_vfx` -- each fed a peer string
straight to `StaticFindObject`. All five now go through `resolve_peer_named_asset` (`Plugin.cpp`):
the peer's string is a key into a set of the LOCAL game's own loaded assets of the right class
(class-scoped `FindAllOf`, rebuilt at most once per 10s and only on a miss), and on a hit the
global lookup runs on the catalog's own copy of the string. A miss is a refusal. Closes both
residual risks: a peer naming loaded-but-wrong assets of the right class is unchanged (parity --
same class, same game), but the garbage-name-spam perf lever (one global object lookup per
message) is now one hash lookup, and nothing peer-controlled reaches `StaticFindObject` at all.

**Why not an allowlist:** the montage mirror is deliberately generic (the sender ships whatever
montage is playing -- capability parity), and a hand list breaks the next montage nobody thought
of. The catalog IS the game's own list, mods included, maintained by the game.

**What to watch, one session:** montage mirror (throw a sword, ledge-hang), outfit swap, landed
sword glow, the ranged shot -- all four must look exactly as before; any of them missing is the
gate over-refusing and the log will say which name missed. **Known edge, stated up front:** an
asset first LOADED mid-session resolves up to ~10s later than before (the miss-triggered refresh
is rate-limited); outfits retry and self-heal, but a montage played within seconds of its first
load this level could skip once. If that is ever seen, the fix is a cheap targeted refresh on the
montage path, not a loosening of the gate.

**Mod compatibility, asked by the user and answered from the code:** unchanged. The old path had
no LoadAsset fallback -- `StaticFindObject` also only ever found loaded objects -- so "same outfit
mod on both machines" worked before and works now (the catalog is YOUR game, mods included), and
"a mod only the peer has" never worked on your screen either way; the refusal is just explicit now.

## [READY] Pending — three input bounds from the 2026-09-02 adversarial review, built and deployed, unwatched

`Plugin.cpp`, three changes, all of the shape "a peer's field reaches the game unchecked" (ADR
0044, `docs/security.md`). Built with `build-pseudoregalia.bat` and deployed to both installs
2026-09-02; nothing has been watched since.

- **`afterimage_n` is clamped to 1..64, else 6.** A peer's value was written straight into the
  pawn's `afterImagesToSpawn`; only `<= 0` was corrected. What to watch: a slide still spawns the
  same afterimage burst as before (the sender's real count is 6 on every build seen, well inside
  the bound), and nothing about the trail looks different.
- **A non-finite `orientation` is zeroed** on the raw (non-bracket) path. Only reachable from a
  peer sending `1e999`; a normal session cannot tell the difference. Nothing to watch beyond
  "ghosts still turn".
- **Nametags are capped at 1024 remembered peers**, evicting names with no live ghost when full.
  A normal session never reaches it. Nothing to watch beyond "names still show".

Regression on the Go side (`core/roster_cap_test.go`) bounds how many ids a relay can announce at
512, so the "unbounded pawn clones" finding is closed above this mod rather than in it.

## [OPEN] Four items that need a real two-machine session, carried out of `status.md` (opened 2026-08-16/17, moved 2026-09-02)

Two real players on two machines were confirmed on 2026-08-16 (`../../agent_docs/verified.md`), and these
four were written down that week as needing re-judging once a peer's state genuinely differs from the
local player's — which loopback can never show. None has been looked at since; each keeps its original
pointer.

- **Ghost collision: answered as a setting, not a yes/no.** ADR 2026-08-19 in `architecture.md`
  makes it a host-set room policy with a one-way client override; decided, not implemented.
- **Killing a ghost leaves the player respawning at 0/empty health** — player melee only; the HUD
  is fine, the value isn't. Suspect shared health state. `verified.md` 2026-08-17.
- **Ghost vanishes while a peer is on a pole**, then returns stuck in a climb pose. Cause unknown,
  two suspects ruled out; `phase7.md`. (Pole *rotation* was the separate item, cleared 2026-08-16.)
- **A thrown sword near a save crystal.** Suspected a loopback-offset artifact rather than a real
  bug; a two-machine session settles it. `verified.md`.
