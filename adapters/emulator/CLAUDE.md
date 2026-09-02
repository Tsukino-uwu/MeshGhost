# Emulator adapters — host rules

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**Loaded automatically** the first time this session reads or edits anything under
`adapters/emulator/`. You do not have to go and find it. Everything here applies to every adapter
whose game runs inside an emulator; per-game facts live in each adapter's own `documentation.md`,
`FLAGS.md` and `BANDAGES.md`.

**Capped, and part of the emulator session's rule STACK** (`agent_docs/claude-md-cap.md`): this
file loads without being asked. Before adding: what comes out?

**Before touching a Lua file here, read `agent_docs/checklists/before-touching-lua.md`; before a
probe, `before-a-probe.md`.** The lessons that used to sit in `pitfalls.md` live there, one line each.

**This file never restates the root `CLAUDE.md` or `../CLAUDE.md`.** A rule with two homes drifts.

## How this file is split, and why

Every adapter here today is BizHawk, so BizHawk rules and emulator-in-general rules share one file
under **two headings**: **Part 1** would survive a Dolphin, mGBA or DuckStation adapter unchanged;
**Part 2** is BizHawk's own API and the GB/GBA hardware. Per `../CLAUDE.md`'s create-a-level-on-demand
rule, a second emulator creates `emulator/bizhawk/`, and Part 2 is what moves down into it.

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

One `console.log` plus one `flush` measured at **63–83ms** — four to five frames — on the emulator's
own thread (2026-08-21), and both Lua adapters shipped a per-second line. So: **open the log buffered
(`setvbuf("full", …)`), never flush per line, flush on a timer, and keep the front end's console for
the rare line somebody needs to see** — for anything that runs every frame, shipped code first. The
cost rule and the numbers are `../CLAUDE.md`'s. **And when anyone says "choppy", measure PACING, not
rate**: `dev-scripts/bizhawk-hitch-meter.lua` reports frames over 20ms, over 33ms and the worst gap,
all of which an average hides.

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

**A Lua chunk may declare at most 200 locals in its main body.** Past that the file does not load:
BizHawk reports `too many local variables (limit is 200) in main function`, the dev loader prints one
`LOAD FAILED` line, and the adapter is simply absent — the game runs with no ghosts, which reads as a
networking fault. Hit four times in one Crystal session (2026-08-21) and again 2026-08-26; preflight's
"Lua parses" now fails the tree the moment a file crosses it, so the cost is a red check, not a cycle.

| adapter | top-level locals, re-measured 2026-08-28 |
|---|---|
| Crystal | **197 of 200** — compiles with 3 added, fails with 4 |
| Emerald | **199 of 200** — compiles with 1 added, fails with 2 |

**A number nothing re-measures is a number that WAS true** — re-measure before planning around the
headroom, and expect worse. **Measure the headroom, do not count `local` lines**: the limit is on
NAMES, so `local a, b, c` spends three. Append N throwaway locals to a copy and compile it, halving N
until it flips, and read the headroom off the PASSING count (`used = 200 - N`):

```sh
C:/msys64/mingw64/bin/luac.exe -p <copy-with-N-extra-locals.lua>
```

**The fix is modules, each with its own budget** (`agent_docs/ideas.md`'s deferred refactors), with one
trap paid for twice: a file loaded with `dofile` sees `debug.getinfo(1,"S").source` as a RELATIVE
path, so a shared module that calls `scriptDir()` resolves to `"."` and `package.loadlib` then resolves
a DLL against BizHawk's process directory. **A shared module never resolves its own directory: the
host adapter resolves `SCRIPT_DIR` and passes it in.**

**So group by default, from the first file** — related constants and state on one table (`local oam =
{...}`), not one name each. **And when a change to a big adapter mysteriously does nothing, check the
loader log for `LOAD FAILED` before anything else.** It is one line, and it scrolls away.

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
