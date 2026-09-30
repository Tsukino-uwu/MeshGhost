# Emulator adapters — host rules

<!-- line-cap: 200 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**Loaded automatically** the first time this session reads or edits anything under
`adapters/emulator/`. It applies to every adapter whose game runs inside an emulator; per-game facts
live in each adapter's own `documentation.md`, `FLAGS.md` and `BANDAGES.md`. **Capped, and part of
the emulator session's rule stack** (`agent_docs/claude-md-cap.md`): before adding, what comes out?

**Before touching a Lua file here, read `agent_docs/checklists/before-touching-lua.md`; before a
probe, `before-a-probe.md`.** The stories behind these rules: `agent_docs/pitfalls/by-lesson.md`,
"The stories behind the rule files".

**Part 1** would survive a Dolphin, mGBA or DuckStation adapter unchanged; **Part 2** is BizHawk's own
API and the GB/GBA hardware. A second emulator creates `emulator/bizhawk/`, and Part 2 moves into it.

---

## Part 1 — true of any emulator host

### An emulator adapter is script-only: never patch the ROM

**Start from this, before the first file exists.** An emulator adapter reads and writes the running
machine's RAM from the emulator's own scripting front end, and never ships, generates or requires a
patched ROM. The reason is compatibility: MeshGhost works on Archipelago seeds and randomizers
**because it never touches the ROM**, so whatever patch the player runs stays intact underneath.

That rules out any technique needing code inside the game (a custom interrupt handler, new code at a
ROM address, a hooked routine that must return a value). The way around is nearly always the front
end reaching the same place from outside: an execute hook on an engine routine is a mid-frame wakeup
with no patch at all. Reasoning and cost: the 2026-08-21 ADR in `agent_docs/architecture.md`.

### A per-second log line is a per-second stall, and it ships

A `console.log` plus a `flush` runs on the emulator's own thread and costs frames. So: **open the log
buffered (`setvbuf("full", …)`), never flush per line, flush on a timer, and keep the front end's
console for the rare line somebody needs to see**, for anything that runs every frame, shipped code
first. Numbers: `agent_docs/pitfalls/by-lesson.md`, "ONE console line a second cost 7.4 fps". **When
anyone says "choppy", measure pacing, not rate**: `dev-scripts/bizhawk-hitch-meter.lua` reports frames
over 20ms, over 33ms and the worst gap, all of which an average hides.

### A memory-write breakpoint is the only instrument that sees between frames

A defect that exists at render time but never at the script tick is invisible to every per-frame
probe by construction: struct dumps, sprite-table scans, VRAM-vs-ROM checks and allocation-bitmap
dumps all read clean while the screen shows garbage. The instrument for that gap is a write breakpoint
on the affected range (BizHawk's API: Part 2):

- **Register one address per tile (stride 32), not every byte**: a breakpoint can push the emulator
  core onto a slow path, and sampling catches any multi-byte copy anyway.
- **Budget the event count and stamp the frame number into every line**: correlating with screenshots
  needs one shared clock across probe lines, log lines and screenshot filenames.
- **A sprite-copy queue that executes at VBlank runs one frame after the request**, so a sprite
  despawned this tick can still write its tiles next frame. If a despawn frees tile ranges, defer the
  free by a few frames.

### Lua's 200-local ceiling stops your adapter loading, silently

**A Lua chunk may declare at most 200 locals in its main body.** Past that the file does not load:
BizHawk reports `too many local variables (limit is 200) in main function`, the dev loader prints one
`LOAD FAILED` line, and the adapter is simply absent, which reads as a networking fault. Preflight's
"Lua parses" fails the tree the moment a file crosses it. Both big adapters sit at or next to the
limit (the last measurement: the stories section).

**Measure the headroom before planning around it; never count `local` lines**: the limit is on names,
so `local a, b, c` spends three. Append N throwaway locals to a copy and compile it, halving N until
it flips, and read the headroom off the passing count (`used = 200 - N`):

```sh
C:/msys64/mingw64/bin/luac.exe -p <copy-with-N-extra-locals.lua>
```

**The fix is modules, each with its own budget** (`agent_docs/ideas.md`'s deferred refactors). **A
shared module never resolves its own directory: the host adapter resolves `SCRIPT_DIR` and passes it
in**; under `dofile`, `debug.getinfo(1,"S").source` is relative, so a module's own `scriptDir()`
resolves to `"."` and a DLL loads against BizHawk's process directory.

**So group by default, from the first file**: related constants and state on one table (`local oam =
{...}`), not one name each. **When a change to a big adapter mysteriously does nothing, check the
loader log for `LOAD FAILED` before anything else.**

**Touch a JSON decoder, run `adapters/emulator/tests/json_fuzz.lua` first**: it loads both shipped
decoders out of their files (`emulator.yml` runs it in CI).

---

## Part 2 — BizHawk, and the GBA/GB hardware underneath

**This is the half a second emulator would not inherit.**

### Don't pay a relaunch per probe revision

`EmuHawk.exe --lua=<script> "<rom>"` attaches a script at launch, but swapping one on a running
emulator is a Lua Console GUI action nothing outside the process can drive. `dev-scripts/bizhawk-dev-loader.lua`
is attached once and then loads, swaps or drops whatever script a one-line control file names. Write a
probe to its contract: set `MESHGHOST_DEV_TICK`, no `while true ... emu.frameadvance()` loop of your
own, and gate that loop on `MESHGHOST_DEV_LOADER` if the file should still work opened directly.
Details: `agent_docs/environment.md`.

### The write-breakpoint API

The instrument Part 1 describes is `event.onmemorywrite` on the affected range: each write event
carries the address and value, and `emu.getregister` the CPU state. On GBA specifically:

- **PC inside the BIOS (0x2A0) means a CpuSet/LZ77 call; LR is also banked to the BIOS there**, so
  registers cannot name the game-side caller. Name the writer by its data instead: search the ROM for
  the written values at the observed stride. No ROM match means a RAM source (decompressed graphics,
  heap frame buffers).

### Read the engine's own copy when the register is write-only

Several GBA display registers are write-only and return garbage when read (`WIN0H`, `WIN0V`, `BLDY`
among them) while their neighbours (`DISPCNT`, `BLDCNT`, `BLDALPHA`, `WININ`, `WINOUT`) read fine, and
nothing in a dump marks which is which. The engine keeps its own copy in RAM to write each frame (a
per-scanline effect keeps a buffer plus a descriptor naming the register and whether it runs); read
that instead. It also holds all 160 lines' values, where the register holds only the current one.

**Check a register's read/write status before building an argument on a dump**, and prefer the
engine's own state to a hardware read whenever both exist.
