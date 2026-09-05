# Unverified — TEVI's queue waiting on the user

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

**Created 2026-08-27.** TEVI had no queue, and three files said that was fine because "an adapter
with nothing pending does not need an empty one" — while `../../agent_docs/status.md` was carrying
TEVI items nobody had watched. The premise was wrong, not the rule: the user's call is that **every
adapter carries this file**, and `preflight.ps1` now requires it. The entries below were moved here
from `status.md` and `ideas.md` rather than invented.

**This queue drains.** Confirmed items move to `VERIFIED.md` with the date and are deleted here;
declined ones go back to being work. An entry still here has not been confirmed. Sibling queues:
`../emulator/pokemon/crystal/UNVERIFIED.md`, `../emulator/pokemon/emerald/UNVERIFIED.md`,
`../pseudoregalia/UNVERIFIED.md`.

---

## This run — watch these first

**The READY entries below, newest first, at most ten.** Each says what to look at and what correct looks
like; answer each with a plain yes or no at the end of the run. Every entry in this file carries
**READY** (built, waits for your eyes), **OPEN** (not fixed, parked as work) or **DONE** (kept for its
mechanism; nothing to confirm) — the rule is [`../_template/UNVERIFIED.md`](../_template/UNVERIFIED.md), and `dev-scripts/preflight.ps1` fails an
entry without one.

- READY — meshghost.exe and config.json now live in the TEVI folder (beside TEVI.exe) and the plugin looks NOWHERE else -- not the plugin folder, not BepInEx\scripts; both installs deployed 2026-09-05 with the files moved up; the start log names the folder used. Unwatched on TEVI (Pseudoregalia's half confirmed).
- READY — `"autostart": false` in config.json now stops the mod starting a client (the old MESHGHOST_NO_AUTOSTART still counts), built and deployed 2026-09-03, unwatched
- MEASURED 2026-09-02 (logs), a look is cheap — the launcher forgets a child the port walk has moved off: cross-wire reproduced on purpose, both copies reached a ghost
- Pending — `anim_t`/`pause` are read as finite-or-absent (2026-09-02 adversarial review), built and deployed, unwatched
- MEASURED, not watched: the relay-down backoff, seen working for the first time (2026-08-28)
- Pending -- the FullMap peer marker was update-driven; the refresh is now FRAME-DRIVEN (2026-08-28)
- Pending -- the peer animation bound is SHIPPED and half-confirmed (2026-08-28)
- Pending -- the cold start LOADS; one VISUAL detail is unwatched (2026-08-28)
- Pending -- the bridge walk DEADLOCK: seen live, fixed, and the fix is not reproduced (2026-08-28)
- Pending -- the charged attack WORKS; whether it is 1:1 was never settled (2026-08-28)
- PARTLY CONFIRMED 2026-08-27 — the send gate works; the port walk converges badly

## [READY] `"autostart"` in config.json replaces the environment variable as the way to say "don't start a client" (2026-09-03), unwatched

The user's call: *"even me that is somewhat tech savvy, has no clue what 'an environment variable' means."*
The launcher reads `"autostart"` out of the same config.json the client will read (own folder first, the
same search order as everything else it resolves), by a hand scan for `"autostart": false`; absent or
anything else means start. `MESHGHOST_NO_AUTOSTART` still counts as a no. `CoreLauncher.ConfigSaysNoAutostart`, checked right after the variable in `TickDisconnected`; the log line is `"autostart": false in config.json -- not starting a core`. **What to watch:**
with `false` in the file, the game comes up with no client started and the log line naming the reason;
with `true` (the shipped value) the client starts exactly as before. Root and per-game READMEs rewritten
around the key ("Turning autostart off").

## [READY] Pending -- the charged attack WORKS; whether it is 1:1 was never settled (2026-08-28)

**The feature is confirmed and lives in [`VERIFIED.md`](VERIFIED.md)** -- three pooled effects, the
hitstop hold, animation phase, and facing captured at fire time, all watched on screen. What stays
here is the standard this project holds itself to: the user's read was *"much better"* and
*"unsure if its 1:1 or not"*, never *"identical"*, and nobody has compared the two side by side.

**What to look at.** The compare setup: a peer doing the charged attack repeatedly while you watch,
against your own attack in the same room. **What correct looks like:** the same rhythm between
star, hold and slam, at the same heights, on the same sides.

**Three residuals, in the order they are likely to be noticed, none of them measured:**

- **A ghost renders behind by design** (`interp` -- 175ms was the dev-judged same-machine floor,
  and the SHIPPED default was raised to 300ms on 2026-09-01 to price a real link, see this file's
  own later entry and `../../agent_docs/verified.md`). Body and effects are delayed together, so it
  should not look internally out of step -- if the star lags the ghost's OWN swing, interpolation
  is not the cause.
  **One consequence is permanent and not a defect:** the weapon strobe cycles every ~83ms while the
  ghost renders 175-300ms behind, so a delayed replica can never agree with the live player frame for
  frame -- only its rhythm, its colours and its HELD poses can match.
- **Effects spawn on message ARRIVAL, and that is now a MEASURED decision rather than a pending
  one (2026-08-28).** The "better fix" this entry used to propose -- spawning when the ghost's clip
  crosses the peer's reported phase -- was built, watched under simulated jitter, and reverted the
  same hour: it pushed the star past the freeze snap, reversing the game's own star-then-freeze
  order. The HOLD needed phase work and got it; the impulse did not. `VERIFIED.md`,
  `../../agent_docs/pitfalls.md` ("IMPULSE and a HOLD").
- **The phase-correction constants are guesses** (updated 2026-08-28: small drift is now a
  playback-speed nudge, not a re-seek -- `PhaseCatchupGain = 2`, range ±0.25, re-seek only past
  0.25 of a clip). The twitch the old tolerance caused is confirmed gone; the exact values are not
  tuned against anything.

**Also unconfirmed, and cheap when the chance comes:** the DODGE trail (mode 2, the yellow one) is
the one trail branch nobody has seen. It needs somewhere with enemies (user). Slide and quickdrop
are both confirmed.

## [READY] Pending -- the bridge walk DEADLOCK: seen live, fixed, and the fix is not reproduced (2026-08-28)

**The defect was observed, not theorised.** Both instances sat logging
`bridge connection ended: ... actively refused` for minutes while their own cores were alive and
listening on 7780 and 7781. Two mechanisms met:

- `ConnectAndReadLoop`'s catch **logged a connection refusal and did nothing else** -- no cooldown,
  no cursor advance. The walk advanced on a core that answered `busy`, and on one that accepted
  then went silent, but never past a port with **nothing listening**.
- `CoreLauncher.TickDisconnected` returns early while `ChildStillRunning()`, so having already
  spawned a core it would not spawn another.

So an adapter could **own a live core it could not reach**: the launcher thought its job was done,
and nothing could move the cursor off an empty port. It stayed invisible because the adapter's own
core had always won the base port, so the cursor never sat anywhere empty. It became reachable
because a core was killed while the adapter's child lived elsewhere.

**The fix**: a port that refuses `RefusalsBeforeWalking` (4) times running releases the cursor.
Counted rather than immediate on purpose -- a refusal is the *normal* first thing on a cold start,
when the adapter dials before its own core has bound, so advancing on the first would walk the
cursor off the base port every launch and creep the whole range upward.

**What IS confirmed (agent, from logs, Go/adapter-plumbing side):** normal recovery is
unregressed -- killing a core produced one refusal, a respawn on the *same* port, and
`bridge ready` again, with the cursor correctly not moving. And the failure line now **names the
port** (`bridge connection ended on port 7778`), which it never did; without it the log could not
distinguish "stuck on one dead port" from "sweeping an empty range", and those want opposite
responses.

**What is NOT confirmed: that the fix resolves the deadlock.** Re-staging it needs the adapter's
child alive on a port *other* than the cursor, which could not be produced on demand. The recovery
path is reasoned from the code, and the log line it would emit
(`nothing has answered on bridge port N in M attempts -- walking on`) **has never been seen**.
**What to look at:** if a session ever shows repeated refusals again, that line appearing within
~8s is the fix working; its absence means this is still open.

## [READY] Pending -- the cold start LOADS; one VISUAL detail is unwatched (2026-08-28)

**The hot-reload half is CONFIRMED and moved to [`VERIFIED.md`](VERIFIED.md)** -- the reload works
and leaves no orphan ghost, watched in a two-instance session. What is left here is everything
that a hot reload cannot, by construction, exercise.

**`LoadOnStart = true` IS CONFIRMED**, later the same session: the user relaunched both games and
both logs show `Loading plugins from ...MeshGhostTevi.dll` during Chainloader followed by
`MeshGhost v0.2.0 loaded.`, with nothing deployed first, and ghosts followed. **`CoreLauncher`'s
cold-start path is confirmed with it** -- `started a core (meshghost.exe, pid ...)` on that same
launch, which is the beside-the-assembly branch rather than the reload branch.

What is left is the one thing a log cannot answer and nobody looked at:

- **UnityExplorer's overlay should now stay hidden until F7.** It opened by default on both
  instances before `Hide On Startup = true` was written, which is what prompted the setting, and no
  launch since has been watched for it. **What correct looks like:** no overlay on top of the game
  until F7 is pressed. Harmless if wrong, and purely a nuisance rather than a defect.

The paragraph below is kept because it names the trap this entry was originally about:

- **If `LoadOnStart` ever regresses**, a fresh TEVI comes up with the
  adapter sitting in `BepInEx\scripts\` **unloaded**, which looks exactly like the mod being
  broken -- there is no ghost and no error. The workaround if it happens is one `-Deploy`.

**The Mono debugger question is answered, and then deliberately switched back off.** Both agents
were confirmed listening on 2026-08-28 (`127.0.0.1:10000` owned by the Steam pid, `:10001` by the
standalone's), so **this build's Mono does carry the debugger agent** and the doorstop route works
without the patched Mono that does not exist for Unity 2021.3. `debug_enabled` is now `false`
again on both: the agent is unauthenticated, nothing was using it, and a GUI debugger is a tool
the user drives rather than the agent. **Still never confirmed: whether dnSpy completes an
attach** -- only that the port answers. `../../agent_docs/environment.md`.

**Nothing here changes what ships.** ScriptEngine and UnityExplorer are developer-machine tools,
the doorstop flag is one line in a local install, and `packaging/release/` carries only the
rebuilt DLL. The pdb the dev loop needs is deployed by `tevi-hotreload.ps1`, never staged.

## [OPEN] Open -- a predicted ghost can sink into the floor; the fix is asking the GAME where the ground is (2026-08-28)

**The one residual the render-knob sweep could not close** (`../../agent_docs/verified.md`, "The
render-knob sweep"): with prediction on, a descending ghost is carried a little below the ground
before the landing sample arrives, and the jump reads a beat late besides. Every generic lever was
tried and the verdicts are pinned in ADR 0040 -- the core cannot know a floor exists.

**The named fix, deliberately not built yet:** the adapter asks TEVI whether the ghost's position
is inside ground (the game's own collision query) and clamps the render. Game-specific by nature,
same "let the game do the work" posture as everything else here. Until then the sink ships as a
known cosmetic limit of prediction -- and prediction itself is opt-in config, off by default.

## [READY] Pending -- the peer animation bound is SHIPPED and half-confirmed (2026-08-28)

**The half that is confirmed moved to [`VERIFIED.md`](VERIFIED.md)**: ghosts animate normally with
`IsPlayableAnimName` live, which is the regression this could have caused (every ghost frozen in
one pose) not happening. What stays here is the half a normal session cannot show.

**Still unwatched: that a HOSTILE name is actually refused**, and the throttled complaint that goes
with it. Nobody has sent a nonexistent clip name. The check is `Animator.HasState` across every
layer -- the same lookup `Play` performs -- so a name it refuses is one `Play` could not have found
either; that reasoning is what the entry rests on, not a run. **What it would look like:** at most
four `ignored an animation name no local controller has` lines per peer, and no Unity animator
warnings at all. `../../agent_docs/ideas.md`, "The ACE audit", gap 2.

## [READY] Pending -- the FullMap peer marker was update-driven; the refresh is now FRAME-DRIVEN (2026-08-28)

**The defect was real and is described below as it stood.** `UpdateRemoteMapMarker` ran only from
inside `UpsertRemoteGhost`, which runs only when a `render_remote` arrives, so the marker was
update-driven rather than frame-driven: a peer that stopped sending left it sitting wherever it
was, until the core's own drop detection finally despawned that peer (quic ~17s, udp up to 60s).

**What changed, built this session and NOT watched:**

- **Every peer's last state is recorded at the TOP of `UpsertRemoteGhost`, above every early
  return.** Two of those returns used to swallow the marker entirely: a state carrying no position,
  and one arriving before there is a local player to clone a ghost from. The map marker is a
  separate feature from the world ghost and no longer inherits the ghost's preconditions -- which
  is the one mechanism that could plausibly explain the *"took a while before it decided to work"*
  symptom below, since a rejoining peer's first states arrive around a scene load.
- **`RefreshRemoteMapMarkers` runs once per frame**, immediately after `DrainInto`, from those
  recorded states. A state that lands this frame is still drawn this frame, so the change costs no
  latency in the normal case.
- **A marker whose state is older than `MarkerStaleSeconds` (1s) HIDES.** Hidden, not destroyed --
  destroying stays the core despawn's job, so a peer mid-hitch comes straight back. One second is
  chosen because the core re-sends every remote it tracks on *every* adapter frame: a peer standing
  perfectly still still produces `render_remote`, so silence means the states stopped arriving,
  never that the peer stopped moving.

**What to look at, and it takes one session.** Open the FullMap with a peer connected, then stop
the peer (close its game, or kill its core). **What correct looks like:** the marker disappears
within about a second, rather than sitting frozen at the last position that arrived.

**The second symptom, and whether it shares a cause is still UNKNOWN.** Reported 2026-08-28: after
a peer left and rejoined, the marker *"took a while before it decided to work/update again"*
(user); the despawn itself was correct. **What to look at:** with the map open, have a peer quit to
the title and rejoin. **What correct looks like:** the marker disappears on leave, and reappears
tracking within a second or so of the peer being back in play. If it is still slow, the early
returns were not the cause and this needs measuring rather than another guess.

`DIAG_MARKER_STALENESS` still exists and now measures the fix rather than the defect: it reports
the age of the DATA each marker is drawing (`LastUpdateTime` is the state's arrival time, not the
redraw time, which is now every frame). A visible marker whose age climbs past one second means
this did not work. It has still never been run ([PROBES.md](PROBES.md)).

Detail and the line numbers as they were: `../../agent_docs/ideas.md`, entry 2 of the HUD/minimap
list.

## [READY] the port walk's dead end, SEEN 2026-09-02, fixed in the launcher and REPRODUCED-AND-RECOVERED the same night: a child alive on a port the walk left behind

**Reproduced deliberately after the fix (agent, from logs -- the plumbing side):** Steam copy launched,
the standalone 3 seconds later (Steam first always: it refuses to start behind a running standalone,
user 2026-09-02). The Steam copy's core bound 7778, the standalone's adapter reached it first and
attached, the Steam adapter got `busy`, and the new line fired: `the core this adapter started (pid
6212, port 7778) is serving another game -- leaving it to that game and starting another on port
7779`, then `bridge ready on port 7779`. Both copies reached a ghost, nobody killed a core. A 1.5s gap
did not cross-wire (the Steam copy's own core lost the bind and its adapter walked normally), so the
race needs the Steam adapter to reach 7778 first; ~3s did it once. **What is left for eyes:** that both
windows show the other's ghost after such a start -- cheap, any two-instance launch.


**Seen live, twice in one relaunch.** Two copies launched close together (my ready check had matched the
previous launch's log): the standalone's core bound 7778 first, the Steam copy's adapter attached to it,
and the standalone's own adapter got "busy" on 7778 and walked -- 7779 through 7785, four refusals each,
for minutes. Nothing ever spawned at the cursor, because `CoreLauncher.TickDisconnected` returns while
its child process is alive, and its child WAS alive: serving the other game. "My child is running" was
read as "I have a core". **Fix (`CoreLauncher.cs`):** the launcher remembers the port it started its child
on; when the walk's cursor is on a different port while that child still lives, the child is forgotten
(never killed -- a game is using it) and a fresh core is started at the cursor. Built with
`build-tevi.bat` and deployed to both installs 2026-09-02, unwatched.

**What to watch:** launch the standalone FIRST and the Steam copy a few seconds later, or both at once;
both must reach `bridge ready`, on different ports, without anyone killing a core. The log line to look
for in the copy that lost the race: `the core this adapter started ... is serving another game`.


**REVISED the same night, after Emerald showed the first version's flaw (2026-09-02, ~23:00).** Forgetting the
child whenever the walk moved off its port was too eager: two instances whose cores were restarted
together each spawned on the base port, each adapter's sweep attached to the OTHER's fresh core first,
each then took `busy` on its own child, forgot it, spawned again -- three cores for two games, and the
emulator at 3fps under the connect storm (Emerald's sweep ran every frame, eight blocking 50ms connects
each). The rule is now two-part in all four launchers: **a spawner waits on its own child's port and never
sweeps past it while that child lives; the child is forgotten only when its port answers "busy"**, never
on silence. Emerald's sweep also runs every 30 frames instead of every frame. Built and deployed (TEVI,
Pseudoregalia DLLs; both Lua files); unwatched beyond one Emerald reload that reattached cleanly.

## [READY] PARTLY CONFIRMED 2026-08-27 — the send gate works; the port walk converges badly

**Watched the same day it was built**, in a two-game session: TEVI beside vanilla Crystal on one
loopback relay. The user, on TEVI: *"TEVI seems to work"*, *"can see the loopback ghost and
stuffs"*. So the send gate does not withhold state that matters and a ghost renders — that half is
confirmed, and the hedge is quoted rather than smoothed over.

**The walk was a different answer, and it is now root-caused and fixed — unwatched.** That session
had TEVI walking 7778→7785 and round again, every port apparently replying `busy`, settling on 7784
after ~35 seconds. Isolated the same day with the real binaries and no game: a core does **not** walk
when its port is taken (it fails to bind and exits), so ports 7779-7785 had no listener and could
not have rejected anything. Every reject came from 7778 and was misreported, because the handler
named the walk's **cursor** instead of the port the **connection** was on. Full measurements:
[BANDAGES.md](BANDAGES.md) entry 5.

**What to look at, and it is a cheap check now.** Two games again, TEVI second. In TEVI's BepInEx log:

- **Exactly one reject, naming 7778 and nothing else.** The old bug's signature was a reject line
  for every port in the range; if that comes back, attribution is still wrong.
- **`bridge ready on port 7779`** — the first free port, not 7784.
- **Convergence in about one retry interval (~2s)**, not 35 seconds, and **one** "started a core"
  line rather than four.
- A ghost still renders, i.e. the send gate did not regress.

**Still unwatched from this entry:** everything below about the two-instance case with two TEVI
copies, and whether a single-game launch (nothing else holding 7778) converges immediately — the
session above never tested that, because Crystal was up first by design.

## [DONE] Original entry — the bridge_ready send gate and the 8-port walk (built 2026-08-27)

Built in this session and **never run in the game**. Both bring TEVI up to the bridge shape
`../_template/PROTOCOL.md` defines and the other three adapters already implement.

- **The send gate.** `bridge_ready` was recognised as of 2026-08-18 but not waited on: the adapter
  sent its first state as soon as the socket connected. It now holds until the core says it is
  ready. Entry 5 in [`BANDAGES.md`](BANDAGES.md) is what this closes.
- **The port walk.** 7778-7785, the same range and count the two Pokémon adapters and
  Pseudoregalia walk, so two copies of TEVI on one machine each find their own core instead of
  silently sharing one. Before this, `BridgePort` had to be set by hand in the BepInEx config.

**What to look at.** One instance: a ghost appears at all, exactly as before — this is a change to
*when* the first packet is sent, so the visible result should be **no different**, and anything
different is the finding. **What correct looks like** in the log: the adapter reports the port it
settled on, and reports waiting for `bridge_ready` before its first send rather than after.

**Two instances is the case the port walk exists for**, and the one worth spending a launch on:
start two TEVI copies with no `BridgePort` set in either config, and each should land on its own
core (7778 and 7779) rather than one failing or both talking to the same one.

## [OPEN] Pending -- two of the six probes have never been run

`DIAG_MARKER_STALENESS` and `DIAG_MENU_GATE` are still written-but-never-run, which is their honest
state ([PROBES.md](PROBES.md)). Neither is part of the shipped mod; both are compiled out while
their flag is false. They exist because their questions cannot be answered by reading code: the
marker one needs to be watched going stale, and the pause-menu one is the exact question whose
answer was reasoned out from code on 2026-08-18 and produced a false regression report.

**This entry used to say "the two probes under `probes/`", which was wrong** -- TEVI has no
`probes/` folder and cannot have one, because BepInEx has no equivalent of BizHawk's Lua console.
A probe here is a `DIAG_*` block inside `Plugin.cs`. Corrected 2026-08-28.

Nothing to confirm here yet: a probe that has never run proves nothing, and its own log is not
evidence either (`../../agent_docs/testing.md`).

## [READY] MEASURED, not watched: the relay-down backoff, seen working for the first time (2026-08-28)

**Here because the evidence is a log this agent read.** What the user saw and confirmed -- two
instances rendering each other, and the ghosts returning after the relay was restarted -- is in
`VERIFIED.md`. The mechanism below is not visible on screen at all.

**The test.** The relay was stopped, the standalone instance closed and relaunched, so its adapter
attached to a core that could not reach the relay. That is the only moment this code path runs: a
relay that drops MID-session is handled by the core retrying on its own, and never rejects anybody.

**What the log showed, in its first 25 seconds:**

```
connected to bridge at 127.0.0.1:7778.
the core on port 7778 rejected this adapter (busy: this core already has a game attached)
  -- walking to the next bridge port.
connected to bridge at 127.0.0.1:7779.
the core on port 7779 cannot reach the relay (core: dial relay: ... actively refused it.)
  -- waiting on this core rather than walking; it retries by itself.
```

with **1** port walk and **5** connect attempts total.

**Both branches of the distinction in one run, which is what makes it convincing.** The same
adapter walked on for "busy" and stayed put for "cannot reach the relay" -- the two cases three of
the four adapters treated identically until this day. Broken, this run would have cooled 7779,
7780, 7781 and the rest of the range in turn, reported "no free port to start a core on", and on an
autostarting adapter spawned cores nobody could use. That is the shape Crystal's own comment prices
at **Emerald running at 5fps while a relay was full**.

**Recovery, same run:** the relay was restarted and both cores reconnected with no intervention,
`members=2` within seconds.

**Still not measured anywhere:** the same path on Emerald, Crystal and Pseudoregalia. All three now
carry the guard -- Crystal since 2026-08-19, the other two added 2026-08-28 -- and on Pseudoregalia
it could not have worked before that day's separate fix, because the rejection it branches on was
being discarded before anything could read it.

## [DONE] user-reported 2026-08-29 and 2026-09-02 — a portal keeps its awake VISUAL after the last ghost leaves; FIXED and WATCHED 2026-09-02 (`VERIFIED.md`, "a portal settles")

**Reported again 2026-09-02 with the trigger named:** *"if a ghost disconnect on top of the warp/portal it
stays visually active, even if no player/ghost is on it anymore."* **The fix is the shape this entry
predicted** (`Plugin.cs`, the `UpdateWarpDevicesForGhosts` call site): the scan now also runs while
`warpsWithGhostInside` is non-empty, so the frame after the last ghost is gone the close branch fires
and the set drains; and the scan prunes ids that match no current device (and clears the set when a
scene has no devices), so a stale id from an earlier scene cannot keep it running. Built with
`build-tevi.bat` 2026-09-02; deploy needs both games closed. **The watch is the one written below:**
a peer standing on a portal, its game closed outright; the portal should settle within about a second.
The control -- the peer walking off normally first -- must still close it.


**The user watched this and it is wrong; nothing below is measured.** A ghost disconnecting while
standing on a portal leaves the portal awake — the *visual* you get standing next to one, the
"assembling" glow the device plays while somebody is on it. It then **stays on until another ghost
or the player walks onto it and off again**, at which point it finally settles. In the user's
words: the stay-near-zone thing *"basically stays enabled until it gets triggered and detriggered
again"*.

**Cosmetic only, and that part is by construction.** The adapter never touches the portal's
trigger — it sets the private `readyopen`/`readyclose` flags and nothing else, precisely so a ghost
cannot save, heal or mark the minimap (the reasoning is in `Plugin.cs` above
`UpdateWarpDevicesForGhosts`). So a portal stuck awake is a stuck ANIMATION, not a stuck game
state, and it cannot have written anything.

**A named suspect, from reading the code — NOT a diagnosis, and not watched.** `Plugin.cs`'s call
site guards the whole scan:

```csharp
if (remoteVisuals.Count > 0)
{
    UpdateWarpDevicesForGhosts();
}
```

The only code that ever closes a portal is the `else if (wasInside)` branch INSIDE that method —
it fires on the frame a device that had a ghost in it no longer does. When the last ghost
disconnects, `remoteVisuals.Count` becomes 0, so the method stops being called at all, and that
branch never gets its chance to run. The flags stay exactly as the departing ghost left them, which
is what the user is looking at. It also predicts the recovery they describe: only a real
enter/exit by the player or another ghost drives the game's own `OnTrigger*` handlers, and those
overwrite the stale flags.

**If that is the cause, the shape of the fix is to let the scan run once more with zero ghosts**,
so the close branch can drain `warpsWithGhostInside`, rather than to widen the guard and pay the
per-frame scan forever. Two details a fix must not miss:

- **It is not specific to disconnecting.** Any way of losing the last ghost reaches the same place
  — a despawn, an area change that filters the peer out, a relay drop. Disconnect is just how the
  user hit it.
- **`warpsWithGhostInside` is keyed by `GetInstanceID()` and is never cleared on a room change**,
  while `warpDevices` is re-scanned every 0.5s. That is a second, independent way for a stale entry
  to survive, and it wants checking in the same pass rather than being found later.

**This is the same shape as the bug fixed on 2026-08-28 one method away** — the local player walking
out of a portal closed it under a ghost that had never left — and the lesson recorded there applies
again: *a transition cannot answer "is anyone still here"*. Here the transition is not missed, it is
never reached.

**What to watch, once something is built:** two instances, a peer standing on a portal, then close
that peer's game outright. The portal should settle on its own within about a second, with nobody
touching it. **The control that makes it meaningful** is the same run with the peer walking off the
portal normally before disconnecting — that path already works today, and must still work after.

## [DONE] the shipped interp default of 300ms: the ladder climbed on a fixed relay, CONFIRMED 2026-09-02 (`VERIFIED.md`, "300ms interp at the 15Hz relay")

**The run this entry asked for happened 2026-09-02, after a transport bug was fixed under it.** Two real
TEVI instances, both through `meshghost-netsim` at 60ms/±25ms/2%/2% (which is ~125ms one-way peer to
peer, the proxy is crossed twice -- `dev-scripts/README.md`), relay at the shipped 15Hz with loss cover
on, quic, climbed from the bad end. The core's new `buffer dry` counter (how often the render time ran
past a moving peer's newest sample) sat beside every rung:

| Interp | Dry renders | The user |
|---|---|---|
| 175ms | 38% | *"stuttering constantly"* |
| 250ms | 3.5%, max 158ms past | *"smooth/delayed + rare stutters"* |
| 300ms | 0.5%, max 69ms past | *"think its smooth all the time now, didn't see any stutter"* |

**So 300ms stands. Asked to settle the "think", the user did: *"it was smooth and i didn't see anything"* --
recorded in `VERIFIED.md`; this entry stays for the ladder's numbers.** The dry lines at 250ms all
showed consecutive seqs with normal transit: the 2% loss holes, where the lost sample only lands
67-83ms later inside the next packet. 300ms is the first rung with room for one lost sample at 15Hz.
Why every EARLIER rung that day was invalid: the relay's connection limiter (ADR 0044's review, that
morning) had hidden the quic connections' unreliable write, so every forwarded state rode the reliable
stream and stalled up to 770ms behind a lost packet -- `agent_docs/verified.md`, "The limiter hid
WriteUnreliable". Both TEVI installs carry `interp 300ms` now.

**What the entry said before the run, kept for the reasoning:**


The user's call, made explicitly as a guess with stated reasoning: Pseudoregalia's ocean-profile
sweep (netsim ~200 ping / ±40ms jitter / 5% loss) measured that its same-continent value needed
+125ms more buffer to stay smooth there, the extra buffer covers the LINK's wobble (a cost in
milliseconds, not percent, so it transfers across games additively), and a too-high interp only
adds delay, never stutter -- so the guess cannot regress smoothness, only immediacy. 175ms stays
the documented same-continent floor in the release README, which also carries the honesty note.

**What confirming this looks like:** one TEVI two-instance session through the same netsim ocean
profile at 300ms -- smooth ghosts confirms the transfer; stutter refutes the additive model and
the number needs its own sweep. Until then every TEVI ghost on ANY link is drawn 125ms later than
the measured pick, which a same-continent player can undo per the README.

## [READY] Pending — `anim_t`/`pause` are read as finite-or-absent (2026-09-02 adversarial review), built and deployed, unwatched

`BridgeClient.cs`: the two peer floats that reach the Animator (`anim_t` → `Animator.Play`'s
normalized time and the phase catch-up speed; `pause` → `anim.speed`) now go through
`FiniteOrNull`. Newtonsoft's `(float?)` cast accepts `"NaN"`/`"Infinity"` strings and turns an
out-of-range double into infinity without throwing, and a NaN there froze that one ghost's
Animator. Built with `build-tevi.bat` and deployed to both installs 2026-09-02. A normal session
cannot produce a non-finite value, so the watch is only "ghost animation phase and pause still
behave as on 2026-09-01". ADR 0044, `docs/security.md`.
