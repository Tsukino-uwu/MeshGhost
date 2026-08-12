# Environment

Exact tools, versions, and configuration known to work for this project. Unfilled until
Phase 1 actually sets up BizHawk — do not pre-fill version numbers from memory.

## Host

- OS: Windows 11 Pro (dev machine). Cross-platform build targets: Windows, Linux, macOS —
  not yet built or tested on the latter two.
- Go toolchain: **confirmed installed**, `go1.26.5 windows/amd64` (`go version`, 2026-08-11).
  `go build ./...` and `go vet ./...` both pass clean on the current type skeleton.
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
- **Building a real UE4SS C++ mod is blocked regardless of the above**: RE-UE4SS's core
  `UE4SS` CMake target hard-depends on a private submodule (`deps/first/Unreal`,
  `Re-UE4SS/UEPseudo` — confirmed private, `gh api` 404), and no official release ships a
  prebuilt import library to link against instead. See `agent_docs/risks.md` and
  `agent_docs/phases/phase7.md` for the full investigation. CMake/MSVC being installed was
  necessary but not sufficient.

## BizHawk / Emerald (to fill during Phase 1)

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
  two-instance testing.
- Archipelago coexistence: confirmed 2 Lua scripts (`ButtonCount`, `Connector`) can run
  concurrently in BizHawk's Lua Console without conflict (2026-08-11) — satisfies
  `phase1.md`'s first coexistence checklist item, though it should be re-checked later with
  the actual `connector_bizhawk_generic.lua` rather than these placeholder scripts.
- Lua socket support (Phase 3): BizHawk's own `comm.*` (`CommLuaLibrary`) is present in this
  2.11 build but uses length-prefixed framing, not NDJSON — inspected directly via
  `BizHawk.Client.Common.dll`'s embedded doc strings (2026-08-11), not used. LuaSocket
  (vendored, `adapters/pokemon/emerald/lib/x64/socket-windows-5-4.dll`) is used instead — see
  `agent_docs/licensing.md` and the Phase 3 ADR in `architecture.md`.
- BizHawk's Lua host (`LuaLibraries.cs`, confirmed by reading source 2026-08-11) is a plain
  `new Lua()` (NLua) with no standard library removed afterward — `debug`, `os`, `package`,
  `io` are all available to a script, not just the subset BizHawk's own libraries use.

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
  `ue4ss\UE4SS.log` before assuming this hasn't drifted again.
- Coexisting mod, confirmed working: **`AP_Randomizer`**, a UE4SS **C++** mod (not Lua) —
  `ue4ss\UE4SS.log` reads `Mod 'AP_Randomizer' has enabled.txt, starting mod.`. Its mod folder
  (`ue4ss\Mods\AP_Randomizer\dlls\`) ships `main.dll`, `libssl-3-x64.dll`,
  `libcrypto-3-x64.dll`, `zlib.dll`, and `cacert.pem` — i.e. it holds a live TLS/websocket
  connection to an Archipelago server from inside a UE4SS C++ mod, confirmed proof that C++
  mods can hold real sockets in this exact game/UE4SS combination. This is the load-bearing
  fact behind Phase 7's "C++ for the shipping adapter" decision (`plans.md`).
- Lua sockets: **not available** — zero `luasocket` references found in the RE-UE4SS repo
  (`gh api search/code`, 2026-08-12) and the Lua API docs (docs.ue4ss.com) list no networking,
  `io`, or binary-module-loading capability. A Lua mod can discover state fast (no build step)
  but cannot itself dial the MeshGhost bridge — confirms the Lua-probe/C++-adapter split.
- Discovery tooling already present, usable for the 7.1 Lua probe: `ActorDumperMod`,
  `ConsoleEnablerMod`, `ConsoleCommandsMod`, `LineTraceMod`, `BPModLoaderMod` (`ue4ss\Mods\`
  listing, 2026-08-12).

## Onboarding checklist

- Confirm the project is checked out to `C:\dev\MeshGhost`.
- Install and record a Go toolchain version here.
- Install and verify a supported BizHawk build; record its version here.
- Confirm the correct Emerald ROM revision and record the expected map/format notes.
- Set up BizHawk Lua scripting and verify access to the Lua console.

## Workspace conventions

- The project lives in `C:\dev\MeshGhost`.
- Do not access outside authorized directories unless explicitly approved.
- Record any non-default environment tweaks here, factually and version-specific.
