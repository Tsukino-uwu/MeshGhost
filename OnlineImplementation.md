
# MeshGhost — Implementation walkthrough (placeholder)

This document is a living, non-technical walkthrough of how MeshGhost (formerly
GhostSync) is intended to be implemented. It is written in the style of a
practical implementation guide: what each major feature is, why it exists, and
where to look in the repository when the implementation is added.

Status: placeholder — the project has not yet implemented runtime code. Use
this to record verifiable, human‑observed evidence later. When populating,
always reference `agent_docs/verified.md` for any memory addresses or runtime
proof.

TL;DR

- Goal: cosmetic "ghosts" only — share position, area, and animation state.
- Two halves: relay server (game‑agnostic) and core client (engine‑agnostic).
- Adapters implement three functions: `get_local_state()`, `render_remote(id, state)`,
 and `despawn_remote(id)`.
- JSON packets follow the contract in `Ghostsync brief.md`.

Quick pointers (existing files)

- Project brief: [Ghostsync brief.md](Ghostsync%20brief.md)
- Verified facts (append-only): [agent_docs/verified.md](agent_docs/verified.md)
- Adapter examples: [adapter/games/pkmn emerald/README.md](adapter/games/pkmn%20emerald/README.md), [adapter/games/OriBF/README.md](adapter/games/OriBF/README.md), [adapter/games/Pseudoregalia/README.md](adapter/games/Pseudoregalia/README.md)
- This overview: [OnlineImplementation.md](OnlineImplementation.md)

## Contents

1. [The three components (relay / core / adapter)](#1-the-three-components-relay--core--adapter)
2. [Packet schema & contract](#2-packet-schema--contract)
3. [Transport and framing notes](#3-transport-and-framing-notes)
4. [BizHawk / Emerald adapter notes](#4-bizhawk--emerald-adapter-notes)
5. [Interpolation, loopback, and sampling](#5-interpolation-loopback-and-sampling)
6. [Phases & milestones (0..6)](#6-phases--milestones-0..6)
7. [Verification standard & evidence format](#7-verification-standard--evidence-format)
8. [Developer pointers (where code will live)](#8-developer-pointers-where-code-will-live)
9. [Testing & QA runbooks (example)](#9-testing--qa-runbooks-example)
10. [Relay server design notes](#10-relay-server-design-notes)
11. [Adapter implementation traps & tips](#11-adapter-implementation-traps--tips)
12. [UI / usability guidelines](#12-ui--usability-guidelines)
13. [Licenses & third-party audit](#13-licenses--third-party-audit)
14. [Community & permission notes](#14-community--permission-notes)
15. [Known failure modes](#15-known-failure-modes)
16. [What is deliberately not built](#16-what-is-deliberately-not-built)

## User-facing implementation overview (placeholder)

This file explains, in simple terms, what MeshGhost is, how it will work, and
where to look when development begins. It is intentionally a placeholder: the
structure and headings are set now so non‑technical contributors can read and
understand the project later. Fill each section with short, observable facts
and links to evidence when code exists.

Who this is for

- Non-technical users who want to understand what the project does.
- Testers and streamers who will verify behavior on-screen.
- New contributors who need a high‑level mental model before reading code.

How to use this file

- Read the short explanations under each heading to get a concept-level view.
- When a section is filled, it should include one-line proof: what was seen,
 when, and where the screenshot/video lives.

Contents (structure to be filled later)

- Project summary — one paragraph you can paste into a forum.
- What you will see — plain checklist of visible behaviours to confirm.
- System components — short, non-technical descriptions (Relay, Core, Adapter).
- Phases & milestones — Phase 0..6, what success looks like for each.
- Quick runbook examples — single-command steps a tester can follow.
- Where the code will live — simple file pointers for curious people.
- FAQ & glossary — answer common questions in plain language.
- Evidence & verification format — how to record "I saw it".

Project summary (placeholder)

- Short explanation of the goal (one or two sentences). Example placeholder:
 "MeshGhost is a system that lets you see your friends as harmless visual
 "ghosts" inside solo games so you can share the experience without changing
 the game's story or items."

What you will see (placeholder checklist)

- "When I walk left, my X value decreases" — shows reading local state works.
- "A ghost appears on another emulator when someone else moves" — shows
 remote rendering.
- "A ghost disappears when the other player leaves the map" — despawn.

System components (non-technical)

- Relay server: a small online service that forwards messages between players.
 (Think of it as a post office for ghost positions.)
- Core client: the part that runs next to the game and decides when and how to
 draw remote players. It also smooths movement so ghosts do not jump.
- Adapter: small per‑game code that reads the game's position and draws ghosts
 in that game's coordinate system.

Phases & milestones (placeholder)

- Phase 0: Design complete on paper. (Files: `Ghostsync brief.md` and
 `agent_docs/verified.md`.)
- Phase 1: Read-only adapter prints positions to a console.
- Phase 2: Fake ghost drawn locally (no network).
- Phase 3: Loopback test with a local relay.
- Phase 4: Two-player test across two instances.
- Phase 5: Extract core into a reusable library.
- Phase 6: Port adapter to second game.

Quick runbook examples (placeholder)

- These will be short numbered steps for a tester. Example placeholder:

 1. Open emulator and load the ROM.
 2. Run the BizHawk Lua script that prints X/Y values.
 3. Walk left and check the console for decreasing X.

Where the code will live (simple pointers)

- `Ghostsync brief.md` — design rules and contract.
- `agent_docs/verified.md` — runtime-verified facts (append-only).
- `adapter/` — per-game adapters and notes.
- `client/` — core client code (transport, interpolation).
- `server/` — relay server code and config.

FAQ & Glossary (placeholder)

- What is a "ghost"? — A purely visual representation of another player.
- Will this change my save files? — No: nothing about game progress is shared.

Evidence & verification format

- Each completed check should record: what was observed, date/time, and a
 screenshot or short video path. Example:
 "Observed: ghost drawn at (x=120,y=48) while walking right; 2026-08-09; screenshot: docs/evidence/phase2.png"

Notes for maintainers

- Keep this file non-technical and concise. Link to technical files rather than
 reprinting code. When filling placeholders, always add a one-line evidence
 statement and a link to `agent_docs/verified.md`.

Next step

- If you want, I can turn one Phase into a complete, step-by-step runbook for
 testers (commands, expected output, and evidence checklist). Which Phase
 should I prepare first?
When code exists, add exact file paths and function names here. Current repo
