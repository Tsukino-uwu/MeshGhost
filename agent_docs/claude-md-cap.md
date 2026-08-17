# Why CLAUDE.md is capped at 300 lines

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
3 lines, one reaching 6 — and the total crept back regardless: **628 lines once (2026-08-15), then
106 the next day even with the cap in force.**

Replaced 2026-08-16 with a per-item limit: **two lines per item, maximum** — what is open, and where
the detail lives. Size then tracks the *number of open items*, which is real signal about the
project, instead of how much context each item drags along.

The general lesson, and the reason this is recorded next to the `CLAUDE.md` cap: **cap the thing
that actually grows.** A total-size limit on a document whose entries can each expand is a limit on
the wrong variable, and it will be defeated quietly rather than loudly.
