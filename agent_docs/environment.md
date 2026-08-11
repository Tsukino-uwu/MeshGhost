# Environment

Exact tools, versions, and configuration known to work for this project. Unfilled until
Phase 1 actually sets up BizHawk — do not pre-fill version numbers from memory.

## Host

- OS: Windows 11 Pro (dev machine). Cross-platform build targets: Windows, Linux, macOS —
  not yet built or tested on the latter two.
- Go toolchain: not yet confirmed installed. Needed before any `cmd/` or `internal/`
  package gets real logic (currently skeleton-only, per Phase 0).

## BizHawk / Emerald (to fill during Phase 1)

- BizHawk version: unfilled.
- Lua version used by BizHawk: unfilled.
- Emerald ROM version/revision: unfilled — record only enough to reproduce, never the ROM
  itself (see `agent_docs/licensing.md` — no ROM is ever committed to this repo).
- Any non-default BizHawk launch options: unfilled.

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
