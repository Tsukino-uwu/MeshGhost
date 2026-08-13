# MeshGhost roadmap

## Overview

MeshGhost is a visual-only multiplayer layer for single-player games. Each player runs an
independent copy of the game, and the only networked state is enough information to render
a cosmetic ghost: location, area, and animation state. Full rationale in `agent_docs/brief.md`.

The architecture is split into: relay server (game-agnostic), core client (game-agnostic),
adapter contract (thin boundary), per-game adapters (game-specific rewrite). Full contract
detail lives in `agent_docs/contract.md`.

Target games: **Pokémon Emerald** (BizHawk, first) → **TEVI** (Unity, second) →
**Pseudoregalia** (UE5, third). See `agent_docs/architecture.md`'s decision log for why
TEVI replaced the brief's original Ori: Will of the Wisps pick.

## Non-goals for early work

- No shared gameplay state, physics, or collision synchronization.
- No game-specific rendering logic inside the core.
- No adapter transport or socket handling — adapters speak only to the local bridge.
- No production binary encoding or performance optimization before the contract is stable.
- No second-game adapter until Phase 5 validates the template.
- No relay authentication work before Phase 4 ships on no-auth (see `architecture.md` ADR);
  don't build room codes early just because they're the eventual goal.
- No emulator memory *writes* or save-state editing — MeshGhost reads game memory and does
  not write it, today. This is the current posture, not a permanent philosophical stance:
  whether it ever changes (see "Depth beyond the cosmetic ghost" below) is pending an actual
  Archipelago-coexistence test, not decided in the abstract. Until that test happens and a
  specific feature is deliberately approved via an ADR in `architecture.md`, this rule holds
  without exception.

## Depth beyond the cosmetic ghost (reserved, not scheduled)

MeshGhost's default is and stays a visual-only mod. But the architecture doesn't trap it
there for a specific game if that's wanted later — see the Extensibility section of
`agent_docs/contract.md` and the matching ADR in `agent_docs/architecture.md` for the
mechanism (an opaque, per-adapter event plane; nothing built yet, just reserved).

Depth ladder — what MeshGhost can support, per game:

| Tier | What | Game writes? | Cost |
| --- | --- | --- | --- |
| 0 — cosmetic ghost (today) | position, area, anim | none | the current project |
| 1 — cosmetic+ | nameplates, emotes, text chat, "friend entered Route 103" pings, shared timers | none | cheap; possible, deliberately not scheduled |
| 2 — read-only shared context | see a friend's party/badges/progress in an overlay | none | moderate; still no risk |
| 3 — consensual interaction | trading, battling | yes | the cliff — a category jump, not a bigger Tier 2. Needs its own ADR, per-game, opt-in. |

Tier 1 items are recorded here as things that are possible and cheap (they need no game
writes), specifically **not scheduled** — phase discipline means finishing the two-player
milestone (Phase 4) before adding anything else, cosmetic or not.

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

- **No authority model, by design.** The relay is a dumb forwarder; each client is
  authoritative over only itself. Continuous co-op needs an arbiter MeshGhost deliberately
  doesn't have.
- **Any arbiter would have to be game-aware** — items, combat, RNG — which breaks the single
  most important invariant in this project: `internal/core` and `internal/relay` never know
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
several transient rendering glitches traced back to already-known causes). Only bike/surf
flags remain deferred (far into the game, not blocking) and the `coordOffsetEnabled`
assumption remains unverified but low-risk. Phase 3 (loopback) is also complete (2026-08-11) —
a real relay/core round trip confirmed trailing a ghost on screen, after finding and fixing
three real bugs along the way (see `agent_docs/phases/phase3.md`). Phase 4 (two players) is
also complete (2026-08-11) — two real BizHawk/Emerald instances confirmed rendering each
other's ghosts, joining, and despawning correctly on both clean and unclean disconnects (see
`agent_docs/phases/phase4.md`). One follow-up carried forward, not a Phase 4 blocker:
battle-skip gating needs a verified `pokeemerald` battle-state address. Phase 5 (extract the
template) is also complete (2026-08-11) — the core was confirmed running standalone against an
in-process fake adapter (a ghost walking in a circle, no game attached), and
`adapters/_template/` is now frozen with a language-agnostic protocol stub for Phase 6 to build
from (see `agent_docs/phases/phase5.md`). See `agent_docs/status.md` for the current one-line
focus.

## Roadmap

### Phase 0 — Contract on paper

Visible outcome: documented schema and interface, plus an empty `agent_docs/verified.md`.
**Status: mostly done, not complete.** The contract structure (schema, message types,
adapter interface, transport, tick model) is written in `agent_docs/contract.md`. What
remains is genuinely Emerald-specific and can only be closed by Phase 1 work — see that
file's "Open questions" section.

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
and fixed: `internal/core` didn't despawn remotes when its own relay connection dropped, the
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
leaked — check for `if game ==`-style branches in `internal/core` and `internal/relay`.
Freeze `adapters/_template/` as the reusable adapter stub — this is the real deliverable of
this phase, not the Emerald adapter itself. **Status: complete** (2026-08-11) — see
`agent_docs/phases/phase5.md` for the full task-by-task record and `agent_docs/verified.md`
for the confirmed fact. No `internal/core`/`internal/relay` changes were needed beyond adding
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
the contract holds up outside Emerald. **Status: everything solo-testable is done and
confirmed (2026-08-12); 6.6 (two real players, needs a second machine) is not** — see
`agent_docs/phases/phase6.md` for the full record. Confirmed live: Mono (not IL2CPP), real
player position/facing/anim/area reading, a real bridge→relay→core round trip via the relay's
`-loopback` flag, and a real character-visual ghost (correct anchor, facing, animation) that
doesn't intrude on TEVI's menus. One real bug found and fixed in `internal/core`
(`Core.MinSendInterval`, see the 2026-08-12 ADR in `architecture.md`) — TEVI's uncapped
`Update()` tripped the relay's 120 msg/sec limit, fixed game-agnostically so every adapter
benefits.

**Deliberately not blocking a third game on 6.6** (decided 2026-08-12): adapters are
structurally isolated (`contract.md`'s hard rules — an adapter only ever talks to its own local
core, `internal/core`/`internal/relay` never branch on game), so there's no technical coupling
that makes starting Pseudoregalia risky to TEVI. The honest tradeoff, recorded rather than
ignored: 6.6 specifically tests things solo-testing can't (real join/leave, cross-area
filtering — the latter genuinely unbuilt, not just untested, since `internal/core` currently
sends every known remote regardless of area). Emerald's own Phase 4 caught two real bugs
Phase 3's solo loopback hadn't surfaced, so something similar in TEVI once a second machine is
available is a real possibility, not just a formality — accepted as a small risk of later
rework rather than sitting idle on a blocker with no ETA. Revisit 6.6 whenever a second machine
(a friend, or another PC) is available; not scheduled.

### Phase 7 — Third game (Pseudoregalia)

Visible outcome: repeat phases 1–4 for Pseudoregalia (UE5) using the frozen template. **Status:
in progress**, started 2026-08-12 — see `agent_docs/phases/phase7.md` for the full task record.
Started early relative to Phase 6's own two-player milestone (6.6) — see Phase 6's status note
above for why that's a deliberate, recorded tradeoff rather than an oversight.

The first task — confirm what modding tooling actually applies before assuming anything, the
same standard TEVI's Mono-vs-IL2CPP check followed — is **done**. Confirmed live via direct
filesystem inspection of this machine's install: engine is **UE 5.1**; UE4SS is **v3.0.1 Beta,
Git SHA `733e5969`**, under the newer `Binaries\Win64\ue4ss\` layout; a UE4SS **C++** mod
(`AP_Randomizer`, the Archipelago integration) is already installed, running, and proven to
hold a real TLS/websocket socket in this exact game — closing `environment.md`'s previously
open "UE4SS version for Pseudoregalia: unfilled" line. Mid-session correction, recorded rather
than silently fixed: an initial reading found an older `v2.5.2`/SHA `a267c64`; the user then
updated their local UE4SS to match a Mar 2026 update to `pseudoregalia-archipelago`'s own
`RE-UE4SS` submodule pin, and all docs were re-checked and corrected to `v3.0.1`.

Licensing gate done: `RE-UE4SS` (MIT) and `pseudoregalia-archipelago` (**no LICENSE file — all
rights reserved**, facts-only per the standing rule) added to `agent_docs/licensing.md`. Four
new UE5-specific risks registered in `agent_docs/risks.md` (Blueprint-vs-C++ readability, no
clip-name-animation equivalent in UE5, UE4SS version drift, `AP_Randomizer` coexistence).

**Adapter-language decision:** Lua for discovery, C++ for the shipping adapter. UE4SS's Lua API
has no socket support (confirmed via `gh api` code search and docs.ue4ss.com — zero
`luasocket` references, no networking capability), but `AP_Randomizer` proves a UE4SS C++ mod
can hold a real socket here. Next: 7.1, a throwaway Lua probe to confirm the player-state read
empirically before writing the C++ adapter.

Deferred idea, raised by the user during Phase 7.6 animation testing (2026-08-13), not
scheduled: make ghost collision (currently always off, `ensure_ghost_spawned`'s
`SetActorEnableCollision`, gated behind the `GHOST_COLLISION_ENABLED` toggle) an opt-in feature
rather than permanently disabled. The user's own framing: physically sharing space with another
player can make the game feel more interactable than a pure visual ghost.

**Tried and reverted same-day, real risk found — see `agent_docs/risks.md`'s ghost-collision
entry for the full record.** A blanket `SetActorEnableCollision(true)` test did *not* make the
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
the same way, or was that specific to melee's collision-based hit detection? Not investigated
yet. This is a materially harder and riskier feature than it looked at first — treat as genuinely
deferred, not a quick follow-up.

### Post-Phase-4 — Room codes

Not a numbered phase because it doesn't gate the games-side milestones. Add shared-secret
room codes to the relay so a session isn't just a bare IP:port. Scheduled after Phase 4
proves the two-player path works at all. **Still not built** — the relay remains no-auth
(`agent_docs/architecture.md`'s ADR); `room` today is a plain label, not a secret.

The config-file mechanism this section anticipated now exists (2026-08-11, alongside the
release-packaging work below), ahead of room codes themselves: `cmd/meshghost`/
`cmd/meshghost-relay` both load an optional `-config=config.json` (defaults to `config.json`
next to the exe; explicit CLI flags still override individual fields). `interp` is not yet one
of the loadable fields — cheap to add whenever it's actually wanted; not done speculatively.
When room codes are actually designed, this is where the secret goes.

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
ahead of its own phase finishing (Phase 6.6 is still open) — the only thing 6.6 needs is a
real second player, and putting the mod in a friend's hands is how that finally gets tested.
TEVI's packaging is unusual: `MeshGhostTevi.dll` is committed to the repo (CI cannot build it —
see `packaging/README.md`'s TEVI section for why) via `dev-scripts/build-tevi.bat`, guarded by
a staleness check in `release.yml` that fails the build if the committed DLL predates its
source. The release is cut with `prerelease` ticked and both `README.txt`s mark TEVI
experimental.

**Follow-up, same day (2026-08-12): `"game"` dropped from the shipped `config.json`.** While
reviewing the config fields above, the user pointed out that the adapter already knows which
game it's running (it's the script/mod the user loaded) — typing it a second time into
`config.json` was a redundant, typo-prone step. Real contract revision, ADR'd in
`architecture.md`: `internal/bridge.Hello` (a new bridge message, `{"type":"hello","payload":
{"game_id":"..."}}`) is now sent by the adapter as the first message on a fresh bridge
connection; `internal/core.Core.ConnectRelayOnAdapterHello` connects to the relay lazily on
that first hello instead of requiring `-game`/`config.json`'s `"game"` up front. Both shipped
adapters updated (`adapters/pokemon/emerald/phase5_5_sprite.lua`,
`adapters/tevi/MeshGhostTevi/BridgeClient.cs` + `Plugin.cs`, TEVI's DLL rebuilt and
recommitted). `-game`/`"game"` still work as an explicit override — needed by
`dev-scripts/run-core.bat` and `cmd/meshghost-fakeadapter`, which have no real adapter to send
a hello. See `agent_docs/contract.md`'s "Connecting: the bridge hello" section for the wire
detail.

## Links

- `agent_docs/contract.md` — packet schema, adapter interface, transport, tick model.
- `agent_docs/brief.md` — original design brief and rationale.
- `agent_docs/architecture.md` — system shape and the decision log (ADRs).
- `agent_docs/phases/phase1.md` — the only currently-live phase file.
- `agent_docs/risks.md` — assumptions and risk register.
- `agent_docs/status.md` — current active phase and focus.
- `agent_docs/verified.md` — append-only verification log.
- `agent_docs/licensing.md` — third-party license audit.
