# How `<game>` works

## Before adding anything to this file

**KEEP THIS SECTION when you copy this file.** It is repeated verbatim at the top of every
adapter's `documentation.md` on purpose — the rule has to be visible at the moment someone is about
to paste something in, not one link away in a file they have not opened. Rule and reasoning:
`adapters/_template/README.md`.

**Explain facts; never reproduce expression.** Measured numbers, timings, field/function/type
*names*, and behaviour described in your own sentences are all fine. Source text in any language,
decompiler or disassembler output, asset content or extracted strings, verbatim reflection or memory
dumps, and data tables copied wholesale are never fine — **regardless of what a licence permits**.

**The test: could someone re-derive this by owning the game and watching it?** If yes, it is a fact
and may be explained; whatever you learned it from only saved you the time, and is not the source of
your right to know it. If the only way to have it is to copy something, it stays out.

This is `CLAUDE.md`'s standing rule — *is this fine sitting in a public repo forever?* — applied to
prose. No, or merely unclear, means out.

---

Copy this file into your adapter folder next to its `README.md`, and fill it in as you learn how
the game does things.

**Anything a real adapter's copy learns — a new rule, a better section shape — comes back here in
the same pass.** `_template/` is the gold standard and is never allowed to lag behind the adapters;
see `README.md`'s standing rule at the top.

Replace the placeholder line below with your own. It is the provenance sentence the standing rule
requires, and the licensing audit greps for it.

> Everything here is measured from a running game on `<date>`. This game has no public source, and
> no decompiled or disassembled material was used in producing it.

**What this file is: how *the game* does things.** Each mechanic — the moves, the effects, the
states — written as what it actually does to the character, which fields carry it, and which
components it moves. The goal is that someone can read "oh, *that's* how X works" without having to
rediscover it by watching pixels.

**Hard rule: nothing here describes an adapter workaround.** No compensations, no "we force this
value back every tick". If a line is only true because of something *your adapter* does, it belongs
in `BANDAGES.md`. This file has to read as a description of the game to someone who has never seen
the adapter's code. (User's rule, 2026-08-16 — the same instinct as the bandage register itself.)

Pointers into the adapter code are fine and useful — *where we read this* — but keep them to one
line each. No code listings: the code is one click away and stays the source of truth.

| File | Answers |
| --- | --- |
| **`documentation.md`** (this) | How does the game do X? |
| `BANDAGES.md` | Where the adapter compensates instead of reproducing the mechanism |
| `agent_docs/verified.md` | Dated evidence behind every claim here |
| A state inventory, *if the game warrants one* | Which state exists, which is synced, how to promote one |

Most adapters have no inventory file — Emerald's addresses and TEVI's class fields live in
`verified.md`. Pseudoregalia has `PLAYER_FIELDS.md` because UE reflection exposes far more than it
syncs. See `README.md`'s folder convention.

Everything in it should be measured from a running game, with each entry saying how confident it
is. Mark inferences as inferences.

## Standing rule: everything in here must be fine on a public repo, forever

This file is **facts observed from a running copy of a game the reader owns** — nothing else. A
rule about content, not a disclaimer at the bottom.

**Allowed**, and the whole point of the file: measured numbers, timings, field and function *names*,
which component moves what, how states relate. Facts are not copyrightable, and short identifiers
carry no copyright of their own.

**Never**, however convenient: game source, decompiled or disassembled output, asset content or
extracted strings, and **verbatim reflection/memory dumps** — a dump is bulk copying of the game's
own data, which a hand-written description of the same mechanism is not. Nothing describing how to
obtain the game or bypass anything.

**The test is the repo-wide one** (`CLAUDE.md`): not "does a licence permit this?" but *"is this
fine sitting in a public repo forever?"* If the answer is no or unclear, it does not go in. If an
entry can only be written by quoting something, it is not an entry.

**Keep a provenance line at the top** saying the contents were measured from a running game and
that no source or decompiled material was used. That sentence is the difference between notes from
observation and something a reader might assume came from leaked source. The standing assessment
behind this rule is recorded in `agent_docs/licensing.md`.

---

## Suggested shape

**Start with the character's anatomy.** Whatever the game's equivalent is of "there is a collision
volume here and a visible body there, and they move independently" — that split explains most
mechanics that follow, and getting it wrong is where the confusing bugs come from.

**Then a state-fields table.** The handful of enums or flags that carry most of the behaviour, with
the values actually observed. Say plainly that the enums have more values than you have seen.

**Then one section per mechanic**, each opening with the same three lines:

> **Fields** the values it sets
> **Components** what it physically moves
> **We read it at** `File.ext:123`

followed by what the game does, how to detect it reliably, and what is known to be a *wrong* way to
detect it. Negative results are worth as much as positive ones here — an enum that looks like the
right signal but also fires on something else will otherwise be rediscovered by the next person.

**Link the evidence, don't paste it.** Say what you measured and how confident you are, then point
at the dated entry in `agent_docs/verified.md`. Sample counts, capture logs and failed-attempt
trails belong there, not here — the same discipline the `README.md` build-story steps follow. If
you catch yourself writing "so we…", stop: that sentence belongs in `BANDAGES.md` or the
`README.md`.

**Finish with known unknowns.** Searches that came up empty, so nobody repeats them, and inferences
that have never been confirmed. When one gets answered, **strike it through and point at the
section that answered it** rather than deleting the line — the list is then also a record of which
questions turned out to be answerable, which is what makes the remaining ones worth trusting. (Same
reason `BANDAGES.md` keeps a removed compensation as a struck-through entry.)

## Why it earns its place

Adapters are built by measuring a game nobody has source for, and that knowledge otherwise lives
scattered across code comments, a phase file, and one very long `verified.md`. This is the file that
answers "how does this game actually work" in one read — which is also the file that tells you
whether a new feature is even possible before you start building it.
