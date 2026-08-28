# Unverified — TEVI's queue waiting on the user

<!-- line-cap: none -- queue that drains; size is how much the user has not seen yet. Why: agent_docs/claude-md-cap.md. -->

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

## Pending -- the charged attack WORKS; whether it is 1:1 was never settled (2026-08-28)

**The feature is confirmed and lives in [`VERIFIED.md`](VERIFIED.md)** -- three pooled effects, the
hitstop hold, animation phase, and facing captured at fire time, all watched on screen. What stays
here is the standard this project holds itself to: the user's read was *"much better"* and
*"unsure if its 1:1 or not"*, never *"identical"*, and nobody has compared the two side by side.

**What to look at.** The compare setup: a peer doing the charged attack repeatedly while you watch,
against your own attack in the same room. **What correct looks like:** the same rhythm between
star, hold and slam, at the same heights, on the same sides.

**Three residuals, in the order they are likely to be noticed, none of them measured:**

- **A ghost renders 250ms behind by design** (`core.DefaultInterpolationDelay`). Body and effects
  are delayed together, so it should not look internally out of step -- if the star lags the
  ghost's OWN swing, interpolation is not the cause and something else is.
- **Effects spawn on message ARRIVAL, not at the ghost's own `animTime`.** The game fires the star
  at `animTime 0.425`; the ghost fires it when told, which coincides only while phase is in sync.
  **The better fix, deliberately not built:** spawn when the ghost's own clip crosses the phase the
  peer reported. More faithful, and it couples effect to animation, so it wanted evidence first.
- **`AnimPhaseTolerance = 0.06` is a guess** -- roughly 25ms on a half-second clip. Too loose and
  the hold lands a frame or two late; too tight and the ghost shimmers from constant re-seeking.

**Also unconfirmed, and cheap when the chance comes:** the DODGE trail (mode 2, the yellow one) is
the one trail branch nobody has seen. It needs somewhere with enemies (user). Slide and quickdrop
are both confirmed.

## Pending -- the bridge walk DEADLOCK: seen live, fixed, and the fix is not reproduced (2026-08-28)

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

## Pending -- the cold start LOADS; one VISUAL detail is unwatched (2026-08-28)

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

## Pending -- the FullMap peer marker was update-driven; the refresh is now FRAME-DRIVEN (2026-08-28)

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

## PARTLY CONFIRMED 2026-08-27 — the send gate works; the port walk converges badly

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

## Original entry — the bridge_ready send gate and the 8-port walk (built 2026-08-27)

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

## Pending -- two of the five probes have never been run

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
