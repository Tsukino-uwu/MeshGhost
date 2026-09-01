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
| [phase8.md](phase8.md) | Emerald, dedicated — the post-5.5 animation and effect work. | Reopened 2026-08-26 (Fly, boat) |
| [phase9.md](phase9.md) | Fourth game: Pokémon Crystal (GBC) — the first **spawned** ghost rather than a drawn one. | **In progress** |
| [phase10.md](phase10.md) | The online stack: relay, client core, protocol, transports — one component log for the whole Go side, backfilled to the repo's start. | **Open-ended by design** |

**Adding one:** create `phaseN.md`, give it the dated-record note at the top, and add its row
here. Numbering follows `plans.md`'s roadmap, and a `.5` is legitimate — Phase 5.5 was real work
that did not warrant its own integer.

**A phase file is the FULL history of its adapter — keep it fed while the work happens** (the
user's call, 2026-09-01). Every phase file above had gone days-to-weeks stale while the work was
recorded only in VERIFIED/pitfalls; each now carries a dated catch-up section at its end, and the
next session should append to the phase file in the same pass that closes the work, not later.

**Go-side (core/relay/protocol/transport) work logs in [phase10.md](phase10.md)** — created
2026-09-01 on the user's call, the same way Emerald got its own file (phase 8) after being built
mixed into phases 1-5.5. ONE file for server and client together, deliberately: nearly every
Go-side event spans both, so two files would double-write or file arbitrarily. It is the
timeline; the detail stays in the ADRs and the topic docs it points at. **Phase 11 onward is
reserved for the fifth game and beyond.**
