# Phase 12 — delivery: packaging, the release pipeline, CI and the gates

> **A dated record.** Entries say what was true when written; paths are left as they were. Adapter
> paths before the 2026-08-25 folder rename read `adapters/bizhawk/` where the tree now says
> `adapters/emulator/`. Why: [../README.md](../README.md).

**Status: LIVE — a component log, not a bounded stretch of work**, the same shape as
[phase10.md](phase10.md). Created **2026-09-11** after an audit of every tree in the repo against
the phase files found this one owned by nothing: ~195 commits of release, CI and packaging work
whose only record was the commit log. `project-history.md` had said as much in prose since it was
written — *"the ongoing refactors and changes made to things like the release packaging along the
way … are scattered across the `phases/` files and commit history instead"* — an acknowledged gap
rather than a hidden one, and the audit is what priced it.

**Scope: how the thing reaches a player, and how the repo polices itself.** `packaging/`,
`.github/workflows/`, `.githooks/`, `dev-scripts/release.ps1` and `stage-release.ps1`,
`dev-scripts/preflight.ps1` and the player-facing `docs/`. **Not** the running stack — a protocol
default, a transport, a relay queue is [phase10.md](phase10.md); a game is its adapter's phase.
The line to hold: **phase 10 is what runs, phase 12 is what ships and what checks.**

Numbering: 12 was reserved for the fifth game until 2026-09-11; a component log is a legitimate
phase here (10 and 11 already are), so the fifth game takes 13 onward and the index says so.

## Purpose

A release is the only artifact a stranger ever sees, and the gates are the only reason anything in
this repo stays true. Both had real, hard-won history — a declined code-signing application, a
release script that failed five different ways in one day, gates that passed while reading the
wrong tree — and none of it had a timeline. This is that timeline. **Detail stays where it lives**:
`docs/code-signing.md`, `docs/antivirus.md`, `agent_docs/pitfalls/`, and the ADRs.

## Backfill — up to this file's creation

Compressed from the commit log 2026-09-11. Each bullet cites the commits; none of it is
reconstructed from memory.

- **2026-08-11 — the pipeline exists on day one.** A real release pipeline with a JSON config and
  GitHub Actions packaging (`731c5307`), then **manual-only releases** and dev/testing scripts
  moved out of the repo root (`8b48270d`). Releasing was never automatic on a push, deliberately.
- **2026-08-12 — one zip, and the adapter declares its own game.** Packaging reworked into a single
  zip (`2f95a83f`); the release version input validated and quoted in the zip filename
  (`5ca93447`); and a **staleness-gate false positive** fixed the same day (`859e17a8`) — the gate
  that compares a shipped DLL against the sources it was built from, which recurs below because it
  keeps doing its job.
- **2026-08-27 — the doc gates existed and CI never ran one** (`18e4d49b`), so they held only when
  somebody remembered. The first instance of this file's recurring theme.
- **2026-08-28 — a release you can try without cutting one** (`47a1047b`).
- **2026-09-02 — what a prospective host asked for.** A bounded log, a binary you can rebuild, a
  scan, a policy file, and the README put back (`240d4592`) — the first time an outside reader's
  questions drove the packaging. The policy file declares its own budget and **CI now says when
  quic-go has moved on** (`75c0052a`); quic-go v0.61 → v0.62 and Go 1.25 → 1.26 because it asks for
  it (`24c106ba`). A vague duration was caught by the docs gate **inside a CI comment**
  (`312ba7fd`) — the gate reaching the file that configures it.
- **2026-09-03/04 — fuzzing becomes a campaign.** Everything fuzzed at once, plus the chord parser
  and the hand-edited config (`6ca1c992`): the first campaigns found a folded duplicate modifier
  and **a chaser queue sized to 336 hours**, both fixed, with the fuzzers' own inputs kept as the
  regressions. A hostile-input harness over TEVI's shipped bridge decoder with no adapter change at
  all (`d31b2a3b`), the Lua decoder harness in CI (`78b69d9e`), and the adapter JSON readers'
  fuzzer breaking one of their own assumptions (`c096e81e`). A release may carry a few lines about
  what it is for (`fc74930c`).
- **2026-09-05 — a staging input was shipping.** The per-game config overrides moved out of the
  release tree (`6dd8c2ef`): they had been going out as an empty `{}` in every zip.
- **2026-09-06 — code signing, and the two prerequisites that needed nothing from SignPath.**
  The SignPath policy page, and the **Windows version resource both exes lacked** — go-winres, ISC,
  build-time only, deterministic (`ddb168d3`). **The adapter DLLs stay unsigned by design.** The
  policy's account of who does what was corrected three times in one day (`0406af6a`, `3ec29b8c`,
  `d9fc65fe`) before it said the true thing: the AI agent writes the code and holds no role, the
  maintainer reviews, and a push happens on an explicit per-push instruction through the
  maintainer's account. **Roles are the one place SignPath cares**, which is why three passes were
  worth it. Also: the four fuzz pins that had never had a step got one (`cc8e196d`) — the user's
  rule is that **CI runs every Go test it can**.
- **2026-09-07 — the leak scanners could not see binaries, and CI barely ran them** (`59fd7a14`);
  a release now refuses to build if the release BODY carries a machine-specific path (`84799e27`).
- **2026-09-08 — the anchor check read UTF-8 as ANSI** and called a correct link broken
  (`1dcd6ea5`). A gate wrong in the safe direction is still wrong, and it trains people to ignore
  it.
- **2026-09-09 — SignPath Foundation declined, on visibility grounds** (`ea3b1357`); reapplication
  invited, alternatives listed, none adopted. Recorded rather than quietly dropped, because the
  next person to ask "why isn't this signed?" deserves the answer. Same day: **a stray file cannot
  enter the repo** — the root is an allowlist and a local-only header is refused, in the hook, in
  preflight and in `hygiene.yml`, **each proven to fail on a plant** (`3981c8df`).
- **2026-09-10 — the release script failed five different ways in one day, and each was real.**
  The trigger was v1.2.6's first dispatch going **past a stale-DLL FAIL that was on screen** — the
  second such release — so a release is now cut behind preflight: rebuild what it names stale,
  refuse on any FAIL, wait for CI, then dispatch (`fde47c9b`). Then the script itself:
  - the clean-tree check read `git status`, not content, and **nine line-ending phantoms refused
    the first run** — now `git diff --quiet HEAD` (`94c75727`);
  - `git` on PATH was **the devkitPro shadow on this machine**, whose diff refused on 3,167
    line-ending phantoms — now git by path, and the clean check ignores CR at EOL (`25c19521`);
  - the second git candidate path **carried a backspace byte from an inline-heredoc escape**
    (`0f121787`) — the repo's own documented hazard, landing in the release script;
  - `gh` answered as JSON parsed through a `jq` expression quoted through two shells, and **the
    third run looped on gh's usage text for the whole CI wait** — now parsed in PowerShell
    (`ec58a1f1`);
  - **Windows PowerShell 5.1 returns a parsed JSON array as one object**, so the arrays are
    unrolled (`c54cd21a`).
  Also that day: the 1046-line zip README split into `docs/`, one copy, staged into the zip
  (`1977b4ea`), the zip's `docs\` made to read as the folder it is with 39 pointers fixed
  (`a9a8fccc`), the release README cut to setup only (`84c7cc8b`), and **nothing shipped hedges
  about itself** — the EXPERIMENTAL blocks are out of the release (`ee724e71`, `0f3a2040`).
- **2026-09-11 — a harness that proves the gates can fail** (`0e82cb74`, `496223d4`).
  `dev-scripts/negative-test-preflight.ps1`: a detached worktree at HEAD, the working copy's
  preflight copied in, one real violation planted per run, and an assertion that the section aimed
  at it names it — **because a plant that quietly did nothing is indistinguishable from a blind
  gate.** Fifteen fixtures; `gates.yml` runs it on any change to preflight, the harness or the
  hook. **It found three on the first pass**, and the first is the one to carry forward:
  **`Set-Location` moves PowerShell's location and NOT the .NET process working directory**, so
  four sections reading files through `[IO.File]` with a relative path were reading a different
  tree — a planted username sat in a tracked `.dll` while the gate printed *"no NEW tracked binary
  embeds a machine-identifying path"*, having read the clean copy next door. Also the `.github`
  link gate scoped to one filename rather than the folder, and the reproduced-expression check
  that had WARNed on every clean run it ever had. **A check can be correct and still be pointed at
  the wrong thing, and a clean result then only tells you it ran.**

## Open

- **Coverage stands at 8 of 47 preflight sections** with a negative test; the harness prints the
  other 39 on every run. Tracked in `status.md`, not claimed as proven gates.
- **The disarmed-probe WARN prints 21 entries every run** — the always-on pattern this file keeps
  finding, and a candidate for the same ratchet the fence check got.
- **Code signing is unresolved**: SignPath declined 2026-09-09, reapplication invited, no
  alternative adopted. `docs/code-signing.md` carries the state.

## 2026-09-11 — the file exists because a phase audit found what owned nothing, and the coverage gate that follows from it

The session that created this file, logged here rather than left for a later backfill — the
failure this whole day was about.

**The audit.** The user asked whether the phase files were missing things. They were: five days
absent from Emerald's log alone, including its largest (36 commits, the OAM tier). Sweeping every
live phase file found **zero absent dates afterwards, from 24 across six files** — and the finding
that mattered was *why the existing gate never fired*. "Phase log freshness" counts commits since
the file was last touched, which is a **backlog**, and a backlog clears when you write about
something else. Every gap was a one- or two-commit day; **six postdated the gate**, one was from
that same morning. Detail per adapter: the 2026-09-11 commits on `phase6`/`7`/`8`/`9`/`10`/`11`.

**The gate that followed.** "Phase log coverage" fails a date on which a phase file's tree changed
with no dated heading claiming it — per-DATE, chosen after measuring that **only 21-29% of adapter
commits touch their phase file in the same commit**, so a per-commit gate would fail three quarters
of commits and be wrong to. It starts from each file's first dated heading (a component log's
Backfill list is the correct form for pre-creation history and must not be failed for it), and its
message **names the sibling file that shares the actual commits**, because the dominant cause is one
commit touching several trees while one file gets written.

**Proving it went wrong three times, which is the keeper.** Attempt one planted with a regex that
never matched an em dash — reported BLIND while proving nothing. Attempt two applied but asserted
against a stream `Write-Host` does not write to — reported BLIND with the FAIL on screen. Attempt
three was correct (exit 0 clean, 1 planted, 0 restored) — but attempt one had **corrupted the file
being tested**, `Get-Content -Raw` reading UTF-8 as ANSI, committed and then repaired (`fc4fc3ad`).
**A test that mutates a real tracked file needs the detached-worktree discipline
`negative-test-preflight.ps1` already uses**; planting into the working copy is how all three
happened.

**Pointer:** the negative-test harness itself, and the three gates it found blind, are logged in
[phase10.md](phase10.md)'s 2026-09-11 (later) entry — written before this file existed.
**From this date, delivery and gate work logs HERE**; phase10's earlier gate entries stay as
written, because a past entry is never edited.

## 2026-09-11 (evening) — every claim in `docs/` re-checked, and what four days had made untrue

The user asked for a fact-check across the user-facing docs, `reviewing.md` above all. Ten files,
~2,750 lines. Three search agents fanned out, then **every finding was re-verified by hand against
the file it named before any edit** — which mattered, because four of them were wrong.

**What held.** `integrating.md` end to end: every message type, field, reject code and reason string,
the QUIC and UDP wire constants, the tag story, the licensing paragraph. `config.md`'s key census: no
key in the doc that does not exist, none in code or the shipped config it omits, every default right,
every relay/core/mod attribution right. `reviewing.md`'s ten-package relay import list (checked with
`go list -deps`), its hello-check ordering step for step, its fuzz census (25 CI steps / 27 targets /
8 packages), and its reproducible-build recipe flag for flag. `code-signing.md` and `antivirus.md`
whole.

**The four corrections to the search pass, all caught by re-reading the source:**

- **`ghost_collision` is per-adapter, and the obvious fix would have been a new error.** Three pages
  said "no shipped mod acts on it yet". The proposed fix was "the shipped adapters read it". The
  relay's own flag help has it right: the **two Lua adapters** read `session_policy` and go
  walk-through on `disabled`; **the two PC adapters do not read it** and hold anyway, because neither
  ships ghosts solid. Swapping one blanket claim for the opposite blanket claim is not a fix.
- `security.md` was reported as telling readers three times to search `architecture.md` for a string
  it does not contain. It says it **once**.
- The code-signing prerequisites landed **2026-09-06**, not 09-08.
- `networking.md`'s `sendState` paragraph was reported as a false "synchronous" claim. It is not
  false — `sendState` genuinely still chooses `SendUnreliable` over `Send`. The section is
  *incomplete*, which is a different edit.

Three reported findings were **dropped** on re-reading: `readBufferBytes = 65535` described as "a 64
KiB buffer" is ordinary rounding; §9 "Two files" is correct about the relay, which is what that
section is about; and `reviewing.md`'s paraphrase of CLAUDE.md's regression-test rule is fair.

**The load-bearing corrections.** `getting-started.md` sent Emerald and Crystal players to BizHawk's
Lua Console for a line only `meshghost.exe` writes, into `meshghost.log` — so the two games whose
players were sent there are the two that could never show it. `security.md` said it had been audited
adversarially **once** when the second review, on 2026-09-07, is cited by that same page two hundred
lines earlier. `networking.md` said "exactly one bounded queue" when there are three, and the
sentence explaining what the one is for is backwards for two of them. And `security.md`'s changelog
stopped at 2026-09-08 with four days of hardening under it, including a udp session-token hijack and
a TLS wrapper that had been quietly defeating the 2026-09-02 descriptor-exhaustion fix for six days.

**Three dead cross-references, all of a shape preflight cannot see** — its link gate resolves link
*targets*, not section names inside them. The TLS channel-binding design was cited twice as living in
`ideas.md`, which contains no mention of channel binding at all (it is in `security-design.md`; the
same wrong pointer was in `verified.md` and ADR 0021, both repointed). `verified.md` has no
"start-order independence" entry. `architecture.md` does not contain the string readers were told to
search for. **A gate that checks whether a link resolves says nothing about whether it lands on what
the sentence promised**, and these three had survived every run.

**One claim was false in a way no doc edit could settle**: `getting-started.md` said Emerald and
Crystal "do not do replays or chasers yet" and TEVI and Pseudoregalia do. `core/localpeer.go` opens
by saying a client-invented ghost renders "through the same buffer, the same bridge messages and the
same adapter code as a real peer" — there is no per-adapter capability to have or lack. The user
confirmed the assumption behind it was never tested: only Pseudoregalia has been watched. The page
now describes the mechanism and claims no per-game behaviour, and the untested half is filed in
TEVI's, Emerald's and Crystal's `UNVERIFIED.md`.

**Left alone deliberately**: `Plugin.cpp`'s comment that `session_policy` is "honoured by zero of
four" is stale, but `preflight.ps1` hashes every source into the committed DLL's `built-from.txt`, so
a comment-only edit marks that DLL STALE and buys a C++ rebuild and a deploy. Recorded rather than
touched.

## 2026-09-11 (later) — a fact-check of every player-facing page, and autostart becoming opt-in

**Compressed from the commit log** (`528fe77d`, `12effc54`, `44f3fb09`, `2c3ce628`, `9badcab7`,
`c611741d`); each bullet cites the commit that carries the full reasoning. Logged here because this
phase owns docs, packaging and the gates, and five of these six landed under it.

**The one a player would hit first.** `getting-started` told Emerald and Crystal players to look for
*"connected to relay ... in room ..."* in BizHawk's Lua Console. **That line is written by
`meshghost.exe` into `meshghost.log` and by nothing else** — the Lua adapters do not emit it and do
not capture the core's output, because the core is spawned windowless with no pipe, deliberately.
**So the two games whose players were sent to the Lua Console are the two that could never show it
there.** The Console is still the right place to check whether the MOD loaded, which is what the
page says now; the same correction went into `troubleshooting.md` and the shipped `README.txt`
(`528fe77d`).

**`ghost_collision`, and why the fix is per-adapter rather than another blanket.** Three pages said
*"no shipped mod acts on it yet"*, which stopped being true for half the adapters on 2026-09-11.
Swapping one blanket claim for the opposite one would have been just as wrong: the two Pokemon mods
read `session_policy` and go walk-through on "disabled"; TEVI's and Pseudoregalia's do not read it,
and it changes nothing for them because neither ships ghosts that block you (`528fe77d`).

**`security.md`'s claim list had stopped four days short**, and `reviewing.md` points a reviewer at
that page as the list of claims to disprove — so a claim that has quietly stopped being true costs
more there than anywhere else in `docs/`. The new section covers four pieces of hardening, each
confirmed against its commit, including a relay that **could silently stop accepting TCP for the
life of the process**: the sniffing listener returned on its first Accept error and Serve's retry
then blocked forever, so for six days the descriptor-exhaustion fix that page documents was
defeated by the wrapper in front of it, with `tls=auto` the shipped default (`12effc54`).

**The README stopped defining itself by a negative list.** It read as a category definition followed
by *"no synced items, enemies, health or progression"* — the shape cut from the player docs on
2026-09-10 — and *"live position, facing and animation"* had stopped describing what ships:
Pseudoregalia mirrors outfits, weapon models, trail colour and an input track, TEVI afterimage
trails and warp state, Crystal palette and species. Three word-level corrections went with it:
**"draws" to "shows"** (drawing is only what the painted tiers do), **"relay" to "server"** (the
README is the first thing a stranger reads, and everyone already owns the word server — relay
stays in `security.md`, `networking.md` and `contract.md` where "forwards, does not simulate" is the
point), and **"know nothing about the game they run beside" to "the game itself"**, which is the
only half of it true of a server on someone else's machine (`44f3fb09`).

**Autostart is opt-in everywhere now, and looks only beside the mod.** The Pokemon scripts searched
three places for `meshghost.exe`: beside the script, the release root three levels up, and a source
checkout four up. **So an install that had never copied an exe anywhere still had a core started for
it from the root** — the per-game copy was not an opt-in, it was the default with an extra step for
people who wanted separate logs. Both `../` fallbacks are gone; the search is the script's own
folder, after `MESHGHOST_CORE_DIR` for a dev checkout. Two shapes, never both: **exe in the release
root means you run it yourself, exe beside the mod means the mod runs it** (`9badcab7`). The
matching doc sentence — *"a small client that your game's mod starts and stops for you"* — stated
unconditionally something the reader has to opt into, and sat in "How it fits together", which is
reached before the step that tells them to copy the exe (`2c3ce628`).

**And the shipped `config.json` stopped warning about its own keys** (`c611741d`), with two tests
that had raced the new writer fixed alongside it.

## 2026-09-12 — pointer: a formatting-only pass over four `docs/` pages

`e58a53d3` normalised markdown table delimiters (`|---|` to `| --- |`, the MD060 lint rule) in
`code-signing.md`, `config.md`, `integrating.md` and `security.md`, plus one stray blank line. **No
prose changed.** Committed on its own so the third adversarial review that followed started from a
clean tree and its diffs carried no unrelated noise; that review's record is
[phase10.md](phase10.md), 2026-09-12.

## 2026-09-12 — the fuzz census checks itself

`docs/reviewing.md` said "the census is maintained by hand" in a paragraph that was itself wrong
about which of two targets runs its seeds, and the roster had been wrong five times by the repo's
own count. `preflight.ps1` now walks every `func Fuzz` in the tree and requires a CI step and a
roster row for each; `ci-fuzz.sh` already caught the opposite direction, so the pair is closed. An
un-campaigned target must declare `// fuzz-census: no-ci-step -- <reason>` in its own file: a first
draft inferred the opt-out from an env-var guard and silently exempted the wrong set, which is the
same hand-maintenance failure. The gate found two on its first run, both also reported by the
instrument-integrity cell of the review. Commit `41972ff9`, with the `/adversarial-review` skill.

## 2026-09-13 — preflight learns to look for reproduced expression anywhere

The fenced-block check watches `documentation.md`; the violation it was written for landed in a Lua COMMENT in the Emerald adapter instead — three verbatim lines of decompiled C, caught by the user asking rather than by any gate. A new section greps tracked text for the SHAPE of reproduced source (a decomp-style typed declaration, a pointer-typed struct), deliberately narrow so prose arrows like `spawn -> OAM -> drawn` do not bury it: measured over the tree, the narrow form finds five lines, four of them real. It FAILS rather than warns, because licensing is the one rule with no judgement call in it. Also: `/config.json` ignored (a developer rig's own core config, beside the `dev-scripts/config.json` rule it mirrors), and `dev-scripts/README.md` now documents the session toggles.

## 2026-09-13 — SYNCED.md: a page per adapter that is also the guard checklist

**What the user asked.** Why only Pseudoregalia had `PLAYER_FIELDS.md`, and whether every adapter
should have a schema of what it sends. It was a mix of a synced-keys table, a field map and
investigation history. Decided together: a new mandated file, `SYNCED.md` (the user picked the
name), **user-facing** like the README, documentation and bandage register, laid out as a short
summary table per group plus a fold-out details table (the user's pick from three mock-ups), with
*Read from* naming the game's field and our function, never a line. The user then noted it doubles
as the dev's checklist that every value has a clamp or guard, which became the design: a
*Checked on arrival* cell is mandatory, and an unguarded value says `not checked yet`.

**What was done.** Template first (`3dab00d5`), then Pseudoregalia with `PLAYER_FIELDS.md` split
into it and `documentation.md` (`fc3872f6`), TEVI (`51711511`), Crystal (`67602b58`), Emerald
(`70b144bd`), each written from the send and receive code rather than from records. Three Explore
passes did the first inventory; every row was re-read at its code site, and that caught the passes
out twice (TEVI sends 26 extras, not 29; Crystal writes more than the action into ghost memory).
Preflight's new section (`a7cd1ebf`) holds 97 keys to their pages both ways, pairs each summary
with its details, refuses an empty check cell and ratchets `not checked yet` at 6 / 20 / 2 / 1;
two negative-test fixtures prove it fails. The gaps above key level went to `tevi/` and
`pseudoregalia/UNVERIFIED.md` as OPEN (`ee43ebd7`).

**Left open.** A code-only push does not run the check in CI: `docs.yml` may not filter on adapter
paths (the adapter-gate rule caught the attempt), so drift is caught by local preflight and
`release.ps1`. `Plugin.cpp` comments still name `PLAYER_FIELDS.md`; changing them needs a rebuild.

**Filed afterwards, same day.** Four follow-ups joined the "measured or observed only" audit in
`status.md` with `hold to 2026-09-16` -- the user's timing, as their weekly usage limit runs out
before then, and they asked that the items not age out. Preflight ages a status item by its newest
date, so no gate changed; `status.md`'s header now says what the marker means. The subagent miscount
became a pitfall (`pitfalls/by-lesson.md`, "A subagent's inventory of the wire was wrong twice").

## 2026-09-13 — A per-game config carries only the keys that game reads

**Found by the user reading the file, not by a check.** After the config rename went out they
asked why `map_markers` — TEVI's pause-menu peer markers — was in Pseudoregalia's `config.json`.
It was there because `stage-release.ps1` cuts the SAME client block for every game, strips only the
`$hidden` advanced keys, and then applies per-game overrides: there was no per-game **removal** at
all. `ghost_range*` escapes that only because it arrives the other way, added per game from
`config-overrides/pseudoregalia.json`. So a key one mod reads went to all four games, and nothing
complained — `notClientSettings` deliberately keeps both out of the unknown-key warning, which is
exactly why it survived unnoticed since `63b6ca5c`.

**Why it is worth fixing at all, given nothing breaks:** a player edits a setting in their own
game's config, nothing happens, and there is no way for them to learn the key was never theirs.
That is a support question with no self-service answer.

**What was built.** `Remove-ClientKey` (a scalar line, or a nested block closed by the first line at
its own indent) plus a `$gameOnly` table naming the one game each such key belongs to —
`map_markers` → TEVI, `input_display` → Pseudoregalia. The root `config.json` keeps both: it is the
complete reference, and `docs/config.md` documents each with its reader, now including the sentence
that adding it to another game's file does nothing. Ownership lives in the script rather than in
three override files saying "not mine", because that is the shape that drifts.

**A latent bug fell out of writing it.** The override path rendered a non-string with
`[string]$prop.Value`, and `[string]$true` is `True` — not JSON. No override had ever been a
boolean, so it had never fired; it would have produced a config no client could read, at the first
attempt to move `map_markers` the other way. Fixed in the same pass.

**The pin.** `TestEachGameConfigCarriesOnlyItsOwnModKeys` asserts the ownership both ways — a key
absent from the games that do not read it, and PRESENT in the one that does, so a too-eager strip
fails too. It skips in a clean checkout like its neighbours (the per-game files are gitignored
staging output), and it was watched to fail before it was kept: re-adding `map_markers` to the
staged Pseudoregalia file failed it with the line naming `$gameOnly`, and re-staging turned it green.

## 2026-09-15 — pointer: this day's workflow and script changes are logged in phase10.md

The fourth review's fixes touched `ci.yml`, the hooks, `preflight.ps1` and `stage-release.ps1`
(the 2026-09-15 entry in `phase10.md`), and the TLS work the same evening added a fuzz step to
`ci.yml` and a `private/` refusal to `stage-release.ps1` (ADR 0066, the evening entry there).
The night of 2026-09-15 is there too: the private-IP test fixtures moved to RFC 5737 ranges so the
leak check's negative fixture proves something again, and the one LF `.bat` was re-checked out.

## 2026-09-15 (later) — pointer: CI sharded, the fuzz job six ways and the race tests three

`41b5a8d1`: `ci.yml`'s fuzz job is a six-shard matrix and its race tests a three-shard one, every
target, fuzz time and `-count=3` unchanged; `ci-fuzz.sh`'s message names the per-shard artifact.
The run on that push: green in 5m17s wall against 17m24s the run before. The read that led there
(the core package at Go's ten-minute limit, the ring fix) is the "after prediction" entry in
`phase10.md`. Not touched: `release.yml`, whose two serial jobs are the next cut.

## 2026-09-15 (last) — the release's Windows tests run beside the unix job

`release.yml`: a `windows-tests` job (vet, `-count=2`, same as before) runs in parallel with
`unix-binaries`; `build-and-package` needs both and no longer tests itself. What blocks a release
is unchanged -- a red on either side and the packaging job never starts, so no tag and no
release. Expected: about 7 minutes in place of 11. Unproven until the next release is cut.

## 2026-09-16 — an Adapters workflow, so the SYNCED gate fires on a code-only push

`846f5a32`: `.github/workflows/adapters.yml` runs `preflight.ps1 -TreeOnly` on any push under
`adapters/**`. Until then the SYNCED.md section (keys in the send code held to the page, the
"not checked yet" ratchet) ran in CI only through `docs.yml`, which fires on `**.md` -- so the one
push it exists for, a key added in C++/C#/Lua with no row, never ran it. Widening `docs.yml` was
refused by preflight's own rule that an adapter gate names only `adapters/**` and its own file,
hence a separate workflow. Same day, `96ed6168`: all 29 "not checked yet" cells guarded (6 / 20 /
2 / 1, ratchets to 0), both DLLs rebuilt and deployed to every install; unwatched in a game.

## 2026-09-16 (later) — every tree-only preflight gate has a negative test; the disarmed-probe warning is a ratchet

The status item: 39 of 47 sections had no fixture in `negative-test-preflight.ps1`, and the
blind-reflection section printed its 23 disarmed entries as a WARN on every run. Now 61 fixtures
cover every section that runs under `-TreeOnly` except two that read git history a plant cannot
rewrite (`CRLF-pinned batch files`, which skips its byte check there, and `_template back-port
freshness`, which already WARNs on a clean tree); the harness counts its coverage against the
live sections only, naming the ones that need a working copy apart. Three plant helpers were
added for the gates a trailing line cannot reach: a regex replace (first-match readers such as the
bridge port constants, the RemoteGhost struct, the drop site), a tracked-file removal (the adapter
file set) and a commit in the scratch worktree (phase-log freshness), with the reset between
fixtures now a hard reset to the real `HEAD`. The disarmed-walk count is `$ratchetDisarmedWalks`
(23): a rise FAILs and lists every entry, a drop FAILs until the number is lowered, and a clean run
prints one PASS line.

Two things the run caught on the way. The recorded floor was first written as 22 from a hand count
of the warning's entries; the harness's baseline reported the section already FAILing on a clean
tree, which is how the miscount surfaced -- the ratchet had never been run before the fixture was.
And two fixture strings holding an em-dash broke the script's parse: PowerShell 5.1 reads the
BOM-less file as CP1252, and one of the em-dash's three bytes is a curly double quote, which closed
the string; every non-ASCII byte in that file is now a parse error waiting, so it stays ASCII
(`dev-scripts/README.md` says so). The full run was 59 of 61 with the floor at 22; after the fix the two blind-walk
fixtures re-run with `-Only`.

## 2026-09-16 (last) — the gates workflow is sharded six ways

The harness has run in CI since 2026-09-11 as `.github/workflows/gates.yml`, unsharded, filtered
to preflight, the harness, the pre-commit hook and itself. This session first wrote a second
workflow for the same job without reading the folder it listed -- caught while answering what else
could be sharded, when the run list showed `gates` at 805 s -- and folded the sharding into the
existing file instead. Its two red runs were read: 2026-09-13 the documentation-fence fixture, whose
section already warned on a clean tree then; 2026-09-15 a stale `status.md` at that commit. Neither
was a blind gate, and both are fixed by later commits.

Why shard: the runner takes about 45 s per fixture, so today's 61 would run about 47 minutes in
one job. The harness grew `-Shard i -Shards n` (fixtures dealt round-robin by position, each job
its slice plus the baseline; the coverage tally reads the full list so a shard never reports the
fixtures it did not run as gaps), and `gates.yml` runs six such jobs, the shape `ci.yml` uses for
the race tests. Checked locally: a 30-way slice ran two fixtures end to end with the tally intact,
and an out-of-range shard is refused. The sharded workflow is unproven until the push that
carries it.

**Same day, after the push.** The sharded `gates` run: five shards green in 279 to 492 s, shard 1
red on `bridge-port-drift` -- the PLANT failed, not the gate: the runner checks out with CRLF and
the pattern's `$` anchor does not match before a carriage return. The pattern now tolerates `\r`
(proved against both endings; a sed attempt put a raw CR byte into the file first, which the
byte dump caught). The other three regex fixtures anchor on nothing that ends a line.

## 2026-09-16 — two entry points in `agent_docs/`, and one line in `reviewing.md`

The user asked for two files: `dependencies.md`, what to install on a fresh Windows 11 with only VS
Code and a clone, by tier of what each unlocks; and `orientation.md`, the whole project in plain
words for the maintainer coming back after a long break. Both written, indexed at the top of
`agent_docs/README.md`'s "Read before you…" list, and recorded in `doc-history.md` with what each
leaves out. Two corrections from the user during the pass: a personal program (a screen recorder)
is not a repo dependency, and `orientation.md`'s adapter ladder needed a step of its own before
"find the player" — learn how the GAME spawns a character and does the thing, and ask it to.

The Emerald paragraph shipped stale and was fixed the same day: the adapter's own README header
still claims the spawned ladder ships, while `phases/phase8.md` records drawn-only since 2026-09-11.
That README and `FLAGS.md` are now an item in `status.md`.

`docs/reviewing.md` gained one sentence pointing a reviewer at `orientation.md`'s first three
sections as the map, with the rest named as internal practice to skip — the user's call after
weighing whether a maintainer-voice file belongs in a reviewer's guide.
