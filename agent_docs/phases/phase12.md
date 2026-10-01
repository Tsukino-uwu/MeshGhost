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

**Same day, later.** The user read "recorded in `status.md` so it does not get lost" and asked
whether it had not simply been fixed -- it had only been offered. Fixed now: the README header and
ladder bullet say drawn only since 2026-09-11 with the spawned and hardware rungs as dev opt-ins,
step 42 tells the drawn-only call in the user's words with the cross-gender ghost it fixed and the
`gMapHeader` relocation it exposed, and the three `FLAGS.md` rows carry the defaults the Lua actually
has (spawn cap zero, hardware off and enabled only by `"1"`, drawn on). The `status.md` item is gone.

## 2026-09-16 (later still) — `documentation.md` is the game only: the audience set, five files stripped

Mid-audit the user asked why the Archipelago mod's three-file toggle sat in Pseudoregalia's
`documentation.md` — *"this is not a fact about the game itself its a fact about another mod"* —
and then set the file's audience for every adapter: *"documentation files should be a user facing
doc about game functions/mechanics, not other fluff"*. `adapters/CLAUDE.md` already said user-facing,
no working notes (2026-09-13); what every copy still carried was the template's own rule section
repeated verbatim at the top ("KEEP THIS SECTION", 2026-08-18), a file table, a standing-rule
section, the file's own history ("written 2026-08-18 after it was argued…"), an "adding to this
file" section, adapter-design asides (Emerald's delayed-ghost and renderer sections), testing
lessons and the user's words quoted as colour. All of it is out of the four adapters' copies: each
now opens with the provenance line, one pointer line (`BANDAGES.md`, `VERIFIED.md`) and the first
mechanic. Emerald 867 → 773 lines, Pseudoregalia 816 → 690, Crystal 810 → 798, TEVI 239 → 202.
The rule moved with it: `_template/documentation.md`'s first section now says it stays in the
template and lists what never goes in; `_template/README.md`'s "repeated verbatim… delete none of
them" paragraph reversed; `licensing.md`'s audit grep for the guard phrase points at the template;
`adapters/CLAUDE.md`'s `documentation.md` bullet reworded in place (285 lines, cap 300). Left alone,
named so it is a decision: the `SYNCED.md` files carry the same "KEEP THIS SECTION" block and were
not asked about; Emerald's `VERIFIED.md` 2026-09-13 entry still names the deleted "delayed ghost"
heading, as a dated record. `doc-history.md` has the entry.

## 2026-09-16 (last) — the audit's Lua tier: a convention and a ratchet, not 380 rewrites

The sweep's remaining tier was the code: 130 decompilation citations in `meshghost_emerald.lua`,
46 in `meshghost_crystal.lua`, 97 and 107 across the two `probes/` folders, and 28 in `pitfalls/`.
Read in context, most sit beside a dated measurement (a probe, a trace, the user on screen) and
explain why the code writes the byte it writes; a minority are the source's reading alone
(the shadow's suppression rule, the jump's frame count, the underwater bob). Rewriting each of
the 380 sites would spend hours on shipped comments to say what one paragraph can: **a citation
is a pointer to where the decompilation places the mechanism the code imitates, never the
evidence; dated is measured, source-only is unverified.** That paragraph is now at the top of
both adapters, and preflight ratchets the four counts (a new citation fails; a shrink asks for
the floor to be lowered), so the set cannot grow silently. The stricter option — site-by-site
rewording, and moving each source-only mechanism into `UNVERIFIED.md` — is the user's call and
is offered in the handoff. `pitfalls/`'s 28 are left as they are: each is a dated record of how a
fix was found, and "the decompilation named the bug" is the method, not a claim about the game.

## 2026-09-16 — the fifth review's instruments cell: what the gates could not see

The X2 cell of the fifth adversarial review (the Go side is `phase10.md`'s entry of the same date)
read the fuzzers, harnesses and gates as the target. Fixed, each checked by making it fail:
- **X2-1 — FuzzSchedule's committed reproducer had tested nothing since 2026-09-01.** The target
  returns on any input no longer than its 5-byte config prefix, added that day without migrating
  anything: the 3-byte reproducer for "names before Welcome block the handshake" and two of five
  seeds ran in 0.00s (measured against the old seeds), and the other three lost their first five
  schedule bytes to the config. Seeds and the reproducer now carry the configuration the target
  pinned before the prefix (100Hz, 15ms interp, linear, 10ms keepalive, no cap);
  `TestFuzzScheduleSeedsAreLongerThanTheirConfig` fails on a short entry.
- **X2-2 — the fuzz census was satisfied by a name anywhere in `ci.yml`**, comments included, and
  kept targets by bare name, so `bridge` and `protocol`'s two `FuzzEnvelopeUnmarshalNeverPanics`
  were one row. Keyed by package and matched against a real step line; shown failing with
  bridge's step removed. udpconn's opt-out is now declared in its file.
- **X2-3 — the census never ran on the push it exists for**: only `docs.yml` runs preflight, and
  it did not trigger on `**_test.go` or `ci.yml`. It does now.
- **X2-4 — `release.ps1`'s "CI is green on HEAD" saw only workflows HEAD's own push triggered**; a
  red race run followed by a `.md`-only commit passed. It also refuses when any workflow's newest
  completed run on master is red (dry-run against the live runs: all green).
- **X2-5 — `FuzzHostileRelayLines`' own-player-id invariant could never fire** (`c.playerID` is
  assigned only by the connect path the harness skips). It checks every Welcome let through;
  shown firing with the Welcome gate disabled.
- **X2-6 — `FuzzHostileBridgeLines` claimed a verdict it never checked, and its liveness check
  passed on a wedged dispatch** (a pipe write succeeds before dispatch). It now waits for the
  core's answer to a hello; the pre-hello rule is pinned by its own test, and the comment says so.
- **X2-7 — `ci.yml`'s header said both schedule fuzzers replay their seeds in the race job**; one
  skips itself without `MESHGHOST_SCHEDULE_FUZZ`. Corrected.
- **X2-8 — `internal/gameblind` scanned six directories** while core, relay and netx import
  `pake` and four `internal/` packages the import rule trusts by path. All five are scanned;
  `github.com/bytemare/opaque` is allowed by name (ADR 0067), which the new scan required.
- **X2-13 — the race shard's exclusion regex matched suffixes.** Anchored on the import path.

Left open, with the reason, in `risks.md` ("Pass 5, left open"): X2-9 (the leak scanners' escaped
and lowercase path forms), X2-10 (the relay fuzzers never reach the room-code branch or a room's
map growth), X2-11 (a Pseudoregalia peer-string parser outside the fuzzed header), X2-12
(Crystal's ROM-index harness covers one of three call sites).

## 2026-09-16 (after) — the audit's Lua tier, site by site

The user took the stricter option. Four agents, one per scope, each allowed to change comment lines
only; each ran a diff check (every changed Lua line a comment) and `luac -p`, and I re-ran both over
the whole diff. Every site was classed as measured (pointer kept), source-only (reworded as unmeasured,
question filed) or forbidden (copied text, tables, layouts, reworded explanations: removed).
- `meshghost_emerald.lua`: 130 path citations to 0 (29 measured, 83 source-only, 18 forbidden).
- `meshghost_crystal.lua`: 46 to 0 (8, 25, 13).
- Emerald probes 97 to 80, Crystal probes 107 to 105: a probe citing where to look is the rule's own
  use; about 65 blocks of copied source text, struct layouts and constant tables went.
The source-only mechanisms are OPEN entries at the top of `emerald/UNVERIFIED.md` and
`crystal/UNVERIFIED.md`, each with the measurement that makes it ours (Emerald's first is a safety
premise: the door task touching nothing but VRAM and the tilemap). Preflight's floors are lowered.

**Left open, beyond a comment edit:** numbers copied into code (Emerald's `genderFrames.ctcVec`,
`reflectiveBehaviour`, `shadowDrop`, the pose-duration tables, `fishingFrameShift`; Crystal's
`facingFrames.ROD`, the shadow object's spawn bytes, `emote.SHADOW_DY`) -- each labelled unmeasured
and listed; and SOURCE TRANSCRIBED INTO PROBE CODE: Crystal's `set_level.lua` growth-rate table and
stat/EXP formulas, the screen-coordinate formula in `spawn_test6/7.lua` and `walk_test.lua`, the
constant name tables in `action_probe`, `action_watch`, `whirlpool_drive`, `struct_diff_probe`, and
Emerald's `surf_bike_probe` flag names.

Found by an agent's adapter check the same day, and fixed: TEVI's bullet ordinal guard threw on every
peer bullet (`6a538a0b`). Found by running the real relay and client binaries: a malformed config.json
save applied the defaults live, a relay's room code included, and every relay save reported
listen_quic as changed (`6f3eeb67`). The same run passed room codes (matching, wrong with a retry a
minute later, one-sided both ways), TOFU after `private/` was deleted, and live edits of max_clients,
only_game, room_code, chaser, interp, replay.seek, hotkeys and the name.

**Then the probe code, the user's call ("probly delete it for now ... if we need something again we
will recheck/measure at that point"):** deleted `set_level.lua`, `spawn_test6.lua`, `spawn_test7.lua`
and `walk_test.lua` (their code transcribed source formulas; what they showed stays in
`crystal/VERIFIED.md`, and `PROBES.md` says what each was). The copied name tables went from
`action_probe`, `action_watch`, `whirlpool_drive`, `struct_diff_probe` and Emerald's
`surf_bike_probe`, which now print raw numbers or bit indices; two code-line citations were stripped.
Probe floors 78 and 85. What remains is the borrowed VALUES in the shipped adapters, each already an
UNVERIFIED question.

## 2026-09-16 (later) — Crystal's borrowed values, measured on the game

The user picked the borrowed values as the next item. Crystal first: vanilla V1.0 launched with the dev
loader, the game continued from its own save, and `crystal/probes/borrowed_values_probe.lua` (new,
read-only) logged every object struct and all OAM through each hop and cast. All three values match
what the engine builds for the player: `facingFrames.ROD` in all four directions, the shadow's spawn
bytes on the frame it appeared, and `emote.SHADOW_DY` down 14 / left 12 / right 12. The up entry
stays open (no hop-up ledge block in the tileset used). Records: `crystal/UNVERIFIED.md` (the per-site
audit entry) and the three code comments; no code value changed.

How the states were reached is the half worth keeping. Two attempts to force a hop -- poking the
standing-tile collision byte, then an execute hook on the jump check -- did nothing, and the user
stopped them: *"make a ledge, don't force a jump without a ledge. let the game handle it the intended
way"*. Writing the tileset's own ledge and water blocks into the map buffer, redrawing through the
START menu and walking onto them worked first time once the neighbour-collision cache was understood
(a block written beside the player is invisible to the next step). The user then set the rule in
several messages -- cheat to create the thing, use it as the game intends, never be stuck, and build
states on the spot rather than trusting savestate slots -- so it lives in `playing.md` with a new
"Building a state" section, and the scratch driver became `crystal/probes/cmd_drive.lua`. One reading
lesson: a bite's "!" took the first four OAM slots (`checklists/before-trusting-a-reading.md`).

Emerald's six borrowed values are next; they need an Emerald instance.

## 2026-09-16 (later still) — Emerald's six borrowed values, measured; the audit's value tier is closed

All six match the engine (`phase8.md`'s entry of the same date has the detail). With Crystal's three,
every borrowed value the Lua tier audit left in shipped code is measured, bar what the game itself makes
unreachable (Crystal's up-hop shadow, Emerald's behaviour 26 and the non-player shadow sizes). The user
spent the session turning "cheat to reach it" into a standing mindset, now the opening of `playing.md`.

## 2026-09-16 (last of the day) — `playing.md` becomes the `play-game` skill

The user brought a task and a draft SKILL.md written in a Claude Desktop chat from the public copy of
`playing.md`, with the instruction that the repo wins. The instructions moved into
`.claude/skills/play-game/` (SKILL.md at 115 of a 120 cap, registered in preflight's budgeted list)
plus four references: `building-a-state.md`, `navigation.md`, `screenshots.md`, `bizhawk.md`.
`playing.md` became `playing-rationale.md`, keeping the quotes, the live cases and the dated rulings.
`CLAUDE.md` gained the slot-1 and one-agent-per-instance rules and the `/play-game` pointer at no net
line. What the draft had wrong, because its author saw one file: no mindset or "Building a state"
(written the same day), the queue driver unnamed (it is `cmd_drive.lua`, polled every 15 frames, not
every frame), `bikeloop_probe.lua` without its game, a reserved-slot "table" in `running-the-rig.md`
that is a bullet list, and the one-agent rule pointed at `environment.md`, a stale pointer inherited
from `playing.md` itself. `environment.md`'s "all ten slots are ours" (2026-08-18) now carries the
2026-08-19 narrowing. New ruling from the user while reviewing the autoplay plan: where a host cannot
capture its own frame, a window capture is fine, and every capture stays gitignored. Checked:
`claude plugin validate --strict .claude/skills` passes; preflight clean; a headless fresh session
loaded the skill as its first call on "Get the Crystal instance to a trainer battle" and did not on
"Fix a build error in the Tevi adapter". Phase files and `doc-history.md` keep `playing.md` as written.

## 2026-09-17 — the gates learn about autoplay (reconstructed from the commit record)

**Written from the commits, not from the session.** Autoplay's arrival changed three things in this
phase's territory, none of them logged here at the time:

- **`.github/workflows/autoplay.yml`** — a CI workflow of its own, 50 lines, added with autoplay's
  first commit (`551accd6`). ADR 0071's reasoning is why it must exist: `autoplay/` is a second Go
  module, so the root module's build, vet, test, race shards and `govulncheck` — in CI and in
  `release.yml` — never see it, and it therefore needs its own checks rather than inheriting any.
- **`preflight.ps1` excludes `autoplay/` from the root-binaries check** (`551accd6`), for the same
  reason in the other direction: none of the root binaries contain that module.
- **`preflight.ps1`'s phase-index check went `-Recurse`** (`7eea2855`, 2026-09-17), because autoplay
  logs moved to one file per game under `phases/autoplay/` on the user's call, and a nested phase
  file was invisible to a flat scan. `c7dfeb55` carried a further +44/-7 to preflight alongside the
  `MEASURED.md` records class.

The pattern worth keeping: **a new dev-only component costs this phase a workflow and a preflight
amendment, and both are easy to leave unlogged** because they ride in a commit whose subject line is
about something else entirely.

## 2026-09-18 — the phase-log rule gets a gate at the moment it can still be obeyed

**The problem, found the same day.** `preflight.ps1` has counted commits to an area since its phase
file last changed for a while, failing at three. It works — it is what found phase6 twelve commits
behind, phase9 ten and phase12 three. But it catches the neglect **later, in a batch**, and by then
the chats that did the work were closed: what was tried, what failed and what the user said was
gone, and three entries had to be reconstructed from the commit record and labelled as such
(`phase6.md`, `phase9.md`, and the entry above this one).

**Why the rule alone could not hold.** A chat has no end event. Nothing fires when one is closed, so
*"append a dated entry before the session ends"* depends on the user remembering to hint and on an
agent choosing to read the hint as an instruction. The user, 2026-09-18: *"i do try to end most chats
with 'is it fine to start a new chat', but i guess that is not enough of a hint/push"*. It is not,
and on that very exchange this agent treated it as a yes/no question and pushed the missing entries
onto a chat that no longer existed.

**What was built.** `.githooks/pre-commit` gained a second check: if this commit touches an area a
phase file owns, and does not touch that phase file, and would be the `lag-max`-th such commit, the
commit is refused. It moves the moment from "before the session ends", which nothing signals, to
"the commit that does the work", which always happens and always has the context still loaded.

**One definition, two enforcers.** The path map and the threshold moved out of `preflight.ps1` into
**`dev-scripts/phase-map.txt`**, which both read. Written twice they would drift, and this repo was
already carrying a live example of a gate disagreeing with the rule it enforces (preflight's
"One-line entries" check fails a second line on a `status.md` item that `CLAUDE.md` explicitly
permits — still open). The file also brought `phase-map.txt` itself into phase12's pathspec: a
change to the gate's map is delivery work.

**Proved in both directions before being kept**, per `testing.md`'s "Confirming a test can actually
fail": at `lag-max 1` a commit touching `.githooks` with no phase entry was refused naming
`phase12.md`; staging this entry let the same commit through; at `lag-max 0` preflight named all
seven phases with their full pathspecs, which is what proves it parses the shared file rather than
quietly running on an empty map.

**What it does not do.** No gate can make an entry *good* — the narrative is still the agent's to
write. It only forces the moment of writing while the context still exists, which is most of the
value and not all of it. And it is a `pre-commit` hook, so it protects a clone that ran
`git config core.hooksPath .githooks` and nothing else; preflight and CI remain the backstop.

## 2026-09-18 (later) — a pre-push audit of autoplay, and the gates it went red on

**Why.** Autoplay had never been pushed. The user's question before pushing it: is anything under
`autoplay/` gitignored — saves, states, logs, pictures — and is there anything in there we would not
want in a public repo.

**The ignore answer was yes, with two gaps.** Everything autoplay generates was already out:
`runs/` (30MB of run `.ndjson`, session folders, driver logs), `states/` (118 savestates, 56 `.sav`,
TEVI's shadow save folder), `bin/`, `obj/` (including the `FileListAbsolute.txt` that holds
machine-local NuGet paths), and every capture, which goes to `dev-scripts/shots/`. The gaps were
that `/autoplay/*.log` was ROOT-ONLY and `/adapters/**/*.log` does not reach autoplay, so a log,
control file or capture written beside a driver was untracked-but-not-ignored — the shape that
swept `ap_try.flag` in on 2026-08-18. Widened to `/autoplay/**/` for `.log`, `.cmd` and `.png`,
with the adapters block's `assets/` exception (`a1b310e0`).

**The provenance answer was clean, and it is worth recording WHY it is clean**, because the pattern
is the reusable part: no game data is in the repo at all. Species, move, type and item names, move
power and accuracy, and the full type chart are READ OUT OF THE ROM at runtime from measured
addresses; the charsets are built from measured letter ranges plus captures of the game drawing each
byte; every decomp mention is labelled as a map (`the decomp as the map only: NOT measured`); the
TEVI driver reflects by name at runtime against the user's own install. That also satisfies the
access model — the repo works for someone holding only it and their own ROM.

**Then preflight, which was already red, on five counts.** Cleared in `ca304b8f`, each at its cause:
two durations written as bare hours (one a real gap, now "past 24 hours",
one about clock hours 0-11 and never a duration at all); three `status.md` items over one line; two items stale at 2026-09-15, re-dated only
after checking each was still true (the Pseudoregalia adapter still mentions `session_policy` only
in 2026-09-04 comments; `phase10.md` says in its own words that the 450ms `-loss-burst` item stands);
and a pitfalls lesson that said "the rule this adds" and then filed the rule nowhere, which is why
its index line had no outcome — now in `checklists/before-trusting-a-reading.md`.

**The `status.md` contradiction the previous entry left open is NOT resolved.** `CLAUDE.md` permits
two lines per item ([../claude-md-cap.md](../claude-md-cap.md)) and preflight's one-line gate fails the second. Today's items were compressed to
one line each, which makes the tree green without deciding which rule is right. Whoever decides it
changes one or the other; the workaround is not the decision.

**The hostname gate went red on autoplay and on nothing real:** `q.no`, `question.no` and `s.info`
are Lua field accesses whose key is a TLD, and `steamworks.net` is the C# Steam binding
`AchievementGuard` names. They joined the section that already carries `env.io` and `ref.no`.

**And the four grandfathered binary leaks came back around.** They were found by scanning before the
record was read, which is exactly the re-raise `risks.md` existed to prevent — the record was
complete but read as pending ("decide at the next UE4SS bump"). The user's first call was not worth
doing; their second was to schedule all four together, since it is a one-time fix that keeps the
tree clean afterwards. `status.md` holds the task (`hold to 2026-09-25`), `risks.md` the sizing and
the done-test (an entry clears when preflight stops naming it), preflight's own message the pointer
(`e903b30a`, `457aa398`). **The lesson is about records, not binaries: a findable record that reads
as an open question gets re-derived by the next session that trips over it.**

## 2026-09-22 — pointer: the CI image test, and the root allowlist gains `nuget.config`

Two commits from 2026-09-18 this log never claimed: every Linux job moved to `ubuntu-26.04` as a test of the image
before GitHub makes it `ubuntu-latest` (`41f16dd2`), and back to `ubuntu-latest` once 26.04 was known green
(`41808a70`). Today the root allowlist in the hook, `preflight.ps1` and `hygiene.yml` gained `nuget.config`, the one
file that names the NuGet feeds every `.csproj` restores from (`be517483`; the why is in `phase6.md`, same date).

## 2026-09-23 — toward v1.3.2: the config doc, one CI flake, the version question

The user asked whether to promote the v1.3.1 pre-release (`24393ba0`, 2026-09-22) or cut v1.3.2: the
pre-release is 32 commits behind and misses the chaser-contact work, so v1.3.2 (a published tag is
never moved). `docs/config.md` said no shipped mod honours chaser contact; Pseudoregalia does now.
CI run 35802463324 (`7190c051`) failed one test on the Windows shipping-target job:
`TestConformanceTheRejectStillArrivesAfterCloseGracefully/quic` (`netx`, untouched that day); it passed
40 of 40 locally and on the nine runs before. Treated as a flake under runner load; the next push's
run is the retest before `release.ps1`. The user: *"if everything passes, make a v1.3.2 release"*.

**The release run itself (35803754908) then failed one different test**, on the Linux `unix-binaries`
job: `TestADeadAdapterSocketFreesTheCoreForTheReconnect` (`core`, the 512-chaser dead-adapter test,
"the core never gave up writing", its 20 s guard). It passed in CI's own `-race` core job the same
evening and 5 of 5 locally, and flaked under a loaded runner once before (2026-09-08, `phase10.md`).
The new `chaser_reset` path is not on it (the test never sends one; `StartChasers` is unchanged). The
failed job was re-run. **Two timing-sensitive tests red in one evening, each on a busy runner:** worth
a look at both guards under load before the next release, not a verdict that either is fine.

## 2026-09-23 — both release-night flakes looked at: one was a real quic defect, one a test watching the wrong end

**`TestConformanceTheRejectStillArrivesAfterCloseGracefully/quic` was a product bug.** `quicconn.Close`
tore the connection down a fixed 250 ms (`closeLinger`) after closing the stream, and CONNECTION_CLOSE
discards unacknowledged data -- so one lost packet whose retransmission backed off past the window lost
the last message for good: the relay's Reject, the core's goodbye. A busy Windows runner dropping
loopback UDP did that; the netsim rig's 1 s blackouts do it on a real connection. New
`TestAWriteBeforeCloseSurvivesABlackout` (a UDP proxy blacks out server-to-client for 2 s) failed 3 of 3
before. Fix: the linger now ends at the PEER's close (its transport reads our FIN and closes) or at a 5 s
bound; quic-go v0.62 has no public "stream data acknowledged" signal, read in its `send_stream.go`. 5 of 5
after. Cost: a peer that never answers holds a closed quic connection for 5 s instead of 250 ms.

**`TestADeadAdapterSocketFreesTheCoreForTheReconnect`: the core had done its part.** The failing log
shows the core's write failing and the socket closed 1 s in; the test waited instead for fake adapter A
to see a non-timeout write error, which it did not for the remaining 19 s on that Linux runner (why
is unknown, and I had no Linux here to find out). The test now also watches the core: it dials B the
moment the attached socket reports `IsClosed`, the exact closed-but-attached window the original bug
lived in. With the fix disabled it still fails 6 of 10; with it, 50 of 50 and 20 of 20 under `-race`.
Both gotests scripts green, `./netx/... -count=10` green. CI (Linux) is the real retest.

## 2026-09-27 — status.md's PINNED items: a priority that cannot age out

The build-paths item (strip the paths and the username out of the four shipped DLLs) was on `hold to 2026-09-25`
and passed that date undone, noticed only at a re-check on 2026-09-27. The user asked for it as priority 1 that
"can't expire". `preflight.ps1`'s status section now skips the age check for an item carrying `PINNED` (matched case
sensitively, as a word, so an ordinary "pinned" doesn't exempt anything); the length limit still applies, and the
pass line counts the pinned items. status.md's header states the rule next to `hold to <date>`; the item sits first
under "Open now". Unpinning is the user's call.

## 2026-09-30 — the rule files cut to rules, and five rules taken from bug_fables_ap (A1)

A read-only comparison with bug_fables_ap (started 2026-09-24 from this repo's `CLAUDE.md`) found its
rules, comments and docs leaner and more current. The user approved a plan in seven steps (A1–A7:
rules, gates, pinned builds, docs, lean comments, copied code, a capability list); this is A1. The
plan's counts were re-checked against the tree first: unchanged since the audit (no commits after
2026-09-29), with small method differences only (a 0x03005d8c literal count of 7 where the plan said
6; 64 `scriptDir()` definitions where it said 63; the TEVI stack at 564 lines, below the 622–639 range).

Added to the root: comments are lean; commit subjects imperative, 72 characters at most, no
attribution, `Seen:` for what the user saw; a step's doc and **Status:** in the same commit or
`docs: no process change`; never call another project bad in the repo; a fact about another project
is read (license first) or asked. The `code-map.md` and `capabilities.md` rules land with those files
(A4, A7), so no rule points at a file that does not exist yet. The nested files lost their stories
(now `pitfalls/by-lesson.md`, "The stories behind the rule files") and the root its dated reasons
(`claude-md-cap.md`, the eighth case). The "never restate" line kept once; hot reload, the 1:1 bar
and log cost one home each; all-caps written as plain words or bold. Stacks 622–639 → 430–495 lines.
`_template/README.md` in the same pass: diagnostics record findings in `FLAGS.md`, not a comment; a
bandage's comment is one line; the out-of-process question points at `adapters/CLAUDE.md`. Preflight
clean; a mechanical check of every old bold span against the new files found one dropped rule
("ask what else the state owns"), restored.

## 2026-09-30 — A2.1: a commit-msg hook, ported from bug_fables_ap

`.githooks/commit-msg` (with `python.sh`, both from bug_fables_ap) refuses a subject over 72
characters (counted in characters), `(the user` in the subject, gate files (hooks, workflows, `.claude/`,
preflight and its harness, the two maps) staged with code, and code under a path in the new
`dev-scripts/doc-map.txt` staged without one of its docs, unless the body carries
`docs: no process change`. The map is the user's pick, as drafted: each adapter → its README; the Go
side → any file in `docs/`, `contract.md`, `adr/` or `testing.md` (it lists every fuzz target; the user widened
this line before the commit); `autoplay/` → its README;
`dev-scripts/` → its README. Markdown and `probes/` never count. Exercised in a scratch clone: 73
characters refused and 72 passed (72 é passed too), attribution refused, gate plus code refused, TEVI and
core changes without a doc refused, and passing with the doc, an ADR or the escape line; a probe-only
and a markdown-only commit passed. Both hooks now carry the executable bit, which a Linux clone needs.

## 2026-09-30 — A2.2: a pre-push hook, and a harness defect it found

`.githooks/pre-push` makes a detached worktree of each pushed tip and runs `preflight.ps1 -TreeOnly` there,
so the pushed commit is checked rather than the working copy; when the push changes `preflight.ps1`, its
harness or `phase-map.txt`, it also runs `negative-test-preflight.ps1` from that worktree in six parallel
shards. Tested three ways: A1's tip was refused for the two defects preflight had found in it (a two-line
status item, two unclaimed phase days); the current tip passed; and a range touching `phase-map.txt` ran the
harness, 58 of 59 fixtures passing. The one failure was the harness's own: `phase-log-behind` plants three
commits in its scratch worktree, and `core.hooksPath` is clone-wide config, so the real pre-commit hook
refused the third and the gate saw two. CI never sets hooksPath, so it only failed locally. Planted
commits now run with hooks pointed at an empty path; the fixture passes. A lesson for the next harness run:
the harness copies the working copy's `preflight.ps1` before every fixture, so editing it mid-run
invalidates every later fixture (24 of 59 errored out that way today, all "gate-lists.txt not found").

## 2026-09-30 — A2.3: one file for the lists the leak and stray gates share

`dev-scripts/gate-lists.txt` now holds the root allowlist, the home and clone patterns, the leak exemptions and the
known leaking binaries (with the rebuild each needs); `.githooks/pre-commit`, `preflight.ps1` and `hygiene.yml`
all read it, where each held its own copy before. The copies had drifted: the hook and `hygiene.yml` also exempted
`CLAUDE.md`, `environment.md` and `pitfalls.md`, preflight did not. The shared list takes preflight's narrower
set, which the tree already passes, so those three files are now scanned everywhere. The binary scan in preflight
gains the two Unix home-directory patterns, which `hygiene.yml` already used. Checked: preflight clean with the same four known
binaries named; the three `hygiene.yml` steps run under bash pass on the tree; in a scratch clone the hook refused
a home path planted in `CLAUDE.md` and a stray root file, and passed an allowlisted root file; a new harness
fixture drops `nuget.config` from the list and the stray gate fails.

## 2026-10-01 — A2.4: the gates' prose cut to one line a section

`dev-scripts/preflight.ps1` went from 3,195 to 2,280 lines: each section now opens with one comment line saying what
it refuses (two only warn, and say so), and about 60 one-line whys stay on code that would otherwise mislead; the
`# ---` separators are gone. `.githooks/pre-commit` went from 221 to 140 lines with a four-line header. Four
subagents drafted a quarter of preflight each in a scratch copy; this session ran every proof. Code unchanged:
preflight's PowerShell parser tokens minus comments are identical (15,678), and the hook's 111 non-comment lines
are identical. History the comments carried went to `pitfalls/by-lesson.md`, "The stories behind the gates", word
for word, only where the repo did not already record it (about 70 were already in the phases, pitfalls,
`claude-md-cap.md` or `doc-history.md`). That section quotes the phrases the durations gate refuses, so their unit
words are written in angle brackets there (`for <months>`) to keep the quotes without tripping the gate.
Preflight is clean.

## 2026-10-01 — A2.5: four new preflight sections, three of them ratchets

Doc coverage: a source file or probe folder with no `code-map.md` row, a shipped config key `docs/config.md` never
names (a hard FAIL: all 77 are named), a build step with no **Status:** line, a Contents list that differs from its
headings (hard, vacuous today: no file has one). Comment traces in code: dated comments, comments naming the user,
review IDs (`PM-4`, `X2-3`, `review H18`, `pass-3`) and `.md` pointers, each on a floor that may only fall.
Workflows pinned: actions on a SHA with a `# vN` comment, top-level `permissions: {}`. Dependencies pinned: exact
NuGet versions, a restore lockfile and `<Deterministic>` per project, a root `global.json`, an exact Go toolchain
line. Floors today: 158 unmapped files and folders, 167 steps without Status, 3,853 dated / 1,234 user / 157
review / 1,777 `.md` comment lines, 32 unpinned actions, 11 workflows without `{}`, 18 build inputs. A4, A5 and A3
bring them to 0, each floor lowered in the same commit, and a section at 0 then stays at 0. Seven new harness
fixtures, one per rule; the commit-msg hook's own header lost its "(the user" wording (the ratchet counted it).

## 2026-10-01 — A2.6: an agent guard, ported from bug_fables_ap

`.claude/hooks/agent-guard.py`, armed by a tracked `.claude/settings.json`, runs before every command, edit and
page fetch Claude Code makes here. It denies `--no-verify` and `commit -n`, any change to `core.hooksPath` other
than arming it, `commit-tree`/`update-ref`, git config set from the environment, and a GitHub read of a project
with no `licensing.md` row (its licence file aside; this project's own owner is listed in `gate-lists.txt`). It
asks before an edit to the gate data (`gate-lists.txt`, `doc-map.txt`, `phase-map.txt`), `docs/capabilities.md` or
`.claude/`, and before a commit while any of those has uncommitted changes. The untracked `settings.local.json` is
unchanged. Seventeen sample events behaved as intended, including a `--no-verify` written inside a heredoc commit
message (allowed: prose runs nothing). `dev-scripts/README.md` now names A2.5's sections too.

## 2026-10-01 — A2's full harness, and A3 begun: pinned, reproducible builds

The full harness on A2's tip (67 fixtures, six shards) was cut off when the session stopped: 64 passed, none
failed, and the three unfinished (`dependency-floating`, `doc-contents-mismatch`, `workflow-action-unpinned`)
passed on a re-run. The cut-off run left four worktrees under the temp folder, removed and pruned by hand.

A3 measured first: each of the TEVI DLL, `main.dll` and `dwmapi.dll` carries exactly one path, its pdb's;
`UE4SS.dll` carries one pdb path plus Rust panic locations (64 into the RE-UE4SS submodule, about 80 into the
cargo registry under the home folder). `BepInEx.Core 5.*` resolves to 5.4.21 in all three BepInEx projects, and
of the two SDKs installed (10.0.302, 10.0.401) the newer builds today. First gate change: `global.json` and
`Directory.Build.props` join the root allowlist, and preflight's built-from check reads a recorded name with a
slash as repo-relative, for build inputs outside the source folder. The seven GitHub Actions the workflows use got
their licensing row (all MIT, each `LICENSE` read 2026-10-01) before their docs or tags were read.

A3, the C# half. A ratchet below its floor now warns rather than fails: the floor sits in `preflight.ps1`, a gate
file, and `commit-msg` keeps gate changes out of code commits, so a code commit that lowers a count could never also
lower its floor. MonoMod's `21.12.13.1` joined the public-IP gate's allowlist (the lockfiles carry it). Then the
build inputs: `global.json` (SDK 10.0.401, `latestPatch`, as in bug_fables_ap), a root `Directory.Build.props` (from
bug_fables_ap) that stops MSBuild importing anything from outside the clone, and in all four C# projects
`BepInEx.Core` 5.4.21 (what `5.*` resolved to), `<Deterministic>`, and a locked restore from a committed
`packages.lock.json` (dotnet writes them CRLF; normalised to LF, and TEVI's is `eol=lf` with its other hashed inputs).
`DebugType=none` was ruled out for TEVI: `tevi-hotreload.ps1` pairs the staged DLL with the in-tree pdb, because
ScriptEngine will not load a plugin without matching symbols. Measured instead: with `-p:PathMap=<clone>=/_/` the
DLL's one path becomes `/_/adapters/tevi/MeshGhostTevi/obj/Release/MeshGhostTevi.pdb`, and two clones at different
paths build byte-identical DLLs. `build-tevi.bat` now runs `build-tevi.ps1`, which builds HEAD that way, refuses
unless the two DLLs match and hold no local path, stages clone A's DLL, copies its DLL and pdb into the in-tree
`bin\Release` for the dev loop, and records every build input's hash (from the clone, in committed form) plus the
SDK in `built-from.txt`. The TEVI bridge fuzz harness passes on the locked restore.
`build-tevi.bat` on HEAD `697da9b4`: two clean clones, byte-identical (`1106c1539e4a`, SDK 10.0.401), the DLL's only
path `/_/adapters/tevi/MeshGhostTevi/obj/Release/MeshGhostTevi.pdb`; preflight no longer lists it among the known
leaking binaries. Deployed to both TEVI installs with `meshghost.exe` and the shipped `config.json` (each install's
config was an older shipped one with default values and no personal name or room; backed up as
`config.json.pre-2026-10-01`), every file hash-checked. Not yet seen on screen.
Then the gates caught up: `tevi.yml` installs the SDK from `global.json` (`setup-dotnet`'s `global-json-file`, read
from its README), `release.yml`'s TEVI staleness step also hashes `packages.lock.json`, `global.json`,
`Directory.Build.props` and `nuget.config` (simulated locally: passes on the tree, and refused a one-byte change to
`global.json`), and the floors fell to 3,852 dated / 1,233 user / 1,774 `.md` comment lines and 2 build inputs
(the two `go.mod` toolchain lines).

A3, the workflows: every action pinned to a full commit SHA with its release in a `# vN.N.N` comment (each tag
resolved through the API: checkout v7.0.1, setup-go v7.0.0, setup-dotnet v5.4.0, upload-artifact v7.0.1,
download-artifact v8.0.1; action-gh-release was already on v3.0.3's commit), every workflow at top-level
`permissions: {}` with `contents: read` per job, and `setup-go` reading the toolchain from `go.mod` (its README:
the `toolchain` directive wins when present). The release gains a `preflight` job (`-TreeOnly`, full history) that
packaging waits on, and an `actions/attest` step (v4.2.2; `attest-build-provenance`'s own README now points new
setups there, so it got a licensing row too) that signs provenance for both `.exe` files and all three release
archives, in the one job that also holds `id-token`, `attestations` and `artifact-metadata` write. All eleven
workflows parse. A bug in A2.5's pinning check surfaced on the first real pins: a second `-notmatch` overwrote
`$Matches`, so every SHA-pinned line counted as unpinned (its fixture planted a tag, which took the other
branch). Fixed with the regex's own groups, and a new fixture plants a SHA with no version comment. The pinning
and dependency ratchets are at 0, so any new unpinned action, open permission or floating input now fails.

A3, the C++ side. Microsoft documents `/PDBALTPATH` (the binary records the given name instead of the pdb's path)
and no deterministic-output option for `cl` or `link`; `/Brepro` is in neither the docs nor either tool's `/?`, so
it was not used, and A5's code-unchanged proof for C++ falls back to tokens plus a clean build, as the plan allows.
`%_PDB%` cannot pass through CMake's Visual Studio generator (it doubles every `%`, and the DLL recorded
`%%%main.pdb%%%`), so the option is `/PDBALTPATH:$<TARGET_PDB_FILE_NAME:...>`: on `main.dll` in `Mod/CMakeLists.txt`,
and on the submodule's `UE4SS` and `proxy` (dwmapi) targets from our top-level `CMakeLists.txt`, without touching the
submodule. The Rust part keeps source paths in its panic messages; Corrosion passes the build's `RUSTFLAGS` through
(read in its `Corrosion.cmake`), and `rustc --help -v` documents `--remap-path-prefix`, so `build-pseudoregalia.bat`
maps the clone to `/_` and the cargo home to `/cargo` (refusing a path with a space, which `RUSTFLAGS` cannot carry)
and now also builds the `proxy` target. A full rebuild (76 crates) and `stage-ue4ss-runtime.bat`: all three DLLs
hold no local path, the submodule pin is unchanged, and preflight reports no tracked binary with a username or
clone path. Deployed to both Pseudoregalia installs with `meshghost.exe` and the shipped config (backed up as
`config.json.pre-2026-10-01`; the overwrite reset the Steam install's chaser count 5 / delay 5s / spacing 5s to the
shipped 1 / 3s / 2s, and dropped three `ghost_range` keys from both). Not yet seen on screen.
With all four binaries clean, the known-leaks list had nothing left to excuse: `[known-binary-leaks]` is gone from
`gate-lists.txt`, and so is the code that read it in the pre-commit hook, preflight and `hygiene.yml`, so any home or
clone path in any tracked binary now fails everywhere. The risk entry that sized this work said to delete itself at
this point, and was. status.md's pinned item now waits only on the on-screen check.
Open at the pause: the full harness on the workflow-pinning tip (`0c9a6c31`) failed one fixture,
`action-version-split`: "GitHub Action versions agree across workflows" reads each action's version from an `@vN`
tag, and every action is now on a SHA with its version in a `# vN.N.N` comment, so the check sees no versions and
passes anything. Fix first next session: read the version from that comment (and keep the fixture), then re-run
the full harness. Everything else in A3 is committed; the two games still need their on-screen check.

## 2026-10-01 (later) — the action-versions check reads SHA pins, and the full harness is green

"GitHub Action versions agree across workflows" matched only `@vN` tags, so after the pinning commit it saw no
versions at all. It now keys each `uses:` line on the SHA plus its `# vN.N.N` comment (or the tag, if an action is
still unpinned), skips commented-out lines, and so also refuses two workflows on the same release at different
commits. The `action-version-split` fixture plants a SHA pin at an older release; the old regex does not match that
line, so the fixture fails without the fix. The full harness on `402e648a`, six shards: 68 of 68 fixtures saw their
planted violation (66 FAIL, 2 WARN), and no worktree was left behind.

## 2026-10-01 (later) — A4 begun: a code map, and the root README checked

`agent_docs/code-map.md` now has a row for every file the doc-coverage section counts: 150 source files (Go,
adapters, autoplay, the agent guard) and 9 probe folders, each one sentence on what the file does plus links to the
docs behind it. Four subagents drafted a quarter each from the code, not the comments; this session checked the
riskier claims against the code (the trust-on-first-use mismatch path in `knownrelays.go`, the try/catch walls in
TEVI's `Plugin.cs`) and preflight checked every link and anchor. Unmapped files: 158 → 0. The `CLAUDE.md` rule
lands with it, folded into the same-commit docs bullet so the file stays at 195 lines: a file's row is read before
changing it and updated with it. `_template/README.md` now says how a build step's **Status:** line is written.
The root README said a ghost is cosmetic in every shipped game; the Pokémon mods honour `ghost_collision: enabled`
and Pseudoregalia's chasers honour `contact`, so it now says "by default".

Found on the way, for A5 (stale code comments, the code is right): Crystal's header says vanilla V1.0 only and
spawned ghosts, where the code also knows V1.1, Archipelago and Speedchoice v8.1 and paints by default;
Pseudoregalia's `BridgeClient.hpp` says a silent core counts as accepting, where the `.cpp` accepts only
`bridge_ready`; its `CoreLauncher.hpp` names the mod folder in the config search, where the `.cpp` reads only the
game's root. For a doc pass: the autoplay README's tools table lacks `clear_obstacle` and `search`, and
`docs/networking.md` § 7 calls the relay's flood cap a tumbling window where `relay.go` runs a leaky bucket.
