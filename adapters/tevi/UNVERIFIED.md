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

## Pending — the FullMap peer marker goes stale when a peer stops sending (shipped bug)

**This one is a known DEFECT waiting to be looked at, not a fix waiting to be confirmed** — it is
here because the queue is where "not yet seen by the user" lives, and nobody has watched it happen.

`UpdateRemoteMapMarker` runs only from inside `UpsertRemoteGhost`, which only fires when a
`render_remote` arrives. So the marker is update-driven, not frame-driven: if a peer's state stops
arriving while the local player has the map open, the marker neither hides nor refreshes. It sits
wherever it was.

**What to look at.** Open the FullMap with a peer connected, then stop the peer (close its game, or
kill its core). **What correct looks like:** the marker disappears, or at minimum stops claiming a
position the peer no longer holds. **What it does today:** the marker stays frozen at the last
position that arrived.

Detail and the line numbers: `../../agent_docs/ideas.md`, entry 2 of the HUD/minimap list.

## Pending — charged-attack VFX are missing on a peer ghost (2026-08-15)

The animation plays and the effect does not. Same shape as Pseudoregalia's ultra-hop trail and
Emerald's surf blob, both of which turned out to be a separate spawned thing the state owns rather
than part of the pose — see `../CLAUDE.md`'s "reproduce the WHOLE effect" rule, which exists
because of exactly this class of gap.

**What to look at.** A peer performing a charged attack, watched from another instance. **What
correct looks like:** whatever the local player's own charged attack shows, shown on the ghost too.
**What it does today:** the ghost animates and spawns nothing.

Written up in `../../agent_docs/phases/phase6.md`. Not started as work; the investigation method is
`../../agent_docs/effect-investigation.md`, which is what to read first.

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

## Pending — the two probes under `probes/` have never been run

`probes/README.md` marks both as **written, never run**, which is their honest state. Neither is
part of the shipped mod. They exist because the two questions above cannot be answered by reading
code: the marker one needs to be watched going stale, and the pause-menu one is the exact question
whose answer was reasoned out from code on 2026-08-18 and produced a false regression report.

Nothing to confirm here yet — this entry is a reminder that a probe that has never run proves
nothing, and that its own log is not evidence either (`../../agent_docs/testing.md`).
