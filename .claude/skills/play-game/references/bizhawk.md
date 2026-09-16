# BizHawk — the whole tool surface, and speed

Read when driving a BizHawk instance and you need more than input: memory, savestates, hooks, an
overlay, speed. **Every item below is permitted, and reaching for the smallest one out of caution is
the mistake** — agents keep using a third of this list. Host facts, versions and traps (the
savestate API and its per-core paths, the GBA cheat-engine trap, launching from PowerShell, the
button names) live in `agent_docs/environment.md` and `agent_docs/running-the-rig.md`.

## Inside the emulator

- `memory.read*` / `write*` across every domain, and `mainmemory`
- VRAM, OAM and palette reads
- `client.screenshot()` — the game frame (`screenshots.md`)
- `client.speedmode()` — below
- `joypad.set` / `get` — **pass no controller index**, and re-issue a held button every frame
  (`environment.md`, "Driving input")
- `savestate.save` / `load` / `saveslot` / `loadslot` — slot 1 is the user's; a savestate is not an
  in-game save (`environment.md`)
- `event.on*` hooks, `emu.framecount`
- `gui.*` for an overlay
- `luanet` for .NET — how the adapter learned its own pid
- the dev loader, `dev-scripts/bizhawk-dev-loader.lua`: attach, swap and drop scripts through the
  instance's control file with no relaunch (`dev-scripts/README.md`)

## Outside the emulator

The decomp as a map (built locally, `environment.md`), the Go rig, `meshghost-fakeadapter`,
`meshghost-netsim`, the relay's `-loopback`, and probes that write.

## Speed

`client.speedmode(n)` is exposed to Lua on this build, with `n` ∈ 50/75/100/150/200/400 — confirmed
at runtime 2026-08-19, not from a doc string (no script in the repo calls it yet). Measured the same
day on a loaded host (4 emulators, a crowd of drawn ghosts):

| Requested | Measured |
|---|---|
| 100% | 59.8 fps |
| 200% | 122.5 fps — the full 2x |
| 400% | 138.3 fps — about **2.3x**, not 4x |

- **A speed setting is a request, not a guarantee**: past some multiple the host CPU is the limit,
  and on a busy machine 400% buys little more than 200%. **Measure what you got** — frames against
  the wall clock, or `client.get_approx_framerate()` (called in a `pcall` in
  `dev-scripts/bizhawk-hitch-meter.lua`).
- **Never reset a speed you did not set.** Check before assuming your instance is at 100: the user
  may have raised it on purpose, and that means "make progress", not "reset me".
- **Put back what YOU changed** — to 100 when finished — so the next reader of that instance is not
  confused by a fast-running game.
- **To price something, turn the frame limiter off**: `emu.limitframerate(false)`, sample, then
  `emu.limitframerate(true)`. Take the baseline with NOTHING loaded, not the script minus the feature
  (`emerald/probes/hookcost_probe.lua`, 2026-09-16). **This BizHawk's own functions are userdata, not Lua
  functions**: `type(emu.limitframerate) == "function"` is false — check `~= nil` before calling.
