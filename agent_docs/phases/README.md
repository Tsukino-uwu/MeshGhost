# Phases — the index

<!-- line-cap: 100 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**One file per phase, kept after the phase ends as a work log.** `status.md` and `plans.md` are
the current-state summary; these are not. **Read every one as a dated record, not as current
fact** — a phase file says what was true while that phase ran, which is exactly why the paths in
it are left as written rather than rewritten. Each affected file carries that note at its own top.

This index exists because `preflight.ps1` now fails a phase file that is missing from it. Every
other required-reading class in this repo — ADRs, pitfalls, VERIFIED entries — already had an
index and a check; phase files were the one class with neither, so a new one could be added and
never referenced from anywhere. Added 2026-08-25.

| Phase | What it covers | Status |
| --- | --- | --- |
| [phase1.md](phase1.md) | Emerald read-only verification — the first addresses, confirmed by walking. | Done |
| [phase2.md](phase2.md) | Fake ghost, no network — proving the screen-position maths offline. | Done |
| [phase3.md](phase3.md) | Loopback — one client sending state and rendering it back to itself. | Done |
| [phase4.md](phase4.md) | Two players — joins, drops, and `area_id` mismatch. | Done |
| [phase5.md](phase5.md) | Extract the template — the core running against a fake adapter, no game. | Done |
| [phase5_5.md](phase5_5.md) | A real, gender-correct Emerald sprite in place of the magenta box. | Done |
| [phase6.md](phase6.md) | Second game: TEVI (Unity/Mono, BepInEx). | Done |
| [phase7.md](phase7.md) | Third game: Pseudoregalia (UE5, UE4SS). The largest record here. | Done |
| [phase8.md](phase8.md) | Emerald, dedicated — the post-5.5 animation and effect work. | Parked 2026-08-21 |
| [phase9.md](phase9.md) | Fourth game: Pokémon Crystal (GBC) — the first **spawned** ghost rather than a drawn one. | **In progress** |

**Adding one:** create `phaseN.md`, give it the dated-record note at the top, and add its row
here. Numbering follows `plans.md`'s roadmap, and a `.5` is legitimate — Phase 5.5 was real work
that did not warrant its own integer.
