# Licensing and third-party audit

The brief is explicit and loud about this: everything in MeshGhost is our own code. Nothing
here is copied from the prior-art projects the brief points at. This file exists so that
claim stays checkable instead of resting on memory.

**Standing rule, and the one the others serve: this repo contains only what may be public.**
The test applied here is not "does some license permit this?" but **"is this fine sitting in a
public repo forever?"** — and anything that is no, or merely unclear, stays out even where a
license would arguably allow it. That is **deliberately stricter than the licenses require**, on
purpose: it means the repo never depends on a judgement call about someone else's terms holding up
later. Reading a reference to learn facts is unaffected; what is constrained is what the repo
*contains*. `pokeemerald` is the worked example — consulted throughout Emerald's development, and
not one byte of it is here.

**How to check that rule still holds** — mechanical, and worth running before a release or after
adding any binary. Both must come back clean:

```sh
# 1. Nothing game-derived tracked. Must print nothing.
git ls-files | grep -Ei '\.(rom|gba|gbc|nds|iso|pak|uasset|umap|pdb|dmp|sav)$|assembly-csharp'

# 2. Every tracked DLL must be our own build output or a permissive dependency
#    shipping its LICENSE alongside. Read the list; there is no rule that can check intent.
git ls-files '*.dll'
```

As of 2026-08-16 that second list is six files: two LuaSocket/Lua binaries, UE4SS's `UE4SS.dll` and
`dwmapi.dll` (MIT, `LICENSE` committed beside them), and our own `MeshGhostTevi.dll` and
Pseudoregalia `main.dll`. No game-derived binary has ever been tracked.

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

[access-models.md](access-models.md)'s "What any of this means for a PUBLIC repo" applies that rule
per approach — what may be committed and what may not, for each way of reading a game — plus the two
things that sit outside copyright entirely (EULA reverse-engineering clauses, and anti-circumvention
rules where DRM is involved). Read it when starting a new game; this file stays the authority.

**Standing rule: an adapter's `documentation.md` is facts-from-observation, and is cleared for a
public repo on that basis.** Assessed 2026-08-17, on the user's question, for
`adapters/pseudoregalia/documentation.md`; the finding generalises to every adapter's copy, and the
rule is restated at the top of that file and in `adapters/_template/documentation.md`.

- **What it may contain**: values measured from a running copy of a game the reader owns — numbers,
  timings, field and function *names*, which component moves what, how states relate. **Facts are
  not copyrightable**, and short identifiers carry no copyright of their own. This is the same
  "facts, never code" posture as the rows below, applied to the game itself rather than to a
  third-party project, and it is what every modding wiki consists of.
- **What it may never contain**: game source, decompiled or disassembled output, asset content or
  extracted strings, or **verbatim reflection/memory dumps**. The dump is the line that matters and
  it is a real one: a dump is bulk copying of the game's own data, where a hand-written description
  of the same mechanism is an independent work. `CLAUDE.md` already forbids dumps repo-wide; this
  says why it also matters for prose.
- **Trademark**: naming a game or character in order to describe it is ordinary nominative use.
- **What is NOT settled by any of the above, and is not a copyright question at all**: a game's own
  EULA may restrict reverse engineering, which is contract rather than copyright — see
  `access-models.md`. Documenting behaviour adds no exposure beyond running the adapter that
  observes it, so this file never *creates* that question; it inherits whatever answer the adapter
  already has.
- **Audit check** (the same shape as the two greps above — verifies content, not intent):

```bash
# An adapter's documentation.md must carry a provenance line, the facts-not-expression guard,
# and no dump-shaped content. Scoped to adapters/ deliberately: docs/networking.md is the Go
# side's own doc, describes code we wrote, and none of this applies to it.
git ls-files 'adapters/**/documentation.md' | xargs grep -LiE 'measured from a running game'
git ls-files 'adapters/**/documentation.md' | xargs grep -LF 'Explain facts; never reproduce expression'
git ls-files 'adapters/**/documentation.md' | xargs grep -nE '[0-9A-F]{16,}|\.uasset|Assembly-CSharp'
```

Both must print nothing. The second is a heuristic, not a proof: long hex runs catch pasted GUIDs
and dumped identifiers, and the two filenames catch asset/assembly content pasted in. A clean run
means nothing obviously dump-shaped got in; reading the file is still what confirms it.

**Standing rule: every entry below is a snapshot, not a permanent guarantee.** Each row
records what a project's license *was, as of the date noted in that row* — not a fact that
holds forever. A project can relicense upstream at any time. Being listed here means "checked
as of this date," not "cleared for all future use" — re-check an entry before relying on it
again if meaningful time has passed or the intended use has changed (e.g. moving from
read-only reference to actually vendoring code), not only reactively if a change happens to be
noticed. Always re-check every entry before cutting a release regardless.

Most rows below carry their own "Checked" note with a specific date; where one doesn't, it
inherited the 2026-08-11 batch check (GitHub API + each repo's own license file, not from
memory) that first populated this table.

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
| Archipelago's `pokemon_emerald` world (`worlds/pokemon_emerald/`) | MIT, own copyright (`Copyright (c) 2023 Zunawe`) — a **separate, per-directory LICENSE file**, distinct from the repo-root MIT above; checked 2026-08-14 by reading `C:\dev\Archipelago\worlds\pokemon_emerald\LICENSE` directly. | Permissive. Consulted for facts only (what the Emerald randomizer's ROM patch and live BizHawk client actually do to RAM/ROM, for the Archipelago-coexistence risk in `risks.md`) — `rom.py`/`client.py`/`docs/rom_changes_en.md` read for that purpose, no code copied. |
| [pokeemerald](https://github.com/pret/pokeemerald) (decomp) | **None — no LICENSE file in the repo** | This is a decompilation of Nintendo's copyrighted Pokémon Emerald. There is no license grant making its source redistributable or reusable, decomp or not. **Consult it only to learn facts** — the address of a struct field, the name of a function, the shape of a data table — and write independent Lua that reads that memory location. **Never copy source text, data tables, or assets from it.** Every fact taken from pokeemerald and used in `verified.md` must cite the specific file and commit/line in pokeemerald as its source, per the brief's "no addresses from memory" rule — that citation is also what keeps this boundary auditable later. |
| [pokecrystal](https://github.com/pret/pokecrystal), [pokered](https://github.com/pret/pokered), [pokefirered](https://github.com/pret/pokefirered), [pokeplatinum](https://github.com/pret/pokeplatinum) (decomps) | **None — no LICENSE file in any of them** | Checked 2026-08-17 via `gh api repos/pret/<name>` for all four; each reports `"license": null`, the same result the `pokeemerald` row above records. `pret` is a single org doing all the Pokémon decompilations, so **one posture covers the whole family** and a new one needs only a date-check, not a fresh assessment. Identical handling to `pokeemerald`: **consult only to learn facts** — an address, a label name, a struct layout — and write independent code from that understanding. **Never copy source text, data tables, or assets.** Every fact used must cite the specific file (and for GB titles, the built `.sym`) as its source. **One structural difference from `pokeemerald` worth knowing before starting a GB/GBC adapter:** the GB games' RAM labels live in floating `SECTION`s (`ram/wram.asm` declares e.g. `SECTION "More WRAM 1", WRAMX` with no address), so **addresses do not exist in the source at all** and only appear at link time — the decomp must actually be *built* to produce `pokecrystal.sym`. Confirmed 2026-08-17 by building `pokecrystal` at `master` with rgbds v1.0.3 (the version its own `INSTALL.md` pins), which yielded `pokecrystal.gbc` + a 1.9 MB `pokecrystal.sym`. Build performed in a scratch directory outside the repo; neither the ROM nor the `.sym` is committed, per the assets rule below. **`pokered` and `pokefirered` were likewise built 2026-08-17**, each producing a ROM byte-identical to the user's own copy (`pokered` yields Red *and* Blue from one build). All four decomps now live as siblings under `C:\dev`, never in this repo — see `environment.md` for the layout and `verified.md` for the hashes and addresses. `pokeplatinum` is **not** built; note also that it self-describes as a **WIP** decompilation, unlike the other four, so its coverage should be checked rather than assumed. |
| Archipelago's `pokemon_rb` world (`worlds/pokemon_rb/`) | MIT, own copyright (`Copyright (c) 2022-2023 Alex "Alchav" Avery`) — a **separate, per-directory LICENSE file**, same pattern as the `pokemon_emerald` row above; checked 2026-08-17 by reading `C:\dev\Archipelago\worlds\pokemon_rb\LICENSE` directly. | Permissive. Consulted for **one structural fact only** (2026-08-17): that it handles Red and Blue as a single world with shared logic but ships two separate ROM patches (`basepatch_red.bsdiff4`, `basepatch_blue.bsdiff4`). Used as corroboration for the independently-derived symbol-diff finding in `verified.md` that Red and Blue share every WRAM address. No code read beyond that, none copied. |
| [Archipelago-Crystal](https://github.com/gerbiljames/Archipelago-Crystal) (`gerbiljames`, branch `pokecrystal-develop`) — an Archipelago fork carrying a `worlds/pokemon_crystal_prerelease` world | MIT at the repo root (Archipelago's own licence, `Copyright (c) 2017 LLCoolDave` et al.), **and** a separate MIT per-directory LICENSE on the Crystal world itself (`Copyright (c) 2024 AliceMousie`, `Copyright (c) 2025 gerbiljames`). | Checked 2026-08-17. **A third instance of the badge-vs-file gap** already recorded for the Archipelago and GBA-PK rows: `gh api repos/gerbiljames/Archipelago-Crystal` reports `"license": "NOASSERTION"`, while both actual LICENSE files are plainly MIT. Resolved the same way — by fetching and reading the files. Treat the GitHub badge as a hint, never as the check. Permissive, but **not yet read for anything**: recorded ahead of need so that a Crystal adapter has a pre-cleared reference, and because Archipelago-coexistence is a live concern for every Pokémon adapter (the Emerald precedent in `risks.md`). Being a prerelease world on a fork, re-check both the licence and the branch before relying on it. |
| [BizHawk](https://github.com/TASEmulators/BizHawk) | MIT | Permissive. Not a dependency — MeshGhost's adapter is a user-supplied Lua script run *inside* the user's own separately-installed BizHawk, never linked or redistributed. Referenced here because `adapters/bizhawk/pokemon/emerald/*.lua` cite its `Lua/_docs_luacats/gui.d.lua` API docs and, from Phase 3, its bundled `comm.*` (`CommLuaLibrary`) socket API was inspected (2026-08-11, via the installed build's `BizHawk.Client.Common.dll` at `C:\ProgramData\Archipelago\Bizhawk\dll\`, not from memory) and *not* used — see the Phase 3 ADR in `architecture.md` for why LuaSocket was chosen instead. Also read directly (2026-08-11, `src/BizHawk.Client.Common/lua/LuaLibraries.cs`) to confirm the Lua host is a plain `new Lua()` (NLua) with no standard library removed afterward, before `phase3_loopback.lua` relied on `debug.getinfo` (for a script-relative path) being available. |
| [Lua](https://www.lua.org/) (PUC-Rio) | MIT | Permissive. **Vendored as a real dependency**, `adapters/bizhawk/pokemon/emerald/lib/x64/lua54.dll` — needed because `socket-windows-5-4.dll` imports `lua54.dll` by name, and Windows' plain `LoadLibrary` (what `package.loadlib` calls) does not search the loading DLL's own directory for that dependency, so it must be pre-loaded explicitly by its own path (confirmed empirically 2026-08-11, see the Phase 3 ADR in `architecture.md`). This exact file is copied byte-for-byte from the user's own installed BizHawk (`C:\ProgramData\Archipelago\Bizhawk\dll\lua54.dll`, confirmed via matching SHA/MD5), not an independent build — deliberately, so the pre-loaded dependency binds to a build compatible with the one already running the script, not a merely similar one. Confirmed genuine, unmodified upstream Lua 5.4.4 by reading its embedded copyright string directly (`Copyright (C) 1994-2022 Lua.org, PUC-Rio`), not assumed. License text now also present alongside the binary at `adapters/bizhawk/pokemon/emerald/lib/x64/lua54.LICENSE.txt` (added 2026-08-11, matching the existing `luasocket.LICENSE.txt` treatment below), not just cited here in prose. |
| [LuaSocket](https://github.com/lunarmodules/luasocket) (Diego Nehab) | MIT | Permissive, redistribution permitted with the copyright/permission notice retained. **Vendored as a real dependency starting Phase 3**, not just a reference: the compiled `socket-windows-5-4.dll` (and the accompanying `socket.lua` helper) let `adapters/bizhawk/pokemon/emerald/*.lua` hold a non-blocking NDJSON TCP socket to the local bridge — see the Phase 3 ADR. License text confirmed 2026-08-11 by reading `luasocket.LICENSE.txt` directly at `C:\dev\Archipelago\data\lua\x64\`. **Binary provenance:** MeshGhost's copy of `socket-windows-5-4.dll` is the same compiled artifact already vendored there by the unrelated (MIT-licensed) Archipelago project, not an independent build from upstream LuaSocket source — deliberately, not from laziness: that specific binary is already confirmed working against this exact BizHawk 2.11 / Lua 5.4 install (`environment.md`'s Archipelago-coexistence entry), and rebuilding our own from source would risk a silent Lua-5.4 ABI mismatch against BizHawk's embedded `lua54.dll` with no error to catch it — the "ran without erroring is not evidence" trap `CLAUDE.md` warns about, applied to a binary instead of a memory address. This is redistribution of an unmodified MIT-licensed binary via an intermediary, permitted under MIT's terms with the notice retained (present in this repo alongside the `.dll`), not a copy of Archipelago's own code. |
| [BepInEx](https://github.com/BepInEx/BepInEx) | LGPL-2.1 | Checked 2026-08-12, via the GitHub API and by reading `LICENSE` directly. Copyleft, same posture as HKMP/`bizhawk-co-op` below: LGPL permits linking without forcing MeshGhost's own license to change. **Not vendored or redistributed.** The TEVI adapter (Phase 6) is a `BaseUnityPlugin` compiled against BepInEx's assemblies pulled from NuGet (`BepInEx.Core`) at build time; at runtime it loads into the user's own, separately-installed BepInEx (already present on this machine for an unrelated reason — the `Tevi Randomizer` mod, see below), the same "runs inside the user's own installed tool, never linked or redistributed" posture already recorded for BizHawk. |
| [Harmony](https://github.com/pardeike/Harmony) (`pardeike`, distributed as `0Harmony`/HarmonyX by BepInEx) | MIT | Checked 2026-08-12, via the GitHub API and by reading `LICENSE` directly (`Copyright (c) 2017 Andreas Pardeike`). Permissive. Same non-redistribution posture as BepInEx above — the TEVI adapter references `0Harmony.dll` from the user's BepInEx install to patch TEVI's own methods (e.g. hooking a position read), never ships a copy of it. |
| [Tevi_Randomizer](https://github.com/BlackSoulKnight/Tevi_Randomizer) (`BlackSoulKnight`) | MIT | Checked 2026-08-12, via the GitHub API and by reading the repo's own `LICENSE` directly (`Copyright (c) 2024 BlackSoulKnight`) — a distinct repo under its own license, **not** covered by Archipelago's MIT grant even though it's Archipelago's TEVI integration mod. Permissive, read-only design/approach reference only, not a dependency: it is the reason BepInEx is already installed and proven working on this machine (its own unrelated mod, not something MeshGhost set up), and its `Tevi_Randomizer.csproj` was read to learn the build approach for a TEVI BepInEx plugin (`netstandard2.0`, BepInEx/Unity pulled from NuGet rather than the user's install, game DLLs referenced by local `HintPath`) and one real class name (`SaveManager`) it Harmony-patches. Per the standing rule, only facts and approach were taken — no code copied. Also a live coexistence check for Phase 6: TEVI's own position-read adapter must be confirmed working both with this mod enabled and disabled, the same posture Archipelago's Lua connector required for Emerald. |
| [Assembly-CSharp.dll / UnityEngine.\*.dll / Newtonsoft.Json.dll / spine-unity.dll](../adapters/tevi/) (TEVI's own shipped game/engine assemblies) | Proprietary (TEVI) / various (Unity runtime, Newtonsoft, Spine) | Not checked as "prior art" — these are the target game's own compiled output, referenced the same way `pokeemerald`'s decomp is: **consulted only to learn facts** (a class name, a field, a method signature) via an assembly inspector, never to copy code. Referenced locally at compile time via relative `HintPath` from the user's own TEVI install; **never committed to the repo, never redistributed** — same "never ship game assets" posture as the Emerald ROM. |
| [ILSpy](https://github.com/icsharpcode/ILSpy) (`ilspycmd` CLI decompiler) | MIT | Checked 2026-08-12, via the GitHub API and by reading `LICENSE` directly (`Copyright (c) 2011-2025 AlphaSierraPapa for the ILSpy team`). Not a MeshGhost dependency at all — a `dotnet tool install -g` developer tool used to decompile the user's own local `Assembly-CSharp.dll` to text so the agent can read TEVI's real class/field names for Phase 6, the direct analogue of reading `pokeemerald.map`/`.sym` for Emerald addresses. Decompiled output is read for facts only and never committed; MeshGhost's own code is written independently from what it reveals, same "facts, never code" posture as `pokeemerald`. |
| [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) | MIT | Checked 2026-08-12, by reading the local `LICENSE` file shipped alongside the user's own installed copy (`...\Pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\LICENSE`, `Copyright (c) 2022 Narknon`) — not the GitHub API, since the install is what Phase 7 actually targets. Permissive. **Deliberate exception to the "runs inside the user's own separately-installed tool, never linked or redistributed" posture used for BizHawk/BepInEx**, decided 2026-08-13: unlike BepInEx (a well-known, easy-to-find tool most modded-game users already know how to get), UE4SS/RE-UE4SS is obscure enough that pointing users at a manual download was judged worse for onboarding than bundling it ourselves — and real breakage was already observed in Phase 7 from a UE4SS version mismatch, which bundling our own exact build eliminates. **Vendored as a real dependency starting the v0.2.0 release**, same posture as the LuaSocket entry below: `packaging/release/games/pseudoregalia/pseudoregalia/Binaries/Win64/` ships `UE4SS.dll` + `dwmapi.dll`, built from this repo's own pinned `RE-UE4SS` git submodule (`adapters/pseudoregalia/MeshGhostPseudo/RE-UE4SS`, currently **v3.0.1 Beta, Git SHA `733e5969`**) via `dev-scripts/stage-ue4ss-runtime.bat`, plus RE-UE4SS's own stock `assets/Mods/`, `UE4SS-settings.ini`, and its `LICENSE` file (MIT requires the notice travel with the binary — it does, at `ue4ss/LICENSE`). Not built from a separate download — every staged file traces to the one pinned submodule commit, and `.github/workflows/release.yml` gates a release on the committed binaries' hashes and the submodule pin still matching, so a moved pin without re-staging fails CI rather than shipping silently stale. **Restructured 2026-08-13** to mirror the real Steam install's own folder layout (`pseudoregalia/Binaries/Win64/...` instead of a flat `ue4ss-runtime/` staging folder), so the whole `pseudoregalia/` folder is one drag-and-drop into the user's install, matching how the Archipelago randomizer's own download works — no path/licensing change, just where the same files land in the repo and the shipped zip. |
| [pseudoregalia-archipelago](https://github.com/pseudoregalia-modding/pseudoregalia-archipelago) | **None — no LICENSE file; `gh api repos/.../pseudoregalia-archipelago` reports `"license": null`.** | Checked 2026-08-12, via `gh api` and a direct fetch (no LICENSE file found in the repo root or at a plausible `/LICENSE` path — 404). All rights reserved by default; there is no grant permitting reuse of its source, decomp-style or not. Same posture as `pokeemerald`: **consult only to learn facts** (which UE object holds the player, which UE4SS hook it uses, what its `.gitmodules` pins) and write independent code from that understanding. **Never copy source text or code structure from `AP_Randomizer/src` or `include`.** Its `.gitmodules` pins `RE-UE4SS @ 733e596` — this is what's read to confirm the target UE4SS version, not the version number alone from memory. Every fact taken from this repo and used in `verified.md` must cite the specific file/line, per the same rule as `pokeemerald`. |
| [pseudoregalia-multiplayer](https://github.com/highrow623/pseudoregalia-multiplayer) (`highrow623`) | MIT — confirmed 2026-08-14 via `gh api repos/highrow623/pseudoregalia-multiplayer/license` (`.license.spdx_id == "MIT"`, reading the repo's own `LICENSE` file, not just the repo metadata badge). | **Read 2026-08-15** (README, `docs/application-protocol.md`, `docs/project-anatomy.md`, `docs/todo.md`, and its repo tree via `gh api`) for facts/approach comparison only, per the standing "facts, never code" rule — no source or `.uasset` assets copied. Comparison notes and ideas worth acting on later are in `agent_docs/ideas.md`'s Pseudoregalia section, not duplicated here. |
| [GBA-PK-multiplayer](https://github.com/TheHunterManX/GBA-PK-multiplayer) (`TheHunterManX`) | CC BY-NC 4.0 (Attribution-NonCommercial) | Checked 2026-08-14 via `gh api repos/.../license` (GitHub reports `"license":"NOASSERTION"`/`"Other"`, the same "badge doesn't reflect the repo's own file" gap already noted for the Archipelago entry above — resolved by fetching and reading `LICENSE.md`'s actual text directly, not trusting the badge). Not a standard code license (no explicit source-redistribution/modification grant the way MIT/LGPL give one), and non-commercial-only. **Read-only design/approach reference, same posture as SilklessCoop and bizhawk-co-op**: consult for facts and technique (how it approaches GBA Pokémon multiplayer over BizHawk Lua) — never copy source text, and never anything beyond non-commercial reference given the license's own scope. |
| [godot-mod-loader](https://github.com/GodotModding/godot-mod-loader) (`GodotModding`) | **CC0-1.0** (Creative Commons Zero — public domain dedication) | Checked 2026-08-15 via `gh api repos/.../license` (`.license.spdx_id == "CC0-1.0"`) **and** by reading the repo's own `LICENSE` file directly, whose text opens `Creative Commons Legal Code / CC0 1.0 Universal` — not the badge alone, per the Archipelago/GBA-PK lesson that GitHub's detection and a repo's actual file can disagree. Repo state at check: default branch `4.x-dev`, not archived, last pushed 2026-07-22. **The most permissive terms in this table** — CC0 waives copyright entirely, so unlike every other row there is no attribution or notice obligation, and even copying source would be permitted. **The brief's own rule is still stricter than the license**, exactly as recorded for the MIT rows: MeshGhost's code is written from scratch regardless of what a license would allow. **Not a dependency and not currently used** — recorded now, ahead of need, purely so that a future Godot adapter has a pre-cleared reference to read on day one instead of stopping to run this check. It is a general-purpose mod loader for GDScript-based Godot games (3.x/4.x), i.e. the Godot analogue of the role BepInEx plays for TEVI and RE-UE4SS for Pseudoregalia — the plausible reading is "how does a mod loader get code into a Godot game and hook its loop", the same question the Everest row exists for. Re-check before any real use: a 2026-08-15 snapshot, and a Godot adapter is not on the roadmap (`plans.md`). |
| [attire-ui-overhaul](https://github.com/pseudoregalia-modding/attire-ui-overhaul) (`FoeHammers`) | **None — no LICENSE file; `gh api repos/.../attire-ui-overhaul` reports `"license": null`, and `/contents/LICENSE` 404s.** | Checked 2026-08-15, via `gh api`. All rights reserved by default. Same posture as `pokeemerald`/`pseudoregalia-archipelago`: **consult only to learn facts** (which Blueprints exist, e.g. `DashDataLib`/`UI_DashColourSelector` for its dash-color-customization feature, per its own README) — never copy any `.uasset` content. This is a Blueprint-only UE project (no C++ source at all), so there is no source *text* to accidentally copy in the first place; any fact taken from a `.uasset`'s embedded name-table strings must be cited by file path here or in `verified.md`, same as every other binary-inspection case (TEVI's `Assembly-CSharp.dll` via ILSpy, RE-UE4SS's own reflection). |
| [quic-go](https://github.com/quic-go/quic-go) | MIT | Checked 2026-08-16 via `gh api repos/quic-go/quic-go/license` (`.license.spdx_id == "MIT"`), reading the repo's own license file rather than the badge — the Archipelago/GBA-PK lesson that the two can disagree. Permissive, compatible alongside this project's MIT `LICENSE`. **Checked ahead of reading any of its source**, per the standing rule, because the selectable-transport work (`transport: tcp \| udp \| quic`) would make it **this repo's first third-party Go dependency** — a `go.mod` module requirement, not vendored source, so nothing of it would sit in the tree. That distinction matters for the publishability rule: a `require` line plus `go.sum` hashes is a reference to code fetched at build time, not a copy of it. Two things to settle before it actually lands: whether CI can fetch it (it currently builds with an empty module graph), and whether a larger binary with a real dependency shifts the antivirus false-positive baseline recorded in `risks.md`. Not yet a dependency as of this entry — recorded at scoping time so the check does not gate implementation later. **Its own dependencies come with it**, since a Go module is compiled *into* our binary and both MIT and BSD-3-Clause require the notice to travel with a binary — so this needs a `THIRD-PARTY-NOTICES.txt` for the Go executables, the same treatment `UE4SS.dll` already gets. Checked 2026-08-16 by reading quic-go's own `go.mod`: the linkable set is quic-go itself, `github.com/quic-go/qpack` (**MIT**, `gh api repos/quic-go/qpack/license`), and four `golang.org/x/*` modules (crypto/net/sync/sys) which share Go's **BSD-3-Clause**, `Copyright 2009 The Go Authors` (confirmed for `golang.org/x/crypto`; confirm each of the others individually when they actually link in). `testify`, `go.uber.org/mock` and `gcassert` are test/tool dependencies and never reach our binary. **Do not take the notices list from `go.mod`** — `go version -m meshghost.exe` reports what was actually linked, which is the authoritative list and the one to audit against. Re-check the whole set whenever the quic-go version moves, same standing note as the RE-UE4SS pin. **Adopted as a real dependency 2026-08-16** at **v0.61.0**, for the `quic` transport. What actually links was then read from the built binary (`go version -m meshghost.exe`), not from `go.mod`, and is **smaller than go.mod suggests**: only `quic-go` (MIT), `golang.org/x/crypto` and `golang.org/x/sys` (both BSD-3-Clause, `Copyright 2009 The Go Authors`, each confirmed by reading the licence file rather than the badge). `golang.org/x/net` is required by `go.mod` but does **not** link, and `qpack`/`testify`/`go.uber.org/mock`/`gcassert` never reach the binary at all. Notices now ship at `packaging/release/THIRD-PARTY-NOTICES.txt` (separate from the UE4SS one, which covers a different binary), with the licence texts quoted verbatim from their own files. `go get` also raised the module's Go directive from 1.22 to 1.25.0. |

## What UE4SS.dll actually contains (added 2026-08-16)

The RE-UE4SS row above covers RE-UE4SS's *own* MIT code. It did not cover what RE-UE4SS
statically links into the `UE4SS.dll` this repo builds and ships — an audit gap found
2026-08-16 during a full-repo fact-check. All of the below is read from the real licence files
in the source tree the shipped binary was built from, not from memory or from a GitHub badge.

**The notices now ship**, at
`packaging/release/games/pseudoregalia/pseudoregalia/Binaries/Win64/ue4ss/THIRD-PARTY-NOTICES.txt`,
hand-maintained (`dev-scripts/stage-ue4ss-runtime.bat` does not generate it, and says so).
Re-check it whenever the RE-UE4SS pin moves, since the dependency set can change with it.

| Library | Licence | Notes |
| --- | --- | --- |
| fmt, Dear ImGui, ImGuiColorTextEdit, Zydis, PolyHook 2.0, Glaze, Corrosion | MIT | Each read directly from its own `LICENSE` in `adapters/pseudoregalia/MeshGhostPseudo/build/_deps/<name>-src/`. Statically linked into `UE4SS.dll`. MIT requires the notice travel with a binary — it now does. |
| raw_pdb | BSD 2-Clause | Same source. Its clause 2 is explicit that binary redistribution must reproduce the notice, which is the clearest single reason this file had to exist. |
| GLFW, IconFontCppHeaders | zlib/libpng-style | Same source. Permissive, notice-retention terms. |
| moodycamel::ConcurrentQueue | Simplified BSD (one bundled header is zlib) | Same source; its `LICENSE.md` carves out the embedded semaphore header explicitly. |
| Khronos `khrplatform.h` (bundled with the glad OpenGL loader) | MIT-style, `Copyright (c) 2008-2018 The Khronos Group Inc.` | The glad loader itself (`deps/third/glad`, generated by glad 0.1.36) carries **no licence header at all** — generator output. Its bundled `KHR/khrplatform.h` does, and that notice is reproduced. |
| [patternsleuth](https://github.com/trumank/patternsleuth) (`trumank`) | **Declared `license = "MIT OR Apache-2.0"` in `Cargo.toml:14` — but no licence TEXT exists anywhere.** `gh api repos/trumank/patternsleuth` reports `license: None`, and there is no `LICENSE` file upstream or in the submodule checkout (checked 2026-08-16). | Statically linked into `UE4SS.dll` as the `patternsleuth_bind` staticlib crate, via Corrosion. **What it does:** a byte-pattern (AOB) scanner that locates Unreal Engine functions and globals inside a stripped Shipping executable — its README calls it "a test suite for finding robust patterns used to locate common functions and globals in Unreal Engine games. For use with UE4SS." It is the layer *beneath* Pseudoregalia's whole access model: UE4SS can only offer runtime reflection because this finds the engine's core structures first (see `access-models.md`). Pattern coverage is engine-version-specific, so a UE4SS pin bump can change what resolves — a real instance of the dated-facts rule. **Notice handling:** the `Cargo.toml` declaration is quoted verbatim in the notices file rather than expanded into standard MIT/Apache text, because writing out a copyright line upstream never wrote would be inventing a fact. |
| [UEPseudo](https://github.com/Re-UE4SS/UEPseudo) (`deps/first/Unreal`) | **None, and the repo is private** — `gh api repos/Re-UE4SS/UEPseudo` reports `private: true`, `spdx_id: NOASSERTION` (checked 2026-08-16). **OPEN QUESTION — see below.** | The C++ type definitions UE4SS compiles against. Two kinds of content: `generated_include/` is genuinely generated offset-accessor wrappers, but `include/Unreal/…` holds **~200 headers carrying `// Copyright Epic Games, Inc. All Rights Reserved.`**, adapted into the `RC::Unreal` namespace. That is why the repo is private and Epic-account-gated: Unreal Engine source is available under the UE EULA to accounts linked to Epic, which is a licence to use, not a public redistribution grant. |

### UEPseudo: the one unresolved item

Recorded deliberately rather than left implicit, per this file's own standard. **No file was
removed and nothing shipped changed on the strength of this** — removing UE4SS would break the
Pseudoregalia adapter, and that is not what this audit concluded.

What is established fact:

- We do **not** redistribute UEPseudo's headers. They are not in this repo and not in the release
  zip; only the compiled `UE4SS.dll` is.
- RE-UE4SS's maintainers **publicly ship the equivalent compiled binary themselves** —
  `UE4SS_v3.0.1.zip` is a public release asset on `UE4SS-RE/RE-UE4SS`, under MIT.
- Where MeshGhost differs from that, and from `pseudoregalia-archipelago` (which bundles a UE4SS
  runtime in its release zip but commits no binaries to its repo): we **build our own** UE4SS
  from source, which is what pulls the private UEPseudo submodule into *our* build chain.

What is **not** established, and must not be asserted either way: how the UE EULA treats a third
party redistributing a binary built against those headers. That is a legal question, not a code
one. Note also that "pseudoregalia-archipelago does it" is not a permission MeshGhost inherits —
that repo is itself unlicensed/all-rights-reserved, which governs its own code and says nothing
about its right to redistribute UE4SS.

**The "just ship upstream's zip instead" option was investigated 2026-08-16 and is NOT a
drop-in swap.** It was first written up here as a clean close; that was wrong, and the measured
facts are:

- **No published upstream artifact matches our pinned commit.** Our pin `733e5969` is **938
  commits ahead** of the `v3.0.1` release tag (`d935b5b2`), 300 files changed
  (`gh api .../compare/...`). The published `UE4SS_v3.0.1.zip` was built 2024-02-14.
- **Our own `main.dll` is linked against UE4SS** (`Mod/CMakeLists.txt`:
  `target_link_libraries(${TARGET} PUBLIC UE4SS ws2_32)`), so running it under a UE4SS built
  938 commits earlier is an ABI mismatch, not a configuration change. Phase 7 already lost time
  to a real UE4SS version mismatch — that is the documented precedent, not a hypothetical.
- **The shipped tree would change shape.** `UE4SS_v3.0.1.zip` predates the `ue4ss/` subfolder
  layout entirely: its `UE4SS.dll` sits at the root of `Binaries/Win64/`. It also adds
  `README.md`/`Changelog.md`.
- **It contains no LICENSE file at all** (checked by listing the archive). We would still have to
  supply RE-UE4SS's MIT notice ourselves, exactly as now — so today's staged tree is *more*
  complete than upstream's own zip.
- **The licensing benefit is narrower than first stated.** We would still be the redistributor of
  the binary, so the third-party notice obligation — and `THIRD-PARTY-NOTICES.txt` — stays either
  way. The only thing that moves upstream is *who compiled against the Epic-copyrighted headers*.

So the real shape of the option is a **migration, not a swap**: re-pin to a commit upstream
publishes a binary for (the closest is the rolling `experimental-latest` prerelease, 1028 commits
past the tag), rebuild the mod against it, and fully re-verify the largest and most fragile
adapter — before 7.7 has even happened. **Decision 2026-08-16: not doing it.** Keep building our
own, keep the notices file, and revisit only if a concrete licensing concern arises rather than
on general tidiness. Recorded as an ADR in `agent_docs/architecture.md`'s decision log (dated
2026-08-16) — that is the canonical decision record; the measurements above are the evidence
behind it.


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

## Cheat codes in this repo: fine, and why (2026-08-18)

**Question, from the user:** is it all right for cheat codes, what they change, and how they work
to sit in a public repo forever? **Answer: yes**, and the reasoning is the same facts-versus-
expression test `CLAUDE.md` applies to everything else — but it lands differently for the two
formats, which is worth knowing before pasting the next list.

- **A decoded address/value pair is a fact about a running game.** `0x7E09C2` holds Samus's
  energy; `wBadges` is at `0xD857`. We already record hundreds of such facts from decompilations,
  with citations. A cheat code that decodes to one is not a different kind of thing, and several
  of ours were *verified against the decomp* before being written down — the Crystal entry in
  `pitfalls.md` exists precisely because that check caught a code that would have corrupted our
  own object array.
- **What we deliberately do not do is paste large curated lists verbatim.** A long, organised
  compilation is somebody's work as a compilation even when each row is a fact, and a wholesale
  copy adds nothing we need. The Super Metroid entry in `ideas.md` is the pattern to follow: the
  codes were **decoded into our own address table**, sorted by address, annotated with what each
  came from, with the unusable Game Genie half described but not reproduced. That form is both
  more useful to us and further from the source — the technical reason and the licensing reason
  point the same way, which is usually the sign of a good format.
- **No game code, ROM data or assets are involved**, so the rule that actually bites elsewhere in
  this project does not apply here at all.
- **Nothing about it is a distribution problem either.** These are single-player games, the codes
  are decades old and published in hundreds of places, and our use is development tooling for
  reaching test states — documented as dev-only in `adapters/_template/README.md`, never shipped.

**The rule to carry forward:** record cheat codes **decoded, by address, in our own table, with
what each was verified against**. Do not paste a list because it is convenient — decode it,
because that is the step that makes it useful, checkable, and ours.

## When this file needs an update

- Before adding any new project to the "prior art" or "tooling" list in `brief.md`.
- Before vendoring any third-party code or library as an actual dependency (as opposed to a
  read-only reference) — check its license fits alongside this project's MIT `LICENSE`
  *before* adding it, not after.
- Before relying on an existing entry again for a genuinely new use, if meaningful time has
  passed since its recorded check date — not just reactively if a change happens to be noticed.
- Always, before cutting a release, regardless of whether anything is suspected to have changed.
