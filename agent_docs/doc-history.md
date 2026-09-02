# Doc restructuring — the record

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

## Archived idea texts — moved out of `ideas.md` (2026-09-02)

The four struck-through sections below were left in the middle of `ideas.md` when this file's `#
Archive` heading moved here on 2026-08-25; the stubs that replaced them said "full text in the archive
at the end of this file", which was true of neither half. They are here verbatim, in their original
order, and the stubs now point here.

## ~~Slide: replace the render-Z bandage with the game's own crouch handling~~ — DONE 2026-08-17

**DONE, and the bandage is deleted.** The ghost is now posed by the game itself — user-confirmed
"looks identical to the player", re-checked with every probe off. It needs five mechanisms
**together**, each of which tests negative alone: mirror the peer's capsule, drive the slide
Blueprint Timeline with the peer's own curve position via `Timeline_1__UpdateFunc`, fire the crouch
input and the crouch events, and set/clear `bIsCrouched` on the peer's edges. Full evidence:
`verified.md` (2026-08-17). How the game does it: `adapters/pseudoregalia/documentation.md`. How it
was found, as method: `pitfalls.md`'s slide case study.

**Kept below: the ruled-out list.** It is the valuable part — nine levers that apply cleanly and do
nothing — and reads correctly as history now that the answer is known. Note that its central
conclusion at the time ("every lead is closed, the bandage stays") was **wrong**, and wrong in an
instructive way: each lead was tested alone, and the answer was their union.

**Flagged by the user 2026-08-16** as a temporary fix that should be replaced by finding out how
the game itself does it — the case `adapters/_template`'s "observe before you override" rule exists
for, and the same shape as the camera fight-back that had to be deleted the same day.

**What shipped until 2026-08-17** (`Plugin.cpp`, the `slide_z_comp` block at the receive site):
during a slide the ghost's render target Z was raised by
`GHOST_STANDING_CAPSULE_HALF - peer_capsule_half`, i.e. **+43 units**, so it stopped sinking into
the floor. That block is now gated off — `constexpr bool GHOST_SLIDE_Z_COMP = false` — and the
pose comes from the game's own crouch path instead. The code is retained, disabled, with the
measurement below in its comment.

**It is not a guess, and that is why it survived** — the mechanism underneath it was measured, and
the comment records it honestly: a real slide shrinks the player's capsule 65 -> 22 and drops its
origin 567.2 -> 524.2, keeping the feet planted. Mirroring `CapsuleHalfHeight` onto the ghost was
tried, confirmed to apply (read back 22), and did **not** fix the visual, because the skeletal mesh
hangs off the capsule at a fixed relative offset (-65) set at construction. **The thing that
adjusts that offset is the player's own crouch logic, which an unpossessed ghost never runs.**

So the bandage is precisely the tell the rule names: it *compensates* for a value the game would
have set, instead of making the game set it.

**ATTEMPTED 2026-08-16 — every lead below is now closed, and the bandage stays.** Full evidence in
`verified.md` and `adapters/pseudoregalia/BANDAGES.md`; this section is kept as the record of what
was ruled out, not as work still to do.

The probe ran (692 samples) and answered the question exactly: the player's mesh sits at
**`-(CapsuleHalfHeight + 1)`** — -66 standing, -23 sliding *and* crouching, zero variance. Standing
is -66, not the -65 recorded here before. Then:

1. **The game's own slide functions — never tried, and correctly so.** The probe showed a
   stationary crouch moves the mesh identically to a slide, so the offset is not slide-specific and
   `slideTick`/`slideOverheadCheck` were never the lever.
2. **The engine's crouch path — dead.** `CapsuleHalfHeight` and `bIsCrouched` are both *outputs*:
   each was written successfully and neither changed anything. The input `bWantsToCrouch` is
   refused outright, because **`bCanEverCrouch` reads false on a ghost's movement component**.
3. **The mesh offset directly — works, and is worse.** The write lands, something re-imposes -66
   about a tick later, and re-asserting it every tick loses the race visibly (user-watched: a ghost
   at varying heights). Not shipped.

**What that leaves, for anyone picking this up.** The finding under all three is that **this game's
slide is not an engine crouch** — it is the game's own logic writing capsule and mesh directly. So
the only remaining route is finding what state that logic reads and whether a ghost can be given
it, which is the PRECONDITION CLAUSE question in this file's Pseudoregalia item 3, not another
engine call. Identifying what re-imposes -66 each tick is the concrete first step, and
`GHOST_MESH_Z_TRACE` (in `Plugin.cpp`, off) already prints the whole chain per tick.

**Why this matters beyond tidiness:** the ghost's Z is being moved for a reason that has nothing to
do with position, so anything else reading that Z inherits the lie. `Plugin.cpp` already notes a
second bug (the thrown-weapon prop) as "structurally the same bug as the slide floor-sinking fix",
which is what a bandage looks like when it starts to spread.

## ~~Spawn to the game's cap, then DRAW above it — a two-tier ghost~~ — SHIPPED, both Pokémon adapters

**DONE — this is not an idea any more.** It shipped for Emerald (`plans.md` phase 8.1) and for
Crystal (9.1), is in both adapters' code, and is user-confirmed on screen (`verified.md`). It was
still labelled "Tier 1-2, unscheduled" until 2026-08-25. Kept in full below because the reasoning
— fidelity and cost turning out to be the same motive — is what a third adapter should read
before choosing a renderer.

**The user's framing, 2026-08-19, and it is the whole idea in one line: *do as much as the game
can handle on its own, then bandage/fake it above that cap.***

**And the two motives turn out to be one motive, measured 2026-08-20.** The idea was about
FIDELITY -- bypass the hardware limit by mimicking what the game does rather than faking it, so a
peer gets the engine's own animation, occlusion, draw priority and reflections instead of an
imitation of them. The performance ordering follows from the same fact, and was not the reason
anyone chose this: a SPAWNED ghost costs ~0.05ms of Lua per frame because the engine is already
walking its object array and building OAM, so one more entry rides along with work being done
anyway. A DRAWN one costs ~0.6ms EVERY frame -- roughly twelve times more -- because it re-does
the whole job after the PPU has finished, one `gui` call per pixel-run, borrowing nothing.

So *faking it means paying for a second renderer*, and the faithful tier is also the cheap one.
The measurements are in `verified.md` 2026-08-20 (a full fps table, and 137 drawn peers at 17fps
from 2026-08-19). The practical rule it settles: **spawn to the engine's cap, draw only the
overflow** -- the drawn tier is a fallback for peers the object array has no room for, never a
default, and never something to reach for because it looks simpler to control.

Crystal's ceiling is measured (`crowd-limits.md`): **9 ghosts**, because the engine has 13 object
structs and 16 map objects and the map spends some of both on its own cast. Peer number ten gets
nothing today — no body, no sprite, no collision — and the adapter logs a refusal. That is honest,
and it is also a hard wall that no cleverness at the hardware level moves: even perfect sprite
multiplexing (rewriting OAM per scanline, which real Game Boy games did) only helps the *drawing*
limits underneath, while the engine still has nowhere to record a fourteenth character.

**Refined 2026-08-20, because that dismissal is only half right.** It holds for the SPAWNED tier --
nothing at the hardware level gives the engine a place to record a fourteenth character. It does
not hold for the DRAWN one, which needs no engine object either: there, a multiplexed hardware
sprite is a candidate replacement that the PPU draws instead of our Lua painting it. See "A THIRD
tier between the two" below.

**The way past it is to stop asking the engine for the overflow.** A drawn ghost — `gui.*`
primitives painted onto the emulator's output, which is how Emerald's adapter works — is not a
sprite at all. It happens after the PPU has finished, so it is subject to **none** of the three
limits: not the 13 object structs, not the 40 OAM entries, not the 10-sprites-per-scanline rule.
Twenty ghosts in one town is a rendering question at that point, not a hardware one.

So: **spawn real objects while slots last, draw the rest.** The first N peers get everything the
engine gives for free — animation, palettes, priority, occlusion behind houses and text boxes,
collision — and peers past the cap still *exist* on screen instead of vanishing.

**What it costs, stated honestly, because this is a bandage by construction and belongs in
`BANDAGES.md` the day it ships:**

- **Two rendering paths in one adapter**, which is the real risk. Every future change has to be
  made twice or deliberately once, and the two drift. Emerald's own history is the evidence: its
  drawn path needed a hand-rolled sprite decode, a manual walk cycle, and a pile of compensations
  that the spawn path deleted outright.
- **A drawn ghost does not occlude.** It paints over houses, over the pause menu, over text boxes.
  Crystal's spawn path fixed exactly this class of thing, and the user called the equivalent fix
  in Emerald the clearest argument for spawning at all.
  **Can it be detected? The user's question, and the answer splits in two** (2026-08-19):
  - **Menus and text boxes: easy, and cheap.** Those are game *states*, not geometry — the adapter
    already reads the equivalent for its send gate. Hide every drawn ghost while one is open and
    the whole class disappears. No pixel reasoning involved.
  - **Better than hiding: clip by REGION** (the user's refinement, 2026-08-19). A text box sits at
    the bottom, a menu down the right — so do not draw into that rectangle and keep drawing
    everywhere else, instead of blanking every peer whenever anyone reads a sign.
    **Where the rectangle comes from is not settled**, and two candidates were probed live:
    - *The Game Boy's own window layer* (`LCDC` bit 5, `WY` at `0xFF4A`, `WX` at `0xFF4B`) looked
      ideal — the hardware stating where overlaid UI is, for free. **It is not usable as-is**:
      Crystal leaves the window enabled and parks `WY` at 144, one row below the screen, and
      opening the start menu drove `WY` to 0 (the whole screen) for about a second before it
      returned to 144 while the menu was still open. So the register tracks a transition, not the
      panel — clipping on it would blank the screen for a moment and then stop working.
    - *The game's own menu rectangle*, `wMenuBorderTopCoord`/`Left`/`Bottom`/`Right`
      (`00:cf82`–`cf85`, tile coordinates, from our hash-verified `pokecrystal` build).
      **This one works — measured 2026-08-19 with the pause menu open**: `top=0 left=10 bottom=15
      right=19`, i.e. columns 10–19 of 20 and rows 0–15 of 18 — the right half of the screen,
      stopping two rows short of the bottom. It corroborates itself against what the user saw
      independently: the one ghost still visible with the menu open was the one standing *below*
      row 15. So a drawn ghost could be clipped out of exactly the panel and keep drawing
      elsewhere, which was the user's own model of the problem before any of this was read.
      **One wrinkle to handle**: the four values flip back to `0,0,0,0` and return several times a
      second while the menu is up — the menu code rewrites them as it redraws — so a consumer has
      to latch the last non-zero rectangle while a panel is open rather than reading them raw, or
      the clip region will strobe.
    - *Text boxes are not in that variable at all, and do not need to be.* With a text box open the
      four values stayed `0,0,0,0` (measured 2026-08-19), because the box is a **constant**:
      `pokecrystal`'s `constants/text_constants.asm` defines `TEXTBOX_X = 0`,
      `TEXTBOX_WIDTH = SCREEN_WIDTH`, `TEXTBOX_HEIGHT = 6` and
      `TEXTBOX_Y = SCREEN_HEIGHT - TEXTBOX_HEIGHT` — tiles 0–19 across, rows 12–17 down, the bottom
      six rows at full width, every time. Nothing in RAM changes because nothing has to.
    - **So the clip region is fully known**: the fixed bottom six rows while a text box is open,
      plus the latched `wMenuBorder*` rectangle while a menu is open. The user's model of this
      — *"the text box is always at the bottom, the menu is on the right, just do not draw
      there"* — turned out to be literally how the game is written.
  - **Scenery: harder, but the hardware carries the answer.** On the Game Boy Color each
    background tile has an attribute byte in VRAM bank 1, and one bit of it means *this tile draws
    in front of sprites*. A drawn ghost could read the attribute at the tile it occupies and skip
    itself when that bit is set. **Approximate on purpose**: it decides per tile, so a character
    straddling two tiles is half right, and it mimics the engine's rule rather than being it. It
    would still catch the big case — standing behind a house — which is the one a player notices.
  - **The spawned tier already has all of this, confirmed on screen 2026-08-19**: with nine ghosts
    around them the user opened the pause menu and found them properly hidden behind it, while a
    ghost outside the menu's region kept drawing — region-accurate occlusion, from an adapter
    containing no menu detection whatsoever. That is the bar the drawn tier has to approximate,
    and it is worth being honest that approximating it is the *whole* cost of this idea.
  - **This is worth pricing before dismissing the whole tier.** "A drawn ghost can never be
    hidden" would be a much heavier objection than "a drawn ghost is hidden by a rule we
    reimplement, imperfectly, at tile resolution".
- **A drawn ghost has no collision and cannot be interacted with** — which is arguably *right*
  for an overflow tier (nine solid ghosts can already box a player in) but makes peers visibly
  unequal.
- **Someone has to animate it.** The engine will not.
- **Where the pixels come from is easier here than in Emerald**, and worth noting before anyone
  assumes otherwise: a peer past the cap usually wears a sprite that is *already resident in
  VRAM* (`wUsedSprites` says so, and the adapter already reads it for peer appearance). Copying
  loaded tiles beats Emerald's decode-from-ROM path.

**The policy question to answer before building it:** *which* peers get the real slots. "First to
arrive" is what happens today and is the worst answer — it makes the quality of a peer's ghost
depend on join order forever. **Nearest-wins** is better: the peers you can actually look at
closely are the ones the engine draws, and the drawn approximations are the distant ones where the
difference is least visible. That also means re-assigning slots as people move, which needs a
hysteresis band or ghosts will churn between tiers while someone walks past.

**Not scheduled.** Nine simultaneous peers in one town is far past anything planned, so this buys
nothing today — it is filed because the *shape* is right and generalises (see the same rule in
`adapters/_template/README.md`), not because Crystal needs it.

## ~~A THIRD tier between the two: a hardware sprite with no engine object~~ — CLOSED 2026-08-21

**Both halves resolved** — the HBlank question is settled and the OAM tier shipped; the detail is
in the CLOSED subsection below, which sat 50 lines under a heading that still read as open.
Filed 2026-08-20.

**The user's shape, and it is the right one: *"maybe spawn -> hblank -> drawn or something.
high/low prio order. to gain some performance"*.** A peer takes the best tier that still has room,
and each step down trades engine behaviour for capacity while staying cheaper than the step below
it. **The user's condition on trying it at all**, same message: *"as long as we don't change saves /
need to make a patch and can't use lua etc."* -- so the whole idea lives or dies on question 1
below, and it is worth answering before anything else here is designed.

**Where it came from.** An outside developer working on Crystal raised sprite multiplexing --
*"one slot and moving it in hblank"* -- as being **cheaper than drawing**. Not measured by us, and
recorded here as a claim to test rather than a fact. The section above dismissed hardware tricks
for fixing the wrong limit; that dismissal is right about the SPAWNED tier and incomplete about the
drawn one, which is what this entry corrects.

### What the technique is

The PPU draws the screen one scanline at a time, and after each line there is a short gap (HBlank)
in which OAM is writable. Rewrite an OAM entry in that gap -- new Y, new tile, new palette -- and
the same hardware sprite is drawn AGAIN further down the screen. One slot becomes many characters
per frame, as long as they are separated vertically. Real Game Boy games did exactly this.

**Why it would be cheaper than our drawn tier, and the reasoning is sound**: a painted ghost is
HOST work -- Lua, after the frame is finished, one `gui` call per pixel-run, measured at ~0.6ms per
ghost per frame (`verified.md` 2026-08-20). A multiplexed sprite is drawn by the EMULATED PPU,
which is being simulated anyway; the host pays only for the writes that set it up. It also arrives
with hardware palettes, background priority and real compositing -- everything the overlay fakes.

### The three questions that decide whether this is buildable HERE

1. **Can OAM be written mid-frame from the FRONT END, with no ROM patch?** This is the whole
   feasibility question. The technique classically needs code inside the game on the LCD
   STAT/HBlank interrupt -- a ROM patch, which the user's condition rules out. It is only viable
   for us if BizHawk exposes a mid-frame hook (a scanline / LYC-style callback) we can write OAM
   from. **Unknown today**: `dev-scripts/bizhawk-capabilities.log` is two lines saying
   `client.getluafunctionslist()` is unavailable on this build, so nothing has actually enumerated
   what this emulator offers. Run `dev-scripts/bizhawk-api-dump.lua` first and answer it from the
   dump, not from memory.
2. **Would per-scanline Lua cost more than it saves?** A callback on every line is 144 Lua calls a
   frame, which is the expensive shape this project has already been bitten by (`pitfalls.md`,
   2026-08-16 and 2026-08-20). It is only cheap if we hook the FEW lines where a sprite has to be
   re-pointed -- two or three per extra ghost -- rather than every line. Design it as "wake me at
   line N", never "call me every line".
3. **Is the HBlank part even needed on GBA?** Emerald has 128 OAM entries against 16 engine object
   events, so the sprite table is nowhere near the binding limit -- the engine's own array is. The
   engine rebuilds OAM every frame, and **we already hook the exact function that does it**
   (`BuildOamBuffer`, used today for fishing alignment and priced at effectively free -- 52.0 vs
   52.6 avg fps, `verified.md` 2026-08-20). Appending our own OAM entries there, after the engine
   has built its list, would give extra hardware sprites with no multiplexing and no patch at all.
   Crystal is the case that genuinely needs multiplexing: 40 OAM entries, and the engine spends
   many of them.

### CLOSED 2026-08-21 — the HBlank half is settled, and the OAM half shipped

**User-confirmed the same day**, once both halves had been answered: *"bizhawk don't support it, and
we want to keep lua instead of patching. so yee thats also confirmed i guess ?"* -- so the
multiplexing idea is **closed by decision**, not parked. The tier it was raised in service of was
built instead and is live (`plans.md` Phase 8.1); the ADR of this date carries the reasoning. What
follows is how the three questions were answered, kept because the METHOD generalises to the next
emulator adapter even though the conclusion is specific to this one.

### ANSWERED 2026-08-21 — all three, offline, before a line was written

**1. There is no scanline hook, and it does not matter.** BizHawk 2.11's `event` library, read out
of `BizHawk.Client.Common.dll` itself rather than asked for, is exactly `onframestart`, `onframeend`,
`oninputpoll`, `onloadstate`, `onsavestate`, `onexit`, `onmemoryexecute`, `onmemoryexecuteany`,
`onmemoryread`, `onmemorywrite`, `availableScopes`, `unregisterbyid`, `unregisterbyname`. No
scanline, no LYC. **Every mid-frame wakeup available to us is a memory callback** -- which is not a
limitation so much as a redirection, because the game's own routines are exactly the addresses worth
waking on.

**2. Moot -- but priced anyway.** Emerald's own VCount interrupt at line 150 gives ONE free
mid-frame wakeup per frame (`EnableVCountIntrAtLine150` runs at boot, vanilla, no patch). The
160-per-frame HBlank path is reachable from Lua by IO writes with no patch at all, and is still the
wrong answer by roughly two orders of magnitude -- and it would fight the field's own HBlank DMA for
the bus, and retiming the VCount line risks the sound engine, which is serviced from that interrupt.

**3. No, and the shortcut is even better than the entry guessed.** `gOamLimit` is **64** on the
overworld while `LoadOam` transfers all **128** entries to hardware every VBlank -- so
`gMain.oamBuffer[64..127]` is dead space the engine's per-frame path never reads or writes, and
anything parked there reaches the PPU on the game's own already-paid DMA. Emerald itself uses this:
the wireless status indicator lives in `oamBuffer[125]` precisely because the sprite system will not
clobber it. So an extra hardware sprite is **three halfword writes per ghost per frame** from the
`BuildOamBuffer` hook we already own -- no multiplexing, no scanline hook, no patch, no second
execute breakpoint to re-price.

**And the user's condition became a project rule.** *"i want us to stick with lua for all bizhawk
games, so we have cross rom patch compatability"* -- recorded as the 2026-08-21 ADR in
`architecture.md`, a non-goal in `plans.md`, and the opening section of `_template/README.md`.
That closes classical HBlank multiplexing permanently for this project, which costs nothing here.

### The ladder, if it works

| tier | what draws it | what it gets | what caps it |
| --- | --- | --- | --- |
| **Spawned** | the engine's own object event | everything: animation, collision, occlusion, priority | the engine's object array (~13 Crystal, 16 Emerald, minus the map's cast) |
| **Hardware sprite** (new) | the PPU, from OAM we write | palettes, background priority, real compositing -- but no engine state, so we drive position and frame ourselves | OAM entries, and the per-scanline sprite cap (10 on GB), which multiplexing does NOT beat |
| **Drawn** | our own `gui.*` overlay | a body on screen, nothing else | nothing, except the host CPU -- ~0.6ms/frame each |

**What the middle tier does NOT give**, and this has to be said plainly so nobody expects it: no
collision, no engine animation, no walking -- a fourteenth character still has nowhere to live in
the game's own state. It is a cheaper, better-composited replacement for the DRAWN tier, not an
extension of the spawned one. VRAM is its other real cost: a hardware sprite needs its tiles
resident, and the adapter's existing tile-range allocation is already the fiddliest part of
spawning.

### Order of work, if it is ever scheduled

1. **Answer question 1 from an API dump.** No hook, no feature -- and that is a cheap, entirely
   offline answer.
2. **Try the GBA shortcut first** (question 3): append OAM entries from the `BuildOamBuffer` hook
   on Emerald and see whether an extra sprite renders at all. It needs no multiplexing, no
   scanline hook and no patch, so it prices the whole idea before any of the hard parts.
3. **Only then Crystal's multiplexing**, where the technique is actually required.
4. **Measure it against the drawn tier** with the same scripted-ride harness the lag hunt used
   (`_template/probes.md`) -- the claim being tested is *cheaper than drawing*, and that is a
   number, not an argument.

**SCHEDULED 2026-08-21** as the Emerald hardware-sprite tier -- see `plans.md`, which holds the
staged build order and the measurement protocol. The HBlank half stays here, unscheduled and now
refuted on its premise rather than merely untried: Emerald has no sprite-count limit to beat (64 of
128 entries unused every frame), and the binding constraint turns out to be OBJ **tiles**, which
multiplexing does nothing for. If it is ever revisited on another game or another core, the one
probe that answers it is an `event.onmemoryexecute` on that game's mid-frame interrupt, counting
invocations per frame and A/B'd on the ride harness -- that single number is what the whole question
turns on.

**Mixing tiers on ONE ghost is allowed, and is probably how the decorations get done** (user,
2026-08-21: *"could always just draw those onto it if needed ? like mix/combine if ever needed ?"*).
The tier is a property of each PIECE, not of the peer: a hardware-sprite body can carry a painted
grass overlay, dust or surf blob on top of it, or a SECOND hardware entry for them -- there are 56
free slots and the engine draws those decorations as separate sprites itself. Painting them is the
cheap option precisely because they are small, occasional and mostly unoccluded; a hardware entry is
the right one wherever the decoration has to be hidden by scenery like the body is. Decide per
decoration, measure, and do not let "which tier is this ghost" become a single answer it does not
have to be.

## ~~Driving the game itself: scripted input~~ — EXISTS AND IS IN ROUTINE USE (filed 2026-08-18)

**Done for BizHawk, and used constantly** — `joypad.set` drives the Crystal and Emerald probes,
`square_drive` hunts for faults, and the technique is written up in `_template/probes.md` and
`pitfalls.md`. **The Pseudoregalia half is what remains unbuilt**; the entry's scope quietly
widened from that one game to "and beyond" without anyone restatusing it. Original text follows.

**The ask, in the user's words:** input mapping / AI control of what happens in-game, the way
BizHawk's `joypad.set` already lets a Lua probe press buttons. Screenshots are a poor channel for
this, but the user can describe the menu path step by step — "past the main menu" is a fixed,
short sequence — so once it is scripted it can be replayed on every run. **The goal is a faster,
more automatic dev/test loop**, because today every Pseudoregalia or TEVI iteration costs the
user a real game launch and a manual walk to the test state.

**Why this is filed rather than dismissed:** it was nearly dismissed. The instruction that
produced this entry was *"don't just assume you can't do something without checking what possible
tools you have available first."* Checking took minutes and turned a guess into three concrete
candidates.

**What is actually available (checked 2026-08-18, not remembered):**

1. **`ProcessEvent` — already in our own mod, already working.** `Plugin.cpp` calls
   `target->ProcessEvent(function, params_buffer.data())` to invoke arbitrary UFunctions with a
   hand-built parameter buffer. That is the general lever: anything the game exposes as a
   Blueprint or native function — menu handlers, level load, a player-controller input entry
   point — is reachable the same way the ghost's own animation calls already are. **This is the
   most promising route precisely because it is not new capability**, just a new caller.
2. **UE4SS key binds are the wrong direction.** `RegisterKeyBind`/`RegisterKeyBindAsync` and
   `IsKeyBindRegistered` *observe* input; they do not synthesise it. `Input/Platform/
   QueueInputSource.hpp` looks like injection and is not — it is explicitly
   *"not an implemented input source and should not be used directly"*, `is_available()` returns
   `false`. **Worth recording as a checked dead end so nobody re-derives it.**
3. **Win32 `SendInput`/`PostMessage`** from inside the mod's own process, which is the closest
   analogue to `joypad.set` and needs no Unreal knowledge at all. Coarser (it goes through the OS
   and needs window focus), but game-agnostic — it would work for TEVI too, which has no
   equivalent of UE4SS.

**Shape it should take if adopted:** a **probe**, never shipped adapter behaviour, and off by
default — an adapter that can press buttons is an adapter that can play the game, which is a very
different promise from a cosmetic ghost, and is squarely the kind of thing `beyond-cosmetic.md`
exists to gate. The obvious first milestone is the smallest observable one: **script the main-menu
sequence to reach a loaded save, and nothing else.** If that replays reliably, everything after it
(walk to a spot, hold a slide, stand still for a ghost-load rig) is the same mechanism repeated,
and the ghost-load/despawn rigs stop needing a human to aim them.

**Not scheduled.** Nothing here is committed until it moves into `plans.md`. The method notes for
writing such a probe belong in `adapters/_template/probes.md`, which carries the pointer.
