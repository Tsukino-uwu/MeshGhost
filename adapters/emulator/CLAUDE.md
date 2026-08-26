# Emulator adapters — host rules

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**Loaded automatically** the first time this session reads or edits anything under
`adapters/emulator/`. You do not have to go and find it. Everything here applies to every adapter
whose game runs inside an emulator; per-game facts live in each adapter's own `documentation.md`,
`FLAGS.md` and `BANDAGES.md`.

**Capped at 200 lines, for the reason the root `CLAUDE.md` is capped** — this file loads without
being asked, so it spends the same instruction budget, and an uncapped auto-loading file
recreates the problem the cap exists to prevent. `agent_docs/claude-md-cap.md` has the argument.
Before adding: what comes out to make room?

**This file never restates the root `CLAUDE.md` or `../CLAUDE.md`.** A rule with two homes drifts.

## How this file is split, and why

Every adapter under here today is BizHawk (Crystal, Emerald), so BizHawk rules and
emulator-in-general rules currently live in one file. They are kept under **two separate
headings** so the difference stays visible:

- **Part 1** is true of any emulator host — it would survive a Dolphin, mGBA or DuckStation
  adapter unchanged.
- **Part 2** is BizHawk's own API, and the GBA/GB hardware the two current games run on. A
  Dolphin adapter would need its own equivalents, not these.

**That division is the cut line.** Per `../CLAUDE.md`'s create-a-level-on-demand rule, a second
emulator is what creates `emulator/bizhawk/` — and when it does, Part 2 is what moves down into it
while Part 1 stays here. Sorting it now means that move is a cut, not a re-derivation.

---

## Part 1 — true of any emulator host

### An emulator adapter is script-only — never patch the ROM

**Start from this, before the first file exists.** An emulator adapter reads and writes the running
machine's RAM from the emulator's own scripting front end, and it never ships, generates or requires
a patched ROM. The reason is compatibility, not purity: MeshGhost works on Archipelago seeds and
randomizers **because it never touches the ROM** — whatever patch the player is already running
stays intact underneath, and MeshGhost layers on top. Our own patch would have to be reconciled
with theirs, which is not something a player can do, so a patch trades a feature that works on
every ROM for one that works on one ROM.

What this rules out is real and worth knowing up front: any technique needing code *inside* the
game — a custom interrupt handler, new code at a ROM address, a hooked routine that must return a
value. The way around it is nearly always the front end reaching the same place from outside: an
execute hook on an engine routine is a mid-frame wakeup with no patch at all. Full reasoning and
what it costs: the 2026-08-21 ADR in `agent_docs/architecture.md`.

### A per-second log line is a per-second stall — and it ships

**A rule the new adapter starts with, because both existing Lua adapters got it wrong.** Writing to
the log is not free: one `console.log` plus one `flush` was measured at **63–83ms** on 2026-08-21 —
four to five frames — on the emulator's own thread. Crystal's drawn tier wrote one summary line a
second whenever peers were present, so a shipped session lost that every second, and Emerald
wrapped the global `console.log` so every console line flushed to disk too.

So: **open the log buffered (`setvbuf("full", …)`), never flush per line, flush on a timer, and keep
the front end's own console call for the rare line somebody actually needs to see.**
[probes.md](../_template/probes.md) has said "buffer, and flush in batches" since the drawn tier was
built — what failed was reading it as advice about *probes*. It is not. It is about anything that
runs every frame, shipped code first.

**And when anyone says "choppy", measure PACING, not rate.** An average cannot see a hitch: ten
frames lost inside one second still reads as 58fps, which is why this cost a whole session before it
was found. `dev-scripts/bizhawk-hitch-meter.lua` is standing rig for exactly that — game-agnostic,
attach it to any performance question, and it reports frames over 20ms, frames over 33ms and the
worst gap rather than an average that hides all three.

### A memory-write breakpoint is the only instrument that sees BETWEEN frames

A defect that exists at RENDER time but never at the script tick is invisible to every per-frame
probe by construction — struct dumps, sprite-table scans, VRAM-vs-ROM checks and allocation-bitmap
dumps all read clean while the screen shows garbage. The instrument for that gap is a write
breakpoint on the affected range. BizHawk's own API for it is in Part 2; these lessons are not
BizHawk's:

- **Register one address per tile (stride 32), not every byte** — a breakpoint can push the
  emulator core onto a slow path, and sampling catches any multi-byte copy anyway.
- **Budget the event count and stamp the frame number into every line** — the interesting
  window is a handful of frames, and correlating with screenshots requires one shared clock
  across probe lines, log lines and screenshot filenames.
- **A sprite-copy queue that executes at VBlank runs one frame AFTER the request** — so a
  sprite despawned this tick can still write its tiles next frame. Tiles freed at despawn and
  re-claimed in the same tick get the dead sprite's frame stamped over the new owner's load.
  If a despawn frees tile ranges, defer the free by a few frames.

### Lua's 200-local ceiling will stop your adapter loading, silently

**A Lua chunk may declare at most 200 locals in its main body.** Past that the file does not load at
all: BizHawk reports `too many local variables (limit is 200) in main function`, the dev loader
prints one `LOAD FAILED` line, and the adapter is simply absent. Nothing else says so — the game
runs normally with no ghosts, which reads as a networking fault or a dead relay.

**Measured 2026-08-21, and it is not theoretical**: Crystal hit it four times in a single session,
and each time cost a reload cycle to identify. Re-counted 2026-08-25:

| adapter | lines | top-level locals |
|---|---|---|
| Crystal | 7,540 | **197 of 200** (re-measured 2026-08-26) |
| Emerald | 10,936 | **198 of 200** (re-measured 2026-08-26) |

**Crystal is three names from the wall and Emerald is two.** Crystal's row read 188 for one day and was
already stale when it was read: adding two plain constants for a feature stopped the file loading
outright (2026-08-26, the fourth time). **A number nothing re-measures is a number that WAS true**
— so re-measure before planning around the headroom, and expect the answer to be worse. Neither
adapter has solved this, and the constants-onto-tables consolidation
that bought Emerald its last few names is a bandage, not a fix. The fix is modules, each with its
own 200-local budget — `agent_docs/ideas.md`'s deferred-refactor list.

**Measure the headroom, do not count `local` lines.** Lua's limit is on NAMES, so
`local a, b, c` spends three and `grep -c '^local '` undercounts badly. Append N throwaway locals
to a copy and compile it, halving N until it flips:

```sh
C:/msys64/mingw64/bin/luac.exe -p <copy-with-N-extra-locals.lua>
```

Both figures above were confirmed that way — Emerald compiles with 3 added and fails with 4
(2026-08-25), Crystal likewise with 3 and 4 (2026-08-26).

**The modules fix has one trap already paid for twice, and it must be designed around.** A file
loaded with `dofile` sees `debug.getinfo(1,"S").source` as a RELATIVE path, so a shared module that
calls `scriptDir()` itself resolves to `"."` — which passes the absolute-path guard's sibling branch,
skips the pwd fallback, and then fails where it actually matters, because `package.loadlib` resolves
a relative DLL path against BizHawk's process directory and never the working directory. Both
adapters' own `scriptDir()` carries the dated warning (2026-08-18, twice in one day). **So a shared
module never resolves its own directory: the host adapter resolves `SCRIPT_DIR` and passes it in.**

**So group by default, from the first file.** Related constants and state go on one table
(`local oam = {...}`, `local COMPARE = {...}`), not one name each. Field offsets, addresses, tier
state and per-frame scratch are all natural groups. Retrofitting this under pressure — which is how
both existing adapters got their tables — means doing it while chasing a bug, which is the worst
time.

**And when a change to a big adapter mysteriously does nothing, check the loader log for
`LOAD FAILED` before anything else.** It is one line, it scrolls away, and it looks nothing like a
bug in the change you just made.

---

## Part 2 — BizHawk, and the GBA/GB hardware underneath

**This is the half a second emulator would NOT inherit.**

### Don't pay a relaunch per probe revision

`EmuHawk.exe --lua=<script> "<rom>"` attaches a script at launch, but swapping one on a *running*
emulator is a Lua Console GUI action nothing outside the process can drive — so every edit
otherwise costs a full relaunch, and each relaunch interrupts whoever is holding the controller.
`dev-scripts/bizhawk-dev-loader.lua` is attached once and then loads, swaps or drops whatever
script a one-line control file names. Write a probe to its contract — set `MESHGHOST_DEV_TICK`,
no `while true ... emu.frameadvance()` loop of your own, and gate that loop on
`MESHGHOST_DEV_LOADER` if the file should still work opened directly. Details and the confirmed
live behaviour: `agent_docs/environment.md`.

### The write-breakpoint API (Emerald, 2026-08-21)

The instrument Part 1 describes is `event.onmemorywrite` on the affected range: each write event
carries the address and value, and `emu.getregister` the CPU state. On GBA specifically:

- **PC inside the BIOS (0x2A0) means a CpuSet/LZ77 call; LR is ALSO banked to the BIOS there**,
  so registers cannot name the game-side caller. Name the writer by its DATA instead: search the
  ROM for the written values at the observed stride. No ROM match means a RAM source
  (decompressed graphics, heap frame buffers).

### Read the engine's own copy when the register is write-only (Emerald, 2026-08-21)

Several GBA display registers are write-only and return garbage when read — `WIN0H`, `WIN0V`,
`BLDY` among them — while their neighbours (`DISPCNT`, `BLDCNT`, `BLDALPHA`, `WININ`, `WINOUT`)
read fine. A register dump therefore mixes real values with convincing noise, and nothing marks
which is which.

The live value usually exists in RAM anyway, because the engine has to keep its own copy to write
each frame: a per-scanline effect keeps a buffer plus a small descriptor saying which register it
targets and whether it is running. Read those instead. It is also strictly better than the
register would have been — a per-scanline effect has 160 different values and the register only
ever holds the current line's.

**Check a register's read/write status before building an argument on a dump**, and prefer the
engine's own state to a hardware read whenever both exist.
