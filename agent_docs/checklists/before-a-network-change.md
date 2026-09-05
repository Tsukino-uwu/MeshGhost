# Before a change to the core, relay, bridge, or any handshake

The Go side is confirmed with tools, never by watching. These are the shapes the tools have missed.

**Read the three in bold, then skim the rest: one line each, the title IS the lesson, the link is the record.**

- **Nothing that can block goes before a handshake completes**, and every step that PRODUCES the answer is gated on the transport, never on the answer.
- **When one component blames another, read the accused side's log at the accusing timestamp** before believing either.
- **A wrapper that embeds an interface hides every optional method behind it** — when you wrap a `net.Conn` (or any interface), assert on the WRAPPED result for each method the code reaches by type assertion (`WriteUnreliable`), in a test, the day you write it; and read the core's `transit:` and `buffer dry` stats before touching interp.
- **Grep who DERIVES from a constant before changing it**, keep interp at or above the link's jitter, and put anything a renderer must draw smoothly in `position`, never `extras`.

## Every lesson filed here

- Gating a handshake on its own result (deadlock, twice in one day) (2026-08-16) — [method.md](../pitfalls/method.md)
- Owning a live core you cannot reach — a walk that never advances past an empty port (2026-08-28) — [method.md](../pitfalls/method.md)
- An answer that ARRIVED and was never READ -- a control-plane message parsed behind a gameplay gate (2026-08-28) — [method.md](../pitfalls/method.md)
- An interpolation delay below the link's jitter converts smoothing into chop (2026-08-28) — [method.md](../pitfalls/method.md)
- An error names its LIMIT, not its cause — and two layers can hold different limits (2026-09-01) — [method.md](../pitfalls/method.md)
- An embedded-interface wrapper hid WriteUnreliable, and the relay forwarded every state on the stream from 01:28 to 21:45 (2026-09-02) — [method.md](../pitfalls/method.md)
- Running two instances of the same emulator/game silently collide on a shared default port — [by-host.md](../pitfalls/by-host.md)
- A bridge port pinned in the environment cannot pin an ALREADY-RUNNING instance (2026-08-19) — [by-lesson.md](../pitfalls/by-lesson.md)
- `extras` is opaque, so nothing that must be SMOOTH can ride in it (2026-08-21) — [by-lesson.md](../pitfalls/by-lesson.md)
- Crystal: the drawn tier's stutter was never in the drawing (2026-08-22) — [by-lesson.md](../pitfalls/by-lesson.md)
- Interpolating a quantity that only moves in whole steps (Crystal, 2026-08-23) — [by-lesson.md](../pitfalls/by-lesson.md)
- A closed port may never refuse — ask "can I bind it", not "did it refuse me" (Pseudoregalia, 2026-08-27) — [by-lesson.md](../pitfalls/by-lesson.md)
- A readiness flag sampled before the call that sets it drops everything arriving with the handshake (Pseudoregalia, 2026-08-28) — [by-lesson.md](../pitfalls/by-lesson.md)
- The turn direction of a fast tumble is not in the samples — three renderers watched, write-through wins (Pseudoregalia, 2026-09-01, CLOSED) — [by-lesson.md](../pitfalls/by-lesson.md)
- A declared-but-never-enforced constant gets calibrated by nobody (Pseudoregalia, 2026-09-01, CLOSED) — [by-lesson.md](../pitfalls/by-lesson.md)
- Interp is sized by the link's wobble plus loss holes, never by raw ping (cross-game, 2026-09-01, CLOSED) — [by-lesson.md](../pitfalls/by-lesson.md)
- A derived constant transmits a change to places nobody reasoned about (Go side, 2026-09-01, CLOSED before shipping) — [by-lesson.md](../pitfalls/by-lesson.md)
- A final message followed by Close() is delivered only SOMETIMES: unread peer data turns the close into a reset — use `CloseGracefully` (relay, 2026-09-05, CLOSED) — [by-lesson.md](../pitfalls/by-lesson.md)
