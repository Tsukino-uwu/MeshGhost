# Unity / BepInEx adapters — host rules

<!-- line-cap: 150 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**Loaded automatically** the first time this session reads or edits anything under
`adapters/tevi/`. Per-game facts live in this adapter's own `documentation.md`, `FLAGS.md` and
`BANDAGES.md`.

**These are HOST rules, sitting at game scope for now.** TEVI is the only Unity game here, so per
`../CLAUDE.md`'s create-a-level-on-demand rule there is no `adapters/unity/` yet — a second Unity
game is what creates one, and this file is what moves up into it. Nothing below is about TEVI
specifically; it is about Unity/Mono and BepInEx.

**Capped, and part of this session's rule STACK** (`agent_docs/claude-md-cap.md`): it loads unasked.
Before adding: what comes out? **It never restates the root `CLAUDE.md` or `../CLAUDE.md`.**
**Before mirroring any state onto a ghost, read `agent_docs/checklists/before-mirroring-state.md`.**

**This file is short, and that is honest rather than incomplete.** TEVI is the smallest adapter
here and fewer host-level rules have been paid for on Unity than on the emulator or Unreal hosts.
It exists so the next one found has a home the moment it is found, instead of landing in
`_template/` where only an end-to-end read would surface it.

## `Instantiate()` deep-copies TRANSIENT state, not just geometry

Cloning a live character's visual hierarchy to build a ghost copies every component's *current*
field values — including whatever transient state the source happens to be in at that instant.
A clone made mid-transition captures that transition's state **permanently**, because a detached
clone has none of the gameplay logic that would later flip it back.

Found live 2026-08-14: a ghost cloned exactly as a zone-load finished inherited
`basesprite.enabled = false` and was invisible forever — alive, active, correctly positioned,
never destroyed. It is the Unity form of a stale reference: same class of bug as a Lua pointer
going stale mid-warp, expressed in render state instead of memory.

**Two rules come out of it, and the second is the one that gets skipped:**

- **Log what was actually inherited BEFORE resetting anything.** The first fix forced *every*
  sprite renderer to `enabled = true` and `color = Color.white`, which cured the invisibility and
  immediately broke the character's outline effect — `outlinesprite` is deliberately not white.
  The log showed `color` was already correct and only `enabled` was wrong. **Reset the field
  confirmed broken, never everything that plausibly could be.**
- **A clone of a self-configuring component inherits its POST-setup state, and its Awake may never
  run.** The boost shield (2026-09-10): the template sits INACTIVE between uses, so its clone is born
  inactive with every material null (activate it once to run Awake); and the template's renderer
  already holds the material its own setup STRIPPED a shader keyword from, so the clone rebuilt every
  material without the bloom/fade effect. Read what the component's setup CHANGES, then undo it on the clone.
- **Don't answer a race with a guessed delay.** A wait only narrows the window against a
  transition whose duration was never measured, and it taxes every recreate that was not racing
  anything. When a symptom looks like "the right value settles eventually, so just wait", check
  first whether forcing the known-good value directly is both cheaper and certain.

## Access model: names from the assembly, never its code

Unity/Mono means `Assembly-CSharp.dll` is decompilable, which makes this the
**self-documenting artifact** access model (`agent_docs/access-models.md`). That is a licensing
boundary, not just a technique: **names, signatures and field layouts may be read and used with a
citation; the decompiled body may never be committed, adapted or paraphrased**
(`agent_docs/licensing.md`). The game's own assemblies are proprietary, gitignored and never
committed — which is also why CI cannot build this adapter and its DLL is checked in instead.

If a Unity game ships `GameAssembly.dll` rather than `Assembly-CSharp.dll`, it is IL2CPP: native,
needing unhollowing, and a materially harder access model. Establish which one before estimating
any Unity adapter.

## Configuration goes through the player's config.json first, BepInEx's config second, never a new env var

The keys every game shares — `local_game_bridge`, `autostart` — are read from the `config.json` in
the game's root folder (2026-08-28, 2026-09-03), because that is the one file every README tells a
player to edit; a BepInEx `BridgePort` entry only wins when changed from its default (`Plugin.cs`,
the tie-break). The shared `MESHGHOST_BRIDGE_PORT` launcher override still wins over both, so one
launcher script can aim every game. `_template/PROTOCOL.md` has the port-walk contract all feed.

## Launching the core: no console window

`ProcessStartInfo` with `UseShellExecute=false` and `CreateNoWindow=true`. A stray console window
on a player's machine is a shipped defect, not a debug convenience.

## Rebuild, then deploy

**A `*.cs`/`*.csproj` edit is not done until `dev-scripts/build-tevi.bat` has run and the DLL is
deployed to the live installs** (CI cannot build it; `packaging/README.md`); the sources are LF-pinned,
so normalize before building — preflight's DLL-vs-source, deployed-copies and LF checks each catch a
miss (live 2026-08-14, 2026-08-15).
