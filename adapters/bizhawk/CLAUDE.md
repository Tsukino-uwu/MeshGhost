# BizHawk adapters — host rules

**Loaded automatically** the first time this session reads or edits anything under
`adapters/bizhawk/`. You do not have to go and find it. Everything here applies to *both*
BizHawk adapters (Crystal, Emerald) and to any future one on this host; per-game facts live in
each adapter's own `documentation.md`, `FLAGS.md` and `BANDAGES.md`.

**Capped at 300 lines, for the reason the root `CLAUDE.md` is capped** — this file loads without
being asked, so it spends the same instruction budget, and an uncapped auto-loading file
recreates the problem the cap exists to prevent. `agent_docs/claude-md-cap.md` has the argument.
Before adding: what comes out to make room?

These sections were moved here verbatim from `adapters/_template/` on 2026-08-25. They were
never template-general — a Unity or Unreal adapter was being told to read GBA register layouts
— and `_template/` keeps a one-line pointer where each one sat.

## An emulator adapter is Lua-only — never patch the ROM

**Start from this, before the first file exists.** A BizHawk adapter reads and writes the running
machine's RAM from the emulator's own Lua front end, and it never ships, generates or requires a
patched ROM. The reason is compatibility, not purity: MeshGhost works on Archipelago seeds and
randomizers **because it never touches the ROM** — whatever patch the player is already running
stays intact underneath, and MeshGhost layers on top. Our own patch would have to be reconciled
with theirs, which is not something a player can do, so a patch trades a feature that works on
every ROM for one that works on one ROM.

What this rules out is real and worth knowing up front: any technique needing code *inside* the
game — a custom interrupt handler, new code at a ROM address, a hooked routine that must return a
value. The way around it is nearly always the front end reaching the same place from outside: an
execute hook on an engine routine is a mid-frame wakeup with no patch at all. Full reasoning and
what it costs: the 2026-08-21 ADR in `agent_docs/architecture.md`.

## A per-second log line is a per-second stall — and it ships

**A rule the new adapter starts with, because both existing Lua adapters got it wrong.** Writing to
the log is not free: one `console.log` plus one `flush` was measured at **63–83ms** on 2026-08-21 —
four to five frames — on the emulator's own thread. Crystal's drawn tier wrote one summary line a
second whenever peers were present, so a shipped session lost that every second, and Emerald
wrapped the global `console.log` so every console line flushed to disk too.

So: **open the log buffered (`setvbuf("full", …)`), never flush per line, flush on a timer, and keep
`console.log` for the rare line somebody actually needs to see.** [probes.md](../_template/probes.md) has said
"buffer, and flush in batches" since the drawn tier was built — what failed was reading it as advice
about *probes*. It is not. It is about anything that runs every frame, shipped code first.

**And when anyone says "choppy", measure PACING, not rate.** An average cannot see a hitch: ten
frames lost inside one second still reads as 58fps, which is why this cost a whole session before it
was found. `dev-scripts/bizhawk-hitch-meter.lua` is standing rig for exactly that — game-agnostic,
attach it to any performance question, and it reports frames over 20ms, frames over 33ms and the
worst gap rather than an average that hides all three.

## Don't pay a relaunch per probe revision (BizHawk)

`EmuHawk.exe --lua=<script> "<rom>"` attaches a script at launch, but swapping one on a *running*
emulator is a Lua Console GUI action nothing outside the process can drive — so every edit
otherwise costs a full relaunch, and each relaunch interrupts whoever is holding the controller.
`dev-scripts/bizhawk-dev-loader.lua` is attached once and then loads, swaps or drops whatever
script a one-line control file names. Write a probe to its contract — set `MESHGHOST_DEV_TICK`,
no `while true ... emu.frameadvance()` loop of your own, and gate that loop on
`MESHGHOST_DEV_LOADER` if the file should still work opened directly. Details and the confirmed
live behaviour: `agent_docs/environment.md`.

## Write breakpoints: the only instrument that sees BETWEEN frames (Emerald, 2026-08-21)

A defect that exists at RENDER time but never at the Lua tick is invisible to every per-frame
probe by construction -- struct dumps, OAM scans, VRAM-vs-ROM checks and allocation-bitmap dumps
all read clean while the screen shows garbage. The instrument for that gap is
`event.onmemorywrite` on the affected range: each write event carries the address and value, and
`emu.getregister` the CPU state.

What a day of using it taught:

- **Register one address per tile (stride 32), not every byte** -- a breakpoint can push the
  emulator core onto a slow path, and sampling catches any multi-byte copy anyway.
- **PC inside the BIOS (0x2A0) means a CpuSet/LZ77 call; LR is ALSO banked to the BIOS there**,
  so registers cannot name the game-side caller. Name the writer by its DATA instead: search the
  ROM for the written values at the observed stride. No ROM match means a RAM source
  (decompressed graphics, heap frame buffers).
- **Budget the event count and stamp `emu.framecount()` into every line** -- the interesting
  window is a handful of frames, and correlating with screenshots requires one shared clock
  across probe lines, log lines and screenshot filenames.
- **The engine's sprite-copy queue executes at VBlank, one frame AFTER the request** -- so a
  sprite despawned this tick can still write its tiles next frame. Tiles freed at despawn and
  re-claimed in the same tick get the dead sprite's frame stamped over the new owner's load.
  If a despawn frees tile ranges, defer the free by a few frames.

## Read the engine's own copy when the register is write-only (Emerald, 2026-08-21)

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

