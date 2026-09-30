# Unity / BepInEx adapters — host rules

<!-- line-cap: 150 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**Loaded automatically** the first time this session reads or edits anything under `adapters/tevi/`.
Per-game facts live in this adapter's own `documentation.md`, `FLAGS.md` and `BANDAGES.md`. **These are
host rules at game scope for now**: a second Unity game creates `adapters/unity/` and this file moves
into it; nothing below is about TEVI specifically, only Unity/Mono and BepInEx.

**Capped, and part of this session's rule stack** (`agent_docs/claude-md-cap.md`): before adding, what
comes out? The stories behind these rules: `agent_docs/pitfalls/by-lesson.md`, "The stories behind the
rule files". **Before mirroring any state onto a ghost, read `agent_docs/checklists/before-mirroring-state.md`.**

## `Instantiate()` deep-copies transient state, not just geometry

Cloning a live character's visual hierarchy copies every component's current field values, including
whatever transient state the source is in at that instant. A clone made mid-transition keeps that
state permanently, because a detached clone has none of the gameplay logic that would flip it back.

- **Log what was actually inherited before resetting anything, then reset the field confirmed broken,
  never everything that plausibly could be** (forcing every renderer white broke the outline, which is
  deliberately not white).
- **A clone of a self-configuring component inherits its post-setup state, and its Awake may never
  run.** A template sitting inactive between uses yields a clone born inactive with null materials
  (activate it once to run Awake); a setup that strips something from its own material hands the clone
  the stripped copy. Read what the component's setup changes, then undo it on the clone.
- **Don't answer a race with a guessed delay.** A wait only narrows the window against an unmeasured
  transition and taxes every recreate that was not racing. Check first whether forcing the known-good
  value directly is both cheaper and certain.

## Access model: names from the assembly, never its code

Unity/Mono means `Assembly-CSharp.dll` is decompilable: the **self-documenting artifact** access model
(`agent_docs/access-models.md`). That is a licensing boundary: **names, signatures and field layouts
may be read and used with a citation; the decompiled body may never be committed, adapted or
paraphrased** (`agent_docs/licensing.md`). The game's own assemblies are proprietary, gitignored and
never committed, which is why CI cannot build this adapter and its DLL is checked in instead.

A Unity game that ships `GameAssembly.dll` rather than `Assembly-CSharp.dll` is IL2CPP: native,
needing unhollowing, and a materially harder access model. Establish which one before estimating.

## Configuration: the player's config.json first, BepInEx's config second, never a new env var

The keys every game shares (`local_game_bridge`, `autostart`) are read from the `config.json` in the
game's root folder, the one file every README tells a player to edit; a BepInEx `BridgePort` entry
only wins when changed from its default (`Plugin.cs`, the tie-break). The shared
`MESHGHOST_BRIDGE_PORT` launcher override wins over both. Port-walk contract: `_template/PROTOCOL.md`.

## Launching the core: no console window

`ProcessStartInfo` with `UseShellExecute=false` and `CreateNoWindow=true`. A stray console window on a
player's machine is a shipped defect.

## Rebuild, then deploy

**A `*.cs`/`*.csproj` edit is not done until `dev-scripts/build-tevi.bat` has run and the DLL is
deployed to the live installs** (CI cannot build it; `packaging/README.md`); the sources are LF-pinned,
so normalize before building. Preflight's DLL-vs-source, deployed-copies and LF checks each catch a miss.

## A ScriptEngine plugin, and a game that was never focused

- **Under ScriptEngine a plugin's `Info.Location` is empty**, so a path built from it lands in the
  game's working folder: build paths from `Paths.BepInExRootPath` (`tevi/MEASURED.md`).
- **A TEVI started while another window has focus takes typing and mouse input from that window** until
  its own window has been clicked once; a test launched by an agent is exposed to whatever the user
  types meanwhile.
