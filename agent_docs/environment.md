# Environment

This file captures the environment, toolchain, and workspace setup for MeshGhost.

## Purpose

Use this file to record the exact tools, versions, and configuration that are known to work for the project.

## Recommended contents

- Host OS and version.
- Editor/IDE and version.
- BizHawk version and any special launch options.
- Lua version used by BizHawk.
- Emulator ROM notes or paths (when allowed).
- Tooling used for Unity/UE modding (BepInEx, Harmony, UE4SS, etc.).
- Any required external programs or helpers.
- Exact versions of any helper scripts or Lua libraries used during verification.

## Onboarding checklist

- Confirm the project is checked out to `C:\dev\MeshGhost`.
- Install and verify a supported BizHawk build.
- Confirm the correct Emerald ROM version and the expected map format.
- Set up BizHawk Lua scripting and verify access to the Lua console.
- Record the host OS, BizHawk version, and Lua version in this file.
- Keep the environment notes up to date whenever verification changes.

## Workspace conventions

- The project lives in `C:\dev\MeshGhost`.
- Do not access outside authorized directories unless explicitly approved.
- Record any non-default environment tweaks here.

## Notes

- If a change in tooling affects the workflow, update this file.
- Keep the file factual and version-specific.
