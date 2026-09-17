# Autoplay — TEVI (Steam build): the game's autoplay log

**A dated record, not current fact.** Each entry says what was true while it was written; paths and
numbers are left as they were. Current state lives in `status.md`; the instructions an agent follows
while playing today in the `play-game` skill (`.claude/skills/play-game/`); what the driver reads and
does in `autoplay/README.md`; the measurements behind it in `adapters/tevi/MEASURED.md`.

**What this file is.** TEVI's entries in autoplay's log (phase 13), from 2026-09-17 on: the plan's Phase 6, the
first PC game -- a BepInEx driver of its own (`autoplay/drivers/bepinex/`), what was measured and built in it, and
what was walked or reached with it. Autoplay's plan, its core, its tools and the shared driver files log in
[../phase13.md](../phase13.md); a change to shared core made from this chat gets its entry there, with a pointer
line here.

## 2026-09-17 — opened: saves measured and backed up, the driver built, and a new game reached through the title

**The order** (`../phase13.md`, "the order from here"): Emerald continues, TEVI starts Phase 6 -- observe, teleport,
a snapshot equivalent and events, navigation teleport-first, `exec` investigated -- and Crystal pauses. The
checkpoint's answer for a PC game's snapshots was in-game save slots the user rarely uses, measured first.

**The saves, measured before anything wrote** (the detail and its evidence: `adapters/tevi/MEASURED.md`, same date):
- **One save folder for both installs.** Both builds' Unity player info file in `TEVI_Data` names `CreSpirit` / `TEVI`, so the Steam
  and the standalone copy share `%USERPROFILE%\AppData\LocalLow\CreSpirit\TEVI`.
- Each slot is `tevisave<N>.sav`, gzip-compressed JSON (Easy Save 3); `tevisystem.sav` holds the recent-slot
  pointers, the backup counter and achievements; `tevisetting` the settings. The Randomizer keeps its games in
  `randomizer\rando.tevisave<N>.sav` -- the user: *"Archipelago has its own savefiles as well, to not mess with
  unmodded saves"*.
- The last session's `Player.log` (2026-09-12) names an autosave's file: `Game Saved to Save Slot 0 | Filename :
  tevisave0.sav`. The settings read `S_SYSTEM_AUTOSAVESLOT` 10 and the system file `backupSaveSlot` 93, with files
  80-99 on disk. The code, read as a map, says backups rotate from that setting times 4 plus 40 up to 99 and a
  chapter reset writes slot 100; not watched happening yet.
- **Backed up** before a session: the whole folder copied beside itself as `TEVI.meshghost-backup-20260917-114515`,
  59 files, every hash matching.

**The user's rulings.** Install: **Steam** (the current build, the one `lib/` matches). Slots: *"feel free to use
36-39 and idm if 40-80~ is also used. i mainly use 1-15 & 95-99 myself"*, then *"feel free to use up 36-80 on the
archipelago saves"*, and *"i care less about the archipelago saves compared to the unmodded saves"*. The autosave:
**the driver holds it off**. The start: **a new game in autoplay's own slot**, with **no** Custom Game options. The
dev cheats: **off** for autoplay sessions, so a segment can read walked.

**Built** (`autoplay/drivers/bepinex/`, never shipped; nothing in the Go core changed):
- `Link.cs` -- the driver side of protocol 1 for any BepInEx game: a thread connects to the core, says the hello,
  reads requests; the main thread answers; a request from a core that has gone is never answered to the next one.
- `tevi/Plugin.cs` -- loaded by ScriptEngine from `BepInEx\scripts\` with `meshghost-autoplay.txt` there (`port`,
  `repo`; no file, no connection). Capabilities `observe`, `wait`, `press`, `screenshot`. The hello: host `bepinex`,
  game `tevi`, variant `vanilla` or `randomizer` by the Randomizer's own switch (a change reconnects), build a hash
  of `Assembly-CSharp.dll`, every slot but 39 protected, and the dev cheats named in `persisting` while any is on.
  `observe`: `mode` (`title`, `no_world`, `loading`, `paused`, `event`, `play`), `location` (area, area id, room,
  x, y, facing), `player` (hp, max, clip), `menu` (the save list's page, row and slot as the menu holds them), `save`
  (slot, Randomizer, guard, the Custom Game options the save runs with), `input_actions`. Events `mode_changed`,
  `area_changed`, `room_changed`.
- `tevi/InputInjection.cs` -- `press` holds the game's own Rewired actions by name (`Confirm`, `XAxis+`), a postfix
  on Rewired's `Player` read methods ORed with the real controller, by frame number: held from S for N frames,
  down on S, up on S+N.
- `tevi/SaveGuard.cs` -- **the save guard**: armed when a core first connects and until the game exits, it refuses
  every Easy Save write, move and delete in the save folder except slot 39's two names, and skips the autosave.
  Applied once per process and kept through hot reloads, its state in the AppDomain, so a reload leaves no gap.

**Live, on the Steam install** (run log `autoplay/runs/2026-09-17_121000.061030.ndjson`, segment 2, **walked**):
- The first load connected to **port 7870**, the Emerald chat's core, which refused it as busy: under ScriptEngine
  a plugin's `Info.Location` reads empty, so the config beside the DLL was never found. Fixed to read
  `BepInEx\scripts\` and to connect nowhere without a config; the next load was on 7872, the guard armed. The dev
  cheats build their toggle path the same way, so theirs is read from the game's root folder, not `scripts\`.
- `observe` at the title: `mode: title`, the Randomizer on, 29 Rewired actions by name. A 3-frame `XAxis+` moved the
  save list one page (8 in a row, 8 pages), `YAxis-` one row down; slot 39 read by `menu.slot` and the picture
  agreeing. Confirm opened Custom Game (none chosen), Confirm & Continue, the difficulty left on the game's
  default, Normal; `mode: play` 184 frames after that press ended, in `OASISHOME` (area 1), room 5,8, HP 100.
- **The Randomizer overrode "none"**: the save ran SpeedRun, FreeRoam, TurboMode and WeaponMastery, read from the
  game; its new-game patch forces the first two. The user closed the game: *"lets disable the archipelago mod for
  now. i don't think it allows you to start a game at the intended intro area"*. Disabled by renaming
  `BepInEx\plugins\Tevi Randomizer\TeviRandomizer.dll` to `.off` (rename it back to enable).
- **The guard's count for that process**: two writes of `tevisystem.sav` refused as the new game began, none
  allowed, no autosave reached; after the game closed, every save file still matched the backup by hash (only
  `Player.log` rotated).
- Open: the pause menu came up on its Notebook tab with no input from the driver; `mode` read `paused` before and
  for the 6 seconds after Back closed it; the save's current slot read 0, not 39.

**The user's question on sight** (the approved plan, same session): YOLO and pictures versus reading the game, and
fast games. The answer taken: the engine's own state every frame in the driver, reflexes at game speed, the clock
held while the model decides, a flight recorder of recent frames, and annotated pictures; a detector only for a
game nothing can be read from (Phase 8). The screenshot is the game's own frame (Unity's `ScreenCapture`, 1280x720),
never the desktop.

## 2026-09-17 (same session) — the Randomizer off, the guard made a shadow, and a Cakewalk new game at the intro

**The user**, after closing the game: *"lets disable the archipelago mod for now. i don't think it allows you to start a game
at the intended intro area"*, and mid-way through the next start, *"Cakewalk, easiest difficulty"*.

**The first vanilla start loaded the player's autosave.** Slot 39, no options, Normal: the game came up in Thanatara Canyon
with HP 1009 and 22,650 coins. The game's log showed why: a new game writes the recent-slot pointer to `tevisystem.sav` and
reads it back after its scene reload; the guard had refused both writes, so it read 0 and loaded slot 0 into memory (nothing
reached the disk). Asked whether it was the autosave hold: the same guard, but the half that refused writes, not the hold
(no autosave had fired). Record: `pitfalls/by-lesson.md`, same date.

**The guard now shadows.** While armed, `ES3Settings.FullPath` maps the save folder to `autoplay/states/tevi/shadow/`, copied
fresh from the real folder as it arms (56 files, the logs left out); ES3's own file moves refuse anything still aimed at the
real folder; the autosave is still held. Without a repo in the config the driver no longer connects. TEVI was closed and
relaunched for it (a guard change needs a new process).

**Built too:** `observe`'s `menu` reads the title's own menus -- the main menu, Custom Game (with `ticked` per option) and the
difficulty list -- as `items` and `cursor`, so the title flow ran on the game's cursor, not on pictures.

**Walked** (run log `autoplay/runs/2026-09-17_121000.061030.ndjson`, segment 4): the title's Start, the save list to slot 39
(9 pages, 3 rows, each read by `menu.slot`), Custom Game with nothing ticked, `Confirm & Continue`, the difficulty list from
Normal up two to Cakewalk, Confirm. The game logged `Save File Slot 39 do not exist. Trying to start New Game`; `observe` read
`mode: event` in `INTRO_ROOM`, HP 100, slot 39; the screen showed the story's first line. The guard: 42 paths shadowed, no
write refused, no autosave held; only the shadow's `tevisystem.sav` written; the real folder identical to the backup by hash.

## 2026-09-17 (same session) — Phase 6's list: the dialogue, the ground around the player, snapshots, a teleport, and a scenario 3 of 3

**The user**, as the intro advanced with no press of the driver's: *"yee it happens when i type/use my mouse"*, then *"it reads
inputs from outside the game i think"* and *"ohh its not doing that anymore now, i had to press Tevi and then unfocus it and its
not reading inputs anymore now unless i have the window active again"*. A change to Rewired's unfocused-input setting was
written and taken out again before it was deployed: the setting already read true, and the leak was a window never focused.
Later, of the intro, *"can play now"*: a 150-second wait of the driver's was rejected, and its core, left holding port 7872, was
stopped (the Emerald chat's on 7870 left alone).

**Built** (the driver only; the Go core unchanged; each measured in `adapters/tevi/MEASURED.md`, same date):
- `observe`'s **`dialogue`** -- status, section, line of lines, speaker, the whole line, how much printed, Auto -- and
  `extras.input_focus`, `fade_alpha_raw`.
- **`Surroundings.cs`**, the plan's layer 1, in an `observe` the agent calls: `player` (on the ground, logic state, velocity),
  `view` (the camera's edges), `local_map` (27 by 17 tiles of the game's own collision grid around the player, with characters,
  items and the elements a player meets drawn over it), `nearby` characters, `elements`, `items`, and `projectiles` (count and
  the nearest 8). The map matched a picture of the cell tile for tile once markers stopped being drawn over it.
- **`snapshot` and `restore`**: the game's own save to slot 39 in the shadow, copied to `autoplay/states/tevi/<label>.State`,
  and back with the recent slot set and `ReloadToGame`, answering once the area, the camera and the fade-in are done (272
  frames; the core's 10 s restore timeout is not near). **`cheat:teleport`** `{x, y}`, answering `held` from a read-back.

**Walked and reached** (run log `autoplay/runs/2026-09-17_121000.061030.ndjson`, segment 5, **reached** by the snapshot's restores
and the teleports): the intro read line by line to Bandit Base's cell; a snapshot `tevi_cell_start`; teleports and three restores,
one teleport inside a fade not holding.

**Phase 6's acceptance: one scenario passes.** `autoplay/games/tevi/scenarios/cell_right_wall.json` -- a teleport onto the cell's
floor, 30 frames standing, then two 60-frame holds of `XAxis+` that the right wall stops at x 17066 -- passed **3 of 3** with no
model (`runs/2026-09-17_130522.657707.ndjson`, its steps walked), and a copy expecting the player short of x 17000 failed at that
step with the value it read. The real save folder matched the backup by hash after both.

## 2026-09-17 (end of the session) — where TEVI's autoplay stands, and how to pick it up

**The user**: *"can we pause here and continue in a new chat ? context is getting high"*.

**Left as it is, outside the repo:**
- **TEVI (Steam) still running**, launched by this chat, in play in Bandit Base's cell, the save guard armed: nothing it does
  reaches the real saves until it exits. Closing it is the user's.
- **The Randomizer disabled**: `BepInEx\plugins\Tevi Randomizer\TeviRandomizer.dll.off` (rename back to enable).
- **The dev cheats off**: `meshghost-devcheats.txt` (all five `=0`) in the game's root folder, beside `TEVI.exe`.
- **The driver** in `BepInEx\scripts\` with `meshghost-autoplay.txt` (`port=7872`, the repo): it arms the guard only when a core
  connects, so ordinary play saves as usual.
- The save folder's backup `TEVI.meshghost-backup-20260917-114515` beside it; the real save files matched it by hash at the end.
- `autoplay/states/tevi/`: the shadow and the snapshot `tevi_cell_start` (gitignored).

**To pick up:** build the core and `mcpcall` into the chat's scratch folder, run them with `-listen 127.0.0.1:7872` and their own
`-log` (Bash quoting: PowerShell 5.1 strips the JSON's quotes), start the core before launching TEVI so the guard arms at load,
and ask before launching. From a fresh launch the title flow is read by `observe`'s `menu`: Start, the save list to slot 39 (it
now holds a Cakewalk game in the shadow only -- the real slot 39 is empty, so a new chat's first launch starts from a new game or
a snapshot copied in by `restore`). The scenario: `go run ./cmd/scenario -listen 127.0.0.1:7872 games/tevi/scenarios`.

**Open, in the approved plan's order:** damage-taken and other events; layer 3, the clock held (`Time.timeScale` measured first,
then a core tool: a shared-core change); layer 5, the annotated picture (the game's own `BulletManager.showHitBox`); layer 4, the
flight recorder (`recent`); then reflexes (layer 2) and `exec` (the game's Quantum Console first). Not measured yet: backup slots,
what exactly opened the pause menu, whether the fade or the load's timing undid a teleport, and which input reached a TEVI never
focused. `tevi_cell_start` lives only in this machine's gitignored states folder.

## 2026-09-17 (next session) — events, the intro played the intended way, and `sequence` for continuous movement

**The user**, asked whether to teleport around looking for something that hurts: *"try to proceed in the game the intended way at
least right now at the start ( its really linear, will force you to learn the basic gameplay)"*. Then, as it was played: *"you
should be able to jump short/high depending on how long the jump button is held"*, that the instruction banners *"are really
useful, as they can explain what to do/how to use things"*, and *"is it possible to move/jump around without doing it in stutter
steps ?"* followed by *"small steps/stutter steps, are never prefered in any game. moving smooth as a player would is always the
goal"* (the rule: the `play-game` skill; the ruling: `playing-rationale.md`).

**Built** (driver, and one shared-core tool: [../phase13.md](../phase13.md), same date; the measurements: `adapters/tevi/MEASURED.md`):
- **Events**: `damage_taken` with its source and `enemy_defeated`, both from the game's one hit method; `hp_changed`, `game_over`,
  `dialogue_changed`, `menu_changed`, `tip_shown`, `item_obtained`.
- **`observe`**: `tip` (the instruction banner), `obtained` (the item box), `screen_text` (every visible text) and `area_elements`.
- **Real input muted** while the guard is armed and the window unfocused. The user, when the pause menu opened by itself: *"its
  grabbing inputs from outside the game when a save is reloaded i think ?"*.
- **`sequence`**: overlapping holds in one call, cut by a `stop_on` event.

**Walked** (run log `autoplay/runs/2026-09-17_131747.151516.ndjson`, segment 3; segment 2, the teleport outside the cell, **reached**,
and the cell restored): up the shelves and out of the cell's left, the ventilation duct broken by a quickdrop, the Dagger and
Orbitars picked up and a conversation, the wall switch (a ↑ bubble) opening the corridor's gate, a shaft of platforms and slopes, a
cat (hurt the player 1 HP a hit), crates, a scene with Caprice and Roleo (`chapter0_opening7`, 11 lines, read by
`dialogue_changed`), a locked floor hatch passed by, the "Basic Engagement" tutorial window, a mouse, and a dog climbed to in one
`sequence` that stopped on its contact hit and beaten by a combo that stopped on `enemy_defeated`. Snapshots `tevi_base_armed` and
`tevi_first_enemy`. Segment 4 **reached**: a restore of `tevi_first_enemy` to check the mute, which also set the walk back to the cat.

## 2026-09-17 (same session) — reflexes: `fight` follows an enemy; the artifact, the hatch, blastvines and the first sigils

**The user**, as it was played: *"need a better way to keep track of/be aware of moving enemies. they will move around/go towards the
player/use ranged attackes etc. you can't just always stop in place and attack hopping that they will walk towards you"*; of an
interaction, *"there will be an icon above the player head, when you can use the up arrow to interact with things"*; of a jump that
kept falling short, *"think you hit your head at the roof/celing"* and *"try to jump below the platform/just a bit to the side of the
platform"*; of orbs on vines, *"these things are bombs you can attack/push towards things to break them, not enemies"*; of a missed
message, *"you got another ui popup, a new skill, along with a description at the bottom left of how to use ti"*; and *"3/10 EP, so
you can still equip more ones if you have any"*. A wrong turn (to a dead end the user had pointed at on purpose) was asked about
rather than walked twice.

**Built** (the shared core's `reflex`: [../phase13.md](../phase13.md); the measurements: `adapters/tevi/MEASURED.md`, same date):
`reflex` `fight` in the driver, which chooses the next frame's input from the enemy's position; `advance_text`; `observe`'s
`interact`, `popup` and a per-frame `trail`; events `interact_changed` and `popup_shown`. A restore made to test the input mute
(segment 4) set the walk back to the first cat; that stretch was walked again in five sequences.

**Walked** (run log `autoplay/runs/2026-09-17_131747.151516.ndjson`, segment 5; no cheat or restore in it): from the first cat to the
dog's ledge again; a dark room lit by picking up the Astral Gear (`chapter0_mainstory1-1`); its red switch (the bubble read
`action`), which opened the crate room's floor hatch and sent a dog down it; a second duct broken by a quickdrop; a mouse, a dog, a
cat and a bot beaten by `fight`; a jump onto a pass-through platform worked out from the `trail`; a Clean Staff `fight` answered
`unreachable`; the blastvines scene (`chapter0_point2`); Palladium picked up, and Palladium and Biscuit Delivery equipped from the
Sigils tab. Snapshots `tevi_dog_ledge`, `tevi_astral_gear`, `tevi_blastvines`.
