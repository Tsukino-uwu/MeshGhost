# Before spawning or touching an actor in Unreal

`adapters/pseudoregalia/CLAUDE.md` loads on contact and carries the host rules (threading, hooks, reflection, lifetimes). This page is the rest.

**Read the four in bold, then skim the rest: one line each, the title IS the lesson, the link is the record.**

- **Never destroy anything from inside a game UI callback — the pause menu's Reset click included.** Drop handles at LoadMap PRE and let the level take them; the reset hook's own destroy-at-click was the instant reset crash from 2026-08-30 to 2026-09-05, and it only ever armed by accident.
- **A runtime-created component carries its CLASS DEFAULT until you overwrite it** — blank it at creation, not where you would normally write.
- **A cosmetic ghost must never fire the world's triggers**, and spawn-time overlaps fire inside `SpawnActor` — suppress on the class template around the spawn.
- **Resolve UFunctions through the class chain, never a hardcoded `/Script` path** — the miss is silent.

## Every lesson filed here

- Never destroy anything inside the game's own Reset click — the hook's destroy WAS the instant crash, hidden since 2026-08-30 by arming-by-accident (Pseudoregalia, 2026-09-05) — [by-lesson.md](../pitfalls/by-lesson.md)
- A ghost pawn steals the player's audio attenuation listener, and takes it to the grave (2026-09-04) — [by-lesson.md](../pitfalls/by-lesson.md)
- A corrective SECOND call belongs in the POST hook -- in PRE the engine overwrites it; better still, rewrite the argument (2026-09-04) — [method.md](../pitfalls/method.md)
- A hardcoded /Script path finds nothing and says nothing — resolve UFunctions through the class chain (Pseudoregalia, 2026-08-28) — [by-lesson.md](../pitfalls/by-lesson.md)
- If it must never be occluded, it must be OPAQUE — no translucency priority beats a level's own planes (Pseudoregalia, 2026-08-29) — [by-lesson.md](../pitfalls/by-lesson.md)
- A runtime-created component carries its CLASS DEFAULT until you overwrite it (Pseudoregalia, 2026-08-29) — [by-lesson.md](../pitfalls/by-lesson.md)
- A billboard faces the CAMERA, not the player pawn (Pseudoregalia, 2026-08-29) — [by-lesson.md](../pitfalls/by-lesson.md)
- A cosmetic ghost fires the world's triggers, and spawn-time overlaps fire inside SpawnActor (Pseudoregalia, 2026-08-29) — [by-lesson.md](../pitfalls/by-lesson.md)
- Disabling a UE4SS mod can take TWO switches, and a reinstall re-arms both (Pseudoregalia, 2026-09-01) — [by-lesson.md](../pitfalls/by-lesson.md)
