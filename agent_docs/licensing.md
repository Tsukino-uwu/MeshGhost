# Licensing and third-party audit

The brief is explicit and loud about this: everything in MeshGhost is our own code. Nothing
here is copied from the prior-art projects the brief points at. This file exists so that
claim stays checkable instead of resting on memory.

**Standing rule: read a project's license before reading its source, and record the result
here before consulting that project for anything.** If a project isn't in the table below,
its license hasn't been checked yet — do not use it as a reference until it is.

**Standing rule: facts and addresses, never code.** Reading a decompilation or another
project's source to learn *where a value lives* (a memory offset, a struct layout, a hook
point) and then writing our own implementation from that understanding is the normal way
this kind of project gets built. Copying source text, data tables, asset files, or
structurally-identical code is a different act and is not permitted regardless of a
project's license terms, unless that license explicitly allows redistribution and the
copied portion is attributed per its terms.

Checked 2026-08-11, via the GitHub API and each repo's own license file — not from memory.

| Project | License | What this means for MeshGhost |
|---|---|---|
| [CelesteNet](https://github.com/0x0ade/CelesteNet) | MIT | Permissive. May read as a design reference. Do not copy source; MIT would technically allow it with attribution, but the brief's rule is stricter than the license requires — everything here is written from scratch. |
| [GhostMod](https://github.com/EverestAPI/GhostMod) | MIT | Same as above — CelesteNet's predecessor, same terms. |
| [Everest](https://github.com/EverestAPI/Everest) | MIT | Permissive. Not currently expected to be used (no source dependency), but if the Unity/UE tooling research ever needs to check how a mod loader hooks a game loop, this is a clean reference. |
| [MonoMod](https://github.com/MonoMod/MonoMod) | MIT | Permissive. Not a current dependency. If a future adapter needs C# IL patching, this could become an actual linked dependency rather than just a reference — re-verify at that point since a dependency has different obligations than a reference. |
| [HKMP](https://github.com/Extremelyd1/HKMP) | LGPL-2.1 | Copyleft, but LGPL specifically permits *linking* without forcing MeshGhost's own license to change, as long as HKMP's own code isn't statically embedded without complying with LGPL's relinking/disclosure terms. Not planned as a dependency — treated as read-only design reference only. |
| [SilklessCoop](https://github.com/nek5s/SilklessCoop) | CC BY-NC-SA + additional restrictions (custom, non-OSI) | **Restrictive. No commercial use, no redistribution or modification of source without the author's written permission.** Do not copy any code or asset from this project under any circumstance without separately obtaining that permission. Read-only design reference for understanding the *problem space* (Silksong co-op), not a source of implementation detail. |
| [bizhawk-co-op](https://github.com/TestRunnerSRL/bizhawk-co-op) (`TestRunnerSRL`) | LGPL-3.0 | Same posture as HKMP: copyleft, linking permitted under LGPL terms, not currently a dependency. Useful as a reference for BizHawk Lua socket patterns specifically because it's the brief's own cited prior art for that — read for the *approach*, write our own Lua. |
| Archipelago (`connector_bizhawk_generic.lua`) | MIT — confirmed 2026-08-11 by reading `C:\dev\Archipelago\LICENSE` directly (no per-subdirectory override LICENSE in `data/lua/`); GitHub's NOASSERTION badge does not reflect the repo's own LICENSE file. Re-check if this ever becomes a real dependency rather than a coexistence/reference check. | Permissive. Cited by the brief as a bridge-pattern reference only; MeshGhost's read-only Lua script runs alongside it in the same BizHawk Lua Console, not linked to or copying from it. |
| [pokeemerald](https://github.com/pret/pokeemerald) (decomp) | **None — no LICENSE file in the repo** | This is a decompilation of Nintendo's copyrighted Pokémon Emerald. There is no license grant making its source redistributable or reusable, decomp or not. **Consult it only to learn facts** — the address of a struct field, the name of a function, the shape of a data table — and write independent Lua that reads that memory location. **Never copy source text, data tables, or assets from it.** Every fact taken from pokeemerald and used in `verified.md` must cite the specific file and commit/line in pokeemerald as its source, per the brief's "no addresses from memory" rule — that citation is also what keeps this boundary auditable later. |
| [BizHawk](https://github.com/TASEmulators/BizHawk) | MIT | Permissive. Not a dependency — MeshGhost's adapter is a user-supplied Lua script run *inside* the user's own separately-installed BizHawk, never linked or redistributed. Referenced here because `adapters/emerald/*.lua` cite its `Lua/_docs_luacats/gui.d.lua` API docs and, from Phase 3, its bundled `comm.*` (`CommLuaLibrary`) socket API was inspected (2026-08-11, via the installed build's `BizHawk.Client.Common.dll` at `C:\ProgramData\Archipelago\Bizhawk\dll\`, not from memory) and *not* used — see the Phase 3 ADR in `architecture.md` for why LuaSocket was chosen instead. Also read directly (2026-08-11, `src/BizHawk.Client.Common/lua/LuaLibraries.cs`) to confirm the Lua host is a plain `new Lua()` (NLua) with no standard library removed afterward, before `phase3_loopback.lua` relied on `debug.getinfo` (for a script-relative path) being available. |
| [Lua](https://www.lua.org/) (PUC-Rio) | MIT | Permissive. **Vendored as a real dependency**, `adapters/emerald/lib/x64/lua54.dll` — needed because `socket-windows-5-4.dll` imports `lua54.dll` by name, and Windows' plain `LoadLibrary` (what `package.loadlib` calls) does not search the loading DLL's own directory for that dependency, so it must be pre-loaded explicitly by its own path (confirmed empirically 2026-08-11, see the Phase 3 ADR in `architecture.md`). This exact file is copied byte-for-byte from the user's own installed BizHawk (`C:\ProgramData\Archipelago\Bizhawk\dll\lua54.dll`, confirmed via matching SHA/MD5), not an independent build — deliberately, so the pre-loaded dependency binds to a build compatible with the one already running the script, not a merely similar one. Confirmed genuine, unmodified upstream Lua 5.4.4 by reading its embedded copyright string directly (`Copyright (C) 1994-2022 Lua.org, PUC-Rio`), not assumed. |
| [LuaSocket](https://github.com/lunarmodules/luasocket) (Diego Nehab) | MIT | Permissive, redistribution permitted with the copyright/permission notice retained. **Vendored as a real dependency starting Phase 3**, not just a reference: the compiled `socket-windows-5-4.dll` (and the accompanying `socket.lua` helper) let `adapters/emerald/*.lua` hold a non-blocking NDJSON TCP socket to the local bridge — see the Phase 3 ADR. License text confirmed 2026-08-11 by reading `luasocket.LICENSE.txt` directly at `C:\dev\Archipelago\data\lua\x64\`. **Binary provenance:** MeshGhost's copy of `socket-windows-5-4.dll` is the same compiled artifact already vendored there by the unrelated (MIT-licensed) Archipelago project, not an independent build from upstream LuaSocket source — deliberately, not from laziness: that specific binary is already confirmed working against this exact BizHawk 2.11 / Lua 5.4 install (`environment.md`'s Archipelago-coexistence entry), and rebuilding our own from source would risk a silent Lua-5.4 ABI mismatch against BizHawk's embedded `lua54.dll` with no error to catch it — the "ran without erroring is not evidence" trap `CLAUDE.md` warns about, applied to a binary instead of a memory address. This is redistribution of an unmodified MIT-licensed binary via an intermediary, permitted under MIT's terms with the notice retained (present in this repo alongside the `.dll`), not a copy of Archipelago's own code. |

## Assets

- **Never ship a ROM.** MeshGhost requires the user's own legally-obtained Emerald ROM;
  nothing in this repo or its releases includes one.
- **Never ship ripped sprites, textures, or audio** from any target game (Emerald, TEVI,
  Pseudoregalia, or the Ori titles). The Phase 2 ghost sprite is either original placeholder
  art authored for this project, or — if a more integrated look is wanted later — read from
  the user's own game data at runtime rather than bundled.
- Game names, engine names, and mod-tool names (BizHawk, BepInEx, UE4SS, etc.) are used
  descriptively to say what MeshGhost interoperates with. This is not a claim of affiliation
  with or endorsement by any of those projects or the games' rights holders.

## When this file needs an update

- Before adding any new project to the "prior art" or "tooling" list in `brief.md`.
- Before vendoring any third-party code or library as an actual dependency (as opposed to a
  read-only reference) — check its license fits alongside this project's MIT `LICENSE`
  *before* adding it, not after.
- If a cited project's license changes upstream — re-check before the next release.
