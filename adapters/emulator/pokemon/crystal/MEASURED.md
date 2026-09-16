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

## Not measured yet

### The rest of autoplay's Crystal reading (from 2026-09-17)

- A battle: what wMapStatus, wSpriteUpdatesEnabled and wBattleMode read from the encounter to the map's
  return, so `mode` can say `battle`. This save has no Pokémon; to settle, the starter from the lab,
  then grass on Route 29 with `autoplay_state_probe.lua` loaded.
- Whether 0x60-0x7F draw the same outside the overworld's message box (a battle loads other tiles):
  run the charset probe in a battle's text box.
- A grid menu (a battle's), a scrolling list (the PACK with items in it) and the PC: what CFA1-CFAC and
  the tile buffer hold.
- `walk` on a bike and surfing (wPlayerState other than 0), off a ledge, into a character, and across a
  map edge; what the neighbour bytes read for each.
- A text speed other than this save's, and whether a box that waits with no ▼ (the last box) reads
  anything besides wTextboxFlags.
