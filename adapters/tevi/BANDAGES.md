# Bandages — TEVI

<!-- line-cap: none -- register; growth is a smell you must be able to SEE, never one to hide by trimming. Why: agent_docs/claude-md-cap.md. -->

Shipped compensations in this adapter: **a fix that restores, forces, compensates for, or
remembers a value rather than preventing whatever changed it.** The rule, its one narrow
exception, and what it is *not*: `adapters/_template/README.md` ("a bandage fix is not a finished
feature").

From the repo-wide audit of 2026-08-16. Its headline holds here too: most things that *look* like
bandages are not — the great majority carry the live incident, the rejected alternative, and the
derivation right beside them. Ranked by how likely each is to cause a real bug.

Other registers: `../pseudoregalia/BANDAGES.md`, `../emulator/pokemon/emerald/BANDAGES.md`,
`../emulator/pokemon/crystal/BANDAGES.md`, `../../agent_docs/bandages-core.md`.

**Cited by method name, not by line number.** Line citations in this file had drifted by
2026-08-18, and a citation pointing at the wrong code is worse than one that makes a reader search.
Switch values and their provenance are in [FLAGS.md](FLAGS.md).

## Is this a bandage?

The canonical guide — the one mechanical test, the tells while you are writing it, the eight
tells that only show up later, and the one bandage shape to avoid outright — lives in
[`adapters/_template/BANDAGES.md`](../_template/BANDAGES.md). Read it before adding an entry.

## Open compensations

### 1. Force-enables all five sprite layers, having measured one

`MeshGhostTevi/Plugin.cs`, `CreateRealGhostVisual()` sets `enabled = true` on every child
`SpriteRenderer` of a cloned ghost, working around `Instantiate()` deep-copying a transient zone-load fade that the logic-less
clone can never clear by itself.

**Forcing is defensible here** — the clone carries no animation logic, so nothing else will ever
set it. **The defect is scope.** The live log measured only `basesprite`; the code enables all five
(`basesprite, outlinesprite, effectsprite, flashsprite, supportsprite`). `flashsprite` is a
hit-flash overlay and `supportsprite` similar — layers that are *normally off*, so forcing them on
likely paints a permanent overlay on every ghost.

`agent_docs/pitfalls.md` already states the lesson this violates: *"only reset the field actually
confirmed broken, not everything that plausibly could be"* — learned from the earlier
`color = Color.white` mis-fix that broke `outlinesprite`.

**Fix:** narrow to `basesprite`, or log all five layers' inherited state on a real repro first.

### 2. `GetRoomWalkedBool(area, x, y, 0, 0)` — two arguments with no citation anywhere

`Plugin.cs`, `UpdateRemoteMapMarker()`. The fog-of-war check calls the game's own discovery-state
query with **five** arguments, and only three of them are explained. The last two are literal
zeroes, and **nothing in this repo says what they mean** — not the call site, not
`documentation.md`, not `VERIFIED.md`.

**This is a `CLAUDE.md` gap, not merely an untidy line:** *no addresses or APIs from memory —
every third-party API call must be traceable to a specific file or documentation page.* The
method's *existence* is properly cited (confirmed live by reading `FullMapTile.SetVisible`'s use of
it), which is exactly what makes the missing half easy to overlook. Two zeroes that happen to
produce the right answer today are indistinguishable from two zeroes that are wrong in a case
nobody has visited.

**Why it is a compensation and not just a gap.** A value chosen because the result looked right,
with no model of what it selects, is the same shape as a tuned constant — and the failure mode is
quiet: a wrong pair here does not throw, it returns a plausible boolean, and the marker is simply
shown or hidden in the wrong rooms.

**Fix — and it needs a live check, not a re-read.** Read the signature out of the decompiled
assembly, name each parameter in the call site's comment, and confirm on a real save that a peer's
marker appears in a room the local player has walked and stays hidden in one they have not,
**including at least one room where the two trailing values would plausibly differ** (a sub-area or
a second floor). Until that runs, treat the fog-of-war behaviour as unverified.

### 3. `MaxRoomCoordinate = 100000` — a bound nobody measured

`Plugin.cs`, `UpdateRemoteMapMarker()`. Peer-supplied `room_x`/`room_y` are rejected outside
±100000 before they can reach `GetRoomWalkedBool`.

**Bounding peer-controlled input before it reaches the engine is correct** — `PROTOCOL.md` requires
it. **The number is the problem, and its own comment says so:** *"Not a measured game constant --
TEVI's real room grid is far smaller than this -- just a generous sanity bound"*. So the guard is
sized against nothing: it stops an absurd value and passes every merely-wrong one, and a wrong-but-
in-range room index reaches a method whose internals are unknown.

**Fix:** read the real grid bound the game already keeps — `FullMap.maxroom` is reflected in this
same file — and bound against that, which turns a guess into a fact and tightens the guard by four
orders of magnitude at the same time.

### 4. Stripping colliders from a clone, for a hazard not confirmed to exist

`Plugin.cs`, `CreateRealGhostVisual()` destroys every `Collider2D` on the cloned ghost. Its own
comment is candid: *"Not confirmed to exist on this object (PixelCharacter.cs itself declares
none), but a hitbox collider living on a child sprite object would be a real, silent bug ... if one
turned out to be there."*

**Defensive-by-default is the right instinct here** — a TEVI ghost must never collide with
anything, and the cost of being wrong is a silent gameplay effect a player would blame on the game.
(Stated narrowly on purpose: this is not a project-wide rule, and reading it as one would be wrong.
Pseudoregalia ships solid ghosts deliberately, and the 2026-08-19 ADR in `agent_docs/architecture.md`
makes collision a host-set room policy rather than a fixed property of being cosmetic.)
It is registered anyway because it is code acting on an unmeasured premise, and that premise is
cheap to settle: **enumerate the clone's components once and log them.** Either the strip is
removing something real, and the entry becomes a documented fact in `documentation.md`, or it is
removing nothing, and it stays as a deliberate guard with the enumeration cited beside it. Right
now it is neither.

**It is also the shape `_template/README.md` warns about from the other side:** the clone was
*created* by us (`Instantiate`), so this is not the borrow-tier problem — but "destroy anything
that might carry a side effect" is still a rule written far from the code that would want that
component later.

### 6. The afterimage trail's CADENCE is ours, because a ghost has no `SpriteAnimation`

`MeshGhostTevi/Plugin.cs`, `ApplyTrail()`. TEVI drives its afterimage trail from `SpriteAnimation`,
which each frame computes a small mode and spawns a pooled `GhostEffect` at its own `trailRate`.
**The proper call exists and is public** -- `SetTrail(t, rate, decay, haveEffect, order, pause)` --
and it is deliberately not gated on `isPlayer()`, so it would work on a ghost.

**We cannot reach it.** A peer ghost is a clone of `spranim_prefer.pixel.gameObject`, the pixel
CHILD, so `SpriteAnimation` sits on a parent that was never cloned. There is no component to call
`SetTrail` on.

**What we do instead:** run the same loop ourselves -- accumulate `Time.deltaTime`, and every
`0.07s` spawn `GemaPoolManager.Instance.CreateGhostEffect()`, hand it the ghost's current sprite and
flip, and set decay and sorting order. **The effect object, its pool, its fade and its sprite are
all still the game's.** Only the *timing loop* is reproduced, and its three constants
(`trailRate 0.07`, `trailDecay 1.5`, `trailOrder 99`) are read from `SpriteAnimation`'s own
defaults rather than tuned by eye.

**Why this is registered rather than called finished.** It is a partial reimplementation of a rule
the game already owns, which is exactly what `../CLAUDE.md` says to prefer not to do -- and the
failure mode is quiet: if a future TEVI build changes `trailRate`, the player's trail changes
density and a ghost's does not, which reads as a desync rather than as a stale constant. It also
means anything the real component does that we have not noticed (a pause condition, a scale rule)
is simply absent on a ghost.

**The real fix, in preference order.** (1) Give the clone a genuine `SpriteAnimation` and call
`SetTrail`, if one can be attached without the gameplay logic it expects. (2) Clone one level
higher so the component comes with it -- which changes what a ghost IS and would need the position
handling revisited, since `documentation.md` records that the drawn position hangs off the pixel
child. Neither was attempted; the cadence version was confirmed working on screen first
(`VERIFIED.md`, 2026-08-28) and the cost of the shortcut is written here so it is a decision rather
than a default.

### 5. CLOSED 2026-08-27 — the send gate, the port walk, and the walk's own root-caused defect

`BridgeClient.cs` handles `bridge_ready` and `reject` as of 2026-08-18 -- before that both fell
into the unknown-message-type default, so every healthy session logged a warning about the one
message meaning everything was fine, and a `reject` was talked straight past: the adapter kept
pushing `local_state` at a core that had already refused it and closed.

**What was missing was the gate.** `_template/PROTOCOL.md` is explicit -- *"Do not start sending
`local_state` until `bridge_ready` arrives"* -- and TEVI sent immediately from 2026-08-18 to
2026-08-27. Recognising the message without honouring it is a half-measure, and it was registered
here rather than quietly left, because the code *looked* like it did the handshake.

**Closed 2026-08-27, by doing exactly what the paragraph below prescribed** — kept as written,
because the reasoning for deferring it is what made the eventual fix safe.

- `bridgeReady` is set on `bridge_ready` and **cleared on every fresh connection** in
  `ConnectAndReadLoop`, which is the precondition this entry named. `SendLocalState` returns early
  until it is set. Dropping those frames costs nothing: a core that has not accepted us has nowhere
  to forward them, and the next frame carries a fresher state than the one withheld — the state
  plane is latest-wins by contract.
- **Silence is not acceptance.** A core that accepts the TCP connection and never answers within
  1.5s is treated as not a core: the port goes on a 10s cooldown and the walk moves on. Without
  that, the gate's failure mode is exactly the silent one this entry warned about.
- **The port walk landed with it**, as the entry predicted it would: 7778-7785, matching the other
  three adapters, with a `reject` cooling that port down and advancing. TEVI is no longer the one
  adapter on a fixed port, and `BridgePort` no longer has to be set by hand for a second instance.

**The send gate is confirmed working; the WALK is not.** Watched 2026-08-27 in a two-game session
(TEVI beside Crystal on one relay). The user: *"TEVI seems to work"*, *"can see the loopback ghost
and stuffs"* — so the gate does not withhold state that matters, and a ghost renders. But the log
of that same session shows the walk converging badly:

- Crystal's core held 7778. TEVI spawned **four** cores; because a core has its own port walk, each
  took a different free port in the range.
- TEVI's adapter then walked **7778 → 7785 and round again**, and **every single port answered
  `busy: this core already has a game attached`**, including ports whose core it had spawned itself.
- It settled on 7784 after roughly **35 seconds**.

**ROOT-CAUSED THE SAME DAY, and both of the first two guesses were wrong.** Isolated with the real
binaries and no game at all — four experiments against a live relay and real cores:

| Experiment | Result |
|---|---|
| Cold core on a free port: hello → `bridge_ready` | **14ms.** Nowhere near the 1.5s timeout. |
| Core told to use a port already held | **Does not walk — fails to bind and exits.** |
| Second adapter on a core that has one | `reject` `busy: this core already has a game attached`, **13ms**, then closed |
| Dial a port with nothing on it | **Dial REFUSED** — no `reject` message at all |

Experiment two is the one that broke the case open: because a core does **not** walk, ports
7779-7785 had no listener during that session and **cannot have sent a `busy` reject**. Every reject
came from 7778 — Crystal's core — and was *misreported eight times as a different port*.

**The actual bug:** the `reject` handler ran on the main thread in `DrainInto`, frames after the
message arrived, and named `CurrentPort` — the walk's **cursor** — instead of the port the
**connection** was on. So it cooled down whatever port the cursor had drifted to. The genuinely busy
port never got cooled and the walk kept returning to it, while innocent free ports were skipped. It
converged only when a spawn happened to land somewhere free and un-cooled.

**Introduced by me, in this same pass**, replacing `dialPort` with `CurrentPort` to fix a compile
error — the two are not the same thing, and swapping one for the other silently changed the meaning
from "the port this connection is on" to "the port the walk happens to be on now".

**The fix:** a `connectedPort` field, set when a connection is published and read wherever a
received message has to name its own port; and `AdvanceWalkPast(port)`, which moves the cursor past
*the port that refused* rather than one step from wherever it sat. Expected convergence is now one
retry interval (~2s): 7778 rejects → cool 7778, step to 7779 → refused → spawn there → ready in
~14ms.

**Also ruled out:** the core releases its admission slot when its adapter disconnects
(`core/bridgeserve.go`), so this was never a stale attachment that failed to free. And autostart
spawning on `CurrentPort` turns out to be **correct** once attribution is fixed, because the walk
only sits on a port whose dial was refused — and a refusal is proof nothing is listening.

**STILL UNWATCHED.** The root cause is measured and the fix follows from it, but the fix itself has
not been seen working. `UNVERIFIED.md` says exactly what to look for, and it is now a cheap check
rather than a vague one: the reject must name **7778 and only 7778**.

**The original deferral, kept:** the gate needs the reconnect path to reset the flag too
(`connectionGeneration` already tracks the generation, so the hook exists). Get that wrong and a
missed or dropped `bridge_ready` silences the adapter completely — a total, silent failure, traded
for today's cosmetic warning. That was a bad trade to make immediately before a live confirmation
pass, so it was deliberately deferred rather than rushed.

## Borderline — noted, not urgent

- **`cloneTemplate` (`Plugin.cs`, the field, remembered in `Update()`).** Literally remembers a
  value across the thing that invalidated it — `cloneTemplate = (player != null && player.t != null)
  ? player : cloneTemplate;`. Saved in practice by Unity's fake-null comparison, but it is the
  pattern the rule names.

## Deliberate — do NOT "fix" these

Recorded so a future audit does not churn them.

- **The loopback render offset, `160f` (`Plugin.cs`, `UpsertRemoteGhost()`).** A dev-only,
  render-only sideways nudge so a loopback ghost can be judged beside the real character; it never
  touches what goes on the wire. **It is a tuned number and says so** — `2f` was live-tested and
  confirmed too small (the ghost rendered basically inside the player), `80f` was
  screenshot-confirmed but still close, and `160f` is a doubling the user explicitly waived a fresh
  live check for, on the grounds that a linear doubling of an already-watched, correctly-oriented
  offset on the same render path is not a new guess. **Deliberate rather than open because there is
  no mechanism to measure**: the "right" separation is a judgement about what a person can see,
  which is the one case where trying values until it looks right *is* the correct method. Do not
  "fix" it into a computed value. Compare Pseudoregalia's `LOOPBACK_GHOST_OFFSET_X`, which is the
  same decision in another game.
- **`connectionGeneration` (`BridgeClient.cs`).** A counter bumped on every reconnect so a
  reader goroutine from a previous connection recognises it is stale and exits quietly. It reads
  like state kept across an invalidation, but it is the invalidation signal itself. (Moved here
  2026-08-17 from `agent_docs/bandages-core.md`, which is the Go side's register — this is C#.)
