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
- Not measured yet: The rest of the text printer (from 2026-09-16)
- Not measured yet: The rest of the map and the walk (from 2026-09-16)
- Not measured yet: The rest of the party, the bag and the flags (from 2026-09-16)

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
