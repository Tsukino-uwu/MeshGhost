# 2026-08-11 — Reserve an opaque event plane and a `features` list, and implement neither now

<!-- ADR 0007. Indexed in ../architecture.md, which is the decision log front door. -->

- **Date:** 2026-08-11
- **Decision:** Reserve an opaque event plane and a `features` capability list in the
  contract, for potential deeper per-game sync later. Do not implement either now.
- **Status:** accepted
- **Context:** The user asked whether the architecture would trap MeshGhost as visual-only
  forever, or whether a specific game's adapter (Emerald, concretely) could later go deeper —
  trading, battling — without a redesign. Two things about the contract are cheap to change
  now and effectively impossible to change once real clients exist: a capability-negotiation
  field, and a reserved addressed-message type.
- **Options considered:** (1) docs-only, no schema change — cheapest today, but capability
  negotiation genuinely cannot be retrofitted after clients ship, since an old client has no
  way to say what it does or doesn't support; (2) reserve the schema fields but implement no
  routing — costs ~10 lines, keeps the door open, nothing is built without a consumer to
  validate it against; (3) reserve and also implement relay-side event routing at Phase 3 —
  the routing itself is cheap to add on top of the forwarding path the relay needs anyway,
  but with no adapter yet sending an event, it would be unexercised code with nothing to
  watch happening on screen, which is exactly what this project's own verification standard
  (`CLAUDE.md`) rules out.
- **Resolution:** Option 2. Add `features` to `hello` and reserve (but do not implement) an
  `event` message type with a `to` addressee field, documented in `agent_docs/contract.md`'s
  Extensibility section. Shape — but do not feature-gate — the Phase 3 relay forwarding path
  to take a recipient set, so wiring in real event routing later is a small localized change
  instead of a rewrite.
- **Consequences:** The state plane (cosmetic `state` messages) stays exactly what it is and
  never grows new fields for deeper features. Any future deep-sync feature for a specific
  game lives entirely inside that game's adapter, sending opaque event payloads the core and
  relay route but never parse — the same opacity discipline already applied to `area_id` and
  `anim`, extended to messages. This does **not** authorize building anything past the
  cosmetic ghost; the brief's "no shared or authoritative world state" non-goal
  (`agent_docs/plans.md`) remains the default posture. Lifting it for a specific game and
  feature is a separate, deliberate decision that needs its own ADR — including how it
  handles game-memory writes and save-corruption risk, since that is a different risk
  category than anything reading-only work carries. See the depth ladder in
  `agent_docs/plans.md` for the tiers this opens up and where the real cliff is.

  This reservation has a ceiling, and the two reasons something sits above it are different in
  kind, not just degree — a future session must not conflate them. **Tier 3** (trading,
  battling — bounded, consensual, episodic sessions) is *unapproved but architecturally
  possible*: the event plane above is exactly the mechanism it would use, and building it only
  needs its own per-feature ADR. **Full continuous co-op** ("everything synced") is
  *architecturally excluded*, not merely unapproved: the relay has no authority model and
  deliberately never will, since giving it one would require the relay to understand the game,
  which is the one thing this whole architecture exists to prevent. No ADR can lift that one
  the way an ADR can lift the Tier 3 non-goal — it would require a different relay design, at
  which point it is a different project. See `agent_docs/plans.md`'s depth ladder for the full
  reasoning.
