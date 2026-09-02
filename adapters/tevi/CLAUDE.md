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

## Configuration goes through BepInEx's own config, not an environment variable

This host has a real config system and the player already knows where it lives, so the bridge
port's primary home is a BepInEx `BridgePort` entry rather than an env var — unlike the emulator
adapters, which have no such system and use the environment. The shared `MESHGHOST_BRIDGE_PORT`
launcher override still exists and wins over the config entry, so one launcher script can aim
every game. `_template/PROTOCOL.md` has the port-walk contract both feed.

## Launching the core: no console window

`ProcessStartInfo` with `UseShellExecute=false` and `CreateNoWindow=true`. A stray console window
on a player's machine is a shipped defect, not a debug convenience.
