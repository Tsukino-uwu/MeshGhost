# How Pokémon Emerald works

> Everything here is **measured from a running game** across Phases 1–5.5 and 8, and cross-checked
> against the public `pret/pokeemerald` decompilation, which is cited by file so any claim can be
> re-checked. **No source text, data table, or asset from that decompilation is reproduced here** —
> only facts, per `agent_docs/licensing.md`.

**What this file is: how *the game* does things**, per mechanic, in our own words. **Nothing here
describes an adapter workaround** — those belong in [BANDAGES.md](BANDAGES.md).

Dated evidence for every claim, with addresses cited to the decomp build:
[`agent_docs/verified.md`](../../../agent_docs/verified.md).

**Written 2026-08-18**, after this adapter had been shipping for a week. It was previously argued
that a `documentation.md` was unnecessary for a game with a decompilation. That was overturned by
the user: a curated description of *the mechanics this adapter actually depends on* is a different
artifact from a decompilation, and "we can look it up" does not survive a session where nobody does.

## Where the player's state lives, and why one address is not enough

Emerald keeps player state in two places, and an adapter needs both:

- **`gSaveBlock1Ptr`** — a **pointer**, not a struct. The save block can relocate, so it must be
  **re-read every frame** rather than cached. Player x/y, map bank/number and warp data are read
  relative to it.
- **`gPlayerAvatar`** — a fixed struct holding how the player is currently *moving*: flags
  (including a dash/running bit), and `runningState`.
- **`gObjectEvents`** — the overworld object array, holding facing and per-object state.

The pointer/fixed-address split is the thing to remember: half the state moves, half does not.

## Movement is tile-based, with a sub-tile phase

The player occupies a tile, and moves between tiles over several frames rather than instantly.
That produces two different notions of "where the player is":

- The **tile** coordinates, which change once per completed step.
- The **visual** position, which slides between tiles during the step.

`runningState` distinguishes them, and its values were behaviour-tested in BizHawk rather than
assumed: **0 = not moving, 1 = turning in place, 2 = moving**. Turning in place is a real state in
this game — pressing a direction while stationary turns the character without changing tiles, and
it produces a `1` per direction change.

A tile is **16 pixels**.

## Which state machine is running: `gMain.callback2`

Emerald tracks what the game is currently doing as a **function pointer** — the current "callback".
Comparing it against the overworld callback (`CB2_Overworld`) is how you ask *"is the player in the
overworld right now"*, rather than inferring it from whether the data looks reasonable.

Measured behaviour worth knowing: during a door transition the callback briefly becomes a series of
warp/fade/map-load handlers and then **settles back** to the field callback. So the callback is
transient during transitions, not merely on or off.

This matters because outside the overworld the save-block pointers can be mid-update, and reading
them then returns plausible values rather than obviously wrong ones.

## Appearance: the player sprite is gender-dependent and stored in ROM

The overworld player graphics exist as separate sprite sets for the two player characters, with
**separate tables for walking and for running** — running is not the walk cycle played faster, and
treating it as such looked visibly wrong in live testing.

The adapter decodes those graphics out of the player's own ROM at runtime rather than shipping any
image (`agent_docs/licensing.md`'s assets rule).

## Maps are identified by a pair

Map identity is **bank + number**, not a single id. Neither means anything alone. Warp data (which
map a door leads to) is held in the save block.

## What is known to differ under the Archipelago randomizer

Recorded here because it is a property of *that ROM*, and the difference is real and measured:
Archipelago's Emerald patch is a full base-ROM recompile, so **fixed addresses move**. Confirmed
cases include the overworld callback, the player sprite data, and the overworld object arrays. Its
own client reads the save-block pointers, which is why those keep working.

Full citation trail, including what is and is not covered:
[`agent_docs/risks.md`](../../../agent_docs/risks.md).
