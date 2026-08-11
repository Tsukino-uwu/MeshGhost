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

## Unity / TEVI, UE5 / Pseudoregalia (to fill at Phase 6 and beyond)

- TEVI IL2CPP vs Mono: unconfirmed. Verify before assuming BepInEx/Harmony tooling applies.
- UE4SS version for Pseudoregalia: unfilled.

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
