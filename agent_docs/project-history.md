# Project history: how MeshGhost actually got built

A retrospective, written from memory rather than derived from logs or commits. It exists
because it's fun to look back on and because it's a useful reference for scoping the next
game adapter — not as a source of truth for exact dates or facts (see `verified.md` and the
`phases/` files for that). Per-adapter build stories live in each game's own `README.md`
(`adapters/emulator/pokemon/emerald/README.md`, `adapters/emulator/pokemon/crystal/README.md`,
`adapters/tevi/README.md`, `adapters/pseudoregalia/README.md`) — this file covers only the part before any adapter
existed.

## Pre-planning / concept (~3-5 hours)

Before any code existed, this much time went into figuring out "how could this work at all":
what pieces were needed (relay, client, adapters), how they should be split up, and what
language/stack to build each in. Go was picked for the client/server specifically for
cross-platform support (Windows/Linux/Mac) without per-platform builds.

This estimate covers only the initial concept/shape work. It does not include the ongoing
refactors and changes made to things like the release packaging along the way while building
the actual adapters — those are scattered across the `phases/` files and commit history
instead.

See `brief.md` for what that planning concluded (the vision and rationale it produced), and
`contract.md` for the interface it eventually settled into.

## The six Phase 0 questions, and how each was closed (moved out of `contract.md`, 2026-09-02)

Kept as dated history rather than deleted, because the answers are the contract. They sat at the end of
`contract.md` until 2026-09-02; a durable artifact is for what IS, and this is how it came to be.

All six were answered against a running game, per the verification standard in `CLAUDE.md` —
each carries its decision and the `verified.md` entry that settled it below. Kept as dated
history rather than deleted, because the answers are the contract. Nothing here is still open;
a *new* question of this kind gets closed the same way it was then, against a running game and
never from memory.

- [x] Exact Emerald `area_id` encoding: map bank + map number, concatenated how? **Decided:**
      `"{mapGroup}:{mapNum}"`, e.g. `"0:9"`, `"1:4"` — plain decimal pair joined by `:`.
      `mapGroup`/`mapNum` alone are sufficient: confirmed stable within a map and confirmed
      changing correctly on every real map transition tested. See `agent_docs/verified.md`
      (`gSaveBlock1Ptr`/map-transition entries).
- [x] First Emerald `anim` tag set: `idle`, `walking`, `running` — is that sufficient for a
      visible Phase 2 ghost, or is facing needed as its own tag? **Decided:** those three are
      sufficient, carried by `runningState`/`dash`: `runningState=0` → `idle`,
      `runningState=2 & !dash` → `walking`, `runningState=2 & dash` → `running`.
      `runningState=1` (turning) does not need its own tag — it's a facing change with no
      position change, already carried by `orientation`. See `agent_docs/verified.md`
      (`gPlayerAvatar`/dash entries).
- [x] Is `orientation` used for Emerald, or is facing carried in `extras` instead? **Decided:**
      `orientation` carries facing direction as `"south"`/`"north"`/`"west"`/`"east"` (matching
      `pokeemerald`'s own `DIR_*` naming for direct traceability), read from
      `gObjectEvents[gPlayerAvatar.objectEventId].facingDirection`. See `agent_docs/
      verified.md` (`gObjectEvents`/facing-direction entry).
- [x] Local snapshot frequency: **answered, not by confirming the brief's 10Hz hypothesis, but
      by superseding it.** The real enforced rate is `core.DefaultMinSendInterval` = **~67ms /
      15Hz** (2026-09-01; 50ms / 20Hz from Phase 6 until then — the 20 was headroom arithmetic
      under the relay's 120 msg/sec cap, never a claim about the right rate). **15 is measured**:
      a rung-by-rung ladder watched on screen plus a blind 15-vs-20 A/B scored at chance, on
      Pseudoregalia as the most sample-hungry adapter — `adapters/pseudoregalia/VERIFIED.md`. The
      brief's 10Hz is now known to sit *below* the visible floor. Operator-configurable per relay
      (`server.send_hz`, 10–100) — see the subsection above and the ADR in `architecture.md`.
- [x] `seq`/`timestamp` semantics: does `seq` reset on reconnect? Is `timestamp` wall-clock
      or client-relative? **Decided (already true of the implementation, not a new choice):**
      `seq` is a `Core`-lifetime counter (`atomic.AddUint64(&c.seq, 1)`) that never resets —
      a reconnect gets a fresh `player_id` anyway per the 2026-08-13 ADR, so this was never
      actually ambiguous. `timestamp` is unambiguously wall-clock
      (`time.Now().UnixMilli()`), not client-relative — see the packet-schema table above for
      why that matters more than it sounds.
- [x] What does `get_local_state()` return when the player is in a menu, cutscene, or other
      non-renderable state — `nil`, or a state with a sentinel `anim`? **Decided:** position
      stayed valid through every pause menu, dialogue, forced-movement cutscene, warp, and
      battle tested — none of those warrant `nil`. **Revised 2026-08-19:** "not in the game
      yet" does, and it is a wider state than the pointer test first used for it. The player
      sitting at Emerald's CONTINUE screen has `gSaveBlock1Ptr` already populated, so the
      adapter was broadcasting their last save point while they were in the main menu — a
      ghost of them standing in the world they are not in. The user's answer: a ghost is only
      shown "when you are actually in game". So the rule is a LATCH, not a per-frame test —
      it opens the first frame the player is confirmed in the overworld and closes only when
      the game is back at the title screen with no save loaded, which keeps every menu,
      cutscene, warp and battle above sending exactly as decided. **Leaving the game must be
      announced, not merely gone quiet about:** the core holds a peer's newest sample forever
      (`core/interp.go`'s `remoteBuffer.at` never expires one), so an adapter that just stops
      sending leaves its ghost frozen on every other screen. The adapter drops its bridge
      connection instead, which the core already turns into a relay leave and every peer into
      a despawn (`core_test.go`'s `TestBridgeDisconnectDespawnsForPeer`), and reconnects
      immediately. Separately, the adapter should debounce one frame around any
      `mapGroup`/`mapNum` change: a transient
      placeholder read was observed exactly at the moment the save block's pointer relocates
      during some (not all) transitions — see `agent_docs/verified.md`'s "placeholder-glitch"
      entries. This is an adapter-side guard, not a reason to return `nil` from the core's
      perspective.
