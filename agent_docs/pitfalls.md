# Adapter pitfalls — how a lesson stops being paid for twice

This is the front door to the project's lessons: what went wrong while building an adapter, how it
was tracked down, and what fixed it. The record is under [pitfalls/](pitfalls/), the index of every
lesson is [pitfalls/INDEX.md](pitfalls/INDEX.md), and **the reading path is
[checklists/](checklists/)** — one page per moment, read before doing the thing.

**Reworked 2026-09-02, because the record was not doing its job.** 14 of 226 titles admitted to
being a repeat ("third time", "four times in one session"). Every lesson that STOPPED recurring had
been given a mechanical check; every lesson that recurred three times existed only as a title in a
chronological index nobody read at the moment it applied. So every lesson now ends in exactly one
of three places, and the reader meets it where the mistake is made rather than in a pile sorted by
when it was learned. Evidence and the user's framing: `doc-history.md`, 2026-09-02.

## Scope boundary

- `agent_docs/verified.md` and each adapter's `VERIFIED.md` hold confirmed runtime facts, human-gated.
  Entries here link to those by heading rather than restating the evidence.
- `agent_docs/risks.md` holds open and closed design risks. This holds closed incidents: symptom →
  cause → fix.
- `agent_docs/phases/*.md` are the run-by-run log per phase. This pulls the transferable lesson out.

## Every lesson ends in one of three places

| Outcome | Meaning | Where it lives |
|---|---|---|
| **CHECK** | a preflight section, hook or test makes the repeat impossible | `dev-scripts/preflight.ps1`, `.githooks/pre-commit`, a Go test |
| **RULE** | one imperative line placed where the mistake is made | a [checklist page](checklists/) by default; a nested `CLAUDE.md` only if it must load unasked |
| **RECORD** | a story with no transferable rule yet | the record only — **a repeat of a RECORD lesson forces promotion** |

**Prefer CHECK over RULE, always.** The rule files are at their stack budget (`claude-md-cap.md`),
and a check does not need to be read to work. When a lesson can only be a rule, it goes on a
checklist page, not in a `CLAUDE.md`, unless it must be in front of the agent before it has done
anything at all.

## The checklists — reach for the page for what you are about to do

| About to… | Read |
|---|---|
| write or arm a probe | [before-a-probe.md](checklists/before-a-probe.md) |
| believe a log, a counter, a trace, a screenshot | [before-trusting-a-reading.md](checklists/before-trusting-a-reading.md) |
| call something fixed, or blame a change for a regression | [before-declaring-a-fix.md](checklists/before-declaring-a-fix.md) |
| edit a file with `python`, `perl`, `sed` or a heredoc | [before-a-scripted-edit.md](checklists/before-a-scripted-edit.md) |
| copy any game state onto a ghost | [before-mirroring-state.md](checklists/before-mirroring-state.md) |
| spawn or touch an actor in Unreal | [before-spawning-in-unreal.md](checklists/before-spawning-in-unreal.md) |
| touch a BizHawk Lua adapter or probe | [before-touching-lua.md](checklists/before-touching-lua.md) |
| change the core, relay, bridge, or a handshake | [before-a-network-change.md](checklists/before-a-network-change.md) |

Each page opens with the three that cost the most, then lists every lesson filed to it, one line
each, linking to the record. `preflight.ps1` holds every page to one line per entry, so a page
grows by lessons, never by verbosity.

## The record

| File | What is in it | Reach for it when |
|---|---|---|
| [pitfalls/INDEX.md](pitfalls/INDEX.md) | every lesson, one tagged line each | you know the lesson and want its outcome or its record |
| [pitfalls/method.md](pitfalls/method.md) | diagnostic methodology, failure signatures, instruments that lie | an instrument disagrees with the screen |
| [pitfalls/by-host.md](pitfalls/by-host.md) | BizHawk Lua, UE4SS, Unity, memory probing, overlay rendering, grouped | you know which subsystem you are touching |
| [pitfalls/by-lesson.md](pitfalls/by-lesson.md) | the chronological record, and the largest | you want the full story behind a line |

Nothing is filed per game, deliberately: a lesson found in Emerald has to be findable while working
on Crystal. The record files stay chronological and are never split; `by-lesson.md` is where new
entries go.

## Filing a new lesson — all of it, in the same commit

1. **The narrative** goes to the end of `pitfalls/by-lesson.md`: symptom, how it was diagnosed,
   cause, fix, and what to reach for first next time.
2. **One tagged line** goes to `pitfalls/INDEX.md` under "By lesson": the title, then
   `[CHECK: <section/test>]`, `[RULE: <file>]` or `[RECORD]`. Preflight fails a heading that is not
   indexed and a line that carries no tag.
3. **Unless it is RECORD, the outcome ships with it**: a preflight section (negative-tested against
   a planted defect first), or one line on the right checklist page. A rule that gains a second
   home is added to preflight's canonical-source register in the same commit.
4. **If the lesson is a repeat of a RECORD line, it is no longer RECORD.** Promote it: the repeat is
   the proof it was transferable.

A new way to MEASURE goes to `adapters/_template/probes.md`; a rule a new adapter should start with
goes to `adapters/_template/README.md`; a host rule that must load unasked goes to that host's
`CLAUDE.md`, displacing a line whose lesson is now a CHECK.
