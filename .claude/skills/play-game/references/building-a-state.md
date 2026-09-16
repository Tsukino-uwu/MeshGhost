# Building a state — what has worked, per game

Read before making a test situation happen in a game: a ledge, water, an item in hand, a place, a
battle. Kept here so the next session reaches for a recipe instead of re-deriving it. **Add to it
whenever a way of making something happen works; say what was measured and when.** Make the thing,
then let the game run the mechanism through ordinary input — never force the outcome (`SKILL.md`).

## The driver: `cmd_drive.lua`, one per game

- `adapters/emulator/pokemon/crystal/probes/cmd_drive.lua` (vanilla V1.0 only: it refuses any other
  ROM title) and `adapters/emulator/pokemon/emerald/probes/cmd_drive.lua` (vanilla: `warp` refuses
  unless `gMain.callback2` is vanilla's `CB2_Overworld`).
- **Load it** by adding its path to your instance's dev-loader control file (the target named in
  `MESHGHOST_DEV_LOADER_TARGET`; `dev-scripts/README.md`, `bizhawk-dev-loader.lua`).
- **Steer it** by writing `cmd_drive.cmd` beside the script, one command per line, `#` comments
  allowed. It is read **every 15 frames**, and a CHANGED file replaces the queue. An empty queue does
  nothing, which is the idle mode a measurement needs.
- **The command list and what each command's addresses rest on** are in each script's own header —
  read it there; the two games' sets differ (Crystal: `block`, `redraw`, `tilecheck`, `collscan`,
  `collfind`, `poke`; Emerald: `warp`, `grid`, `mtscan`, `mtset`, `givekey`, `register`, `objdump`,
  `poke8|16|32`, `rec`; both: `hold`, `wait`, `shot`, `status`).
- **Its log**: Crystal writes `crystal/logs/cmd_drive_<ts>.log`, Emerald writes
  `emerald/probes/cmd_drive_<ts>.log`.
- **Take it off the target when done**: an input-driving tool left loaded is a suspect in every
  later report.

## Crystal (vanilla V1.0, 2026-09-16) — `crystal/probes/cmd_drive.lua`

- **The map is a buffer of block ids from the LOADED tileset.** Write one with `block BX,BY ID`; which
  ids are ledges or water differs per tileset, so ask `collscan` (ledges) and `collfind 29` (water)
  first. In tileset 6 (a town): `$56` hop down, `$4c` hop left, `$4d` hop right, `$35` water.
- **The player's tile is `wXCoord`/`wYCoord`**, not the object struct's map coordinates, which read 4
  more on both axes; block = tile // 2. `tilecheck` prints the lookup beside the engine's own byte.
- **Close the START menu to redraw** (`redraw`): the screen is rebuilt from the blocks.
- **The next step does not see a block written beside the player**: the neighbour collisions are
  cached and refreshed after a step. Write first, then walk onto the block or next to it.
- **A hop**: stand on the ledge block's hop row or column and press toward the face; the engine hops two
  tiles and spawns its own shadow.
- **An item without a menu**: add it to the key items (count 01:d8bc, list 01:d8bd, `$ff` after the
  last), register it (01:d95b = `$80` + list position + 1, 01:d95c = the item), then press Select —
  facing a water block that casts the Super Rod (`$3d`). A fishing text clears with A twice; a bite's
  "!" can appear and a battle can follow.
- **A door or warp rebuilds the block buffer from ROM**, undoing every `block`.
- **What did not work, and should not have**: poking the standing-tile collision byte, and an execute
  hook on the jump check. Neither hopped, and neither would have been the game's own hop.

## Emerald (vanilla, 2026-09-16) — `emerald/probes/cmd_drive.lua`, `emerald/probes/find_behaviour.py`

- **Teleport first, walk never.** `warp G.N X,Y` is the game's own map load and lands exactly; onto a
  water tile it arrives SURFING. A warp also reloads the map grid, so it undoes tile writes — warp,
  then write. Walking around a building to reach a door cost several tries that one warp did not.
- **Need a particular kind of tile? Find a real one**: `find_behaviour.py ROM SYM BEHAVIOUR` scans every
  map grid in the ROM and prints `warp` lines, including walkable tiles directly above one. It found
  puddles, ice, a bridge and Sootopolis's deep water, and showed one behaviour exists nowhere.
- **Or make one**: `mtscan BEH` lists the loaded tilesets' metatiles with that behaviour, `mtset` writes
  one into the grid. Write it OFF screen (8 rows away) and walk to it: the game draws it as it scrolls in.
  A written ledge hopped like a real one.
- **Items without a menu**: `givekey ID` then `register ID`, then Select — mounted the Acro Bike and cast
  the Super Rod. Turn toward water with a ~4-frame tap; B clears the fishing text.
- **Check the ground truth first**: continuing a save made in a dev session that spawned a ghost brings
  the ghost back as a real object (`emerald/UNVERIFIED.md`); `objdump` shows it, a warp clears it.
- **An in-game save keeps what `givekey`/`register` wrote**: they write SaveBlock1, which is what the
  save stores. `cmd_drive` itself never writes the save file.

## Other probes that reach a state

Each adapter's `PROBES.md` lists the rest — `goto_map.lua`, `noclip.lua`, `watertile.lua`, the grant
kits, the ride and square drivers — with what each writes and whether it survives a reload. Check
the sibling game's `probes/` before writing a new one (`/write-a-probe`).
