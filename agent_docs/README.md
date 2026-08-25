# agent_docs — internal project documentation

Internal documentation for MeshGhost: architecture, planning, licensing, and verification.

## Files

- [brief.md](brief.md) — the original design brief: vision, non-goals, prior art, rationale.
- [project-history.md](project-history.md) — retrospective on the pre-planning phase before any
  adapter existed. Per-adapter build stories live in each game's own `README.md` instead.
- [contract.md](contract.md) — **the durable artifact.** Packet schema, message types, adapter
  interface, transport, tick model, limits. Changes here are contract revisions, not routine
  edits — record the "why" in [architecture.md](architecture.md)'s decision log.
- [architecture.md](architecture.md) — system shape and the architecture decision log (ADRs),
  plus the CelesteNet prior-art notes several of those ADRs were researched against.
- [plans.md](plans.md) — live roadmap, phase status, non-goals.
- [ideas.md](ideas.md) — unscheduled feature backlog. Not the roadmap — researched enough to
  act on when picked, but nothing here is committed until it moves into [plans.md](plans.md).
- [status.md](status.md) — one-screen summary of the active phase and current focus.
- [risks.md](risks.md) — assumptions and risk register.
- [licensing.md](licensing.md) — third-party license audit. Check before referencing any
  outside project.
- [environment.md](environment.md) — toolchain and environment notes, filled in as phases
  actually run.
- [playing.md](playing.md) — everything about driving a running game: what an agent may change,
  how to steer input, how to navigate, how to use screenshots. **Read before driving any game.**
- [verified.md](verified.md) — append-only, human-gated log of confirmed runtime facts.
- [unverified.md](unverified.md) — the waiting room for it: things the agent believes work and the
  user has not seen yet, with what to look at and what correct looks like. A checklist to work
  down; confirmed items move to `verified.md`, declined ones go back to being work.
- [testing.md](testing.md) — **how to run every automated check** for the Go client/server: the
  one local command, the local `-race` recipe (working since 2026-08-18), what CI adds on top
  (fuzzing, cross-compiles, gofmt), how to run a real fuzz campaign, and the traps that otherwise get rediscovered. Read before adding a
  test or diagnosing an intermittent failure. Covers the Go side only — adapters are watched, not
  tested, per CLAUDE.md.
- [pitfalls.md](pitfalls.md) — adapter-specific issues across all games: symptom, how it was
  diagnosed, root cause, fix. Not design decisions ([risks.md](risks.md)) or confirmed facts
  ([verified.md](verified.md)).
- [beyond-cosmetic.md](beyond-cosmetic.md) — **the concept layer under the depth ladder**: sync
  models, the five authority models and which of them need game knowledge, the readiness gaps a
  fuller online mode would have to close, and the rule that keeps the door open (capability is
  adapter-opt-in via `features`, never relay-imposed via `game_id`). Nothing in it is scheduled.
- [kill-credit.md](kill-credit.md) — **who gets the reward, and when an enemy is actually dead**,
  for any future enemy/boss sync. Sync damage rather than death and let each client's own game
  kill the enemy itself; participation, liveness, difficulty and player-count scaling are four
  independent per-entity-class policies. Carries the hard-case list and the MMO/co-op prior art.
  Sits under `beyond-cosmetic.md`. Nothing in it is scheduled.
- [bandages-core.md](bandages-core.md) — shipped compensations in the Go side (core, relay,
  transport), and the ones deliberately left alone. **Per-adapter bandages live in each adapter's
  own `BANDAGES.md`**, next to its `README.md`; the rule and the how-to-spot-one guide are in
  `adapters/_template/`. Each adapter also carries a **`FLAGS.md`** (its compile-time flag
  register — shipped behaviour / probe / dormant) and a **`documentation.md`** (how that GAME
  works, never our compensations). All four shipped adapters have all three, as of 2026-08-18.
- **`adapters/CLAUDE.md` and `adapters/bizhawk/CLAUDE.md` — rules that load themselves.** A nested
  `CLAUDE.md` is read automatically the first time a session touches a file in that folder, and
  costs nothing on a session that never does. The first holds the hard rules common to every
  adapter; the second holds the BizHawk/Lua host rules Crystal and Emerald share. Both are capped
  at 300 lines for the same reason the root file is, and neither restates it. Added 2026-08-25,
  moving content out of `_template/` that was only reachable by reading it end to end.
- **`.claude/skills/new-adapter/` and `.claude/skills/write-a-probe/` — required reading, sequenced.**
  A skill's body loads only when invoked, so these carry the order to read things in without
  spending context until the moment they apply. They are maps, not copies: every rule keeps one home.

**The one-line map, if you are new here** (user's framing, 2026-08-19, corrected on one point):

| Kind | Where | Lifetime |
|---|---|---|
| **The rules** | `CLAUDE.md` | Permanent, always loaded, hard 300-line cap |
| **Working state** — what is open right now | `status.md` | Deliberately volatile: overwritten in place, items deleted when done |
| **What we know** | `verified.md` (append-only, dated), `pitfalls.md` (symptom → cause → fix), `phases/` | Permanent |
| **What we intend** | `plans.md` (committed), `ideas.md` (not) | Until done or dropped |
| **The machine and the conventions** | `environment.md` | Updated as the setup moves |
| **Driving a running game** | `playing.md` | Updated when the user rules on what is allowed |
| **Who the USER is** | agent memory, outside the repo | Permanent — and **never project facts**, which the repo must own |

The correction worth making explicit: **agent memory is long-term memory about the user, not about
the work.** The project's own long-term memory is `verified.md` + `pitfalls.md` + the phase files —
the things a human, a future session and CI can all read. Anything about the code that lives only
in agent memory is invisible to all three and goes stale with nothing to catch it.

- [access-models.md](access-models.md) — **what you can read about a game**, which predicts an
  adapter's difficulty better than its engine does. What each shipped adapter used (decompilation /
  self-documenting artifact / runtime reflection), the other approaches that exist, and a checklist
  for working out what a new game offers. Read before starting a new adapter.
- **`adapters/_template/probes.md` — how to build a probe that answers something**: searching for a
  value you cannot name (drive an input one way, then reverse it), instrumenting a running game
  without changing what it does, what a probe is allowed to cost, and the two ways a probe lies.
  It sits with the template rather than here because it is adapter work; read it before writing one.
- [crowd-limits.md](crowd-limits.md) — **how many ghosts a game can actually hold**, per game and
  per map, and what happens past that. An emulated game has a fixed array of character slots and a
  fixed hardware sprite budget, both settled by the Game Boy's own hardware, so this has a hard
  answer no amount of relay capacity changes. Includes the reusable measuring rig (synthetic peers
  over the real relay, engine-side probe, frame-rate check). Ask it early for a new game.
- [effect-investigation.md](effect-investigation.md) — **how to search**: the procedure for finding,
  mirroring and confirming a game's visual effect, told through the Pseudoregalia afterimage/trail
  investigation start to finish. Complements the other two rather than repeating them —
  [pitfalls.md](pitfalls.md) is what went wrong, `_template/README.md` is what to build, this is how
  to go looking. Read it before starting effect/VFX work on a new game.
- `phases/` — a file per phase. Kept around after the phase ends as a work log/archive
  rather than folded away — [status.md](status.md) and [plans.md](plans.md) stay the
  current-state summary. **Read them as dated records, not as current fact.** Notably, every
  `internal/protocol|transport|bridge|core|relay|netx` path written before 2026-08-17 is now at
  the repo root (`protocol/`, `core/`, …) — see the module-rename ADR in
  [architecture.md](architecture.md). Those paths are left as written rather than rewritten,
  because a phase file records what was true while the phase ran.
- [claude-md-cap.md](claude-md-cap.md) — why `CLAUDE.md` holds a hard 300-line cap, and why
  `status.md`'s cap is per-item rather than a flat line count. The evidence behind two rules
  that otherwise read as arbitrary.

**`../docs/` is the other half of the documentation, and it is not this folder's job.** It is
written for people *using* MeshGhost; `agent_docs/` is the internal record of how it was built.
Four files, all one level up:

- [../docs/security.md](../docs/security.md) — security and privacy posture: what's already
  checked-safe (no client ever learns a peer's IP; room-code auth, protocol- and game-version
  checks, and bounded reads all shipped 2026-08-14) versus the gaps that remain. Since
  2026-08-16 `quic` is the default, so a room code is encrypted by default, and TLS over `tcp`
  landed 2026-08-19 — but the certificate is unverified, so encrypted is not authenticated, and
  `udp` is still plaintext with no fix available.
- [../docs/networking.md](../docs/networking.md) — how the relay and client actually work,
  traced through the real code: the life of a connection, the life of a state message, the
  concurrency model, the transports, the limits. Read it before changing any of them.
- [../docs/integrating.md](../docs/integrating.md) — putting MeshGhost into a game whose source
  you own, in any language: the sidecar bridge (least work, and what every shipped adapter
  does), importing the Go packages, or reimplementing the relay protocol. **Unsupported and
  untested by us** — we test the relay, the client and our own adapters, nothing else — but it
  records the things only the Go source knew: the QUIC rules an implementer must match exactly,
  a real captured wire transcript, and what the relay answers versus drops in silence.
- [../docs/antivirus.md](../docs/antivirus.md) — why the unsigned Go binaries get flagged, the
  two separate causes, and what a user can verify instead of taking our word for it.

## How to use this folder

- [contract.md](contract.md) is the first thing to read before touching `core`,
  `relay`, or any adapter.
- Keep confirmed implementation facts in [verified.md](verified.md) — nowhere else, and never
  before the user has watched them work.
- Create `phases/phaseN.md` when phase N starts; leave it in place as a historical record
  once phase N ends (update [plans.md](plans.md)/[status.md](status.md) to reflect current
  state, don't delete it).

## Document structure and style

- Use clear headings and short sections.
- Prefer links over repetition — cross-reference instead of copying content between files.
- Keep each file focused on one audience: public readers ([README.md](../README.md) at repo
  root), planners ([plans.md](plans.md), [status.md](status.md)), implementers
  ([contract.md](contract.md), [architecture.md](architecture.md)), or verifiers
  ([verified.md](verified.md), [licensing.md](licensing.md)).
