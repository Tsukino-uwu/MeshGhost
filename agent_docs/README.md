# agent_docs — internal project documentation

The internal record of how MeshGhost is built: the contract, the guides, the records, and what is
open. **Grouped by KIND, one line per file** (regrouped 2026-09-02; it had been in the order files
were added, with entries appended after the map that was supposed to explain them). The other half
of the documentation, written for people *using* MeshGhost, is [`../docs/`](../docs/), listed last.

## The rules and the contract

- [contract.md](contract.md) — **the durable artifact**: packet schema, message types, adapter interface, transport, tick model, limits. A change is a contract revision: a new file in `adr/`, indexed in `architecture.md`.
- [architecture.md](architecture.md) — system shape, package boundaries, and **the index to the decision log** in `adr/` (one file per ADR, dated in its filename; `preflight.ps1` fails an unindexed one).
- [claude-md-cap.md](claude-md-cap.md) — why `CLAUDE.md` and the nested rule files are capped, why nothing else is, and why indexes and queues are held to one line per entry instead (the six cases, dated).
- [licensing.md](licensing.md) — the third-party audit and the gate: a project not listed has not been checked; `preflight.ps1` fails a citation in a living doc that this file does not name.
- [brief.md](brief.md) — the original design brief. **HISTORIC AND FROZEN**: never corrected, drift from it is history.

## Read before you…

- …start a new game's adapter: [access-models.md](access-models.md) — what you will be able to READ about a game predicts the adapter's difficulty better than its engine. Then `/new-adapter`.
- …do anything on the list of moments: [checklists/](checklists/) — **one page per moment** (a probe, a reading, a fix, a scripted edit, mirroring state, Unreal, Lua, a network change); one line per lesson, linking to the record.
- …touch `core`, `relay`, `transport`, `bridge` or a test: [testing.md](testing.md) — the one local command, the `-race` recipe, what CI adds, how to run a fuzz campaign, the traps.
- …propose efficiency or scale work on the Go side: [scaling.md](scaling.md) — the no-ceiling principle, the four axes and their measured ranking, the ratified JSON-over-binary decision.
- …decide who receives what: [culling.md](culling.md) — the culling model, distance culling, adaptive Hz, culling an isolated player's uploads (split out of `scaling.md` 2026-09-02; nothing scheduled).
- …raise `send_hz` or touch the snapshot buffer: [hz-ceiling.md](hz-ceiling.md) — where the buffer edge-holds, what timestamps cost, bandwidth per room size.
- …ask how many ghosts a game can hold: [crowd-limits.md](crowd-limits.md) — per game and per map, with the measuring rig; the game-side pair to `scaling.md`.
- …start effect/VFX work: [effect-investigation.md](effect-investigation.md) — how to search for, mirror and confirm a game's visual effect, told through the Pseudoregalia trail.
- …drive a running game yourself: [playing.md](playing.md) — what an agent may change, how to steer input, navigate, use screenshots.
- …run a live test: [running-the-rig.md](running-the-rig.md) — start the scaffolding hidden, the netsim default, two games at once, several agents, crash dumps, the savestate slots (split out of `environment.md` 2026-09-02).
- …set up or trust the machine: [environment.md](environment.md) — host, toolchain, BizHawk's Lua capabilities, the decomp workspaces, Unity/UE installs, onboarding, conventions.
- …propose anything past Tier 2: [beyond-cosmetic.md](beyond-cosmetic.md) — sync models, the five authority models, the readiness gaps; and [kill-credit.md](kill-credit.md) for enemy/boss sync. Nothing in either is scheduled.
- …write a probe: `adapters/_template/probes.md` — how to build one that answers something, and the ways an instrument lies. Sits with the template because it is adapter work; `/write-a-probe` sequences it.

## The records

- [verified.md](verified.md) — append-only, human-gated confirmed facts for the Go side and cross-game entries, plus the index to each adapter's own `VERIFIED.md`.
- [unverified.md](unverified.md) — the index to the four per-game queues; each `UNVERIFIED.md` opens with "This run — watch these first" and every entry is READY, OPEN or DONE.
- [pitfalls.md](pitfalls.md) — **how a lesson stops being paid for twice**: every lesson ends as a CHECK, a RULE or a RECORD; the filing rule. Reworked 2026-09-02.
- `pitfalls/` — the record: `INDEX.md` (every lesson, one tagged line), `method.md`, `by-host.md`, `by-lesson.md` (chronological; new entries go at its end). Nothing is filed per game, deliberately.
- `phases/` — **the complete running log per phase, appended every session** ([phases/README.md](phases/README.md) is the index and the rule). Read as dated records: paths are left as they were written, so files written before the 2026-08-17 module move say `internal/protocol|transport|bridge|core|relay|netx` for what is now at the repo root, and files before 2026-08-25 say `adapters/bizhawk/` for `adapters/emulator/`; `internal/README.md` became `../docs/networking.md` and `../docs/security.md`.
- [risks.md](risks.md) — assumptions and the risk register, open and closed, plus the known gaps carried out of `status.md`.
- [bandages-core.md](bandages-core.md) — shipped compensations in the Go side; per-adapter bandages live in each adapter's `BANDAGES.md`.
- [doc-history.md](doc-history.md) — the dated record of every doc-restructuring pass, what was left alone and why, and the archived idea texts. Quotes rules in their wording at the time, on purpose.
- [project-history.md](project-history.md) — the pre-planning retrospective, and the six Phase 0 questions with how each closed.

## Working state and ideas

- [status.md](status.md) — what is open right now: one dated line per item; an item dated more than 2 days before the file's last commit fails `preflight.ps1`.
- [plans.md](plans.md) — the roadmap: committed, in progress, done; non-goals; the depth ladder.
- [ideas.md](ideas.md) — where future plans and brainstorming are kept so they are not forgotten; nothing scheduled; title index at the top.
- [security-design.md](security-design.md) — the unscheduled security design behind `docs/security.md`'s posture (moved out of `ideas.md` 2026-09-02).
- [candidate-games.md](candidate-games.md) — games that might get an adapter and prior-art reads; nothing checked (moved out of `ideas.md` 2026-09-02).

## Rules that load themselves, and the two skills

- `CLAUDE.md` at the root, and `adapters/CLAUDE.md`, `adapters/emulator/CLAUDE.md`, `adapters/tevi/CLAUDE.md`, `adapters/pseudoregalia/CLAUDE.md` — read automatically on first contact with their folder; the only capped files, and their stack is budgeted.
- `.claude/skills/new-adapter/` and `.claude/skills/write-a-probe/` — required reading, sequenced; maps, not copies.

**The one-line map** (user's framing, 2026-08-19): the rules are `CLAUDE.md`; working state is
`status.md`; what we know is `verified.md`, the checklists and `phases/`; what we intend is `plans.md`
and `ideas.md`; the machine is `environment.md`, running it is `running-the-rig.md`, driving the game
is `playing.md`; **who the USER is lives in agent memory, outside the repo, and never a project fact**.

## `../docs/` — written for people using MeshGhost

- [../docs/config.md](../docs/config.md) — every `config.json` key, its shipped value, what it does, which program reads it.
- [../docs/networking.md](../docs/networking.md) — how the relay and client actually work, traced through the code: connections, state messages, concurrency, transports, limits.
- [../docs/security.md](../docs/security.md) — the security and privacy posture: what is checked-safe versus the known gaps, per transport.
- [../docs/reviewing.md](../docs/reviewing.md) — the reviewer's front door: which code a host runs, where the claims are, how to run the fuzzers and the race suite yourself.
- [../docs/integrating.md](../docs/integrating.md) — putting MeshGhost into a game you own, in any language; unsupported and untested by us, but the wire facts are here.
- [../docs/antivirus.md](../docs/antivirus.md) — why the unsigned binaries get flagged and what a user can verify.
- [../docs/live-reload.md](../docs/live-reload.md) — how each host reloads adapter code into a running game.

## How to use this folder

- `contract.md` first, before touching `core`, `relay` or any adapter; the relevant `checklists/` page before doing the thing.
- Confirmed facts go in `verified.md` or an adapter's `VERIFIED.md`, never before the user has watched them work.
- Before a session ends, append to the active phase file ([phases/README.md](phases/README.md)); re-date or move `status.md`'s items at the start of the next.
- Cross-reference instead of copying; one audience per file; a rule has one home and every copy links to it.
