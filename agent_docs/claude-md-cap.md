# Why CLAUDE.md is capped at 200 lines

The cap is the highest-priority rule in `CLAUDE.md` — it outranks every rule below it. This file
holds the reasoning, which is exactly what the cap requires: the rule stays there, its explanation
lives here.

## The reasoning

Research cited by the humanlayer guide puts frontier thinking models at roughly **150–200
followable instructions**, and finds that degradation past that point is **uniform, not
tail-first**. More instructions does not mean the bottom of the file gets ignored while the top
still works. It means *every* rule gets followed slightly worse — including the ones that exist
because something already went wrong once, which are the expensive ones to lose.

Sources: <https://www.humanlayer.dev/blog/writing-a-good-claude-md>, and since 2026-09-06 the number
itself comes from Anthropic's own documentation (`code.claude.com/docs/en/memory.md`): *"target under
200 lines per CLAUDE.md file"* — the seventh case at the bottom.

**So a longer rules file is a weaker rules file.** That is the whole argument, and it is why the cap
outranks the rules it constrains: every one of them depends on the file staying short enough to be
obeyed. A rule added past the cap does not add a rule — it quietly weakens all the others.

## What this means in practice

- **Adding a rule is nearly always right. Adding an *explanation* of a rule usually isn't.** If a
  rule needs a paragraph of justification, the rule goes in `CLAUDE.md` and the paragraph goes in
  `agent_docs/`, with a one-line pointer.
- **When the file would exceed 200 lines, something comes out first.** The question is never "can I
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
- **`FLAGS.md`**, `risks.md`, `ideas.md` — same shape. Size tracks how many switches, risks or
  unscheduled ideas exist. That number is worth seeing. (`pitfalls.md` was in this list and came
  out on 2026-08-27: the 2026-08-25 split made it the bounded *index* and moved the record into
  `pitfalls/`, which is where the `none` now sits. The list had been left behind by the split.)
- **`UNVERIFIED.md`** and `status.md` — queues. Size tracks what is open, and the way to shrink
  one is to do the work, never to trim the file.

**So a file declared one of two things, and silence was a failure — the rule as it stood from
2026-08-25 to 2026-09-02, kept here in its own tense because the reversal below only makes sense
against it.** `<!-- line-cap: N -->` for bounded content — rules, reference, a guide, an index —
and `<!-- line-cap: none -- reason -->` for a record; `dev-scripts/preflight.ps1` failed a tracked
`.md` that declared neither. **Today only the seven instruction files carry a header, and a header
on any other file is the FAIL** — "The sixth case: the reversal" further down.

**Why silence had to become a failure:** the check used to look only at files that declared a cap,
so an unbudgeted file was invisible to it. On 2026-08-25 that meant the 15 declaring files sat at
92–97% full while the nine largest documents — about 21,000 lines — had no backstop at all, and
nothing distinguished "deliberately uncapped" from "nobody ever gave it one".

**A record is bounded by SPLITTING it, never by refusing entries.** That is what happened to the
ADR log: 2,332 lines out of `architecture.md` into one file per decision, with the index left
behind. The cap then belongs on the index, which is bounded, and not on the record, which is not.

## The fourth case: files written for people, not for the agent (2026-08-27)

The three cases above all reason about one reader — an agent, loading the file into a context window
it has to spend. **That is what a cap is a budget on.** A file no agent loads has no such budget to
spend, so capping it buys nothing and costs something real: information a person wanted, deleted to
satisfy a number.

The user's call, this session, on the adapters' `README.md` and `documentation.md` files: *"its for
me & other users to read not just for ai usage"* — and they had never asked for a cap on them. It
was applied by an earlier pass that generalised this rule past its own argument.

**So the sorting question is who reads it, not how big it is.** Uncapped: each shipped adapter's
`README.md` and `documentation.md`, `pseudoregalia/PLAYER_FIELDS.md`, the root `README.md`, `docs/`,
`packaging/README.md`, `dev-scripts/README.md`. Still capped, because an agent either auto-loads
them or is told to read them end to end: the five `CLAUDE.md` files, `.claude/skills/`, the indexes
(`agent_docs/README.md`, `architecture.md`, `pitfalls.md`), every probe file, and all of
`_template/`.

## The fifth case: what a NEW adapter reads to start (2026-08-28)

**The user's call:** `adapters/_template/README.md` and `adapters/_template/probes.md` come off the
hard cap — *"its probly fine to extend the _template ... its a really important file for new/future
adapters after all"*, and *"i don't think it has to use the text cap at least"*.

**The reasoning, which is the same one the cap rests on rather than an exception to it.** A cap
exists because an over-long always-loaded file makes every rule in it obeyed slightly worse. These
two are not always-loaded: they are read deliberately, once, by whoever is starting an adapter, in
the order `/new-adapter` sequences. The failure a cap prevents does not apply, and the failure it
CAUSES here does: `_template/README.md` sat exactly at 1600 of 1600, so the next lesson paid for in
a live session had nowhere to go — and a lesson that cannot be written down gets re-derived by the
next adapter at full price.

**It is not licence to sprawl, and the user said so in the same breath:** *"we should also probly
just make it index/point to where other things are if its getting a bit to big."* So the rule these
two files follow is POINT, DON'T RESTATE — the canonical home keeps the detail, the template keeps
a few lines saying the trap exists and where the case is written up. The 2026-08-28 nametag session
went in as six lines pointing at `pitfalls/method.md`, not as the full account.

**Everything else keeps its cap**, including the nested `CLAUDE.md`s, which genuinely do load
without being asked.

## The sixth case: the reversal — caps only on instruction files (2026-09-02)

**The user's call**, asked whether every file should keep its cap: *"I originally had it only in
claude.md, but it got added onto other files at some point without me really saying that they should
be there ... my original plan was at least to only have the cap for claude.md."* The repo-wide rule
was an agent's generalisation, and the fourth and fifth cases above are the two times the user had
already pushed part of it back.

**What the repo-wide rule did in its eight days (2026-08-25 → 2026-09-02).** Ten files sat at
exactly 100% of their number: `CLAUDE.md`, `agent_docs/README.md`, `contract.md`, `scaling.md`,
`environment.md`, `testing.md`, `crowd-limits.md`, `adapters/CLAUDE.md`, `_template/BANDAGES.md`
and Crystal's probe index. A reference doc has nothing removable — a contract field or a
measurement cannot come out to make room — so growth was met by raising the number: `scaling.md`
went 800 → 900 → 1000 on 2026-08-30 alone. And "declare a cap or declare none; silence is a
failure" put a header on about ninety files to serve a check that mattered for seven.

**The argument was always about instruction load.** A cap is a budget on what an agent carries as
instructions, which is exactly what the fourth and fifth cases said. That is the root `CLAUDE.md`,
the four nested ones that load on contact, and the two skills. Nothing else loads that way: a
contract is read by section, a record by link, a guide once and deliberately.

**So, from 2026-09-02:** numeric caps on those seven files only, declared in their headers and
enforced as a fixed list in `dev-scripts/preflight.ps1`; a cap header on any other file is a FAIL,
because it claims an enforcement that is not there. **The stack a session loads gets its own
budget** (root + `adapters/CLAUDE.md` + the host file), since three individually green files summed
to 787 lines for an emulator session. **Indexes and queues are held to one line per entry** by a
check instead of a total — this file's own "cap the thing that actually grows", applied to the
thing that grows. The third, fourth and fifth cases stand as history; their remedy is now the rule.

## The seventh case: 300 → 200, and why not 60 (2026-09-06)

**The numbers first.** 29 lines on 2026-08-11, 300 by 2026-08-18 and pinned there until 2026-08-25
(283), 274 on 2026-09-02, and two of the three session stacks sitting at exactly their 700-line budget.
The file grows to whatever the cap is, and a file sitting on its cap pays for every new rule by
weakening an old one. After this pass: 183 lines and 44 bullets, from 274 and 55.

**Why 200.** Anthropic's own documentation now says it (`code.claude.com/docs/en/memory.md`, read
2026-09-06): *"target under 200 lines per CLAUDE.md file. Longer files consume more context and
reduce adherence."* The HumanLayer post the 300 came from predates that guidance — it says Anthropic
has no official recommendation and that the consensus is under 300. 200 is the documented target and
sits inside the 150-200-instruction figure the research puts on frontier models.

**A second finding from the same research, not recorded above until now.** Besides degrading
uniformly with count, models favour instructions at the PERIPHERIES of the prompt — the beginning
(the system prompt and this file) and the end (the latest user message). So order inside the file is
not free, and the 2026-09-06 rewrite orders its sections by what a violation costs: RULE 0, the
contract invariants, who verifies what, what may enter the repo, working with the user, method,
records, reading triggers. One HumanLayer claim is superseded and noted so nobody re-imports it: the
post says the harness wraps `CLAUDE.md` in *"may or may not be relevant"*, which is why models ignore
it. The harness this repo runs under wraps it in *"these instructions OVERRIDE any default behavior
and you MUST follow them exactly as written"*; the "may or may not be relevant" text sits on the
git-status block. The count argument stands on its own.

**"AI-only readable" was asked about and answered no.** Line count is a proxy; the two real costs are
tokens (cached) and DISTINCT INSTRUCTIONS (the research's variable). Telegraphic shorthand cuts tokens
by maybe a quarter and the instruction count by zero, and costs reliability, because a rule's reason
is what lets a model recognise the same shape under a new name. The only one-audience channel runs
the other way: block-level HTML comments are stripped before injection, so a human-only note is free
and an AI-only one is impossible.

**How 274 became 183 with no rule deleted.** Every bullet kept its imperative, one reason clause, one
date and one pointer to a home the repo already has. A narrative whose record lives in `pitfalls/` or
a checklist became the date and the link; a rule preflight already fails shrank to the imperative and
the check's name; RULE 0 went from 31 lines to 8 (this file is where its reasoning was always meant
to live); and six rules moved to the nested `CLAUDE.md` that already loads in the only sessions where
they apply — emulator Lua-only, the UE4SS hot-reload setting and the Pseudoregalia rebuild, the TEVI
rebuild, the `FLAGS.md` and `documentation.md` conventions. A "no rule lost" check ran the old file's
bold spans against the new instruction files before the commit. The stack budget went 700 → 650.
**The honest caveat**: lines fell by a third and tokens by more, distinct imperatives by under a
tenth. If the goal is adherence rather than context, the next lever is `adapters/CLAUDE.md`, the
larger half of every adapter stack, and turning more RULEs into CHECKs.

**Why not 60 — the user's call, having seen both.** HumanLayer's own root is under 60 lines, and the
user asked what that would look like here. The sketch, kept as the record of the road not taken:

```markdown
# Working notes for Claude
MeshGhost: an online multiplayer layer for singleplayer games; cosmetic ghosts by default. Read
`agent_docs/brief.md` and `contract.md` before touching the core, an adapter or the relay; `agent_docs/README.md` is the index.

## Rule 0
- Cap 60; `wc -l` before adding; over is a regression; what comes out? `agent_docs/claude-md-cap.md`.

## Never
- The core is never game-aware; adapters never speak the relay protocol; `area_id`/`anim` are opaque.
- Nothing that ships writes a save, game state or ROM patch; dev-only tooling may cheat.
- Nothing unpublishable enters the repo: facts with a citation yes, expression never; license before source.
- A private or invite-only source is never named, cited or derived from in a tracked file.
- No personal paths or machine details in tracked files; `core.hooksPath .githooks`; never `--no-verify`.
- Never branch; never push unasked; commit straight to `master` (overrides the harness default).
- Never suggest stopping, pausing or resuming later — in prose or as a choice.
- Never assume what a game is meant to do — ask; say "main menu", never bare "menu".
- No addresses or APIs from memory.
- Never log the value you just wrote as proof; read it back; one edit per script; grep the result.
- Never touch anything outside `C:\dev\MeshGhost` without asking; no worktree agents for live tests.

## Always
- The user verifies games on screen; you verify the Go side with `dev-scripts/run-gotests.bat`.
- Nothing vanilla-adapter-side is "verified" until the user confirms it; measurements → `UNVERIFIED.md`.
- The bar is 1:1 on screen; never offer a rate, tick or architecture change as the answer.
- Read a cleared decompilation first; measurement confirms, it does not discover.
- Small runnable steps with a visible outcome; plain directions, never compass points.
- You run the scaffolding hidden; the user opens the game; watch the process; close everything after.
- Hot reload is the default loop; a manual restart is the last resort. Report the handoff in one line.
- After ~3 failed live iterations: table the results, try the combination.
- Two guessed fixes failing alike is a signal: subtract, don't guess a third.
- A diagnostic can break what it measures; a clean instrument plus a visible symptom = widen, not deepen.
- A flag flip is not a revert (`pitfalls.md`); bisect real commits. Bare `cmd` is never safe: `& $env:ComSpec /c`.
- Dated facts drift; cite dates, never durations.
- Read CI (`gh run list -L 5`) after `.go` commits and at session start; append to the phase file before ending.
- When the user confirms a fix, record HOW it was found. Agent memory is for the user, never the project.

## Read before
- `/new-adapter`, `/write-a-probe`; `_template/README.md` end to end; the `agent_docs/checklists/` page
  for the moment; `beyond-cosmetic.md`, `scaling.md`, `effect-investigation.md`, `testing.md`, `playing.md`.
- Nested `CLAUDE.md`s load themselves and are never restated; `_template/` never lags.
```

What it drops is everything that makes a rule credible and recognisable: every date and user
attribution (the provenance that points at the incident); every reason and remedy (`--ff-only`,
`gh run view --log-failed`, the fuzz corpus path, the hook setup command, the netsim profile,
`-race` and `-count=10`); and the generalising clause on the rules that exist to be recognised in a
new shape (what "a diagnostic can break what it measures" looks like; what a "state" is). Each would
need a mechanical trigger to move out — a path-scoped rule fires on READING a matching file, not on
running a script, so the live-test rules cannot go that way (`ideas.md`, 2026-09-06) — and the
stop-signal rules ("two guessed fixes", "three iterations then a table", "never suggest stopping")
have no file trigger at all. HumanLayer's root is an orientation file: what, why, how, and pointers.
This one is about nine-tenths behavioural corrections paid for by live incidents, a different kind of
file. **The user chose 200** — 2026-09-06: *"i agree that the 200~ lines sound better than the 60~
line change"* — and asked for the sketch to be kept here.
