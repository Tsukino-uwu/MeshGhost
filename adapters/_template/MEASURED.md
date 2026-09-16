# Measured — TEMPLATE

**This is the template. Copy it to `<your-adapter>/MEASURED.md`, fix the title and the relative link
depths, delete everything above the horizontal rule below.** Neither the copy nor this template
carries a line cap: caps apply only to files that load as instructions
(`agent_docs/claude-md-cap.md`), and a record grows with what it holds.

**When to create it:** with the adapter, like `VERIFIED.md` and `UNVERIFIED.md`;
`dev-scripts/preflight.ps1` fails an adapter without one. The file exists since 2026-09-16, the
user's call: *"verified/unverified should just be non code related things that i can verify like
'Jump is not working' or 'fly is working properly now'"*, and a MEASURED.md *"for you to put all
these code related things in as they should always be measured/confirmed when put in there to begin
with"*. Before it, byte-level facts sat in `UNVERIFIED.md` waiting for a confirmation the user can
never give, and the queue stopped being a queue.

**Link depths differ by where the adapter sits** — four levels down for an emulator game
(`adapters/emulator/pokemon/<game>/`), two for everything else.

---

# Measured — &lt;Game Name&gt;

**What this is.** The code-level facts about this game that the agent MEASURED: addresses, what a
field or byte reads in which state, encodings, timings, costs, which routine fires when. Each one is
settled by its own evidence, not by the user watching, because nobody can watch a byte.

**The three records, and which one a thing belongs in:**

| Record | Holds | Who settles it |
| --- | --- | --- |
| [`VERIFIED.md`](VERIFIED.md) | what the game visibly does with the adapter: "jumping works", "the ghost's fly looks right" | the user, on screen |
| [`UNVERIFIED.md`](UNVERIFIED.md) | the same kind of claim, built and waiting for the user's eyes | the user, on screen |
| **MEASURED.md** (this) | the bytes, addresses and timings underneath | the agent's own measurement |

When a measurement has a visible consequence, the bytes go here and the visible part goes to
`UNVERIFIED.md` for the user.

**The rule for an entry** (`CLAUDE.md`, MEASURED OR OBSERVED ONLY; `agent_docs/licensing.md`):

- **It names its evidence and its date**: the probe or test, the log or capture, what was done in the
  game while it ran. "Measured" with no instrument named is not an entry.
- **It is true as of that date, on that build.** Say which ROM, version or install; a fact from one
  build is not a fact about another.
- **A source is never the evidence.** A decompilation, wiki, symbol file, dump or other project says
  where to look. A `.sym` from a build we hashed identical to the ROM proves an ADDRESS, never what
  the byte means.
- **Superseding is a new dated entry** that says what it replaces; the old one gets a one-line
  pointer, not a rewrite. A measurement that turns out wrong is itself worth keeping.
- **The instrument is the first suspect** (`agent_docs/checklists/before-trusting-a-reading.md`):
  write down what it could NOT see, so the next reader knows the entry's edges.

**Keep the `## Not measured yet` section LAST.** It holds what a source says and nobody has measured,
each item written as a question with how to settle it. Nothing in it is a fact, and nothing in it is
cited as one anywhere else. Measuring an item moves it up into the measured entries; the pattern is
`documentation.md`'s "what we know, plus a plainly marked list of what we know we do not know".

Sibling records: list the other adapters' `MEASURED.md` here.

**Keep the `## Index` section below, one line per `###` entry in either section.** This file only
grows, like `VERIFIED.md`, so the index is what keeps it findable.

## Index

&lt;One line per entry, the heading's text, under Measured and Not measured yet.&gt;

## Measured

&lt;Entries go here, newest at the end. One `###` heading per subject with its date, e.g.
`### Text printing and the character encoding (2026-09-16)`: the facts, then the evidence.&gt;

## Not measured yet

&lt;Questions from a source, one `###` heading each: what it claims, what IS ours so far, and how to
settle it.&gt;
