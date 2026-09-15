---

<!-- line-cap: 120 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

name: adversarial-review
description: Read before running an adversarial review pass on MeshGhost — a fan-out of read-only attacker agents against the relay, the client, the bridge and the adapters. Carries the four reader modes and their order, the decomposition rule, the prohibition block, the claim record and the verification tiers, and says which parts must be regenerated rather than copied. Use when asked to review the tree for what a bad actor could do, when planning a security pass, or when picking up a pass somebody else started.
---

# Running an adversarial review

## Four reader modes, one job each; the external one opens the pass

- **External** — a fresh clone in a directory outside the project, so no project `CLAUDE.md`, memory
  or `agent_docs/` loads; a session given only the code and the public `docs/`; one real person's
  vague question, *"is it safe to host this on a server?"* or *"any concerns running this on my PC?"*,
  host and player alternating. Pass 4 (2026-09-15) was the host's, run by the asker on their own
  machine. **The only unbiased critic**: it lacks the repo's model, not merely its findings.
- **In-repo blind** — the strict cells below. Hunts; inherits the repo's vocabulary, so say so.
- **Some guidance** — pointed at `contract.md`, `architecture.md` and the census, never the security
  docs. The default setting for a strict cell.
- **Everything** — handed `docs/security.md`'s "what's already true" section, to falsify each claim
  against the code. Never hunts: a guided hunter reports your own model back as corroboration.

**Order: the external question first, the strict cells second**, taking what the outsider found to
T2/T3 and covering what it could not reach. "Other issues" is allowed in the question, but a finding
still names a damage — time, data, money, or a false belief about what is running. Vague plus
everything is forbidden. The seed list scores modes: run one cell two ways and keep what scores.

## Before any strict brief: the entry-point census

**List every entry point that parses bytes from a stranger, and name which cell owns each one**, in
writing, first. Walking the components instead left the replay-clip position un-owned through four
positions and fifteen cells on pass 3 — clips are shared between players, the docs suggest zipping
one to send, and everything in `replay/active/` is parsed the moment a game launches. An un-owned
entry point is the cheapest serious finding available, and invisible to every cell-bound agent.

## Decompose by (position × class), never by component

A component split gives one agent `protocol/` and another `relay/`; the first sees a correct
validator, the second a correct marshal, and neither owns the line between them where the value
changes size. **Position** frames the cell — what the attacker controls, what counts as a win, what
is already accepted. **Class** splits the reading inside it.

Derive the positions from who can reach the tree *this pass*, ranked by what each costs the victim;
derive the cells from what components exist and what changed since the last pass. **This skill
carries neither the cell list nor an agent count**: a baked-in list is a list nobody re-derives.
Double-cover the single highest-cost item with two cells reached by different routes.

## The ten prohibitions, verbatim in every strict brief

1. Read-only. No files, no builds that write into the repo.
2. **A claim without `file:line` is not a claim.**
3. Do not report anything on the attached exclusion list.
4. Do not report a peer making their **own** ghost look wrong, move oddly, or appear strangely.
5. Name the victim and the damage in the same sentence as the mechanism. "Unvalidated" is not a
   finding; "unvalidated, therefore X happens to Y" is.
6. **State the bounding negative** — what your finding does *not* do.
7. Rank your own output; say which claims you would bet on.
8. Do not propose a fix requiring the Go side to know what a game value **means**
   (`internal/gameblind` fails the build for it).
9. Do not go looking for `docs/security.md`, `agent_docs/security-design.md`, `agent_docs/risks.md`,
   the working findings file or the review ADRs. You are the second reader *because* you lack the
   author's model.
10. Stay in your cell; one line for anything outside it.

Ask each cell to finish by naming **what it covered and found clean** — without that you cannot
tell coverage from silence.

## Seeds stay private; exclusions go out, regenerated every time

Your own candidate findings are **not** given to the agents: echo reads as corroboration. Afterwards
the seed list is a coverage key (a seed its home cell missed indicts the *brief*), a quality prior
per agent, and a fallback queue: seeds nobody found are filed as `seed, not independently found`.

**Regenerate the exclusion list from `docs/security.md`'s known gaps plus `agent_docs/risks.md`,
every pass; never copy one off a page, including this one.** Both files move, and a stale list tells
every agent not to report something since re-broken. It names **accepted risks only, never fixed
defects**: a fixed defect is not in the code the agent reads, and listing it would leak your model.

## Tiers: nothing is filed below T2, nothing is "fixed" below T3

- **T0 CLAIM** — rejected unopened without `file:line`, a named victim and damage.
- **T1 READ** — open the cited lines yourself. Kill reasons in the order they fire: **the guard is
  three lines down** (the commonest by far); the line does not say what the claim says; accepted risk
  in other words; the sender's own ghost; wrong position. For a hostile relay, confidentiality is
  out of scope while integrity and availability are in.
- **T2 REPRODUCE** — promotion to *finding*. Go side: a `_test.go` driving the real component that
  fails on master, mandatory. Adapter side, in order: extend that adapter's CI harness to reach the
  **dispatch** layer; or extract a pure helper and test that, the shape the fix wants anyway; or a
  read you performed plus sibling parity — enough to file and fix, never enough to call verified.
- **T3 FIX AND PROVE** — the test passes, **and you re-run it with the fix reverted and record that
  it fails**. `run-gotests.bat` green; `run-gotests-race.bat` for concurrency. Say plainly when a test
  cannot be shown failing because it references identifiers the fix introduces — a real limitation.
- **T4 SEEN** — adapter-side, the user's alone, on screen in a running game.
- **DECISION** — not a tier. A claim that cannot be fixed unilaterally gets options and costs, and waits.

## Standing lessons, which are what the cells are actually hunting

- **A read site is not a sink.** "This value is read here" is not a finding; where it becomes an
  index, an address, a size, a key that grows or an allocation, is.
- **The guard is three lines down.** Check before filing; this kills more claims than anything else.
- **A blind instrument is the real defect.** A target that truncates its own input to the limit whose
  overflow is the bug runs green forever. Audit the instruments as their own cell.
- **A bound is measured the way the party that must satisfy it measures it**: a forwarder measures
  what it will write, a terminal receiver what it was handed, a memory budget memory, not a sample count.
- **A guard its sibling has and this one does not** is the highest-yield grep. Roster the guards,
  then find same-shaped sites that skip them: send vs receive, wire vs file, one plane vs its twin,
  a field vs the same field in its delta type, admission vs teardown.
- **An eviction ordered by age is ordered by whatever a third party controls.**

`agent_docs/pitfalls/` has these with their symptoms and fixes; `agent_docs/adr/` has the decisions.

**Legal fixes** are `CLAUDE.md`'s: game-blind (`internal/gameblind`), who verifies what, the `_template`
back-port, caps sized from a real game value. An adapter fix waits in its `UNVERIFIED.md` until the user sees it.

## The cap is a real constraint, so order the launch

Pass 3 lost seven of seventeen cells mid-flight and the survivors were whichever finished first.
**Launch in priority order and write that order down**, so an interrupted pass loses its cheapest
cells rather than its best. Record which cells never ran: "unknown" is not "clean".
