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

### 5. CLOSED 2026-08-27 — `bridge_ready` is now the send gate, and TEVI walks the port range

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

**NOT CONFIRMED ON SCREEN.** Built and deployed, never watched — `UNVERIFIED.md` has what to look
at and what correct looks like, including the two-instance case the walk exists for. This entry
stays here until that happens.

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
