# Bandages — TEVI

Shipped compensations in this adapter: **a fix that restores, forces, compensates for, or
remembers a value rather than preventing whatever changed it.** The rule, its one narrow
exception, and what it is *not*: `adapters/_template/README.md` ("a bandage fix is not a finished
feature").

From the repo-wide audit of 2026-08-16. Its headline holds here too: most things that *look* like
bandages are not — the great majority carry the live incident, the rejected alternative, and the
derivation right beside them. Ranked by how likely each is to cause a real bug.

Other registers: `../pseudoregalia/BANDAGES.md`, `../pokemon/emerald/BANDAGES.md`,
`../../agent_docs/bandages-core.md`.

## Is this a bandage? — the short form

Full version, including all seven after-the-fact tells: `../_template/BANDAGES.md`.

**The one mechanical test:** does the fix **prevent** the wrong thing, or **correct** it
afterwards? Correcting afterwards means the cause is still running. Then: *"what would make this
unnecessary?"* (a proper fix has no answer) and *"where did this number come from?"* — measuring
the mechanism, or trying values until it looked right?

**Writing it:** watch for *almost*, *good enough*, *for now* in your own reasoning, and for code
that *restores*, *forces*, *remembers*, *re-applies*, or *offsets* a value.

**Discovering it later — you will not always know at the time.** Add an entry if any of these
happen: its cause got fixed somewhere else and the fix is still there; a second bug gets described
as *"structurally the same bug as X"*; it outlived its purpose and became the bug itself; a
constant needs re-tuning when something unrelated changes; removing it breaks something it was
never about; you can't explain it without describing a sequence; it needs a companion fix elsewhere
to stay correct.

**When in doubt, log it.** A false positive costs one line under "Deliberate".

## Open compensations

### 1. Force-enables all five sprite layers, having measured one

`MeshGhostTevi/Plugin.cs:330-333` sets `enabled = true` on every child `SpriteRenderer` of a cloned
ghost, working around `Instantiate()` deep-copying a transient zone-load fade that the logic-less
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

## Borderline — noted, not urgent

- **`Plugin.cs:528` — `cloneTemplate`.** Literally remembers a value across the thing that
  invalidated it. Saved in practice by Unity's fake-null comparison, but it is the pattern the rule
  names.

## Deliberate — do NOT "fix" these

Recorded so a future audit does not churn them.

- **`connectionGeneration` (`BridgeClient.cs:67`).** A counter bumped on every reconnect so a
  reader goroutine from a previous connection recognises it is stale and exits quietly. It reads
  like state kept across an invalidation, but it is the invalidation signal itself. (Moved here
  2026-08-17 from `agent_docs/bandages-core.md`, which is the Go side's register — this is C#.)
