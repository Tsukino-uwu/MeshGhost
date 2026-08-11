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
| Archipelago (`connector_bizhawk_generic.lua`) | Custom (NOASSERTION on GitHub — see repo's own LICENSE file before use) | License terms are non-standard; re-read the actual file at time of use rather than trusting this summary, since Archipelago's license has changed over project history. Cited by the brief as a bridge-pattern reference only. |
| [pokeemerald](https://github.com/pret/pokeemerald) (decomp) | **None — no LICENSE file in the repo** | This is a decompilation of Nintendo's copyrighted Pokémon Emerald. There is no license grant making its source redistributable or reusable, decomp or not. **Consult it only to learn facts** — the address of a struct field, the name of a function, the shape of a data table — and write independent Lua that reads that memory location. **Never copy source text, data tables, or assets from it.** Every fact taken from pokeemerald and used in `verified.md` must cite the specific file and commit/line in pokeemerald as its source, per the brief's "no addresses from memory" rule — that citation is also what keeps this boundary auditable later. |

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
