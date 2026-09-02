# Verified facts — TEMPLATE

**This is the template. Copy it to `<your-adapter>/VERIFIED.md`, fix the title and the relative
link depths, delete this paragraph and everything above the horizontal rule below.** Neither the
copy nor this template carries a line cap: caps apply only to files that load as instructions
(`agent_docs/claude-md-cap.md`), and a record grows with what it holds.

**Why a template exists at all.** `_template/README.md`'s folder-convention table has mandated a
`VERIFIED.md` in every adapter since it was written, and said "no template — see any shipped
adapter's". That is how four copies of the same ~30-line preamble came to exist and start
drifting. Written 2026-08-25 with the drift folded back in.

**Link depths differ by where the adapter sits.** An emulator game is four levels down
(`adapters/emulator/pokemon/<game>/`) and everything else is two (`adapters/<game>/`). Copy the
depth from the nearest shipped adapter at your own level rather than counting, and let
`dev-scripts/preflight.ps1`'s markdown-link check confirm it.

---

# Verified facts — &lt;Game Name&gt;

Facts about this adapter and this game, **confirmed by watching a running game**.

**The gate is the strict one.** Nothing adapter- or game-side on the BASE/VANILLA game goes in
here until **the user has confirmed it on screen** — no probe log, console read or screenshot of
yours substitutes, and neither does a clean test run. Measurements that are not yet confirmed live
in [`UNVERIFIED.md`](UNVERIFIED.md). A patched ROM (Archipelago and similar) is the agent's to
confirm visually; say so in the entry. The full rule is in the root `CLAUDE.md`.

**Append-only.** Do not rewrite or delete an entry's original observation. Adding later
live-confirmed detail to an existing entry is fine; superseding one is a NEW entry plus an
annotation, never an edit to the old. This is also why the file declares no line cap: capping a
record would mean deleting evidence in order to add evidence.

**A fact confirmed against one build/ROM/version is not automatically true of another.** State the
scope in `Notes` whenever it plausibly matters.

**The entry format, and the two evidence tracks**, are in `agent_docs/verified.md`, which remains
the home for Go-side and cross-game entries and carries the index to every adapter's file.

**Keep the `## Index` section below, and add one line to it per entry.** `dev-scripts/preflight.ps1`
fails an entry that is not listed. It exists because this file only ever grows and cannot be
capped -- capping a record would mean deleting evidence in order to add evidence -- so the index is
what keeps it findable. Reading the index costs ~150 lines where reading Emerald's record costs
3,685.

Sibling registers: list the other adapters' `VERIFIED.md` here, so any one of them leads to the
rest.

## Index — every entry in this file

&lt;One line per entry, title only. Entries at both `##` and `###` are indexed; the levels are
historical and are NOT normalised, because changing an entry's heading rewrites the record.&gt;

## Confirmed facts

&lt;Entries go here, newest at the end. One `##` heading each: what was confirmed, and the date.&gt;
