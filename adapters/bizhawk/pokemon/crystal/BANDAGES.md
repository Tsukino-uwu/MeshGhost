# Crystal — bandage register

**Empty, and that is the point.** Phase 9 exists because the user's call was to build this adapter
without starting from a compensation: *"i want to actually spawn in as intended now for crystal, so
we don't start doing this game with bandaids from the get go"* (2026-08-17).

**A file that is present and empty is the goal; a file that is absent is a gap.** An absent register
cannot tell you whether an adapter has no compensations or merely never wrote them down.

The canonical guide — what counts as a bandage, the mechanical tell, the one narrow exception, and
the user's standing position that a bandage is a state to leave rather than rest at — lives in
[`adapters/_template/BANDAGES.md`](../../_template/BANDAGES.md). Read it before adding an entry.

## Shipped compensations

*None.*

## Deliberate — measured decisions, not bandages

*None yet.* A number **measured from the game** and written down is a design decision with evidence
behind it, not a compensation; log those here so a later audit does not churn them.

## Known temptations, recorded before they are taken

Not bandages — nothing has been shipped. Listed because each is a place where a compensation is the
obvious next move, and naming them early makes taking one a decision rather than a slip.

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
