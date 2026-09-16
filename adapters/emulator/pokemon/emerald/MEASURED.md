# Measured — Pokémon Emerald

**What this is.** The code-level facts about this game that the agent MEASURED: addresses, what a
field or byte reads in which state, encodings, timings, costs, which routine fires when. Each one is
settled by its own evidence, not by the user watching, because nobody can watch a byte.

**The three records, and which one a thing belongs in:**

| Record | Holds | Who settles it |
| --- | --- | --- |
| [`VERIFIED.md`](VERIFIED.md) | what the game visibly does with the adapter: "jumping works", "the ghost's fly looks right" | the user, on screen |
| [`UNVERIFIED.md`](UNVERIFIED.md) | the same kind of claim, built and waiting for the user's eyes | the user, on screen |
| **MEASURED.md** (this) | the bytes, addresses and timings underneath | the agent's own measurement |

When a measurement has a visible consequence, the bytes go here and the visible part goes to
`UNVERIFIED.md` for the user.

**The rule for an entry** (`CLAUDE.md`, MEASURED OR OBSERVED ONLY; `agent_docs/licensing.md`):

- **It names its evidence and its date**: the probe or test, the log or capture, what was done in the
  game while it ran. "Measured" with no instrument named is not an entry.
- **It is true as of that date, on that build.** Say which ROM, version or install; a fact from one
  build is not a fact about another.
- **A source is never the evidence.** A decompilation, wiki, symbol file, dump or other project says
  where to look. A `.sym` from a build we hashed identical to the ROM proves an ADDRESS, never what
  the byte means.
- **Superseding is a new dated entry** that says what it replaces; the old one gets a one-line
  pointer, not a rewrite. A measurement that turns out wrong is itself worth keeping.
- **The instrument is the first suspect** (`agent_docs/checklists/before-trusting-a-reading.md`):
  write down what it could NOT see, so the next reader knows the entry's edges.

**Keep the `## Not measured yet` section LAST.** It holds what a source says and nobody has measured,
each item written as a question with how to settle it. Nothing in it is a fact, and nothing in it is
cited as one anywhere else. Measuring an item moves it up into the measured entries; the pattern is
`documentation.md`'s "what we know, plus a plainly marked list of what we know we do not know".

Sibling records: [Pokémon Crystal](../crystal/MEASURED.md), [TEVI](../../../tevi/MEASURED.md), [Pseudoregalia](../../../pseudoregalia/MEASURED.md).

**Older code-level entries still sit in `UNVERIFIED.md` and `VERIFIED.md`**: sorting them into
this file is a queued task (`agent_docs/status.md`, 2026-09-16). Until it runs, look there too.

**Keep the `## Index` section below, one line per `###` entry in either section.** This file only
grows, like `VERIFIED.md`, so the index is what keeps it findable.

## Index

- Text printing, menus and the character encoding (2026-09-16)
- The map around the player, and one walked step (2026-09-16)
- Not measured yet: The rest of the text printer (from 2026-09-16)
- Not measured yet: The rest of the map and the walk (from 2026-09-16)

## Measured

### Text printing, menus and the character encoding (2026-09-16)

**Vanilla ROM.** Its SHA-1 (`F3AE0881…`) equals our pokeemerald build's and what
`gameinfo.getromhash()` returns, so the build's addresses are addresses; every meaning below is from
`probes/text_probe.lua` (read-only) and `probes/charset_probe.lua` (writes the message buffer once),
read against captures of the same frames (`dev-scripts/shots/emerald/autoplay_text_*` and
`autoplay_cs_box01`..`13`, gitignored). Used by `autoplay/drivers/bizhawk/games/emerald.lua`, whose
table holds the byte-to-character mapping. Moved here from `UNVERIFIED.md` the day this file began.

- **The encoding.** The game's own printer drew every byte 00-F7 in a message box, ten per line
  between ▶ (EF) markers; a script split each line at the marker's exact pixel mask (every line 11
  markers, and 12 on the one holding EF itself). 152 bytes draw a glyph and 96 draw nothing (7D-83
  blank at widths 3 to 9 px). A-Z are BB-D4, a-z D5-EE, 0-9 A1-AA; 00 is the gap between words in real
  dialogue. Read as ß: 15 (an R-like glyph with a hook). Left raw: 50 (a tall empty rectangle) and 59
  (unidentified). The START menu, the nurse's three boxes, her YES/NO and her goodbye decode to exactly
  what their captures show.
- **Commands seen in real text.** FE began the second line, 16 px lower; FB ended a box: the red
  arrow appeared, the printer waited, and A cleared the window and went on; FF ended the string: on
  the last box the printer went idle with the box still drawn and no arrow, and the next A cleared the
  window tilemap (FillWindowPixelBuffer and ClearWindowTilemap on window 0, no RemoveWindow).
- **The printer block, 0x24 bytes per window id.** +0x1B reads 1 while a message is on its way and 0
  at its end; +0x1C reads 0 while printing and 2 on the arrow; the first word is one past the last
  byte taken (42 bytes in at the first box's arrow, whose FB is byte 41).
- **The text routine's entry.** R0 points at a template whose first word points at the string, +4 the
  window, +6/+7 x and y; R1 the speed: 4 for the nurse on this save, 255 for the START items, 0 for
  the ▶ cursor. Only her text ran a printer: no window-1 printer went active in either menu.
- **Windows, 12 bytes per id.** +0 the background (FF after RemoveWindow), +1 left, +2 top, +3 width,
  +4 height. The START menu's (22, 1, 7 by 16) and the message box's (2, 15, 27 by 4) matched BG0's
  drawn columns and rows with a one-tile frame round them.
- **The menu block, 12 bytes.** +1 top (9 on START, 1 on the YES/NO) is the first item's y; +2 the
  cursor, one entry per Down or Up press (0→1→2, 2→5, 5→0); +4 the last index (6, 1); +5 the window;
  +8 the row height (16), the spacing between items. It keeps its values after the menu closes. Both
  menus reached the routine named Menu_MoveCursor; the YES/NO never reached the one named InitMenu (a
  hook there missed it).
- **What an execute hook costs.** One emulator, frame limiter off, standing in the Pokémon Center:
  344 frames/s with no hook, 245.6 with one, 242.0 with five, so the price is having any at all.
  Requested 400% read 238-240 either way, capped by the setting rather than the CPU.

### The map around the player, and one walked step (2026-09-16)

**Vanilla ROM, map 0.10 (the town with the Pokémon Center) and 2.2 (inside it).** From
`probes/map_probe.lua` (read-only: the grid, behaviours, objects and the header's event lists on
every tile, facing or elevation change) and `probes/step_probe.lua` (read-only: the player object's
movement bytes and the avatar block on every frame they change), against captures
`dev-scripts/shots/emerald/autoplay_map_00`..`03` and the walks that produced them. Used by
`autoplay/drivers/bizhawk/games/emerald.lua` for `local_map`, `nearby`, `warps` and `walk`.

- **Position.** SaveBlock1's x and y plus 7 equal the player object's +0x10/+0x12, at five walked
  positions: (10,16)/(17,23), (9,16)/(16,23), (9,17)/(16,24), (9,18)/(16,25), (9,19)/(16,26).
- **The grid.** The 12-byte block named gBackupMapLayout holds width (+0), height (+4) and the entries'
  pointer (+8); an entry is read at `(x + width * y) * 2` in object coordinates. The tile the player
  walked into from object (16,23) going left read 0x0463 (collision bits set) and refused the step;
  the path tiles walked read 0x31D8/0x31D9 (collision clear, elevation 3).
- **The map's own size.** On 0.10 the grid is 35 by 34 and the header's first pointer's +0/+4 read 20
  by 20: 15 more columns, 14 more rows. On 2.2 the cells outside the header's size once offset by 7
  are exactly the black area right of and below the room in the capture.
- **Warps.** The header's second pointer starts with four count bytes; the list behind the second
  count is 8 bytes an entry: x +0, y +2, destination map number +6 and group +7. Walking into (6,16)
  on 0.10 arrived on 2.2 all four times (a plain press, then three `walk` calls, the first two of which
  gave up before the door finished); stepping down off (7,8) on 2.2 arrived on 0.10 both times. Both
  doors 0.10 lists sit on tiles whose behaviour byte is 0x69.
- **Characters.** Object slots in use have bit 0 of byte 0 set (five on 0.10, the player among them;
  none else). +0x05 the graphic, +0x08 the local id, +0x10/+0x12 where it stands. On 0.10 two slots'
  id, graphic and first position (+0x0C/+0x0E, less 7) matched entries in the list behind the header's
  first count (24 bytes: id +0, graphic +1, x +4, y +6); the drawn positions matched the captures on
  both maps.
- **Grass.** The two patches drawn at the bottom of the 0.10 capture read behaviour 0x02, tile for tile.
- **A walked tile.** The destination coordinate is written the frame the press lands, the previous
  coordinate keeps the old tile, byte 0's top bit clears, the avatar block's +2 reads 2 and +3 reads 1;
  16 frames later the top bit is back and the previous coordinate catches up, and 2 frames after that
  +2 and +3 are both 0. That together is "at rest". +0x1C read 0x0A walking left, 0x08 down, 0x09 up.
  A 40-frame hold of Down walked 3 tiles.
- **A turn.** A 3-frame tap facing another way: +0x18 changed (0x33 to 0x11) and +2 read 1 for 7
  frames; no step. Held, the step followed the 7 frames of turning.
- **A refused step.** Walking left into the wall: +2 read 2 from the first frame with the coordinates
  unchanged, +0x1C 0x1B, and the bump lasted about 31 frames before rest.
- **A door.** Facing it already: every one of these bytes stayed at rest for 20 frames while the door
  opened, then the step into it began with no button held; afterwards byte 1 read 0xA0 and the map
  changed about 60 frames later. Turning to it first: +2 read 1 and +3 read 2 for 13 frames before
  the step.
- **`walk` against the same map** (2026-09-16): up 3 done in 66 frames; left 2 refused at once with
  the tile (8,16) reported as collision 1; both doors reported `map_changed`.

## Not measured yet

### The rest of the text printer (from 2026-09-16)

A box that scrolls rather than clears (FA), pauses, and the FC/FD/F8/F9 commands with their
parameters; list menus (the bag, the PC, shops), the battle menus and battle text; any font but the
message font's line advance; any text speed but this save's, and any instant-text build; any patched
build. To settle: `probes/text_probe.lua` through a conversation that scrolls, a shop, the bag and one
battle, each paired with captures.

### The rest of the map and the walk (from 2026-09-16)

- What the grid's border holds outdoors, next to a connected map, and whether a step onto it crosses
  over: walk off an edge of 0.10 that has a connection, with `map_probe.lua` loaded.
- Whether a clear tile at another elevation accepts a step (the local map shows its elevation digit):
  a bridge, stairs, the Center's elevation-0 tile beside the stairs.
- A character in the way: does `walk` read the refusal the same way, and name the character.
- A ledge, a run, a bike, and a wild encounter or a trainer's sight during a walk (`moved` for a hop,
  `left_overworld`, `dialogue_open`).
- Other values of +0x1C, what byte 1's 0xA0 means, and the +0x1E/+0x1F bytes that read 0x69 on the
  door; the warp entry's +4 and +5.
