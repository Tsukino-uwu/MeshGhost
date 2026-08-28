# 2026-08-19 — Ghost collision becomes a room policy the host sets, with a client override one way only

<!-- ADR 0035. Indexed in ../architecture.md, which is the decision log front door. -->

## Amendment 2026-08-28: collision is a PER-ADAPTER capability, not a global one

**User, after TEVI:** *"not all games will have or work well with collision, its basically a per
adapter kind of thing. not a global thing i originally planned it as."*

The room policy below is not wrong, but its premise -- that every game can make a ghost solid, so
the only question is whether a room wants it -- does not hold:

- **TEVI cannot do it at all.** The ghost is a clone of the player's visual object with every
  `Collider2D` and `Rigidbody2D` stripped at creation, and the adapter does not handle
  `session_policy`. Shipping `ghost_collision: enabled` there advertised a switch that does
  nothing, which is the same shape of trap `local_game_bridge` was until the same day's fix.
- **Pseudoregalia can, and should not**: a solid ghost in a 3D platformer blocks doorways and
  ledges, so it ships disabled.
- **The Pokemon adapters can, meaningfully**, since a spawned object event is a real map object.

**What survives unchanged:** the resolution rule. `ResolveGhostCollision` disables if EITHER side
asks, so a room can turn collision OFF for everyone but can never force it ON for a player -- and a
game that cannot do it simply never does. That asymmetry is what keeps the room policy merely
optimistic rather than wrong.

**What changed in practice:** the default now lives per game, in that game's
`client-config-overrides.json`, rather than being one value every adapter receives. The room knob
remains for a host who wants it off room-wide.

**What is still owed:** an adapter that cannot honour the policy should SAY so rather than be told
and silently ignore it -- today the core logs "told the adapter" for TEVI, which is not true. That
is a bridge-contract question (a capability declaration, like `render_all_areas`) and is unbuilt.


- **Decision:** Add `server.ghost_collision`, values `"enabled"` (the default) and `"disabled"`.
  The relay advertises it in `Welcome` beside `SendHz`; the core forwards it to the adapter over a
  new `session_policy` bridge message; the adapter honours it. `"enabled"` does **not** mean
  "force collision on" — it means "each adapter's own default stands, including the places an
  adapter already makes a ghost passable". `"disabled"` is binding: no ghost blocks anything, in
  any game, at any time. A client may set `client.ghost_collision` to `"disabled"` as well, and
  **the more restrictive of the two wins** — a host can take collision away from a room, and can
  never force it onto a player who does not want it.
- **Status:** **Implemented 2026-08-19, Go side complete and confirmed with the tools.**
  `server.ghost_collision` / `client.ghost_collision` in `config.json`, `-ghost-collision` on both
  binaries, `Welcome.GhostCollision` on the wire, `bridge.SessionPolicy` down to the adapter.
  `contract.md`'s bridge section is amended. Covered by `protocol/ghostcollision_test.go` (the
  resolution rule, every combination), `core/ghostcollision_test.go` (the full hop chain plus the
  ordering race below), and `internal/e2e/ghostcollision_e2e_test.go`, which drives the real
  `.exe`s. Full suite, `-race`, and `-count=10` on the touched packages all clean.

  **Adapters do not honour it yet** — that is the remaining half, and it is per-game work needing
  live confirmation. Until an adapter reads the message, setting this changes nothing on screen.

  **One real bug was found by building it.** The first cut pushed the policy from the `Welcome`
  handler, which runs on the relay read goroutine, while `bridge_ready` is sent on the adapter read
  goroutine — so `session_policy` could reach an adapter *before* the message that tells it the
  core is usable at all, and an adapter is entitled to discard that. It was not hypothetical: with
  the gate removed the ordering test fails on iteration 0, every run. Fixed with an `adapterReady`
  gate; the test exists because deleting the post-ready push did not fail anything, which is what
  exposed the `Welcome` path as the one actually delivering.
- **Context:** `brief.md` originally promised remote players were "non-interactive props with no
  collision"; that line was superseded 2026-08-15 when ghost collision became an opt-in per-adapter
  feature on the user's own request. It has been uneven ever since. Pseudoregalia ships
  `GHOST_COLLISION_ENABLED = true` as a deliberate feature, while TEVI's `BANDAGES.md` asserts
  "a cosmetic ghost must never collide with anything" — two shipped adapters stating opposite
  rules. Meanwhile `crowd-limits.md` recorded a Crystal ghost occupying a tile off-screen so the
  player walked into a solid character they could not see, and its entry still ends "it can still
  box the player in". The user's own yes/no call on keeping collision was deferred 2026-08-15
  pending a real two-player session, that session ran 2026-08-16, and the question was never
  re-judged — `status.md` lists it under "was blocked on a two-player session". This ADR does not
  answer that yes/no; it makes it a setting instead, which is the answer that survives either way.
- **Options considered:** (1) **Client-only** — cheapest by a wide margin, needs no contract change
  at all, and is technically sufficient because collision here is *purely local*: your game only
  ever blocks your own movement against your own copy of a ghost, and nothing about it is
  negotiated between peers (`plans.md`'s standing non-goal). Rejected because it cannot give a host
  one consistent answer for a crowded room, which is the actual request. (2) **Server-only and
  binding** — simplest to document, but leaves a player with no recourse in an `"enabled"` room.
  (3) **Server floor plus a one-way client override.**
- **Resolution:** Option 3, which is `Welcome.SendHz`'s existing idiom applied to a boolean: there,
  the relay's rate is prescriptive for a client that has not expressed a preference, but a client
  that deliberately configured a slower one keeps it, and the slower of the two wins. Here the more
  restrictive of the two wins, for the same reason — the host owns the room's rules, and a player
  owns their own comfort. Nothing new has to be invented to explain it.
- **Why a new bridge message rather than a field on `BridgeReady`:** `BridgeReady` is documented as
  deliberately carrying no payload, on the argument that anything worth knowing is "either the
  adapter's own input or none of its business". A host-set room policy is a genuine third category
  that did not exist when that was written, so the argument does not exclude it — but a one-shot
  field on the handshake would still be wrong, because the core can re-handshake with the relay in
  the background (`reconnectWithBackoff`) without the adapter ever reconnecting, and a reconnecting
  client already "re-reads the room's advertised send_hz from the new Welcome". A policy that can
  change mid-session needs a message that can be sent again. `BridgeReady`'s ordering is fine
  either way: `ConnectRelayOnAdapterHello` completes before it is sent, so the `Welcome` is already
  in hand.
- **Consequences:** It is **advisory, not enforceable.** The relay has no game knowledge and cannot
  tell whether an adapter obeyed — exactly like `send_hz`. Shipped adapters honour it; nothing
  makes them, and this must be said plainly in the host-facing docs rather than implied.

  **The cost of `"disabled"` is very uneven per game, and three of the four are not free.** TEVI is
  already there — it destroys every `Collider2D`/`Rigidbody2D` at clone time, so `"disabled"` is a
  no-op and `"enabled"` would mean nothing without changing that `Destroy` to a disable.
  Pseudoregalia is cheap and clean: one `SetActorEnableCollision(false)`, and its animation
  pipeline was built while collision was off, so nothing in the pose path reads collision state —
  but a re-enable path must re-apply `bCanBeDamaged = false` and the `ECC_WorldDynamic` retype,
  which today sit inside `if constexpr (GHOST_COLLISION_ENABLED)` and would otherwise be silently
  skipped, returning the ghost damageable.

  **Emerald and Crystal are the expensive case, and the reason is structural.** Neither adapter
  writes a collision field at all; a ghost is solid because it *is* a real engine object holding a
  tile, and map coordinates are what drive collision. There is no bit to clear. "Off" therefore
  means demoting the peer to the drawn tier — a painted overlay that loses the engine's animation,
  draw priority and occlusion. Crystal can do this today (`shouldBlock` already demotes idle and
  pushed-into peers, which is the same mechanism); Emerald needs its dormant
  `MESHGHOST_EMERALD_DRAWN_OVERFLOW` shipped on first, and that flag carries its own known
  problem — a peer crossing the spawn budget changes from solid to walk-through with nothing on
  screen explaining it.

  **This makes drawn-tier visual parity a prerequisite rather than a nice-to-have**, on the user's
  explicit call: a demoted ghost must not feel worse than a spawned one, which means occlusion,
  shadows and water reflection have to be reached for in the drawn path before `"disabled"` is a
  good experience in the two Pokemon games. Tracked separately — that is per-game rendering
  research needing live confirmation, not something this ADR schedules.

  A genuinely non-solid *spawned* ghost — keeping engine animation while not blocking — has no
  implemented path in either Pokemon game and no cited source for the field that would do it.
  Emerald's object elevation byte at `0x0b` is the candidate to research and is **uncited
  inference**; per the address rule it needs a real decomp citation before anyone writes it. If it
  works, it collapses the whole expensive case above.


---

- **Date:** 2026-08-20
- **Decision:** The Go side stays game-blind permanently — and "game-blind" is a statement about
  GAME KNOWLEDGE, not about which process does work. A client-only "hide every ghost, but still be
  one" setting therefore belongs in the **core**, as a receive-side filter.
- **Status:** accepted (user ruling)
- **Context:** Filing the hide-ghosts idea, I offered core-versus-adapter and called the core the
  cheaper place because it saves per-peer work for every game at once. The user ruled first on the
  principle: *"i never want the server/client to know anything about any game/adapter no matter
  what. it should always stay dumb no matter what new config/features we add for it ... this whole
  project is built on the server/client being its own thing, and the adapter/game being its own
  thing"* — then asked the sharper question, *"or could it be in core, and still keep server/client
  dumb? to make it reusable in other games"*.
- **Options considered:** (a) each adapter suppresses its own rendering; (b) the core stops
  delivering remote states to the bridge; (c) a relay-side policy like `ghost_collision`.
- **Resolution:** (b). (c) is wrong outright — this setting must not change what anyone else sees,
  so there is nothing for a relay to advertise or for a host to set. Between (a) and (b), the test
  the rule actually asks is *"does this code have to know anything about a specific game?"*, and
  dropping remote peer states does not: it operates on the contract's own data, exactly as the
  receive-rate cap and the cross-area filter already do. **The core can hold this and still be
  dumb.** Written once, every existing and future adapter inherits it with no per-game work, which
  is the reuse the user asked about, and the adapter's per-peer cost disappears for free because it
  never learns a peer exists.
- **Consequences:** From an adapter's side, flipping this on looks exactly like every peer leaving
  the room — a case every adapter already handles game-agnostically, so it reuses existing contract
  behaviour rather than adding any. **That is the thing to verify live before calling it done**: a
  ghost starved of updates must be torn down, not frozen in place, and the same question decides
  whether the setting can be toggled mid-session (a speedrunner practising, then running) or only
  at startup.

  **Send is untouched by construction.** The core still reports local state and still publishes it,
  so peers see you normally; only delivery of THEIR states into this machine's bridge stops. The
  relay is not involved at all.

  **The tell for a future violation, so this stays checkable:** a game name, an adapter-specific
  branch, or a field the core has to interpret rather than pass through. Any of those means the
  work moved to the wrong side of the line, however cheap it looked — and "it would be more
  efficient in the core" is precisely the argument that has to lose, because efficiency is the
  reason a game-aware core gets built by accident. The one-line form of this now sits in
  `CLAUDE.md`'s core rule.

  **The rule stated in the user's own words, 2026-08-20, and this is the version to apply:**
  *"its fine to have dumb/generic things in the server/client i guess, if it allows us to reuse
  things for other games. but i still want it to be dumb/not know how the games work"*. So the
  question to ask of any proposed Go-side feature is never "is this a feature?" but **"does it
  need to know how a game works?"** — a generic capability every adapter can reuse is welcome
  there; anything that has to understand a game is not, however small.

  **Enforced, not merely stated, since 2026-08-20:** `internal/gameblind` fails the build on a
  game name in library code, a non-generic import, a changed wire field list, or any import that
  merges server, client and adapter into fewer than three things. `testing.md` describes it.
