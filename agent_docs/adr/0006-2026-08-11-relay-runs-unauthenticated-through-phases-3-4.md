# 2026-08-11 — Relay runs unauthenticated through Phases 3-4; room code is the recorded end goal

<!-- ADR 0006. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-11
- **Decision:** Relay runs without authentication through Phases 3–4; room code + shared
  secret is the recorded end goal for later.
- **Status:** superseded 2026-08-14 by the room-code/version-check ADR below, which built the
  recorded end goal. Kept as the record of why no-auth was right for Phases 3–4.
- **Context:** Phase 4 puts a relay on the open internet with no connection or auth model
  defined anywhere in the original docs.
- **Options considered:** no-auth self-hosted (simplest, least friction for proving the
  transport/schema work), room code + shared secret self-hosted (better end-user story, more
  to build before Phase 3 can start), a publicly hosted always-on relay (best UX, adds
  hosting cost, abuse surface, and a privacy/ToS obligation the project otherwise avoids
  entirely).
- **Resolution:** No-auth, direct IP:port for Phases 3–4, to keep the loopback and
  two-player milestones focused on schema/transport correctness. Payload size caps and rate
  limits (see `contract.md`) ship from day one regardless — those defend against a malformed
  peer, not an attacker, and cost nothing to add now.
- **Consequences:** Phase 4's "first real milestone" is not yet safe to run on a relay
  reachable by strangers. Room code + shared secret is scheduled as its own piece of work
  after Phase 4, before any relay is exposed beyond a friend the host directly gave an
  address to.
