# Before writing or arming a probe

A probe is a question asked of a running game, and most fail as questions. `/write-a-probe` sequences the method; this page is what has already gone wrong.

**Read the three in bold, then skim the rest: one line each, the title IS the lesson, the link is the record.**

- **A probe can break the thing it measures**, and then every reading agrees with itself — audit its cost, keep it off by default, re-run with it off before believing anything.
- **A filter applied before you look is a guess about the answer.** Dump everything at a rare EVENT; filter while reading, never before; state what the instrument CANNOT see.
- **An object `IsValid()` refuses is address-only** — `GetFullName()` on a pawn CDO's component template crashed the game from a "read-only" probe (2026-09-06); named property reads only, never a name, class or call ([pitfalls/by-lesson.md](../pitfalls/by-lesson.md)).
- **A Lua `RegisterHook`, even on a native function, is a suspect in a freeze** — a melee attack froze the game thread with two logging-only hooks loaded and was clean without them (2026-09-06, one negative); hooks for an event-driven mechanism are built in the C++ adapter ([pitfalls/by-lesson.md](../pitfalls/by-lesson.md)).
- **Unload anything that drives input or writes memory before judging a report** — a loaded probe is a suspect in every later symptom, and a writing probe that half-matches corrupts the rest.

- **Two UE4SS Lua wrappers for one object are never `==`** -- a probe that acts on "the other pawn" proves identity by `GetAddress()` or FName, never by `~=`, and logs the chosen pawn beside the player's before its first action; three input events reached the player before that was learned ([pitfalls/by-lesson.md](../pitfalls/by-lesson.md), 2026-09-08).

## Every lesson filed here
- **A `ForEachProperty`/`ForEachFunction` callback must return NOTHING** -- UE4SS stops the walk on any returned value, `false` included; and a struct with no reflected fields comes back to Lua as an empty table ([pitfalls/by-lesson.md](../pitfalls/by-lesson.md), 2026-09-08).
- **A count of the classes you named cannot find a leak of a class you did not** — census EVERY object by class against a baseline first; and a Lua error inside `ForEachUObject` aborts the game, so its callback only appends ([pitfalls/by-lesson.md](../pitfalls/by-lesson.md), 2026-09-06).
- **To dump an object, never dereference what its properties point at** — address plus declared class is the safe form, and it is built: `adapters/pseudoregalia/probes/probe_dump/` (2026-09-06).
