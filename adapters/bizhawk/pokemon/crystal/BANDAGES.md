# Crystal — bandage register

**Nearly empty, and that is the point.** Phase 9 exists because the user's call was to build this
adapter without starting from a compensation: *"i want to actually spawn in as intended now for
crystal, so we don't start doing this game with bandaids from the get go"* (2026-08-17). The
adapter now ships, and it carries **no open compensations** — two entries under Deliberate, both
measured, and nothing under Shipped.

**A file that is present and empty is the goal; a file that is absent is a gap.** An absent register
cannot tell you whether an adapter has no compensations or merely never wrote them down.

The canonical guide — what counts as a bandage, the mechanical tell, the one narrow exception, and
the user's standing position that a bandage is a state to leave rather than rest at — lives in
[`adapters/_template/BANDAGES.md`](../../../_template/BANDAGES.md). Read it before adding an entry.

## Shipped compensations

*None.*

## Deliberate — measured decisions, not bandages

A number **measured from the game** and written down is a design decision with evidence behind it,
not a compensation. These are logged so a later audit does not churn them — and so that the day one
of them stops being measured, the entry is already here to be corrected.

- **The adapter applies the first 2 px of every step itself.** `stepGhost()` writes the game's own
  step-initiation set and then adds ±2 to the ghost's sprite X/Y in the same frame. It looks
  exactly like the tell — a value nudged by hand right after the engine was asked to do the job —
  and it is not one, because the *mechanism* is known rather than the *symptom*: **the engine
  applies its own first 2 px increment in the frame it initiates a step**, and ours begins a frame
  later. Without the addition every step lands 2 px short and the error accumulates, so this is
  starting the ghost from the same place the engine starts a real character, not correcting it
  afterwards. Established by watching a real NPC take one step frame by frame
  (`probes/step_watch_probe.lua`) — the same capture that overturned the movement plan before any
  code was written. **What would let it go:** initiating the ghost's step in the same frame the
  engine would, which needs a write that lands before the engine's own step pass rather than after
  it. If that ever becomes possible, this line should disappear rather than be re-tuned. A *tuned*
  version of this — nudging the number until it looked right — would belong in Shipped, above.
- **`MESHGHOST_CRYSTAL_AP_TRY` substitutes a named candidate address for an unmeasured one.**
  Superficially the shape a bandage takes: continuing on data known to be uncertain. It is
  deliberate, and every clause of how it is built is what keeps it out of Shipped. It is
  **off by default** and a missing address otherwise **refuses to run** rather than falling back;
  it substitutes only from an explicit `candidates` table kept separate from the real fields,
  precisely so a candidate that ordinary code can read does not quietly get treated as measured;
  it logs `UNCONFIRMED ADDRESS IN USE` on **every** startup, so a session run this way can be told
  apart afterwards; and it announces that nothing seen in that session may be written to
  `verified.md` as a fact. **It lowers the bar to *unconfirmed*, never to *invented*** — a missing
  candidate still refuses. `release.yml` fails the build if `ap_try.flag` reaches the package.
  **What would let it go:** measuring the addresses it stands in for. `W_BATTLEMODE` on the
  Archipelago table is the last one, and it needs a single trainer battle
  (`probes/ap_battlemode_probe.lua`). Registered in [FLAGS.md](FLAGS.md) as a runtime switch.

## Known temptations, recorded before they are taken

Not bandages — none of these has been taken. Listed because each is a place where a compensation is
the obvious next move, and naming them early makes taking one a decision rather than a slip.

- **Falling back to drawing an overlay if spawning proves unreliable**, and leaving both paths in.
  Named in the spawn ADR as the specific risk this adapter carries
  (`agent_docs/architecture.md`, 2026-08-17). Emerald draws because it must; Crystal drawing
  *as well as* spawning would be a compensation wearing a feature's clothes.
- **Writing an object struct directly instead of going through a map object.** It renders, and it
  was the first thing that worked — but it produces a half-owned object the engine does not
  maintain, with collision and sprite drifting apart. Any future use of that shortcut is a bandage
  and belongs here with the reason.
- **Re-writing a value every tick to keep a ghost where it should be.** The tell from the guide
  applies directly: a fix that *restores* a value rather than preventing whatever changed it.
