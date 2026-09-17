# Measured — TEVI

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

Sibling records: [Pokémon Emerald](../emulator/pokemon/emerald/MEASURED.md), [Pokémon Crystal](../emulator/pokemon/crystal/MEASURED.md), [Pseudoregalia](../pseudoregalia/MEASURED.md).

**Older code-level entries still sit in `UNVERIFIED.md` and `VERIFIED.md`**: sorting them into
this file is a queued task (`agent_docs/status.md`, 2026-09-16). Until it runs, look there too.

**Keep the `## Index` section below, one line per `###` entry in either section.** This file only
grows, like `VERIFIED.md`, so the index is what keeps it findable.

## Index

- 2026-09-17 — Where the saves live, what a slot's file is, and what the last autosave wrote
- 2026-09-17 — The save list's cursor, and a new game started through it by injected input
- 2026-09-17 — Under ScriptEngine a plugin's `Info.Location` is empty
- 2026-09-17 — The Randomizer turns Custom Game options on by itself
- Not measured yet — backup slots and the chapter-reset slot
- Not measured yet — what `mode: paused` reads from, and why the pause menu opened

## Measured

### 2026-09-17 — Where the saves live, what a slot's file is, and what the last autosave wrote

**Evidence** (autoplay's Phase 6, `agent_docs/phases/autoplay/tevi.md`): a listing of the save folder; the system
and settings files decompressed in memory (read, never written); `Player.log` from the 2026-09-12 session; both
installs' Unity player info file (`TEVI_Data\app` with the `.info` extension). On the Steam build (`Assembly-CSharp.dll` sha256 `ca07d121...`) and the standalone
build 14778703.

- **Both installs save to one folder**: each build's player info file names `CreSpirit` and `TEVI`, and the folder is
  `%USERPROFILE%\AppData\LocalLow\CreSpirit\TEVI`. A save either install writes, the other reads.
- **A slot is `tevisave<N>.sav`**, a gzip stream (bytes `1f 8b`) of Easy Save 3 JSON, one `{"__type", "value"}`
  object per key (`EXP`, `Resource`, ...). The same folder holds `tevisystem.sav` (keys `recentSaveSlot`,
  `recentMSave`, `backupSaveSlot`, the achievements) and `tevisetting` (`S_*` settings), both gzip JSON too, and
  `tevisigil.sav`. The Randomizer's games are `randomizer\rando.tevisave<N>.sav`, with its `settings.tevi`.
- **An autosave wrote slot 0**: `Player.log`, 2026-09-12, reads `Prepared to auto save.`, then `Game Saved to Save
  Slot 0 | Filename : tevisave0.sav`, `Save recent manual save slot : 0`, `Auto saved.`
- The files on 2026-09-17: slots 0-4, 6, 7, 69 and 80-100; `tevisetting` `S_SYSTEM_AUTOSAVESLOT` 10 and
  `S_SYSTEM_AUTOSAVETIME_SLIDE` 15; `tevisystem.sav` `backupSaveSlot` 93, `recentSaveSlot` 0, `recentMSave` 6.
- **Not seen**: a backup slot being written, or which one (see Not measured yet).

### 2026-09-17 — The save list's cursor, and a new game started through it by injected input

**Evidence**: autoplay's TEVI driver on the Steam build, `observe` reading `HUDSaveMenu.Instance`'s `page` and
`selected` beside screenshots of the same moments (`dev-scripts/shots/tevi/autoplay_save_list_slot39.png`, gitignored),
presses through the driver's Rewired injection; run log `autoplay/runs/2026-09-17_121000.061030.ndjson`.

- **The list is 4 rows a page, and the drawn number is page times 4 plus the row**: page 9, row 3 read slot 39, and
  the picture showed the row "39" highlighted.
- **A 3-frame `XAxis+` hold moves one page right**, eight holds eight pages; **a 3-frame `YAxis-` hold moves one row
  down** (36 to 37 to 38 to 39).
- **The Rewired actions** (`ReInput.mapping.Actions`, at the title): 0 `XAxis` and 1 `YAxis` (axes); buttons 2
  `Jump`, 3 `Ranged`, 4 `Attack`, 5 `Dash`, 6 `Boost`, 7 `LB`, 8 `RB`, 9 `Start`, 10 `Bag`, 11 `ButtonPadX`, 12
  `ButtonPadY`, 13 `Confirm`, 14 `Back`, 15 `Map`, 16 `DefaultX`, 17 `DefaultY`, 18 `Badge`, 19 `Craft`, 21 `Item`,
  22 `Character`, 23 `PageL`, 24 `PageR`, 25 `Notebook`, 26 `Burst`, 27 `Backflip`, 28 `AreaBomb`, 29 `Taunt`.
- **Confirm on an empty slot at the title opens Custom Game**, where `XAxis+` moved the highlight to "Confirm &
  Continue" and Confirm opened the difficulty screen, Normal highlighted by default; Confirm there started the game:
  `mode` title, `no_world` (61 frames after the press), `loading`, `play` (184 frames after it), a second
  `loading`/`play` one frame apart as the room became 5,8, then area `OASISHOME` (area id 1). The player stood at
  x 6984.78, y -6776.0, facing `RIGHT`, clip `stand`, HP 100 of 100.
- `MainVar.instance._saveslot` read 39 on the Custom Game screen and 0 once in the game.

### 2026-09-17 — Under ScriptEngine a plugin's `Info.Location` is empty

**Evidence**: `BepInEx\LogOutput.log` on the Steam install. autoplay's driver built its config path from
`Info.Location` and logged `no .\meshghost-autoplay.txt` though the file sat beside the DLL in `scripts\`; the dev
cheats' own load line reads `Toggle file: .\meshghost-devcheats.txt`, and with a toggle file in `scripts\` they kept
logging all five on until the file was moved to the game's root folder, when they logged
`hp=False mp=False charge=False crystal=False swap=False`.

- A path built from a ScriptEngine-loaded plugin's location lands in the process's working folder, the game root.
  `Paths.BepInExRootPath` gives the install's BepInEx folder instead (what the autoplay driver uses since).

### 2026-09-17 — The Randomizer turns Custom Game options on by itself

**Evidence**: the Steam build with `Tevi Randomizer` 1.6.1 loaded and switched on; a new game started with none of
the twelve options ticked ("Custom Selected : 0/12" on screen); then `SaveManager.GetCustomGame` asked for each value
by the driver, and the corner text drawn during the fade-in.

- The running save answered `SpeedRun`, `FreeRoam`, `TurboMode` and `WeaponMastery`, and the fade-in drew those four
  names. The mod's `GemaNewGame.OnEnable` prefix sets the first two (read in its installed DLL, MIT-licensed); where the other two come
  from is not traced.

## Not measured yet

### Not measured yet — backup slots and the chapter-reset slot

The code, read as a map (`SaveManager.SaveGame`, `ReallyDoAutoSave`; `SettingManager.GetBackupSaveSlotStart`,
`IncreaseBackupSaveSlot`), says: an autosave writes slot 0 and, when the player is in a new room and
`S_SYSTEM_AUTOSAVETIME_SLIDE` minutes have passed, also a backup slot, which runs from `S_SYSTEM_AUTOSAVESLOT` times 4
plus 40 up to 99 and wraps; a chapter reset saves and loads slot 100; the save list refuses a manual save and a new game
at or past the backup start. **To settle**: with a backup of the folder, watch which file changes across an autosave
after the timer, and whether slot 93 (the stored counter) is the one written.

### Not measured yet — what `mode: paused` reads from, and why the pause menu opened

The driver's `paused` is `GameSystem.isAnyPause()`. Right after the Randomizer new game above, the pause menu was open
on its Notebook tab with no injected input, and `mode` read `paused` both while it was open and for 360 frames after
Back closed it (the picture showed the player in the field). **To settle**: log `isAnyPause()` and the pause menu's own
open state each frame across opening and closing it, and whether the game opens the menu when its window loses focus.
