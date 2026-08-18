# Environment

Exact tools, versions, and configuration known to work for this project. Filled in as each
phase actually sets up its own tooling — never pre-fill a version number from memory.

Every version below is confirmed as of its own recorded date, not a permanent guarantee — see
`CLAUDE.md`'s general rule on dated facts in `agent_docs/`. Installed tools/mods/games can
update out from under this file with no warning (this has already happened three times here:
UE4SS drifted v2.5.2→v3.0.1 mid-Phase-7, TEVI's install updated between two consecutive checks,
and a 2026-08-13 `AP_Randomizer` reinstall silently swapped the shared UE4SS runtime — see the
UE4SS entry below for that last one specifically, which is currently unresolved).

## Host

- OS: Windows 11 Pro (dev machine). Cross-platform build targets: Windows, Linux, macOS.
  **All three are built.** CI cross-compiles `linux/arm64`, `darwin/amd64` and `darwin/arm64` on
  every run (`.github/workflows/ci.yml`), and `release.yml` ships linux amd64/arm64 and macOS
  amd64/arm64 binaries in their own archives. What is still true is that **macOS has no runner and
  is never *run*** — compile-only — and Linux has been exercised live by the Linux tester
  (Pseudoregalia over Proton, 2026-08-16, `verified.md`) rather than by CI.
- Go toolchain: **confirmed installed**, `go1.26.5 windows/amd64` (`go version`, 2026-08-11).
  `go build ./...` and `go vet ./...` both pass clean on the current type skeleton.
  **Re-confirmed 2026-08-17**: still `go1.26.5 windows/amd64`.
- Go module pins (read from `go.mod`, 2026-08-17): language directive `go 1.25.0` — raised from
  1.22 by `go get` when quic-go was adopted (see `agent_docs/licensing.md`) — and one direct
  dependency, `github.com/quic-go/quic-go v0.61.0`, with `golang.org/x/crypto v0.54.0`,
  `golang.org/x/net v0.56.0` and `golang.org/x/sys v0.47.0` indirect. Both GitHub workflows pin
  `setup-go` to `1.25`, which is the directive's floor rather than the locally installed version;
  `GOTOOLCHAIN=auto` is what let CI pass while it was still pinned to 1.22. Which of these
  actually *link* into the shipped binaries is a separate (smaller) list — see
  `packaging/release/THIRD-PARTY-NOTICES.txt`.
- **cgo / the race detector: works, as of 2026-08-18.** `go test -race` needs a real C toolchain,
  and the one that works here is the **standalone MSYS2 mingw64** at `C:/msys64/mingw64/bin`
  (not devkitPro's MSYS2, whose `gcc` cgo cannot use — `stddef.h: No such file or directory`).
  **Setting `CC` alone is not enough**: the compiler's own `bin` must be *ahead of devkitPro on
  `PATH`* so `as`/`ld`/headers resolve, or it fails with `runtime/cgo: cgo.exe: exit status 2`.
  This was recorded as "does not work on this machine" from 2026-08-16 until 2026-08-18, which
  was wrong about the reason. The exact recipe is in `testing.md`'s Race detector section, and
  `dev-scripts/run-gotests-race.bat` runs it. Same `PATH`-shadowing trap as `cmake` and `cmd`
  (`pitfalls.md`).
- Python: **confirmed installed**, 3.12.10 (`python --version`, 2026-08-11), at the standard
  per-user install location (`%LOCALAPPDATA%\Programs\Python\Python312\python.exe`). Invoke as
  `python`, not `python3` — only `python` is on `PATH` (both in a normal shell and in the
  agent's Bash tool, which runs Git Bash and has its own `PATH`).
- .NET SDK: **confirmed installed**, `10.0.302` (`dotnet --version`, 2026-08-12), at
  `C:\Program Files\dotnet\sdk`. Used for the TEVI adapter (Phase 6) — a `netstandard2.0` class
  library targeting BepInEx 5.4, which the modern SDK builds fine via `dotnet build`.
- CMake: **confirmed installed**, `4.4.2` (`cmake --version`, 2026-08-12), via
  `winget install Kitware.CMake`, at `C:\Program Files\CMake\bin`.
- Visual Studio / MSVC C++ toolchain: **confirmed installed**, VS 2022 Build Tools with the
  C++ workload (`Microsoft.VisualStudio.Component.VC.Tools.x86.x64`), via winget, at
  `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` (confirmed via `vswhere`,
  2026-08-12).
- **Building a real UE4SS C++ mod was blocked by a private submodule, resolved 2026-08-12**:
  RE-UE4SS's core `UE4SS` CMake target hard-depends on `deps/first/Unreal`
  (`Re-UE4SS/UEPseudo`), gated behind linking a GitHub account to an Epic Games account and
  accepting the resulting `EpicGames` org invite — done, and `git submodule update --init
  deps/first/Unreal` now succeeds with real content. CMake/MSVC being installed was necessary
  but not sufficient on its own; this access gate was the other half. See
  `agent_docs/risks.md` and `agent_docs/phases/phase7.md` for the full investigation, and
  `MeshGhostPseudo`'s shipping C++ mod (built via `dev-scripts/build-pseudoregalia.bat`) for
  confirmation the unblocked path actually builds.

## BizHawk / Emerald

- BizHawk version: **confirmed**, 2.11 (Help → About, 2026-08-11).
- Lua version used by BizHawk: **confirmed**, Lua 5.4 (`print(_VERSION)` in the Lua Console,
  2026-08-11).
- Emerald ROM version/revision: file named "Pokemon - Emerald Version (USA, Europe).gba",
  16,777,216 bytes, MD5 `605B89B67018ABCEA91E693A4DD25BE3` (computed via `Get-FileHash`,
  2026-08-11). Not yet cross-referenced against a named revision (e.g. "U 1.0" vs "U 1.1") —
  do that against a citable source (e.g. pokeemerald's own build docs) before relying on it.
  Per `agent_docs/licensing.md`, only the hash/size is recorded for reproducibility; the ROM
  itself is never committed.
- BizHawk core in use: GBA core confirmed via the emulator's "GBA" menu being present
  (2026-08-11) — not the SNES/BSNES core, which matters because a leftover Archipelago
  `Connector.lua` (SNI/SNES-only) throws an unrelated timeout error that can be ignored.
- Any non-default BizHawk launch options: none — launched normally, no special flags/config
  (confirmed 2026-08-11).
- BizHawk install location (this machine): `C:\ProgramData\Archipelago\Bizhawk\EmuHawk.exe`
  (a shared install also used by Archipelago, not a MeshGhost-dedicated copy). ROM location:
  `C:\ProgramData\Archipelago\bizhawk roms\Roms\gba\Pokemon - Emerald Version (USA,
  Europe).gba` — same file whose hash is recorded above. Confirmed 2026-08-11 for Phase 4
  two-instance testing. **For a real two-instance test, launch each `EmuHawk.exe` with
  `MESHGHOST_BRIDGE_PORT` set first** (instance 2 needs `7779`; the Lua adapter defaults to
  7778 if unset, same as instance 1) — double-clicking the exe directly skips this silently,
  with no error, and both instances end up talking to the same core. See
  `dev-scripts/README.md`'s `.local.bat` launchers and `pitfalls.md`'s "Running two instances
  of the same emulator/game silently collide on a shared default port" entry (found live
  2026-08-14, cost a long diagnostic session before the actual cause was this simple).
  **Superseded in code on 2026-08-18, but NOT yet live-verified**: both Pokémon adapters now walk
  ports 7778-7785 and take the first core that answers `bridge_ready`, so a second instance
  should find its own core with no environment variable at all. Until that has actually been
  watched with two emulators and two cores, keep setting the variable — it is still honoured, and
  an explicit port disables the walk by design.
- Archipelago coexistence: confirmed 2 Lua scripts (`ButtonCount`, `Connector`) can run
  concurrently in BizHawk's Lua Console without conflict (2026-08-11) — satisfies
  `phase1.md`'s first coexistence checklist item, though it should be re-checked later with
  the actual `connector_bizhawk_generic.lua` rather than these placeholder scripts.
- Lua socket support (Phase 3): BizHawk's own `comm.*` (`CommLuaLibrary`) is present in this
  2.11 build but uses length-prefixed framing, not NDJSON — inspected directly via
  `BizHawk.Client.Common.dll`'s embedded doc strings (2026-08-11), not used. LuaSocket
  (vendored, `adapters/bizhawk/pokemon/emerald/lib/x64/socket-windows-5-4.dll`) is used instead — see
  `agent_docs/licensing.md` and the Phase 3 ADR in `architecture.md`.
- BizHawk's Lua host (`LuaLibraries.cs`, confirmed by reading source 2026-08-11) is a plain
  `new Lua()` (NLua) with no standard library removed afterward — `debug`, `os`, `package`,
  `io` are all available to a script, not just the subset BizHawk's own libraries use.
- Memory Lua API (Stage 1 of the VRAM investigation, 2026-08-14): `BizHawk.Client.Common.dll`'s
  embedded doc strings mention `memory.hash_region(addr, count[, domain])`,
  `memory.read_bytes_as_array(addr, length[, domain])`, `memory.write_bytes_as_array`,
  `memory.getmemorydomainsize`, `event.onexit`, `event.onmemorywrite` / `onmemoryread` /
  `onmemoryexecute` / `onmemoryexecuteany`, and the RAM Watch/Search `FreezeValue`/`FreezeList`
  freeze feature. **Correction, found live 2026-08-14 running `vram_probe.lua` for real: a doc
  string existing in the DLL is not proof the function is actually callable at runtime.**
  `memory.hash_region` reported as `nil` (not a function) in this real session even though its
  doc string is present, which is why the probe fell back to its sampled Tier C rather than the
  exhaustive hash-based tier. `event.onexit` and `memory.read_u8`/`read_u32_le`/`read_u16_le`
  (already long-relied-on elsewhere in this project) are confirmed actually callable this way;
  the rest of the list above is unconfirmed at runtime and should not be assumed available
  without the same `type(memory.x) == "function"` guard `vram_probe.lua` uses. None of these
  are game- or sprite-specific — they're generic address-space read/write/hook primitives, the
  same shape as the standalone-mGBA `emu:write32` idiom `GBA-PK-multiplayer` uses, just under
  BizHawk's own naming.
- GBA memory domain names on this core (**confirmed** 2026-08-14, via
  `memory.getmemorydomainlist()` from `vram_probe.lua`'s startup log, real user run):
  `IWRAM`, `EWRAM`, `BIOS`, `PALRAM`, `VRAM`, `OAM`, `ROM`, `SRAM`, `Combined WRAM`,
  `System Bus`. A `VRAM` domain does exist on this core (contrary to the "no VRAM domain
  confirmed" gap noted in the Stage 1 plan) — `vram_probe.lua` runs its live aliasing check
  against it at startup rather than assuming the mapping.
- `memory.getmemorydomainlist()`'s own embedded doc string (`BizHawk.Client.Common.dll`)
  claims it returns "a single string delimited by line feeds" — **that's wrong for this 2.11
  build**, confirmed live 2026-08-14: it actually returns a Lua table of domain-name strings.
  Don't trust that doc string's return-type claim for other scripts either; `vram_probe.lua`
  now handles both shapes defensively.

- **Attaching Lua from outside BizHawk, and swapping scripts without relaunching — 2026-08-18.**
  Two separate capabilities, and only the first is BizHawk's own:
  - **Launch-time attach**: `EmuHawk.exe --lua=<script.lua> "<rom>"` loads and runs a script as
    the emulator starts. Confirmed live 2026-08-18 (`object_slot_probe.lua` came up and logged on
    the first try). This is the only handle BizHawk itself exposes to anything outside the
    process — **attaching, swapping or stopping a script on an already-running instance is a Lua
    Console GUI action** and nothing external can drive it.
  - **`dev-scripts/bizhawk-dev-loader.lua` closes that gap.** Attach it once with `--lua=`; it
    polls `dev-scripts/bizhawk-dev-loader.target` (**one script path per line**, or `none`) and
    loads, swaps or drops those scripts live. **It runs several at once** — added 2026-08-18 once
    one slot proved a false constraint: a test-state script has to top up a countdown every frame
    to hold permanent repel, so keeping it meant dropping the adapter, and each swap silently
    undid the other's work. A target that errors in its tick is unloaded and skipped; the rest
    keep running. **Prefer absolute paths**: a relative one resolves against BizHawk's working
    directory, not the loader's folder, and a script that then loads a DLL relative to itself
    fails with "The specified module could not be found" — an error that reads as a missing file
    when the file is present. Writing one line to that file is now the whole
    attach/detach cycle — no relaunch, no GUI, and the running game is undisturbed.
    **Confirmed live 2026-08-18**: loaded, dropped on `none`, and re-loaded, all from the loader's
    own log, with the emulator running throughout.
  - **Why it matters**: an adapter's probe loop is edit-run-watch, and previously every edit cost
    a full emulator relaunch (Crystal's spawn work went through seven `spawn_test` scripts, so
    seven relaunches, each interrupting whoever holds the controller). The contract for a
    loadable script is in the loader's own header: set `MESHGHOST_DEV_TICK`, don't run your own
    `while true ... emu.frameadvance()` loop, and check `MESHGHOST_DEV_LOADER` if the same file
    should still work when opened directly in the Lua Console. It is a development tool only and
    is never part of a shipped adapter.
  - **The effect, in the user's words the day it was built** (2026-08-18): *"i had to start/stop
    each lua myself, go to the folder and open new scripts, refresh them etc myself before. so
    this is way faster for testing and finding things"*, and on the arc across three adapters —
    *"when we started emerald it took forever, then we did the crystal probes and it was
    easier/faster, and now when you are handling the load/deload/reload on your own its almost
    feeling fully automatic and super fast"*. Worth recording because the speed-up is **not** the
    agent getting better at Emerald: it is that the human stopped being in the loop for the
    mechanical half. The remaining human step — watching the screen and saying what is wrong — is
    the one that cannot be automated and is exactly where every real bug this session was caught.
- **A BizHawk Lua script must find itself with `debug.getinfo`, never `io.popen("cd")` —
  2026-08-18.** BizHawk changes the working directory to a script's own folder when that script is
  opened by hand in the Lua Console, so `io.popen("cd")` returns the right answer *by coincidence*
  and only in that one case. Load the same file any other way — from another script, or with a
  different working directory — and it resolves `lib/x64/` against the wrong folder and dies with
  **"The specified module could not be found"**, which reads like a missing DLL and sends you
  looking at LuaSocket instead of at a path. Found live 2026-08-18 loading the Emerald adapter
  through the dev loader. `io.popen` also **spawns a real `cmd` process**, so every launch flashed
  a console window on screen — the user spotted that independently, and it is pure cost: nothing
  needs a shell to ask where it is. `debug.getinfo(1, "S").source` is the path the chunk was
  loaded from, which is the actual question. Crystal's adapter already did this and Emerald's did
  not; both do now.
- **CORRECTION, same day: `io.popen` was NOT an unreachable fallback, and deleting it broke
  `--lua=` immediately.** Loaded with `--lua=<path>` BizHawk reports `source` as
  `[string "main"]` -- not a path -- so `debug.getinfo` cannot answer and the fallback was what
  ran on every such launch. That is where the console flash came from, and it is also why the
  flash was visible when the loader claimed to have removed the cause. Both adapters now accept
  `MESHGHOST_SCRIPT_DIR` (an env var a launcher can set for free, no process spawned), fall back
  to `debug.getinfo`, and keep `io.popen` last for the case where nothing offered an answer.
  `dev-scripts` set the env var. **The lesson is the shape, not the API: "this branch is
  unreachable" is a claim to test, not to annotate** -- one launch settled it.
- **Savestates are drivable from Lua, and all ten slots are ours for testing — 2026-08-18.**
  `savestate.save` / `load` / `saveslot` / `loadslot` are all present and callable in this build
  (checked at runtime, not from a doc string — `savestate.saveslots` does NOT exist). BizHawk has
  **ten slots**, and the user has given standing permission to use all of them during
  dev/testing: *"you are allowed to use all 10 during dev/testing/local tests"*.
  `dev-scripts/bizhawk-savestate.lua` saves or loads one slot and stops.
  **Why it matters:** reaching a test state costs the user real playing time, so a checkpoint
  turns "walk back to the route / re-catch a Pokemon / replay the intro" into an instant restore,
  and makes a risky test cheap to repeat.
  **The trap, hit live the same day: a savestate is NOT an in-game save.** Asked to "save" before
  an emulator relaunch, the user saved a *state* — and the relaunch still lost their place,
  because the two are separate mechanisms. Anything a test kit writes into RAM (badges, items,
  repel) is captured by a savestate but only reaches the `.sav` file when the game itself saves.
  Say which one is meant. Recovery, when it happens: the state FILES survive a relaunch
  (`Bizhawk/GBA/State/<rom>.mGBA.QuickSaveN.State`), so `loadslot` puts it back.
- **A whole test cycle can now run without the user touching anything — 2026-08-18.** The pieces
  were assembled separately today and only add up when listed together, which is the user's own
  observation: *"this also allows you to start bizhawk, get in game without me doing anything"*
  and *"it allows you to bypass/test things you couldn't without me before"*.

  | Step | Mechanism | Status |
  | --- | --- | --- |
  | Start the emulator with a ROM and a script | `EmuHawk.exe --lua=... "<rom>"` | confirmed, used all day |
  | Attach/swap/drop scripts while it runs | `bizhawk-dev-loader.lua` + its control file | confirmed, dozens of times |
  | Get past the title screen into a save | `savestate.loadslot(n)` | **confirmed end to end**: after an emulator relaunch, a `loadslot` put the game in the overworld with no button pressed by anyone |
  | Re-reach any prepared state | ten savestate slots | confirmed |
  | Press buttons | `joypad.set` | **works** — confirmed 2026-08-18 by holding Down for 48 frames and reading the player's coordinates move (9,9) -> (9,12). **Pass NO controller index** (see below) |
  | Observe | memory reads + each script's own log file | confirmed |

  **What this changes:** a test that needs the game in a particular place no longer costs the user
  the walk to get there. Checkpoint the state once, and every later run starts from it.

  **What it does NOT change, and this is the part to keep hold of:** `CLAUDE.md`'s rule that an
  adapter claim needs *"the expected thing seen happening on screen"* stands exactly as before.
  Every one of the six real bugs found in the 2026-08-18 Emerald session — the ghost wearing the
  player's animation frames, the slot-machine script, the frozen ghost, the fast-walk instead of a
  run, the off-grid placement, the leaked ghosts across route boundaries — was caught by a person
  looking at the screen, and in every case the logs looked healthy. **Automating the mechanical
  half of the loop is what this buys; the judging half is not automatable and should not be
  presented as if it were.**
- **The agent can SEE the screen — `client.screenshot`, confirmed working 2026-08-18.**
  `dev-scripts/bizhawk-screenshot.lua` writes a PNG; the agent then reads that PNG directly. First
  run showed the town, the player, and the spawned ghost beside them, all legible.
  **A SCREENSHOT IS NEVER PROOF, AND THIS CHANGES NO RULE.** The user's instruction on the day the
  capability was found, having been asked directly whether the gate should move: *"Keep the rule
  exactly as it is"* and *"even with a picture, I still have to verify/confirm visually as well.
  never take pictures as proof"*. `verified.md`'s human gate on anything visual stands **exactly**
  as written — a screenshot does not satisfy it, not for motion, and not for a static fact either.
  **What it is for:** the agent debugging faster on its own time — checking a hypothesis before
  spending the user's attention, seeing which of two guesses is worth pursuing, attaching the
  failing frame to a question instead of describing it in words. It shortens the loop *before* a
  claim is made; it is not evidence *for* the claim.
  **ALWAYS CROSS-REFERENCE A PICTURE WITH THE LOG, AND TAKE ONE RATHER THAN WAITING FOR ONE**
  (user, 2026-08-18). Both halves were learned the same afternoon:
  - **A screenshot alone misleads.** Three in a row showed "no ghost" and sent a session chasing a
    rendering bug — they had been taken a frame or two after the loader started, before the
    adapter had even connected. The log held the actual cause: `rejected (busy: this core already
    has a game attached)`, a leaked bridge socket from the previous reload.
  - **A log alone misses what matters.** When a ghost was finally built from a peer's own graphic,
    every logged field looked correct — right OAM, right pointers, right tile allocation — and it
    rendered as scrambled garbage. Only a picture showed that, and the agent had the capability to
    take one and waited for the user's instead.

  **Why the limit is real and not just caution:** a still frame answers "what is on screen right
  now", never "does this look right while moving". All six real bugs in the 2026-08-18 Emerald
  session were motion or interaction defects — a ghost mirroring the player's animation, a frozen
  ghost, a walk that should have been a run, a script firing on interaction — and **a screenshot
  would have caught almost none of them.** The instrument is weakest exactly where the bugs were.
- **The cheat engine is reachable from Lua, and on GBA it is a trap — 2026-08-18.**
  `client.addcheat` / `removecheat` / `opencheats` are all callable (NLua reports them as
  `userdata`, not `function`, so a type check rejects them wrongly). But `addcheat`'s own doc
  string says it adds a code *"if supported"*, and a `pcall` returning true only means the call
  did not throw. This build has a `GbaGameSharkDecoder` and **no CodeBreaker decoder**: of six
  Emerald codes added, four were silently dropped and **two were accepted, decoded to nonsense
  (address `0x0000000E`), and marked ACTIVE** — writing a garbage byte every frame, which would
  later have been blamed on the adapter. Judge a cheat by the decoded ADDRESS shown in the Cheats
  dialog, never by the API's return value, and clear what you added
  (`dev-scripts/bizhawk-cheat-clear.lua`). Full write-up, including the Gold/Silver-code trap that
  writes into Crystal's object array: `pitfalls.md`. **For GBA, prefer writing the real save
  structure at decomp-verified offsets** — `adapters/bizhawk/pokemon/emerald/probes/testkit.lua`.
- **To enumerate what a BizHawk build actually implements**, `client.getluafunctionslist()`
  returns the real list — better than reading DLL strings, which include functions that are nil at
  runtime.
- **Driving input: `joypad.set(buttons)` with NO controller index, and get the button names from
  the core — 2026-08-18.** Two silent failures before this worked, and neither raised an error:
  - **`joypad.set({Right = true}, 1)` does nothing.** The trailing `1` makes BizHawk look for the
    player-prefixed name (`"P1 Right"`), which a single-controller core does not have. Dropping
    the index made the same call move the player immediately. The `pcall` succeeded both times —
    **a silent no-op, not an error**, which is the recurring shape of this whole API.
  - **Button names differ per core**, as the user put it: GBA, DS, GB and SNES all present
    different controls. Do not hardcode them — **`joypad.get()` returns the current input as a
    table, so its KEYS are exactly what this core accepts.** On the GBA core they are bare
    `A B L R Up Down Left Right Start Select`, plus `Power`, `Light Sensor` and `Tilt X/Y/Z`.
  - `joypad.set` applies to the **next frame only**, so a held button must be re-issued every
    frame rather than set once.
- **Switching ROMs without restarting the emulator — `client.openrom` (2026-08-18).**
  `client.openrom(path)`, `client.closerom()` and `client.reboot_core()` are all present in this
  build's Lua API. The user pointed at BizHawk's own File -> Recent ROM list to make the point:
  changing ROM is a menu action, not a relaunch, and the Lua API exposes it. **That matters
  because a relaunch drops every attached script**, the dev loader included, and loses whatever
  state the session was holding — so testing "does this adapter behave on a different ROM" costs a
  full re-setup only if you go the long way round.
  Practical use: the Emerald adapter has to be exercised against **both** a vanilla and an
  Archipelago-patched ROM (`BANDAGES.md`), and those are two `openrom` calls apart rather than two
  emulator sessions apart.
  **Tested 2026-08-18, and it does everything the menu does:** `client.openrom` loads an
  **arbitrary path**, not only recent entries; **the Lua environment survives the swap**, so the
  dev loader and every attached script keep running; and swapping back plus `loadslot` restores
  the previous session exactly. Measured vanilla -> AP seed -> vanilla in a single run. The user
  confirmed visually that the patched ROM really loaded.
  **Two traps found while proving it:**
  - **The cartridge header does NOT identify a patched ROM.** Both read `POKEMON EMER`, because an
    Archipelago patch keeps the header. Fingerprint **code** instead — three words around
    `CB2_Overworld` gave vanilla `4809B510 23C004D2 46684918` against the seed's
    `00000888 FF86F779 4809B510`. That third word is vanilla's *first*, which is the known
    `CB2_Overworld` relocation (`0x08085E5C` -> `0x080867F1`, `verified.md` 2026-08-14) showing up
    as a shift — an independent corroboration nobody asked for.
  - **State carried over between runs made a real difference invisible.** The first attempt sampled
    "before" and "after" in two separate runs, and got identical fingerprints — because the earlier
    run had already left the other ROM loaded, so both samples were the same cartridge. Measure
    both sides inside one run, from a starting point you set yourself.
  **Still blocked on something else**: a patched ROM boots to the intro, and no save or savestate
  exists for one on this machine — so reaching its overworld means playing the intro. Swapping is
  cheap; arriving somewhere useful is not.
- **Telling a patched ROM from a vanilla one by its file name — a tell, never a conclusion.**
  The user, 2026-08-18: *"garbled = probly archipelago, good names = most likely the vanilla
  roms"*. A clean `Pokemon - Emerald Version (USA, Europe).gba` is almost certainly vanilla; a
  `P1_Tsukino_N2LVKSRcSG-V8oZzd11ehg.gba` is almost certainly a generated Archipelago seed, since
  the generator names output after the player and a seed hash. **Useful for picking a file, never
  for deciding what the adapter is talking to** — the adapter identifies the ROM from memory
  (finding the player's own object event at one of two known addresses) precisely because a file
  name is not evidence. Same standing rule recorded for Crystal: treat the name as a hint and
  confirm.
- **Restarting the game without restarting the emulator** — BizHawk's Emulation menu has Reboot
  Core (Ctrl+R), Soft Reset and Hard Reset; pointed out by the user 2026-08-18. Useful when a test
  needs a cold boot: it avoids relaunching EmuHawk, which would drop every attached script and
  release the loader. Prefer restoring a savestate where that suffices, since it is faster and
  lands exactly where wanted.
- **BizHawk pauses while any of its own menus or dialogs is open** — confirmed by the user
  2026-08-18, who has "pause when unfocused" already disabled. While paused, `emu.frameadvance()`
  does not return, so **the dev loader stops polling and every attached script stops ticking**.
  The symptom is confusing from outside: control-file changes are silently ignored and log files
  stop growing, which reads as a broken loader rather than a paused emulator. Check whether the
  adapter's log is still growing before debugging anything else.
- **How to actually use all of the above: iterate freely, then hand over ONE confirmation.**
  Stated by the user 2026-08-18, after the automation above was assembled:

  > *"you are fine to test/try things, and fix them. but i have to confirm the end result. it does
  > not stop you from trying to find/fix more things. it just means i will have to confirm
  > personally at the end that EVERYTHING works as intended after you have done so."*

  **The gate is on the CLAIM, not on the activity.** Restoring savestates, driving input, taking
  screenshots, spawning things, breaking them and fixing them again — all of that is the agent's
  own business and needs no permission and no supervision. What needs the user is the *end
  result*: a personal confirmation that everything works as intended, before anything is called
  done or written into `verified.md`.

  **The practical shape this asks for**, which is the opposite of what the agent was doing before
  it was said: do **not** stop after every change to ask "does this look right?". Run the loop —
  find, fix, re-test, find the next thing — and hand over a finished piece with a short list of
  what to look at. Interrupting at each step spends the user's attention on intermediate states
  that may not survive the next fix, and their attention is the scarce resource the whole toolchain
  exists to protect.

  **The hard part, restated because it is the part that decays:** *"nothing is considered
  done/fixed until i actually confirm it as such"* (user, 2026-08-18). Not the tests passing, not
  the log looking right, not a screenshot, not the agent having watched a memory value change, and
  not several of those together. **Until the user has confirmed it, a fix is a candidate fix and a
  feature is an attempt** — say so in those words, in chat, in commits, and in `status.md`.
  Writing "done" or "fixed" or "confirmed" ahead of that is the exact failure the split exists to
  prevent, and it is easy to do by accident after a long run where everything went well.

  **Work can queue up while the user is away** (2026-08-18): *"i can confirm/check multiple things
  later if you think a step is currently done yourself, i will confirm them all individually
  later. you are fine to keep going if you 'think' it looks fine or is fixed. but this also does
  not mean it bypasses that i have to actually double check/confirm visually later."* So: do not
  idle waiting for a confirmation, and do not stop at the first thing worth showing. Keep going,
  keep a **list** of what each step is believed to do, and hand the whole list over — the user
  confirms them one by one. "I think this is fixed" is a legitimate working state to build on; it
  is never a finished one, and the queue does not shorten the checking, it only batches it.

  So the loop is: iterate freely -> reach a coherent stopping point -> hand over a list of what to
  look at, described as unconfirmed -> the user confirms -> only then is it done, and only then
  does it go in `verified.md`. The reasoning behind the split is in [testing.md](testing.md), and
  a screenshot never substitutes for any part of it.

  **The two ways the user actually confirms** — *"I either have to play/see it for myself, or see
  it visually happen while/after you have attempted a fix for something"*:

  1. **They play it.** They drive, and report what the game does.
  2. **They watch it happen** while or right after a fix is deployed — the agent sets everything
     up and they observe the result without having to reproduce it themselves.

  **What (2) demands of the agent, and it is easy to get wrong:** a deployed fix has to be
  *observable when they look*. That means saying **what to watch, where, and when** — "the ghost
  should now run when you run" is checkable; "deployed, let me know" is not. Where a state is hard
  to reach, get the game there first (savestate, testkit, scripted input) so the thing to watch is
  already on screen. A fix that only shows up in a log has not been handed over in a form the user
  can confirm at all.

  **And it has to be the REAL behaviour, in the game, as intended** — *"should be replicated as
  intended in the game, so i can observe it working as intended and then either confirm or decline
  it"*. Two things follow:

  - **Demonstrate the intended use, not a rig that happens to work.** A behaviour shown only under
    a special setup proves the setup. Where a rig is unavoidable, say so and say what it does not
    cover — a loopback ghost, for instance, is the player's own state echoed back, so it can look
    perfect while a real peer's differing state would not.
  - **"Confirm or decline" means decline is a normal outcome, not a failure of the handover.**
    Present the thing to be judged, not a conclusion to be agreed with: describe what to watch and
    what correct looks like, then let the answer be no. Do not ask leading questions ("does that
    look right now?"), do not pre-announce success, and treat a decline as information about the
    fix rather than about the user's attention.

### What is expected of the agent, and what is not

**Expected:**

- Do the work without asking at each step: investigate, write, test, break, fix, re-test.
- Use every tool available to narrow a problem down before involving the user — savestates,
  scripted input, screenshots, the test kit, the loader, extra probes.
- Verify the Go client/server/relay **yourself**, with the tools, and never ask the user to watch
  deterministic code ([testing.md](testing.md)).
- Run all scaffolding (relay, core, launchers, emulator) and shut it down afterwards.
- Hand over coherent stopping points, with what to look at, described as unconfirmed.
- Say which evidence class each claim rests on: a log/console read, a Go test, or a user watching.

**Not expected:**

- Not expected to stop after every change to ask "does this look right?" — batch it.
- Not expected to avoid risky experiments. Savestates make almost everything reversible; the rules
  that still bind are the shipped-code ones (never write a save from an adapter, never ship a
  compensation unregistered), not caution about trying things.
- Not expected to confirm anything visual or gameplay-related. The agent **cannot** — and a
  screenshot it took does not count, by the user's explicit instruction.
- Not expected to ask the user to run scripts, `.bat` files, or watch the Go side.
- **COMBINE the capabilities — that is where the leverage is, not in any one of them.** The user,
  2026-08-18, on being told fishing and underwater were "untested":

  > *"you can use cheats to move to different places in the game can't you? and you can probly just
  > change a tile to be ground/water as well? and use the fishing rod onto the water? be a bit
  > creative with the abilities you have for doing things. combine inputs/savestates/cheats to
  > find/test things"*

  The correction is worth keeping because the failure was one of imagination, not capability: each
  tool had been used on its own, and "untested" was reported for a state that was reachable by
  putting three of them together. **Reaching a game state is a puzzle to solve with the toolkit,
  not a precondition to wait for.** What is available, and what it buys when combined:

  | Tool | On its own | Combined |
  | --- | --- | --- |
  | Savestates (10) | Return to a known point | Checkpoint before every attempt, so any experiment is free to fail |
  | `joypad.set` | Press buttons | Walk to a place, open a menu, use an item, trigger an event |
  | Memory writes | Give an item, set a flag | **Edit the world**: change a tile under or in front of the player |
  | Screenshots + zoom | See one frame | Judge the result of the above without asking the user |
  | The decompilation | Look up an address | Find *which* value makes a tile water, an item usable, a state legal |

  Worked example: to test a surfing or fishing ghost you do not need to walk to the sea. Find a
  water metatile in the current tileset (the decomp says which behaviour means water), **write it
  into the tile in front of the player**, checkpoint, then drive the input that uses it — and
  restore the checkpoint afterwards so nothing is left changed. Same shape for any state: ask what
  the game checks, write that, and drive the rest.

  **The standing limit is unchanged.** All of this is dev-only tooling for reaching a state faster;
  it never becomes adapter behaviour, and none of it confirms anything — the user still watches the
  end result.
- **SILENCE IS NOT A RESULT. Prove the measurement was live before reading anything into it.**
  This went wrong **four separate ways on 2026-08-18**, and the last two were the same mistake
  repeated after it had already been written down:
  1. A screenshot fired before the adapter had connected — three convincing pictures of a game
     with no ghost in it.
  2. A probe failed to load (a lost backslash), and its empty log was read as "fishing produced no
     data" rather than "the probe never ran".
  3. **The emulator was paused** — BizHawk pauses while any of its own menus is open — so every
     attached script stopped ticking and every log stopped growing.
  4. The same empty-log-means-nothing-happened reading, again, an hour after (2) was documented.

  **The check is three commands and settles all four:** is the script in the loader log as
  `loaded`, is its log file *growing*, and is a frame counter *advancing*? An empty log answers
  none of those. A probe that is not running produces exactly the same output as a game that did
  nothing, and the two are indistinguishable from the outside — which is why the check has to be
  positive evidence of life, not the absence of an error.
- **Do not write Lua containing backslashes through a shell heredoc.** A Lua pattern like
  `match("^(.*)[/\][^/\]*$")` needs two backslashes in the file, and a bash heredoc plus a
  Python string plus a regex each eat one — so the file ends up with one and Lua rejects it with
  *"invalid escape sequence"*. This happened **four times on 2026-08-18**, twice silently enough
  that a script simply never loaded and its absence was mistaken for the feature not working.
  Use the Edit tool (it respects the literal text), or write the character via `chr(92)` and
  **read the line back with `repr()` in the same command** to confirm what actually landed.
- **`dev-scripts/lua-forward-refs.py` — a name used before its `local` definition.** In Lua that
  resolves to a **global**, which is `nil`, so the call site silently does nothing or errors
  somewhere unrelated — it never looks like what it is. This bit the Emerald adapter **three times
  on 2026-08-18** (`despawnAllGhosts` in the bridge reset, `frameCounter` in the port walk, and
  `SURFING_GFX`/`spawnSurfBlob` in the spawn), each time costing a live test to find, and the
  third one presented as "the surf blob feature does nothing at all".
  Run it over any Lua that has grown past a screen:
  `python dev-scripts/lua-forward-refs.py adapters/bizhawk/pokemon/*/meshghost_*.lua`.
  It considers **file-scope** locals only (a local inside a function cannot be the trap), ignores
  strings, comments, field access, method calls and table keys, and understands a forward
  declaration as the fix rather than an instance. **It reports candidates for a human to judge, not
  errors** — expect roughly one false positive per file. The Emerald adapter reports zero.
- **`dev-scripts/bizhawk-syntax-check.lua` — does this Lua even parse?** BizHawk embeds Lua 5.4
  and this machine has no standalone Lua binary, so before this the only way to find a missing
  `end` in an adapter was to load it into a live session. The checker `loadfile()`s a list of
  files (compiling, never running them, so no socket or frame loop starts) and reports each one.
  Run it through the loader like any other target. Added 2026-08-18 after a bridge rewrite that
  touched both Pokémon adapters at once.

## pokeemerald decomp (address source for Phase 1)

Built once to extract real RAM addresses via a `make compare`-verified build — see
`agent_docs/verified.md` for the addresses themselves and their citations.

- Toolchain: msys2 + devkitARM (GBA Development component only), installed via the devkitPro
  installer to `C:\devkitPro` (confirmed 2026-08-11).
- **To open the msys2 shell:** run `C:\devkitPro\msys2\msys2_shell.bat` (double-click in File
  Explorer, or launch it from Explorer's address bar / a Run dialog). This is a different
  shell from the agent's Bash tool (Git Bash) — `make`/`arm-none-eabi-*` are only on `PATH`
  inside this msys2 shell, not in Git Bash or plain PowerShell.
- Repo locations: `C:\dev\pokeemerald` and `C:\dev\agbcc`, siblings, both outside
  `C:\dev\MeshGhost` on purpose (keeps unlicensed Nintendo-derived source out of this repo's
  tree — see `agent_docs/licensing.md`). In the msys2 shell these are `/c/dev/pokeemerald` and
  `/c/dev/agbcc`.
- Build produces `pokeemerald.map` (always) and `pokeemerald.sym` (via `make syms`) in
  `C:\dev\pokeemerald` — grep either for a symbol name to get its address. No rebuild needed
  to look up a new symbol from an already-built tree; only `make syms` if `.sym` is wanted and
  hasn't been generated yet.
- Build verified matching: `make compare` printed `pokeemerald.gba: OK` (2026-08-11) — this
  must hold for any address pulled from this build to be trustworthy; a `make modern`
  (devkitARM-only, no agbcc) build would NOT match and must not be used for addresses.

## pokecrystal decomp (address source for any Crystal work) — 2026-08-17

Built once during scoping to extract RAM addresses. Verified byte-identical to the user's own
V1.0 ROM — see `agent_docs/verified.md` for the hashes and the addresses themselves.

- **Nothing new had to be installed.** The devkitPro installer has **no Game Boy component** —
  GB/GBC does not use devkitPro at all — so re-running it would not have helped. The host
  `gcc` (15.3.0) and `make` already present with msys2 are the only compiler needed.
- Toolchain: **rgbds v1.0.3**, the version `pokecrystal`'s own `INSTALL.md` pins. Distributed as a
  portable `rgbds-win64.zip` on `gbdev/rgbds` releases — **no installer, no PATH changes**; unzip
  it and put its `bin/` on `PATH` for the build only.
- **Build must run inside the msys2 shell**, the same one the pokeemerald section above describes.
  This is the single trap worth knowing, because **its symptom looks like a broken compiler rather
  than a wrong shell**: run from Git Bash, `gcc` fails with `no include path in which to search for
  stdio.h` on every standard header, because msys2's `gcc` resolves `/usr/include` against
  whichever shell's root it is running under. `pokecrystal` builds host tools from `tools/*.c`
  before it assembles anything, so this failure surfaces indirectly as ~2000 `INCBIN` errors about
  missing `.2bpp` graphics — the real cause is several steps upstream of the visible error.
- Build: plain `make`. Takes ~80 s. **`make -j8` is fine** — parallelism was briefly suspected of
  racing the graphics generation, and it does not.
- Output: `pokecrystal.gbc` and `pokecrystal.sym` (~1.9 MB) in the repo root. Grep the `.sym` for a
  label to get its address, in `bank:offset` form since GB WRAM is banked. No rebuild is needed to
  look up a further symbol from an already-built tree.
- Verification gate: the built ROM's SHA1 must equal the ROM being played. For V1.0 that is
  `f4cd194bdee0d04ca4eac29e09b8e4e9d818c133`. `pokecrystal` also builds V1.1, an Australian
  release and two PS3 VC images, each with a different hash — **addresses do not transfer between
  revisions**.
- Repo location: `C:\dev\pokecrystal` — see the shared layout note below.

## Pokémon decomp workspace layout — 2026-08-17

All decomps are **siblings under `C:\dev`, outside `C:\dev\MeshGhost` on purpose**, keeping
unlicensed Nintendo-derived source out of this repo's tree (`agent_docs/licensing.md`). Placed
there on the user's explicit instruction, 2026-08-17.

| Path | Game(s) | Toolchain | Built & hash-verified |
| --- | --- | --- | --- |
| `C:\dev\pokeemerald` | Emerald | agbcc | yes (2026-08-11) |
| `C:\dev\pokecrystal` | Crystal | rgbds | yes (2026-08-17) |
| `C:\dev\pokered` | **Red and Blue both** | rgbds | yes (2026-08-17) |
| `C:\dev\pokefirered` | FireRed (also builds LeafGreen) | agbcc | yes (2026-08-17) |
| `C:\dev\pokeplatinum` | Platinum (**WIP decomp**) | blocked — see below | **no, cloned only** |
| `C:\dev\agbcc` | — (GBA compiler) | — | prebuilt, shared |
| `C:\dev\rgbds` | — (GB assembler, v1.0.3) | — | portable, no install |

- **`rgbds` is portable and shared** — unzipped, not installed. Put `C:\dev\rgbds\bin` on `PATH`
  for a build; it changes nothing globally.
- **`agbcc` is shared and already built.** To use it for a new GBA decomp, run
  `./install.sh ../<decomp>` from `C:\dev\agbcc` inside the msys2 shell — it copies into that
  tree's `tools/agbcc`. Done for pokefirered 2026-08-17; no rebuild of agbcc was needed.
- **Everything above builds in devkitPro's msys2 shell**, and the wrong-shell trap described in the
  pokecrystal section applies to all of them equally.
- Build times with `-j8`: pokered ~2 min, pokecrystal ~1.5 min, pokefirered ~3.5 min.
- **`C:\dev\pokeplatinum` (Platinum, NDS) is cloned but NOT built** (2026-08-17, 236 MB), on the
  user's call that a WIP decomp is worth having on disk regardless. Being C, its headers are
  readable as-is for struct layouts and names — a spot check found `FieldSystem`,
  `BerryPatchManager` and `TownMapContext` properly named, alongside undecompiled `sub_<address>`
  functions. **Absolute addresses still need a build**, which is what is blocked — it cannot be built
  with what is installed. Its deps need a standalone MSYS2 or WSL, since devkitPro's msys2 carries
  no mingw64/ucrt64 repos. It is also a WIP decompilation rather than a complete one. See
  `verified.md` for the detail; decide before installing anything for it.

## Unity / TEVI, UE5 / Pseudoregalia (Phase 6 onward)

- TEVI IL2CPP vs Mono: **confirmed Mono**, originally 2026-08-11, **re-confirmed 2026-08-12
  against the current on-disk build** (see version stamp below — the install had updated between
  checks). Install at `C:\Program Files (x86)\Steam\steamapps\common\TEVI`.
  `TEVI_Data\Managed\Assembly-CSharp.dll` is present (IL2CPP builds strip managed assemblies and
  ship `GameAssembly.dll` instead, which is absent here); `doorstop_config.ini` has a
  `[UnityMono]` section, not `[UnityIL2CPP]`. So BepInEx/Harmony tooling applies directly — no
  `Il2CppInterop`/unhollowed-assembly step needed.
- **Game version stamp (2026-08-12):** `TEVI.exe` and `UnityPlayer.dll` dated 2026-07-16,
  `Assembly-CSharp.dll` dated 2026-07-09. Any fact read from `Assembly-CSharp.dll` (Phase 6.2
  onward) should cite this stamp, the same way Emerald facts cite the ROM hash — a future game
  update makes it obvious what needs re-checking. BepInEx's own log conveniently carries this
  stamp too: its header line's timestamp (`BepInEx 5.4.23.3 - TEVI (7/16/2026 3:00:23 AM)`)
  matches `TEVI.exe`'s file date exactly.
- **Unity version: confirmed `2021.3.25f1` (build `68ef2c4f8861`)**, read directly from
  `UnityPlayer.dll`'s own file-version metadata (`Get-Item ... | .VersionInfo`), not from a
  modding tool's reference-package choice. Use `2021.3.25` for `UnityEngine.Modules` when
  building a plugin against this install.
- BepInEx installed on this TEVI copy because of the **`Tevi Randomizer` mod — the Archipelago
  integration for TEVI, `BlackSoulKnight/Tevi_Randomizer`** — not something MeshGhost set up.
  Confirmed working, not just present: after updating both the game and the randomizer
  (2026-08-12) and launching TEVI once to the main menu, `BepInEx/LogOutput.log` reads cleanly —
  BepInEx 5.4.23.3, `Running under Unity v2021.3.25.6876972`, CLR `4.0.30319.42000`, `Supports
  SRE: True`, `Loading [Randomizer 1.6.1]` → `Chainloader startup complete`, no errors or
  warnings. This is the known-good "before MeshGhost touched anything" baseline log, and proves
  Harmony-based patching works against this exact install rather than just being theoretically
  compatible. See `agent_docs/licensing.md` for the randomizer's own (separate, MIT) license.
- Assembly inspector for reading `Assembly-CSharp.dll` facts (Phase 6.2): **`ilspycmd`**
  (ILSpy's CLI decompiler), installed 2026-08-12 via `dotnet tool install -g ilspycmd`
  (v10.1.1.8388). Chosen over a GUI tool (dnSpy/ILSpy GUI/dotPeek) specifically so the agent can
  read decompiled source directly via the CLI rather than relaying findings through the user —
  same role `pokeemerald.map`/`.sym` play for Emerald. MIT-licensed, see
  `agent_docs/licensing.md`; not a MeshGhost dependency, a local dev tool only.
- Pseudoregalia install: `C:\Program Files (x86)\Steam\steamapps\common\Pseudoregalia`
  (confirmed 2026-08-12 via a Steam-library directory scan).
- **Launching `dev-scripts\*.bat` headlessly (agent-run scaffolding).** The scripts are written
  for a human double-click, and two properties of that fight automation: they invoke
  `..\meshghost.exe`, which is **relative to the working directory, not to the script**, and they
  end in `pause`, which blocks forever on an attached stdin. What works from PowerShell:

  ```powershell
  Start-Process -FilePath "$env:ComSpec" `
    -ArgumentList '/c','C:\dev\MeshGhost\dev-scripts\run-relay-loopback.bat' `
    -WorkingDirectory 'C:\dev\MeshGhost\dev-scripts' `
    -RedirectStandardOutput '...\relay-live.log' -PassThru -WindowStyle Hidden
  ```

  Three things that do **not** work, each failing unhelpfully: a bare script name in
  `-ArgumentList` (cmd reports `not recognized as an internal or external command` even with
  `-WorkingDirectory` set); `'cd /d <dir> && script.bat'` as one argument (the `&&` does not
  survive Start-Process's argument handling, and the error again names the script rather than the
  parse); and plain `cmd` instead of `$env:ComSpec`, which on this machine is a devkitPro
  document rather than an interpreter (see `pitfalls.md`). Found live 2026-08-17, four attempts.
- **Deploying Pseudoregalia for a live test — TWO artifacts, not one.** Everything the mod needs
  sits in one folder, `…\Pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo\`:
  - `dlls\main.dll` ← `dev-scripts\build-pseudoregalia.bat` output, staged under
    `packaging\release\games\pseudoregalia\…\MeshGhostPseudo\dlls\main.dll`
  - `meshghost.exe` ← the repo-root client, rebuilt with `go build -o meshghost.exe ./cmd/meshghost`
  - `config.json` — the mod's OWN client settings (`connect_to`, `transport`, `room`, `interp`).
    Not the release-folder `config.json`; the mod starts the client and points it at this one.

  **Copying only the DLL is the mistake to avoid**, and it fails in a way that does not look like
  a stale binary: the mod logs `bridge: connected=false connect_attempts=N` forever and no ghost
  ever appears, because the client it autostarts is a different build (or missing) rather than
  wrong. Found live 2026-08-17 — the installed `meshghost.exe` was a day old while `main.dll` was
  minutes old. The tell is `connect_attempts` climbing with `send_ok=0` in `UE4SS.log`, plus **no
  `meshghost` process and no client log in the mod folder** (the client writes its log beside
  itself on startup, so its absence means it never started).
- **SteamCMD**: `C:\dev\steamcmd\steamcmd.exe`, outside `C:\dev\MeshGhost` on purpose (a
  standalone tool, not repo content). `+download_depot` ignores `+force_install_dir` — it always
  lands under `steamcmd`'s own `steamapps\content\app_<id>\depot_<id>\` and has to be copied out
  manually. Logging into it with a real account signs that account's normal Steam client offline
  (Steam allows one online session per account) — expect the regular Steam client to need
  reconnecting afterward. No login is cached between sessions on this machine by choice (the
  folder gets wiped after use rather than storing credentials).
- **Standalone TEVI build for local dual-instance testing**: `C:\dev\tevi-14778703` (SteamDB
  build `14778703`, 2024-06-20, depot `2230651`, manifest `7992513181981867642`) — outside
  `C:\dev\MeshGhost` for the same reason as the SteamCMD tool. Needs a `steam_appid.txt`
  (containing `2230650`) at its root for `steam_api64.dll` to initialize when launched outside
  Steam. An earlier build, `C:\dev\tevi-v1.01-test` (buildid `12996163`), was tried first, didn't
  work, and has since been **fully removed from disk** (2026-08-14) — `14778703` above is the
  only standalone build now in use; don't reference the removed one as if it's still present.
  See
  `agent_docs/verified.md`'s "TEVI build 14778703 allows two simultaneous local instances" entry
  and `agent_docs/phases/phase6.md`'s Notes for how this enables 6.6 (two real players) without a
  second machine.
- **Engine: confirmed UE 5.1** (`++UE5+Release-5.1-CL-23901901`), read directly as a UTF-16
  string embedded in `pseudoregalia\Binaries\Win64\pseudoregalia-Win64-Shipping.exe`
  (2026-08-12) — not assumed from UE4SS's stated 4.12–5.7 support range. Shipping exe/game
  binary dated 2025-04-26 at that check.
- **UE4SS version: confirmed `v3.0.1 Beta #0`, Git SHA `733e5969`** (`ue4ss\UE4SS.log` header,
  2026-08-12), installed under the newer `pseudoregalia\Binaries\Win64\ue4ss\` layout (mods
  live in `ue4ss\Mods\`, listed via both `mods.txt` and `mods.json`). This closes the
  previously-unfilled line. **Superseded an earlier same-day reading** of `v2.5.2 Beta #0` /
  SHA `a267c64` at the old flat `Binaries\Win64\` layout — the user updated their local UE4SS
  install mid-session to match a Mar 2026 update to the `pseudoregalia-archipelago` repo (its
  `.gitmodules` pins `RE-UE4SS @ 733e596`, matching the new SHA exactly). **Any Pseudoregalia
  adapter work must target v3.0.1 and the `ue4ss\` layout, not v2.5.2** — re-check
  `ue4ss\UE4SS.log` before assuming this hasn't drifted again. **This line is currently known
  stale, not just theoretically at risk**: `agent_docs/verified.md`'s "MeshGhostPseudo survives
  an AP_Randomizer reinstall that silently swaps the shared UE4SS runtime" entry records that a
  2026-08-13 `AP_Randomizer` reinstall rewrote the *shared* `UE4SS.dll`/`dwmapi.dll`/
  `UE4SS-settings.ini` to a different build (different size and SHA-256) — and that the
  `UE4SS.log` banner confirming `v3.0.1`/`733e5969` above was read from a session that predates
  that swap, so it does **not** identify whatever build is actually installed now. Re-read
  `ue4ss\UE4SS.log`'s banner fresh before trusting this line for any real work — don't assume
  it from this entry.
- Coexisting mod, confirmed working: **`AP_Randomizer`**, a UE4SS **C++** mod (not Lua) —
  `ue4ss\UE4SS.log` reads `Mod 'AP_Randomizer' has enabled.txt, starting mod.`. Its mod folder
  (`ue4ss\Mods\AP_Randomizer\dlls\`) ships `main.dll`, `libssl-3-x64.dll`,
  `libcrypto-3-x64.dll`, `zlib.dll`, and `cacert.pem` — i.e. it holds a live TLS/websocket
  connection to an Archipelago server from inside a UE4SS C++ mod, confirmed proof that C++
  mods can hold real sockets in this exact game/UE4SS combination. This is the load-bearing
  fact behind Phase 7's "C++ for the shipping adapter" decision (`plans.md`).
- Lua sockets: **reachable after all, via `package.loadlib`** — UE4SS's embedded Lua 5.4 has no
  first-party socket library (zero `luasocket` references in the RE-UE4SS repo, no networking/
  `io` capability documented at docs.ue4ss.com), but `package.loadlib` is a real, callable
  function, and a real connect/send/receive round trip against the actual bridge protocol was
  live-confirmed working via the vendored `lua54.dll`/`socket-windows-5-4.dll` pair
  (`MeshGhostSocketProbe`/Stage 3, `agent_docs/verified.md`). The eventual C++-for-the-shipping-
  adapter decision (`agent_docs/phases/phase7.md`'s 7.6) was **not** about sockets being
  unreachable from Lua — it was a real binary-compatibility bug in that same vendored socket
  pair that only surfaced under 7.5's sustained real 10Hz two-way traffic (83-98% of received
  lines failing to decode), never under a one-shot probe's light traffic. See
  `agent_docs/risks.md`'s `package.loadlib` entry for the full evidence trail.
- Discovery tooling already present, usable for the 7.1 Lua probe: `ActorDumperMod`,
  `ConsoleEnablerMod`, `ConsoleCommandsMod`, `LineTraceMod`, `BPModLoaderMod` (`ue4ss\Mods\`
  listing, 2026-08-12).

## Running the scaffolding for a local test — keep it hidden

**User preference, 2026-08-18.** When starting the relay, a core, or any other helper process for a
local/dev test, **start it hidden and redirect its output to a log**, then read the log. Never leave
a console window per process on the user's screen.

```powershell
Start-Process -WindowStyle Hidden -FilePath ".\meshghost-relay.exe" `
  -ArgumentList "-loopback","-send-hz=100" `
  -RedirectStandardOutput "relay.log" -RedirectStandardError "relay.err.log"
```

Two reasons, and the second is the one that matters:

- **The window is pure clutter.** Its output is already going to the log, so the window shows
  nothing the log does not.
- **The user is mid-test.** Windows appearing over a running game interrupt the exact thing the
  scaffolding exists to support, and the user has to move or minimise them before playing.

**Read the log to confirm startup** — `CLAUDE.md` already requires confirming the relay/core came up
and chose the right transport, and hiding the window does not relax that. It is the log that
proves it either way; the window never did.

Live case: two visible consoles appeared over a Crystal session on 2026-08-18, which is what
prompted the preference.

## Onboarding checklist

All done on this machine — kept as the checklist a fresh setup should still follow:

- [x] Confirm the project is checked out to `C:\dev\MeshGhost`.
- [x] Install and record a Go toolchain version here (see "Host" above).
- [x] Install and verify a supported BizHawk build; record its version here (see "BizHawk /
      Emerald" above).
- [x] Confirm the correct Emerald ROM revision and record the expected map/format notes.
- [x] Set up BizHawk Lua scripting and verify access to the Lua console.

## Workspace conventions

- The project lives in `C:\dev\MeshGhost`.
- Do not access outside authorized directories unless explicitly approved.
- Record any non-default environment tweaks here, factually and version-specific.
- **BizHawk Lua CAN start a process with NO window — via `luanet`, not `os.execute`
  (2026-08-18).** This unblocks autostart for both Pokemon adapters, which was previously assumed
  impossible because every shell route flashes.
  - **`os.execute` and `io.popen` always flash, in every shape.** Tried plain, `start /b`,
    `powershell -WindowStyle Hidden`, and `wscript.exe` running a hidden-`Run` `.vbs`; the user
    watched all of them and every one showed a window. The reason they all fail is the same: both
    functions go through the C runtime's `system()`, which runs `cmd /c ...`, so **the window
    belongs to the shell doing the launching, not to the child** — which is why hiding the child
    cannot help, and why `-WindowStyle Hidden` flashed *longest* (PowerShell is slow to start).
  - **The build has no process API of its own.** Enumerated every global: `client`, `emu`, `comm`,
    `bizstring` contain nothing that starts a program. (`client.getluafunctionslist` does NOT exist
    in this build; walk `_G` instead.)
  - **`luanet` is in `_G`** — NLua's .NET bridge. `luanet.load_assembly("System")` first (without
    it `import_type` returns nil, which is what made the first attempt look like a dead end), then
    `luanet.import_type("System.Diagnostics.Process")` and `...ProcessStartInfo`. Set
    `UseShellExecute = false` and `CreateNoWindow = true`.
  - **Confirmed invisible by the user, against a positive control**: three spaced spawns —
    hidden `cmd.exe`, hidden `meshghost.exe`, then a deliberate window-showing
    `Process.Start(file, args)` — observed as "hidden, hidden, show", with all three verified to
    have actually run via marker files. The control is what makes the two silences mean something.
  - `Process.GetCurrentProcess().Id` comes with it, so a Lua adapter can pass
    `-exit-with-pid=<EmuHawk's pid>` and get auto-close for free, the same way TEVI and
    Pseudoregalia do.
  - Probe: `dev-scripts/bizhawk-spawn-probe.lua`.
