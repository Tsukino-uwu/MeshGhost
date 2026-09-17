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
- The party, the bag, money, badges and flags (2026-09-16)
- A new screen's windows (2026-09-16)
- What the driver and its hooks cost (2026-09-16)
- A wild battle: who is in it, what it asks, its cursors and its text (2026-09-16)
- A move's type, power, accuracy, PP and effect text (2026-09-16)
- Crossing a map edge, a trainer's sight, and a trainer battle (2026-09-16)
- A direction held across tiles, walking and running (2026-09-16)
- The two bikes: getting on, speed, and stopping on a tile (2026-09-16)
- Turning at speed, routes, a Pokémon Center, and battles as one call (2026-09-16)
- A trainer's sight and defeat flag, a trainer coming for the player, and the level-up box (2026-09-17)
- The bag's item list, its item menu, and a Repel used through them (2026-09-17)
- A new game to the first trainer battle: warps, elevation 0, cutscenes and the script status (2026-09-17)
- A move's animation holds a battle's next message (2026-09-17)
- A finished message's printer and window, and a stale one (2026-09-17)
- The naming keyboard, and a blank box put back after it (2026-09-17)
- The truck's door taken from rest, the wall clock's screen, and a question drawn instantly (2026-09-17)
- The wall clock set: PM, midnight, YES, and the clock viewed after (2026-09-17)
- The starter bag, and a stale message on its screen after a restore (2026-09-17)
- Autoplay's noclip: through a collision tile and a character (2026-09-17)
- A battle controller at work: the rescue battle's intro (2026-09-17)
- What a move's type does to its damage (2026-09-17)
- Not measured yet: The rest of the text printer (from 2026-09-16)
- Not measured yet: The rest of the map and the walk (from 2026-09-16)
- Not measured yet: The rest of the party, the bag and the flags (from 2026-09-16)
- Not measured yet: The rest of a battle (from 2026-09-16)

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
  **Superseded** by "What the driver and its hooks cost" (2026-09-16): the no-hook figure was the
  driver's reconnect loop.

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

### The party, the bag, money, badges and flags (2026-09-16)

**Vanilla ROM, the save the text and map entries used** (one level-6 MUDKIP, `testkit.lua`'s bag,
eight badges). From `probes/party_bag_probe.lua` (read-only: the party, pockets, money and flag bytes,
dumped on change), `probes/substruct_order_probe.lua` (writes the party in live RAM, restored on
unload), and autoplay's `set_flag` and `give_item` cheats; each read against captures of what the game
drew (`dev-scripts/shots/emerald/autoplay_pb_*`, `autoplay_so_*`, `autoplay_badge_*`, `autoplay_gi_*`,
gitignored). Used by `autoplay/drivers/bizhawk/games/emerald.lua` for `party`, `bag`, `money`,
`badges` and both cheats.

- **A party slot is 0x64 bytes** at the address the build names gPlayerParty; the byte named
  gPlayerPartyCount read 1. +0x08 is the 10-byte name in the game's encoding (MUDKIP); +0x54 the level
  (6); +0x56 and +0x58 HP and max HP (17, 22); +0x5A to +0x62 attack, defense, speed, sp. atk and sp.
  def as u16s (14, 11, 10, 12, 12, the SKILLS page); +0x04's low half the ID No. (0x5C51 = 23633, on
  the INFO page and the trainer card); +0x50 read 0 with no status drawn. SaveBlock1's copy at +0x238
  equalled the live slot; they were not seen to differ, since no battle or save came between.
- **The 48 bytes at +0x20** are four 12-byte blocks: XOR each u32 with +0x00 ^ +0x04 and the 24 u16
  halves sum to +0x1C (0x0E8E both). On this MUDKIP (personality mod 24 = 6), block 1 held species 283,
  whose 11-byte species-table entry reads MUDKIP, held item 0 (NONE) and EXP 221 as a u32 at +4; block 0
  held u16 moves 33, 45, 189 and 0, which the 13-byte move-name table reads as TACKLE, GROWL, MUD-SLAP,
  with PP 32, 40, 10 as bytes at +8 (the BATTLE MOVES page); block 3 +2's low 7 bits read 5 ("met at
  Lv5").
- **Which block is which, for every personality.** The routine the build names GetSubstruct was entered
  with the slot in R0, the personality in R1 and a kind 0-3 in R2, and returned a pointer to a block
  (hooked at its entry and its return address). With the party rewritten as six copies re-keyed to
  residues 0-23 over four rounds, and the summary paged through all six each round, it answered all
  96 residue/kind pairs with no conflict: **residue r places the kinds in the r-th lexicographic
  ordering of 0,1,2,3** (0: 0,1,2,3; 1: 0,1,3,2; 6: 1,0,2,3; 23: 3,2,1,0). At residue 6 that is the
  MUDKIP's own layout, which names the kinds: 0 species, item and EXP; 1 moves and PP; 3 the met
  level. Kind 2 is block 2 on that layout, and nothing drawn was read from it. The routine ran when a
  screen loaded a Pokémon (the party menu opening, each Down on the summary), not while one was shown.
- **The bag**, SaveBlock1 pockets of 4-byte slots, the id then the quantity XOR the low half of
  SaveBlock2 +0xAC: +0x560 ITEMS (RARE CANDY x99), +0x650 POKé BALLS (MASTER BALL x5, POKé BALL x5),
  +0x690 TMs & HMs (items 339-346, whose table names read HM01-HM08 and which the pocket draws as HM1
  CUT to HM8 DIVE), +0x5D8 KEY ITEMS (MACH BIKE, ACRO BIKE, SUPER ROD), +0x790 BERRIES (empty) -- each as
  the bag drew it. +0x498 held id 13 (POTION in the table) with its quantity word reading 0x0001 raw
  (22939 if XORed like the pockets); the PC's storage was not opened.
- **The item table**, 44 bytes an entry: the name in the first 14 bytes, +0x0E the id again, +0x1A the
  pocket in the bag's order -- 1 for the ITEMS entries, 2 the balls, 3 the HMs, 5 the key items, and
  4 for ORAN BERRY, which `give_item` put under BERRIES. +0x10 read 4800 for RARE CANDY and 200 for
  POKé BALL; no shop was opened.
- **Money** is SaveBlock1 +0x490 XOR the whole SaveBlock2 +0xAC word: 3300, the trainer card's ₽3300.
  +0x494 XOR the low half read 0; nothing drawn showed it.
- **Flags** are SaveBlock1 +0x1270, one bit per id: bit id & 7 of byte id >> 3. Ids 0x867-0x86E were
  set, eight badges were drawn and the main menu read BADGES 8. Three trainer cards, each after
  clearing the ids whose index (id - 0x867) had bit 0, bit 1 or bit 2 set, left exactly those positions
  empty, so **0x867 + i is badge i + 1 from the left**; setting 0x86E back redrew the eighth. Also set,
  and not identified: 0x860, 0x861, 0x86F, 0x870.
- **Before CONTINUE the save pointers and the key read otherwise**: SaveBlock1 0x02025A2C, SaveBlock2
  0x02024A80, key 0x34CCD638 at the title; 0x02025A10, 0x02024A64 and 0x7FCF599A in the overworld, the
  values every decode above used.
- **The cheats against the screen**, same session: `give_item` added ORAN BERRY x3 (a new BERRIES
  stack), POTION x2 (a new ITEMS stack) and POKé BALL 5 to 8, each drawn so; it refused RARE CANDY past
  99, a name the table lacks, and any item while the trainer card was open.
- **Not seen by any of it**: an egg, a status condition, a second real Pokémon, a battle's effect on
  the slot, what kind 2 holds, the PC's storage, a stack past 99, any flag but the badges, a patched ROM.

### A new screen's windows (2026-09-16)

**Vanilla ROM, the same save.** From `probes/window_life_probe.lua` (read-only: every call to the
routines the build names InitWindows, AddWindow, RemoveWindow, FreeAllWindowBuffers,
ClearWindowTilemap and Menu_MoveCursor, with byte +0 of window ids 0-11 beside each) while the agent
opened the START menu, chose POKéMON, opened and closed the Pokémon's submenu and went back out. Used
by `autoplay/drivers/bizhawk/games/emerald.lua`, which forgets its windows' text and menu there.

- **The START menu**: AddWindow, then Menu_MoveCursor, with window 1's background byte turning 00.
- **Choosing POKéMON**: FreeAllWindowBuffers, then gMain.callback2 changed twice, then InitWindows;
  after InitWindows ids 0-6 read 00 00 00 00 00 00 02 before any AddWindow, and the START menu's window
  1 never passed through RemoveWindow or ClearWindowTilemap. The party menu then drew its own text
  with window 1 in use, which the driver had been reading as the START menu with seven empty items.
- **The submenu** (SUMMARY, ITEM, CANCEL) was window 8, opened with AddWindow and Menu_MoveCursor and
  closed with ClearWindowTilemap and RemoveWindow on 8 and on 9, its message window.
- **Back out**: FreeAllWindowBuffers, InitWindows, AddWindow, Menu_MoveCursor, and the START menu was
  drawn again on window 1.
- **With InitWindows hooked**, the same path read no menu in the party menu, the submenu's three items
  on window 8 (`select` CANCEL closed it) and the START menu again on the way out.
- **Not seen**: any other screen change (the bag, a battle, a map load), and whether InitWindows ever
  runs while a screen keeps its windows.

### What the driver and its hooks cost (2026-09-16)

**Replaces** the text entry's "What an execute hook costs". One emulator, vanilla, standing still in
town (map 0.10) with no input, from `probes/hookcost_probe.lua`: the frame limiter off, a
`client.get_approx_framerate()` reading every 120 frames, the median of the last 20 of 30 (the reading
climbs for the first several), then the limiter back on. In frames per second:

| Loaded | No core listening | A core connected |
| --- | --- | --- |
| nothing | 835 | -- |
| the driver, no hooks | 350 | 818 |
| the driver, its six hooks | 244 | 415.5 |
| the driver, one no-op hook | -- | 410.5 |
| the driver retrying by wall clock, no hooks | 802.5 | -- |
| the driver retrying by wall clock, six hooks | 402.5 | -- |

- **The driver's reconnect loop was the larger cost**: with no core listening, a connect attempt with
  a 50 ms timeout every 30 frames took 835 to 350. Retrying once a second instead read 802.5.
- **Any execute hook halves top speed**, and how many does not matter: 818 with none, 410.5 with one
  that does nothing, 415.5 with the driver's six.
- **The old figures** (344 with no hook, 245.6 with one, 242.0 with five) match the no-core column: that
  run had the driver loaded and no core connected.
- A `get_approx_framerate()` of about 60 in the first sample, and dips near 360 once a second in the
  retry runs, are the reading's lag and the retry itself.
- `emu.limitframerate` and `client.get_approx_framerate` are userdata in this BizHawk, not Lua
  functions: a check for `type(...) == "function"` reports them absent.
- **Not measured**: another place in the game, a second emulator running beside it, a battle.

### A wild battle: who is in it, what it asks, its cursors and its text (2026-09-16)

**Vanilla ROM, the same save, map 0.16's grass** (warped to with autoplay's `warp`, then walked until
an encounter). From `probes/battle_state_probe.lua` (read-only: the battle's globals, its four
battler records and its message buffer, logged on every change with the pad) through one wild battle
against a level-3 POOCHYENA, read against captures of every message, both menus and each cursor
position (`dev-scripts/shots/emerald/autoplay_bt_*`, gitignored). Then three more battles driven by
autoplay's tools alone. Used by `autoplay/drivers/bizhawk/games/emerald.lua` for `battle`, the battle
`menu` and `mode`.

- **gMain.callback2** read 0x08036FAD during the intro, then the routine the build names BattleMainCB2,
  +1 (0x08038421), from before "Wild POOCHYENA appeared!" until after the last message; then 0x080860C9,
  0x080860F5 and the overworld's.
- **Battlers.** The byte named gBattlersCount read 2 and the four named gBattlerPositions 00 01 FF FF;
  battler 0 was the MUDKIP and 1 the POOCHYENA. Each battler's 0x58 bytes: species at +0x00 (283, 286,
  named MUDKIP and POOCHYENA by the species table); +0x02 to +0x0A attack, defense, speed, sp. atk and
  sp. def (14, 11, 10, 12, 12, the summary's); moves at +0x0C (33, 45, 189, 0; and 33); PP at +0x24;
  HP at +0x28, level at +0x2A, max HP at +0x2C; the name at +0x30. The MUDKIP's HP read 17, 15 and 13
  as the box drew 17/22, 15/22 and 13/22; its TACKLE PP 32, 31, 30 as the move menu drew 32/35, 31/35
  and 30/35; after "MUDKIP grew to LV. 7!" it read level 7 and max HP 24, drawn 15/24. The POOCHYENA's
  level read 3 (drawn Lv3) and its HP 15, 8, 1, 0 (its bar has no numbers) before "Wild POOCHYENA
  fainted!".
- **What it asks.** The first word of the block named gBattlerControllerFuncs (battler 0's) read the
  routine named HandleInputChooseAction, +1 (0x08057589), for as long as FIGHT, BAG, POKéMON and RUN
  waited, and the one named HandleInputChooseMove, +1 (0x08057BFD), while the move menu did.
- **Cursors.** The first byte named gActionSelectionCursor went 0 → 1 (Right, ▶ on BAG) → 3 (Down,
  RUN) → 2 (Left, POKéMON) → 0 (Up, FIGHT). The first named gMoveSelectionCursor went 0 → 1 (Right,
  GROWL), stayed 1 on Down toward the empty fourth slot, 0 on Left, and 2 on Down from TACKLE
  (MUD-SLAP, the type line GROUND and PP 10/10).
- **Text.** The buffer named gDisplayedStringBattle held each message in turn, and the driver's
  existing message reading showed the same text on window 0. In the menus' own strings, FC 13 38 sat
  between FIGHT and BAG, and with the cursor moved to BAG the capture's first column of FIGHT is x=136
  and of BAG x=192, 0x38 apart, with no glyph between; FC 06 01 sat in "TYPE/NORMAL" and FC 02 02 and
  FC 01 0B around "MUDKIP♂", none drawn. "MUDKIP grew to LV. 7!" ended FC 0A FB; "Got away safely!"
  began with an FC the decoder did not know (not logged raw).
- **Window text in a battle.** The action and move menus' windows kept reading as on screen through
  "MUDKIP used TACKLE!", when neither was drawn; so window text is not read in a battle.
- **After it.** The byte named gBattleTypeFlags read 4 throughout and the one named gBattleOutcome 0,
  then 1 once the POOCHYENA fainted; both kept those values back in the overworld. The party slot then
  read level 7, max HP 24, attack 15 and TACKLE at 29 PP.
- **Driven by the tools** (same session): `select` FIGHT, then GROWL (one Right), TACKLE (one Left),
  MUD-SLAP (one Down) and RUN (Right, then Down, then "Got away safely!"), across three more battles
  against POOCHYENA twice and a WURMPLE, whose moves read TACKLE and STRING SHOT. Each ended back in the
  overworld; after the MUD-SLAP battle the party's EXP read 290 (221 before the first battle).
- **Not seen**: a trainer battle, a double battle, the BAG or POKéMON menus in a battle, a switch, a
  catch, a faint of the player's Pokémon, a whiteout, any outcome but 1, a patched ROM.

### A move's type, power, accuracy, PP and effect text (2026-09-16)

**Vanilla ROM, the same save.** From `probes/move_data_probe.lua` (read-only: the 12-byte entries of
the table the build names gBattleMoves for the MUDKIP's three moves, the 7-byte type name each points
at, and the string behind each move's entry in gMoveDescriptionPointers), read against captures of the
summary's BATTLE MOVES page with each move selected (`autoplay_mv_det_1`..`3`). Used by
`autoplay/drivers/bizhawk/games/emerald.lua` for each move in `party` and `battle`.

- **+1 the power**: 35 TACKLE, 0 GROWL (drawn "---"), 20 MUD-SLAP.
- **+2 the type**, the index of a 7-byte entry in the type names: 0 read NORMAL for TACKLE and GROWL,
  4 read GROUND for MUD-SLAP, as each row's type label.
- **+3 the accuracy**: 95, 100, 100.
- **+4 the PP** each move's maximum was drawn as, on a Pokémon whose PP were never raised: 35, 40, 10.
- **The effect text** at move id - 1 in the pointer table: "Charges the foe with a full-body tackle.",
  "Growls cutely to reduce the foe’s ATTACK.", "Hurls mud in the foe’s face to reduce its accuracy.",
  each word for word as the DESCRIPTION box, with its line break where the box broke it.
- +0 read 0, 18 and 73, +5 0, 0 and 100, +6 0, 8 and 0, and +8 51, 22 and 18; nothing drawn showed them.
- **Not seen**: any other move, a move whose PP was raised, what the other bytes mean.

### Crossing a map edge, a trainer's sight, and a trainer battle (2026-09-16)

**Vanilla ROM, the same save.** Walked with autoplay's `walk` from route 0.16 through the town 0.10 to
route 0.17, with `probes/battle_state_probe.lua` loaded for the battle, read against captures
(`dev-scripts/shots/emerald/autoplay_tr_*`, gitignored). The trainer was found with
`probes/find_objects.py`, which lists a map's character templates from the ROM.

- **Map edges.** Walking up from 0.16 (9,4), the step after (9,0) arrived on 0.10 at (9,19) with
  `map_changed`; running left from 0.10 (7,10), the step after (0,10) arrived on 0.17 at (49,10). The
  same row or column carried over both times.
- **A trainer's template.** On 0.17, four of the nine character templates have a nonzero u16 at +0x0C
  (1 each) and +0x0E reading 2 or 3. The one at (33,14), +0x0E 3, was drawn facing down. Standing three
  tiles to its right (36,14) did nothing; stepping into (33,17), three tiles below it, from the side
  opened its challenge with the trainer walked to (33,16) and `walk` answering `dialogue_open`. A
  template's other trainers were not tried.
- **The printer's +0x1C read 3** on that challenge while both lines were drawn with the red arrow, before
  an FA scrolled the text (`autoplay_tr_state3`).
- **The battle.** "YOUNGSTER CALVIN would like to battle!", "YOUNGSTER CALVIN sent out POOCHYENA!", and
  the opponent's messages began "Foe POOCHYENA". The byte named gBattleTypeFlags read 0x0C through it,
  against 0x04 in the four wild battles; callback2 went 0x08036761 (the routine named CB2_InitBattle, +1)
  and 0x08036FAD before BattleMainCB2's. The opponent's moves read TACKLE and HOWL. After "Player
  defeated YOUNGSTER CALVIN!" and "A got ₽80 for winning!", `money` read 3380 against 3300 before; the
  trainer then spoke again in the overworld.
- **The outcome byte** read 4 when this probe loaded, after the earlier battle escaped with RUN and
  before any other, 0 through the trainer battle and 1 after the win.
- **Not seen**: a trainer with more than one Pokémon, a double battle, a trainer seen from any other side,
  a lost trainer battle, what +0x0C's value 1 and +0x0E mean beyond this one trainer.

### A direction held across tiles, walking and running (2026-09-16)

**Vanilla ROM, route 0.17, row 17** (six clear tiles, then a wall at x=40). From `probes/step_probe.lua`
(read-only, logging the player object's bytes and the avatar block on every change, with the pad): Right
held for 150 frames from x=33, walking, then B+Left held for 70 frames, running.

- **Walking**, after a 7-frame turn: each tile began the frame the coordinate changed (avatar +2 reading 2,
  +3 reading 2 and then 1), and 16 frames later the object's byte 0 top bit came back and the previous
  coordinate caught up -- for one frame; the next tile's coordinate changed on the frame after. Six in a
  row, with no frame at rest between them.
- **Into the wall** straight after a tile: the coordinate stayed, the previous one already equalled it,
  +2 read 2, +0x1C went 0x0B to 0x1C, +3 went 2 then 0, and byte 0's top bit was clear for 30 frames;
  still held, it bumped again.
- **Running**: the same pattern at 8 frames a tile, avatar byte 0 reading 0x81 and +0x1C 0x37.
- **Released mid-step**, the step finished and the avatar's +2 and +3 read 0 two frames after it did.
- **`walk` built on that** (same session): right 6 done in 107 frames; right 5 answered `blocked` after 2
  with (40,17) reported as collision 1; running left 8 done in 75 frames. The step log shows no frame at
  rest while the direction was held in any of the three.
- **Not seen**: a door, a ledge, a character in the way, or a map edge in the middle of a held chain.

### The two bikes: getting on, speed, and stopping on a tile (2026-09-16)

**Vanilla ROM, route 0.17, row 17** (clear from x=26 to 39, a wall at 40). Each bike registered to SELECT
with autoplay's `register_item` (the write `cmd_drive.lua`'s `register` measured) and mounted with a
press of Select; rides logged by `probes/step_probe.lua` and `probes/bike_probe.lua` (read-only: the
player object's coordinates, top bit and +0x1C, and the avatar block's first 16 bytes, on every change,
with the pad). Object x values below are map x + 7.

- **Getting on.** Select with the Mach Bike registered: the avatar's first byte read 2 (1 on foot). With
  the Acro Bike registered while on the Mach Bike, one Select read 1 and the next 4.
- **The Mach Bike speeds up.** Held from rest (after the same 7-frame turn as on foot): the first tile
  took 16 frames (+0x1C 0x0B riding right, 0x0A left), the second 8 (0x18, 0x17), then 4 each (0x30,
  0x2F). The avatar's +0x0B read 0, 1, then 3 on each of the next six held tiles; +0x0A read 1, 2, 2.
- **Released, it coasts.** With +0x0B at 3 on the last held tile (twice, `bike_probe.lua`), three more
  tiles followed with no input (+0x0B 2, 1, 0 at their starts, at 4, 8 and 16 frames), then rest; the
  same three from top speed in `step_probe.lua`, which does not log +0x0B; released on an 8-frame second
  tile (`step_probe.lua`), one more at 16 frames. As many tiles as +0x0B reads, in every case logged.
- **Into a wall** it bumped (+0x1C 0x20, +2 reading 2 with the coordinate unchanged) again every 16
  frames while held.
- **The Acro Bike** did not speed up: after six frames with +0x1C 0x03 and +0x0A counting 1 to 6, a
  one-frame turn, then every tile 6 frames (+0x1C 0x2B riding left). Released, it stopped on the tile it
  was on.
- **`walk` on each** (same session, from `observe`'s x before and after): Acro right 5 and left 3 exact,
  in 40 and 28 frames; Mach right 1, right 2, right 4, left 6 and right 11 all exact, the 11 in 87 frames
  stopping on x=39 beside the wall with no 0x20 in the log (released after tile 8 at speed 3, three tiles
  of coast).
- **Not seen**: turning or riding up and down on either bike, a Mach Bike released at speed 2, the Acro
  Bike's tricks, a slope, a ledge or a warp on a bike, a patched ROM.

### Turning at speed, routes, a Pokémon Center, and battles as one call (2026-09-16)

**Vanilla ROM, the same save**, routes 0.16 and 0.17, the town 0.10 and its Pokémon Center 2.2. From
`probes/bike_probe.lua` for the ride bytes, autoplay's own answers and `observe`, and captures
(`dev-scripts/shots/emerald/autoplay_tr2_state`, `autoplay_heal_state`, gitignored).

- **A Mach Bike turn at speed.** Riding left at +0x0B 3, the direction let go for two frames (+0x0B read
  2 on the next tile) and Down held before that tile's end: on arrival the next step went down, +0x1C
  0x2D, +0x0B 3 again. The step after ran into a character standing below: +0x1C 0x1D and +0x0A and
  +0x0B both 0.
- **`goto` on the Mach Bike**, (33,15) to (40,12): right 7 at speed, let go early to stop on (40,15)
  (the last leg was 3), up 3 with a release after the second tile; every step logged, no bump action.
  To (20,14) from the east: a step refused at (26,15) (+0x1C 0x1F), a replan, and a route through tall
  grass that met a wild WURMPLE at (20,16); with grass costed, (20,16) to (20,14) went around it.
- **A trainer's sight stops a route**: a route up column 19 stopped at (19,7) with `no_response` while the
  trainer from (19,4) walked over, and the next call found "Did you just become a TRAINER?" open.
- **The Pokémon Center.** Walking up into its door on the Mach Bike arrived in 2.2 with `movement`
  `on_foot`. At (7,4), A toward the nurse (7,2) across the counter began her text; "Okay, I'll take your
  POKéMON for a few seconds." did not change for more than 30 frames of A while the machine played, and
  afterwards the party read 26/26.
- **`battle` as one call.** A trainer battle already at its end: `ended` after 421 frames, money 3380
  to 3428 with "A got ₽48 for winning!". A wild ZIGZAGOON from its first message: `ended` after 2439
  frames and 41 seconds on the wall clock, the log naming every message and choice ("MUDKIP's attack
  missed!", "A critical hit!", TACKLE three times) and MUDKIP back in the overworld at 15/26.
- **`advance_text`** stopped at the nurse's YES/NO with its items after three boxes, in 501 frames.
- **Not seen**: a route across a map edge, a trainer's facing read from memory, a Repel, a battle lost,
  a battle that asks for a switch or a new move.

### A trainer's sight and defeat flag, a trainer coming for the player, and the level-up box (2026-09-17)

**Vanilla ROM, the same save**, route 0.17, restored each time from one named snapshot taken with RICK
(25,15) and TIANA (8,7) unbeaten, on the night of 2026-09-16 into 2026-09-17. Read with autoplay's
`observe` (the live character's bytes, its template on the map and the first bytes of that template's
script) and moved with `walk` and `goto`, beside `probes/battle_state_probe.lua` (now also logging the
battle script pointer and all 0x28 bytes of the struct the build names gBattleScripting) and the new
`probes/trainer_approach_probe.lua` (read-only: the approach globals, the script context status, the
player's coordinates and the pad, on every change). Captures in `dev-scripts/shots/emerald/autoplay_sight_*`
(gitignored). Addresses from the build hashed identical to the ROM; meanings as below.

- **Template and live character agree.** All four trainers' templates read +0x0C 1 and +0x0E 3, 2, 3, 3;
  the live characters read +0x07 1 and +0x1D the same numbers, and +0x06 the template's +0x09 (8, 7, 0x12,
  8). Each template's +0x10 pointed at a script beginning 5C.
- **The defeat flag.** Flag 0x500 + the script's u16 at +2 read set for the two trainers beaten on
  2026-09-16 (0x63E, 0x64D) and clear for RICK (0x767) and TIANA (0x75B); after each of their battles was
  won, theirs read set. CALVIN (beaten, range 3, facing down) did not come for the player standing at
  (33,17), three tiles below him.
- **Range, in tiles.** RICK (+0x1D 2, facing up): at (25,12), three above him, nothing in 120 frames; the
  step to (25,13), two above, brought him. TIANA (+0x1D 3): at (12,7), four to her right, nothing in 330
  frames, most of them facing right; at (11,7), three to her right, she came.
- **Facing, +0x18's low nibble.** 1 read on CALVIN, drawn facing down, who came from below on 2026-09-16;
  2 on RICK, who came for a player above him; 4 on TIANA when she came for a player to her right. 3 did not
  appear on a trainer.
- **Turning.** Sampled 16 times 30 frames apart: TIANA (+0x06 0x12) read 4 and 1 in turns, the trainer at
  (19,4) (+0x06 8) read 1 throughout, and a character with +0x06 1 read 4, 2 and 3. **A turning trainer
  comes for a player who is standing still**: the step into (11,7) ended with TIANA reading 1 and nothing
  happened; about 30 frames later she read 4, walked to (10,7) and spoke.
- **A trainer coming.** The byte the build names gNoOfApproachingTrainers read 0 before, and 1 from the
  frame after the step into the line began, 16 frames before the player arrived, through the approach
  (RICK four times, TIANA once; a probe loaded during TIANA's earlier approach read the same). The byte
  the build names gSpecialVar_LastTalked read the trainer's local id (3, 4) and the second byte of
  gApproachingTrainers its distance (2 both). A warp during RICK's approach set both back to 0 as
  the map loaded; what they read after a battle was not seen.
- **The script context status** (the byte the build names sGlobalScriptContextStatus) read 2 before the
  step, after a warp, and from 25 frames after the overworld returned from RICK's battle; 0 on the
  approach's first frame and 0 or 1 from then through his words, the battle and his words after.
- **The level-up box.** gBattleScripting +0x1E read 10 before "MUDKIP grew to LV. 9!", then 0, 3, 4, 5, and
  6 while the box's first page waited; an A press made it 7 and then 8 while the second page waited;
  another made it 9 and then 10, and the battle script pointer moved on the next frame. Nothing else the
  probe logs changed while the box waited. The next message printed 156 frames after that last A. Logged
  once; `battle`, built on it, then went through the box in three more battles.
- **Text.** A trainer's defeat words ended FC 09 FF, with the printer's +0x1C reading 1 until an A press
  moved on (three battles); "grew to LV. 9!" ended FC 0A FB. Neither takes an argument.
- **The tools built on it** (same night): `walk` down into RICK's line answered `spotted` (local id 3, two
  tiles) after 3 frames, and `battle` called straight after played from his approach to "A got ₽64 for
  winning!" with no nudge; a `goto` to (10,9), reachable only through TIANA's line, planned through (8,9),
  named her in `route_in_sight` and answered `spotted`; a `goto` from (12,5) to (6,9) went around her line
  through the grass at x=7 (a wild WURMPLE there, run from) and she did not come in 300 frames after.
- **Not seen**: a wall or a character between a trainer and the player, facing 3 on a trainer, movement
  values other than 7, 8 and 0x12 on a trainer, a trainer value other than 1, a double battle from two
  trainers, the script context status for anything but a trainer, and whether FC 09 or FC 0A draws
  anything.

### The bag's item list, its item menu, and a Repel used through them (2026-09-17)

**Vanilla ROM, the same save**, route 0.17, the bag opened from the START menu. From the new
`probes/list_menu_probe.lua` (read-only: callback2, the 0x1C bytes the build names gBagPosition, the first
12 bytes of sMenu, gMultiuseListMenuTemplate, every active task's routine, and each list-menu task's data
and entries, on every change, with the pad), read against captures (`dev-scripts/shots/emerald/autoplay_bag_*`,
gitignored). REPEL, POTION and nine more kinds were put in the ITEMS pocket with `give_item`; everything
after that went through the game's own menus.

- **The bag screen.** callback2 read 0x081AAB9D and 0x081AAD8D on the way in (the routines the build
  names CB2_BagMenuFromStartMenu and CB2_Bag, +1), then 0x081AAD5D (CB2_BagMenuRun, +1) while the bag
  waited. It opened on the pocket last used: KEY ITEMS, drawn so.
- **gBagPosition.** Byte 5 read 4 on KEY ITEMS and 0 once Right had wrapped to ITEMS, drawn so. The u16 at
  8 + 2 × the pocket followed the list's row (0 to 1 on KEY ITEMS, 0 to 6 on ITEMS), and the u16 at 0x12 +
  2 × the pocket its scroll.
- **The list.** While the list waited, one task ran the routine named ListMenuDummyTask; another list's
  task went and a new one came when the pocket changed. Its data's first word pointed at 8-byte entries
  (a name pointer, then an id: 0, 1, 2 ... and -2 for CLOSE BAG); +0x0C read the count (4 on KEY ITEMS,
  13 on ITEMS with twelve kinds), +0x0E how many are shown at once (4, then 8), +0x10 the window (0), +0x18
  the scroll and +0x1A the row. Eleven Downs through ITEMS read rows 1, 2, 3, 4, then scroll 1 to 5 at row
  4, then rows 5 and 6; the capture drew AWAKENING at the top and the cursor on MAX REPEL, entry 11 = scroll
  + row. The names were the item names as drawn; the quantities ("× 5") are drawn separately.
- **The item menu.** A on REPEL drew USE, GIVE, TOSS, CANCEL in two columns, and sMenu read left 0, top 1,
  cursor 0, last 3, window 6, width 0x38, height 0x10, 2 columns and 2 rows. Menu_MoveCursor was not
  called; the routine named ChangeMenuGridCursorPosition runs from a grid's setup. The printed pieces fell
  one per cell by x over the width and y over the height, and the cursor moved row by row: `select`
  reached CANCEL (3) and USE (0) in two steps each.
- **A leftover.** Back on the START menu after the item menu, sMenu still read 2 columns: a list menu's
  setup does not clear them, so a grid is told apart by which cursor routine last ran.
- **USE on a Repel.** After USE the list stayed on screen with "REPEL is selected." for more than 20 frames;
  then "A used the REPEL." printed in window 6, ending FC 09, and `advance_text` closed it with one A. The
  REPEL count read 5 before and 4 after. Whether wild encounters then stopped is not measured.
- **Not seen**: the bag in a battle, the party menu an item asks for (POTION's USE), TOSS and GIVE, a
  pocket other than ITEMS and KEY ITEMS, a list that is not the bag's (a shop, the PC), and the Repel's
  step count.

### A new game to the first trainer battle: warps, elevation 0, cutscenes and the script status (2026-09-17)

**Vanilla ROM**, a new game started from the main menu after a soft reset (the cartridge save was never
written), played to MAY's battle on Route 103 with autoplay's tools; the run log is one file carried across
every core (`autoplay/runs/`, gitignored). Readings from `observe` (warps now carry their tile's collision,
elevation and behaviour; extras the script context status), `walk`, `goto`, the programs' logs, captures
(`dev-scripts/shots/emerald/autoplay_acc_*`, `autoplay_ng_*`, gitignored), and `probes/trainer_approach_probe.lua`
for the script status after MAY's battle.

- **Getting there.** A+B+Start+Select for 10 frames restarted to the intro; Start skipped it, and a Start on
  the title once it had drawn opened the main menu (callback2 0x0802F6B1): CONTINUE, NEW GAME, OPTION, drawn
  with the highlighted one filled white. Down, then A, began Birch's speech after a fade of more than 180
  frames.
- **A message already under way.** After a restore, the speech read as no message while "Welcome to the world
  of" printed: its boxes were one string, printed from one text call. The window's printer read active with
  its pointer inside a ROM string; going back to the byte after the previous FF gave "My name is BIRCH." as the
  box on screen, and `advance_text` pressed through the speech from there.
- **Choices under a held A.** An A held until a message changed went on to answer the menu that appeared as the
  text ended: "Are you a boy? Or are you a girl?" and "So it's A?" were both answered with their first entry.
  With A tapped for 2 frames and a message without an arrow waited on for 20 frames first, `advance_text`
  stopped at the clock's "Is this the correct time?" and Birch's "go see MAY?" YES/NO menus.
- **The naming screen** began with no name and the cursor on A; A added the highlighted letter, START moved the
  cursor to OK, B deleted the last letter, and A on OK confirmed. It is not read by `observe`.
- **Warps.** The truck's door (4,2) read behaviour 0x62 and stayed closed while the truck drove; once open,
  stepping onto it did nothing until Right was pressed on it. The house's door mats (8,8) and (9,8) read 0x65,
  collision 0, elevation 0: walking right across both did nothing; Down while standing on one left the house.
  Stairs read 0x60 at elevation 0 (the three whose tiles were read) and warped on the step onto them (four
  stairs taken, in both houses). Town doors read
  0x69 with collision set and elevation 0; `goto` walked up into the neighbour's from the tile below and
  arrived inside.
- **Elevation 0.** The mats and stairs at elevation 0 took a step from elevation 3 and gave one back to it; the
  planner, standing on a mat, had planned at elevation 0 and found the room (elevation 3) closed.
- **The script context status** read 0 or 1 through MAY's conversation, her battle and her words after, and 2
  1044 frames after the overworld came back from the battle, as she walked away. On Route 101 a cutscene walked
  the player from y=19 to 15 between two messages with no message on screen.
- **Screens nothing reads.** An A pressed after 3 seconds of no change picked the middle Poké Ball on Birch's
  bag screen (TORCHIC), answered YES to a nickname, and typed "AA" on the naming keyboard. On the bag screen
  Right moved to the right-hand ball (MUDKIP) and A asked "Do you choose this POKéMON?" with a YES/NO the
  menu reading saw.
- **Battles on the way.** In wild battles after "used STRING SHOT!" the game waited in a message state that
  `battle` does not count as waiting (a nudge moved it on each time, four times in one battle). MAY's battle
  read kind `trainer`, type flags 0x0C, her TREECKO, and ended `ended` with money 3000 to 3300.
- **Not seen**: a West or North arrow warp, a door entered from another side, elevation 15 ("F" tiles), what
  says a battle message waits for A after STRING SHOT, a nickname actually given, and the naming screen's
  other pages.
- **Superseded in part (2026-09-17):** nothing waited for A after STRING SHOT; its animation held the next message
  ("A move's animation holds a battle's next message", below).

### A move's animation holds a battle's next message (2026-09-17)

**Vanilla ROM, the new game's save**, BUG CATCHER RICK's battle on route 0.17, replayed from one named snapshot
taken at "BUG CATCHER RICK would like to battle!" (gitignored `autoplay/states/`) and played by autoplay's `battle`,
with `probes/battle_state_probe.lua` loaded -- now also logging the bytes the build names gAnimScriptActive and
gPauseCounterBattle, the first two text printers' 0x24 bytes, and every pad change. Five battles; addresses from the
build hashed identical to the ROM, meanings as below.

- **The stall.** "Foe WURMPLE used STRING SHOT!" began printing and printer 0's +0x1B went to 0 115 frames later;
  gAnimScriptActive then read 01 for 228 frames, 00 for 4, 01 for 75, and "MUDKIP's SPEED fell!" began 2 frames after
  that -- 431 frames from the first message's start to the second's. Nothing else the probe logs changed while it read
  01, and no message was on its way.
- **No button was waited for.** With `battle` pressing A after 180 frames of no change, its A landed inside the
  228-frame animation four times in one battle and changed nothing logged; with the press held off while the byte read
  01, seven STRING SHOTs in three more battles went from message to message in 431 frames each, with no button pressed
  between them.
- **Every other stretch of 01** in the first battle, 14 of its 18, read 20, 41 or 75 frames; only STRING SHOT's four
  of 228 outlasted 180.
- **gPauseCounterBattle** counted from 00 to 3F and went back to 00, many times in each battle; not read against
  anything.
- **Not seen**: any other move's animation, the BATTLE SCENE option turned off, a double battle, a wild battle with
  this probe loaded.

### A finished message's printer and window, and a stale one (2026-09-17)

**Vanilla ROM, the new game's save**, route 0.17: RICK's challenge restored from a named snapshot taken with its box
finished, his words after the battle printed live, his battle's first message, and the START menu after it. From the
new `probes/printer_state_probe.lua` (read-only: text printers 0-7 and window slots 0-7 whole on every change, the bytes
before each printer's pointer back to an FF, each window's first and last tile on its background, BG0's drawn rows) and
`text_probe.lua`, with a capture of the restored box (`dev-scripts/shots/emerald/autoplay_rick_challenge_restored.png`,
gitignored). Addresses from the build hashed identical to the ROM.

- **A finished field message.** Restored with "Hahah! Our eyes met! I'll take you on with my BUG POKéMON!" drawn and
  waiting: printer 0's +0x1B read 0, its pointer 0x02021FFF, one past the FF that ends the 58 bytes from 0x02021FC4 (the
  build's gStringVar4); no FF in the 197 bytes before 0x02021FC4. His words after the battle began printing with the
  pointer at 0x02021FC4 and ended at 0x02022009, one past their FF, the same way.
- **The window put, and cleared.** Window 0 read background 0, left 2, top 15, 27 by 4, base block 0x194; its first cell
  on BG0 held tile 0x194 and its last 0x1FF (base + 27 x 4 - 1) while either message was up, and both read 0 once A
  closed the box. In a battle window 0 read 26 by 4 with base 0x090, and its cells 0x090 and 0x0F7 while "BUG CATCHER
  RICK would like to battle!" printed from 0x02022E2C (the build's gDisplayedStringBattle).
- **A stale printer.** In the overworld after the battle, printer 0 still pointed one past "A got ₽64 for winning!"'s FF
  while window 0's cells read 0; with the START menu open its frame drew BG0 rows 0-15 at columns 21-29, into window 0's
  top row.
- **MBOX is not the box** (the byte the build names sFieldMessageBoxMode, in `text_probe.lua`'s logs of 2026-09-16): it
  read 02 from the frame a message's printer began to the frame it finished, and 00 while the finished text stayed up.
- **The driver built on it** (same day): restored at the challenge, `observe` read the box `finished` and `recovered`,
  and `battle` played from it to `ended` with no nudge; after the battle and with the START menu open, no message read.
- **Not seen**: a finished message from a ROM string, windows 8-31, a message box other than window 0, a sign or a
  nurse's box after a restore.
- **Superseded in part (2026-09-17):** a window put with a stale printer can be blank; a finished message also needs
  drawn pixels ("The naming keyboard, and a blank box put back after it", below).

### The naming keyboard, and a blank box put back after it (2026-09-17)

**Vanilla ROM, the new game's "YOUR NAME?"** (reached from the `new_game` snapshot with `advance_text` and `select`
BOY; a snapshot `ng_naming` taken on it, gitignored). From the new `probes/naming_probe.lua` (read-only: the block the
build's sNamingScreen points at -- its +0x1800 and +0x1E10..+0x1E3F -- the cursor's sprite and every sprite whose data
changed, the template, and once the ROM's keyboard table; each on change with the pad) and `printer_state_probe.lua`,
while single presses were made, against captures (`dev-scripts/shots/emerald/autoplay_nm_*`, gitignored). Addresses
from the build hashed identical to the ROM; meanings as below.

- **The block.** While callback2 read 0x080E4F59, the pointer at 0x02039F94 held 0x02000010. +0x1800 read FF until A
  typed H (C2 at +0x1800), then h (DC), and B took the last one off. +0x1E22 read 1 on the capitals page, 2 after Select,
  0 after another and 1 after a third, each drawn so. +0x1E10 read 2 while presses were taken, 4 and 5 through a page
  swap (34 frames, three times), 3 for 17 frames after the seventh letter, and 6, 8, 9 once A chose OK, before callback2 went
  0x08031679 and the pointer 0.
- **The cursor.** +0x1E23 read 0; sprite 0 of the build's gSprites (0x44 bytes a sprite) sat at x 38, y 88, and its
  +0x2E and +0x30 went 0 to 1 on Right and on Down, with x and y moving 12 and 16. Start put them at 8 and 2 (OK, below
  the page and BACK buttons); on the symbols page the button column read 6, and Left from it read 5 and row 3. After the
  seventh letter they went to 8 and 2 by themselves, and the next A closed the screen with the name.
- **The template.** The pointer at +0x1E28 (0x0858BFA8) led to 00 07 01 00 01 ...: the name was drawn with 7 places,
  and +8 pointed at "YOUR NAME?".
- **The keys.** The 0x60 bytes from 0x0858BE40 read as three blocks of 4 rows of 8: block 1 as the capitals page drew
  (A-F, a blank, "." / G-L, a blank, "," / M-S / T-Z), block 0 the same in small letters, block 2 the symbols page
  (0-4 / 5-9 / ! ? ♂ ♀ / - / … “ ” ‘ ’). Every typed byte was its key's: H and T from block 1, h from block 0, … from block 2.
- **autoplay's `type_text` built on it** (same day): "Ab1…" typed across all three pages in 279 frames without
  confirming, as drawn; "BRENDAN" typed, confirmed, and Birch's next box read "So it's BRENDAN?".
- **A blank box put back.** Back from the keyboard, Birch's window 0 (base 0x001) read put (cells 001 and 06C) for 7
  frames before "So it's BRENDAN?" began, while its printer still pointed past "What's your name?"'s FF in gStringVar4:
  the driver took that up as a finished message. Its pixel buffer's first 16 rows read one value (00, then 11); RICK's
  finished box read 8 values, mostly 11.
- **Not seen**: a nickname's keyboard (its title and length), pressing A on the page or BACK button, B with nothing
  typed, the pages' blank keys typed, any other language's keyboard.

### The truck's door taken from rest, the wall clock's screen, and a question drawn instantly (2026-09-17)

**Vanilla ROM, the new game "BRENDAN"** from the snapshot `ng_naming`: the truck (`ng_truck_fast`, text speed FAST), the
room upstairs (`ng_room`) and the clock (`ng_clock`), all gitignored. From autoplay's own answers, captures
(`dev-scripts/shots/emerald/autoplay_ng_*`, `autoplay_clk_*`, gitignored) and the new `probes/task_probe.lua`
(read-only: every active task of the build's gTasks whole, on change, with the pad).

- **The truck's door.** With the door open (its three warp tiles reading behaviour 0x62), a held walk right 2 from (2,2)
  took one tile and bumped at (4,2); from the same snapshot, walk right 1 twice landed on (4,2), the second from rest.
  Right pressed there warped to 0.9 after 21 frames. autoplay's `goto` (4,2), releasing a tile short, then entered
  in 73 frames.
- **The clock screen.** A toward the room's clock from (5,2) printed "The clock is stopped…" and "Better set it and
  start it!", then callback2 read 0x08134C9D. Task 0 ran 0x08134CE9 while the hands turned, and the s16 words of its data
  (from the task's +8, offsets below within them) read, drawn at 10:00 AM: +0 0, +2 300, +4 10, +6 0, +8 0, +10 0, +12 0.
  One Right made +6 1 and +0 6. Right held for 60 frames raised +6 by one every 6 frames to 11, +2 reading 305 from
  11, +8 reading 2 and +12 counting 1 to 10; Left made +6 10 and +8 1; each release set +8 and +12 back to 0. The capture after each showed 10:11 and 10:10 AM. So +4 and +6 are the hours and
  minutes shown, and +0 and +2 the hands' angles; +10 read 0 with AM drawn, and PM was not seen.
- **Its question.** A moved task 0 to 0x08134DC5 and then 0x08134E31, and "Is this the correct time?" was drawn with a
  YES/NO that autoplay's `menu` read (cursor on NO). That question was drawn at once into window 0 while the window's
  printer still pointed past "Better set it and start it!"'s FF, so the driver had taken that up as a finished message;
  an instant print leaves the printer as it was (`text_probe.lua`'s w=1 printer stayed zero through instant prints,
  2026-09-16).
- **Not seen**: PM, the hours turning past 12, YES chosen and what the game then does, a door of this kind entered on a
  bike.

### The wall clock set: PM, midnight, YES, and the clock viewed after (2026-09-17)

**Vanilla ROM, the new game "BRENDAN"** from the snapshots `ng_clock` and `ng_room` (gitignored), with
`probes/task_probe.lua` loaded beside autoplay's driver, against captures (`dev-scripts/shots/emerald/autoplay_clk2_*` to
`autoplay_clk5_*`, gitignored). Routine names from the build hashed identical to the ROM; what the words do as below.

- **Past noon and midnight.** Right held 300 frames from 10:00 raised task 0's +4 (data words from the task's +8) to 12 on
  the frame +6 went 59 to 0, and +10 went 0 to 1 on that frame; it stopped at 13:00, drawn 1:00 PM. Left held from 10:00
  took +4 down through 1 and 0 with +10 at 0, and from 0:59 to 23:59 with +10 going to 1; 22:36 was drawn 10:36 PM.
- **The pace.** +12 counted up once a frame while a direction was held (to 255); the minutes moved one every 6 frames at
  first, and one a frame once +12 passed 60 (11:01 to 13:00 in 119 frames). The frame the pad let go, nothing moved;
  +8 and +12 read 0 on it.
- **The sign.** The AM/PM sign turns over after +10 changes: set to 23:59 from midnight (one minute back), the capture one
  frame after `set_clock` answered still drew AM, and the one 14 frames after it PM, as the later ones did.
- **YES.** A moved the routine to 0x08134DC5 on the pad's own frame and to 0x08134E31 two frames later; "Is this the correct
  time?" and YES/NO were drawn with the cursor on NO. Up moved it to YES; A moved the routine to 0x08134EA5 and then
  0x08134EE9 (the build's `Task_SetClock_Confirmed` and `Task_SetClock_Exit`), callback2 read 0x0809E8B5 23 frames later
  and, through two others, the overworld's 11 frames after that. The room was drawn with MOM beside the player, and her five
  boxes followed ("MOM: BRENDAN, how do you like your new room?" to "...everything's all there on your desk.").
- **Viewed after.** A toward the clock once set went straight to callback2 0x08134B45 (`CB2_ViewWallClock`) and then
  0x08134C9D, with no message; task 0 ran 0x08134F11 and then 0x08134F41 (`Task_ViewClock_WaitFadeIn`, `_HandleInput`), its
  words reading 7, 30, 0 after the clock was set to 7:30, and 7:30 AM was drawn with "A CANCEL"; read again after the
  driver was reloaded they said 7, 31. A left it for the overworld.
- **autoplay's `set_clock` built on it** (same day): 10:00, 13:00, 9:59, 0:00, 23:59 and 12:01 each set with one held
  direction and no overshoot, each capture drawing that time; 7:30 confirmed, and the view screen then read and drew it.
- **Not seen**: the view screen's FadeOut and Exit routines, B on the question, NO chosen, a clock set on a save that already
  has one, the time drawn after the game has been running for hours.

### The starter bag, and a stale message on its screen after a restore (2026-09-17)

**Vanilla ROM, the new game "BRENDAN"**, walked from `ng_clock_set` to Route 101 with autoplay's tools (run log
`autoplay/runs/2026-09-17_033152.953259.ndjson`, segment 3, walked), then from the snapshots `ng_route101_facing_bag` and
`ng_starter_bag` (all gitignored), with `probes/task_probe.lua` beside the driver, against captures
(`dev-scripts/shots/emerald/autoplay_ng_starter_bag.png`, `autoplay_bag_*`, gitignored). Routine and table names from the
build hashed identical to the ROM; what each word does as below.

- **The screen.** A toward BIRCH's bag from (7,15) facing up took callback2 to 0x08133F0D (`CB2_ChooseStarter`) and 3
  frames later 0x081341E1 (`CB2_StarterChoose`); task 0 ran 0x081341FD and then 0x0813425D
  (`Task_HandleStarterChooseInput`), its data word 0 reading 1, with the hand on the bottom ball and "CHICK POKéMON /
  TORCHIC" labelled.
- **Left and Right.** Left made word 0 read 0 on the pad's own frame, the task running 0x08134641 and then 0x08134669
  (`Task_MoveStarterChooseCursor`, `Task_CreateStarterLabel`) and 0x0813425D again 2 frames later; the hand was on the left
  ball with "WOOD GECKO POKéMON / TREECKO". Left again changed nothing. Right made it 1 and then 2 the same way, the second
  with the hand on the right ball and "MUD FISH POKéMON / MUDKIP"; Right again changed nothing.
- **The species.** The three u16s at 0x085B1DF8 (`sStarterMon`), named through the species table, read TREECKO, TORCHIC and
  MUDKIP in that order, the label drawn for word 0, 1 and 2 (autoplay's `select` to each, against the captures after it).
- **Choosing.** A on MUDKIP ran 0x08134341 (`Task_WaitForStarterSprite`) on the pad's frame, 0x08134391 17 frames later and
  then 0x08134401 (`Task_HandleConfirmStarterInput`), with "Do you choose this POKéMON?" and a YES/NO the menu reader read
  (cursor on YES). B there ran 0x081344AD and 0x081341FD and was back at 0x0813425D with word 0 still 2. YES began a wild
  battle ("Wild ZIGZAGOON appeared!", "Go! MUDKIP!"); after it BIRCH's words, then in the lab (map 1.4) "BRENDAN received the
  MUDKIP" and a nickname YES/NO.
- **A stale message after a restore.** Restored at `ng_starter_bag`, window 0 read put and drawn while its printer was
  inactive and pointed one past the FF of "In my BAG! There's a POKé BALL!" in the field message buffer, so the driver took
  that up as a finished message; while the driver had been running, the bag screen's own "PROF. BIRCH is in trouble!"
  printed into window 0 read as `screen_text` instead (the driver saw it printed instantly). The same restore reading on
  `ng_gender` (callback2 0x0802F6B1, `CB2_MainMenu`) and `rick_challenge` (the overworld's) took up the right box, and on
  `ng_clock` and `ng_naming` nothing.
- **Not seen**: the other two balls chosen, NO on the question, the nickname screen, the bag on any build but vanilla.

### Autoplay's noclip: through a collision tile and a character (2026-09-17)

**Vanilla ROM**, autoplay's `noclip` cheat (the mechanism of `probes/noclip.lua`, applied by the driver every frame), from
the snapshots `session_end_route016` and `fast_text_route102` (gitignored); read with autoplay's `walk`, `observe` and the
cheat's own counts.

- **A collision tile.** On route 0.16 at (5,4), `walk` up 3 moved 2 and stopped `blocked` at (5,1), collision 1. From the
  same snapshot with noclip on (57 grid words cleared, 1 character moved), `walk` up 3 moved 3 and answered `done` at (5,1);
  `local_map` drew the tiles around as `.` where it had drawn `#`. Off put back 75 words and 1 elevation -- more words than
  first cleared, since each frame clears what the moved window holds -- and `local_map` drew the `#` again.
- **A character.** On route 0.17 at (25,13), `walk` down 2 moved 0, `blocked` by RICK (local id 3) on (25,14). With noclip
  on (52 words, 3 characters) and the core restarted in between, `walk` down 2 moved 2 to (25,15), through his tile, while
  `nearby` still listed him at (25,14). Off put back 52 words and 3 elevations.
- **Not measured**: what it costs a frame, water, a ledge, a map changed while it is on, a snapshot taken while it is on.

### A battle controller at work: the rescue battle's intro (2026-09-17)

**Vanilla ROM, the new game's save**, BIRCH's rescue battle against a wild ZIGZAGOON, from the snapshot `ng_rescue_battle`
(gitignored; taken on the first frame callback2 read BattleMainCB2, f376300), with `probes/battle_state_probe.lua` loaded --
now also logging the bytes the build names gBattleMainFunc and gIntroSlideFlags -- and played by autoplay's `battle`. Logs
`battle_state_probe_bizhawk-dev-loader-autoplay_target_20260917_041303.log` and `_041754.log` (gitignored). Addresses from the
build hashed identical to the ROM; routine names are the build's, what each did as below.

- **The nudge.** `battle strongest` pressed A once at f376489, before "Wild ZIGZAGOON appeared!", its log's `nudged`
  entry. From f376308 the u32 the build names gBattleControllerExecFlags read 03: battler 0's controller routine (the
  build's gBattlerControllerFuncs, one word per battler) was CompleteOnBattlerSpriteCallbackDummy until f376462, and
  battler 1's TryShinyAnimAfterMonAnim until f376526, when the flags read 00 and both routines were back at the ones they
  idled in (PlayerBufferRunCommand, OpponentBufferRunCommand). Nothing in `battle`'s progress signature changed in those
  218 frames.
- **The A did nothing.** From the same snapshot with no input at all (`wait` 520), the flags went 03, 02 and 00 on the
  same frames, f376308, f376462 and f376526, and gBattleMainFunc moved on at f376527 as before. The message that followed
  then waited: battler 0's routine read CompleteOnInactiveTextPrinter2 with bit 0 set from f376528 to the end of the wait,
  "Wild ZIGZAGOON appeared!" `waiting_for_button`.
- **Every other stretch.** Through the whole battle (four turns, the faint, the EXP), a controller's bit read set for 20
  frames or more 28 times; none had a button down but TryShinyAnimAfterMonAnim's (the nudge, above) and the three in
  CompleteOnInactiveTextPrinter2 (messages, each ended by `battle`'s A). The rest, in frames: the send-out (BattleControllerDummy 31, Intro_TryShinyAnimShowHealthbox
  108), PlayerDoMoveAnimation 44, OpponentDoMoveAnimation 44-58, DoHitAnimBlinkSpriteEffect 33, CompleteOnFinishedBattleAnimation
  76, CompleteOnHealthbarDone 20, and battler 1's own CompleteOnInactiveTextPrinter 21-27 (the foe's messages, which went
  on with nothing pressed). HandleInputChooseAction and HandleInputChooseMove, the menus, read with bit 0 set on every
  line logged (8) and were answered in under 20 frames.
- **With a set bit counted as progress** (autoplay's `animationPlaying`, unless the routine is one of those three waits),
  the same battle from the snapshot went from "Wild ZIGZAGOON appeared!" to BIRCH's nickname YES/NO with no nudge, twice
  (probe on, 3091 frames; probe off, 3091). With the probe on, every A landed on something waiting: 8 on the battle menus,
  3 on a message's arrow, 15 on BIRCH's words after the battle.
- **Not seen**: a controller waiting for a button in any other routine (a switch after a faint, a move to forget, a
  catch's nickname, the BAG), a double battle, the BATTLE SCENE option turned off. The nudge last session also landed on
  "Go! MUDKIP!", not repeated here; the send-out's routines above ran 139 frames between them.

### What a move's type does to its damage (2026-09-17)

**Vanilla ROM, the new game's save**, BIRCH's rescue battle from the snapshots `ng_rescue_move_menu` and `ng_rescue_action_menu`
(gitignored), with `probes/type_calc_probe.lua` loaded (execute hooks at the entries of the battle script commands the build
names Cmd_typecalc and Cmd_adjustnormaldamage). Logs `type_calc_probe_bizhawk-dev-loader-autoplay_target_20260917_042811.log`
and `_043610.log` (gitignored). The decomp was the map for where the multiplying happens; addresses from the build hashed
identical to the ROM.

- **The table.** The 0x150 ROM bytes the build names gTypeEffectiveness read as 112 triples: 108 of (a move's type, a
  defending type, 20, 5 or 0), then FE FE 00, then two more (NORMAL and FIGHT against GHOST, 0), then FF FF 00. Types are
  the indices autoplay already names moves by (gTypeNames: 0 NORMAL to 17 DARK, 9 drawn as "???"). Taken as a chart, the 110
  entries and the ×1 of every pair not listed matched all 289 cells of Bulbapedia's Generation II-V type chart, the map the
  user named; no pair was listed twice.
- **What the battle does with it.** Ten trials, each from `ng_rescue_move_menu` with MUDKIP's (WATER) first move, its attack
  and special attack (200), and ZIGZAGOON's two type bytes (+0x21, +0x22 of its gBattleMons entry) written through autoplay's
  `exec`, then the move chosen with `select`. gBattleMoveDamage at typecalc's entry and at adjustnormaldamage's, and
  gMoveResultFlags after:

  | Move (its type) | Foe's type bytes | Damage before → after | Flags | Message |
  |---|---|---|---|---|
  | TACKLE (NORMAL) | NORMAL | 95 → 95 | 00 | none |
  | WATER GUN (WATER) | NORMAL | 130 → 195 | 00 | none |
  | TACKLE | ROCK | 95 → 47 | 04 | "It's not very effective…" |
  | TACKLE | GHOST | 95 → 0 | 08 | "It doesn't affect Wild ZIGZAGOON…" |
  | WATER GUN | GROUND, ROCK | 130 → 780 | 02 | "It's super effective!" |
  | WATER GUN | WATER, GRASS | 130 → 48 | 04 | "It's not very effective…" |
  | MUD-SLAP (GROUND) | FIRE, FLYING | 55 → 0 | 08 | "It doesn't affect…" |
  | MUD-SLAP | FLYING, FIRE | 55 → 0 | 08 | "It doesn't affect…" |
  | EMBER (FIRE) | GRASS, STEEL | 130 → 520 | 02 | "It's super effective!" |
  | EMBER | WATER, GRASS | 130 → 130 | 00 | none |

  So: ×1.5 (130 to 195) when the move's type is one of the attacker's type bytes, then the multiplier of each
  entry naming the move's type and one of the foe's two bytes, one step at a time in whole numbers (130, 195, 97, 48), the
  entries after FE included, and a single type (both bytes the same) counted once. The flags followed: 02 with a ×2 left,
  04 with a ×0.5 left, neither when they cancelled, 08 at ×0.
- **Its own type bytes.** MUDKIP's battle entry read 0B 0B and ZIGZAGOON's 00 00, the same as +6 and +7 of their 28-byte
  entries in the block named gSpeciesInfo; RICK's WURMPLE's read BUG.
- **Chosen by autoplay.** `battle` with the new policy `effective` (power × accuracy × that bonus × those multipliers) against
  `strongest`, from `ng_rescue_action_menu` with the moves and the foe's types written before FIGHT (written after the move
  menu opened, the game refused Down onto a slot its menu had opened empty, and `battle` answered `stuck` 4 times out of 6):
  ROCK/GROUND, EMBER five turns against MUD-SLAP two; WATER/GRASS, WATER GUN seven against EMBER two; GHOST, TACKLE doing
  0 until its PP ran out against MUD-SLAP from the first turn. Every typecalc logged ran the move `battle` had chosen that
  turn; in the GHOST run TACKLE was chosen ten times and reached typecalc eight (the other two not looked at). The
  same `effective` run with the probe unloaded: MUD-SLAP twice, 2222 frames, as with it. RICK's battle from
  `rick_battle_start` under `effective`: TACKLE every turn (MUD-SLAP weighed ×0.5 against BUG), `ended`, a win.
- **Not measured**: an ability (the decomp names LEVITATE and WONDER GUARD inside typecalc), FORESIGHT or ODOR SLEUTH (the
  decomp stops at FE for a foe under them), a move whose type changes (HIDDEN POWER, WEATHER BALL), the physical and special
  split by type, weather, a double battle, and the AI's own copy of the calculation.

## Not measured yet

### The rest of the text printer (from 2026-09-16)

A box that scrolls rather than clears (FA), pauses, and the FC/FD/F8/F9 commands with their
parameters; list menus other than the bag's (the PC, shops), the battle menus and battle text; any font but the
message font's line advance; any text speed but this save's, and any instant-text build; any patched
build. To settle: `probes/text_probe.lua` through a conversation that scrolls, a shop, the bag and one
battle, each paired with captures.

### The rest of the map and the walk (from 2026-09-16)

- What the grid's border holds outdoors, next to a connected map (a step across the edge is measured:
  "Crossing a map edge"): dump it with `map_probe.lua` standing at an edge of 0.10.
- Whether a clear tile at another elevation accepts a step (the local map shows its elevation digit):
  a bridge, stairs, the Center's elevation-0 tile beside the stairs.
- A character in the way: does `walk` read the refusal the same way, and name the character.
- A ledge, a run, a bike, and a wild encounter or a trainer's sight during a walk (`moved` for a hop,
  `left_overworld`, `dialogue_open`).
- Other values of +0x1C, what byte 1's 0xA0 means, and the +0x1E/+0x1F bytes that read 0x69 on the
  door; the warp entry's +4 and +5.

### The rest of the party, the bag and the flags (from 2026-09-16)

- An egg and a bad egg: what the slot's +0x13 byte (0x02 on the MUDKIP) and the party menu show. To
  settle: a daycare egg with `party_bag_probe.lua` loaded.
- Status conditions in +0x50: poison, sleep and the rest. To settle: a battle that inflicts one.
- What kind 2's block holds, and kind 3's other fields (the decomp names EVs and contest stats, IVs,
  ability, ribbons, the met location): read against a page that draws each.
- When SaveBlock1's party copy stops matching the live one: after a battle, then after an in-game save.
- Whether +0x498 is the PC's item storage, with its quantity stored plainly: open a PC's ITEM STORAGE.
- A stack past 99, and the pocket slot counts (30, 16, 64, 46, 30 from the build's layout): give past
  them and open the bag.
- What flags 0x860, 0x861, 0x86F and 0x870 are, and any flag past the badges; the ids from 0x4000 the
  decomp routes elsewhere, which `set_flag` does not accept.

### The rest of a battle (from 2026-09-16)

- A trainer battle: what gBattleTypeFlags reads, whether battler 0 is still the player's, and the
  text around a trainer's Pokémon. To settle: the first trainer battle, with `battle_state_probe.lua`.
- A double battle: the positions, both controllers, and which cursor belongs to which battler.
- The BAG and POKéMON menus inside a battle, a switch, a catch, a faint, a whiteout, a run that fails,
  and what gBattleOutcome reads for each.
- The FC codes seen but not measured: whether FC 09 and FC 0A draw anything (neither takes an argument:
  "A trainer's sight and defeat flag", 2026-09-17), and the one that begins "Got away safely!".
- What move bytes +0, +5, +6 and +8 mean (the decomp names effect, secondary chance, target and flags).
