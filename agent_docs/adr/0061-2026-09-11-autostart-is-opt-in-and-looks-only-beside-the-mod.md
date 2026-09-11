# 2026-09-11 — Autostart is opt-in, and looks only beside the mod

<!-- ADR 0061. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** every adapter's autostart search looks **only where the mod itself lives**. The two
  `../` fallbacks in the Emerald and Crystal Lua scripts — the release root three levels up, a
  source checkout four up — are removed. `MESHGHOST_CORE_DIR` stays ahead of the search as the dev
  escape hatch, the same name and the same position TEVI's `CoreSearchDirs` already gives it.
- **Consequence, stated plainly:** there are two shapes and never both at once. `meshghost.exe` in
  the release root means **you run it yourself**. `meshghost.exe` copied in beside the mod means
  **autostart**, still switchable with `"autostart": false` in the `config.json` beside it. Making
  that copy *is* the opt-in.
- **Status:** built 2026-09-11 in both Lua adapters. **Unwatched in a running game** — see each
  adapter's `UNVERIFIED.md`. TEVI and Pseudoregalia needed no code change; they already behaved
  this way. **Crystal's half is committed with this ADR; Emerald's is not** — that file was being
  worked on in parallel, so its `findCoreExe` change sits in the working tree and lands with that
  session's commit. The two edits are identical apart from Crystal's leading path separator.
- **Asked for by the user**, 2026-09-11: *"everything should either be 'run exe manually from
  root' or 'place exe in mod folder for autostart, toggle on/off in config'. not both at once"*.

## Why the fallback had to go

Autostart is a convenience a player chooses, not a requirement. The user's framing: *"its a qol
people can have but not a requirement"*, and *"autostart is also what might trigger antivirus
things"*.

A search that reached back to the release root defeated both halves of that. An install that had
never copied an exe anywhere still had a process spawned for it, so the opt-in was not an opt-in —
it was the default with an extra step available for people who wanted their logs separated. And the
behaviour it produced silently is precisely the one an antivirus flags: one program starting
another. Asking for that is fine; getting it without asking is not.

It also made the two Pokémon adapters the odd ones out. TEVI searches `MESHGHOST_CORE_DIR` then
`Paths.GameRootPath`; Pseudoregalia searches the game root, the mod folder and the dlls folder.
Neither can see a MeshGhost release folder at all, so for those two games the rule was already
"copy it in or start it yourself". The Lua pair carried a third behaviour nobody else had.

## What this costs, and who pays it

**An existing install that left the exe in the release root stops autostarting.** That is the
intended outcome and not a regression: that install now runs the client the way the release root
has always implied, by being double-clicked. The message the script already prints on a miss says
both options in one line — *"Start it yourself, or put a copy beside this file."*

The reversed decision is the 2026-09-10 one recorded in both scripts' comments, which added the
per-game copy as the documented layout while keeping the fallbacks explicitly *"not deprecated"* so
that *"an install that never copied the exe keeps working exactly as it did"*. That compatibility
is what is being given up, deliberately and by the user's call, because it was the thing making
autostart non-optional.

## The dev loop

Nine of the local BizHawk launchers relied on the four-up fallback to autostart against the
repo-root build; the other nine set `MESHGHOST_NO_AUTOSTART=1` and start a core themselves. The
nine now set `MESHGHOST_CORE_DIR=%~dp0..`, which is why the env var is kept ahead of the mod folder
rather than dropped along with the `../` paths: a checkout runs the script where it sits, and no
player ever copies an exe there.

## How to confirm it

In a running game, not from the code:

1. With **no** `meshghost.exe` beside the script, load the Lua script. The console must say
   `meshghost.exe not found near this script -- not starting a core`, and no `meshghost.exe`
   appears in Task Manager. A copy in the release root must not change that.
2. With a copy **beside** the script, load it again. A core starts, hidden, and dies with the
   emulator.
3. With that copy still in place and `"autostart": false` in the `config.json` beside it, no core
   starts, and a client already running is used as before.
