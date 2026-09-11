# Phases — the index

**One file per phase, kept after the phase ends as a work log.** `status.md` and `plans.md` are
the current-state summary; these are not. **Read every one as a dated record, not as current
fact** — a phase file says what was true while that phase ran, which is exactly why the paths in
it are left as written rather than rewritten. Each affected file carries that note at its own top.

This index exists because `preflight.ps1` now fails a phase file that is missing from it. Every
other required-reading class in this repo — ADRs, pitfalls, VERIFIED entries — already had an
index and a check; phase files were the one class with neither, so a new one could be added and
never referenced from anywhere. Added 2026-08-25.

| Phase | What it covers | The log is... |
| --- | --- | --- |
| [phase1.md](phase1.md) | Emerald read-only verification — the first addresses, confirmed by walking. | **Frozen 2026-09-06**; Emerald continues in phase 8 |
| [phase2.md](phase2.md) | Fake ghost, no network — proving the screen-position maths offline. | **Frozen 2026-09-06**; Emerald continues in phase 8 |
| [phase3.md](phase3.md) | Loopback — one client sending state and rendering it back to itself. | **Frozen 2026-09-06**; the Go side continues in phase 10 |
| [phase4.md](phase4.md) | Two players — joins, drops, and `area_id` mismatch. | **Frozen 2026-09-06**; the Go side continues in phase 10 |
| [phase5.md](phase5.md) | Extract the template — the core running against a fake adapter, no game. | **Frozen 2026-09-06**; the Go side continues in phase 10 |
| [phase5_5.md](phase5_5.md) | A real, gender-correct Emerald sprite in place of the magenta box. | **Frozen 2026-09-06**; Emerald continues in phase 8 |
| [phase6.md](phase6.md) | Second game: TEVI (Unity/Mono, BepInEx). | Live — TEVI's whole log |
| [phase7.md](phase7.md) | Third game: Pseudoregalia (UE5, UE4SS). The largest record here. | Live — Pseudoregalia's whole log |
| [phase8.md](phase8.md) | Emerald, dedicated — the post-5.5 animation and effect work. | Live — Emerald's whole log |
| [phase9.md](phase9.md) | Fourth game: Pokémon Crystal (GBC) — the first **spawned** ghost rather than a drawn one. | Live — Crystal's whole log |
| [phase10.md](phase10.md) | The online stack: relay, client core, protocol, transports — one component log for the whole Go side, backfilled to the repo's start. | Live — the Go side's whole log |
| [phase11.md](phase11.md) | Replays: recording, playback ghosts, the chaser pack, system-wide hotkeys, split times — Go-side feature work (ADRs 0047, 0048). | Live — planned 2026-09-03 |
| [phase12.md](phase12.md) | Delivery: packaging, the release pipeline, CI and the gates — one component log for what ships and what checks. | Live — created 2026-09-11 |

**Frozen is not "done" (the user's call, 2026-09-06).** The six early files mixed the server, the
client and Emerald together before each stream had a log of its own; their work continues in phases
8 and 10, so nothing is appended to them and their headers say so. Every other log is live, and
"feature complete" in any header is a dated playable-state marker, never a closed component.

**There is no "done" column, on purpose (the user's call, 2026-09-02).** A game is never done —
every shipped adapter is in progress for as long as the game has a state nobody has watched — so a
per-phase status only ever said "done" about the six early files whose work moved into a dedicated
log. What a reader needs is which file to APPEND to: a closed log is history, a live log is the
one that keeps being fed. Current state lives in `status.md`, never here.

**Adding one:** create `phaseN.md`, give it the dated-record note at the top, and add its row
here. Numbering follows `plans.md`'s roadmap, and a `.5` is legitimate — Phase 5.5 was real work
that did not warrant its own integer.

**A phase file is the COMPLETE running log of its adapter, appended EVERY SESSION** — the user's
call, 2026-09-01 and again 2026-09-02, when every live log had become a catch-up summary written after
the fact ("Catch-up record, written 2026-09-01 — the active phase's missing week"). Append a dated entry
to the active phase file: what was tried, what happened, what the user said, and links to the VERIFIED,
UNVERIFIED and pitfalls entries it produced. Facts and lessons still live in their records; this is the
timeline that ties them together. **Never split a phase file, and never edit a past entry** — append a
dated correction.

**WHEN to append: as soon as a result lands, and never later than the session's end (the user,
2026-09-11).** The original rule said only "before a session ends", and **a session may not get an
end** — a chat can be abandoned, interrupted or replaced mid-work, so a trigger that fires only on a
clean finish is a trigger that sometimes never fires. A result is a confirmation, a fix, a
measurement, or a theory refuted; that moment always arrives, because it is the moment you commit.
**This is NOT "an entry per commit"** — most commits are intermediate steps in one result, and an
entry for each would make this file a second copy of the commit log, burying the entries that matter
under the ones that do not.

**What saves you when a session ends badly is the COMMIT MESSAGE**, so write it as though it is the
only record — in this repo it often is. Proved 2026-09-11: five unlogged days across four adapters
were reconstructed into real entries from their commit messages alone, by an agent present for none
of them. The substance survives an abrupt ending; only the index is lost, and the index is
recoverable. That is the whole reason the gates below can be a safety net rather than a rescue.

**Two gates, on different axes** (`dev-scripts/preflight.ps1`): "Phase log freshness" fails a live
log once its adapter has three commits the log does not mention — it catches *you have stopped
writing*. "Phase log coverage" fails a date on which an adapter changed with no entry claiming it —
it catches *this specific day was never written*, which freshness structurally cannot see, because a
one-commit day never reaches three and the counter resets whenever the file is touched for any other
reason. Every gap found in the 2026-09-11 audit was a one- or two-commit day, including six that
postdated the freshness gate.

**A ONE-LINE POINTER IS A COMPLETE ENTRY.** Written down 2026-09-11, because a coverage gate without
this pushes whoever hits it into retelling a repo-wide sweep in five files, which is worse than the
gap — it buries the real entries in churn. Both of these fully satisfy the rule:

- **A pointer**, when the day's work is genuinely logged elsewhere: *"2026-09-04 — pointer: the
  day's three commits are logged in [phase9.md](phase9.md)"*. Most gaps are this shape, because the
  cause is nearly always one commit touching several adapter trees while only one phase file gets
  written (TCP_NODELAY touched four; the bridge-port config touched all four).
- **One heading absorbing several incidental dates**, for repo-wide sweeps that changed an adapter's
  files without a session happening: *"Repo-wide sweeps that touched this adapter's files —
  2026-08-19, 2026-08-21, 2026-08-25"*. Spell the dates in full so a date-aware reader finds them.

**Put the date in the section heading, in full.** A date mentioned only in a body is reachable by
reading the file and by nothing else — which is how Fly came to look absent from Emerald's own phase
file while being documented inside it (2026-09-11). Sections that legitimately carry their dates
inline — a `## Tasks` checklist, an early phase's topic sections — are exempt and the coverage gate
skips them.

**Go-side (core/relay/protocol/transport) work logs in [phase10.md](phase10.md)** — created
2026-09-01 on the user's call, the same way Emerald got its own file (phase 8) after being built
mixed into phases 1-5.5. ONE file for server and client together, deliberately: nearly every
Go-side event spans both, so two files would double-write or file arbitrarily. It is the
timeline; the detail stays in the ADRs and the topic docs it points at. **Phase 11 became the
replay work on 2026-09-03 and Phase 12 the delivery pipeline on 2026-09-11 (feature-sized and component-sized work each get their own log); the fifth game takes 13 onward.**
