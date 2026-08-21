# MeshGhost roadmap

## Overview

MeshGhost is an online multiplayer layer for single-player games. Each player runs an
independent copy of the game, and the state networked *by default* is enough to render a
cosmetic ghost: location, area, and animation. Deeper planes exist as of 2026-08-17 but are
opt-in and used by no adapter — see `beyond-cosmetic.md`. Rationale in `agent_docs/brief.md`.

The architecture is split into: relay server (game-agnostic), core client (game-agnostic),
adapter contract (thin boundary), per-game adapters (game-specific rewrite). Full contract
detail lives in `agent_docs/contract.md`.

Target games: **Pokémon Emerald** (BizHawk, first) → **TEVI** (Unity, second) →
**Pseudoregalia** (UE5, third) → **Pokémon Crystal** (BizHawk, fourth — Phase 9, shipping since
2026-08-18). **Four adapters ship.** See `agent_docs/architecture.md`'s decision log for why
TEVI replaced the brief's original Ori: Will of the Wisps pick.

## Non-goals for early work

- No shared gameplay state, physics, or collision *synchronization*. (Pseudoregalia's ghost has
  been physically solid since 2026-08-15 — see Phase 7 — but that is a purely local capsule on a
  cosmetic ghost; nothing about collision is negotiated or replicated between peers. Narrowed
  2026-08-17: `world.v1` gives the relay a place to *hold* shared opaque entity state and hand it to
  a successor host, which is mechanism rather than gameplay — it neither simulates nor interprets
  anything, and no adapter uses it. The non-goal still stands as written: nothing about physics or
  collision is negotiated between peers.)
- No game-specific rendering logic inside the core.
- **No ROM patch, in any adapter, ever** — emulator adapters are Lua-only, because never touching
  the ROM is exactly what lets MeshGhost run on top of an Archipelago seed or a randomizer. See the
  2026-08-21 ADR in `architecture.md` for the full reasoning and what it costs us.
- No adapter transport or socket handling — adapters speak only to the local bridge.
- ~~No production binary encoding or performance optimization before the contract is stable.~~
  **Amended 2026-08-18, on the user's explicit call.** Efficiency is now a standing goal, not
  something deferred until it hurts: *"we should always strive for improvement/performance not
  being stale and inefficent or avoiding new/modern methods... we should always try to lower the
  bandwidth/cpu usage whenever possible."* See "Efficiency is a standing goal" below. The half
  that survives is the *sequencing* one — do not churn the wire format while the contract is
  still moving — not the idea that small savings are beneath bothering with.
- No second-game adapter until Phase 5 validates the template.

### Efficiency is a standing goal — and the size of the win is not the test

Recorded 2026-08-18, on the user's call, as the general stance for all server/client networking
work rather than a decision about one feature.

**No saving is too small to take.** A 0.1% reduction is a real win once a server carries many
players across many games, and the reflex to dismiss a small percentage is how a system ends up
stale and inefficient. Prompted by exactly that: a design note proposed a "under ~20% and it is
not worth it" threshold for relay-side area filtering, and the user rejected the framing outright.
**Do not gate an optimization on how big the win is.** Gate it on risk and on the one constraint
below.

**The one hard constraint: it must not make the adapters or the games run worse.** The point is to
make everything better overall, not to move cost from the network onto the game thread. A
compression scheme that costs frame time, a filter that adds per-tick work in an adapter, a diff
that needs a full re-marshal per frame — those fail this test even if they cut bytes, and they run
straight into the standing rule that a diagnostic must not break the thing it measures. Bandwidth
and CPU are both on the "lower it" side of the ledger; game smoothness is not currency to spend.

**We must not be the reason a big server is impossible.** User, 2026-08-18: *"Im probly never
going to host a 1k+ ppl lobby myself, but i don't want our server/client to be the reason someone
couldn't be able to do that if they want to."* So the target is not "8 players is our size" —
`DefaultMaxClients = 8` is a safe default for a home uplink and explicitly *"not because 9 would
break something"* (`packaging/release/README.txt`). The ceiling should be the operator's hardware,
never an avoidable choice of ours.

This reframes cross-area filtering from a saving into a **scaling-shape change**, which matters far
more. Today the host's uplink carries `n x (n-1)` state messages — measured at 2.2 GB/hour for 8
players, 39.7 GB/hour for 32, and simply impossible at 1000. Filtering by area makes the cost
`n x (peers sharing your area)`: if a thousand players are spread over hundreds of areas, fan-out
per sender is a handful rather than 999, and the curve stops being quadratic in total population.
**That is the difference between "8 is the practical limit" and "the limit is how many people are
standing in the same room."** No amount of shrinking a state line does that; only not sending it
does.

**Where the ceiling is allowed to live: in the game, never in us.** User, 2026-08-18: *"the only
limitation should be a free limit / lag in game due to having to many players etc. it should be a
per adapter issue. not a server/client issue."*

So a room's practical size should be decided by what the GAME can do — how many ghost actors the
engine will render before the frame rate suffers, how many object-event slots a ROM has, what a
sprite table can hold. Those are real, per-adapter, and legitimately different per title; Emerald's
object-event slots and Pseudoregalia's actor cost are not the same ceiling and should not pretend
to be. **What must never be the binding constraint is `core`, `relay`, `transport` or the wire
format.** If someone's session tops out, the honest answer should be "your game cannot draw more
than that", not "our relay could not carry it."

Two consequences worth stating, because they are easy to get backwards:
- `DefaultMaxClients` is a **safe default for a home uplink**, not a statement about the software's
  capability, and its doc comment should keep saying so.
- A per-adapter limit belongs in that adapter's own docs (its `README.md` / `documentation.md`) as a
  measured game fact, not as a protocol constant. The Go side should not learn a per-game number —
  that would be `if game == "emerald"` by another name, which `CLAUDE.md` forbids outright.

**Modern methods are in scope**, not avoided out of conservatism — subject to the same constraint,
and to the contract-stability sequencing above.

What this does NOT license: breaking the contract silently, optimizing on a guess instead of a
measurement (measure first — that is why the cross-area counters in `relay/introspect.go` exist),
or trading debuggability away wholesale. `contract.md`'s "JSON until it hurts" still stands as the
*default format* decision; it is no longer a reason to decline a cheap saving elsewhere.
- ~~No relay authentication work before Phase 4 ships on no-auth~~ — **superseded 2026-08-13,
  done 2026-08-14**: Phase 4 shipped 2026-08-11; relay/core safety became the explicit next
  priority and room-code auth is now built, see "Room codes / relay safety" below. Kept struck
  through, not deleted, so the original reasoning (don't build room codes early just because
  they're the eventual goal) stays legible as a past decision, not silently erased.
- No emulator memory *writes* or save-state editing — MeshGhost reads game memory and does
  not write it, today. This is the current posture, not a permanent philosophical stance:
  whether it ever changes (see "Depth beyond the cosmetic ghost" below) is pending an actual
  Archipelago-coexistence test, not decided in the abstract. Until that test happens and a
  specific feature is deliberately approved via an ADR in `architecture.md`, this rule holds
  without exception.
  **First exception granted 2026-08-17, by exactly that route** — the Crystal adapter spawns a
  real object event rather than drawing an overlay, approved by the user and recorded as an ADR in
  `architecture.md`. **Extended to Emerald 2026-08-18**, by the same route and with its own ADR:
  Emerald's shipped adapter now spawns a real object event too, on a vanilla ROM, and keeps the
  overlay for a patched one. So the exception covers **both BizHawk Pokémon adapters**, not
  Crystal alone. It is still **narrow**: those two games only, live RAM only, cosmetic
  only, and the adapter must positively identify the ROM before writing — because Archipelago's
  Crystal patch rearranges WRAM non-uniformly, so a write to a moved address corrupts rather than
  fails (`verified.md`). **Amended 2026-08-18 on the user's call: identification is a *warn*, not
  a *refuse*.** No ROM is refused by default; the adapter always says which build it found, and
  `MESHGHOST_CRYSTAL_STRICT=1` restores refusal for anyone who wants it (`verified.md`).
  **Archipelago's standing is settled, 2026-08-18, on the user's call: it is a real goal, but it
  comes after the original game, always.** Vanilla is what the project promises and what gets
  fixed first; a patched ROM is worked toward and treated as best-effort until it is not. So the
  coexistence test is neither waived nor a blocker on shipping vanilla work — it gates calling
  the *patched-ROM* version of a feature done, and nothing else. This resolves the tension
  between this paragraph and `phases/phase9.md` marking Archipelago in-scope: in-scope and
  second in line are not in conflict. Every other
  adapter remains read-only, and "never write a save" is untouched and absolute **for anything that
  ships**. Clarified 2026-08-18, on the user's call: a **dev-only probe may cheat**, save data
  included, because reaching a test state (surfing, a bike, eight badges) otherwise costs an hour
  of play per attempt and the tester's own save is expendable during development. The carve-out is
  a probe in `probes/`, never an adapter and never in a release; the full statement and its three
  conditions are in `adapters/_template/README.md`, and the worked example is
  `adapters/bizhawk/pokemon/emerald/probes/testkit.lua`.

## Depth beyond the cosmetic ghost (reserved, not scheduled)

MeshGhost's default is and stays cosmetic. But the architecture doesn't trap it
there for a specific game if that's wanted later — see the Extensibility section of
`agent_docs/contract.md` and the matching ADR in `agent_docs/architecture.md` for the
mechanism. What was built on 2026-08-17, all opt-in per room and used by no adapter: an opaque
addressed **event** plane, a room **sequencer**, **leases** over opaque keys, **escrow** for
both-or-neither exchanges, and **world custody** (`world.v1`) — the relay holding the latest opaque
blob per entity and handing it to whoever takes an authority lease next. See `beyond-cosmetic.md`;
primitives only, and none of it is a licence to use them.

The concept layer under this ladder — sync models, the authority taxonomy, and what a
deeper-than-cosmetic mode would actually have to close — is `agent_docs/beyond-cosmetic.md`.
Read it before proposing anything past Tier 2.

Depth ladder — what MeshGhost can support, per game:

| Tier | What | Game writes? | Cost |
| --- | --- | --- | --- |
| 0 — cosmetic ghost (today) | position, area, anim | none | the current project |
| 1 — cosmetic+ | nameplates, emotes, text chat, "friend entered Route 103" pings, shared timers | none | cheap; possible, deliberately not scheduled |
| 2 — read-only shared context | see a friend's party/badges/progress in an overlay | none | moderate; still no risk |
| 3 — consensual interaction | trading, battling | yes | the cliff — a category jump, not a bigger Tier 2. Needs its own ADR, per-game, opt-in. |

**The ladder describes what a GAME does, not what the relay offers**, and the two moved apart on
2026-08-17. The planes above are mechanism at every tier: a room can hold a whole world of opaque
entity state without any game writing a byte, because the relay stores and orders it and the adapter
decides what — if anything — to render. So none of them is a rung, and reaching a higher rung still
costs exactly what this table says it costs.

Tier 1 items are recorded here as things that are possible and cheap (they need no game
writes), specifically **not scheduled** — phase discipline means finishing the phase that is
actually live before adding anything else, cosmetic or not. (Written when Phase 4's two-player
milestone was the gate; that closed 2026-08-11, and the rule is what carried forward, not the
particular phase number.)

See `agent_docs/ideas.md` for the researched backlog this ladder feeds — including a first
investigation of Emerald's Union Room (spawn-based rendering vs. today's overlay drawing) and
TEVI's opt-in ghost-collision experiment. Nothing there is scheduled; move an entry here with a
phase number when it's picked.

Tier 3 (Emerald trading/battling, concretely) is gated on two things, neither settled: an ADR
that accepts the save-corruption risk memory writes carry, and the Archipelago-coexistence
test below, since Archipelago already patches the Emerald ROM and writes memory via its own
BizHawk Lua connector.

### Below the line: full co-op is a different project, not a Tier 4

"Everything in the game synced, full online co-op" is not the next rung on this ladder, and
not because of effort. Tier 3 works because a trade or a battle is a **bounded, consensual,
episodic session**: it starts, both sides explicitly agree, authority is handed over for its
duration, it ends, both games resume independently. Full co-op is **continuous and needs a
permanent arbiter** — no start/end/consent moment, and something has to resolve every
conflict forever: who picked up the item, whose RNG applies, what happens when one player is
in a menu and the other isn't.

Three concrete blockers, none of them about how much time it would take:

- **No *simulation* authority, by design** — sharpened 2026-08-17, because the relay is no longer
  a pure forwarder and the original wording ("no authority model") is now contradicted by
  `relay/world.go`'s own opening paragraph. It does arbitrate *order* (the sequencer),
  *designation* (who holds a key) and *custody* (what a successor inherits), all by comparing
  opaque strings. What it will never do is decide whether an action was legitimate — items,
  combat, RNG — and continuous co-op needs exactly that arbiter.
- **Any arbiter would have to be game-aware** — items, combat, RNG — which breaks the single
  most important invariant in this project: `core` and `relay` never know
  game specifics.
- **Two independent simulations is the founding premise** (the brief accepts desync as
  correct behavior). Full co-op needs the simulations to agree, which means either lockstep
  determinism (not viable with two save files and independent menus/RNG) or authoritative
  state replication — i.e. rewriting the target game's netcode. For Emerald that's the
  brief's own "decomp ROM hack, heaviest" tier, applied to the whole game instead of one
  sprite.

The brief's own numbers make this concrete: relay, interpolation, and schema are ~100%
reusable across games; reading position and rendering a ghost are ~0% reusable. A full-co-op
project is *nothing but* the ~0%-reusable kind of work — there is no shared abstraction left
for MeshGhost to contribute beyond raw transport. So: **full co-op for a specific game is a
separate, per-game project** (effectively netcode grafted onto that game) that could reuse
MeshGhost's relay/transport as a building block, but not its core, and would need its own ADR
before any work started. This is not a future phase of MeshGhost; it doesn't get a tier
number here on purpose.

## Current status

Phases 0–2 are complete — see `agent_docs/verified.md` for every confirmed address, the
`area_id`/`anim`/`orientation` decisions closed in `agent_docs/contract.md`, and the Phase 2
ghost-overlay/screen-position findings (including the battle-drawing-skip design decision and
several transient rendering glitches traced back to already-known causes). The bike/surf flags
deferred there were picked up in Phase 8 and are done (2026-08-20/21, `verified.md`); the
`coordOffsetEnabled` assumption remains unverified but low-risk. Phase 3 (loopback) is also complete (2026-08-11) —
a real relay/core round trip confirmed trailing a ghost on screen, after finding and fixing
three real bugs along the way (see `agent_docs/phases/phase3.md`). Phase 4 (two players) is
also complete (2026-08-11) — two real BizHawk/Emerald instances confirmed rendering each
other's ghosts, joining, and despawning correctly on both clean and unclean disconnects (see
`agent_docs/phases/phase4.md`). The one follow-up it carried — battle-skip gating needing a
verified `pokeemerald` battle-state signal — was closed the same day with
`gMain.callback2 == CB2_Overworld`, confirmed live and per-viewer (`agent_docs/verified.md`).
Phase 5 (extract the
template) is also complete (2026-08-11) — the core was confirmed running standalone against an
in-process fake adapter (a ghost walking in a circle, no game attached), and
`adapters/_template/` gained a language-agnostic protocol stub for Phase 6 to build from (see
`agent_docs/phases/phase5.md`). **"Frozen" was the wording here until 2026-08-18 and it is
wrong** — `CLAUDE.md` requires `_template/` to be kept as the gold standard and back-ported in
the same pass whenever a shipped adapter learns a rule, file or trap; what is stable is the
*protocol stub*, not the folder. Phases 6, 7, 8 and 9 (TEVI, Pseudoregalia, Emerald's ongoing
post-5.5 work, and Crystal) are covered in their own sections further down this file. See `agent_docs/status.md` for the current one-screen summary of active work.

## Roadmap

### Phase 0 — Contract on paper

Visible outcome: documented schema and interface, plus an empty `agent_docs/verified.md`.
**Status: complete.** The contract structure (schema, message types, adapter interface,
transport, tick model) is written in `agent_docs/contract.md`, and every item in that file's
"Open questions carried from the original Phase 0 backlog" list is now closed with a live
citation (the last of them by Phase 1/2 work in 2026-08-11, plus the snapshot-frequency
question re-answered by the 2026-08-15 rate-control ADR).

### Phase 1 — Emerald read-only verification

Visible outcome: BizHawk Lua prints local player state from actual game memory, and it
tracks known-direction motion. **Status: complete** (2026-08-11), bike/surf flags deferred.
See `agent_docs/verified.md`.

### Phase 2 — Fake ghost, no network

Visible outcome: a rendered ghost overlay in Emerald following a hardcoded offset, using
`gui.drawImage`. Proves the screen-position math (map coords + camera scroll) before network
code is in the picture. **Status: complete** (2026-08-11) — confirmed tracking the player
including at a real camera-pinned map edge, plus three transient-rendering findings (battle
sprite-slot reuse, route-crossing jitter, door-warp jitter) all traced to already-understood
causes rather than new bugs. See `agent_docs/verified.md`. Detailed record:
`agent_docs/phases/phase2.md`.

### Phase 3 — Loopback

Visible outcome: one client sends its own state through a local relay and renders its ghost
trailing itself by ~200ms. Exercises the bridge, the relay protocol, the schema, and the
interpolation buffer on one machine before a second machine is involved. Implements the
payload/rate limits from `agent_docs/contract.md` even though no-auth means nothing else
guards the relay yet. **Status: complete** (2026-08-11) — confirmed on screen: a ghost trails
the player by ~200ms with `TILE = 16` correct, holding steady across walking/running and
route/house transitions, with no flicker, over the real relay/core/bridge round trip
(loopback flag on, not a same-process shortcut). Three real bugs were found via live testing
and fixed: `core` didn't despawn remotes when its own relay connection dropped, the
Lua adapter didn't detect its own bridge connection dying, and — the one that made both of
those look worse than they were — BizHawk's `gui.*` overlay does not auto-clear between
frames (corrected a wrong assumption stated in `contract.md`'s tick model since Phase 2). See
`agent_docs/phases/phase3.md` for the full task-by-task record and `agent_docs/verified.md`
for every confirmed fact.

### Phase 4 — Two players

Visible outcome: two BizHawk clients render each other's ghosts and handle joins/drops.
First real multiplayer milestone. No-auth per the current ADR — treat the relay address as
something only shared directly with a friend, not something safe to post publicly, until
room codes ship (see below). **Status: complete** (2026-08-11) — see
`agent_docs/phases/phase4.md` for the full task-by-task record and `agent_docs/verified.md`
for every confirmed fact.

Deferred idea, raised during Phase 4 testing, not scheduled: a ghost in a map connected to the
local player's current map (an adjacent route/town, seamlessly scrolled between rather than
warped) currently just doesn't render at all, same as any other different `area_id`, even
though the two areas are visually contiguous at the shared edge. Rendering it correctly across
that seam would mean reading and verifying `pokeemerald`'s own map-connection offset data
(new, unverified addresses) and extending the screen-position formula to place a ghost from a
different map at the right spot near the boundary — real new work, adapter-side only (does not
touch the core's `area_id`-is-opaque rule), not attempted.

### Phase 5 — Extract the template

Visible outcome: the core runs independently of the Emerald adapter against a fake adapter
that moves a ghost in a circle, with no game attached. If it doesn't run cleanly, something
leaked — check for `if game ==`-style branches in `core` and `relay`.
Freeze `adapters/_template/` as the reusable adapter stub — this is the real deliverable of
this phase, not the Emerald adapter itself. **Status: complete** (2026-08-11) — see
`agent_docs/phases/phase5.md` for the full task-by-task record and `agent_docs/verified.md`
for the confirmed fact. No `core`/`relay` changes were needed beyond adding
`Core.RunAdapter`, an in-process driver alongside the existing bridge-wire path — both share
one diff implementation, so there's no game-specific or protocol-specific branching in either.

### Phase 5.5 — Real Emerald ghost sprite (gender-correct)

Not a numbered milestone in the original game-count sense (doesn't gate Phase 6), but the user
wants Emerald's ghost rendering "finished" — a real Brendan/May sprite instead of the magenta
placeholder box, gender advertised in the schema so a remote renders correctly, and every
Phase 1/2 address re-verified on a female save (previously male-only). **Status: complete**,
2026-08-11 — see `agent_docs/phases/phase5_5.md` for the full research citations, task list,
and `agent_docs/verified.md` for every confirmed fact. Real sprite art, gender-correct
rendering (including a genuinely separate running pose, found live — not a faster walk cycle),
and female-save re-verification all confirmed live with two real peers. Along the way, also
fixed real sub-tile position-smoothing and stale-remotes bugs surfaced by testing with a real
detailed sprite instead of the old placeholder box. Deliberately does not touch bike/surf
flags, ledge jumps (surfaced during testing, added to the same deferred item), seamless
route/town rendering, the `coordOffsetEnabled` assumption, the relay-disconnect log spam, or
the two open contract questions — those stay exactly as already documented, deferred.

### Phase 6 — Second game (TEVI)

Visible outcome: repeat phases 1–4 for TEVI using the frozen template, and find out whether
the contract holds up outside Emerald. **Status: fully done, including 6.6 (two real players),
confirmed 2026-08-13** — see `agent_docs/phases/phase6.md` for the full record. Confirmed live:
Mono (not IL2CPP), real player position/facing/anim/area reading, a real bridge→relay→core
round trip through both the relay's `-loopback` flag and a real non-loopback relay with two
distinct local players, and a real character-visual ghost (correct anchor, facing, animation)
that doesn't intrude on TEVI's menus. Three real bugs found and fixed in `core`
(game-agnostic, benefiting every adapter): `Core.MinSendInterval` (2026-08-12 ADR — TEVI's
uncapped `Update()` tripped the relay's 120 msg/sec limit); closing a bridge connection now
disconnects the relay too (2026-08-13 ADR — a player's ghost was staying frozen in a peer's
world after returning to the main menu or closing the game, confirmed live — both the
main-menu-return and game-close cases now despawn correctly, pause menu confirmed unaffected);
and cross-area filtering (2026-08-13 ADR — a remote's ghost rendered at another zone's raw
coordinates regardless of which zone the local player was actually in, invisible only by
coincidence when two real zones' coordinate ranges didn't overlap on screen — built,
regression-tested, and confirmed live). **6.7, started and closed 2026-08-13**: shows remote
players' room locations on TEVI's map screens (not just the world-space ghost) — see
`phase6.md` for the full record (TEVI's map is room-grid based, not continuous position;
`FullMap.playerPos`/`GetRoomCode`/`roomtilelist` are the relevant real facts found). Built,
fog-of-war-gated, and confirmed live the same session.

**Deliberately not blocking a third game on 6.6** (decided 2026-08-12): adapters are
structurally isolated (`contract.md`'s hard rules — an adapter only ever talks to its own local
core, `core`/`relay` never branch on game), so there's no technical coupling
that makes starting Pseudoregalia risky to TEVI. The honest tradeoff, recorded rather than
ignored: 6.6 specifically tests things solo-testing can't (real join/leave, cross-area
filtering — the latter genuinely unbuilt, not just untested, since `core` currently
sends every known remote regardless of area). Emerald's own Phase 4 caught two real bugs
Phase 3's solo loopback hadn't surfaced, so something similar in TEVI once a second machine is
available is a real possibility, not just a formality — accepted as a small risk of later
rework rather than sitting idle on a blocker with no ETA. **This risk closed, not just
resolved by waiting**: a standalone second TEVI build, confirmed to run
alongside the Steam copy, unblocked real two-player testing, and 6.6 completed 2026-08-13 — see
the "Status" line at the top of this section.

### Phase 7 — Third game (Pseudoregalia)

Visible outcome: repeat phases 1–4 for Pseudoregalia (UE5) using the frozen template. **Status:
7.0–7.8 done — 7.7 confirmed 2026-08-16, two real players on two machines with the Linux
tester; 7.8 (slide pose via the game's own crouch path) landed 2026-08-17** — see
`agent_docs/phases/phase7.md` for
the full task record. Started early relative to Phase 6's own two-player milestone (6.6) — see
Phase 6's status note above for why that's a deliberate, recorded tradeoff rather than an
oversight.

Tooling confirmed (engine UE 5.1; UE4SS v3.0.1 Beta, Git SHA `733e5969`), licensing gate done
(`RE-UE4SS` MIT, `pseudoregalia-archipelago` all-rights-reserved/facts-only), and the shipping
adapter is a UE4SS **C++** mod (`adapters/pseudoregalia/MeshGhostPseudo/`) — the earlier
Lua-only plan was superseded once the private `UEPseudo` submodule blocker (7.2) was worked
around locally. 7.1–7.6 each hit and fixed real bugs live (spawn timing, drag-on-possession,
camera-locked-to-ghost, invisible `SpawnActor`'d meshes, stuck falling/ledge-hang animation) —
full blow-by-blow in `phase7.md`, since each is a transferable UE4SS-reflection lesson, not
just a fixed bug. **First release package cut 2026-08-13** as EXPERIMENTAL/pre-release, same
status TEVI shipped at before its own two-player test — see
`packaging/release/games/pseudoregalia/README.txt`. 7.7 (a real second player over a real
network) closed 2026-08-16, so the adapter is confirmed-working rather than expected-to-work.

Ghost collision, raised by the user during Phase 7.6 animation testing (2026-08-13): make it a
feature rather than permanently disabled. The user's own framing: physically sharing space with
another player can make the game feel more interactable than a pure visual ghost.

**SHIPPED 2026-08-15 — `GHOST_COLLISION_ENABLED = true` (`Plugin.cpp`) is now a deliberate
feature, not a test flag.** The run-ending danger found along the way (an enemy hitting a ghost
hurting and killing the *real* player) was fixed by giving the ghost capsule the
`ECC_WorldDynamic` object type, so enemy targeting never queries it. Residual and accepted: a
player can still deliberately melee a ghost and take damage. Hard rule: never set
`LOOPBACK_GHOST_OFFSET_X = 0` while collision is on — it reproduces the 7.4 drag/pull bug.
Whether it is actually *fun* was expected to be one of the things 7.7 decides; **7.7 closed
2026-08-16 without a recorded judgement on that**, so the keep-or-axe call stays open — it is
listed in `agent_docs/status.md`. Full record: `agent_docs/ideas.md`
item 5 and `agent_docs/risks.md`'s ghost-collision group.

The history below is kept because it is the reasoning that got here, and it is dated 2026-08-13 —
**it is superseded by the paragraph above.** Tried and reverted same-day, real risk found: A blanket `SetActorEnableCollision(true)` test did *not* make the
ghost physically solid — the real player could still walk straight through it — but it could
still be attacked and killed with melee, which killed the real player's own character, not just
the ghost. Worst of both: no physical solidity (the actual goal) plus a new death risk.
`SetActorEnableCollision` only restores the component's existing query/physics collision mode,
not per-channel Block/Overlap/Ignore responses — real physical blocking would need a separate,
explicit response-channel change, not yet identified. The real-player-death effect suggests this
class's health/damage state may not be safely scoped per-instance at all. Any future attempt
needs to identify and disable the specific damage/hit collision channel via reflection first
(not guessed), separately figure out what response-channel change would give real physical
blocking, plus a real answer to the open question the user raised: does *any* other in-world
damage source (hazards, out-of-bounds, enemies) reach the ghost and propagate to the real player
the same way, or was that specific to melee's collision-based hit detection? (That last question
was answered 2026-08-15 — it did, via enemies, and that is what the fix above addresses.)

### Phase 8 — Emerald, dedicated (post-5.5 ongoing work)

**Status: LIVE, and the peer-state work inside it is CLOSED — Emerald is FEATURE COMPLETE as of
2026-08-21, the user's call** (*"i consider the game to be fully synced up animation and effect
wise now"*, `verified.md`). Every way this game moves a character and every field effect it hangs
off one is mirrored on all three tiers. **The adapter is PARKED** — the user moved to Crystal the
same day, so the phase stays open but nothing in it is scheduled. What remains is a different kind
of work: polish, custom features beyond matching the game, and two untested-but-assumed states
(`unverified.md`). **A new Emerald animation/effect item needs a reason it is not polish or a
custom feature.**

Started 2026-08-14, then quiet while Phases 6/7 had the attention, and picked
back up with a full session on **2026-08-18** that replaced the overlay with a real spawned object
event (its own ADR in `architecture.md`; user-confirmed piece by piece on screen, end-to-end pass
still queued in `unverified.md`). `status.md` is the index of what is open — see `agent_docs/phases/phase8.md` for the full record. Numbered next in sequence rather than folded back into 1–5.5 (which bundled Emerald
with building the server/client/core themselves) — those stay as-is to avoid breaking their
many existing citations elsewhere. A dedicated home for real Emerald-specific work that keeps
happening after Phase 5.5's "good enough" milestone: a review/refactor sweep (real
socket-framing and crash-safety bugs), a real non-loopback two-peer test, a four-part
Archipelago-ROM-compatibility investigation (relocated `CB2_Overworld`, relocated sprite data,
relocated `gObjectEvents`/`gPlayerAvatar`, and a timing bug in that last fix), a gender-read
timing bug, local dev/testing tuned for instant feedback (`-interp=0ms`/new `-min-send` flag),
and a real sub-tile movement-smoothing bug found once that tuning stopped a network buffer from
hiding it. Movement support has since landed and been user-confirmed on screen: ledges
(2026-08-19), the Mach Bike (2026-08-20), the Acro Bike (2026-08-21) and surfing/diving
(2026-08-21) — see `verified.md`, plus ice, fog and cave darkness the same day, which is where the
feature-complete call above came from. **Rail movement and the ferry were never tested and are
ASSUMED to work** — the user's call 2026-08-21, dropped from `status.md` deliberately rather than
left open; the assumption is recorded in `unverified.md` so it cannot decay into a memory of having
checked. Also not started: Stages 2–5 of the
VRAM/sprite-injection investigation (`agent_docs/ideas.md`; Stage 1 — read-only probing — ran
2026-08-14, written up in `agent_docs/environment.md`). Note that any stage of that investigation
which actually *writes* emulator memory is gated by the no-memory-writes non-goal above, and needs
its own ADR before it starts.

### Phase 8.1 — Emerald: a hardware-sprite tier between spawning and drawing

**Scheduled 2026-08-21, on the user's call**, moved here from `ideas.md` ("A THIRD tier between the
two"), which keeps the full write-up, the three feasibility questions and their answers. The ladder
becomes **spawned → hardware sprite → painted**, each peer taking the best tier with room, and the
painted tier stays as the last resort rather than being retired.

**Status: built and running the same day.** The `spawn → OAM → drawn` ladder is live, and the
hardware tier's movement, rendering and scenery occlusion were all user-confirmed on screen
2026-08-21 (`verified.md`). It still ships behind `MESHGHOST_EMERALD_HW_OVERFLOW`, off by default.

**The mechanism, settled offline before any code** (`verified.md` 2026-08-21): BizHawk 2.11 has no
scanline callback at all, so no HBlank multiplexing — and Emerald does not need it. `gOamLimit` is 64
on the overworld while `LoadOam` pushes all 128 entries to hardware every VBlank, so
`gMain.oamBuffer[64..127]` is dead space the engine's per-frame path never touches, and Emerald parks
its own wireless indicator at index 125 for that reason. A peer therefore costs **three halfword
writes per frame** from the `BuildOamBuffer` hook the adapter already owns — no patch, no second
breakpoint, and the PPU does the drawing, which brings real occlusion, palette fades and cave/weather
dimming that the painted tier has to fake or simply lacks.

**What it does not get**, and it is registered up front rather than discovered: no collision, no
engine animation, no walking, no sprite-vs-sprite y-sorting against the engine's own sprites (ours
sit above index 64 and lose overlap ties). OBJ **tiles**, not OAM entries, become the capacity cap —
and `allocSpriteTiles()` already returning `nil` on exhaustion is exactly the clean fall-through to
the painted tier. Decorations (tall grass, dust, surf blob) may be **mixed per piece** — painted on
top of a hardware body, or given their own hardware entry where they need to be occluded too.

**Staged, probe-first**: a read-only shadow-OAM probe, then the smallest possible on-screen proof
(one injected entry borrowing the player's own tiles and palette, watched going behind a roof and
under a text box), then tiles/motion/the hook, then the adapter behind
`MESHGHOST_EMERALD_HW_OVERFLOW` (off by default), then elevation priority and shadows. The
comparison instrument gains a third copy: `MESHGHOST_COMPARE_TIERS` renders the loopback ghost
spawned 2 tiles right, painted 2 tiles left and hardware **3 tiles above**, so the player and all
three tiers are judged against each other in one frame.

**The claim being tested is "cheaper than drawing"**, and it is a number: `probes/fpsride.lua` on the
same route, walking peers, at N = 1/4/8, reporting the slope and the per-leg minimum — not the mean
alone, and not the adapter's own `os.clock` buckets.

### Phase 9 — Pokémon Crystal (GBC), spawn-based rather than drawn

**Status: in progress, started 2026-08-17.** Full record: `agent_docs/phases/phase9.md`. The fourth
game, and the first to render a peer by **spawning a real in-game object** rather than drawing an
overlay — the user's explicit call, so a new adapter does not begin with a compensation Emerald
already carries. That crossed the no-memory-writes non-goal above and has its own ADR
(`architecture.md`, 2026-08-17), narrowly scoped: Crystal only, vanilla V1.0 only, live RAM only,
cosmetic only, and the adapter must identify the ROM before writing. (Vanilla-only and
refuse-otherwise were both relaxed 2026-08-18 on the user's call: every ROM is identified and
attempted, Archipelago included, with `MESHGHOST_CRYSTAL_STRICT=1` restoring refusal — `verified.md`.)

**Settled**: the decomp builds byte-identical to the ROM being played, so addresses are
authoritative; `WRAM` is the domain to read; the in-game gate is `wMapStatus == HANDLE` **and**
`wBattleMode == 0` (both terms established empirically after simpler versions failed); object state
is rebuilt per map, and a **battle exit is also a map re-entry**; and **the engine adopts map
objects we write**, which is the ADR's chosen branch proven rather than assumed.

**That central open problem is SOLVED, 2026-08-18**: neither of the engine's adoption paths
(map-load, screen-edge) picks up an object placed beside the player mid-map, and the adapter now
gets one there anyway — a ghost spawns beside the player mid-map and walks with the game's own
step animation. **Networking is in and works**: `meshghost_crystal.lua` carries `get_local_state`,
`render_remote` and `despawn_remote` over the bridge, and a loopback ghost was watched moving and
facing correctly (`verified.md`, `phases/phase9.md`).

### Phase 9.1 — Crystal: cap at what the hardware can draw, then DRAW the overflow

**Scheduled 2026-08-19, on the user's explicit call**, moved here from `ideas.md` (which keeps the
full technical write-up and the costs). Their words, answering a direct question about what a
player should get past the hardware's limit: *"cap it, and just draw extras instead if that is
required. i don't want things to pop in/out all the time. i want every player/ghost to be visible
all the time instead."*

**Half of it is done and live.** The adapter now stops spawning at
`HARDWARE_CHARACTER_LIMIT = 10` characters on screen — the Game Boy draws at most 10 sprites per
scanline and an overworld character is 4 of them, so an eleventh loses pieces of itself no matter
whose it is. Measured after the change: **no scanline overflow at all, and no NPC starved**, where
minutes earlier a crowd had an NPC one tile from the player simply not drawn. Ghosts also give
their slots back beyond 8 tiles, the way the engine's own characters do, and both pools allocate
from the top down so the game's cast keeps the hardware's draw priority.

**The remaining half landed the same evening**: peers past the cap are **drawn over the emulator**,
so every peer is visible all the time — 89 on a full screen at 60fps, user-confirmed. Facing,
walk animation, text-box and menu clipping, cartridge-sourced sprites and the collision policy all
followed. What is NOT confirmed is anything after the screen-filling test itself; `unverified.md`
lists the six things a person still has to judge. Design, costs and the two occlusion
mechanisms (a text box is the fixed bottom six rows; a menu publishes `wMenuBorder*`) are in
`ideas.md` under "Spawn to the game's cap, then DRAW above it". The pixels are the near-term
question: a peer past the cap is usually wearing a sprite already resident in VRAM, which the
adapter can already identify via `wUsedSprites`.

**This is a deliberate bandage and gets registered as one** in `BANDAGES.md` the day it ships,
with its honest costs: no engine animation, no collision, occlusion re-implemented at tile
resolution, and two rendering paths in one adapter.

### Room codes / relay safety

**Set as the current/next priority 2026-08-13; core work done 2026-08-14.** Full record: the
ADR in `agent_docs/architecture.md` (search "room-code/version ADR") and `docs/security.md`'s
"What changed" section. Short version — the three pieces originally scoped, plus what each
still leaves open:

- **Auth** — `hello` now carries an optional `room_code`, constant-time-checked against the
  relay's own configured `Server.RoomCode`; empty/unset (the default) still means auth is off,
  unchanged from the original friend-hosted posture. **Open limit at the time**: no TLS, so the
  code crossed the wire in plaintext (closed since — quic 2026-08-16, tcp 2026-08-19; see the
  "Partly overtaken" paragraph below); **and** auth only works if the relay
  binary is current — a stale relay silently ignores the field and stays open with no warning
  (`risks.md`'s new "stale relay" entry, found from the user asking what an old client/server
  does against new ones).
- **Peer game-version check** — `hello` now carries an optional `game_version`, sticky per room
  the same way `game_id` already is. **Open limit**: each adapter reports its own script/mod
  version (no cited memory address exists to read a real game/DLC build in any of the three
  games), so this doesn't fully close the original TEVI concern about differing Steam patch
  levels or DLC state — see `risks.md`'s updated entry.
- **Malicious-peer hardening** — done as a real audit against concrete findings, not a
  hypothetical checklist: a real remote-OOM in `transport` (unbounded read buffer),
  missing read/write deadlines, a relay hello-timeout, `Room.Forward` holding a lock across a
  potentially-blocking `Send`, and the core trusting the relay's `player_id`s completely
  (`welcome.roster` was discarded) are all fixed. Not claimed exhaustive — see
  `docs/security.md`'s "known gaps" for what wasn't attempted.

`cmd/meshghost`/`cmd/meshghost-relay` both gained `-room-code`/`-game-version` flags and
matching `config.json` fields (`room_code` on both client and server sections, `game_version`
on the client section) — see `packaging/README.md`. The config-file mechanism this section
originally anticipated (2026-08-11) is where these landed, as expected.

**Not done as part of this pass, deliberately out of scope**: TLS (a separate, larger piece of
work — see `risks.md`); the "stale relay" gap has no protocol-level fix, only a documentation
one (tell hosts to update); TEVI's `game_version` doesn't yet reflect a real Steam build number.

**Partly overtaken 2026-08-16 by selectable transports** (ADR in `architecture.md`): `quic` is
encrypted, so a room code on that transport no longer crosses the wire in the clear. **TLS over
`tcp` landed 2026-08-19** (`netx/tlsx`, `tls: off`/`auto`/`required` on both ends — the binaries
default to `off`, the shipped `packaging/release/config.json` to `auto`), so both default
transports encrypt; `udp` can never have it at all. **The shipped defaults then changed
2026-08-16**: `config.json` now ships `client.transport: "auto"` (prefers quic) and
`server.transport: "tcp,quic"`, so quic is the normal path and tcp the fallback. Encrypted is
still not authenticated — the certificate is unverified.

### Selectable transport: `tcp` | `udp` | `quic`

**Built 2026-08-16**, from a user question about whether a TCP/UDP toggle was possible. Motivation
is modularity, explicitly not throughput: `Transport` was called "the swappable network boundary"
in the brief and in its own doc comment while having exactly one implementation, so the claim was
untested. Three implementations behind one interface, selected by `"transport"` in `config.json`,
with the relay able to serve several at once and a room able to mix them freely.

The seam sits at `net.Listener`/`net.Conn` (`netx`), not at a second `Transport`
implementation, which is why `relay` gained no transport-aware line and its
per-connection-goroutine concurrency model survived untouched. `Send` is reliable everywhere and
`SendUnreliable` is the explicit opt-out, used only by the two state hot paths.

**Adapters are unaffected and cannot observe any of it** — the bridge stays loopback TCP NDJSON.

**Since built, all 2026-08-16**: transport discovery — the relay answers what it serves during the
tcp handshake, so a client only ever needs the tcp port and the host says nothing out of band;
**quic became the shipped default** off the back of it, sharing the relay's port number (see the
paragraph above); `udp`'s reliable path became ordered as well as reliable (it deduped but never
resequenced — ADR in `architecture.md`); and `cmd/meshghost-netsim` landed as a fault-injecting
proxy so loss/latency can be exercised against real binaries.

**Open, and deliberately not attempted here**: `udp` can never be encrypted; there is still no
per-IP connection cap. Full detail in the ADR,
`risks.md`, and `verified.md`.

### Send/receive rate control

**Built 2026-08-15**, in response to a user question about a setting they recalled discussing
but that had never actually landed in the code (checked via full git history/reflog/dangling-
commit search — no trace found; either a prior conversation that didn't leave a commit, or a
plan that was never implemented). Full record: the ADR in `agent_docs/architecture.md` (search
"2026-08-15", the send/receive rate-control ADR) and `agent_docs/contract.md`'s new
"`send_hz` and `max_receive_hz_per_player`" subsection. Short version:

- **`server.send_hz`** (relay, default 20, valid 10–100) — the room-wide state send rate,
  advertised to every client via `Welcome.SendHz`. A client adopts it as its own send rate
  unless it deliberately configured a slower one (`-min-send`/`min_send`), which always wins —
  prescriptive but with a per-client floor, never a way to force a client to send faster than
  it wants to.
- **`client.max_receive_hz_per_player`** (client, default 0/uncapped, valid 10–100 if set) — how
  fast a client wants *other players'* state forwarded to it, per peer. Enforced at the relay by
  dropping the excess before it goes out on the wire (client-side discarding would save no
  bandwidth). Two recipients can receive the same sender at two different effective rates
  simultaneously.
- The per-client flood cap (`relay.MaxMessagesPerSecond`) now scales with the configured
  `send_hz` (`max(120, send_hz × 6)`), **only ever up**, never down — turning a room's rate down
  must never start disconnecting older clients still sending at their own built-in 20Hz.
- An over-limit client now gets a `Reject` (`ReasonRateLimited`, classified retryable) before the
  relay closes the connection, instead of the previous anonymous hangup.

**Real regression caught and fixed in the same change**: every `dev-scripts/run-core-*.bat`
pass `-min-send=10ms` — faster than the (now fallback-only) 20Hz default — which under "slower
wins" against an unconfigured relay would have silently capped every one of them back down to
50ms, undoing the exact fast-local-timing setup Phase 8 chose deliberately
(`agent_docs/phases/phase8.md`). Every relay dev script now passes `-send-hz=100`
(`run-relay.bat`, `run-relay-loopback.bat`, `run-relay-online.bat`).

**Not done, deliberately**: advertising a recipient's cap back to the sender (no way for a
sender to know a given peer is receiving it throttled); auto-deriving `-interp` from the
effective rate (a cap/rate below ~10Hz needs `-interp` raised by hand or ghosts visibly stutter,
documented in the flag help and README instead of engineered around). Both are real, left for
`agent_docs/ideas.md`.

### Release packaging (not a phase, tooling)

Added 2026-08-11 (`v0.1.0`, two zips: `meshghost-relay-...` / `meshghost-emerald-player-...`).
Reworked 2026-08-12: **one zip**, not two. The two-zip split's naming (`relay`/`player`) was
flagged right after `v0.1.0` shipped as not reading as "server, host this" / "client, join
with this" to a non-technical downloader. Rather than just rename the two zips, the fix went
further — `packaging/release/` now holds everything (client + server exes, one `config.json`
with `client`/`server` sections, one `README.txt`, and `games/<publisher>/<game>/` mirroring
`adapters/`), so there's no second file to pick wrong in the first place. See
`packaging/README.md` for the full design (why one zip, the config field names, why JSON, why
no password yet, why manual). `.github/workflows/release.yml` builds `meshghost.exe` and
`meshghost-server.exe` (renamed from `meshghost-relay.exe`; the internal package/binary source
at `cmd/meshghost-relay/` did not move — end-user-facing rename only) and zips the whole
`packaging/release/` folder.

Adding a game to a release is a deliberate step, not automatic — see "Adding a game to the
release" in `packaging/README.md`. **TEVI shipped in the same reworked release (2026-08-12)**,
ahead of its own phase finishing at the time (Phase 6.6 was still open) — the only thing 6.6
needed was a real second player, and putting the mod in a friend's hands was how that finally
got tested. **6.6 has since completed** (2026-08-13, see the Phase 6 section above) — this
paragraph is kept as the real, contemporaneous rationale for shipping ahead of that milestone,
not a claim that 6.6 is still open.
TEVI's packaging is unusual: `MeshGhostTevi.dll` is committed to the repo (CI cannot build it —
see `packaging/README.md`'s TEVI section for why) via `dev-scripts/build-tevi.bat`, guarded by
a staleness check in `release.yml` that fails the build if the committed DLL predates its
source. The release is cut with `prerelease` ticked and both `README.txt`s mark TEVI
experimental.

**Follow-up, same day (2026-08-12): `"game"` dropped from the shipped `config.json`.** While
reviewing the config fields above, the user pointed out that the adapter already knows which
game it's running (it's the script/mod the user loaded) — typing it a second time into
`config.json` was a redundant, typo-prone step. Real contract revision, ADR'd in
`architecture.md`: `bridge.Hello` (a new bridge message, `{"type":"hello","payload":
{"game_id":"..."}}`) is now sent by the adapter as the first message on a fresh bridge
connection; `core.Core.ConnectRelayOnAdapterHello` connects to the relay lazily on
that first hello instead of requiring `-game`/`config.json`'s `"game"` up front. Both shipped
adapters updated (`adapters/bizhawk/pokemon/emerald/probes/phase5_5_sprite.lua`,
`adapters/tevi/MeshGhostTevi/BridgeClient.cs` + `Plugin.cs`, TEVI's DLL rebuilt and
recommitted). `-game`/`"game"` still work as an explicit override — needed by
`dev-scripts/run-core-*.bat` (each game's dev launcher still passes it explicitly) and
`cmd/meshghost-fakeadapter`, which has no real adapter to send a hello. See
`agent_docs/contract.md`'s "Connecting: the bridge hello" section for the wire detail.

## Links

- `agent_docs/contract.md` — packet schema, adapter interface, transport, tick model.
- `agent_docs/brief.md` — original design brief and rationale.
- `agent_docs/architecture.md` — system shape and the decision log (ADRs).
- `agent_docs/phases/` — one file per phase; see `agent_docs/status.md` for which is
  currently live (this list intentionally doesn't name one directly — it goes stale every
  time a phase opens or closes, and already had at this exact spot before).
- `agent_docs/risks.md` — assumptions and risk register.
- `agent_docs/status.md` — current active phase and focus.
- `agent_docs/verified.md` — append-only verification log.
- `agent_docs/licensing.md` — third-party license audit.
- `agent_docs/pitfalls.md` — adapter-specific issues log: symptom, diagnosis, fix.
- `agent_docs/environment.md` — toolchain/tool/mod versions, filled in as phases need them.
- `agent_docs/ideas.md` — unscheduled backlog; an idea moves here first, then gets a phase
  number and moves into this file once actually picked up.
