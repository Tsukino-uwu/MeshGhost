# Probe index — TEMPLATE

<!-- line-cap: 150 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**This is the template. Copy it to `<your-adapter>/probes/README.md`, fix the title, delete
everything above the horizontal rule below.**

**When to create it:** once `probes/` holds more than a couple of scripts, and `preflight.ps1`
fails a probe folder holding more than two that has no index. Every shipped adapter with
probes now have one — Crystal and Emerald in `probes/README.md`, Pseudoregalia in a `PROBES.md` at
its adapter root, because **UE4SS loads a Lua mod from a fixed `<ModName>/Scripts/main.lua`, so
each probe is its own mod directory and there is no `probes/` folder to index from the inside.**
That is a host constraint, not a per-adapter exception: any future UE4SS adapter inherits it.
(This said "Pseudoregalia indexes none of them" until 2026-08-27 — `PROBES.md` closed that on
2026-08-25, and the template may never lag a shipped adapter.)

**Not to be confused with `_template/probes.md`**, which is the *method* — how to build a probe
that answers something, and the ways an instrument lies. That one is read, never copied. This one
is a per-adapter index of what actually exists, and it is copied and filled in.

---

# &lt;Game&gt; probes

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

Every script here is a **development tool**, not part of the shipped adapter. They are kept
because they are the record of *how each fact was established* — the addresses and recipes cited
in `VERIFIED.md` and the phase files were measured by something in this list, and several get
re-run later to ask the same question of a different build.

**Logs are not kept.** Each probe writes a timestamped `.log` beside itself, and `.gitignore`
covers them. Once a run has been read, its conclusion belongs in `VERIFIED.md` — not in a
megabyte of raw log.

**How to run one**: &lt;the host's mechanism — for BizHawk, point `dev-scripts/bizhawk-dev-loader.target`
at it and the loader swaps scripts live with no relaunch; see `agent_docs/environment.md`.&gt;

## Anything here that WRITES must be listed, by name, in this section

**Put this section first, and keep it first even when the list is empty** ("Every probe here is
read-only" is a useful sentence). A folder index that hides a memory-writing tool is the worst
kind of gap: nobody reads a header they did not know existed, and a writing probe left loaded
becomes a suspect in every later bug report (`agent_docs/pitfalls.md`, 2026-08-22).

For each one, say **what it writes and what undoes it** — object RAM that a map load rebuilds is a
very different risk from anything that touches a save. **A probe may cheat; a shipped adapter may
never.** Nothing here writes a save, ever.

## The probes

&lt;Group by what question they answer, not alphabetically. One line each: the name, the question it
answers, and the fact it established if it established one.&gt;
