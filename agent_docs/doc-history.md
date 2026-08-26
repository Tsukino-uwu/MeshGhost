# Doc restructuring — the record

<!-- line-cap: none -- append-only record of doc restructuring passes; it QUOTES canonical rules verbatim, which is why preflight exempts it from the canonical-source check. Why a record is exempt: agent_docs/claude-md-cap.md. -->

**What this is:** the dated record of every pass that has restructured this project's
documentation — what was changed, what was deliberately left alone and why, and the measurements
behind each decision. Split out of `ideas.md` on 2026-08-25.

**Why it is not in `ideas.md`:** that file is an unscheduled feature backlog, and this is neither
unscheduled nor a feature — it is history. Keeping them together gave `ideas.md` three jobs
(backlog, restructuring record, and an archive that quotes canonical rules verbatim) and forced
`preflight.ps1` to exempt the whole file from the canonical-source drift check. That exemption now
travels with the record, so the backlog is checked like every other file.

**Why it is exempt at all:** this record quotes rules — the bandage tells, the two-lines-per-item
rule — in the wording they had at the time, on purpose. A record that silently re-words itself to
match the current rule is not a record. Everywhere else, a restated rule must link to its home.

**Adding a pass:** append a new `## ` section with its date. Do not edit an existing one to match
what is true now; add the correction as part of the new pass, the way `verified.md` does.

## Doc restructuring: what was done, and the measurements not to re-derive (2026-08-25)

Two passes have now touched this. The 2026-08-25 **repair** pass fixed facts and collapsed
duplication. The 2026-08-25 **staged-context** pass (commits `64c3162`..`47d4537`) built the
delivery mechanism: `adapters/CLAUDE.md` and `adapters/emulator/CLAUDE.md` (nested files that load
themselves on contact), `.claude/skills/new-adapter/` and `.claude/skills/write-a-probe/`, and the
`CLAUDE.md` cap reclaimed from 299 to 278 by deleting an index that duplicated
`agent_docs/README.md`.

**That second pass built the machinery and deliberately did not solve the volume problem.** The
end-to-end mandated read fell only ~7% (3,537 -> 3,302 lines across the two `_template` files);
327 lines moved to load-on-contact or load-on-demand. Everything below is what remains, with the
measurements behind it, so none of this is worked out twice.

### 1. Condense the rules, relocate their evidence — the pass that actually shrinks things

`_template/README.md`'s 13 `## Hard rule:` sections total **734 lines**, so they cannot all fit a
300-line cap. Six were moved verbatim to `adapters/CLAUDE.md`. The rest cannot be *relocated*,
only *condensed*: each rule reduced to its imperative plus a one-line dated stub, with the
narrative going to `pitfalls.md`. **That is a rewrite of rule text and the highest-risk item in
any of this.**

Still to condense: the bandage rule (51 lines), find-out-how-the-GAME-does-it (237), ghost-liveness
gating (86), ship-the-bare-minimum (69). Left in `_template/` on purpose: "this folder is the gold
standard" (it is about `_template` itself) and "Hard rules, restated" (a third copy of rules
already in the root `CLAUDE.md`).

**Bucket split, measured across both template files (3,537 lines at the time):** RULE ~1,185
(34%), RATIONALE/dated evidence ~945 (27%), PROCEDURE ~740 (21%), REFERENCE ~515 (15%), EXAMPLE
~90 (3%). **The evidence needs no new file — `pitfalls.md` already is "symptom -> diagnosis ->
fix".**

**Two sections resist a host split** and were left for this pass: the tier ladder and "Measure
what is DRAWN, not the fields that feed it" alternate a general rule with GBA/Game Boy mechanics
paragraph by paragraph, so splitting them by host means splitting rule from evidence.

**Also here:** `probes.md:827-894` holds a third copy of the logging-cost rule (the other two were
at `README.md:496-514` and `544-554`); the read-budget rule and the probe cost warning are each
stated twice across the two files. Neither file has a table of contents, section numbering or any
priority marker — **that is the retrieval failure the end-to-end mandate was written to paper
over**, and `probes.md` has been compensating in-band with its "the three that cost the most, if
you read nothing else" triage block.

### 2. The four multiply-stated rules, with verdicts

- **Publishability header, 5 copies — KEEP.** Byte-identical modulo relative-link depth, mandated
  on purpose at `_template/README.md`, and it propagates by copying `_template/documentation.md`
  forward, which is why it never drifted. **One defect: `adapters/pseudoregalia/documentation.md`
  is missing the provenance sentence `licensing.md`'s audit greps for.**
- **Bandage block, 6 copies — ALREADY DRIFTED, live in the tree.**
  `emerald/BANDAGES.md:17` and `bandages-core.md:20` say "all **seven** after-the-fact tells";
  `pseudoregalia:18`, `tevi:21` and the template stub `:298` say "**eight**" — and the three
  saying eight list seven, because the stub's final clause was dropped in transit. Also
  `_template/BANDAGES.md:300` points at `../_template/BANDAGES.md`, which from inside `_template/`
  resolves to itself. **`crystal/BANDAGES.md` links instead of copying, in 3 lines, and is the only
  one that could not drift — adopt its shape everywhere.**
- **"A flag flip is not a revert", 10 copies — the worst, and decaying directionally.** Five
  different lengths (3-10 lines), byte-identical only across the three Lua/C# `FLAGS.md` files.
  **It is homeless:** four copies cite `CLAUDE.md` as the authority, but that file is capped and
  holds the second-*shortest* version. The copies lost the *actionable* half first — "verify the
  flag disables the cost, or revert the commit" is gone from three of ten. **Home it at
  `pitfalls.md:285`**, which already holds the long form with its evidence.
- **Phase disclaimer, 6 copies — DELETE.** 7 lines, 614 bytes, **100% byte-identical, zero
  adaptation**, in `phases/phase3.md`-`phase8.md`. `agent_docs/README.md:89-95` already states the
  same fact as canonical. Replace with one line each, or a single note on the `phases/` index.

**The predictor, worth keeping:** duplication survives when it has a documented reason *and* a
propagation mechanism. The two that had both stayed clean; the two that had neither decayed.

### 3. Three checks for `dev-scripts/preflight.ps1` — what stops all of it re-growing

Prose alone does not hold here and the repo has recorded that three times: `.githooks/pre-commit`
("as strong as prose gets... read and broken anyway"), `preflight.ps1`'s duration check ("a grep
does not need anyone to notice"), and `status.md` going 50 -> 628 lines with a flat cap nominally
in force. The `CLAUDE.md` cap holds *because* `preflight.ps1:116` checks it.

1. **A reading-budget check** — every file named as mandatory-read declares a cap in its header
   and the check enforces it. Extends the existing single-file cap check to a set: same code, a
   loop instead of a constant. **Without this the template is back over 1,000 lines.**
2. **A canonical-source check** — a register mapping each multiply-stated rule to its home and its
   canonical one-liner, failing when a copy drifts. Nothing does this today, which is why the
   seven/eight drift is sitting unnoticed. Seed it with the four above.
3. **A back-port staleness check** — `CLAUDE.md` requires `_template/` never to lag a shipped
   adapter; that is prose only, and `_template/documentation.md` sat untouched from 2026-08-18
   through the Crystal work. Same shape as the existing DLL-vs-source gate.

Of 22 mandated reads inventoried, **exactly one carries a completion test** (the `wc -l`
self-check) and it is attached to the heaviest file. Once the core is capped and small that check
becomes credible and can be stated once for the set. The inventoried load: ~1,701 lines before an
ordinary session, ~5,258 to touch the core, **~14,500-18,500 before a new adapter's first file**
(~7,956 of prose plus a 6,495-10,503-line reference adapter).

### 4. The per-game split of `verified.md` — designed, approved in principle, not started

`verified.md` is 10,174 lines and touched by **207 of the repo's 794 commits (26%)**, the hottest
file in the tree, with four games and the Go side interleaved chronologically. Target: per-adapter
`VERIFIED.md` beside each `README.md`/`BANDAGES.md`/`FLAGS.md`/`documentation.md`, with
`agent_docs/verified.md` keeping Go-side and cross-game entries plus an index.

**The segmentation rule, and the trap that looks correct.** Do not split on every heading (290
`###` vs 236 `- Date:`; the excess are sub-headings *inside* entries). Do not split on `- Date:`
(44 top-level entries carry the date in the heading instead). **And do not split on depth by
position** — "`###` before line 3051, `##` after" passes conservation arithmetic and is wrong: the
entry at 3520 runs to the next `##` at 4378 and swallows **27 dated sub-entries**, including a
Go-side fuzz/test entry nested inside a Pseudoregalia `##`, which it would file into
`adapters/pseudoregalia/VERIFIED.md` with nothing flagging it.

The rule that holds: let `C` be `^## Confirmed facts$` (line 49); ignore everything at or before
it. A heading starts an entry iff it is not inside a fence **and** either it matches `^## `
(unconditionally — 13 entries in the 3051-3467 run carry their date only in prose), **or** it
matches `^### ` and a `^- Date:` line falls within the next 4 lines with no heading between,
**or it matches `^### 20\d\d-\d\d-\d\d` — a LEADING date.**

> **CORRECTED 2026-08-25, while implementing it. The rule as first written was wrong, and its
> stated yield of "332 entries, 65 sub-headings" was wrong with it** — the numbers were derived
> from the same defective rule, so reproducing them exactly proved nothing. **The conservation
> arithmetic passed and the result was still incorrect**, which is the precise failure this section
> warns about two paragraphs above, reproduced by the rule it recommends instead.
>
> **What it missed.** 12 dated `###` headings carry their date in the heading and have no `- Date:`
> line, so the `- Date:`-within-4 test filed them as sub-headings. Ten of them sat inside ONE
> Go-side entry (`### CORRECTION: MaxEventBytes'…`, lines 7491-7754, 264 lines) and cover Go-side
> release facts, Emerald AND Crystal — all of which would have been swallowed into whatever single
> destination that one entry was classified as, with nothing flagging it.
>
> **The discriminator, and it is clean.** A LEADING date (`### 2026-08-18 — v0.9.5 released…`)
> starts a real entry. A TRAILING date (`### Following it: the ghost fights back — 2026-08-16, same
> session`) is a genuine sub-heading continuing the entry above it. Anchoring on `^### 20\d\d` and
> not on "contains a date anywhere" separates the 10 from the 2 exactly.
>
> **Corrected yield: 342 entries**, sum of lengths still exactly 10,124, no gap or overlap. Verify
> against 342, not 332.
>
> **The transferable half:** a conservation check confirms nothing when the thing it checks and the
> number it checks against were produced by the same rule. Line counts still summed to 10,124 while
> ten entries were in the wrong file. Conservation catches LOSS; it cannot catch MISFILING.

**Classify on entry BODY, not heading** — that collapses the residual needing human review from
~119 to ~35-42. Known false friend: Pseudoregalia's *save crystal* matches "crystal". The
access-model groundwork entries describe games with no adapter folder and stay in `agent_docs/`.

**Move verbatim, in original order.** 69 entries say "the entry above/below", so relative order
inside each destination is load-bearing; and heading depth is inconsistent for historical reasons,
which is itself a record of when things were written.

**The known defect:** a ~215-line Pseudoregalia block was appended twice in rewritten form and the
copies contradict each other (~4007 vs ~4099, glow on the ghost's root vs `WeaponMesh` at zero
offset; only the later is right; paired crash entries at ~4038 and ~4127). **Move both, append one
`### CORRECTION:` linking them** — deleting one would be the only actual append-only violation in
the operation, and that pair is the only duplicate heading pair in the file, so a
`sort | uniq -d` expecting exactly 2 lines is a live check.

**The real cost is the pointers, not the split.** `verified.md` is mentioned **449 times across 56
files**, only 23 are markdown links and **none are anchored**. ~426 bare mentions will not break a
link checker and will silently point at the wrong half. Leave `phases/*.md` alone — they are dated
records and rewriting their pointers falsifies what they recorded.

**Conservation checks:** line count (body = 10,124 exactly); a sorted body diff before vs after,
budgeting the deliberate additions; the heading multiset with `sort`, never `sort -u`; `- Date:`
count = 236; and each of the 13 `Superseded by`/`CORRECTION:`/`RETRACTION:`/`NOTE:` annotations
resolving inside its new file. The `internal/X` NOTE is file-scoped and must be replicated into
every destination. One genuine cross-file break: the `RULE CHANGE` entry is governance (stays in
`agent_docs/`) but its target is an Emerald entry.

`unverified.md` splits the same way and is far easier — it is 100% per-game already, with no
Go-side entries by design.

### 5. What was actually done, 2026-08-25 — and the two things still open

**Sections 1-4 above are the plan; this is the outcome.** Kept because the measurements in them
are worth not re-deriving, and because one of them turned out to be wrong (see the CORRECTION in
section 4 — the segmentation rule, and why its conservation check could not catch its own error).

**Done:**

- **The four multiply-stated rules** each have one home. The bandage tell count was a live bug:
  all four stubs listed seven where the canonical list has eight, and the missing one was the
  severe borrow-an-object tell.
- **Six preflight checks**, not three: reading budgets (16 files declared their own cap in their
  header that day — 36 capped and 90 exempt by 2026-08-27, and the script carries 22 checks by
  then), a canonical-source register for multiply-stated rules, `_template` back-port freshness,
  repo-wide markdown link integrity, and `pitfalls.md` index coverage. Both doc checks passed a
  deliberately broken tree on their first run — see `pitfalls.md`, "A check that lists no files
  passes every time".
- **The `_template` condense.** Four hard rules reduced to imperative plus dated stub; the Lua
  200-local ceiling moved to `emulator/CLAUDE.md` where it loads on contact; both files gained the
  table of contents neither had. **The honest number: 3,302 → 3,216 lines, 2.6%.** The composition
  changed more than the count. Anyone hoping this halves the mandated reading should know it did not.
- **The per-game split.** `verified.md` 10,174 → 1,072 across five files; `unverified.md` 1,670 → 36
  across three. Byte-perfect by sorted multiset. One entry was misfiled and caught by auditing on
  *terminology* rather than game names — the classifier counts names, and that entry never said
  "Emerald".
- **`pitfalls.md` indexed** over both its halves, taxonomy kept and not extended, with a check.
- **`architecture.md`**: 20 headingless ADRs given headings; three ADRs rescued from inside
  "Prior art".
- **The queues drain**, `status.md`'s duplicated rule is a pointer, and `ideas.md`'s struck-through
  DONE sections are archived at the end of this file — one of which was hiding an open item.

**Still open, deliberately:**

- **Incident narrative still sits inside several ADRs**, and in one ~170-line Archipelago bullet in
  `risks.md`. That content belongs in `pitfalls.md` with the ADR reduced to what it decides. Not
  attempted: it rewrites the substance of dated decisions rather than moving them.
- ~~**`status.md` is still three screens** (~50 items)~~ — **drained 2026-08-25**, and this bullet
  went on claiming otherwise until 2026-08-27 while `status.md` itself cited *this section* as the
  authority that it had been drained. Two documents each pointing at the other is how a closed item
  stays open in one of them; close it in both, in the same pass.
- The `agent_docs/probe-discipline.md` extraction (six entries on instruments that lie, five on
  probe hygiene) was **not** done — the index made it unnecessary for retrieval, and it would add
  a third destination to keep straight.


---

# Archive — shipped, closed, or already existing

**Kept verbatim, moved here 2026-08-25.** These four sat inline among open ideas with
`~~strikethrough~~` titles, which reads as skippable but still costs the reading. Each is
recorded properly elsewhere — `VERIFIED.md`, an ADR in `architecture.md`, `pitfalls.md` —
and each left a short pointer where it used to be. Nothing was deleted: the reasoning behind
a shipped decision is worth having, it just does not belong in the queue of things to do.

**One of them was hiding an open item.** "Driving the game itself" was filed as done because
the BizHawk half is; the Pseudoregalia half has never been built, and the entry's scope had
widened to "and beyond" without anyone restatusing it. That half is now an open entry above.

### The third pass (2026-08-25) — the structural half, and two things it deliberately did NOT do

The first two passes fixed facts and built the delivery mechanism. This one went after shape.
Done, each its own commit:

- **`adapters/bizhawk/` -> `adapters/emulator/`**, with `tevi/CLAUDE.md` and
  `pseudoregalia/CLAUDE.md` added so Unity and Unreal host rules have an auto-loading home. The
  rule that replaced a taxonomy: **create a level only when two things actually share it.**
- **The ADR log left `architecture.md`** — 2,332 of its 2,501 lines — for one file per decision
  under `adr/`, with the index staying behind at the address every citation already points to.
- **Every doc declares a cap or declares why it has none**, and silence is now a preflight FAIL.
  48 capped, 69 exempt. The exemption is the other half of the rule, not a loophole.
- **`_template` ships the three files it had always mandated** (`VERIFIED.md`, `UNVERIFIED.md`,
  `probes-README.md`), and preflight checks the adapter file set.
- **`internal/cfg`** for the config plumbing both mains were copying.

**NOT done, and this is the part worth reading.**

**1. `pitfalls.md` was not split per game, and should not be — but it WAS split.** The user's
framing settled it: the file's job is stopping a repeat mistake on a future adapter, and the long
write-ups can live elsewhere. That is what the file already said it was doing — *"the titles are
the lessons"* — so `pitfalls.md` became the 201-line index and the evidence moved to `pitfalls/`,
cut on the boundaries the index already declared. Reading the lessons costs 201 lines, not 5,180.
Nothing was re-filed and no judgement was needed, which is what separates it from the per-game
split below.

**Why the per-game split stays rejected.** The plan called for moving the 78
game-named entries out to each adapter, the way `verified.md` was. That contradicts a decision this
repo made on 2026-08-25 and wrote into `preflight.ps1`: *"Nothing can mechanically verify 'is this
filed under the right theme', which is why the taxonomy was not finished."* Trying it confirmed the
prediction — classifying by game-mentions-in-body gave `AMBIGUOUS` or a one-mention guess for most
entries, because a heading like "Inferring what a game is MEANT to do (2026-08-18, TEVI)" names the
game as *provenance*, not as scope, and that entry's lesson is cited in the root `CLAUDE.md`. **The
file's value is that a lesson found in Emerald is findable while working on Crystal**, which is the
exact property a per-game split destroys. Its index plus the coverage check is the right control.

**2. The append-only ledgers were indexed rather than split, because the axis chosen for them does
not exist yet.**
The agreed shape was a directory plus a capped index, partitioned along the axis you append —
period — so that appending never rewrites. That is right in principle and unusable today: **every
entry in every one of these files is dated 2026-08**, because the repo began 2026-08-11. Month
partitioning yields one file. Phase partitioning is no better, since each adapter's record is one
game in one phase: all of `pseudoregalia/VERIFIED.md` is Phase 7. The only axis that would actually
divide them is per-week, which is arbitrary and would read as such.

**Answered by taking the third of three options, 2026-08-25.** Splitting per-week would have been
arbitrary and would have read as such; waiting for a second month leaves the files unusable
meanwhile. So all five got an index and a preflight coverage check instead — 407 entries — which is
what every option needed anyway, and loses nothing. **Revisit splitting when the dates actually
spread across more than one month**; the index is then the thing that survives the split, exactly
as `pitfalls.md`'s did.

**3. Left alone deliberately, each for a stated reason:** renaming the local `meshghost-relay.exe`
to match the shipped `meshghost-server.exe` (25 files name the old one, several of them append-only
records, and the mismatch is already documented — churn for cosmetics); moving root build output
and logs into `bin/` and `logs/` (touches every `dev-scripts` launcher, and breaking the user's
test scaffolding unsupervised is a bad trade for a tidier `ls`); collapsing the copy-paste
`run-core-*.bat` family (same reason); and `ideas.md`'s own split. All still worth doing.

## The full-project refactor pass (2026-08-25) — 15 commits

Asked for as "a full project refactor", scoped by the user to code structure/dedup plus docs
cleanup, across everything, with redesign welcome. Three recon passes (Go, adapters,
docs/scripts/packaging) mapped it first; a fourth designed the phases.

**What shipped**

- **Probe folders stopped being artifact dumps.** Screenshots got the rule the logs already had
  (`.gitignore`), five hand-committed PNGs were untracked, and ~580MB of read artifacts left the
  disk with the user's approval. Crystal's probe index named 29 of 46 scripts while announcing
  "Ten of these WRITE game RAM" above a list of nine; all 46 are indexed and the writers are
  sorted by what they actually touch.
- **Three docs corrected** that sent a fresh session somewhere wrong: the ADR instruction that
  outlived the `adr/` split, two hardcoded line counts nothing updated, and the
  `meshghost-relay.exe`/`meshghost-server.exe` split-brain, now stated once in `packaging/README.md`.
- **`status.md` 167 → 140 lines**, every item back inside its two-line rule. Sixteen Crystal
  entries were each restating a heading from a 1,186-line queue — an index of an index — and are
  now six subsystem pointers. Two items were assumptions, not open work, and moved to `risks.md`.
- **`ideas.md` lost the third of its three jobs** to this file, taking with it the single
  `preflight.ps1` exemption from the canonical-source check. The largest uncapped doc had been the
  one file exempt from the only check that would notice a rule going stale inside it.
- **Two new indexes with checks behind them**: `phases/README.md` (phase files were the one
  required-reading class with neither) and a `dev-scripts/README.md` coverage check that found
  exactly the six undocumented scripts the recon had listed, having been written first.
- **Nine `run-core-*.bat` collapsed into `run-core.bat <game> [transport] [instance]`**, verified
  by running it. Three launchers deliberately survive, because the filename is what records which
  rig produced a reading.
- **Go**: `internal/cfg` finished the job it was named for (log rotation, the `flag.Visit` idiom,
  and 25 hand-written override blocks, with the precedence rule finally tested);
  `internal/textfmt` for a formatter written twice byte-for-byte; `MaxHelloFieldLen` moved to the
  side of the protocol/policy line `relay/limits.go`'s own header draws; `relay/online.go`
  1,115 → 191 and `core/core.go` 2,048 → 636, both pure moves verified by diffing the declaration
  sets; the one relay startup rule with a refusal in it made testable and negative-tested.
- **`bridge` went from `[no test files]` to seven tests and two fuzz targets**, registered in
  `ci.yml` — it is the wire contract four adapters implement by hand in three languages, and a
  JSON boundary fed by a script the user edits.
- **The cross-language bridge constants** stopped being kept in step by a comment: `preflight.ps1`
  now compares them in real units across Lua, C++ and the template, and was negative-tested.

**Three recon findings deliberately NOT acted on, because the evidence did not support them**

- The three vendored LuaSocket LICENSE files are not duplication. A license sits beside the binary
  it covers; deleting two would be a licensing error. Only Emerald's `.dll` pair is tracked.
- `probe_ghost`'s superseded bridge copy stays: referenced from ten files including LF-pinned
  `Plugin.cpp`, so removing it would force a DLL rebuild to delete an artifact doing a documented job.
- The three envelope-send helpers stay separate. `relay.sendEnvelope` and `core.sendBridgeEnvelope`
  are structurally identical, and merging them would couple the two protocols `contract.md`
  deliberately keeps apart, to save fourteen lines. That duplication is the boundary doing its job.

**What remains: the Lua module extraction.** Deferred with its design rather than rushed. The
ceiling is real and was re-measured (Emerald exactly 197 of 200, Crystal 188), and the trap that
would otherwise be paid for a third time is now written into `adapters/emulator/CLAUDE.md`: a
shared module must never resolve its own directory, because `dofile` makes `debug.getinfo` relative
and `package.loadlib` then resolves against BizHawk's process directory. It is also the one phase
that cannot be finished without a live run.
