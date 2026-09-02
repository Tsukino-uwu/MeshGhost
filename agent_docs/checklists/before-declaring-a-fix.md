# Before declaring a fix

A fix is a claim. These are the ways a claim has looked true here while being false.

**Read the three in bold, then skim the rest: one line each, the title IS the lesson, the link is the record.**

- **Run the same test without the fix, and reproduce a regression on the last-known-good build FIRST.** A regression report is a hypothesis; bisect real commits; a flag flip is not a revert ([method.md](../pitfalls/method.md)).
- **Two guessed fixes failing the same way is a stop signal.** After ~3 single-variable negatives, run the union, then subtract from a working state.
- **Validate on the REPORTED path, not its neighbour**, and ask what is true where a fix works — a fix named after a place gets re-found somewhere else.

## Every lesson filed here

- Diagnostic methodology — [method.md](../pitfalls/method.md)
- A reference is not the thing — clearing a pointer removes nothing (2026-08-27) — [method.md](../pitfalls/method.md)
- A deploy that reports success can deploy nothing — three ways, one loop (2026-08-28) — [method.md](../pitfalls/method.md)
- Failure signatures — [method.md](../pitfalls/method.md)
- Two draw paths, and a fix applied to one of them — 2026-08-20, Emerald — [by-lesson.md](../pitfalls/by-lesson.md)
- An adjustment that changes nothing is evidence about the MECHANISM — 2026-08-20, Emerald — [by-lesson.md](../pitfalls/by-lesson.md)
- Emerald: the seam-crossing pop was the CORE's, and every adapter instrument measured innocent (2026-08-20) — [by-lesson.md](../pitfalls/by-lesson.md)
- Emerald: the frame rate went to ~1fps, and it was the ALLOCATOR, not the drawing (2026-08-21) — [by-lesson.md](../pitfalls/by-lesson.md)
- Emerald: THE PAIR was wrong -- and fixing it did NOT clear the symptoms (2026-08-21) — [by-lesson.md](../pitfalls/by-lesson.md)
- A fix named after WHERE it was found will be re-found somewhere else (Emerald, 2026-08-21) — [by-lesson.md](../pitfalls/by-lesson.md)
- An explanation that only fits your own case is not an explanation (Emerald, 2026-08-21) — [by-lesson.md](../pitfalls/by-lesson.md)
- A clip's GATE is more dangerous than the clip (Emerald, 2026-08-21) — [by-lesson.md](../pitfalls/by-lesson.md)
- The dev rig's update rate is part of the experiment (2026-08-21) — [by-lesson.md](../pitfalls/by-lesson.md)
- The rig ran the SHIPPED interpolation while the test needed none (Crystal, 2026-08-22) — [by-lesson.md](../pitfalls/by-lesson.md)
- A cache whose comment claims it is invalidated, and nothing ever clears it (Crystal, 2026-08-25) — [by-lesson.md](../pitfalls/by-lesson.md)
- A cache with an invalidation comment and no invalidation (Crystal, 2026-08-25) — see by-host — [by-lesson.md](../pitfalls/by-lesson.md)
- A fix validated on the neighbouring path, not the reported one (Crystal, 2026-08-26) — [by-lesson.md](../pitfalls/by-lesson.md)
- Three fixes in one day attached to a trigger that was a subset of the event (Crystal, 2026-08-26) — [by-lesson.md](../pitfalls/by-lesson.md)
- A regression report is a hypothesis, not a verdict — bisect before accepting blame (2026-08-27) — [by-lesson.md](../pitfalls/by-lesson.md)
- A refusal on safety grounds is still a claim, and claims get checked (Pseudoregalia, 2026-08-27) — [by-lesson.md](../pitfalls/by-lesson.md)
- A fix that depends on an object being REACHABLE breaks when you change that object's LIFETIME (Pseudoregalia, 2026-08-29) — [by-lesson.md](../pitfalls/by-lesson.md)
- A diagnostic sweep can be load-bearing: check what it does when it is NOT armed (Pseudoregalia, 2026-08-30, OPEN) — [by-lesson.md](../pitfalls/by-lesson.md)
- Six hypotheses before opening the crash dump (Pseudoregalia, 2026-08-30) — [by-lesson.md](../pitfalls/by-lesson.md)
- A dozen single-run A/Bs against an intermittent bug (Pseudoregalia, 2026-08-31) — [by-lesson.md](../pitfalls/by-lesson.md)
- A blind A/B convicts the renderer, not the knob — the "15Hz tell" fired on 20Hz rounds (Pseudoregalia, 2026-09-01, CLOSED) — [by-lesson.md](../pitfalls/by-lesson.md)
