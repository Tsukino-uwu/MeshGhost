# Verified facts

This file records facts that have been confirmed by observing actual behavior in a running
game. See `CLAUDE.md` for the full rule; summary:

- No inferred or speculative values are allowed.
- Every entry must include a source, such as a memory address, API, or documentation
  reference.
- This file is append-only and human-gated: an entry goes in only after the user has
  personally watched the behavior happen. A successful build or a plausible-looking number
  is not sufficient grounds for an entry.

## Entry format

Copy this block per fact:

```text
### <short claim, e.g. "Emerald local player X position">

- Date:
- Observed: <what was seen on screen, and what action produced it, e.g. "printed value
  decreased by 16 per tile when walking left in Littleroot Town">
- Source: <exact file + symbol/line in the referenced repo, or doc page + section>
- Notes: <anything conditional — game version, ROM revision, edge cases found>
```

## Confirmed facts

(none yet — Phase 1 has not started)
