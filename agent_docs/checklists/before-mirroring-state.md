# Before mirroring game state onto a ghost

The 1:1 bar, and every way a copy has looked right and been wrong. `adapters/CLAUDE.md` carries the hard rules; this page is everything under them.

**Read the three in bold, then skim the rest: one line each, the title IS the lesson, the link is the record.**

- **Copy what the effect DOES, never the structure that does it, and never a value the game DERIVES** — run the engine's own step, read its own art, diff what you built against what it built.
- **A transition cannot answer "is anyone still here"; only a per-frame test can.** An impulse wants ordering, a hold wants the truth of its own frame.
- **The moment your mirroring writes where your detector reads, two symmetric peers form a loop.** Attribute by identity, never by proximity or count.

## Every lesson filed here

- Mirror the handler the game actually uses — Stay, not Enter/Exit (2026-08-28) — [method.md](../pitfalls/method.md)
- A probe's sample rate is not a mechanism's sample rate (2026-08-28) — [method.md](../pitfalls/method.md)
- Mirroring through SHARED state makes symmetric peers echo each other (2026-08-28) — [method.md](../pitfalls/method.md)
- When mirroring an IMPULSE and a HOLD, the hold needs the truth of its own frame (2026-08-28) — [method.md](../pitfalls/method.md)
- Overlay / sprite rendering (2D, retained-mode drawing APIs) — [by-host.md](../pitfalls/by-host.md)
- Reconstructing continuous motion from discrete, throttled position samples (Emerald sub-tile glide saga, 2026-08-14) — [by-host.md](../pitfalls/by-host.md)
- Pooled objects: detecting "spawned" by object identity silently undercounts (2026-08-16) — [by-host.md](../pitfalls/by-host.md)
- Latch event payloads to the event; don't republish them as per-tick state (2026-08-16) — [by-host.md](../pitfalls/by-host.md)
- Sampling a multi-tick spawn once attributes its stragglers to the NEXT event (2026-08-16) — [by-host.md](../pitfalls/by-host.md)
- Pooling cuts both ways: a retirement move reads as a birth (2026-08-16) — [by-host.md](../pitfalls/by-host.md)
- A spawned character renders a few pixels off its tile, forever (2026-08-18) — [by-lesson.md](../pitfalls/by-lesson.md)
- A spawned entity leaks once per zone crossing, but survives doors fine (2026-08-18) — [by-lesson.md](../pitfalls/by-lesson.md)
- Crystal: a drawn ghost paints over a FULL-SCREEN menu, because the adapter reads it as a text box (2026-08-19) — [by-lesson.md](../pitfalls/by-lesson.md)
- Crystal: the drawn tier needs a POSITIVE "is the overworld on screen", not a list of screens to avoid (2026-08-19) — [by-lesson.md](../pitfalls/by-lesson.md)
- Calibrating on OAM entry 0: the entry ORDER swaps when the sprite flips (2026-08-19) — [by-lesson.md](../pitfalls/by-lesson.md)
- Frame tiles in the tilemap are not the same thing as a panel on screen (2026-08-19) — [by-lesson.md](../pitfalls/by-lesson.md)
- "A bit choppy" cost six rewrites, because it was three separate bugs and none were where I looked — 2026-08-19 — [by-lesson.md](../pitfalls/by-lesson.md)
- Approximating the game's own art never converges — read it instead, 2026-08-19 — [by-lesson.md](../pitfalls/by-lesson.md)
- A value the game DERIVES cannot be COPIED — 2026-08-19, Emerald — [by-lesson.md](../pitfalls/by-lesson.md)
- A script's writes land between frames; the game's land inside one — 2026-08-19, Emerald — [by-lesson.md](../pitfalls/by-lesson.md)
- A world-space anchor built from a SPRITE carries the sprite's own terms — 2026-08-19, Emerald — [by-lesson.md](../pitfalls/by-lesson.md)
- A rule that is right for one graphic can be wrong for another — 2026-08-20, Emerald — [by-lesson.md](../pitfalls/by-lesson.md)
- A stable field can read zero exactly when the thing it describes is happening — 2026-08-20, Emerald — [by-lesson.md](../pitfalls/by-lesson.md)
- A character can face one way and move another — 2026-08-20, Emerald — [by-lesson.md](../pitfalls/by-lesson.md)
- A watchdog that names what it caught — 2026-08-20, Emerald — [by-lesson.md](../pitfalls/by-lesson.md)
- Emerald: a remembered riding style outlived the peer's actual one (2026-08-21) — [by-lesson.md](../pitfalls/by-lesson.md)
- Emerald: a gate written for ANIMATION also swallowed a POSITION (2026-08-21) — [by-lesson.md](../pitfalls/by-lesson.md)
- Crystal: our own ghost's OAM entries are indistinguishable from the player's (2026-08-22) — [by-lesson.md](../pitfalls/by-lesson.md)
- An animation that plays without moving the character (Crystal, 2026-08-23) — [by-lesson.md](../pitfalls/by-lesson.md)
- The player does not own OAM entries 0-3, and a priority object silently moves every painted peer (2026-08-26, Crystal) — [by-lesson.md](../pitfalls/by-lesson.md)
- The decompilation says what the engine CAN do; only a measurement says what the game DOES (Crystal, 2026-08-26) — [by-lesson.md](../pitfalls/by-lesson.md)
- A stale coordinate is indistinguishable from a live one, and the game may never clear it (Crystal, 2026-08-26) — [by-lesson.md](../pitfalls/by-lesson.md)
- A field that describes "the most recent X" cannot describe "every X on screen" (Crystal, 2026-08-26) — [by-lesson.md](../pitfalls/by-lesson.md)
- A gate that defers a decision must also freeze the evidence it reads (Crystal, 2026-08-26) — [by-lesson.md](../pitfalls/by-lesson.md)
- A field name that lies, protected by the engine only ever using it on the player (Crystal, 2026-08-26) — [by-lesson.md](../pitfalls/by-lesson.md)
- A latch that survives one phase of a two-phase effect will fire in the other — [by-lesson.md](../pitfalls/by-lesson.md)
- Gating a shared graphic on the graphic ALONE, when one state borrows it — [by-lesson.md](../pitfalls/by-lesson.md)
- An engine sequence with a WARP in the middle goes quiet, and quiet is not "finished" — [by-lesson.md](../pitfalls/by-lesson.md)
- AN ID IS NOT PORTABLE, AND NEITHER IS A CONSTANT — one table further along than an address — [by-lesson.md](../pitfalls/by-lesson.md)
- A bypass that freezes a countdown instead of spending it (Crystal, 2026-08-27) — [by-lesson.md](../pitfalls/by-lesson.md)
- Proximity is not identity, and a loopback rig makes that worse (Pseudoregalia, 2026-08-27) — [by-lesson.md](../pitfalls/by-lesson.md)
- Never strip a component you do not OWN: a reflected walk that WRITES must prove each value's outer chain reaches the swept actor — `cachedMesh` was the player's body (Pseudoregalia, 2026-09-05) — [by-lesson.md](../pitfalls/by-lesson.md)
