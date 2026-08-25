---
name: new-adapter
description: Read before building a MeshGhost adapter for a new game — before creating its first file. Sequences the required reading (access model, contract, template, licensing) into the order the work actually needs it, instead of one 1,500-line pass. Use when starting a new game's adapter, evaluating whether a game is adaptable, or picking up adapter work on a game with no adapter yet.
---

# Starting a new game's adapter

This skill is a **map, not a copy**. Every rule still lives in one place; what was missing was an
order to read them in. The mandate that produced this was written because reading the top of
`adapters/_template/README.md` and starting work failed twice on 2026-08-17, "both times with the
answer already sitting further down the file" — that is a retrieval failure, and a sequence fixes
it more cheaply than endurance does.

**Rules that are already loaded, and are not repeated here:** the root `CLAUDE.md`, plus
`adapters/CLAUDE.md` (every-adapter hard rules) which loads itself the moment you touch anything
under `adapters/`, plus `adapters/emulator/CLAUDE.md` if the game is an emulated one.

## Before you decide anything

1. **`agent_docs/access-models.md`** — what you will be able to READ about this game. This
   predicts an adapter's difficulty better than its engine does, and it is the question that
   changes every later decision. Answer it first.
2. **`agent_docs/licensing.md`** — **read a project's license before reading its source.** If a
   reference project is not listed there, its license has not been checked; do not use it until
   it is. A private or invite-only source is a harder no: never named, linked, cited or derived
   from in any tracked file.
3. **`agent_docs/contract.md`** — the packet schema, the adapter interface, the transport
   contract. Read at minimum its adapter-interface section. This is the most durable file in the
   repo and the thing your adapter has to satisfy.
4. **If the game has a cleared decompilation, READ IT** rather than measuring your way to what it
   already says. `licensing.md` clears all four `pret` decomps for facts-with-a-citation.
   Measurement is for CONFIRMING what the source says, not for discovering it.

## Then, in `adapters/_template/README.md`, these sections in this order

- **"Folder convention"** — where the files go, and which are expected of every adapter
  (`README.md`, `BANDAGES.md`, `FLAGS.md`, `documentation.md` — no exceptions).
- **"Starting a new game's adapter"** — the numbered setup steps.
- **"First, work out what you will be able to READ"** — the access-model table applied.
- **"Where does this already happen normally?"** — pick the common path, not the matching
  feature. This is the single most useful habit in the file.
- **"Ask the game what it has, before you guess at what it might have"** — enumerate first.
  Guessing at names produces plausible numbers instead of errors, which is worse than crashing.
- **"Read the working adapter for the same host before writing a new script"** — open it and copy
  its shape before writing anything.
- **"A new game gets its own `agent_docs/phases/phaseN.md`"** — create it when the folder is
  created, and **ASK the user for the phase number.**

## Before you write the first probe

Invoke `/write-a-probe`. A probe can break the thing it measures, and then every reading agrees
with itself — that is the most expensive lesson in this repo.

## While building

Read these when you reach them, not up front:

| When | Read |
|---|---|
| starting effect/VFX work | `agent_docs/effect-investigation.md` — before it goes wrong, not after |
| the game may not hold many ghosts | `agent_docs/crowd-limits.md` — ask it early |
| about to compensate for something | `adapters/_template/BANDAGES.md` — is this a bandage? |
| driving the running game yourself | `agent_docs/playing.md` |
| writing the adapter's own README | `_template/README.md`, "Writing the new adapter's own README" |
| adding a compile-time switch | `adapters/_template/FLAGS.md` |

## The two that decide whether it ships

- **The bar is 1:1**, judged ON SCREEN, not by matching numbers. "Close" and "only during the
  transition" are open, not done.
- **Nothing that ships writes a save, game state, or a ROM patch** — ever, not even as a feature.
  Dev-only test tooling may cheat; an adapter may not.

## Back-port

`adapters/_template/` is the gold standard and may never lag. A rule, file or trap this adapter
learns is back-ported **in the same pass**, not later.
