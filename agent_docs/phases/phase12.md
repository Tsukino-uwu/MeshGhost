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
