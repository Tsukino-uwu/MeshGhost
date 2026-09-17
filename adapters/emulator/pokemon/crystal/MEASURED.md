# Measured — Pokémon Crystal

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

Sibling records: [Pokémon Emerald](../emerald/MEASURED.md), [TEVI](../../../tevi/MEASURED.md), [Pseudoregalia](../../../pseudoregalia/MEASURED.md).

**Older code-level entries still sit in `UNVERIFIED.md` and `VERIFIED.md`**: sorting them into
this file is a queued task (`agent_docs/status.md`, 2026-09-16). Until it runs, look there too.

**Keep the `## Index` section below, one line per `###` entry in either section.** This file only
grows, like `VERIFIED.md`, so the index is what keeps it findable.

## Index

- Which ROM: the hash autoplay checks (2026-09-17)
- Where the player is, and whether the overworld is running (2026-09-17)
- A step on foot, a refused step, and a door (2026-09-17)
- The map's warp list (2026-09-17)
- Text on screen: the tile buffer, the message box and what each byte draws (2026-09-17)
- A menu with a cursor, and when the game sees a button (2026-09-17)
- The map around the player, the characters on it, and its signs (2026-09-17)
- A script taking over: a scene, a character walking over, a wild encounter (2026-09-17)
- Which font is loaded, and a picture drawn with the letters' tiles (2026-09-17)
- A wild battle: when it is one, its two menus and its font (2026-09-17)
- advance_text and battle through the shared machine (2026-09-17)
- The battlers, their moves, and what a move's power and accuracy bytes do (2026-09-17)
- The warp cheat: the game's own map load, to Route 30 (2026-09-17)
- A trainer battle: sight, approach, the battle's own waits with no ▼, and the words after (2026-09-17)
- The PACK: its pockets, the item pocket, and its list that scrolls (2026-09-17)
- A trainer talked to (2026-09-17)
- The ball pocket, a POKé BALL thrown in a battle, and a second Pokémon in the party (2026-09-17)
- A warp written while a trainer's script runs; the switch question and the nickname question in a battle (2026-09-17)
- A house's mat, a trainer before it loads, and `goto` ridden (2026-09-17)
- The party's moves, PP, item and status, the POKéMON menu, a heal, and a defeat flag cleared in a trainer's line (2026-09-17)
- Badges on the trainer card (2026-09-17)
- The key item pocket, and riding the BICYCLE (2026-09-17)
- The TM/HM pocket, and a list that redraws for 11 frames (2026-09-17)
- Surfing, and a poisoned party on foot (2026-09-17)
- Not measured yet: The rest of autoplay's Crystal reading (from 2026-09-17)

## Measured

### Which ROM: the hash autoplay checks (2026-09-17)

**Vanilla V1.0.** `sha1sum` of the ROM file and of our pokecrystal build's `.gbc` both read
`F4CD194B…18C133`, and `gameinfo.getromhash()` in BizHawk returned the same string, upper case
(`probes/autoplay_state_probe.lua`'s first log line, `logs/autoplay_state_7871_20260917_002042.log`).
So the build's `.sym` gives addresses on this ROM; every meaning below is from the running game.
`autoplay/drivers/bizhawk/games/crystal.lua` reads and drives only when the hash matches. What this
could not see: any other build (V1.1, Speedchoice, Archipelago), none of which was run.

### Where the player is, and whether the overworld is running (2026-09-17)

**Vanilla V1.0, a save in New Bark Town (map 24.4) with no Pokémon.** `probes/autoplay_state_probe.lua`
(read-only, every watched byte on change) through a cold boot, the intro, the title, the main menu,
CONTINUE, walks in all four directions, a sign, the START menu, the PACK, the POKéGEAR and a door each
way, read against captures `dev-scripts/shots/crystal/autoplay_boot_00`..`05`, `sign_*`, `start_*`,
`pack_*`, `gear_*`, `door_*` (gitignored).

- **Map and tile.** wMapGroup/wMapNumber (01:DCB5/DCB6) read 0.0 through the intro, title and main menu
  and 24.4 once CONTINUE loaded the town; through the door they read 24.9, and back 24.4.
  wXCoord/wYCoord (DCB8/DCB7) are the player's tile, and change on the frame a step ENDS. The player
  object (01:D4D6) holds the step's target at +0x10/+0x11, 4 more than those (12,14 against 8,10; 6,11
  against 2,7).
- **Facing.** The player object's +0x08 read 0x00 after a turn down, 0x04 up, 0x08 left, 0x0C right.
- **Running or not.** wMapStatus (01:D432) read 0 until the town was running, then 2 through walking,
  the sign's text and the START menu, and 1 from the frame after a step onto a door until the new map
  ran (32 frames in, 37 out). wSpriteUpdatesEnabled (00:C2CE) read 1 in all of those and 0 exactly while
  the PACK (f19906-20034) or the POKéGEAR (f20132-20278) filled the screen; wStateFlags' bit 0 moved with
  it. autoplay's `mode` is `overworld` for status 2 with sprite updates on.
- **Not seen:** a battle (the save has no Pokémon), a cutscene, the Fly map or any other full-screen menu.

### A step on foot, a refused step, and a door (2026-09-17)

**Same run, same probe.** Held walks right 2, down into a roof, up 2, left 2; a press into the roof from
rest; a door entered from below and left from its inside mat. Used by `crystal.lua`'s `walk`.

- **The overworld moved the player on even frames only**, every 2 frames.
- **Direction codes.** wWalkingDirection (01:D043), and wPlayerStepDirection (01:D151) while a step ran,
  read 0 down, 1 up, 2 left, 3 right; 255 with nothing held.
- **wPlayerMovement (00:C2DF)** read 62 at rest, 4 + the code while turning (6 frames, when the press
  faced another way; no step began until 2 frames after), 12 + the code while stepping, and 80 while a
  step was refused: for as long as the direction stayed held, with the coordinates unchanged and the
  object's +0x0B reading 3 (1 at rest, 2 turning or stepping).
- **A step.** It begins on the frame +0x10/+0x11 move and +0x07 reads 4 + the code (FF otherwise); 14
  frames later wXCoord/wYCoord and +0x12/+0x13 catch up and +0x07 is FF again. Held, the next step began
  2 frames after that end; released at any point during a step, the step finished and wPlayerMovement
  read 62 2 frames after its end. A 20-frame press walked 2 tiles for that reason.
- **The engine's neighbour bytes** wTileDown..wTileRight (00:C2FA-C2FD) changed mid-step: 7 beside the
  roof bumped from above and the sign, 0x29 beside the water `walk` was refused by at (18,9) — the value
  `probes/cmd_drive.lua`'s header records for water (2026-09-16).
- **A door.** The step onto (11,13) ended and wMapStatus read 1 on the next frame; the map id changed 8
  frames later and status read 2 again 24 frames after that. Leaving by the mat: the press turned the
  player and wMapStatus went straight to 1 with no step; once the outside map ran, the game walked the
  player one tile off the door by itself, 2 frames after status 2 — so a first `walk` answered on the
  door tile, and now waits 8 frames of rest.
- **Live through `walk`:** right 3 (59 frames), up 5 (91), left 3, left 1, `blocked` after 3 tiles with
  collision 0x29 and at once from rest, `map_changed` into 24.6 on the 4th tile and out again, ending on
  (13,6); `dialogue_open` and `menu_open` at once with a box or the START menu up.
- **Not seen:** a character in the way, a ledge, a bike or surfing (wPlayerState, 01:D95D, read 0 on foot
  throughout), an edge between maps, a wild encounter or a trainer during a walk.

### The map's warp list (2026-09-17)

**Same run.** wCurMapWarpEventCount (01:DBFB) and the pointer at DBFC-DBFD into the bank in wMapScriptsBank
(01:D1A3): 4 entries on 24.4, 2 on 24.9, 5 bytes each. Read as y, x, a destination warp number counted
from 1, a map group and number: 24.4's fourth entry is (13, 11, 1, 24, 9), and walking up onto (11,13)
arrived on 24.9 at (2,7), the tile of 24.9's first entry; both of 24.9's entries, (7,2) and (7,3), name
24.4's warp 4, and stepping off the mat arrived on 24.4 at (11,13). Walking up onto (13,5), 24.4's second
entry, arrived on 24.6. **Not seen:** a warp that is not a door (a cave mouth, stairs), an entry whose
destination warp is not 1 or 4.

### Text on screen: the tile buffer, the message box and what each byte draws (2026-09-17)

**Vanilla V1.0, New Bark Town.** `probes/autoplay_text_probe.lua` (read-only: the 18 rows of wTilemap,
00:C4A0, 20 wide, and wTextboxFlags, 00:CFCF, on change) through the town sign's three boxes, twice, and
SAVE's question; `probes/autoplay_charset_probe.lua` (writes wTilemap inside an open box) for the glyphs.
Logs `logs/autoplay_text_7871_20260917_003358.log`, `..._003702.log`, `logs/autoplay_charset_*.log`;
captures `autoplay_txt_*`, `autoplay_charset_p0`..`p2`, `autoplay_charset_sheet` (gitignored).

- **The text is the tile buffer.** Every letter printed was written into wTilemap, one a frame, and on
  the frame the sign's box closed the map's own tiles were back in rows 12-17.
- **The message box.** Rows 12-17: 79 and 7B the top corners, 7D and 7E the bottom ones, 7A the top and
  bottom edges, 7C the sides. Lines print on rows 14 and 16, columns 1-18; a new box scrolled them up
  through rows 13 and 15. While a box waited for a button, 0xEE (▼) was drawn at (18,17) for 16 frames
  and gone for 16, repeatedly (nine changes in a 150-frame wait); on the sign's last box it never came.
  No HRAM byte changed in step with the blink (the probe's HRAM dump, FF80-FFFE, through the same wait:
  three counted seconds, four changed every frame).
- **Printing or done.** wTextboxFlags read 3 from the frame before a message's first letter and 1 from the
  frame after its last: the sign's last box (last letter f15397, 1 at f15398) and SAVE's question (last
  letter f17333, 1 at f17334, the frame its YES/NO was drawn). An empty box frame stood for 4 frames
  before the save question's flags went to 3.
- **What each byte draws**, named from the charset probe's captures (0x60-0xFF, 72 to a page, rows 13-16),
  every glyph checked against the real text read: A-Z are 0x80-0x99, a-z 0xA0-0xB9, 0-9 0xF6-0xFF, 0x7F
  the space; `crystal.lua`'s table holds the rest, among them 0x70 and 0x71 ("PO", "Ké", drawn as one
  word in POKéGEAR), 0xD0-0xD6 ('d 'l 'm 'r 's 't 'v), 0xE1/0xE2 (PK, MN), 0xE6 ?, 0xE7 !, 0xE8 and 0xF2 each
  a dot, 0xEC ▷, 0xED ▶, 0xEE ▼, 0xEF ♂, 0xF5 ♀, 0xF0 ₽, and 0x63-0x6D a bold D E F G H I V S L M :. Nothing
  was drawn for 0xBA-0xBF, 0xC6-0xCF, 0xD7-0xDE, 0xE4 and 0xE5. 0x62 (a small boxed shape) is not named.
- **Real text read with it:** "NEW BARK TOWN", "The Town Where the / Winds of a New / Beginning Blow",
  "Would you like to / save the game?", the START menu's items and all six descriptions, "PLAYER A",
  "BADGES 0", "TIME 0:10", the main menu's CONTINUE / NEW GAME / OPTION and "SUNDAY / DAY 2:32".
- **Not seen:** bytes below 0x60 in text (in the overworld they are the map's tiles), any other font (a
  battle's), any text speed but this save's (wOptions read 1).

### A menu with a cursor, and when the game sees a button (2026-09-17)

**Same probe**, its `menu` line (0x40 bytes from wWindowStackPointer, 00:CF71): the START menu with Down
pressed four times, SAVE chosen, its YES/NO, B back out; then autoplay's `select`.

- **Open windows.** wWindowStackSize (00:CF78) read 0 with none, 1 with the START menu, 2 once SAVE's
  box was drawn, 4 with the YES/NO, then 3, 2 and 1 as B closed them. wWindowStackPointer (CF71-CF72) read
  DFFD with none open and again once B closed the START menu (`autoplay_state_probe.lua`). The sign's box
  changed none of the menu block.
- **The menu's shape.** CFA1/CFA2 held the first item's row and the cursor's column (2, 11 on START; 8, 1
  on the YES/NO; the main menu's items also read), CFA3/CFA4 the rows and columns (6, 1; 2, 1), CFA7's high
  nibble the rows between items (2 on both, as drawn), CF85 the frame's right column (19; 5).
- **The cursor.** wMenuCursorY (CFA9) counted from 1 and moved one item per Down press; wCursorCurrentTile
  (CFAC-CFAD) pointed at the ▶'s cell (C4D3 on PACK, row 2 column 11; C54B on SAVE). The ▶ turned into ▷
  (0xEC) once A chose SAVE, and back when its YES/NO closed.
- **When the game sees a button.** hJoyDown (FFA8) is the game's copy of the buttons, changed only when
  it looks: in the START menu it read Down at f16525, hJoyPressed went back to 0 four frames later with
  Down still held, and hJoyDown stayed Down for the 36 frames it was held. autoplay's `select` released
  for 2 frames between moves, the menu never saw the release, and the held Down never moved the cursor
  again; waiting until hJoyDown reads 0 fixed it: down 4 in 33 frames, up 4 in 35, EXIT confirmed, and
  NO reached on the YES/NO (its ▶ on NO in `autoplay_yesno_no`), which was left with B, never confirmed.
- **Not seen:** a menu with more than one column, a scrolling list (the PACK's items, the PC), a menu
  whose items are not 2 rows apart.

### The map around the player, the characters on it, and its signs (2026-09-17)

**Vanilla V1.0: New Bark Town, Elm's lab (24.5), Route 29 (24.3).** `probes/autoplay_map_probe.lua`
(read-only: 11 by 15 tiles of block id and collision around the player, every object record, every
map-object record and the coord, bg and object event lists, on each tile, map or object change), read
against captures with a tile grid drawn over them (`autoplay_map_00_grid`, `coll15_00_grid`,
`route29_00_grid`, `route29_01_grid`, gitignored), and `walk` into what it named.

- **The collision formula holds on three maps.** `cmd_drive.lua`'s (2026-09-16): block (x//2, y//2) at
  (by+3)*(wMapWidth+6)+(bx+3) in wOverworldMapBlocks, quadrant (y%2)*2+(x%2) of its four bytes in the
  collision table at wTileset+6 (bank) / +7 (pointer). New Bark's capture agreed tile for tile: roofs,
  walls, the sign at (8,8) and the mailbox at (9,13) 0x07; both doors 0x71, at the warp list's (11,13)
  and (13,5); the left house's door (3,11) 0x71 and in the warp list; open ground and grass patches 0x00.
  On every refused step the engine's own neighbour byte equalled the computed one: 0x07 at (1,14), 0x15
  at (5,15) and (2,15), 0x29 at (18,9). 0x15 was drawn as trees along the town's south edge and refused a
  step; 0x18 was drawn as tall grass on Route 29 and was walked on, and a wild battle began on its 4th
  step there. The map is wMapWidth by wMapHeight blocks (10 by 9 in town, 5 by 6 in the lab); tiles past
  that are the next map's or border.
- **The characters.** Object records 1-12 (0x28 bytes from 01:D4FE) whose first byte is not 0: +0x00 the
  graphic, +0x01 the index in the map's object list, +0x08 the facing (the player's codes: the girl drawn
  facing down read 0x00, then drawn from behind read 0x04; the man drawn from behind 0x04),
  +0x10/+0x11 the tile plus 4 — (6,8) and (12,9) in the capture, and Elm at (3,4) and the three Poké
  Balls on the lab's table at (6,3)-(8,3). When the girl walked from (6,8) to (1,8) in her scene, +0x10
  followed her tile by tile. A character stands in the way like a wall: `walk` into the girl at (6,8) read
  wPlayerMovement 80 (refused) on a tile whose own collision is 0x00. A character off screen loaded when
  the player came near (map object 3, graphic 4, at (3,2) outside the lab), and the ball taken from the
  table left the records. One record read graphic 255, index 255 and movement 28 on Elm's own tile during
  his scene; what it is was not looked at.
- **Signs.** The bg event list (count 01:DC01, pointer DC02 in wMapScriptsBank), 5 bytes an entry: y, x,
  then a kind and a script pointer. Its (8, 8, 0) is the sign that showed "NEW BARK TOWN"; its (13, 9) is
  the mailbox, (5, 11) the sign by the door at (13,5), and Route 29's (7, 51) was drawn as a sign.
- **Not seen:** what 0x9D (in the lab's back wall) does; a ledge through `walk`; what the coord event
  list's bytes mean beyond its entries sitting on New Bark's west exit.

### A script taking over: a scene, a character walking over, a wild encounter (2026-09-17)

**Same run, `probes/autoplay_state_probe.lua`.** wScriptRunning (01:D438) went 0 to 255 on the frame
after a step ended on a tile that starts something: New Bark's west exit (1,9) with no Pokémon
(wScriptMode 1; "Wait, A!" printed 10 frames later, then the girl walked over and walked the player back
east), the tile in Elm's lab where his aide steps in front of the player (mode 2 while she walked, then
1), and a step in Route 29's tall grass (mode 1; wBattleMode 1 about 180 frames later). Plain walking only
ever read 9 (a turn, mode 3) and 5 (a door, mode 1). Held input did nothing once it read 255: `walk` held
Down for 135 frames at the aide's tile before giving up, and once it stopped on 255 it answered
`script_started` on the lab and exit tiles and in the grass. 255 also read while a message, a menu or a
Pokémon's picture waited. **Not seen:** a trainer's approach.

### Which font is loaded, and a picture drawn with the letters' tiles (2026-09-17)

**Vanilla V1.0.** In Elm's lab a Cyndaquil picture filled rows 4-13 inside a frame, drawn with tile ids
0x80-0xB0 in columns, while the script waited for a button with no message box (wScriptRunning 255);
`screen_text` read it as "AHOV:dk". `probes/autoplay_font_probe.lua` (read-only) logged an FNV-1a
checksum of each id range's tiles in VRAM bank 0 (LCDC read E3 on every screen, so ids 0x80-0xFF at offset
0x0800 and 0x00-0x7F at 0x1000) while snapshots of each screen were restored:

| Screen | 0x80-0xB9 | 0x60-0x7F | 0xBA-0xFF |
| --- | --- | --- | --- |
| town sign's box, START menu, main menu, Elm's question | ABC168AD | 463433A3 | 55247223 |
| wild battle (message and move menu) | ABC168AD | 0E4FC271 | 55247223 |
| Cyndaquil's picture | A75F347B | (not logged) | (not logged) |
| New Bark with no text up | CF66AFAD | (not logged) | (not logged) |

**The battle's 0x60-0x7F**, charset-probed in its message box ("Wild PIDGEY appeared!",
`autoplay_charset_60_7F_overworld_vs_battle`, gitignored): 0x6E the ":L" before a level (PIDGEY's "3",
CYNDAQUIL's "5"), 0x75 "…", 0x79-0x7F the frame and the space as in the town; the rest drew HP-bar pieces
and shapes. `crystal.lua` names 0x80-0xFF only while the first checksum reads ABC168AD for `screen_text`,
and 0x60-0x7F only by the table whose checksum is loaded.

### A wild battle: when it is one, its two menus and its font (2026-09-17)

**Vanilla V1.0, Route 29, a wild PIDGEY (L3) against CYNDAQUIL (L5).** `autoplay_state_probe.lua` and
`autoplay_text_probe.lua`, captures `autoplay_battle_00`..`02` (gitignored).

- **When.** wBattleMode (01:D22D) went 0 to 1 about 180 frames after the encounter's script began, on the
  frame wSpriteUpdatesEnabled went 1 to 0, and read 1 through the text, both menus and "Got away
  safely!"; wMapStatus read 2 from the encounter to the battle's first text (the frames the probe logged).
  After A on "Got away safely!", `mode` read `overworld` again on the same tile within 240 frames. `mode`
  says `battle` while wBattleMode is not 0.
- **The action menu** used the block the START menu does: first row 14 and cursor column 9, 2 rows by 2
  columns (CFA3, CFA4), CFA7 0x26 — items 2 rows and 6 columns apart (FIGHT at column 10, PKMN at 16) —
  wMenuCursorY and wMenuCursorX (CFAA) both from 1, the ▶ at wCursorCurrentTile, wWindowStackSize 1. It is
  drawn inside a frame shaped like the message box (rows 12-17), beside an empty left box.
- **The move menu** (FIGHT, then A): first row 13, column 5, 2 rows (the two moves CYNDAQUIL knew) by 1,
  CFA7 0x10, the ▶ at its cell — and wWindowStackSize 0. B went back to the action menu.
- **Live through `select`:** RUN reached in 2 steps (Right, then Down) and confirmed; "Got away safely!".
- **Not seen:** a trainer battle, the battlers' species, HP and moves in memory, a Pokémon fainting, the
  PKMN and PACK screens in a battle.

### advance_text and battle through the shared machine (2026-09-17)

**Vanilla V1.0, the session's snapshots.** `autoplay/drivers/bizhawk/text.lua` with Crystal's hooks, live:
`advance_text` closed the town sign's three boxes (221 frames), stopped `menu_open` at Elm's "You'll take CYNDAQUIL"
YES/NO (28), got through "A received POTION." and its jingle to "always busy." (651), and read the west exit's six
boxes while the girl walked the player back to (5,8) (688); `battle` with policy `run` chose RUN and ended in the
overworld (480). Two readings the hooks rest on: **hJoyDown's bit 0 is A** (it read 1 while each A was held in the
message boxes and 0 once let go, `autoplay_text_probe.lua`), so a tap holds A until the game has seen it; and **no
message box had a frame tile (0x79-0x7E) in columns 1-18** of rows 13-16, while the battle's action menu drew a 0x7C
column at 8 before its ▶ -- read as a message until that became a condition. **Not seen:** a trainer's words before
and after a battle, a level-up, a battle won.

### The battlers, their moves, and what a move's power and accuracy bytes do (2026-09-17)

**Vanilla V1.0, Route 29, the wild PIDGEY (L3) against CYNDAQUIL (L5)**, from the snapshots `battle_pidgey_appeared` and
`battle_menu` (the move menu). `probes/autoplay_battle_probe.lua` (read-only; logs `logs/autoplay_battle_7871_20260917_013116`,
`_013317`, `_013711`, `_014010`) read against `observe`'s `screen_text` and captures `autoplay_bprobe_move_menu`, `_leer`,
`_menu_turn2`, `autoplay_party_after_win`, `autoplay_trainer_card` (gitignored); `probes/autoplay_move_write_probe.lua`
(writes, `logs/autoplay_move_write_7871_20260917_013317.log`) for power and accuracy. Used by `crystal.lua`'s `battle`
field, `strongestMove` and `endedReport`.

- **The battlers.** 0x20 bytes at 00:C62C (the player's) and 01:D206 (the opponent's). +0x00 the species: 155 and 16,
  whose entries in the name table (10 bytes at 14:7384 + (id - 1) * 10) spelled CYNDAQUIL and PIDGEY as the screen drew
  them. +0x02-+0x05 the moves: 33, 43, 0, 0 as the move menu listed TACKLE, LEER, -, -; PIDGEY's 33, 0, 0, 0, and
  "Enemy PIDGEY used TACKLE!". +0x08-+0x0B their PP: 35 and 30 as the move box drew 35/35 and 30/30; 34 once TACKLE was
  used, drawn 34/35, then 33, 32, 31 a use; PIDGEY's 35 went to 34, 33, 32 a TACKLE. +0x0D the level: 5 and 3, drawn :L5
  and :L3. +0x10/+0x11 the HP and +0x12/+0x13 the max HP, high byte first: 19 and 19 drawn 19/19, then 16 drawn 16/19;
  PIDGEY's 15 of 15, then 10 while its bar went from 48 green pixels to 32 (the captures, counted). The nicknames at
  00:C621 and 00:C616, 0x50-ended, spelled CYNDAQUIL and PIDGEY. Before "Go! CYNDAQUIL!" the player's block read all 0,
  and it filled on the frame the Pokémon came out; once wBattleMode went to 0 the player's block was overwritten with
  other data within 41 frames, so it is read only while wBattleMode is not 0.
- **The move data.** The table at 10:5AFB, 7 bytes an entry from id 1: TACKLE's `21 00 23 00 F2 23 00`, LEER's
  `2B 13 00 00 FF 1E 00`. The player's move struct (00:C60F) held the entry of the move under the move menu's ▶ (TACKLE's,
  then LEER's with the ▶ moved) and was loaded again on the turn; the opponent's (00:C608) held its TACKLE's on its
  turn. +0x03 the type: 0 for both, and the pointer at 14:497B + 2 * 0 led to "NORMAL", drawn TYPE/ NORMAL. +0x05 the PP
  drawn as the maximum (35, 30), on a Pokémon whose PP were never raised. Move names: the id'th 0x50-ended string from
  72:5F29 spelled TACKLE (33) and LEER (43), as the menu drew them.
- **Power and accuracy, by what they did.** Crystal draws neither, so one TACKLE was replayed from `battle_menu` with one
  byte of the player's move struct held at a value every frame (the probe's log shows each write read back, and the
  struct reloaded 7 frames after the restore and rewritten on that frame, 30 frames before the damage was computed). Two
  runs with nothing written matched frame for frame (wCurDamage, 01:D256, 6 then 5; PIDGEY 15 to 10), so each row
  differs from them only by the byte:

  | Byte | Value | wCurDamage | PIDGEY's HP | Text |
  | --- | --- | --- | --- | --- |
  | +0x02 | 35 (the table's) | 6, then 5 | 15 → 10 | CYNDAQUIL used TACKLE! |
  | +0x02 | 0 | not set | 15 | CYNDAQUIL used TACKLE! |
  | +0x02 | 70 | 10, then 8 | 15 → 7 | CYNDAQUIL used TACKLE! |
  | +0x02 | 140 | 19, then 16, then 15 | 15 → 0 | Enemy PIDGEY fainted! |
  | +0x04 | 0 | 6, then 5 | 15 | CYNDAQUIL's attack missed! (wAttackMissed, 00:C667, 1) |
  | +0x04 | 255 | 6, then 5 | 15 → 10 | CYNDAQUIL used TACKLE! |

  So +0x02 is the power and +0x04 the accuracy. With 0 held, the byte read 1 on the frame the miss was decided: the game
  had changed it. The scale of +0x04 is not measured (242 missed once, on the first turn from
  `battle_pidgey_appeared`), so autoplay reports it as `accuracy_raw` and only compares it.
- **After the battle.** wBattleResult (01:D0EE) read 0 after "Enemy PIDGEY fainted!" and 2 after "Got away safely!", in
  the overworld. wMoney (01:D84E), 3 bytes high first, read 3000 as the trainer card drew MONEY ₽3000. The party's first
  Pokémon (0x30 bytes from 01:DCDF, wPartyCount 01:DCD7 reading 1, its nickname at 01:DE41): +0x00 155, +0x1F the level
  5, +0x22/+0x23 the HP and +0x24/+0x25 the max HP (10 and 19) as the POKéMON screen drew CYNDAQUIL :L5 10/19; its HP
  followed the battle's on the same frames. Also read: +0x06/+0x07 34555 as the card drew the ID No., and +0x08-+0x0A
  135 then 158 as "CYNDAQUIL gained 23 EXP. Points!" printed.
- **A battle's message box is cleared over 2 frames**: row 14 on one and row 16 on the next (`autoplay_text_probe.lua`,
  `logs/autoplay_text_7871_20260917_014010.log`, f52753 and f53728), and `battle`'s log listed the frame between as
  boxes ("            d!", "used TACKLE!"). A box whose rows changed since the frame before now reads `printing`.
- **Live through `battle` with policy `strongest`** from `battle_pidgey_appeared`: FIGHT and TACKLE four turns (LEER
  scores 0), one miss, "Enemy PIDGEY fainted!", "CYNDAQUIL gained 23 EXP. Points!", `ended` in 2168 frames with
  `outcome_raw` 0, money 3000 and CYNDAQUIL 10/19; RUN from the same snapshot, `outcome_raw` 2.
- **Not seen:** any move but TACKLE and LEER (so one power and one type in the table read against anything), a type
  other than NORMAL drawn, raised PP, a status, a level-up, the player's Pokémon fainting, a trainer battle, the party
  past its first slot, the scale of the accuracy byte, what +0x01 of a move entry (0x13 for LEER) does.

### The warp cheat: the game's own map load, to Route 30 (2026-09-17)

**Vanilla V1.0, from `route29_after_win` (24.3 at (53,12)).** `crystal.lua`'s `warp` cheat writes what
`probes/goto_map.lua` writes (its header, 2026-08-21: map group and number and the tile directly, wDefaultSpawnpoint
01:D001 0xFF, hMapEntryMethod FF9F 0xF1, wMapStatus 1). Read with `probes/autoplay_state_probe.lua` and
`probes/autoplay_map_probe.lua` (`logs/autoplay_state_7871_20260917_014819.log`, `logs/autoplay_map_7871_20260917_014819.log`)
and the capture `autoplay_route30_warp` (gitignored). Asked for 26.1 at (1,13): wMapStatus read 1 from the frame after the
writes (f57414) and 2 again 30 frames later; the map read 26.1 and the tile (1,13); the game drew its "ROUTE 30" sign; the
object records loaded the woman at (2,13) and, walking up, a character at (1,7). The cheat answered `done` in 31 frames.
**Not seen:** a warp onto a solid tile, water or a warp tile, a warp into a building, any map but 26.1.

### A trainer battle: sight, approach, the battle's own waits with no ▼, and the words after (2026-09-17)

**Vanilla V1.0, Route 30 (26.1), Bug Catcher Don at (1,7) facing down, CYNDAQUIL L5.** Snapshots `route30_warped`,
`route30_don_4below` (the player at (1,11)), `route30_don_battle_start`. Four read-only probes, each replaying from
`route30_don_4below`: `autoplay_state_probe.lua` and `autoplay_battle_probe.lua` (`logs/autoplay_state_7871_20260917_014819.log`,
`logs/autoplay_battle_7871_20260917_014819.log`), the new `autoplay_trainer_probe.lua`
(`logs/autoplay_trainer_7871_20260917_015340.log`) and `autoplay_text_probe.lua` (`logs/autoplay_text_7871_20260917_015635.log`),
with captures `autoplay_route30_y11`, `autoplay_route30_don_seen_a`/`_b`, `autoplay_don_caterpie_out`/`2` (gitignored).

- **Sight.** Standing at (1,11), four tiles below Don, for 120 frames: nothing. One step up to (1,10): two frames after the
  step ended wScriptRunning (01:D438) went 0 to 1 -- not the 255 of a sign, a scene or a wild encounter -- with wScriptMode
  1, then 2 while Don walked. On that frame hLastTalked (FFE0) read 4, Don's map object; D03F read 3, the tiles between
  them; D040 0; D03E 0x68, wMapScriptsBank; and D041-D04C held the 12 bytes his map-object record points at (below).
  An object record with graphic 255 and map object 255 sat on Don's tile while he came, as one did on Elm's in his scene;
  what it is was not looked at.
- **His map-object record** (16 x 0x10 from 01:D71E, indexed by an object record's +0x01): `02 25 0B 05 06 00 FF FF B2 03
  BE 57 FF FF 00 00` -- +0x00 the object record holding him (slot 2 in `nearby`), +0x01 his graphic (37), +0x02 and
  +0x03 his y and x plus 4, which followed his walk to (1,9), +0x08 0xB2, +0x09 3 (the range walked above), +0x0A a pointer (57BE) into
  wMapScriptsBank. The route's other two records whose +0x08 low nibble reads 2 are at (2,28), range 3, and (5,23), range
  1; no other record reads 2 there. Neither of those was walked into.
- **What that pointer holds**: `38 05 24 01 D8 59 03 5A 00 00 CA 57`. 0x0538 = 1336, and bit 0 of the byte 167 past
  wEventFlags (01:DA72) read 1 in the state the first win left, 0 once `route30_don_4below` was restored, and 1 after the
  replayed win;
  36 and 1 are what wOtherTrainerClass (D22F) and wOtherTrainerID (D231) read from the approach through the battle.
- **The words before.** "Instead of a bug POKéMON, I found a trainer!" in the message box, pressed with A, then no text
  while wScriptRunning stayed 1, until wSpriteUpdatesEnabled went 0 and 22 frames later wBattleMode read **2**: "BUG
  CATCHER DON wants to battle!". `advance_text` called when `walk` answered took 442 frames to `battle_started`.
- **The opponent before it is sent out.** From wBattleMode 2 until "BUG CATCHER DON sent out" began, wCurOTMon (00:C663)
  read 255 and the opponent's block still held the wild PIDGEY of the battle before, with its nickname zeroed; on the
  frame the first CATERPIE was written (L3, 16 HP, TACKLE and STRING SHOT, whose uses the log printed) it read 0, and 1
  for his second. wOTPartyCount (01:D280) read 2. In the wild battle wCurOTMon read 0 throughout.
- **Two waits with no ▼.** After "CYNDAQUIL grew to level 6!" the box cleared and a framed window from (9,0) to (19,11)
  -- corners 79 7B 7D 7E, ATTACK at row 1 column 11, then the five stats -- was drawn 114 frames after the message's last
  letter and stayed until A. After "BUG CATCHER DON was defeated!", "Argh! You're too strong!" printed and stayed until
  A. In both, wTextboxFlags read 1, no ▼ was drawn, and wTextDelayFrames (00:CFB2) counted 5, 4, 3, 2, 1 and back to 5
  until the A (reaching 5 31 and 36 times). Elsewhere in the replayed battle it went from 1 back to 5 on no screen; at
  the action menu it counted down once as A was pressed, and under "learned SMOKESCREEN!" once, with its ▼. Before the
  restore it had also cycled under a "wants to battle!" with its ▼, so the ▼ is read first. `battle` had waited 180
  frames and nudged at each.
- **The words after.** "A got ₽48 for winning!", and wMoney read 3048 against 3000: a second reading of it. The map
  reloaded (wMapStatus 1, then 2) with wScriptRunning 1 until it ran again, then 0; Don stood at (1,9).
- **Live through the tools** from `route30_don_4below`: `walk` up 1 answered `spotted` in 18 frames with `trainer`
  `{map_object: 4, tiles_away: 3}`; `battle strongest` straight after played his words, both CATERPIEs, the level-up box,
  "SMOKESCREEN" learned, his defeat and the prize to `ended` (6956 frames, `outcome_raw` 0, money 3048), with no nudge.
  `nearby` gave Don `trainer: {range: 3, beaten: false, flag: 1336}` before and `beaten: true` after; `local_map` marked
  (1,8)-(1,10) `!` before and nothing after. The earlier snapshots replayed unchanged (the sign 221 frames, the wild
  battle 2168 and 480, Elm's YES/NO 28, the west exit 688).
- **Not seen:** a trainer talked to first, a trainer that turns or walks, a range other than 3 walked, a sight line
  crossed by another character, a trainer battle lost, the other two trainers' flags changing, what +0x08's high nibble
  means.

### The PACK: its pockets, the item pocket, and its list that scrolls (2026-09-17)

**Vanilla V1.0, Route 30.** The new `probes/autoplay_bag_probe.lua` (read-only: wCurPocket, the pockets' cursor and scroll
bytes, the scrolling menu's header copy, the four pockets, each item's name and attribute entry) with
`autoplay_text_probe.lua`; logs `logs/autoplay_bag_7871_20260917_021016` (the pockets), `_021114` (the item ball), `_021200`
(the attributes), `_021244` and `logs/autoplay_text_7871_20260917_021244` (the scroll), `logs/autoplay_text_7871_20260917_021505`
(the redraw); captures `autoplay_pack_items`, `autoplay_pack9_*` (gitignored). Snapshots `route30_got_antidote`,
`route30_items9`, `pack_items9_open`.

- **The item pocket.** wNumItems (01:D892), then an id and a quantity per entry, then FF: `01 12 01 FF` while the PACK
  drew POTION ×1. Facing Route 30's item ball at (8,35) and pressing A printed "A found ANTIDOTE!" and "A put the
  ANTIDOTE in the ITEM POCKET.", and it read `02 12 01 09 01 FF`. Item names: the id'th 0x50-ended string from 72:4000
  spelled POTION (18) and ANTIDOTE (9). The 7 bytes at 01:67C1 + (id - 1) * 7 read `2C 01 00 14 40 01 55` and
  `64 00 00 00 40 01 55`: +0x05 01 for both, the pocket the game filed them in; nothing else there was read against
  anything. The ball, key item and TM/HM pockets read empty (`00 FF`, `00 FF`, all 0).
- **The pockets.** Right moved wCurPocket (00:CF65) 0 → 1 → 2 → 3, and the scrolling menu's header copy (from 00:CF91)
  pointed at the pocket shown: D892 on 0, D8D7 on 1, D8BC on 2, with height 5 at CF92 and 02 at CF94 (01 on the D8BC
  pocket). wItemsPocketCursor (01:D0D9) read 1, wMenuCursorY's value, once Right left the item pocket with the ▶ on its first row.
- **The list that scrolls.** With `give_item` (below) the item pocket held 9 entries; the PACK drew 5 rows (name, then
  the quantity on the row under it) and CANCEL after the last entry. Down 9 times from the top: wMenuCursorY (00:CFA9)
  1 to 5 down the rows shown, then 5 while the list moved; wMenuScrollPosition (01:D0E4) 0, then 1 to 5; wScrollingMenuListSize
  (01:D144) 9. So the entry under the ▶ is D0E4 + wMenuCursorY - 1, and CANCEL is at 9. The rows drawn were always
  the entries from D0E4 down, a long name cut at the screen's edge ("SUPER POTIO" read from the tiles, SUPER POTION
  from the table).
- **The redraw after a press.** Down at f65085 moved wMenuCursorY on that frame; the rows were redrawn over the next 3
  frames and the ▶ reached its new row at f65090. For those frames no menu read on screen, and `select` had stopped
  with "the menu closed or changed". `crystal.lua` keeps the whole list for 10 frames after it last read it.
- **Its description box** under the list read as a finished message ("Restores POKéMON / HP by 20."): it changed with
  the ▶ and is not a message the player presses through, so it goes out as the menu's `description`.
- **`give_item`** writes an entry the same way, for an item whose +0x05 reads 01: SUPER POTION ×3, REPEL ×2, ESCAPE
  ROPE, FULL HEAL, AWAKENING, BURN HEAL and ICE HEAL each read back, and the PACK drew each name and quantity.
- **Live through the tools** from `pack_items9_open`: `select` ICE HEAL (8 steps, the list scrolled), back to ANTIDOTE
  (7), CANCEL (index 9), then REPEL confirmed opened USE / GIVE / TOSS / QUIT (read as a menu, as drawn); `select` USE
  printed "A used the REPEL." and `advance_text` returned `menu_open` on the list with REPEL at 1 (2 before). Its log
  also listed the description box once, from the frames before the list's ▶ was back.
- **Not seen:** a list in another pocket with anything in it, the key item pocket's one-byte entries, TOSS or a quantity
  chooser, a full pocket, what CF77 (which alternated between two values each press) is, the PACK in a battle.

### A trainer talked to (2026-09-17)

**Vanilla V1.0, Route 30, Youngster Mikey at (5,23) facing down**, from `route30_warped` warped to (5,20); snapshot
`route30_facing_mikey`. `probes/autoplay_trainer_probe.lua` (`logs/autoplay_trainer_7871_20260917_022238.log`).

- `walk` down 3 answered `blocked` after 2 tiles with his map object (3) in the way. `nearby` gave him `trainer: {range:
  1, beaten: false, flag: 1450}` (his record's +0x09 1); nothing was marked `!`, since the tile below him holds another
  character.
- A pressed facing him: wScriptRunning went 0 to **2** (not the 1 of a trainer who sees the player), wScriptMode 1,
  hLastTalked 3, D03F 1, D040 FF, and D041-D04C `AA 05 16 02 28 59 5F 59 00 00 B6 57`: flag 1450, then 22 and 2, which
  wOtherTrainerClass and wOtherTrainerID read two frames later.
- `battle strongest` from there: "You're a POKéMON trainer, right?", "Then you have to battle!", "YOUNGSTER MIKEY wants to
  battle!", his PIDGEY, the level-up box, "That's strange. I won before." and "A got ₽64 for winning!", to `ended` in 5063
  frames with no nudge; money 3064 against 3000 in that snapshot. His `beaten` then read true (flag 1450's bit set).
- **Not seen:** talking to a beaten trainer, a trainer talked to from beside or behind.

### The ball pocket, a POKé BALL thrown in a battle, and a second Pokémon in the party (2026-09-17)

**Vanilla V1.0, Route 31 (26.2).** `probes/autoplay_bag_probe.lua` (`logs/autoplay_bag_7871_20260917_022537`, `_023151`),
`probes/autoplay_battle_probe.lua` (`logs/autoplay_battle_7871_20260917_023151`, `_023923`, the second with every party
slot), `probes/autoplay_text_probe.lua` (`logs/autoplay_text_7871_20260917_023014`); captures `autoplay_pack_balls`,
`autoplay_battle_pack`, `autoplay_battle_ball_menu`, `autoplay_battle_ball_thrown2`, `autoplay_party2` (gitignored).
Snapshots `route31_got_ball`, `route31_balls6`, `route31_wild_bellsprout`, `battle_ball_use_menu`,
`battle_caught_bellsprout`, `route31_caught_bellsprout`.

- **The ball pocket.** Route 31's item ball at (19,15), faced and pressed: "A found POKé BALL!", "A put the POKé BALL in the
  BALL POCKET.", and wNumBalls (01:D8D7) read `01 05 01 FF` (from `00 FF`). POKé BALL's name is `54 7F 81 80 8B 8B 50`
  in the table at 72:4000, printed "POKé BALL": 0x54 printed as POKé. Its attribute entry read `C8 00 00 00 40 03 06`,
  +0x05 03. `give_item` added 5 more; the PACK's ball pocket then drew POKé BALL ×6 and CANCEL, and the list reader,
  with the header pointing at D8D7 and wCurPocket 1, read the same. BICYCLE's +0x05 read 02 and was refused.
- **Mom's call on the way.** A step in the grass stopped `walk` with `script_started` and no text; the POKéGEAR rang,
  then "MOM:" in a box at the top and "Hello?" below, then "What about money? Should I save it?" with YES / NO (NO
  chosen through `select`), then "Click!". `advance_text` read all of it.
- **The PACK in a battle.** A wild BELLSPROUT (L5, VINE WHIP, 20 HP): PACK from the action grid opened the PACK on the
  pocket last shown (the ball pocket), read whole as out of a battle. POKé BALL chosen opened USE / QUIT (read as drawn),
  over the item's description. That box read `waiting_for_button`: wTextDelayFrames counted 5 down to 1 and back
  under it for as long as the menu waited (249 times), as under the PACK's list out of a battle — so under a menu the
  count no longer makes a box wait.
- **The throw.** USE printed "A used the POKé BALL." and the ball shook on the opponent's side; the ball pocket read 5.
  Replayed from `battle_ball_use_menu` with 3, 9, 17, 29 and 41 frames before USE: "Aww! It appeared to be caught!",
  "Shoot! It was so close too!" twice, "Aargh! Almost had it!", and at 41 "Gotcha! BELLSPROUT was caught!", then "Give a
  nickname to BELLSPROUT?" with YES / NO, still in the battle (wBattleMode 1); NO ended it.
- **The second party slot.** wPartyCount 2, the species list at 01:DCD8 `9B 45 FF`, and 0x30 bytes after the first
  slot: `45 00 16 00 00 00 86 FB 00 00 87 …` with +0x1F 05, +0x22/+0x23 20 and +0x24/+0x25 20; its nickname 11 bytes
  after the first's spelled BELLSPROUT. The POKéMON screen drew CYNDAQUIL :L5 10/19 and BELLSPROUT :L5 20/20. It also
  read the player's ID (34555) at +0x06 and 135 at +0x08-+0x0A. `battle run` in the next wild battle ended with
  `party` listing both.
- **Not seen:** a third slot, a nickname given, a Pokémon sent to the PC, a throw at a weakened or paralysed Pokémon
  (the user, on being told of the replays: catching is easier at lower HP and with a status such as paralysis), the
  key item and TM/HM pockets with anything in them.

### A warp written while a trainer's script runs; the switch question and the nickname question in a battle (2026-09-17)

**Vanilla V1.0, Route 30 (26.1), Bug Catcher Don, with CYNDAQUIL (L5, 10/19) and BELLSPROUT (L5, 20/20) in the party**, from
`session_end_route31`. `observe` through the autoplay tools, then `probes/autoplay_text_probe.lua` (`logs/autoplay_text_7871_20260917_031530.log`);
captures `autoplay_scn_warp_mid_approach`, `_after_a`, `_after_a2`, `autoplay_scn_party_menu_after_yes`, `autoplay_switch_question`,
`autoplay_nickname_question` (gitignored). Snapshots `route30_don_battle_start_2party`, `battle_don_party_menu_after_yes`,
`battle_don_switch_question`, `battle_nickname_question`.

- **A warp during Don's words.** After `walk` answered `spotted`, with "Instead of a bug / POKéMON, I found" waiting and
  wScriptRunning 1, the `warp` cheat's writes (26.1 at (1,11)) left wMapStatus at 1 and the map did not load: 900 frames
  with the box up and `mode` `not_overworld`. A went on through his words ("a trainer!", then A) and wBattleMode read 2
  ("BUG CATCHER DON wants to battle!") with wMapStatus still 1. After `battle strongest` won it (3339 frames) the map ran
  with the player on (1,11), the tile the warp had written, and Don beaten at (1,9). The cheat now refuses while
  wScriptRunning reads anything but 0.
- **The switch question.** After "Enemy CATERPIE fainted!", the EXP, level 6, the stats box and "CYNDAQUIL learned
  SMOKESCREEN!", the box printed "BUG CATCHER DON / is about to use", "is about to use / CATERPIE.", then "Will A" on row
  14 and "change POKéMON?" on row 16 (last letter f138085). On f138086 a frame was drawn at rows 7-11, columns 1-6 (79 and 7B
  at (1,7) and (6,7), 7D and 7E at (1,11) and (6,11)) with YES on row 8 and NO on row 10 from column 3, and the ▶ at (2,8) on
  f138090. The menu block read wWindowStackSize 2, first row 8 (CFA1), column 2 (CFA2), 2 rows by 1 column, CFA7 0x20;
  wTextboxFlags 1, no ▼, wTextDelayFrames counting 5 down to 1 and back while it waited, wScriptRunning 1.
- **YES, and back out.** On the first run `battle` had no reader for it, nudged A after 180 frames, and YES opened "Which
  PKMN?" with the party and CANCEL (the menu reader read the rows cut at the frame: "CYNDAQUIL  18/ 2"). The user, watching:
  *"you pressed "yes" for swapping a pokemon during a trainer fight after defeating a pokemon ( there is a setting to
  change this in options, set/shift i think) so now you either have to B/cancel/go back. or pick another pokemon"*.
  `select` CANCEL went back into the battle, CYNDAQUIL still in, and Don sent out his second CATERPIE.
- **Answered NO.** With the reader, `battle` stopped `needs_choice` on the question without pressing; answering NO, from
  `battle_don_switch_question` it pressed Down and A, logged `chose NO` with the question, and played Don's second
  CATERPIE to `ended` (3107 frames, `outcome_raw` 0, ₽3048), CYNDAQUIL in throughout.
- **The nickname question.** From the snapshot at "Gotcha! BELLSPROUT was caught!", 40 frames on the box read "Give a
  nickname to" / "BELLSPROUT?" and a YES/NO was framed at rows 7-11, columns 14-19: first row 8, column 15 (14 before the
  ▶ was drawn), the same block. `battle` stops `needs_choice` there, kind `nickname`.
- **Replayed after the change, unchanged:** the town sign (221 frames), Elm's YES/NO (28), the wild PIDGEY with
  `strongest` (2168) and `run` (480).
- **Not seen:** the switch question with the OPTION the user named set the other way; "Use next POKéMON?" after the
  player's Pokémon faints; the question to forget a move for a new one; what the party menu in a battle reads past its cut
  rows.

### A house's mat, a trainer before it loads, and `goto` ridden (2026-09-17)

**Vanilla V1.0: New Bark Town (24.4), houses 24.9 and 24.6, Route 30 (26.1).** The autoplay tools' answers, with
`probes/autoplay_map_probe.lua` for the map-object records (`logs/autoplay_map_7871_20260917_032920.log`).

- **Warp tiles' collision bytes.** New Bark's four doors read 0x71 (the formula `local_map` uses); the mats inside 24.9 at
  (2,7) and (3,7), and inside 24.6 at (6,7) and (7,7), read 0x70; 24.6's third warp, at (9,0) to 24.7, read 0x7A (not
  entered).
- **A mat.** In 24.9, `walk` right from one mat onto the other and `walk` down onto a mat from (3,6) each answered `done`
  on the mat (26 and 27 frames): stepping onto it does not warp. From rest on it, `walk` down answered `map_changed` to
  24.4 with `moved` 0 (63 frames), and a held `walk` down 2 from (2,6) stepped onto the mat and went on into the town
  (`moved` 1, 88 frames).
- **A trainer before it loads.** From Route 30's (1,13) only the player and one character had object records; Don's
  map-object record 4 read `FF 25 0B 05 06 00 FF FF B2 03 BE 57 FF FF 00 00` -- FF where, once he loaded one step later, it
  read 02, his object slot -- then his graphic, his tile plus 4 (y 7, x 1), 06 at +0x04, the trainer nibble 2 and range
  3. The route's other two trainers' records read (2,28) range 3 with 09 at +0x04, and Youngster Mikey's (5,23) range 1
  with 06. Don's 06 is the `movement_type_raw` `nearby` read from his object record once he loaded. Movement types seen
  with a facing that never changed while watched: 6 for Don and Mikey, facing down; 7 for 24.9's character at (5,4),
  facing up; 8 for Route 31's trainer at (21,13), facing left. No 9 was seen on screen.
- **`goto` ridden, from snapshots.** From (11,14) below 24.9's door to 24.6's door at (13,5): 13 tiles, 3 turns, `map_changed`
  standing on 24.6's mat at (6,7), 258 frames. From (6,5) in 24.6 to its mat (7,7): onto the mat, down held, `map_changed`
  with `entered` (7,7), standing in town on (13,6), 122 frames. From `route30_warped` (1,13), with Don not loaded: to (2,6)
  in 172 frames, 10 tiles, 2 turns, up the grass column beside his line and never into it; to (5,4), 15 tiles, 252 frames;
  from (1,11) to (1,9), in his line, over three grass tiles rather than one line tile, `spotted` at (1,9) with map object 4
  two tiles away and Don named in `route_in_sight` (74 frames). From (2,6) toward (1,10) the first step, into grass,
  answered `script_started` (a wild encounter). Refused at once: (20,20), outside the map's 20 by 18; the mailbox (9,13);
  and Route 30's (2,11), "collision 0x12 planned as closed: not measured".
- **Not seen:** a replan after a bump; movement type 9 or any trainer that turns; a mat or stairs of any other byte (0x7A);
  a map edge crossed by `goto`; what a trainer's sight does past a wall.

### The party's moves, PP, item and status, the POKéMON menu, a heal, and a defeat flag cleared in a trainer's line (2026-09-17)

**Vanilla V1.0, from `session_end_route31` (CYNDAQUIL L5 10/19, BELLSPROUT L5 20/20), and Route 30.**
`probes/autoplay_battle_probe.lua`'s party lines and `probes/autoplay_text_probe.lua` (`logs/autoplay_battle_7871_20260917_033339.log`,
`logs/autoplay_text_7871_20260917_033339.log`), read against captures `autoplay_party_menu`, `autoplay_party_submenu`,
`autoplay_summary_p1`, `_p3`, `autoplay_summary_bellsprout`, `autoplay_party_menu_healed`, `autoplay_summary_healed_moves`,
`autoplay_scn_flag_cleared_in_sight` (gitignored).

- **A party slot's bytes against the summary.** CYNDAQUIL's 0x30 bytes: `9B AD 21 2B 00 00 86 FB 00 00 9E …` with `1F 1E 00 00` at
  +0x17 and `05 00 00 00 0A 00 13` from +0x1F. The summary's pages drew ITEM BERRY (+0x01 0xAD; the item names' 173rd
  string spelled BERRY), MOVE TACKLE PP 31/35 and LEER 30/30 (+0x02/+0x03 33 and 43; +0x17/+0x18 31 and 30), EXP POINTS 158
  (+0x08-+0x0A, high byte first), STATUS/ OK (+0x20 0), and 10/ 19 (+0x22-+0x25). BELLSPROUT's summary, reached with Down
  from CYNDAQUIL's, drew no ITEM (+0x01 0) and VINE WHIP 10/10 (+0x02 22, +0x17 10). The stats at +0x26-+0x2F were not
  drawn on the pages opened, and are not read.
- **The POKéMON menu.** START, POKéMON: each name on rows 1 and 3 from column 3, its HP ("10/ 19") at columns 14-19, its
  ":L5" and HP bar on the row under it, CANCEL on row 5, and "Choose a POKéMON." in a box at rows 14-17 (not the message
  box's rows, so no `dialogue`). The menu block read first row 1, column 0, 3 rows by 1 column, 2 rows apart, the frame's
  right column 19 -- so the grid reader cut the last digit of the HP -- and wMenuCursorY followed the ▶. A on CYNDAQUIL
  opened STATS / SWITCH / MOVE / ITEM / CANCEL, read as a menu as drawn. On the summary, one 4-frame Right left the first page
  as it was 40 frames later and a second brought up the moves page; two 8-frame Rights also reached the moves page. B
  went back to the list with the ▶ on the Pokémon last shown.
- **`heal`.** Written from `session_end_route31`: HP from +0x24/+0x25 into +0x22/+0x23, PP from the move table's +0x05
  into +0x17-+0x1A, and 0 into +0x20. The POKéMON menu then drew CYNDAQUIL 19/ 19 (10/ 19 before), and the summary TACKLE PP
  35/35 (31/35 before).
- **A defeat flag cleared in a trainer's line.** A scenario run ended with Don beaten at (1,9), where he had walked, and the
  player at (1,10) facing him. The next run's setup cleared his flag (`set_flag`) and healed; two cheats later the warp was
  refused with wScriptRunning 1, and the screen showed "Instead of a bug / POKéMON, I found" with Don still at (1,9). No
  step had been taken: the game's sight check found the player standing one tile into his line.
- **The scenario, replayed** (`autoplay/games/crystal/scenarios/trainer_sight_range.json`, its setup reordered to warp, heal,
  then clear the flag; run logs `autoplay/runs/2026-09-17_034156.929329.ndjson` and the two broken runs after it, gitignored):
  3 of 3 passed (1m24s, 1m26s, 1m09s), each run starting where the last ended, Don beaten at (1,9) beside the player -- the
  warp's map load put him back on (1,7) every time, and his cleared flag had him come at three tiles again. Broken on purpose
  from copies: `tiles_away` 4 failed at the walk with "trainer.tiles_away: want 4, got 3"; his flag SET in the setup, with
  the check on `beaten` dropped, failed at the walk with "outcome: want "spotted", got "done"". Both exited 1.
- **Not seen:** a status other than OK; raised PP; a party slot past the second; the menu's SWITCH, MOVE or ITEM.

### Badges on the trainer card (2026-09-17)

**Vanilla V1.0, Route 30, the chat's save (no badges).** START, the player's name ("A"), A: the trainer card's second page
numbered eight gym leaders' faces 1-4 on the top row and 5-8 below, with no badge drawn, while wJohtoBadges (01:D857 in
our build's `.sym`) read 0. Captures `autoplay_trainer_card_p2`, `autoplay_trainer_card_badge1`, `autoplay_trainer_card_badges148_a`
and `_b`, and the enlarged comparisons `autoplay_badge1_compare`, `autoplay_badges148_b_zoom` (gitignored); each capture
compared to the no-badge one pixel by pixel.

- **Bit 0.** Written to 1 (`set_badge` 1) in the overworld, then the card reopened: the only pixels that changed were at x
  22-26, y 89-103, a badge drawn beside leader 1 -- thin, as if turned edge-on.
- **Bits 0, 3 and 7** (the byte read 137): badges beside leaders 1, 4 and 8, drawn face-on 16 pixels wide in a capture 10
  frames after one that showed them 2-4 pixels wide, so they turn. Nothing changed by the other five leaders.
- So bit N-1 is badge N as the card numbers it. `observe` read `badges` [1, 4, 8]; all three were cleared again with
  `set_badge` `value: false` (the byte read 0).
- **Not seen:** a badge the game gave (a gym won); wKantoBadges (D858); anything a badge unlocks (an HM used outside a
  battle, obedience).

### The key item pocket, and riding the BICYCLE (2026-09-17)

**Vanilla V1.0, Route 30 and New Bark Town.** `probes/autoplay_bag_probe.lua`, `probes/autoplay_text_probe.lua` and
`probes/autoplay_state_probe.lua` (`logs/autoplay_bag_7871_20260917_035248.log`, `logs/autoplay_text_7871_20260917_035248.log`,
`logs/autoplay_state_7871_20260917_035340.log`); captures `autoplay_pack_key_items`, `autoplay_pack_bicycle_menu`,
`autoplay_on_bicycle` (gitignored).

- **Which items are key items.** The game's attribute table (01:67C1, 7 bytes an item) read +0x05 02 for 22 ids, among them
  BICYCLE (7), COIN CASE (54), ITEMFINDER (55) and OLD ROD (58); 04 for 57 ids from TM01 (191); 01 for 164 and 03 for 12. Read
  from our build's `.gbc`, whose SHA-1 is the ROM's.
- **The pocket's layout, by what the PACK drew.** wNumKeyItems (01:D8BC) written as `02 07 3A FF` (`give_item` BICYCLE, then OLD
  ROD): the PACK's third pocket (wCurPocket 2, two Rights from the item pocket) drew BICYCLE, OLD ROD and CANCEL, and under the
  first "A collapsible bike / for fast movement."; wScrollingMenuListSize read 2 and the menu header 01 then D8BC where the item
  pocket's reads 02 then D892. A two-byte entry would have drawn one item. So a count, one id an entry, FF; the `.sym` leaves
  room for 25.
- **On the bike.** BICYCLE chosen opened USE / SEL / QUIT; USE printed "A got on the BICYCLE." and on that frame wPlayerState
  (01:D95D) went 0 to 1 and the player object's graphic 01 to 02. Chosen again from the PACK: "A got off the BICYCLE." and
  `movement` `on_foot`. A warp to New Bark kept the bike; riding into house 24.9's door left the player on foot inside
  (graphic 01), and on foot coming out.
- **A ride.** 40 frames of Right on the bike from (4,9): wPlayerMovement 7 (4 + the code) for 6 frames, then 19 (16 + the
  code) stepping; each step began as the object's +0x10 moved and wXCoord caught up 6 frames later, the next beginning 2
  frames after; let go during the fourth step, that step finished, no fifth began, and wPlayerMovement read 62 two frames
  after its end, on (8,9). On foot the same step took 14 frames.
- **Through the tools on the bike:** `walk` right 5 `done` in 43 frames; `walk` right 10 `blocked` after 4 by the water at
  (18,9), collision 0x29; `goto` (11,14) from (17,9), 11 tiles and 2 turns in 100 frames; `goto` the door (11,13)
  `map_changed` into 24.9.
- **Not seen:** SEL (registering the bike to SELECT); riding over a ledge or into tall grass; a building the game refuses a
  bike in; the key items' other entries' effects.

### The TM/HM pocket, and a list that redraws for 11 frames (2026-09-17)

**Vanilla V1.0, New Bark Town.** `probes/autoplay_bag_probe.lua` and `probes/autoplay_text_probe.lua`
(`logs/autoplay_bag_7871_20260917_035825.log`, `logs/autoplay_text_7871_20260917_035825.log`, and
`logs/autoplay_text_7871_20260917_040112.log` for the scroll-up selects); captures `autoplay_pack_tms`, `autoplay_pack_tms_scrolled`,
`autoplay_pack_tms_hm07` (gitignored).

- **Which items.** The attribute table files 57 ids under 04, in id order TM01 (191) to TM50 (242) and HM01 (243) to HM07
  (249); two ids between them (195, 220) file elsewhere. wTMsHMs (01:D859) is 57 bytes in our build's `.sym`.
- **The layout, by what the PACK drew.** 1 written at D859 + 0, + 4 and + 56 (`give_item` TM01, TM05, HM07): the fourth
  pocket (wCurPocket 3) drew "01 DYNAMICPUNCH ×1", "05 ROAR ×1", "H7 WATERFALL" with no count, and CANCEL, and under the first
  "An attack that / always confuses.". With TM02-TM04 and TM06-TM08 added, the rows in order drew DYNAMICPUNCH, HEADBUTT,
  CURSE, ROLLOUT, ROAR, TOXIC, ZAP CANNON, ROCK SMASH, WATERFALL: a count per TM or HM at its place among the 57.
- **The move names.** TMHMMoves (04:567A in our `.sym`) read one move id an entry; entries 1-8 and 57 spelled the nine drawn
  (223 DYNAMICPUNCH, 29 HEADBUTT, 174 CURSE, 205 ROLLOUT, 46 ROAR, 92 TOXIC, 192 ZAP CANNON, 249 ROCK SMASH, 127 WATERFALL).
- **The list that scrolls.** Down pressed 11 times from the top with nine held: wTMHMPocketCursor (01:D0DC) read 0-4 down the
  five rows shown and stayed 4 while wTMHMPocketScrollPosition (01:D0E2) read 1-5 as the list moved, CANCEL on the last row
  at 5 + 4; wMenuCursorY followed D0DC + 1. So the entry under the ▶ is D0E2 + D0DC.
- **A redraw with no ▶ for 11 frames.** `select` that scrolled up from CANCEL failed "the menu closed or changed while the
  cursor was moving" 2 times in 13. A temporary log line in the list reader, written on each frame within 30 of a verified
  read where it gave up, showed no menu one frame past its 10-frame grace each time the list moved (seen at f227503, given up
  at f227514), and the list whole again after. With the grace at 20: 64 selects of 64 in four batches, two right after a
  driver reload. One earlier batch counted 15 successes of 16 in output that was not kept; which call, if any, failed is
  not known.
- **Not seen:** a TM taught (USE on a Pokémon), a TM's count past 1, HM01-HM06 drawn, the pocket in a battle.

### Surfing, and a poisoned party on foot (2026-09-17)

**Vanilla V1.0, New Bark Town's pond (x 18-19, y 6-9).** The autoplay tools' answers, `probes/autoplay_text_probe.lua`,
`probes/autoplay_state_probe.lua` (`logs/autoplay_state_7871_20260917_040949.log`) and `probes/autoplay_battle_probe.lua`'s
party lines (`logs/autoplay_battle_7871_20260917_041644.log`, `logs/autoplay_state_7871_20260917_041644.log`); captures
`autoplay_water_no_badge`, `autoplay_bellsprout_field_menu`, `autoplay_surf_no_badge`, `autoplay_surfing`, `autoplay_surf_landed`,
`autoplay_party_poisoned`, `autoplay_party_healed_from_psn`, `autoplay_poison_hp0` (gitignored).

- **SURF on a party Pokémon.** `set_move` wrote SURF (57) into BELLSPROUT's second slot with PP 15; its party menu then listed
  SURF above STATS / SWITCH / MOVE / ITEM / CANCEL.
- **Which badge.** With no badge, A facing the water at (18,9) printed nothing, and SURF from the menu printed "Sorry! A new
  BADGE / is required.". Badges 1, 2 and 3 each alone (`set_badge`) got the same answer; badge 4 alone got "BELLSPROUT used
  SURF!". Badges 5-8 were not tried. With badge 4, A facing the water printed "The water is calm. / Want to SURF?" with YES /
  NO, and YES surfed.
- **On the water.** wPlayerState (01:D95D) went 0 to 4 and the player object's graphic to 0x53, the player moved onto the
  water tile by itself, and `observe` read `movement` `surfing`. Up held: wPlayerMovement 5 (4 + the code) turning for 6
  frames, 13 (12 + the code) stepping, the target tile moving as a step began and wYCoord catching up 14 frames later, the
  next step 2 frames after, rest (62) 2 frames after the last -- a step on foot's numbers.
- **Ashore.** Left held from the water at (18,7): wPlayerState went to 0 as the press began, then a step on foot (14, 14
  frames) onto (17,7), graphic 01.
- **Through the tools, surfing:** `walk` down 2 `done` in 43 frames; `goto` (19,6) stopped `script_started` after 3 tiles, a
  wild TENTACOOL (POISON STING, SUPERSONIC, CONSTRICT, ACID); `battle run` answered "Can't escape!" four times, CYNDAQUIL was
  confused and then poisoned, and the fifth RUN got away; `goto` (17,8), ashore, `done` in 65 frames, 3 tiles, `movement`
  `on_foot`.
- **The poison.** CYNDAQUIL's status byte (+0x20) read 8, and the POKéMON menu drew "PSN" where its level mark stands; `heal`
  wrote 0 and the menu drew the level again. Walking poisoned (`set_status` PSN), its HP fell by 1 about every fourth step,
  and at each fall wWalkingDirection read 0 for about 5 frames with wPlayerMovement still 14 and wScriptRunning 0, so the
  next step began about 7 frames late; `walk` and `goto` rode through with `done`. Riding on, the HP read 3, 2, 1, then 0:
  the status byte read 0 with it, and "CYNDAQUIL / fainted!" printed in the overworld with wScriptRunning 255, which `goto`
  answered as `script_started`; `advance_text` closed it with the player where they stood.
- **Not seen:** badges 5-8 against SURF; a water tile of another byte; surfing across a map edge or into a trainer's line;
  the poison's flash on screen (no capture fell inside a tick); whether a party with every Pokémon fainted this way whites
  out.

## Not measured yet

### The rest of autoplay's Crystal reading (from 2026-09-17)

- The rest of a trainer (measured 2026-09-17 for Bug Catcher Don and Youngster Mikey, above): a trainer that turns or
  walks, a range-1 line walked into, a lost trainer battle.
- The rest of a battle (measured 2026-09-17 for one wild battle, above): a level-up and its stats box, the player's
  Pokémon fainting and the whiteout, a status, a second Pokémon in the party (is the next slot 0x30 on?), a move of
  another type drawn against the type table.
- The other lists (measured 2026-09-17 for the PACK's item and ball pockets, above): the key item and TM/HM pockets
  with something in them, the Pokémon menu, the PC, a mart; is the list always named by the header copy at CF91?
- `walk` on a bike and surfing (wPlayerState other than 0) and off a ledge; collision 0x9D.
- A text speed other than this save's; whether a box that waits with no ▼ reads anything besides
  wTextboxFlags ("A received POTION." ignored A through its jingle, then went on).
