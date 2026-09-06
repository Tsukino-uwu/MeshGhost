# Before writing or arming a probe

A probe is a question asked of a running game, and most fail as questions. `/write-a-probe` sequences the method; this page is what has already gone wrong.

**Read the three in bold, then skim the rest: one line each, the title IS the lesson, the link is the record.**

- **A probe can break the thing it measures**, and then every reading agrees with itself — audit its cost, keep it off by default, re-run with it off before believing anything.
- **A filter applied before you look is a guess about the answer.** Dump everything at a rare EVENT; filter while reading, never before; state what the instrument CANNOT see.
- **Unload anything that drives input or writes memory before judging a report** — a loaded probe is a suspect in every later symptom, and a writing probe that half-matches corrupts the rest.

## Every lesson filed here
- **A count of the classes you named cannot find a leak of a class you did not** — census EVERY object by class against a baseline first; and a Lua error inside `ForEachUObject` aborts the game, so its callback only appends ([pitfalls/by-lesson.md](../pitfalls/by-lesson.md), 2026-09-06).
- **To dump an object, never dereference what its properties point at** — address plus declared class is the safe form, and it is built: `adapters/pseudoregalia/probes/probe_dump/` (2026-09-06).
