# Bandages — Pokémon Emerald

Shipped compensations in this adapter: **a fix that restores, forces, compensates for, or
remembers a value rather than preventing whatever changed it.** The rule, its one narrow
exception, and what it is *not*: `adapters/_template/README.md` ("a bandage fix is not a finished
feature").

From the repo-wide audit of 2026-08-16. Its headline holds here too: most things that *look* like
bandages are not — the great majority carry the live incident, the rejected alternative, and the
derivation right beside them. Ranked by how likely each is to cause a real bug.

Other registers: `../../pseudoregalia/BANDAGES.md`, `../../tevi/BANDAGES.md`,
`../../../agent_docs/bandages-core.md`.

## Is this a bandage? — the short form

Full version, including all seven after-the-fact tells: `../../_template/BANDAGES.md`.

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

### 1. Proceeds on known-wrong addresses for an unrecognised ROM

`meshghost_emerald.lua:304-307` (sprite data) and `:359-379` / `:1060-1062` (avatar offset). When
neither the vanilla nor the known Archipelago-shifted address verifies, both warn and **carry on
with vanilla addresses**.

**This is the one that puts wrong data on the wire.** Nothing gates *sending* on
`avatarAddrConfirmed`, so `getLocalState()` reads `GPLAYERAVATAR_ADDR + 0` every frame until
detection succeeds — on a future Archipelago recompile that never happens, and the adapter
transmits garbage facing/anim to real peers while drawing remotes at a garbage screen position.

The two *known* offsets are exceptionally well measured (byte-level ROM diffs, multi-stage live
probes). What was never observed is what the fallback path actually renders or sends.

**Fix:** on "not found", stop sending (`ENCODED_NO_SEND`) and stop drawing remotes. A visibly
disabled adapter beats silent wrong data.

### 2. Blanket per-frame `pcall` with a 300-frame log gag

`meshghost_emerald.lua:1133-1142`. The resilience posture is right for a Lua script that would
otherwise die for the session — but it cannot tell one malformed line from every frame failing. A
systematically broken read reports once per ~5s and the ghost silently stops updating.

**Fix:** a consecutive-failure counter that logs loudly and disables the offending subsystem,
rather than a constant chosen to protect the console.

## Borderline — noted, not urgent

- **`meshghost_emerald.lua:675` — `FACING[facingRaw] or "south"`.** Turns a bad memory read into a
  plausible value with no counter or log, which is the failure mode `CLAUDE.md` warns about. (The
  neighbouring gender/direction defaults are documented forward-compat and fine.)

## Deliberate — do NOT "fix" these

Recorded so a future audit does not churn them.

- **`STEP_DURATION_FRAMES`.** Measured live twice with zero variance, and two "smarter"
  self-correcting alternatives were built, traced, proven worse and reverted with the evidence
  left inline. **The reference case for how this repo justifies a constant** — read it before
  arguing any other number here is arbitrary.
