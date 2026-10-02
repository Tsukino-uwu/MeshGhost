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
- Ledges, water, and other maps read from the ROM (2026-09-17)
- A warp's arrival, a whiteout, a Center's counter, and WALLY's battle (2026-09-17)
- Rustboro: a north arrow warp, a floor at elevation 0, a YES/NO that ignores an early A, ROXANNE, an evolution (2026-09-17)
- The learn-a-move question, the move list and the evolution scene (2026-09-17)
- The bag inside a battle, and a POTION used through it (2026-09-17)
- A Mart: the buy list, the quantity box, and the list left active under it (2026-09-17)
- The live grid against the ROM's layout: a gym's barriers opened by its switches (2026-09-17)
- A mud slope on 0.26: onto it and slid back (2026-09-17)
- Map headers, events and behaviours read by an unattended session (2026-09-17)
- The field controls lock, and a script context left waiting after a ROCK SMASH escape (2026-09-23)
- A ledge hopped right, a RUN refused by ARENA TRAP, and a battler's ability (2026-09-23)
- The MACH BIKE from RYDEL, SELECT to mount, and the map's cycling bit (2026-09-23)
- TM and HM compatibility, a double battle's menus and target, and a move's target byte (2026-09-23)
- SURF: the question, the avatar byte, and stepping off onto land (2026-09-23)
- Long grass (0x03) refuses the MACH BIKE (2026-09-23)
- The repel step counter, the FLY map's place name, and rotating gate bytes (2026-09-23)
- The FLY map's cursor, the party screen's cursors, and Mossdeep's rotating statues (2026-09-23)
- Boulders and STRENGTH, hide flags, currents, waterfalls, cracked floors on the MACH BIKE, and DIVE (2026-09-24)
- Which badge each field move needs, from the party menu (2026-09-24)
- 2026-10-02 — Facts the code comments carried, moved here word for word
- Not measured yet: The rest of the text printer (from 2026-09-16)
- Not measured yet: The rest of the map and the walk (from 2026-09-16)
- Not measured yet: The rest of the party, the bag and the flags (from 2026-09-16)
- Not measured yet: The rest of a battle (from 2026-09-16)
- Not measured yet: Field-move badges on an Archipelago seed (from 2026-09-24)
- Not measured yet — what the code comments said the game's code shows (moved 2026-10-02)

## Measured

### Text printing, menus and the character encoding (2026-09-16)

**Vanilla ROM.** Its SHA-1 (`F3AE0881…`) equals our pokeemerald build's and what
`gameinfo.getromhash()` returns, so the build's addresses are addresses; every meaning below is from
`probes/text_probe.lua` (read-only) and `probes/charset_probe.lua` (writes the message buffer once),
read against captures of the same frames (thirteen of the charset's boxes among them). Used by `autoplay/drivers/bizhawk/games/emerald.lua`, whose
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
movement bytes and the avatar block on every frame they change), against four captures
of the map and the walks that produced them. Used by
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
drew (the party, its order, the badges, the items given). Used by `autoplay/drivers/bizhawk/games/emerald.lua` for `party`, `bag`, `money`,
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
position. Then three more battles driven by
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
summary's BATTLE MOVES page with each of the three moves selected. Used by
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
of the same moments. The trainer was found with
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
  an FA scrolled the text (a capture of that moment).
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
of the second trainer and the heal.

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
player's coordinates and the pad, on every change). Captures of the same
moments. Addresses from the build hashed identical to the ROM; meanings as below.

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
and entries, on every change, with the pad), read against captures of the bag. REPEL, POTION and nine more kinds were put in the ITEMS pocket with `give_item`; everything
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
written), played to MAY's battle on Route 103 with autoplay's tools, one run log carried across every
core. Readings from `observe` (warps now carry their tile's collision,
elevation and behaviour; extras the script context status), `walk`, `goto`, the programs' logs, captures
along the way, and `probes/trainer_approach_probe.lua`
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

**Vanilla ROM, the new game's save**, BUG CATCHER RICK's battle on route 0.17, replayed from one snapshot
taken at "BUG CATCHER RICK would like to battle!" (reached) and played by autoplay's `battle`,
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
`text_probe.lua`, with a capture of the restored box. Addresses from the build hashed identical to the ROM.

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

**Vanilla ROM, the new game's "YOUR NAME?"** (reached from a snapshot at the new game's start with `advance_text` and
`select` BOY; a snapshot taken on it). From the new `probes/naming_probe.lua` (read-only: the block the
build's sNamingScreen points at -- its +0x1800 and +0x1E10..+0x1E3F -- the cursor's sprite and every sprite whose data
changed, the template, and once the ROM's keyboard table; each on change with the pad) and `printer_state_probe.lua`,
while single presses were made, against captures of each press. Addresses
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

**Vanilla ROM, the new game "BRENDAN"** from the snapshot at "YOUR NAME?", then snapshots in the truck (text speed
FAST), the room upstairs and at the clock. From autoplay's own answers, captures of the same moments and the new `probes/task_probe.lua`
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

**Vanilla ROM, the new game "BRENDAN"** from the snapshots at the clock and in the room upstairs, with
`probes/task_probe.lua` loaded beside autoplay's driver, against captures of four tries. Routine names from the build hashed identical to the ROM; what the words do as below.

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
  has one, the time drawn once the game clock has advanced past 24 hours.

### The starter bag, and a stale message on its screen after a restore (2026-09-17)

**Vanilla ROM, the new game "BRENDAN"**, walked from the clock being set to Route 101 with autoplay's tools (walked), then from snapshots
facing the bag and at the starter bag (reached), with `probes/task_probe.lua` beside the driver, against captures of
the same moments. Routine and table names from the
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
- **A stale message after a restore.** Restored at the starter bag, window 0 read put and drawn while its printer was
  inactive and pointed one past the FF of "In my BAG! There's a POKé BALL!" in the field message buffer, so the driver took
  that up as a finished message; while the driver had been running, the bag screen's own "PROF. BIRCH is in trouble!"
  printed into window 0 read as `screen_text` instead (the driver saw it printed instantly). The same restore reading on
  snapshots at the gender question (callback2 0x0802F6B1, `CB2_MainMenu`) and RICK's challenge (the overworld's) took up
  the right box, and at the clock and "YOUR NAME?" nothing.
- **Not seen**: the other two balls chosen, NO on the question, the nickname screen, the bag on any build but vanilla.

### Autoplay's noclip: through a collision tile and a character (2026-09-17)

**Vanilla ROM**, autoplay's `noclip` cheat (the mechanism of `probes/noclip.lua`, applied by the driver every frame), from
snapshots on routes 0.16 and 0.17 (reached); read with autoplay's `walk`, `observe` and the
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

**Vanilla ROM, the new game's save**, BIRCH's rescue battle against a wild ZIGZAGOON, from a snapshot
taken on the first frame callback2 read BattleMainCB2 (f376300), with `probes/battle_state_probe.lua` loaded --
now also logging the bytes the build names gBattleMainFunc and gIntroSlideFlags -- and played by autoplay's `battle`, twice. Addresses from the
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

**Vanilla ROM, the new game's save**, BIRCH's rescue battle from snapshots at its move menu and its action menu, with `probes/type_calc_probe.lua` loaded (execute hooks at the entries of the battle script commands the build
names Cmd_typecalc and Cmd_adjustnormaldamage), two runs. The decomp was the map for where the multiplying happens; addresses from the build hashed
identical to the ROM.

- **The table.** The 0x150 ROM bytes the build names gTypeEffectiveness read as 112 triples: 108 of (a move's type, a
  defending type, 20, 5 or 0), then FE FE 00, then two more (NORMAL and FIGHT against GHOST, 0), then FF FF 00. Types are
  the indices autoplay already names moves by (gTypeNames: 0 NORMAL to 17 DARK, 9 drawn as "???"). Taken as a chart, the 110
  entries and the ×1 of every pair not listed matched all 289 cells of Bulbapedia's Generation II-V type chart, the map the
  user named; no pair was listed twice.
- **What the battle does with it.** Ten trials, each from the snapshot at the move menu with MUDKIP's (WATER) first move, its attack
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
  `strongest`, from the snapshot at the action menu with the moves and the foe's types written before FIGHT (written after the move
  menu opened, the game refused Down onto a slot its menu had opened empty, and `battle` answered `stuck` 4 times out of 6):
  ROCK/GROUND, EMBER five turns against MUD-SLAP two; WATER/GRASS, WATER GUN seven against EMBER two; GHOST, TACKLE doing
  0 until its PP ran out against MUD-SLAP from the first turn. Every typecalc logged ran the move `battle` had chosen that
  turn; in the GHOST run TACKLE was chosen ten times and reached typecalc eight (the other two not looked at). The
  same `effective` run with the probe unloaded: MUD-SLAP twice, 2222 frames, as with it. RICK's battle from
  its snapshot under `effective`: TACKLE every turn (MUD-SLAP weighed ×0.5 against BUG), `ended`, a win.
- **Not measured**: an ability (the decomp names LEVITATE and WONDER GUARD inside typecalc), FORESIGHT or ODOR SLEUTH (the
  decomp stops at FE for a foe under them), a move whose type changes (HIDDEN POWER, WEATHER BALL), the physical and special
  split by type, weather, a double battle, and the AI's own copy of the calculation.

### Ledges, water, and other maps read from the ROM (2026-09-17)

**Vanilla ROM**, the old save restored from a snapshot on map 0.18, read with autoplay's `exec` (read-only code),
`walk` and `goto`, and `probes/step_probe.lua` loaded beside the driver for the hop. The build's `.sym` and the decomp are the
map for the names.

- **Any map's header.** The block named gMapGroups (0x08486578) held, at group 0, a pointer to a list whose entry 18 pointed at
  a ROM header whose 28 bytes read the same as gMapHeader's copy (0x02037318) while on 0.18. Its layout's map data (+0x0C)
  read equal to the live grid (gBackupMapLayout, 7 tiles in) on all 1760 tiles of the 80 by 22 map. Other maps were read
  the same way and their tables used live: 0.10's warps and 2.2's (the Center) matched the doors walked through below.
- **Connections** read as the adapter's seam work measured them (+0x0C: count, then 12-byte entries). 0.18: south to 0.10
  offset 0, east to 0.25 offset -60; 0.10: north 0.18, south 0.16, west 0.17, all 0; 0.16: north 0.10, south 0.9; 0.9:
  north 0.16. **The offset**: 0.18's side at x=79 is open on rows 7-11 and 0.25's at x=0 on rows 67-71; `goto` from 0.18
  (76,9) to 0.25 (2,69) went straight right, 5 tiles, no turn -- a row r on the first map is r minus the offset on the next.
- **A ledge.** On 0.18 the tiles with behaviour 0x3B read collision set, elevation 3 (23 of them, (6,5) among the
  row at y=5). Down from (6,4): Down pressed, a 7-frame turn (avatar +2 at 1); then on one frame the object's y went 11 to 12
  (map y 4 to 5, onto the ledge tile) with the avatar's +2 and +3 at 2 and the previous y still 11; 15 frames later y went
  to 13 (map 6) with the previous at 12; 16 frames later the previous caught up and byte 0's top bit came back; at rest 2
  frames after. `walk down 1` answered `done`, moved 2, overshot 1. Up into it from (6,6): refused, as a wall's bump
  reads, `blocked_by` behaviour 59, collision 1. `goto` (6,4) to (6,7) went straight down over it (3 tiles, 60 frames); back
  to (6,4) it went round (5 tiles, 2 turns).
- **Water.** 338 tiles of 0.18 read behaviour 0x15, collision 0, elevation 1. On foot, `walk right` from the shore (21,8)
  into (22,8) was refused (`blocked_by` behaviour 21, collision 0, elevation 1).
- **The player's facing.** The player object's +0x18 read 0x11 after a walk down, 0x22 up, 0x33 left and 0x44 right.
- **Warps crossed by `goto`**: 0.10's Center door (6,16), behaviour 0x69, walked up into from below, arrived on 2.2; and
  back out by one of 2.2's warps at (6,8) and (7,8). The destination's warp number (+4 of a warp entry, 0 on each of 0.10's) was read with `exec`; nothing uses it.
- **Scripts on the way.** On 0.10's bottom row, going south, MAY's "Let's hurry home!" opened (the player just past her
  battle); on 0.10's west side, going left, "Aaaaah! Wait! Please don't come in here." -- both stopped `goto`
  `dialogue_open`.
- **Not measured**: ledges of behaviour 0x38, 0x39 and 0x3A (on 0.17 and other routes, not walked); water at another
  behaviour; a cut tree, a boulder, a Rock Smash rock, a waterfall; a warp to a map the header names as dynamic; a warp
  that lands on an arrow warp; what the refused water step looks like surfing or with SURF known.

### A warp's arrival, a whiteout, a Center's counter, and WALLY's battle (2026-09-17)

**Vanilla ROM**, the old save played from Route 110 (0.25) through the story to Petalburg's gym with autoplay's tools
(walked), with captures along the way.

- **Where a warp lands.** A warp entry's +5 is the destination's warp number from 0: 0.10's Center door (6,16) reads +5 0
  and the player arrived on 2.2's warp 0 at (7,8); 2.2's (7,8) reads +5 2 and the player arrived on 0.10's warp 2 at
  (6,16), the game then stepping the player down to (6,17). +4 read 3 on 2.2's two mats (their tiles read elevation 3), 4
  on its stairs and 0 on the other maps read.
- **A whiteout.** POKéFAN ISABEL's PLUSLE fainted MUDKIP (8 HP at the start) on 0.25: "A is out of usable POKéMON!", "A
  whited out!". `battle` answered `ended` with `outcome_raw` 2; money 3300 before, 1650 after; the player stood on 0.10
  (6,17), below the Center door there (the last Center entered), MUDKIP at 25/25, status 0.
- **A Center's counter.** Petalburg's Center (8.4): the nurse at (7,2), the counter tile (7,3) behaviour 0x80, collision
  set, elevation 0. From (7,4) facing up, A opened "Hello, and welcome to the POKéMON CENTER.", "Would you like to rest
  your POKéMON?" with a YES/NO; YES healed MUDKIP 13/27 to 27/27.
- **WALLY's catching battle** (the gym, after DAD's words): the type flags read 0x204, against 0x04 in the four wild
  battles measured before. The game played ZIGZAGOON's turns and WALLY's POKé BALL with no input; the bag's USE/CANCEL that
  `battle` had stopped on moved on alone within 300 frames to "Gotcha! RALTS was caught!". `outcome_raw` read 7 after it.
  The message after "Wild RALTS appeared!" and "RALTS was caught!" decoded with bytes after an FC read raw
  (`{FC}Ë{7F}`), not measured.
- **Map ids met** (each map's number read as `observe` names it, matching the decomp's order where checked): Littleroot 0.9,
  Oldale 0.10, Routes 101-103 as 0.16-0.18, Petalburg 0.0, its Center 8.4 and gym 8.1 (the door drawn "GYM" in
  a capture), Birch's lab 1.4.
- **Not measured**: the whiteout's own text beyond the two lines, where a whiteout lands with no Center visited, other
  `outcome_raw` values, other bits of the type flags.

### Rustboro: a north arrow warp, a floor at elevation 0, a YES/NO that ignores an early A, ROXANNE, an evolution (2026-09-17)

**Vanilla ROM**, played on from after WALLY's battle with autoplay's tools, the same
session, with captures along the way.

- **Petalburg Woods' north exit** (24.11 (14,5) and (15,5)): behaviour 0x64, collision 0, elevation 0. `goto` stepped onto
  it and stood there (`done`, no warp, twice); from (15,5) Up answered `map_changed` onto 0.19 (11,29).
- **The gym's floor at elevation 0.** Petalburg's gym (8.1) from the scene with DAD: the player object's elevation read 0,
  the floor round it read 0 and the entrance mats (4,111) and (5,111) read 3 (behaviour 0x65). A `goto` planned at
  elevation 0 refused the mats as "not an open tile at elevation 0"; planned onto any level it walked onto (4,111), and
  Down there left for 0.0 (15,8).
- **A YES/NO right after it opens.** The nurse's "Would you like to rest your POKéMON?" in Petalburg's Center, just after
  `talk` stopped `menu_open` on it: A held 30 frames did nothing; 10 frames later a 2-frame A answered YES ("Okay, I'll take
  your POKéMON"). `select` holding A from that moment had answered "did not respond" twice; with a release and a second
  press after 15 frames it answered YES 3 times of 3.
- **A character not loaded.** In Rustboro's gym (11.3) from its door (5,17), ROXANNE (local 1, template at (5,2)) was not in
  the object slots; `talk` to her by her template's tile reached her, past YOUNGSTER TOMMY (local 2, (5,13), range 2), whom
  the only way up crossed.
- **ROXANNE.** The first try, MUDKIP Lv 12 to 14 with WATER GUN chosen every turn: her NOSEPASS used ROCK TOMB, BLOCK, an
  ORAN BERRY and two POTIONs and fainted MUDKIP -- `outcome_raw` 2, the player at 0.3 (16,39) below the Center door there,
  money 4982 to 2491. The second, Lv 14 to 16: WATER GUN every turn, "Player defeated LEADER ROXANNE!", STONE BADGE,
  TM39; `observe` then read `badges` [1] and `badge_count` 1.
- **The learn-a-move question and the evolution scene.** "Delete a move to make room for BIDE?" in the battle read as no
  menu, and after `battle`'s nudges the move list was up (callback2 0x081BFAB5, the cursor drawn on TACKLE; Down moved it one
  row, A chose GROWL, "1, 2, and… Poof!" printed with FC bytes read raw). After the battle, "What? MUDKIP is evolving!":
  `battle` answered `stuck` on it; 900 frames with no input later "Congratulations! Your MUDKIP evolved into MARSHTOMP!"
  (callback2 0x0813E3A5), then "Delete a move to make room for MUD SHOT?", whose YES `advance_text`'s tap answered; BIDE
  was chosen the same way. `advance_text` answered `battle_started` as that screen closed.
- **Not measured**: the learn-a-move YES/NO and the move list in memory, the evolution scene's state, the arrow warps 0x63,
  a hide flag on a character template.

### The learn-a-move question, the move list and the evolution scene (2026-09-17)

**Vanilla ROM.** Made situation: a snapshot in Rustboro restored, MUDKIP's EXP written to 2534 through `exec` (its encrypted block
and checksum; `observe` read it back with no mismatch), a wild WHISMUR on 0.31; and
the save just after the STONE BADGE with MARSHTOMP's EXP written to 5459, a wild ABRA there. `probes/battle_state_probe.lua` loaded, with its
new SUM and TASK lines, with captures of the same moments. The decomp was the map for every routine and field; the build's `.sym` names the addresses.

- **The level-up learnsets and EXP table.** The ROM's pointer table the build names gLevelUpLearnsets read, for MUDKIP,
  BIDE (117) at 15, and for MARSHTOMP MUD SHOT (341) at 16 and FORESIGHT (193) at 20; the table it names gExperienceTables,
  at the growth byte +0x13 of a species' 28-byte entry, 2535 for level 16 and 5460 for 20. The game did what they said: EXP
  2534 at Lv 12 went to Lv 15 and "trying to learn BIDE", then Lv 16 and an evolution with MUD SHOT; 5459 at Lv 16 went to
  Lv 20 and FORESIGHT.
- **The question inside a battle.** After "Delete a move to make room for BIDE?" the battle script's pointer stood at
  0x082DABF4, whose byte 5A indexes the ROM's command table (the build's gBattleScriptingCommandsTable) to 0x0804E039 (the
  build's Cmd_yesnoboxlearnmove, +1). gBattleScripting +0x1F read 1 while the YES/NO waited, gBattleCommunication +1 the
  cursor (0 YES; `select NO` made it 1). A made +0x1F 2 and opened the move list; NO printed "Stop learning BIDE?", after
  which the pointer stood at 0x082DAC03 with +0x1F 1 and the cursor 0 again, and NO there went back to "MUDKIP is trying to
  learn BIDE."
- **The move list.** callback2 0x081BFAB5 (the build's MainCB2 in the summary screen), task 0 running 0x081C174D (its
  Task_HandleReplaceMoveInput); the pointer sMonSummaryScreen (0x0203CF1C) led to a block whose +0x40BC read 03, +0x40BE 00
  (the party slot), +0x40C4 the move to learn (0x0075 BIDE, 0x0155 MUD SHOT) and +0x40C6 the cursor: Down took it 0 to 4,
  and the captures drew the red frame on TACKLE at 0 and on BIDE, the move to learn, at 4 -- the four moves in the party's
  slot order, then the new one. A on 1 forgot GROWL. A on 3 forgot WATER GUN, not BIDE: BIDE had taken GROWL's slot 1, which
  the capture drew (a wrong press of this session's, and the reason the entries are read, not assumed).
- **The evolution scene.** "What? MUDKIP is evolving!" read `finished`; with no input callback2 read 0x0813E3A5 (the build's
  CB2_EvolutionSceneUpdate) and task 0 ran 0x0813E571 (Task_EvolutionScene), data word 0 stepping to 0x0F by frame 662300,
  where "Congratulations! Your MUDKIP evolved into MARSHTOMP!" waited on its arrow (2646 frames with no input, until an A).
  Then word 0 read 0x16 while MUD SHOT was offered, data word 6 its step: 1 and 2 on "is trying to learn" and "can't learn
  more than four moves" (each on its arrow), 3 printing "Delete a move to make room for MUD SHOT?", 4 with the YES/NO up
  (Down made gBattleCommunication +1 read 1 and the capture drew No), 6 on the list (the same summary fields, move 0x0155),
  7 and 8 through "Poof!". Data word 7 read 5 on that question and 0x0B on "Stop learning MUD SHOT?", which NO opened; NO
  there went back to step 0. At the end callback2 went to BattleMainCB2 again, where `observe` read `mode` battle for a
  moment with the old battlers.
- **Autoplay's reading of them, checked live.** From a snapshot at the WHISMUR battle's start: `battle effective` stopped `needs_choice` on
  the BIDE question with no nudge; `select NO` then read "Stop learning BIDE?" as `stop_learning`; `select NO`; `battle effective
  forget strong_variety` chose YES and GROWL, went through the evolution, YES and BIDE for MUD SHOT, and ended (TACKLE, MUD
  SHOT, MUD-SLAP, WATER GUN). From the ABRA battle: NO to FORESIGHT, YES to "Stop learning FORESIGHT?", "did not learn".
- **Not measured**: an HM in the list; a party slot other than 0 learning or evolving; the list opened outside a battle
  (a TM, the Move Tutor); B anywhere here (the decomp says B held during the evolution stops it); the FC bytes read raw in
  "Stop learning" and "Poof!".

### The bag inside a battle, and a POTION used through it (2026-09-17)

**Vanilla ROM.** Made situation: the save just after the STONE BADGE (MARSHTOMP Lv 16 at 26/51 HP), `give_item` POTION ×3, a wild
TAILLOW on 0.31 (reached); autoplay's `observe`, `select` and `exec` reads of the build's gPartyMenu (0x0203CEC8),
with captures of the same moments.

- **BAG from the action menu** opened the bag: `observe` read the list as it reads the bag's list in the field (the
  task running the build's ListMenuDummyTask) -- POTION and CLOSE BAG, pocket `items`, with the POTION's effect text in
  window 1 -- about 40 frames after the action menu answered; a `select` in that gap found no menu.
- **A on POTION** opened USE / CANCEL (the menu reader, window 6) and "POTION is selected."; USE opened "Use on which
  POKéMON?" -- callback2 0x081B01B1 (the build's CB2_UpdatePartyMenu, +1) with task 0 running 0x081B1371 (its
  Task_HandleChooseMonInput, +1) about 20 frames later. Byte +9 of gPartyMenu read 0 with the capture's frame on MARSHTOMP, 7
  after a Down with it on CANCEL, and 0 again after the next Down. Bytes +0..+3 read the routine 0x081B6255, +8 01, +0x0B 03.
- **A on MARSHTOMP** printed "MARSHTOMP's HP was restored by 20 point(s)." (ending FC 09) and returned to the battle, where the
  foe moved; HP read 46 of 51 in the battle and the party, and the bag 2 POTIONs after the battle.
- **Not measured**: a party of more than one (the other slots' cursor values and layout), CANCEL chosen, a POTION on a
  Pokémon at full HP, the other pockets in a battle, a Poké Ball thrown.

### A Mart: the buy list, the quantity box, and the list left active under it (2026-09-17)

**Vanilla ROM**, Slateport's Mart (9.13), walked in the story; autoplay's `observe`, `select` and `exec` reads with captures
of the same moments.

- `talk` to the clerk (local 1, across the counter) opened BUY / SELL / QUIT (the menu reader). BUY showed the list, read by the
  list reader: POKé BALL, GREAT BALL, POTION, SUPER POTION, ANTIDOTE, PARLYZ HEAL, ESCAPE ROPE, REPEL, HARBOR MAIL, CANCEL, the
  prices printed in window 1.
- A on POTION printed "POTION? Certainly. How many would you like?" and a task ran 0x080E0D89 (the build's
  Task_BuyHowManyDialogueHandleInput, +1): data word 1 read 1, then 2 and 3 after two Ups, the capture drawing "x03 ₽900"; word 5
  read 13 (POTION). A printed "POTION? And you wanted 3? That will be ₽900." and a YES/NO the menu reader read; YES printed "Here you
  go! Thank you very much.", the bag held 3 POTIONs and money read 7.
- **The list's task (the build's ListMenuDummyTask) stayed active** under the quantity box, the price question and "Here you go!":
  `select POTION` answered "did not respond" though its A had been taken, and `advance_text` stopped `menu_open` on the list at once.
- "Here you go!" waited on A after the driver was reloaded, and read as no message (a finished message is recovered only on the
  overworld's and the main menu's screens).
- **Not measured**: SELL, Right/Left in the quantity box (±10 in the decomp), a purchase refused for money.

### The live grid against the ROM's layout: a gym's barriers opened by its switches (2026-09-17)

**Vanilla ROM**, a snapshot in WATTSON's gym (10.0, the player at (5,3) after its four switches); a read-only
`exec` comparing each tile of the map's ROM layout (gMapGroups' header, +0 layout, +0x0C data) with the live grid
(gBackupMapLayout, +7 each way).

- **20 of the map's 210 tiles differ.** The barriers read collision set in the ROM and clear in the live grid: (4,7) `0628` against
  `0238`, (5,7) `0629`/`0239`, (1,11), (2,11), (4,14), (5,14) the same; the tiles above them change metatile with no collision
  change ((4,6) `0220`/`0230`); (6,9) `0648`/`021A` and (6,10) `0650`/`0251` go from collision set to clear; (6,8) `0640`/`0E42` and
  (3,11) `0643`/`0E43` change metatile and stay collision set. The four switches, (0,15), (3,9),
  (4,12) and (8,9), read `3205` in the ROM and `3206` live.
- **What it did to `goto`**: a trip from (5,3) to Mauville's Center (10.5) planned the gym's own floor from the ROM and
  answered "no way on foot known from 10.0 (5,3) to 10.5 (7,4)" at once. With the map the player stands on read from the live
  grid, the same trip from the same snapshot went, and `heal` answered `done`, MARSHTOMP 67 to 95 of 95 HP.
- **Not measured**: which other maps a script changes (Dewford's gym floor answered the same "no way on foot" on 2026-09-17,
  not looked at), and a map other than the current one whose tiles a script changed before the player left it.

### A mud slope on 0.26: onto it and slid back (2026-09-17)

**Vanilla ROM**, the game where attempt 2 of the autoplay acceptance was stopped (not a snapshot), on foot (walked), then the
tracked scenario `autoplay/games/emerald/scenarios/mud_slope.json`.

- **The tiles**: `observe`'s local map on 0.26 read behaviour 0xD0 at (17,36) and (17,37), straight above the player at
  (17,38); the screenshot showed a brown slope cut into the cliff there.
- **`walk up 1`** from (17,38) answered `done`, moved 2, overshot 1, and left the player on (17,38): onto the slope and
  slid back. Two unattended sessions' trips (to 0.13 and to 0.28) walked up it until stopped. The user: *"you need a mach
  bike to go up the mud slides"*.
- **`goto` closes 0xD0 on foot** since: from (17,38) to (17,35) it answers `unreachable` with no step taken, and without that
  check it was "still running after 7200 frames" (`games/emerald/scenarios/mud_slope.json`, 3 of 3 with it, 0 of 1 without).
  A trip from (17,38) to 0.28 (88,6) then went round and arrived, one trainer on the way.
- **Not measured**: moving down a slope, the MACH BIKE on one, and whether every 0xD0 tile is a slope.

### Map headers, events and behaviours read by an unattended session (2026-09-17)

**Vanilla ROM**, read-only `exec` reads by three headless sessions of the autoplay acceptance,
checked against the session's own play stream afterwards; each layout below is what its reads returned consistently.

- **The header** (gMapHeader's copy at 0x02037318, or a ROM header through gMapGroups): connections at +0x0C (a count,
  then a list of 12-byte entries: a direction byte, the offset at +4, group at +8, map at +9). Direction 3 was a west edge:
  0.27's east edge (39,8) led onto 0.26 at x 0, row 28, with 0.27 listed on 0.26 at direction 3, offset 20; the other
  directions are not measured. The warps they read on 0.26 and 0.27 matched `observe`'s.
- **Events** (header +4): object count at +0, warp count at +1, objects at +4 (24 bytes: local id +0, graphics +1, x +4,
  y +6), warps at +8 (8 bytes: x, y, destination warp id +5, map +6, group +7). On Lavaridge's gym 4.1, object 1 (graphics
  128) at (13,9) was the local 1 whose `talk` started LEADER FLANNERY's battle; 4.1's warp at (10,18) pointed at id 0, and
  4.2's warp 0 is (10,18).
- **The live grid** (0x03005DC0: width, height, a pointer; a u16 per tile, 7 tiles in): metatile id bits 0-9, collision
  10-11, elevation 12-15. A tile's behaviour is the low byte of its tileset's attribute table (layout +0x10 primary, +0x14
  secondary; tileset +0x10; ids from 512 secondary). On 24.14 its collision matched what `goto` and `walk` did.
- **Behaviours seen**: 0xD0 on 0.26 at (17,36), (17,37), (29,6) and (29,7) (A mud slope on 0.26, above); 0x3B drawn as
  collision on 4.1 and 4.2, crossed by `walk down` 4 from 4.2 (10,6) to (10,11); 0x68 on 4.1's warp tiles (8,9), (12,12),
  (10,6), (14,6), where a step dropped the player to the same tile on 4.2; 0x29 on 4.2's warp tiles (8,9), (12,12), (13,17),
  (10,18), where a step threw the player to 4.1, standing one tile right. Standing on one after arriving did nothing.
- **Not measured**: the other connection directions, whether 0x3B rows are one-way there, and why `observe`'s `nearby`
  left out characters beyond about 10 tiles.

### The field controls lock, and a script context left waiting after a ROCK SMASH escape (2026-09-23)

**Vanilla ROM**, autoplay `exec` reads through `mcpcall`, the game driven by autoplay tools; the address is the one
the byte-identical build's `.sym` names sLockFieldControls, its meaning what the reads below showed.

- **The rock.** 0.26 (18,102) facing the rock at (18,101): A, YES; one frame offset in six brought a wild GEODUDE
  (`advance_text` answered `battle_started`), the others `closed` with the rock smashed. `battle run_wild` from there
  chose RUN, read "Got away safely!", and the mode went back to overworld.
- **0x03000e38 (the script context status) stayed 1 after that escape**, 600 frames later and after the player had
  walked a tile up; the player walked freely (a screenshot, and `walk up` 1 answered `done`). Before the rock it read 2.
- **0x03000f2c read 1 while a script held the player**: at the rock's YES/NO and in the battle (both context 1),
  and **0 once the player walked**: after the escape (context 1) and before the rock (context 2). Three runs from one
  snapshot, the same each time.
- **What `battle` did with it**: waiting out "a script running" by the context alone, it ended `stuck` after the
  escape (1784 frames); gated on this byte too, it ended `ended` (1296 frames), 4 of 4 from the same snapshot. RICK's
  battle from `rick_battle_start` still ended `ended`, and the three Emerald scenarios passed 3 of 3.
- **MAY on Route 110** (the context had read 0-1 for 1044 frames after her first battle, above, "A new game to the first
  trainer battle"): from `story_before_may_route110`, 19 frames' wait, `walk up` 1, `advance_text`, `battle effective`
  won and read her words after ("...train a lot harder for the next time.") and answered `ended` in 10355 frames; the
  read straight after was context 2, lock 0, so `battle` had not ended before her script. Two earlier offsets whited out.

### A ledge hopped right, a RUN refused by ARENA TRAP, and a battler's ability (2026-09-23)

**Vanilla ROM**, autoplay tools and `exec` reads through `mcpcall`; the ability table's address is the one the
byte-identical build's `.sym` names gAbilityNames, the ability's offset the decomp's map, both confirmed by the names read.

- **Route 112 (0.27) from ROM tiles**: columns of behaviour 0x38 at x=10, 13, 15 and 17 (rows 43-53) between the
  Jagged Pass exit (6,46) and the rest of the route; `goto` found no way east while only 0x3B was a ledge.
- **0x38 is a ledge hopped moving right**: from (9,50) `walk right` 1 moved the player to (11,50); `walk left` 1 from
  there was refused, the tile (10,50) reading collision 1, elevation 0. 0x39 and 0x3A were not walked.
- **ARENA TRAP**: a wild TRAPINCH Lv 21 on 0.26 (15,45), the desert. RUN confirmed at the action menu printed "Wild
  TRAPINCH prevents escape with ARENA TRAP!" and the action menu came back (a screenshot). `battle run_wild` chose RUN
  until its 36000-frame limit; choosing FIGHT once a RUN was refused, it ended the battle in 1202 frames, 3 of 3
  (WATER GUN, super effective, TRAPINCH fainted). The GEODUDE escape still ended `ended`.
- **The ability**: byte +0x20 of a battler's 0x58-byte record; names 13 bytes apart from 0x0831b6db. Read: SWAMPERT
  67 TORRENT, TRAPINCH 71 ARENA TRAP, GEODUDE 69 ROCK HEAD; id 25 decoded WONDER GUARD.
- **WONDER GUARD** (the user: only super-effective moves damage it) was not met: with the TRAPINCH's byte written to
  25, `effectiveMove` scored ROCK SMASH, MUD SHOT and TAKE DOWN 0 and chose WATER GUN (x2). What the game does with it
  is not measured.

### The MACH BIKE from RYDEL, SELECT to mount, and the map's cycling bit (2026-09-23)

**Vanilla ROM**, autoplay tools and `exec` reads through `mcpcall`; the header offset is the decomp map's field, its bit
confirmed by the mounts below.

- **RYDEL**: Mauville 0.2's door to 10.1 (35,5); `talk` local 1, YES to "Did you come from far away?", then MACH or ACRO:
  MACH gave the MACH BIKE, id 259, in the KEY ITEMS pocket.
- **SELECT** with 259 registered (SaveBlock1 +0x496, the `register_item` cheat): in 10.1 it printed "DAD's advice… A,
  there's a time and place for everything!" and the player stayed on foot; on 0.2 (35,8) `observe` read `mach_bike` 60
  frames later; SELECT again got off.
- **The map header's byte +0x1A**: 0x0D on 0.2, 0.0, 0.16, 0.27; 0x0F in cave 24.14; 0x00 in 10.1, 10.5 and 4.1 (0x01 at
  +0x1B there). Bit 0 set where the bike went, clear where SELECT refused (10.1); the cave's bit not tried on the bike.
- **A trip riding**: `goto` run presses SELECT at rest when on foot, 259 registered and bit 0 set; Mauville (35,8) to
  Petalburg (15,9) done in 9 calls, four wild battles, `mach_bike` read between them.

### TM and HM compatibility, a double battle's menus and target, and a move's target byte (2026-09-23)

**Vanilla ROM**, autoplay tools and `exec` reads through `mcpcall`; addresses are the byte-identical build's `.sym`,
what each byte means as read below.

- **TM and HM compatibility**: 8 bytes a species at gTMHMLearnsets (0x0831e898), bit i for entry i of sTMHMMoves
  (0x08616040, 58 move ids). HM bits read: SWAMPERT SURF, STRENGTH, ROCK SMASH, WATERFALL, DIVE (SURF and ROCK SMASH
  it learned from the HMs); TAILLOW FLY.
- **A double battle**: TWINS GINA & MIA on 0.19 (28,16), with SWAMPERT and TAILLOW in the party. Type flags 0x0D;
  battlers at positions 0 SWAMPERT, 1 SEEDOT, 2 TAILLOW, 3 LOTAD. "What will TAILLOW do?" came with
  gBattlerControllerFuncs[2] on the action and move routines while [0] was not; the action and move cursors are one
  byte a battler (gActionSelectionCursor, gMoveSelectionCursor + battler).
- **The target step**: after a single-target move the move menu stayed drawn and battler 0's routine read
  HandleInputChooseTarget (0x08057824); gMultiUsePlayerCursor (0x03005d74) read the aimed battler, 1 first. Right went
  1 to 0 (the player's own SWAMPERT), Down 0 to 3, Left 3 to 0, Up 0 to 1. A confirmed it.
- **A move's target byte** (+6 of its 12-byte entry): 0 for ROCK SMASH, MUD SHOT, TAKE DOWN, PECK, ASTONISH; 8 for
  SURF and GROWL (GROWL lowered both SWAMPERT's and TAILLOW's ATTACK when LOTAD used it); 16 for BIDE, HARDEN, FOCUS
  ENERGY; 32 for EARTHQUAKE, SELFDESTRUCT, EXPLOSION and MAGNITUDE (the user: these hit the partner too).
- **`battle effective`** in it, after the fixes: each battler's own moves, aimed at a foe standing (target 1, then 3),
  both foes fainted, `ended`.

### SURF: the question, the avatar byte, and stepping off onto land (2026-09-23)

**Vanilla ROM**, autoplay tools and `exec` reads through `mcpcall`.

- **The question**: on 0.33 (17,10), on the MACH BIKE, facing right onto (18,10) (behaviour 0x15, elevation 1), A printed
  "The water is dyed a deep blue… Would you like to SURF?" with YES/NO; YES, "SWAMPERT used SURF!", and the player stood
  on (18,10). The same from (31,10) facing left, on foot.
- **The avatar byte** (gPlayerAvatar +0): 0x08 on the water, 0x01 on foot, 0x02 on the MACH BIKE.
- **Off the water**: `walk right` 13 from (18,10) crossed 0.33's river and stopped on (31,10), elevation 3 land, on foot;
  a water level of 1 onto land of 3 was taken.
- **Elevation-1 behaviours by map** (ROM tiles): 0.33 all 0x15; 0.25 0x15, 0x70, 0x0C and 0x00; 0.19 0x15, 0x10, 0x0C and
  0x00; Dewford's gym 3.3 0x00 only. Only 0x15 was surfed.
- **A trip across**: from (17,10) to (33,10), `goto` answered `obstacle` at the bank, `clear_obstacle` the question, YES,
  `goto` done: 5 calls.

### Long grass (0x03) refuses the MACH BIKE (2026-09-23)

**Vanilla ROM**, autoplay tools and `exec` reads through `mcpcall`.

- 0.34 (Route 119) read 765 tiles of behaviour 0x03 among its 40 by 140 (ROM tiles); rows 128-131 of its south end.
- Standing on (16,130) (behaviour 0x03), SELECT with the MACH BIKE registered printed "DAD's advice… A, …" and the
  player stayed on foot (a screenshot); the avatar byte read 0x21 there, 0x01 on plain ground.
- `goto` with `run` onto 0.34 went on foot (movement `on_foot` after it), the map holding 0x03.

### The repel step counter, the FLY map's place name, and rotating gate bytes (2026-09-23)

**Vanilla ROM**, autoplay tools and `exec` reads through `mcpcall`; addresses from the byte-identical build's `.sym` and
the decomp's var list (VAR_REPEL_STEP_COUNT 0x4021, vars at SaveBlock1 +0x139C), meanings as read below.

- **Repel**: the u16 at SaveBlock1 +0x13DE read 0, then 250 after a MAX REPEL was used from the field BAG in Lilycove's
  store 13.17 (the bag's MAX REPEL count 8 to 7).
- **FLY**: [0x0203a148] held 0x02000010 with the FLY map up; +8 read 213 with a blank name off land, 31 with "ROUTE 1??",
  5 with "VERDANTURF TOWN"; +12 is the place name as game text. With LAVARIDGE TOWN and LILYCOVE CITY named there, A flew
  the player outside that town's Center (0.12 (9,7), 0.5 (24,15)).
- **Rotating gates** (WINONA's gym 12.1): the eight bytes at SaveBlock1 +0x139C (VAR_TEMP_0 on) read 1,2,1,1,0,0,0,2 at the
  door, the decomp's starting table; each changed by one as the player pushed through its gate (a read-only recorder of
  tile and bytes, the user walking), and the recorded moves replayed from the door reached (15,3) with 2,3,2,1,0,3,1,3.

### The FLY map's cursor, the party screen's cursors, and Mossdeep's rotating statues (2026-09-23)

**Vanilla ROM**, autoplay tools and `exec` reads through `mcpcall`; the rotating puzzle's routine from the decomp as the map
(which colour moves on a switch, arrows one step), what moved read below.

- **FLY map cursor**: with the map up from MOSSDEEP CITY 0.6, the u16s at [0x0203a148] +0x5C and +0x5E read 25 and 7 on
  "MOSSDEEP CITY"; Right made 26,7 (+8 from 0x0d to the same, still MOSSDEEP CITY) and Down 26,8 ("ROUTE 125", +8 0x2a).
  A walk of the cursor over every cell (the driver's `fly_scan`) moved it only over columns 1-28 and rows 2-16; each
  town's first cell read so is the table in `autoplay/drivers/bizhawk/games/emerald.lua` (FLY_SPOTS). `fly` to LILYCOVE
  CITY by it landed on 0.5 (24,15) in 501 frames, and back to MOSSDEEP CITY on 0.6 (28,17) in 517.
- **Party screen cursors** (the START menu's POKéMON): the s8 at 0x0203cec8 +9 read 0 on opening and followed Down;
  after SWITCH the cursor that moved was +10 (Down from slot 0: 0, then 1, while +9 stayed 0), CANCEL 7. A held Down
  through `select` ran past the Pokémon there, and on the summary's forget-a-move list a held Down was not taken; taps
  12 frames apart were taken on both.
- **The bag's TMs & HMs list** printed each entry as formatting codes, the number and the move ("{F9}Ë34{FC}ÙÊSHOCK WAVE"),
  in the bag's own order (TM08 ... HM06), so it is chosen by place. A pocket just turned to took no Up for 30 frames.
- **Mossdeep's gym 14.0, the statues**: the metatile ids on the gym floor read 0x250 upward in rows of 8 per colour
  (yellow, blue, green, purple, red; the first four of a row arrows right, down, left, up, the fifth the switch).
  Stepping onto the blue switch (8,10) moved the four characters on blue arrows one tile each: 6 (7,8) to (6,8), 15
  (6,8) to (6,9), 16 (9,9) to (10,9), 17 (10,9) to (10,8); a later press, and every red, green and yellow press after,
  moved its colour's characters along the same loops as predicted from the arrows (13 presses in all). The characters
  are the gym's trainers and statues; the switches are step-on events (none reads in the tile's behaviour byte).
- **A warp pad** (behaviour 0x0e) landed on the same map: (3,28) on (1,23), (8,12) on (7,18), (11,3) on (11,35), (13,32)
  on (21,10), (1,33) on (20,24), matching the map's warp table.

### Boulders and STRENGTH, hide flags, currents, waterfalls, cracked floors on the MACH BIKE, and DIVE (2026-09-24)

**Vanilla ROM**, autoplay tools and `exec` reads through `mcpcall`, from states the route run saved on the way; used by
the obstacle planner (`autoplay/drivers/bizhawk/route.lua`, OBSTACLES, and the Emerald module's THE ROOM).

- **STRENGTH**: on 24.35 (5,8) facing the boulder at (5,7), A printed "It's a big boulder, but a POKéMON may be able to
  push it aside. / Would you like to use STRENGTH?"; YES, "SWAMPERT used STRENGTH! … made it possible to move boulders
  around!". Of SaveBlock1's flag bytes (+0x1270, 0x130 bytes) only flag 0x889 changed, 0 to 1.
- **A push**: Up held 8 frames from (5,8) moved the boulder (graphics 87, local 2) from (5,7) to (5,6), read on the
  press's last frame; the player stayed on (5,8). 24.35 holds 12 boulders (templates 1-12), four of them beyond
  `observe`'s radius. The planner's trips crossed 24.35 (9 pushes), 24.28 and Victory Road B1F (24.44), pushing as
  planned.
- **Hide flags**: a template's u16 at +0x14 is its flag. On 24.43 the two templates with a flag set (0x35A, 0x2EF, both
  graphics 135) were the only ones with no live character; the boulders' and rocks' flags on 24.35, 24.28 and 24.44 are
  0x11-0x1F, all clear, and a room left and entered again has its boulders back (route.md, 24.28). SaveBlock1 +0xC70 holds
  a copy of the room's templates (24.35's twelve in order) that kept the pushed boulder at (5,7).
- **Currents and waterfalls** (ROM tiles): 24.33's currents read collision 0, elevation 1, behaviours 0x50-0x53 (108
  tiles); Ever Grande 0.8 rows 60-67 and Victory Road B2F 24.45 read waterfalls as 0x13, collision 0, elevation 1.
  Surfed by the planner: 24.33's slides, B2F's east fall climbed with WATERFALL and its west fall come down.
- **Cracked floor on the MACH BIKE** (24.82 (11,2), the second visit, `ride`'s per-tile speed byte, avatar +0x0B as each
  step began): held from rest down column 11 the steps read 0, 1, 3, 3…; the cracks (0xD2) at rows 5-7 entered at 3 held;
  let go on row 10, the bike coasted rows 11 and 12 reading 2 and 1, the crack at 11 held and the one at 12 dropped the
  player onto 24.81 (11,12). Let go on row 7 instead: rows 8, 9 and 10 read 2, 1, 0 and it stopped on 10; the crossed
  cracks then read behaviour 0x66, and walking onto (11,7) dropped the player onto 24.81 (11,7). On foot, a step onto
  (11,5) from (11,4) landed on 24.81 (11,5). No connection in 24.82's header names 24.81.
- **A ride stopped on a crack** (24.82 (6,4)): the bike stood there past `ride`'s 30 still frames before the player
  dropped onto 24.81 (6,4); after the map load the overworld was back with the field controls lock (0x03000f2c) at 1 and
  the script context off for about 50 frames, and a held direction was not taken until it cleared.
- **DIVE**: surfing on 0.43 (38,27), deep water 0x12, A printed "The sea is deep here. Would you
  like to use DIVE?"; YES, "MARILL used DIVE.", and the player stood on 0.53 (38,27), the avatar byte 0x30. There B printed
  "Light is filtering down from above. Would you like to use DIVE?"; YES: 0.43 (38,27), the avatar byte 0x28. 0.43's
  header lists 0.53 as a connection of kind 5 and 0.53 lists 0.43 as kind 6; 0.53 reads open (collision 0, level 3)
  where 0.43 is deep water. The underwater cave 24.26 has no connection: surfacing from (6,5) there ended on 24.27 (10,17)
  (the route run's state with "MARILL used DIVE." up, its text read on).

### Which badge each field move needs, from the party menu (2026-09-24)

**Vanilla ROM.** Made situation: the route run's `r5_evergrande` (0.8, surfing, eight badges; the party knowing FLY,
SURF, STRENGTH, ROCK SMASH, DIVE and WATERFALL, none knowing CUT or FLASH). For each of those six moves and each badge
flag 0x867-0x86E: restored, that one flag cleared with `set_flag`, the move chosen through the autoplay `field_move`
errand (START, POKéMON, the first Pokémon knowing it, A, the move), and the lines the screen showed read back. 48 trials.
"This can't be used until a new BADGE is obtained." came in exactly one per move: **FLY with 0x86C (badge 6) cleared,
SURF 0x86B (5), STRENGTH 0x86A (4), ROCK SMASH 0x869 (3), DIVE 0x86D (7), WATERFALL 0x86E (8)**. With any other flag
cleared each move gave its own answer: FLY's map ("FLY to where?"), "You're already SURFING.", or "Can't use that here."
With all eight set FLY's map came up (the control). CUT and FLASH are not measured (no Pokémon knew them); neither is
the overworld's own check (facing water, a rock, a waterfall with a badge missing), which the planner's actions go
through.

### 2026-10-02 — Facts the code comments carried, moved here word for word

Each fact below sat in a code comment beside the code that uses it (at `f64560cc`), and no entry above held it. On 2026-10-02 the comments were cut to what and why and the facts moved here word for word. Each names the probe, capture or date it was measured with where the comment did; none was re-measured for this entry. The label above each group is the file it came from, then the entry it was checked against.

**`autoplay/drivers/bizhawk/games/emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "A trainer's sight and defeat flag, a trainer coming for the player, and the level-up box (2026-09-17)"; adapters/emulator/pokemon/emerald/MEASURED.md, "The learn-a-move question, the move list and the evolution scene (2026-09-17)"; adapters/emulator/pokemon/emerald/MEASURED.md, "TM and HM compatibility, a double battle's menus and target, and a move's target byte (2026-09-23)"; adapters/emulator/pokemon/emerald/MEASURED.md, "The field controls lock, and a script context left waiting after a ROCK SMASH escape (2026-09-23)"; adapters/emulator/pokemon/emerald/MEASURED.md, "Boulders and STRENGTH, hide flags, currents, waterfalls, cracked floors on the MACH BIKE, and DIVE (2026-09-24)"; adapters/emulator/pokemon/emerald/MEASURED.md, "SURF: the question, the avatar byte, and stepping off onto land (2026-09-23)"; adapters/emulator/pokemon/emerald/MEASURED.md, "A move's type, power, accuracy, PP and effect text (2026-09-16)"; adapters/emulator/pokemon/emerald/MEASURED.md, "Not measured yet: The rest of a battle (from 2026-09-16)"

- 2026-09-23 (Weather Institute 2F, Routes 118 and 120): +0x06 9 read left only over 4500 frames (+0x18 3, the grunt at 19,6), 0x0A right (the grunt at 15,6), 0x0D down and up (the grunt at 10,8, crossed while it faced up), 0x0E left and right (120's at 5,22), 0x10 up and right (118's at 56,7), 0x11 left and down (121's at 22,5, 12 reads), 0x17 all four (120's rotator at 16,6), 0x18 the same clockwise (129's at 35,9 read down, right, up in 10 reads). So +0x18's 3 is left too (`turnFacing`). A walking trainer (0x1A, 121's at 11,6, on rows 7-10) moves its line and is not timed: crossed above it while it walked down, away (by hand).
- A trainer that walks (2026-09-23/24: 121's at 11,6 lapped rows 7-10; 108's at 52,13 x49-52 rows 10-13; the Aqua Hideout 1F's at 20,4 x7-20 rows 4-9) stays inside a box round its template tile: the template's +0x0A, low nibble the x range and high nibble the y range (read 0x55, 0x05, 0x31 on 128 for a loop, a left-right and up-down walkers, matching those laps). Its sight is taken from every tile of that box, every way: never timed, just avoided. Wandering (0x02-0x06), walking back and forth (0x19-0x1C) and walk sequences (0x1D-0x34) walk.
- "Will A change POKéMON?" before a trainer's next Pokémon (2026-09-23, GUITARIST DALTON on 0.33, the first time the party held two): not read, a nudge's A answered YES and opened the party screen. Read by its message, its YES/NO cursor taken to be the nickname question's: MAY's battle in Lilycove read it before GROVYLE, SLUGMA and PELIPPER ("PKMN TRAINER MAY is about to use GROVYLE."), and `select` YES and NO each did what they say (2026-09-23).
- A ROCK SMASH rock (graphics 86: the two on 0.26 at (18,101) and (19,100) that A, YES broke, 2026-09-17 and 09-23) is an obstacle, not a wall, while the party knows ROCK SMASH: the walk stops in front of it and `smash` breaks it.
- A damaging move whose accuracy byte reads 0 never misses (SHOCK WAVE, "never misses" on its summary, scored 0 and SPARK was chosen over it, 2026-09-23): taken as 100.
- RECOIL (the user, 2026-09-23: TAKE DOWN hurts the user; SWAMPERT ended WINONA's battle on 1 HP): the effect byte read 48 for TAKE DOWN and SUBMISSION, 198 for DOUBLE-EDGE, 0 for plain damage. Below 40% HP such a move scores a quarter.
- The user faints itself (2026-09-23: SELFDESTRUCT scored 200 power, ELECTRODE used it on ARCHIE's CROBAT and fainted): the effect byte read 7 for SELFDESTRUCT and EXPLOSION through `exec`. Scored 0, a last resort.
- x and/or y: also where it stands, for a trainer that walks a loop (Aqua Hideout 1F's grunt lapped x7-20, rows 4-9, in about 600 frames; a poll from outside read him 250 frames apart).

**`autoplay/drivers/bizhawk/route.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Turning at speed, routes, a Pokémon Center, and battles as one call (2026-09-16)"

- goto {x, y, run, cross_grass}: to a tile on this map by a planned route of straight legs, holding each leg's direction and switching to the next as the step into the corner begins -- a held direction turns on arrival, and the Mach Bike kept its speed through a turn (Emerald, bike_probe.lua, 2026-09-16: the first tile after the corner read +0x0B 3). A ride that coasts once let go lets go on the last leg by the module's `coast`, and a last leg of `shortLeg` tiles or fewer is reached by stopping at its corner first (after a turn at speed the Mach Bike's first tile coasted three). It stops for the same reasons `walk` does (the module's `watch`), and a warp or an edge that changes the map ends it too. Returns (program, error, frame limit) like any program.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Index" (no entry covers a ROM variant or its address shifts; VERIFIED.md's "2026-09-11 — SPEEDCHOICE 1.2.2 ran for the first time", PROBES.md's "Porting to an unmeasured build" and phases/phase8.md's SPEEDCHOICE offsets table hold the shifts and the method, not these readings)

- SPEEDCHOICE 1.2.2 (cartridge game code "SPDC"), measured 2026-09-11 and corroborated twice. `probes/romvariant_probe.lua` resolved gObjectEvents to six AMBIGUOUS candidates and refused to pick, which was right; `probes/objevents_pick_probe.lua` then decided between them with a fact that probe did not have -- on this build gSaveBlock1Ptr WORKS, so the player's true tile is known, and exactly one candidate (0x020373F4) held it at slot 0 with real NPC tiles in slots 1..3. The other five were solid zeros. 0x020373F4 - 0x02037350 = 0xA4, and the same search independently put gPlayerAvatar at 0x02037634, which is 0xA4 past its vanilla address too: two structures, one shift. The ROM side moves by a different amount, and that is also measured twice: romvariant_probe RESOLVED gObjectEventGraphicsInfoPointers at 0x0850BA28 (+0x6408, 95 of 96 entries validating as ObjectEventGraphicsInfo), and 0x0849EC00 -- the Brendan palette at +0x6408 -- was among the palette candidates its byte-signature search turned up. **WRITTEN AS LITERALS AT THEIR USE SITES, NOT AS LOCALS**: this file is at Lua's hard ceiling of 200 locals per main function and three more tipped it into a PARSE failure ("too many local variables"), the same trap Crystal hit the same day.
- **WHEN gMain ITSELF HAS MOVED, THIS TEST CANNOT BE ASKED (2026-09-11).** Every entry point below is a code address, so a plausible reading is always in ROM. EX SPEEDCHOICE 0.4.0 reads E0999086 here -- not a pointer at all, because its IWRAM is relocated and gMain is not where this looks. Comparing garbage against three known constants can only ever answer "no", and the adapter would then never send or render on that build. The fallback is a different question with the same answer: does the PLAYER'S OBJECT EVENT exist and hold a plausible tile? The object event system only runs in the field, so a live player entry is itself evidence of being in the overworld -- weaker than reading the callback (it cannot tell a paused field state from a running one), and used only where the stronger test is unavailable. Through a GLOBAL, and deliberately: `playerObjEventExistsAt` and `avatarAddrOffset` are file-scope locals declared ~250 lines BELOW this function, so naming them here would compile to nil globals and throw on the first frame -- the forward-reference trap this file documents, which bit six times on 2026-09-11 alone. The global is assigned at load time, at the definition site, so by the time any frame runs it is there.
- Archipelago's recompile relocates this whole sprite/palette data block -- confirmed 2026-08-14 by directly comparing ROM file bytes (not a runtime read) between the vanilla ROM and two independent Archipelago-patched-ROM files: the exact 256-byte raw tile block at each vanilla *_PIC_*_ADDR above, and the exact 32-byte raw palette block at each *_PAL_*_ADDR above, were each found at exactly ONE new location in both patched ROMs (identical between the two, i.e. seed-independent, consistent with Archipelago's Emerald patch being one static base recompile shared by every seed -- see agent_docs/risks.md's Archipelago-coexistence entry). All six addresses shifted by the exact same delta: +0x7530. This is a genuinely different address family from CB2_Overworld's own Archipelago shift (which moved by a different amount, 0x995, in ROM code rather than ROM data) -- no single ROM-wide offset applies to everything, only to this contiguous graphics block. Detected once at startup below (a live byte comparison, not assumed) rather than hardcoded as "the" address, since a future Archipelago Emerald world/generator version could recompile to a different offset -- the same portability caveat as every other address in this project.
- Detect once at startup whether the vanilla or Archipelago-shifted sprite/palette addresses are actually live, by comparing Brendan's palette's first 4 raw bytes (0x0E 0x53 0x5F 0x5B, read directly from the vanilla ROM file 2026-08-14) against both candidate locations -- a live verification, not an assumption, same discipline as vram_probe.lua's VRAM<->System-Bus aliasing check. Falls back to vanilla (with a loud warning) if neither matches, e.g. a future Archipelago Emerald world/generator version that recompiles to a third, unknown offset.
- EX SPEEDCHOICE 0.4.0: +0x1E6DBC, from romvariant_probe RESOLVING the graphics table at 0x086EC3DC with 95 of 96 entries validating as ObjectEventGraphicsInfo. Note this build is a 32MB cartridge and that scan only found it because the probe now MEASURES the ROM bound by half-mirror comparison -- its old 16MB fallback was exactly half of this ROM, so the table sat in the half it never looked at. **EX SPEEDCHOICE MOVES ITS SPRITE DATA AND ITS GRAPHICS TABLE BY DIFFERENT AMOUNTS**, which is why this build needs two offsets where every other one needs a single shift. Sprite data (pic + palette) is +0x9CB78; the graphics-info table is +0x1E6DBC. Assuming one shift for both is what made the first attempt report "sprite data not found" while the table had already been RESOLVED at 95/96 entries. Measured offline against the ROM files rather than in the emulator, because it is a question about cartridge bytes: vanilla's 32-byte Brendan palette appears three times in this ROM, and vanilla's first 256-byte sprite frame appears exactly ONCE -- at 0x08534170, with one of those three palettes sitting 0x1200 past it, which is the same gap the two have in vanilla. One pair, two independent signatures, no judgement call.
- EX SPEEDCHOICE 0.4.0 ("SPDX"), +0xC80. Measured by `probes/objevents_walk_probe.lua`, which had to exist because the trick that decided SPEEDCHOICE does not work here: that one compares each candidate against the SAVE BLOCK's tile, and on this build the whole of IWRAM moved -- 0x03005D8C reads FDFDFFFF and gMain.callback2 reads E0999086, neither a pointer. So the candidate was picked by WALKING instead: of six survivors from romvariant_probe's structural search, exactly one tracked the player for all 16 steps (four out and four back on each axis). romvariant_probe independently put gPlayerAvatar at 0x02038210, which is +0xC80 from its vanilla address too.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "A direction held across tiles, walking and running (2026-09-16)" (step timing only; UNVERIFIED.md's per-site audit entry records DIRECTION_ANIM and both duration tables as measured, not the one-frame lag)

- Per-pose hold durations (frames), indexed the same as DIRECTION_ANIM's steps array: uniform for walking, uneven for running. MEASURED 2026-09-16 (same run): each drawn walking pose held 8 frames and running poses 5, 3, 5, 3, in all four directions; the drawn image changes one frame after the animation command index does.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Ledges, water, and other maps read from the ROM (2026-09-17)"

- Measured: 16 (pond water) and 21 (ocean water, NOT in the set -- a peer surfing at sea gets no reflection).

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Map headers, events and behaviours read by an unattended session (2026-09-17)"

- `probes/occlusion_probe.lua` diffed both builds and that is exactly where they part company: AP      layout=03FF03FF  tilesets 00000000 / 00000000 vanilla layout=083EA284  tilesets 083DF704 / 083DF71C

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "SURF: the question, the avatar byte, and stepping off onto land (2026-09-23)"

- Measured for south only: probes/surfblob_probe.lua watched the game's own blob report anim 0 / image 0 while the player faced south, 2026-08-19. […] the palette slot is read off the game's own blob (measured 0, the same probe).

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "The truck's door taken from rest, the wall clock's screen, and a question drawn instantly (2026-09-17)"

- A door animation is ~20 frames and every real pair is separated by frames with no door task at all -- the walk up into the doorway, or a whole visit to the house -- so "the peer says there is no door right now" is the end of an event,

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "A new screen's windows (2026-09-16)" (no entry covers the HM banner's show-mon task; VERIFIED.md, "Emerald: the drawn copy no longer vanishes through the HM splash", holds only the window read from the task's data, and agent_docs/pitfalls/by-lesson.md holds the banner flicker rule, not the ~2 seconds)

- AND KEEP IGNORING THE TILEMAP FOR A FEW FRAMES. The banner's rows stay WRITTEN after its task is gone -- the game clears them in its own restore step -- so trusting the tilemap again immediately re-clips everything, which is why the blank survived as a single frame per cycle after the first attempt at this. Eight frames covers the restore twice over. Nothing else can legitimately draw a panel in that window: a text box needs a script, and the surf sequence runs none.
- ROWS 0-4 ON THE LEFT NEED A STREAK, not a time window. The only thing the game puts there is the map-name banner. A REAL banner is rock-stable in the tilemap for ~2 seconds; the mid-ride redraw flicker that was eating a trailing ghost's hat alternates within a few scans and never holds five in a row. A first attempt gated these rows to a window after a map change instead -- wrong, because riding away from a fresh crossing is exactly when the user tests, so the window re-admitted the flicker for their whole ride. The START menu also reaches these rows but on the RIGHT half; spans starting past midscreen are untouched.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Index" (no entry covers Fly; the Fly questions are in UNVERIFIED.md, "the engine states inside a Fly departure", and the warp gap appears in BANDAGES.md only as the 480-frame timeout, not its ~25-frame length)

- FLY OVER THE WIRE ENDED. Two very different reasons produce the same nil, and the latch is what tells them apart:
  - the last phase was 2 -- the peer was CARRIED AWAY and is now mid-warp, behind its own fade, with the fly-out task destroyed and the fly-in task not yet created. On a same-town fly this gap is ~25 frames, and rebuilding here put a standing ghost on the takeoff tile between the two halves of the flight -- a pop the player being watched never shows, because their screen is black. So the ghost stays hidden and NOTHING is rebuilt until the arrival's own fly frames arrive (a fresh flight: the latch clears below), a different area tears the ghost down, or a timeout says it is not coming.
  - the last phase was 1 -- the peer was SET DOWN. The engine releases its character partway down the arrival arc and finishes with its own drop table, so a landed peer's last word is always phase 1, and a departed one's is always phase 2. That is the whole discriminator, and it has to be the phase rather than the done-latch: the arrival runs an arc of its own, so it ends latched too, and testing the latch hid every peer that had just landed for the full timeout -- the user, watching arrivals, *"they appear for a bit, go invisible, and then appear again"*.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Index" (no entry covers sprite tiles or OBJ VRAM; VERIFIED.md's fishing entries and pitfalls/by-lesson.md checked: neither holds the probes/tilewatch reading)

- LOAD THE FIRST FRAME OURSELVES, so a new graphic is never worn over the old graphic's pixels. Measured, per frame, across a rod being cast (probes/tilewatch, 2026-08-19): f=11  ghost gfx=0    tile=44  pixels=250A6BD5   -- walker f=12  ghost gfx=137  tile=44  pixels=250A6BD5   -- fishing SHAPE, walker PIXELS f=13  ghost gfx=137  tile=44  pixels=AD0B1438   -- fishing pixels arrive The engine's own tile copy is queued and executes at the next VBlank, so there is always exactly one frame where the sprite has the new graphic's 32-wide shape and the previous graphic's content. That single frame is the snap: the user, with the painted copy beside it as the control, *"it still snaps compared to the drawn & player"* -- and the painted copy cannot show it, because it decodes from ROM every frame and has no VRAM waiting to be filled. So the pixels are written at the moment the graphic is applied -- the same bytes the engine will copy a frame later, from the same place: images[frame] resolved through the graphic's own animation table. Nothing here races the engine; it simply gets there first. A GLOBAL because this chunk is at Lua's 200-local ceiling.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "What the driver and its hooks cost (2026-09-16)" (it prices the autoplay driver, not this adapter's frame copy)

- A frame copy is info.size/4 read+write pairs -- 128 of each for a 32x32 graphic. Cheap once and ruinous per frame, so it must stay on a CHANGE and never become per-frame work. Measured 2026-08-20 in ordinary play: 1 per 300 frames.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Index" (no entry covers hardware OAM against the sprite struct; VERIFIED.md's surf-start and orange-sprite entries record other causes)

- THE OLD RANGE IS FREED LATER, NOT NOW -- the hardware is still drawing from it. Measured 2026-08-21, hardware OAM dumped per frame across a graphic swap: for TWO frames after this function runs, the entries at 0x07000000 still carry the OLD tile number (the OAM the PPU shows lags the sprite struct by the buffer-build/VBlank-copy pipeline). Freed immediately, those two frames draw whatever the engine loads into the reclaimed range next -- harmless most of the time, and exactly wrong during the start of surfing, where the show-mon effect is loading a full Pokemon picture into OBJ VRAM that instant: the ghost renders scrambled pieces of the incoming picture for a frame. Whether the allocator lands there varies run to run, which is why the user saw it "every 2-3 savestate reloads". Queued with the ghost that owns it, and the service point frees only while that ghost is still ITSELF alive (identity, not slot state) -- a world rebuild between queue and free means the engine reset the bitmap and the bits are not ours to touch, the same rule every other free in this file follows.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "The map around the player, and one walked step (2026-09-16)" (it records +0x1C while walking, not that a settled object keeps its last action id)

- ...EXCEPT WHEN NOTHING IS DRIVING IT. "The engine animates the walking graphic" holds only while one of our movement actions is running. A ghost standing still on foot has none, and the last thing to touch its animation may have been a different graphic entirely -- so it keeps whatever frame it was left on. Measured at the last commit, standing: the ghost held exactly the ROM frame for index 0 while the player stood on index 1. "Nothing is running" is the held-movement bit, NOT the action id: movementActionId keeps the last action's number long after it finished, so a settled ghost reads 0x00 and never NONE.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "The map around the player, and one walked step (2026-09-16)" (it records the step's bytes, not who owns pos2 during it)

- The graphic swap waits for the step to END, below this guard rather than above it. A peer's state arrives while the ghost may still be mid-stride: its walk is engine-driven and takes 16 frames from when we asked for it, so a rod that arrives partway through lands on a WALKING ghost. The player can never do that -- you cannot start fishing mid-step -- and it has a mechanical consequence too: the engine owns pos2 for the duration of a step, so the peer's own sprite offset is overwritten every frame until the step finishes. Measured with a probe loaded before the adapter: three frames of the fishing graphic at pos2 0,0, drawn 8px left, ending exactly when the step did. Waiting costs at most one step. It buys a ghost that stops, then fishes, like the player.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "SURF: the question, the avatar byte, and stepping off onto land (2026-09-23)", "The two bikes: getting on, speed, and stopping on a tile (2026-09-16)", "Not measured yet" (all five); also UNVERIFIED.md "[OPEN] the surf blob's other data slots" and "[OPEN] the OAM layout pass"

- A GHOST THAT OWES A TILE ON A BIKE MUST RIDE IT, NOT WALK IT. `acroBase` is taken from the peer's CURRENT action, and a ghost is usually a step behind: by the time it covers the tile, the peer has moved on to ending the wheelie or to standing, so there is no acro action left to copy and the ghost falls through to a plain WALK. Measured on one tile of wheelie ride: the player rode it with action 0x84 and the ghost walked it with 0x08 -- a walk step is also twice as long as a ride step, so the ride animation ran across the whole of it. The user: the spawned ghost is *"doing the while cosntantly riding animation instead of just the small wiggle"*. Remembering the last acro family the peer actually used, and reusing it for as long as the peer is on a bike, means the ghost performs the game's own riding action for the tiles it owes -- the same shape as the drawn tier remembering the peer's last moving animation number, and for exactly the same reason.
- DEFERRED, like the spawned tier's swap frees, for the same measured reason: the hardware OAM shows the old tile number for ~2 more frames after a release, so an immediate free lets the next allocation write into tiles still on screen -- the user's *"oam & its reflection is glitching when going back to land"*, where the dismount's graphic change is exactly a release-and-reacquire. Entries are stamped with the tier's area; the service point frees them only while that area still stands, the same forget-don't-free rule as everywhere else.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "The two bikes: getting on, speed, and stopping on a tile (2026-09-16)"; adapters/emulator/pokemon/emerald/MEASURED.md, "A direction held across tiles, walking and running (2026-09-16)"; adapters/emulator/pokemon/emerald/MEASURED.md, "Not measured yet: The rest of the map and the walk (from 2026-09-16)"; also documentation.md, "A step is a fixed table, one entry a frame" and "The walk animation swaps twice per tile" (the walker only); VERIFIED.md 2026-08-20 bike entries (animation 4 against 8, a whole pedal cycle per tile) and pitfalls/by-lesson.md "one tile of bike travel cost the ghost a whole pedal cycle", none of which names the four-pose ride cycle, the index a tile starts at, or the Acro and walker moving numbers

- FROM THE START OF THIS STEP, not from an absolute distance. The rate was right first time -- half a tile per pose, two poses per tile, which is what the player does -- but the PHASE was whatever the running total happened to land on. A ride animation is four poses alternating a neutral frame with two different pedal frames, so a tile beginning on an odd index shows two pedal frames back to back: *"the drawn ghost wiggle twice for a single tile, its only supposed to do it once"*. Measured on the player, one tile is index 0 then 1 -- it always starts from the beginning of the cycle, so the ghost must too.
- The moving animation NUMBER cannot be hardcoded, though: it is 8..11 on the Acro Bike against 4..7 for a walker, and every graphic may differ.

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Measured" (an adapter cost or timing no entry held)

- The SAME pacing, applied to a DRAWN peer. A spawned ghost never needed this: the engine walks it tile to tile at exactly these durations, which is most of why it looks right. A drawn one had nobody doing that, so it was painted wherever the newest sample said -- and the user, seeing both renderers side by side for the first time (MESHGHOST_COMPARE_TIERS, 2026-08-19), described precisely what that does: *"really stuttery/choppy"*, and *"moving/catching up with the player too fast"* next to a spawned ghost that "properly follows". Both are one bug. Samples arrive at the relay's rate, not the game's, so a renderer that follows them literally moves at the NETWORK's pace, in jumps of whatever distance arrived. So a drawn peer now glides between TILES over the same 16/8 frames the game gives a step, from per-peer state kept on the peer's own table (no new chunk locals -- this file is at 196 of Lua's 200). A jump longer than one tile is a warp, a respawn or first sight, and snaps. SMOOTH WITH A FILTER, WHICH HAS NO CLOCK OF ITS OWN. Seven attempts at moving a drawn ghost, and the measurements finally separate the two questions that were tangled together the whole time: * WHY it looked wrong. Every model before this one had its own timing -- a step duration, a speed, a state machine -- running against a world that scrolls on the game's clock. Two clocks beat, and the beat was the chop. That diagnosis was right and is why nothing here schedules anything any more. * Why "just draw the peer where it is" was ALSO wrong. Measured (probes/tier_compare.log): a peer's position changes in 549 frames out of 4140 -- one frame in eight -- in jumps of 2 to 4 pixels. The core interpolates (`-interp`, 100ms by default) but it DELIVERS at the relay's rate, around 8-20 a second, while this tier redraws at 60. Between deliveries the position is a constant, so drawing it faithfully draws a staircase. The engine hides the same staircase for a spawned ghost by walking it a tile at a time. So the adapter does have to smooth -- it just must not schedule. An exponential filter is the shape that fits: it has a lag and nothing else. No step duration to disagree with the game's, no phase to drift, no state machine to be out of sync with the world's scroll. Whatever rate positions arrive at, and however uneven, it turns them into continuous motion, and it cannot beat against anything because there is no periodicity in it to beat with. THE TRAILING DELAY IS ZERO, AND THE REASON IT USED TO BE EIGHT IS WORTH KEEPING (2026-09-13). It was 8 frames to match the SPAWNED tier: the user's call on 2026-08-19 asked for the two renderers to be *"1:1 to the spawned ghost as much as possible"*, and a drawn ghost is naturally AHEAD of a spawned one -- not by error, but because the engine cannot begin a step until its object is standing on a tile, so an engine-driven ghost always trails the truth by up to one step. Ours has no such rule and sits where the peer actually is, so the lag was reproduced here rather than the step machine that causes it. THAT IS THE WRONG STANDARD, and the user said so plainly once the difference was on screen (2026-09-13): *"a ghost is never in the same game, but its supposed to look 1:1 to what a player did in another game"*. The bar is the PEER'S OWN MOTION, not our other renderer -- and a spawned ghost trails only because of an engine limitation the painted tier does not share. Imitating it made the faithful renderer less faithful. What the delay cost, measured all of one session: the camera is slaved to the player's own sprite and stops the instant the player does, so a ghost N frames behind spends those N frames sliding across a stationary screen -- 8px walking, a WHOLE TILE running (documentation.md, "What that means for a ghost that is DELAYED"). With it at zero the user's verdict was *"it actually looks identical now"*. The env var still sets it, so a TIER-COMPARISON session -- the case the 8 was written for, both renderers of one peer side by side -- can have the old behaviour back with dev-scripts/drawn-delay-8.lua. On genderFrames rather than as a chunk local, for the ceiling reason above.
- CONSTANT SPEED, NOT AN EASE. The filter here used to be `x += (target - x) * 0.25`, which is an exponential ease: it never travels at a steady rate, and its steady-state lag grows with how fast the peer is going. That is invisible at walking pace and obvious on a bike -- the user asked for the square test on one, 2026-08-20, and the log answered it: while the peer was at tile 27.19 the drawn ghost sat at 26.019 and closed at 0.002, 0.015, 0.026, 0.036, 0.042, 0.048 tiles a frame -- accelerating, never constant, over a tile behind. A character that drifts toward where it should be instead of travelling there IS the definition of gliding, whatever its legs are doing. A character in this game crosses a tile at a fixed speed and stops. So: move toward the (delayed) target at the speed the TARGET ITSELF is moving, which is the peer's own speed whatever they are riding, with a quarter extra so a gap closes instead of persisting, and never overshoot. The delay line above still provides the trailing distance the engine's own step machine would produce; this only decides how the ground between is covered.
- The floor matters: with the target still, a zero limit would freeze a ghost that is not yet where it belongs. 0.02 tiles a frame closes a sub-pixel gap without being visible as motion. CAPPED, because the peer's own position stream is not continuous. Measured on the Mach Bike across 1x1 and 2x2 squares: the peer's reported position advances 0.06 a frame and then JUMPS about 0.6 of a tile at the boundary -- it reports roughly half a tile of sub-tile progress and then arrives. Taking the speed from that jump let the ghost cover 0.81 of a tile in a single frame, which is a pop, not motion. The old ease hid this by never following anything faithfully. 0.25 tiles a frame is the game's own ceiling -- a tile in four frames, the fastest a Mach Bike moves -- so nothing legitimate is ever slowed by this, and a wire discontinuity is absorbed over three frames instead of popped in one.
- Measured 2026-08-19 with 137 drawn peers: ~40,000 pixel calls a frame took the emulator to 17fps.
- Times THIS FUNCTION only, so the profiler's `draw` section can be split into the per-RUN loop (here) and the per-PEER setup around it (occlusion spans, pose selection, cache lookups). Two os.clock calls per PASS -- ~63 a frame, not per run -- so the instrument is ~0.1% of what it measures. Those have different fixes, which is the only reason to separate them.
- PROFILING (2026-09-11): the per-peer SETUP half of the painted tier is 47 of its 61ms, and this function is the only thing called once per peer that does real work -- it resolves occlusion against the background tilemap. Timed at the definition so every call site is caught, including the reflection and surf-blob ones. Two os.clock calls per CALL, which is a handful per peer, not per run.
- MESHGHOST_EMERALD_REFL_TRACE only (it was COMPARE_TIERS until 2026-09-02), on CHANGE only: what the ground test decided and where it was asked. A reflection that does not appear is either a gate that said no or a decode that returned nothing, and those two have different fixes -- this line says which, without another guess. Moved off the compare flag because compare mode is the dev DEFAULT, and with a crowd walking, "on change" is every peer's every tile: ~150 lines a second with 31 peers even after the per-peer key fix below, all of it string.format on the emulator's thread while the drawn tier was being judged for cost (adapters/CLAUDE.md: probes come off when they are not answering a question).

**`adapters/emulator/pokemon/emerald/probes/cmd_drive.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "A warp's arrival, a whiteout, a Center's counter, and WALLY's battle (2026-09-17)"; adapters/emulator/pokemon/emerald/MEASURED.md, "The party, the bag, money, badges and flags (2026-09-16)"; adapters/emulator/pokemon/emerald/MEASURED.md, "The two bikes: getting on, speed, and stopping on a tile (2026-09-16)" (they hold the bag's +0x5D8 and its XOR and the +0x496 write autoplay's `register_item` reuses; UNVERIFIED.md holds the +0xA30 copy and names the written ledge and the warps, and PROBES.md:67 says a warp onto water arrives surfing; none holds the ledge's metatile 135 and behaviour 59 hopping two tiles, a warp landing on the named tile every time, the `mtscan` chain and its five behaviours, or the Super Rod cast through Select. PROBES.md:67 points readers at this header for what is measured)

- WHAT IS MEASURED (vanilla, 2026-09-16, this tool's log and `borrowed_values_probe.lua`):
  - `warp` -- sWarpDestination and SaveBlock1's location, SaveBlock1 pos, gFieldCallback, then gMain.callback2 = CB2_LoadMap (`goto_map.lua`'s writes) -- landed on the named map and tile every time, onto land and onto water; a warp onto water arrives SURFING (graphic 2, the blob). A warp reloads the map grid from ROM, so it undoes every `mtset`.
  - `mtset` into gBackupMapLayout's grid: a ledge metatile (135, behaviour 59) written 8 rows below the player was drawn by the game when it scrolled on screen and hopped two tiles by walking into it. A tile written ON screen is not redrawn -- write it off screen and walk to it.
  - `mtscan` reads gMapHeader -> mapLayout -> primary/secondary tileset -> metatileAttributes; behaviours 16/22/56/57/59 came back as tiles that behaved as such. Past the secondary tileset's real count it reads whatever follows, so trust low secondary ids only.
  - `givekey`/`register`: SaveBlock1 Key Items at +0x5D8 with the quantity XOR SaveBlock2's key low half (`testkit.lua`'s write), and SaveBlock1+0x496 -- Select then mounted the Acro Bike (272) and cast the Super Rod (264) through the game's own paths.
  - SaveBlock1's object-event copy starts at +0xA30 (slot 0 matched it byte for byte).

**`adapters/emulator/pokemon/emerald/probes/object_slot_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Index" (no entry covers OAM attribute layout; UNVERIFIED.md's "[OPEN] the OAM layout pass" lists the shape/size bits, not where priority and palette sit; unmeasured, a "Not measured yet" item)

- OamData is a packed bitfield; priority/paletteNum live in the second word's high byte. Printed raw so nothing here depends on decoding it correctly today.

**`adapters/emulator/pokemon/emerald/probes/phase2_ghost.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Index" (no entry covers gSprites' symbol size; VERIFIED.md's Phase 1/2 entries and phases/phase2.md hold these addresses and the screen formula, not the .sym array size 0x1144 over 65 entries; phases/phase2.md:26 points readers at this header for the addresses)

- Address/formula sources, all from the same make-compare-verified pokeemerald build used in Phase 1 (see agent_docs/verified.md for the build verification entry):
  - gSaveBlock1Ptr = 0x03005d8c (reused from Phase 1 for the nil/no-save-loaded gate)
  - gPlayerAvatar = 0x02037590 (confirmed Phase 1, pokeemerald.map/.sym)
  - gSprites = 0x02020630, entry size 0x44 (pokeemerald.sym gives the array size 0x1144; 0x1144 / 65 = 0x44)
  - gSpriteCoordOffsetX = 0x02021bbc s16 (pokeemerald.sym)
  - gSpriteCoordOffsetY = 0x02021bbe s16 (pokeemerald.sym)
  - Field offsets (gPlayerAvatar.spriteId, the struct Sprite position fields) were looked up in include/global.fieldmap.h and include/sprite.h; the code below holds the values.

**`adapters/emulator/pokemon/emerald/probes/playersprite_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "2026-10-02 — Facts the code comments carried, moved here word for word" (its SPEEDCHOICE 1.2.2 bullet holds the gObjectEvents and gPlayerAvatar shift, not gSprites; FLAGS.md:34 and BANDAGES.md:149 hold gSprites not moving on Archipelago; PROBES.md:264 holds the (-56,160) reading, not 0x02020634)

- gsprites_scan_probe.lua confirmed 0x02020634 by WALKING the player and watching a sprite track it, which is strong -- but it proves some sprite tracks the player, not that the entry the adapter picks is that one. A shadow, a reflection or a follower tracks the player too.

**`adapters/emulator/pokemon/emerald/probes/saveblock_pair_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "2026-10-02 — Facts the code comments carried, moved here word for word" (its EX SPEEDCHOICE 0.4.0 bullet records that 0x03005D8C reads FDFDFFFF there, not the two candidates 0x03004CAC and 0x03005158; phases/phase8.md's offsets table has no save-block row)

- THE QUESTION. `saveblock_find_probe.lua` left EX SPEEDCHOICE with two IWRAM slots that both hold the player's save block and both tracked it through six steps -- 0x03004CAC and 0x03005158, pointing at the SAME struct. For reading a tile either would do, but the adapter also reads gSaveBlock2Ptr (the player's gender lives there), and in vanilla the two sit ADJACENT: gSaveBlock1Ptr 0x03005D8C, gSaveBlock2Ptr 0x03005D90. So the candidate with a second, DIFFERENT EWRAM pointer immediately after it is the one in the real pair.

**`adapters/emulator/pokemon/emerald/probes/testkit.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "The repel step counter, the FLY map's place name, and rotating gate bytes (2026-09-23)"; adapters/emulator/pokemon/emerald/MEASURED.md, "Not measured yet: The rest of the party, the bag and the flags (from 2026-09-16)" (the first measures the counter reading 250 after a MAX REPEL, not a per-step decrement or the prompt at zero; the second lists a stack past 99 as unmeasured; no record holds an evolution level)

- levels, so a caught Pokemon can hold its own. 99 is the stack cap; Wailmer evolves into Wailord at 40.
- Vars live in their own SaveBlock1 array (where to look: include/global.h:1021), indexed from VARS_START. The hypothesis this kit runs on: VAR_REPEL_STEP_COUNT is the counter the Repel ITEM sets, the repel effect lasts while it is non-zero, and the game decrements it one per step. So "permanent repel" is not a flag to set once -- it is this counter kept topped up, which is why this one is maintained every frame while everything else here is applied once. Keeping it high also avoids the "use another Repel?" prompt entirely, since that fires exactly when it hits zero.

**`adapters/emulator/pokemon/emerald/probes/vramwrite_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "2026-10-02 — Facts the code comments carried, moved here word for word" (its "THE OLD RANGE IS FREED LATER" bullet covers the two-frame OAM lag, not where the ghost's tiles land; VERIFIED.md's 2026-08-21 surf-start entry holds the write breakpoint and the BIOS CpuSet bursts, not the tile range. The code's BASE now reads tile 192, not 84: the reading below is as written then)

- The ghost's post-swap range is deterministic in the replay (tiles 84.., measured three runs in a row), so the addresses are fixed rather than chased.
  - Moved 2026-10-02 with a caveat: `vramwrite_probe.lua` now writes from tile 192 (`BASE = 0x06010000 + 192 * 32`), not 84.

**`adapters/emulator/pokemon/emerald/probes/object_slot_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Measured" (an adapter cost or timing no entry held)

- THE CONSOLE IS THE EXPENSIVE HALF. `console.log` appends to BizHawk's GUI console window, on the emulator's own thread; pitfalls.md measured ONE such line a second costing 7.4fps, and removing the per-line disk flush alone left 87-175ms hitches still there (2026-08-21). So the console gets the opening lines and then one in twenty, while the FILE gets every line -- the log is the record, the console is only a glance.

**`adapters/emulator/pokemon/emerald/probes/capacity_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Index" (no entry covers hardware OAM use; VERIFIED.md's 2026-08-21 OAM pipeline table holds the per-frame gDummyOamData fill read from the decomp, not the 128/128 disable-bit reading on the running game; the code keeps the parking as one line)

- OAM entries actually IN USE, out of 128. The obvious test -- the hardware's own disable bit -- reads 128/128 on this game and means nothing: Emerald does not disable unused objects, it parks them on a dummy entry (off the bottom of the screen), so every entry looks "enabled". Instead this calibrates itself: whatever 8-byte attribute pattern is the MOST COMMON across the 128 entries is the parked/unused one, and everything unlike it is a real object. That holds as long as unused entries outnumber any single duplicated real one, which is true whenever there is headroom -- and if it ever stops being true, the count is conservative rather than silently wrong.

**`adapters/emulator/pokemon/emerald/probes/dive_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Not measured yet — what the code comments said the game's code shows (moved 2026-10-02)" (it holds no dive entry; UNVERIFIED.md's "[OPEN] what the underwater transition does, and how the bob is driven (2026-09-16)" holds the bobber's design, not which data slot carries what; names read from the decomp, never measured)

- A sprite, described in the fields that matter for a bob: where it is, what drives it, what it carries. data[0..2] are the driver's own slots (sSpriteId / sBobY / sTimer).

**`adapters/emulator/pokemon/emerald/probes/goto_map.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "A warp's arrival, a whiteout, a Center's counter, and WALLY's battle (2026-09-17)" (it reads the map header's warp entries, not the save block's WarpData or the pending-warp static; VERIFIED.md's "`goto_map` was placing nobody" holds the CB2_LoadMap path, not these addresses or layouts)

- ADDRESSES. gFieldCallback 03005DAC, CB2_LoadMap 08085FCC and FieldCB_DefaultWarpExit 080AF398 are named in pokeemerald.map; gMain.callback2 030022C4 is copied from the adapter. sWarpDestination is a STATIC and so has no symbol; its address is DERIVED, not measured: the map file puts gLastUsedWarp at 020322DC, and the declaration order at overworld.c:193-194 points one 8-byte struct WarpData later -> 020322E4. A warp landing where asked is what tests it. MAP_MAUVILLE_CITY [source text not copied] -- mapNum 2, mapGroup 0 (constants/map_groups.h:13)
- HOW, and it is the game's own map load rather than a coordinate poke alone. Writing the player's position by itself would move them WITHOUT loading the destination map -- the tiles, objects and connections would still be the old map's. The route is four writes:
  - 1. sWarpDestination AND gSaveBlock1Ptr->location -- where to go (struct WarpData: [source text not copied]).
  - 2. gSaveBlock1Ptr->pos -- WHERE ON THAT MAP TO STAND. See below; this is not optional.
  - 3. gMain.callback2 = CB2_LoadMap, which loads the map named by location.
  - 4. gFieldCallback = FieldCB_DefaultWarpExit -- the ordinary arrive-from-a-warp fade-in, so it looks like every other door in the game rather than a hard cut.
- x = -1, unused when warpId is valid

**`adapters/emulator/pokemon/emerald/probes/noclip.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Map headers, events and behaviours read by an unattended session (2026-09-17)"; adapters/emulator/pokemon/emerald/MEASURED.md, "Autoplay's noclip: through a collision tile and a character (2026-09-17)"; adapters/emulator/pokemon/emerald/MEASURED.md, "Not measured yet — what the code comments said the game's code shows (moved 2026-10-02)" (they hold the grid word's layout, that clearing collision walks through a tile and a character, and VERIFIED.md the +0x0B low nibble; none holds the decomp's collision paths, the odd elevations' shared subpriority 115, MAPGRID_UNDEFINED reporting collision whatever its bits, or ledges going through IsMetatileDirectionallyImpassable; "Autoplay's noclip" lists a ledge as not measured)

- HOW, and it is one field rather than a patched function. Each block of the live map grid is taken to be a 16-bit word with metatile id, collision and elevation bits (where to look: the MAPGRID_* masks, include/global.fieldmap.h:6-12; the collision paths start at `MapGridGetCollisionAt`, fieldmap.c:327, and event_object_movement.c:4663, 4680). The hypothesis this tool runs on: zero the collision bits and the tile is walkable.
- So every non-player object is put on an elevation the player is not on, and put back on unload. The value is chosen from the ODD elevations, which all share `sElevationToSubpriority`'s 115 (:7725) -- so the NPC keeps the draw order it had, and the only thing that changes is whether it blocks. Elevation is the LOW NIBBLE of the object event's +0x0B, which is where this adapter already reads it.
- WHAT IT DOES NOT DO. A block whose id is MAPGRID_UNDEFINED (0x03FF) reports collision whatever its bits say, so the map's outer border still stops you -- you cannot walk off the world. Ledges and one-way tiles go through `IsMetatileDirectionallyImpassable`, which reads the tileset's behaviour bytes in ROM and is untouched here: a ledge still hops you rather than letting you walk up it.

**`adapters/emulator/pokemon/emerald/probes/press_a.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Text printing, menus and the character encoding (2026-09-16)" (A clearing a box after FB/FF, not a held A, the overworld, or an input debounce); PROBES.md:73 holds "tapped, not held -- the game reads a new press", and the code keeps that as one line; no record holds a held A talking on the overworld or the debounce

- Advancing a text box is the sort of thing an agent should do for itself rather than hand back to the user (.claude/skills/play-game/SKILL.md, "Drive it yourself before asking"). Tapped, not held: the game reads a NEW press, so a held A advances one box and then sits there -- and a held A on the overworld would talk to whatever is in front of the player.
- 10 frames down, 10 up: comfortably longer than the game's input debounce either way.

**`adapters/emulator/pokemon/emerald/probes/saveblock_find_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "2026-10-02 — Facts the code comments carried, moved here word for word" (its EX SPEEDCHOICE entries hold FDFDFFFF and +0xC80, not a second save block) and "The party, the bag, money, badges and flags (2026-09-16)"; PROBES.md:261 holds the walk, and PROBES.md:262 says a copy of gSaveBlock1Ptr lacks gSaveBlock2Ptr at +4, which is about the pointer, not about the game keeping more than one save block

- THEN IT WALKS. A match is a candidate until it MOVES with the player: the probe steps one axis and requires every surviving candidate to follow. That is the same discipline gsprites_scan_probe uses, and it is what separates the real pointer from a stale copy of it -- Emerald keeps more than one save block in memory.

**`adapters/emulator/pokemon/emerald/probes/shadowdust_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Not measured yet — what the code comments said the game's code shows (moved 2026-10-02)" (its shadow entry holds the four shadow templates' addresses and its SurfBlob entry a SpriteTemplate's images at +0x0C; no entry holds gSprites' field offsets, gPlayerAvatar's spriteId at +0x04, gSpriteCoordOffsetX/Y's addresses or GroundImpactDust at 0850CCA0)

- ADDRESSES, from our own make-compare-verified pokeemerald build: gSprites 02020630 stride 0x44 { oam 0x00, images 0x0C, pos1 0x20, pos2 0x24, callback 0x1C, flags 0x3E, subpriority 0x43 } gPlayerAvatar 02037590 { spriteId 0x04, objectEventId 0x05 } gObjectEvents 02037350 stride 0x24 { movementActionId 0x1C } gSpriteCoordOffsetX/Y 03005dec / 03005dee Field effect sprite templates (pokeemerald.map), `images` at +0x0C: ShadowSmall 0850C9FC · ShadowMedium 0850CA14 · ShadowLarge 0850CA2C ShadowExtraLarge 0850CA44 · GroundImpactDust 0850CCA0

**`adapters/emulator/pokemon/emerald/probes/spawn_test.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Index" (no entry covers OBJ tile allocation, the camera block's symbols, a sprite's ROM pointers, which sprite slot CreateSprite takes, the facing actions, or how the game frees a removed object's tiles); VERIFIED.md's 2026-08-18 spawn entries (1492-1538) hold the spawn's outcome and gender for free, phases/phase8.md:292-293 the shared-tiles symptom, pitfalls/by-lesson.md:1349-1350 frames copied in when the animation advances, by-lesson.md:1670 the 1024-tile bitmap, VERIFIED.md:3018-3020 east as the west frames plus the flip, UNVERIFIED.md:102 queues "the allocation bitmap is first-fit" for the shipped adapter; none holds the rest of these. The code keeps one line each for the sprite-slot order and for freeing exactly the allocated range

- The SPRITE is copied from the PLAYER's sprite, then patched. A sprite holds four ROM pointers (anims, images, affineAnims, template) that cannot be synthesised from Lua, only copied -- and copying the PLAYER's means the ghost looks like the player, in the correct gender, using a palette that is already loaded on every map by construction (the player's graphics are resident everywhere). Same reasoning as Crystal's "borrow the player's sprite" step, arrived at there the hard way.
- pokeemerald.sym: gFieldCamera 03005dd0 (struct CameraObject, x at +0x10, y at +0x14), gTotalCameraPixelOffsetY 03005de8, gTotalCameraPixelOffsetX 03005dec.
- Sprite tile allocation. A sprite whose images are a frame list (not a sheet) owns a range of OBJ VRAM tiles, and the engine appears to copy the current animation frame into THAT range whenever the frame changes (where to look: RequestSpriteFrameImageCopy, sprite.c:802). So a sprite copied from the player would point at the PLAYER's tiles and display whatever frame the player is in -- which matches what was seen live: a ghost that mirrored the player's facing. Giving the ghost its own tile range makes the engine fill it with the ghost's own frames, for free and with no drawing code. sSpriteTileAllocBitmap  02021b3c, 0x80 bytes = TOTAL_OBJ_TILE_COUNT (1024) bits gReservedSpriteTileCount 02021b3a (u16) -- allocation starts above the reserved region gObjectEventGraphicsInfoPointers 08505620 -- [graphicsId] -> ObjectEventGraphicsInfo*, whose `size` (u16 at +0x06) is the byte size of one frame; TILE_SIZE_4BPP is 32.
- Scan downward: the engine's own CreateSprite takes the lowest free index, so taking a high one keeps our ghost out of the way of whatever the game allocates next.
- Despawn. The ghost now owns a real tile allocation, so despawning MUST return it -- otherwise every re-spawn leaks a run of OBJ VRAM and a long session eventually cannot spawn at all. What this still does not do is follow the game's own removal path (where to look: RemoveObjectEventInternal, event_object_movement.c:1399), which appears to free tiles by the sprite's own image size -- getting that wrong would free somebody else's VRAM. Freeing exactly the range we allocated is both simpler and safer.

**`adapters/emulator/pokemon/emerald/probes/square_drive.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "A direction held across tiles, walking and running (2026-09-16)" (holds that B with a direction runs, at 8 frames a tile; not that B alone opens nothing in the overworld, and UNVERIFIED.md's "[OPEN] what the game checks before it lets a player run" keeps the Running Shoes precondition open)

- B IS THE RUN BUTTON (with the Running Shoes), and it is held with the direction rather than tapped. It opens nothing in the overworld on its own, so this cannot wander into a menu.

**`adapters/emulator/pokemon/emerald/probes/surf_bike_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "SURF: the question, the avatar byte, and stepping off onto land (2026-09-23)" (holds the avatar byte 0x08 on the water, 0x01 on foot and 0x02 on the Mach Bike, and "A direction held across tiles" holds 0x81 running; nothing holds the Acro Bike's bit 2 or the decomp's bit names)

- (1) Does PLAYER_AVATAR_FLAG_MACH_BIKE/_ACRO_BIKE/_SURFING (bits 1/2/3 on the same PlayerAvatar.flags byte meshghost_emerald.lua already reads for the dash bit, bit 7 -- pokeemerald's real include/global.fieldmap.h:288-295) actually behave as documented on this real Archipelago-patched ROM, the same "bitfields need an on-screen check" rule agent_docs/pitfalls.md already states.

**`adapters/emulator/pokemon/emerald/probes/text_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Text printing, menus and the character encoding (2026-09-16)" and "The rest of the text printer (from 2026-09-16)" (neither says which text the game draws without the text routine, such as the title screen's)

- WHAT IT CANNOT SEE: text drawn without that routine (a bitmap blitted by a special screen, the title), the frame each glyph lands (it logs the string when printing STARTS), and anything on a patched ROM.

**`adapters/emulator/pokemon/emerald/probes/wheelie_ghost.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "The two bikes: getting on, speed, and stopping on a tile (2026-09-16)" (bike speed and mounting only; VERIFIED.md's 2026-08-20 wheelie entry and documentation.md's Acro table hold the pop wheelie's 9 busy frames, not the player's step sub-state, paused bit, animation 23 or command index through it)

- WHAT THE PLAYER LOOKED LIKE, to compare against: nine frames with `data2` (the step function's sub-state) at 1 and the sprite's paused bit CLEAR, its animation number 23 and its command index advancing 0 -> 1, then `data2` = 2 and finished on the tenth frame. A sub-state that never leaves 1 is therefore a step function still waiting for its animation.

**`adapters/emulator/pokemon/emerald/probes/camoffset_find_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Index" (no entry covers the camera offset block; phases/phase8.md:1036-1043 holds EX SPEEDCHOICE's camera block shift of -0x10D0, not the vanilla and SPEEDCHOICE sprite and offset readings, the screen-centre formula or the vanilla addresses)

- THE TEST, and it needs no known address. The local player is drawn at the centre of its own screen, and the adapter's own arithmetic says how: sprite.x + cameraOffsetX = screen x. Vanilla reads sprite (168,112) with camOff (-48,0) and lands on (120,112); SPEEDCHOICE reads (24,144) with (96,-32) and lands on the same place. So on any build the true offsets are wantX = 120 - sprite.x wantY = 112 - sprite.y Scan IWRAM for that exact s16 pair, laid out as vanilla lays it out: Y first, X four bytes later (gTotalCameraPixelOffsetY 0x03005DE8, gTotalCameraPixelOffsetX 0x03005DEC).

**`adapters/emulator/pokemon/emerald/probes/facing_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "The map around the player, and one walked step (2026-09-16)" and "Ledges, water, and other maps read from the ROM (2026-09-17)" (they hold the object's +0x05, +0x08, +0x10/+0x12, +0x18 and +0x1C; VERIFIED.md:2130 holds animPaused at +0x2C, decomp-cited; none holds gPlayerAvatar's spriteId at +0x04, the sprite's animNum +0x2A, animCmdIndex +0x2B, hFlip bit 0 of +0x3F, or OAM attr1 bit 12)

- ADDRESSES, from our own make-compare-verified pokeemerald build: gPlayerAvatar 02037590 { spriteId 0x04, objectEventId 0x05 } gObjectEvents 02037350 stride 0x24 { active bit0 of 0x00, localId 0x08, spriteId 0x04, facingDirection low nibble of 0x18, movementActionId 0x1C } gSprites 02020630 stride 0x44 { oam 0x00, animNum 0x2A, animCmdIndex 0x2B, animPaused bit6 of 0x2C, hFlip bit0 of 0x3F } OAM attr1 bit 12 is hFlip for a non-affine entry.

**`adapters/emulator/pokemon/emerald/probes/framedump.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Index" (no entry lists the graphics info fields; VERIFIED.md:1843 holds the table at 0x08505620, and MEASURED.md's 2026-10-02 shadow entry the shadow size at +0x0C bits 4-5, not size, width, height, palette slot, anims or images; no record holds anim 13 at full speed)

- Graphics info table 0x08505620, struct offsets as measured for this adapter (verified.md): size +0x06, width +0x08, height +0x0A, paletteSlot +0x0C (low nibble), anims +0x18, images +0x1C.
- the FAST family, all four directions: anim 13 is what a full-speed ride resolves live, and its images (1,5,6) were never dumped

**`adapters/emulator/pokemon/emerald/probes/move_data_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "A move's type, power, accuracy, PP and effect text (2026-09-16)" (it holds the entries' bytes, not the three tables' sizes)

- ADDRESSES: a pokeemerald build whose ROM hashed identical to the vanilla ROM (SHA-1, 2026-09-16) proves where the tables the build names gBattleMoves, gTypeNames and gMoveDescriptionPointers live, and their sizes (0x10A4, 0x7E, 0x588); what an entry's bytes mean is what this is for. Vanilla only.

**`adapters/emulator/pokemon/emerald/probes/playeranim_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "The map around the player, and one walked step (2026-09-16)" (object +0x05 and +0x1C); VERIFIED.md:2130 and UNVERIFIED.md "[OPEN] the animation-control bit layout" hold animPaused and animDelayCounter at +0x2C, decomp-cited; none holds gPlayerAvatar's spriteId at +0x04 or the sprite's animNum +0x2A and animCmdIndex +0x2B

- ADDRESSES: gPlayerAvatar 02037590 {spriteId 0x04, objectEventId 0x05}, gObjectEvents 02037350 stride 0x24 (graphicsId 0x05, movementActionId 0x1C), gSprites 02020630 stride 0x44 (animNum 0x2A, animCmdIndex 0x2B, animPaused = bit 0x40 of 0x2C, animDelayCounter 0x2D).

**`adapters/emulator/pokemon/emerald/probes/ripple_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "Index" and "Not measured yet — what the code comments said the game's code shows (moved 2026-10-02)" (no entry lists the sprite struct's offsets; the SurfBlob entry holds a SpriteTemplate's fields, not a sprite's; VERIFIED.md:3219-3233 holds the ripple's readings, not the offsets)

- ADDRESSES are the adapter's own, cited there: gSprites 0x02020630 with stride 0x44, and the sprite struct's offsets -- oam +0x00, anims +0x08, images +0x0c, callback +0x1c, pos1 +0x20/+22, pos2 +0x24/+26, animNum +0x2a, animCmdIndex +0x2b, data +0x2e, flags +0x3e (inUse bit 0, invisible bit 2), subpriority +0x43. gPlayerAvatar 0x02037590 (spriteId +0x04, objectEventId +0x05), gObjectEvents 0x02037350 with stride 0x24, gSaveBlock1Ptr 0x03005d8c.

**`adapters/emulator/pokemon/emerald/probes/type_calc_probe.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "What a move's type does to its damage (2026-09-17)" (its "Not measured" names abilities, FORESIGHT, ODOR SLEUTH and type-changing moves, not typecalc2 or fixed-damage moves)

- WHAT IT CANNOT SEE: damage computed by any other command (typecalc2, a fixed-damage move), anything between the two hooks other than their words, a patched ROM.

**`adapters/emulator/pokemon/emerald/probes/warpdump.lua`**, checked against adapters/emulator/pokemon/emerald/MEASURED.md, "The map around the player, and one walked step (2026-09-16)" (it holds SaveBlock1's x and y plus 7, not their offsets or a location at +0x04)

- struct SaveBlock1: [source text not copied] pos (0x00), [source text not copied] location (0x04)

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

### Field-move badges on an Archipelago seed (from 2026-09-24)

- Where an Archipelago seed keeps its field-move rule. Its world's `rom.py` writes four bits per field move at +0x14 of
  a block its data names `gArchipelagoOptions` (a badge count 0-8, or 0xF for "these badges", a bitfield per move from
  +0x18). Both local seeds (ROM name "pokemon emerald version / AP 5") read `ff ff 0f ff` then `01 02 04 08 10 20 40 80`
  at file offset 0x59f584, which would mean FLY with no badge and the rest as vanilla. Not measured in a running seed.
  The autoplay driver's reads are vanilla addresses throughout, and the party is listed 0x30 further on there.

### Not measured yet — what the code comments said the game's code shows (moved 2026-10-02)

These sat in code comments (at `f64560cc`) and say they come from reading the game's code as a map. Nothing here is a fact: each is where to look, until measured.

**`autoplay/drivers/bizhawk/games/emerald.lua`**

- The routine the build names Cmd_trygivecaughtmonnick: "Give a nickname to the captured X?" after a catch, its YES/NO waiting while gBattleCommunication +0 reads 1 -- the decomp as the map; read live after a TAILLOW caught on 0.19, and NO through `select` went on to the end of the battle (2026-09-23).
- Water is entered only from level 3: on 0.34 (25,47), at level 4 on a 0x0C ledge facing water, A gave no SURF question (2026-09-23), where from level 3 on 0.33 it did; the decomp's check wants the default level (the map).

**`adapters/emulator/pokemon/emerald/meshghost_emerald.lua`**

- THE RESTORE STEPS ARE NOT COVERAGE. The effect's last steps put the banner away, and on its final frame the task RESETS its stored window to the full screen (measured: state 6, v=0..160) -- a reset, not a claim. Clipping to that blanked the painted ghost for exactly one frame, three frames before it jumps onto the blob, which is the user's *"vanishes just slightly, barely noticable"*. From RestoreBg onward there is no banner to hide behind, so there is no panel: this code reads the task's state from data[0] and treats 5 and up as restore/end (state 6 measured above; 5 as RestoreBg is the decompilation's naming, a pointer).
- Built from the field effect's own sprite template rather than copied from a live blob, because no blob exists unless somebody is already surfing. gFieldEffectObjectTemplate_SurfBlob 0850CBC4 (SpriteTemplate: tileTag 0x00, paletteTag 0x02, oam 0x04, anims 0x08, images 0x0C, affineAnims 0x10, callback 0x14) UpdateSurfBlobFieldEffect 08155658 (+1 for Thumb) What this code writes into the blob: bob state in data[0] (its low nibble measured changing on the player's own blob at a dismount, see the dismount note), the ghost's object id in data[2], velocity and previous x/y seeded to -1, coordOffsetEnabled, palette 0 and subpriority 150. The slot meanings other than data[0], and the seed values, follow the decompilation's FldEff_SurfBlob (a pointer) and are not measured.
- What this code does (modelled on the decompilation's FldEff_Shadow / UpdateShadowFieldEffect -- pointers). MEASURED 2026-09-16 (probes/borrowed_values_probe.lua) on the engine's own shadow under a walking ledge hop and an Acro Bike hop: template 0850CA14, subpriority 148, the player's x, 12px below the player's pos1 y with pos2 zero, priority the player's. Every graphic id the decompilation names as the player's (0-3, 63, 89-93, 111-112, 137-138, 191-194 -- of which 0, 2, 63 and 137 were seen on the player that day) carries shadow size 1 in the ROM's graphics table, so the other templates are never chosen for a peer:
  - template chosen by the graphic's shadow size (bits 4-5 of graphicsInfo +0x0C): ShadowSmall 0850C9FC, Medium 0850CA14, Large 0850CA2C, ExtraLarge 0850CA44 (pokeemerald.map)
  - subpriority 148, coordOffsetEnabled
  - a per-size vertical drop (genderFrames.shadowDrop)
  - each frame: priority follows the character's, x = character's x, y = character's y + drop -- pos1 only, so the shadow stays on the ground while the character arcs on pos2.
- **THE INVARIANT ABOVE IS NOT YET CONFIRMED ON A RUNNING GAME** (2026-09-12). It is read from the decompilation's declared layout, which is a fact about the struct, and the ordering claim follows from what the list is FOR -- but neither has been read back out of a live gTasks while other tasks were in it. The failure it would produce is loud and local (a door that does not animate, or one task slot of sixteen behaving oddly) rather than silent, and the caller refuses to mark a slot active unless this returns true. Confirming it is one probe's work: dump the chain head-to-tail with each entry's priority during ordinary play and check it is sorted.
- The two graphics the rule belongs to (the fishing graphics' ids per the decompilation, a pointer). 137 MEASURED 2026-09-16: Brendan's object event held it for the length of each cast; May's 138 is unmeasured.
- A DISMOUNT PARKS THE BLOB BEFORE THE JUMP, exactly as the game does it. The blob's bob state changes on the dismount frame and the blob stays parked (filmed below); Task_StopSurfingInit and UpdateBobbingEffect are the decompilation's pointers for it. That is the whole of "the blob stays in the water while you jump ashore". We never sent that state, so a ghost's blob rode ashore under it: the user, with slot 2 re-aimed at this exact transition, *"the blob follows them onto land... the blob is supposed to stay in the water"*. Filmed on the player's own blob during the repro: data[0] low nibble 1 -> 2 on the dismount frame, position parked.
- SHIPPED BEHAVIOUR from here down, not the dev flag above -- this loop runs for every ghost regardless of MESHGHOST_EMERALD_NO_COLLISION. hasShadow STAYS SET on a ghost (byte +0x02 bit 6), and this is the fix for the green flicker near a hopping ghost (user, 2026-08-21: *"a 'green' spot ... same shape as the shadows"*). A ghost's jump runs DoShadowFieldEffect (the pointer), which spawns a shadow effect bound by localId -- and a ghost wears LOCALID_PLAYER, so the effect re-finds the PLAYER, sees its hasShadow clear, and FieldEffectStops itself within a frame or two. In that frame it is a real 16x8 sprite at an uninitialised position whose VRAM copy has not landed yet, i.e. a shadow-shaped patch of whatever pixels were left in that tile range -- green, on a grass map. The probe caught it as one-frame shadow.M entries at dy=-768 (shadowdust_probe, 2026-08-21). DoShadowFieldEffect's own gate is the object's hasShadow flag, so holding it set means the engine never spawns the doomed effect at all -- the engine's own switch, not a hook. Re-applied per frame because the jump-landing ground effects clear it (the decompilation's reading; unmeasured); our real shadow sprite is what actually appears under the ghost.
- `sanim` is the player's own SPRITE ANIMATION NUMBER, and it is what `gfx` alone cannot say. Adopting a peer's graphicsId makes a ghost hold a fishing rod; it does not make it FISH. The game drives that animation from its own fishing task -- and a ghost has no task, so it sits on the first frame of the animation forever. The user, watching it: *"neither of them are doing the mid fishing animations, just the starting fishing one"* (2026-08-19). The animation number is the missing half. Both ends are on the same graphic by then, so the numbering matches, and the peer's own sprite is the authority on what that character is doing. `spaused` is the third thing a sprite's animation state is made of, after the number and the frame -- IS IT RUNNING. A ghost has no task to start or stop its animation, so this decides whether the engine should be handed the animation to play or told to hold one frame. Without it every mirrored state was un-paused, which is right for fishing (the game's task really is animating the player) and wrong for a bike standing still: measured 2026-08-19, the player's own Mach Bike sprite idles at anim 7 frame 3 with animPaused SET, while a spawned ghost pedalled on the spot. The user: *"idle it looks fine on the drawn ghost already, but on the spawned one its doing a 'moving' animation when idle"*. `noanim` is `spaused`'s missing partner, and the pair is not redundant. `spaused` says the sprite's animation is not running; `disableAnim` says the OBJECT is forbidden one, and that outranks a movement. Everywhere else in the game those agree, so one bit was enough -- ice is where they come apart. On ice the character CROSSES TILES with its legs held still (the decompilation's ForcedMovement_Slide, field_player_avatar.c, is where to look; the measurement below is what makes it a fact). Without this bit a ghost is told "moving", the engine gives it the walk cycle its action carries, and it strides across the ice while the player glides: measured in Shoal Cave, 2026-08-21 -- the player held anim 10/0 with disableAnim set for the whole slide while the ghost's own copy cycled 10/2, 10/3 under the same action id on the same tile. `invis`, `boat`, `fly` and `flyk` are the four that describe a character the engine has stopped drawing -- Briney's ride and the Fly cutscene. Everything above them assumes there is a character on the tile to describe; see flyRide's header for why that assumption fails at exactly these two moments, and what each field is read from. `dk`/`dx`/`dy` -- the door -- are the one group here that is APPENDED rather than always present, and that is the point. Every other field costs its `"name":null` on all ~20 packets a second whether it carries anything or not, which is the right trade for a field that changes constantly. A door is the opposite: three or four events a minute, and three always-null fields would add ~30 bytes to every packet forever -- about 2 MB an hour, per peer, to say "no door" twenty times a second. So the door suffix is written only while the engine actually has a door open, and the steady-state packet is byte-for-byte the one this adapter has always sent.
- MOVE AT A SPEED THE ENGINE ACTUALLY PRODUCES (2026-09-12). The limit above is a measured rate times 1.25 -- a catch-up factor -- so after a turn, where the model still owes ground on the axis it was walking, it closes that gap at 1.25x the peer's speed. At running pace that is 2.5px a frame, and NOTHING in this game moves at 2.5px a frame. The user, watching a running square: *"like its sliding after running another direction"*. A character here is stepped by a fixed table -- `NpcTakeStep`, documented in documentation.md -- and every entry in it is a whole number of pixels: MOVE_SPEED_NORMAL 1px   FAST_1 2px   FAST_2 2,3,3,2,3,3   FASTER 4px   FASTEST 8px The peer tells us which one it is: `pspeed` is that same MOVE_SPEED constant, already on the wire and already validated to 0..4. So the ghost moves at the peer's OWN quantum, and a frame of motion is a frame the engine could have produced. CATCHING UP IS ALSO DONE AT A REAL SPEED. Falling behind cannot be answered with a fraction, so a model more than a tile adrift steps up to the next quantum -- a character that needs to cover ground RUNS; it does not walk faster. Anything larger than that is a discontinuity, and the two-tile guard above has already snapped it. FAST_2 IS APPROXIMATED, and says so: its 2,3,3,2,3,3 is uneven per frame and reproducing it exactly needs the peer's step PHASE, which is not on the wire. The average (16/6 px) is used until it is -- the one place here that is not frame-exact. `pspeed` IS NOT `MOVE_SPEED_*`, AND ASSUMING IT WAS COST AN ITERATION (2026-09-12). It is `gPlayerAvatar.bikeSpeed`, which this adapter treats as PLAYER_SPEED_* with 0 meaning standing -- one MORE than the step table's index, where 0 is already walking. The value-to- speed mapping is the decompilation's (bike.h, a pointer) and unmeasured; what is measured is the on-foot 0 below. Indexed as MOVE_SPEED it made a running peer (`pspeed` 0 on foot) move at 1px a frame against a target advancing 2px, so the model lost a pixel every frame until it was a full tile behind and the catch-up rule lurched it forward. Measured in probes/movetrace.log: `d(tgt)=-0.1250 d(model)=-0.0625` for five frames running, `dist` climbing 0.75 -> 1.06. AND ON FOOT THE FIELD READS 0 ANYWAY: the adapter sends the raw `bikeSpeed` byte, and a running player on foot reports 0 (the movetrace.log run above). So the gait comes from `anim`, which this adapter already derives from runningState and the dash flag, and `pspeed` covers the vehicles `anim` cannot describe. The larger of the two wins: a mach bike reads FASTEST while its anim is still "walking", and a dash reads "running" while pspeed is 0. Check what a field IS and DOES, never what its name suggests -- adapters/_template/probes.md has carried that rule since 2026-08-19, and this is the fourth entry under it. The engine's own per-frame pixel counts, indexed by MOVE_SPEED_* (documentation.md, "A step is a fixed table"). FAST_2 -- the acro bike -- is the uneven one: 2,3,3,2,3,3. It is entered here as its MAXIMUM rather than its average, and that is not a fudge: this number is a CEILING, and the model lands exactly on its target whenever the target is within one frame's reach. A ceiling of 3 therefore reproduces 2 on the frames the engine moves 2 and 3 on the frames it moves 3, because the WIRE is already carrying the real pattern -- the sender ramps on the engine's own step length now. The average was worse than either: it could not keep up on a 3px frame and overshot the 2px ones, which is the gait the user called out first.

**`adapters/emulator/pokemon/emerald/probes/bikeclimb_probe.lua`**

- THE RUN-UP IS THE POINT. Held from a standing start one tile below the mud, the bike never accelerates at all: it gains a tile and loses it, once a second, forever -- measured, and the reason `speed=0 peak=0` appeared in every line of the hold-Up log. Where the decomp points for why (unmeasured): ForcedMovement_MuddySlope, src/field_player_avatar.c:567-581.

**`adapters/emulator/pokemon/emerald/probes/spawn_test.lua`**

- Facing without stepping. The decomp suggests a separate east facing animation (where to look: sFaceDirectionAnimNums, event_object_movement.c:715) -- so all four directions should be reachable the same way, and the cycle phase below tests exactly that rather than reasoning about it.
