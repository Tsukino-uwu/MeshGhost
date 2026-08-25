# Why CLAUDE.md is capped at 300 lines

<!-- line-cap: 100 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

The cap is the highest-priority rule in `CLAUDE.md` — it outranks every rule below it. This file
holds the reasoning, which is exactly what the cap requires: the rule stays there, its explanation
lives here.

## The reasoning

Research cited by the humanlayer guide puts frontier thinking models at roughly **150–200
followable instructions**, and finds that degradation past that point is **uniform, not
tail-first**. More instructions does not mean the bottom of the file gets ignored while the top
still works. It means *every* rule gets followed slightly worse — including the ones that exist
because something already went wrong once, which are the expensive ones to lose.

Source: <https://www.humanlayer.dev/blog/writing-a-good-claude-md>

**So a longer rules file is a weaker rules file.** That is the whole argument, and it is why the cap
outranks the rules it constrains: every one of them depends on the file staying short enough to be
obeyed. A rule added past the cap does not add a rule — it quietly weakens all the others.

## What this means in practice

- **Adding a rule is nearly always right. Adding an *explanation* of a rule usually isn't.** If a
  rule needs a paragraph of justification, the rule goes in `CLAUDE.md` and the paragraph goes in
  `agent_docs/`, with a one-line pointer.
- **When the file would exceed 300 lines, something comes out first.** The question is never "can I
  add this?" but "what comes out to make room?" Trimming later does not happen.
- **Prefer moving reasoning over deleting rules.** A rule that cost a live incident to learn should
  survive as a single imperative line, not be dropped because its story was long.
- **Dates and one found-live example earn their place**; a full retelling does not. "Found live
  2026-08-16" plus a pointer beats five lines of narrative.

## The same failure, one level down: `status.md`

`agent_docs/status.md` had a flat ~50-line cap and it did not work. The cap bounded the *file* but
nothing bounded *per-item verbosity*, so every item arrived carrying its own rationale — averaging
3 lines, one reaching 6 — and the total crept back regardless. The dates, re-checked against
`git log` 2026-08-18 (the earlier version of this paragraph had them off by a day): the file peaked
at **628 lines on 2026-08-14**, was cut to **132 the next day**, and had crept back to **116 by
2026-08-16** — all with the flat cap nominally in force, and all far over the ~50 lines it stated.

Replaced 2026-08-16 with a per-item limit: **two lines per item, maximum** — what is open, and where
the detail lives. Size then tracks the *number of open items*, which is real signal about the
project, instead of how much context each item drags along.

The general lesson, and the reason this is recorded next to the `CLAUDE.md` cap: **cap the thing
that actually grows.** A total-size limit on a document whose entries can each expand is a limit on
the wrong variable, and it will be defeated quietly rather than loudly.

## The third case: files that must NOT be capped (2026-08-25)

Applying "cap the thing that actually grows" across the whole repo turned up a category the rule
had not been stated for. **For a record, the thing that grows is the number of entries — and that
is real signal about the project, not bloat.**

Capping one is actively harmful, in a way a line count cannot see:

- **`VERIFIED.md`** — capping an append-only, human-gated record means deleting evidence in order
  to add evidence. The cap would be satisfied by destroying exactly what the file exists for.
- **`BANDAGES.md`** — a register whose growth is a *smell*. A cap would answer that smell by
  hiding it, which is the opposite of the register's job.
- **`FLAGS.md`**, `risks.md`, `pitfalls.md`, `ideas.md` — same shape. Size tracks how many
  switches, risks, incidents or unscheduled ideas exist. That number is worth seeing.
- **`UNVERIFIED.md`** and `status.md` — queues. Size tracks what is open, and the way to shrink
  one is to do the work, never to trim the file.

**So a file declares one of two things, and silence is a failure.** `<!-- line-cap: N -->` for
bounded content — rules, reference, a guide, an index — and `<!-- line-cap: none -- reason -->`
for a record. `dev-scripts/preflight.ps1` fails a tracked `.md` that declares neither.

**Why silence had to become a failure:** the check used to look only at files that declared a cap,
so an unbudgeted file was invisible to it. On 2026-08-25 that meant the 15 declaring files sat at
92–97% full while the nine largest documents — about 21,000 lines — had no backstop at all, and
nothing distinguished "deliberately uncapped" from "nobody ever gave it one".

**A record is bounded by SPLITTING it, never by refusing entries.** That is what happened to the
ADR log: 2,332 lines out of `architecture.md` into one file per decision, with the index left
behind. The cap then belongs on the index, which is bounded, and not on the record, which is not.
