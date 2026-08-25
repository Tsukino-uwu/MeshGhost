# 2026-08-11 — Second target game is TEVI, not Ori: Will of the Wisps

<!-- ADR 0005. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-11
- **Decision:** Second target game is TEVI, not Ori: Will of the Wisps.
- **Status:** accepted
- **Context:** The brief and the original `plans.md` named Ori: Will of the Wisps as the
  second game, but neither Ori title is owned, and the `adapter/games/` scaffolding had
  drifted to include an unrelated Ori title (Blind Forest) plus an untracked TEVI folder.
- **Options considered:** Ori: Blind Forest (owned-status same problem, older Unity build,
  matches the stray folder), Ori: Will of the Wisps (matches the brief, not owned), TEVI
  (owned, Unity, movement-focused 2D platformer — same genre fit as the Ori reasoning),
  leaving the second slot undecided.
- **Resolution:** TEVI. It's owned and fits the same "movement-focused, genre where ghost
  co-op shines" reasoning the brief used for Ori and for Pseudoregalia.
- **Consequences:** `agent_docs/brief.md` section 4 keeps the original Ori reasoning as
  historical context; `adapters/tevi/` is the live second-game folder; `adapters/oribf/` was
  kept as a candidate, not deleted, in case Ori is picked up later. **Amended 2026-08-25:** that
  folder is now deleted and the candidate lives in `ideas.md` instead — it never held anything but
  a README, and an empty directory under `adapters/` reads as an adapter in progress. TEVI's own IL2CPP/Mono
  status is unverified and must be checked at Phase 6, not assumed by analogy to Ori.
