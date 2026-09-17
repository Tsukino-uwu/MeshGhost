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

## 2026-09-17 (same session) — into the Sewerways and to the first save point

**The user**, as it was played: *"normal enemies are never required to defeat, only bosses"*; *"got a new move, showed how to use it in
the bottom left"* and *"can also view how all moves are used/done at the pause menu"*; *"you can scroll down the list, if you can't
see everything"*; *"not all sigils are worth using all the time, can enable/disable ones you want by preference"*; *"you can equip
sigils directly when picking them up"*.

**Walked** (run log `autoplay/runs/2026-09-17_131747.151516.ndjson`, segment 5): Knives Out picked up and equipped; a grate broken by
a quickdrop into the Sewerways; the game's map read for the way down; Clean Staffs, bats, mice, bots, a mouse and a cat beaten by
`fight` on the way; the move list read row by row; the first save point used, saved to slot 39 in the shadow. Snapshots
`tevi_sewer_entry`, `tevi_first_savepoint`. The measurements: `adapters/tevi/MEASURED.md`, "Into the Sewerways".

**Built**: `fight` ends `no_progress` when its target's HP stops changing; `screen_text` holds 150 entries of 1500 characters.

## 2026-09-17 (same session) — layer 3: the clock held

**Built**: `clock` in the core ([../phase13.md](../phase13.md)) and in the driver (`Clock.cs`: a postfix on the game's own per-frame
`GameSystem.TimeScale`). **Measured** (segment 6, reached by nothing, at the Sewerways save point room; `adapters/tevi/MEASURED.md`,
"Holding the clock"): held mid-jump, stepped 20 and 1, released; input while held does nothing unless it is the request running, and a
sequence while held runs exactly its frames. Open: what enemies and the unscaled systems do while held.

## 2026-09-17 (end of the session) — where TEVI's autoplay stands, and how to pick it up

**The user**: *"can we start a new chat ?"*, with the Emerald chat still running.

**Left as it is, outside the repo:** TEVI (Steam) running, idle in play in the Sewerways save point room, the clock released, the save
guard armed (nothing reaches the real saves until it exits; closing it is the user's). The Randomizer still `.off`, the dev cheats off,
the driver in `BepInEx\scripts\` with its config (port 7872). The real save folder matched `TEVI.meshghost-backup-20260917-114515` by
hash (PowerShell, 57 files). No core running. `autoplay/states/tevi/`: the shadow (slot 39 holds the save made at the save point) and
snapshots `tevi_cell_start`, `tevi_base_armed`, `tevi_first_enemy`, `tevi_dog_ledge`, `tevi_astral_gear`, `tevi_blastvines`,
`tevi_sewer_entry`, `tevi_first_savepoint` (gitignored).

**To pick up:** as the last session's entry says (core and `mcpcall` built into the chat's scratch folder, `-listen 127.0.0.1:7872`,
its own `-log`, calls from Bash). If TEVI is still running, no launch is needed: the driver connects when a core starts. If it was
closed, start the core first and ask before launching; the guard copies the real folder into the shadow as it arms, so
slot 39's save is gone from a fresh process: get into a game (Start, slot 39, a new game) and `restore` `tevi_first_savepoint`.
Moving is `sequence` (never one hold per call), enemies `reflex` `fight`, conversations and item boxes `advance_text`, time `clock`.
Hot reload: rebuild in `autoplay/drivers/bepinex/tevi/` and copy the DLL and pdb into `BepInEx\scripts\`; a change to `SaveGuard.cs`
needs a restart. The game's own lessons are text now: `tip`, `popup`, `screen_text` (tutorial windows), the pause menu's Characters
move list.

**What the user taught about playing TEVI** (for whoever plays next): normal enemies are never required, only bosses; the icon over
her head means Up interacts; blastorbs are pushed by attacks into things to break them, not fought; sigils cost EP and are chosen by
preference, and can be equipped from the pickup box when EP allows; hold length sets jump height; a pass-through platform is jumped up
through from just beside it; the minimap and the full map (`Map`) show how rooms connect.

**Open, in the plan's order:** layer 5, annotated pictures with the game's hitbox drawing; layer 4, the flight recorder past `trail`
(a core `recent`); `exec` (the game's Quantum Console first). Smaller: the clock with enemies and the unscaled systems (fades, dialogue);
`advance_text` equipping a sigil from its box; `hp_changed` grouped while HP refills; `fight` using Upper Slash and the air combo;
a `goto` over TEVI's grid for the save point and exits `area_elements` lists; what a blastorb breaks.

## 2026-09-17 (new session) — layers 5 and 4, and Ribauld: a dodge that reads the game's boxes and learns an enemy's tells

**Built** (driver, and two shared-core tools: [../phase13.md](../phase13.md), same date; the measurements: `adapters/tevi/MEASURED.md`):
- **Layer 5, `screenshot` `annotate`**: the game's own hitbox drawing (`BulletManager.showHitBox`) on for the captured frame only, and
  numbered tags over what `observe` reads, each listed in the answer. **Layer 4, `recent`**: the flight recorder, 60 seconds of game
  time a row a frame (position, speed, input, the nearest characters with animation, logic state and hitstun, the nearest hostile
  boxes), read after an event with `until_frame`. The clock hold now survives a hot reload.
- **Threats as the game tests a hit** (`Threats.cs`): live bullets with damage and a box, lasers (a circle cast, not a bullet), and a
  blastorb as its blast when it moves toward a character or hops in place, else its touch distance.
- **The dodge** (`Dodge.cs`): 12 plans (stand, run, hop, jump, and quickdrop in the air) over 45 frames against those boxes, with walls,
  the boss arena's camera edges, floors, homing shots, clearance and commitment. `reflex` `evade`; `fight` with it, `attack` `auto`
  (melee in reach, from the air when standing is not safe, Orbitars out of reach), hugging the target, quickdrop instead of falling,
  orb pushes.
- **Tells** (`Tells.cs`): the logic state an enemy is in when each attack box is born, learned by watching, predicted as that box after
  its delay; the table survives a hot reload.

**Walked and reached** (run log `autoplay/runs/2026-09-17_150941.595165.ndjson`): from the Sewerways save point right along the
sewer, onto a raised floor and up a wall by its platform, to Ribauld (**walked**, one sequence each leg). The fight then many times
from snapshot `tevi_ribauld_start` (**reached**; it restores at the save point, and each try walks back in one `sequence`). Ribauld
beaten twice: once shooting from range (phase one hitless, one hit in phase two), once with tells (phase one hitless, two charges hit in
phase two). The try-by-try table is in `MEASURED.md`.

**The user, while it was played** (the combat rules they set are in `playing-rationale.md`, "Combat"): boss fights hitless and fast
as the bar for every game, a goal rather than a requirement; *"this is on the easiest difficulty, harder/hardest diffs may have more
moves/way more projectiles"*, and *"if this succeds, try the hardest difficulty afterwards"*; stay on the boss and melee, melee before
air before Orbitars, quickdrop to get down and avoid hits (it does a little damage and gives invincibility frames); push orbs into the
boss with melee or Orbitars; keep a boss fight's combo going; and *"you are always allowed to hot reload"*. Of outlines: none; yellow while being
attacked, stunned and not attacking; red once attacked too much, until a cooldown, taking less damage, not knocked back and attacking
freely. Holding Attack may give combos or a charge attack.

**Open:** a hitless phase two; the outline (yellow, red) as a field the fight uses; attacking into every safe gap (the user still saw
gaps, with over-dodging); holding Attack and the damage rotation; the combo meter; the hardest difficulty; then `exec` (the game's Quantum
Console first).

## 2026-09-17 (same session) — Infernal BBQ from the cell, `reflex` `goto`, and a death at the blastvines

**The user**, as the Ribauld fight ran on a save whose difficulty had been set by a cheat: *"this does not look like infernal bbq, lets
go back to the main menu and start a fresh new save on slot40"*, *"I want you to replay from the cell, at the harder difficulty"* and
*"prove that you can do the whole intro section faster now, than we did before"*. Then, as it was played: *"can we add a reflex for how
to move around with boxes/ledges/platforms ?"*; *"spend as little time in the air as possible"*, *"basically be efficient while moving
around"*, *"there is no need to jump constantly when walking up stairs"*; *"its always fine to run past normal enemies"*, *"going below
enemies or jumping over them etc, to get to where you want faster. as long as its safe"*, *"prefer always going forward"*; of the
blastorbs, *"use the orbs to your advantage, melee/orbitar them towards enemies if they are nearby. else just go past them"*; and
*"you want to avoid ever taking a hit ... especially on infernal bbq where everything hurts a lot"*.

**Built** (driver): `cheat` `difficulty` (the game's own `SaveManager.SetDifficulty`; the HUD read "Infernal BBQ" after it, but a hit
still cost 1 HP and the user judged the fight unchanged); slots 39 and 40 autoplay's; `local_map` 101 by 51 tiles; **`reflex` `goto`**
(`Navigate.cs`): a route over the collision grid's standing tiles by steps, stairs, falls and jumps held for their height and distance,
carried out a frame at a time through the fight's dodge, quickdropping onto landings, breaking a covered duct, shooting a resting blastorb
aside; `fight` with no quickdrop as an attack.

**Walked and reached** (run log `autoplay/runs/2026-09-17_150941.595165.ndjson`): back to the title through the options' "Return to title
screen" (Tab is the `Bag` action), a new game in slot 40 on Infernal BBQ with no Custom Game option, the intro, the cell (snapshot
`tevi_inf_cell_start`). From the cell by hand-timed sequences to the gate room: **reached**, because a teleport to the spot she already
stood on was sent by mistake. Then **walked**: the Dagger and Orbitars (the first run's snapshots gave the positions to head for), the
wall switch, the gate, the shaft of platforms (two hand-timed tries failed; `goto` climbed it), the corridor, a cat (fought, hitless),
Caprice and Roleo, Basic Engagement, a mouse (it hit her for 26 HP on the way; then fought hitless), the Astral Gear and its switch, a
dog in the hatch (fought, hitless), the duct, a cat (fought: one hit for 33), the blastvines (snapshot `tevi_inf_blastvines_hp17`,
HP 17). There a hand-written step back walked her off the vine ledge onto a cat and a mouse, and she died; the game revived her at that
snapshot's save with 50 HP. From it `goto` shot the floor orb aside, and a mouse in the way hit her once more (35 HP) while fought.

**Faster than the first run**, by the game's own play time in the snapshots: the cell to the blastvines took 624 s (17.7 to 641.7),
against 2,194 s on Cakewalk the first time (324.7 to 2,519.4); 3 hits by then against 49 by the first save point.

**Open:** the rest of the route (blastvines to the save point, then Ribauld) hitless: unfamiliar enemies hit before their tells are
learned, so fight them from range first; the tells table to survive a game restart; the whole Infernal fight with Ribauld.

**The blastvines room on Infernal BBQ, try by try** (same session, from the revive at `tevi_inf_blastvines_hp17`, 50 HP each time):

| Try | What ran | Result |
| --- | --- | --- |
| 1 | a hand-written step back to shoot a hanging orb | walked off the vine ledge onto a cat and a mouse: death |
| 2 | `goto`, then `fight` against a bot in a pit (first meeting, from range) | no room to back off, its first attack: death |
| 3 | `goto` with hop-then-quickdrop plans | one hit (27): the blast table had learned the dog as an explosive from its growing attack box (fixed: only `EXPLODE` bullets teach) |
| 4 | `goto` stepping in only for a hit within 14 frames | a cat's contact hit at 23 HP: death |

**Built along the way:** the tells table kept in `autoplay/states/tevi/tells.json` (gitignored) as well as the AppDomain; an enemy kind
with no learned attack fought from range; hop-then-quickdrop plans; `goto`'s dodge steps in only for a close hit. **Not tried yet**, the
combination the user pointed to: clearing the room's cats, dog, mouse and bot with the blastorbs from the vine ledge above before
going down, instead of walking among them.

## 2026-09-17 (end of the session) — the Infernal BBQ run reached the first save point; what was learned, and how to pick up

**The user**: *"yee just keep running and pay as little time and effort as possible on normal enemies, they are only an obstacle if you
wait around/try to fight them"*; *"just keep running, don't panic and stay idle/wait for enemies to attack you. dodge things along the way"*;
of the blastvines room, *"shot the orb with the orbitar, so it gets pushed towards the robot enemy. then jump down into the hole"* and *"you
have to shot the orb earler/from further away, and then you can just melee it into the robot afterwards"*; *"if you manage to jump into the
hole/go to another area enemies can't follow you there"*; *"just drop down fast to avoid the bats, jump on the cleaners head with quickdrop
to get past safely as long as you won't hit the roof/ceiling"*; *"go backwards/forwards a bit after hitting enemies with quickdrop, you can
control your movement in the air still"*; *"push orbs into enemies when possible, it deals damage and knocks them back"*; and of the Outline
Status tutorial, *"this tutorial explains the armor thing"*. Then: *"lets end this chat here, write down what we have learned, then continue
TEVI in a new chat"*.

**Reached the first save point on Infernal BBQ** and saved there (slot 40, in the shadow), snapshot `tevi_inf_first_savepoint`. By the game's
own play time in the saves: **the cell to the save point in 713.7 s with 7 hits, against 3,393.2 s and 49 hits on Cakewalk the first time.**
A death reloads the last save, so that play time leaves out the attempts lost to deaths: there were eight or so, in the blastvines room and on
the Sewerways' way down (the Clean Staffs, a bat, a bot).

**Built in this stretch** (`Navigate.cs`): a resting blastorb or a normal enemy on her level ahead is hurdled by a running jump steered to the
first standing tile past it (shooting an orb aside sent it back into her path, 50 HP); in the air over an enemy she quickdrops once onto it and
steers on through the bounce (stomping again kept her over a bot until it swept her for 39); `goto` with `dodge` false runs without stopping.
A driving loop outside the repo ran `goto` in 240-frame stretches and snapshotted each one that took no hit, so a death cost one stretch.

**What was learned, for whoever plays TEVI next:**
- **Normal enemies are passed, not fought.** Keep running; hurdle a body in the way; quickdrop onto one below for its invincibility frames
  and steer on; drop into a hole or change area and they cannot follow. Standing near one to dodge is what gets her hit.
- **On Infernal BBQ a normal enemy's hit costs 24 to 39 HP** (a mouse 26 and 35, a cat 33, a Clean Staff's sweep and a bot's sweep 39), so two
  hits can kill; a death reloads the last save with half HP.
- **Blastorbs**: push them into enemies (damage and knockback) from further away, with Orbitars first and melee after; never walk into a
  resting one; one that is shot can come back into the path.
- **Outlines** (the game's Outline Status tutorial): attacked, a target goes yellow (submissive: knocked back when not attacking), then red
  (dominant: its actions cannot be interrupted and melee does less damage). The armor meter measured in `MEASURED.md` is the same thing.
- **Tells come too late on a first meeting**: the dodge learns an attack by seeing it once, and a tight room gives no room to learn it from
  range. The tells table is now kept in `autoplay/states/tevi/tells.json` (gitignored), so it survives a restart.
- **Hold the clock between calls** for timing claims: play time otherwise runs while the model reads.

**Left as it is, outside the repo:** TEVI (Steam) running, idle in play at the Sewerways save point on the Infernal BBQ game (slot 40, HP 100),
clock released, the save guard armed (closing the game is the user's). The Randomizer still `.off`, the dev cheats off. Snapshots in
`autoplay/states/tevi/`: the Cakewalk ones as before plus `tevi_ribauld_start`, `tevi_ribauld_start_infernal` (difficulty set by cheat, not a
real Infernal game), `tevi_inf_cell_start`, `tevi_inf_blastvines_hp17`, `tevi_inf_palladium`, `tevi_inf_leg`, `tevi_inf_first_savepoint`;
`tells.json`. The real save folder matched `TEVI.meshghost-backup-20260917-114515` by hash at the end (PowerShell, 57 files, logs left out).

**To pick up:** core and `mcpcall` built into the chat's scratch folder, `-listen 127.0.0.1:7872`, its own `-log`, calls from Bash (as before).
If TEVI is still running, no launch is needed. If not, ask before launching; from the title, Start, slot 40 loads the Infernal game at the save
point (it is in the shadow only: a fresh process copies the real folder over the shadow as the guard arms, so restore
`tevi_inf_first_savepoint` from inside a game instead). Next on the route: Ribauld on Infernal BBQ, hitless (the fight's tells are learned on
Cakewalk; Infernal may add moves). Moving is `reflex` `goto` (in stretches, with snapshots); combat `reflex` `fight`; conversations `advance_text`.

**Open:** a hitless run through a room of normal enemies on Infernal BBQ; Ribauld on Infernal BBQ; hold-Attack combos and the damage rotation;
the combo meter in boss fights; `exec` (the game's Quantum Console first).

## 2026-09-17 (new session) — Ribauld on Infernal BBQ: beaten three times, once hitless; the laser curtain, thrown orbs and the quickdrop press

**The user, as it was played** (in order): *"its also possible to quickdrop onto bombs to push them"*; *"make sure to use the orbs more,
melee/orbitar/quickdrop them into the boss"*; *"now its not using any melee attacks ?"* (a ranged-only comparison try); *"the combat logic does
not know how to deal with multiple laser attacks at all"*; of the warning beams, *"they are safe locations, until they activate/start to deal
damage"*; *"how would this acocunt for future/different beams ? variying sizes/speed/spacing ?"*; *"still getting hit a lot when the orbs are
being thrown out"*; *"got scared at the start of the second phase / when there were 2 orbs out"*; *"Priority 1 is to not get hit, but priority 2
is to always hugg/stick to the boss as much as possible to constantly deal damage, everything else is a 3rd priority"*; *"deal damage as
much/fast as possible in whatever way is possible / don't take any damage at all"*, measured as *"time taken / current boss health / amount of
hits"*, not per-attack damage (*"there will be more attack moves available later"*); *"double jumps can be useful, but think they need to be
accounted for properly. they leave you vulnerable in the air longer"*. And an idea, filed in `ideas.md`: autoplay reading a replay or input
recording of the user's play as a hint of what to do.

**Built** (driver; the measurements in `adapters/tevi/MEASURED.md`, "Ribauld on Infernal BBQ"):
- **Lasers**: the flight recorder keeps them (up to 32 a row); each laser's age is counted in game frames and the age a type first hurts is
  learned (Ribauld's cut-in laser 56); the dodge counts a warning beam only from then. No swing within 40 of a beam about to hurt (a swing
  slides her).
- **Thrown orbs as tells**: an explosive character coming into play is sampled for the nearest enemy's state, like a bullet's birth
  (Ribauld `ATTACK1` 27 frames, `ATTACK3` 40). An orb's hop counts as its detonation only from rest (thrown orbs bounce).
- **Orbs third**: hit only when already in her swing or under her, never walked to; `orb_shots` shoots a still orb out of reach between them.
  `orb_frames`, `orb_log` (each time an orb is sent flying, and what she was doing).
- **`chain_guard`**: no combo chaining while a combo (56 frames, ground) outlasts the target's fastest learned tell (16, his charge).
- **The quickdrop press**: Down held 4 frames, then Jump, Down kept through the press (`InputInjection.Quickdrop`, used by `fight` and `goto`).
  Pressed together, or with Down let go or held only 2 frames while rising, the game made a double jump, and several hits came from it.

**Reached / walked**: every try restored `tevi_inf_first_savepoint` (reached), then walked in with one `sequence`, `advance_text`, the Quickdrop
window, and `fight` in 600-frame chunks with the clock held between them (a death came in the gap between two uncontrolled calls first).

| Try | Build | Time | Ribauld HP left | Hits |
| --- | --- | --- | --- | --- |
| 1-10 | the fight as it was, then orbs first, ranged, warning beams (138, then 56) | died each time | 178 to 705 | 2-6 |
| 11 | + thrown-orb tells | 138.7 s | 0 | 1 |
| 12-16 | + orbs in reach, Orbitar at orbs, no chaining; from 15 the quickdrop with Down 2 frames first | died each time | 64 to 616 | 3-4 |
| A1 | Down 2 frames first; chaining on, no orb shots | 115.4 s | **0** | **0** |
| B1 | Down 2 frames first; chain guard, orb shots | died 99.5 s | 232 | 3 |
| A2 | as A1 | died 42.5 s | 528 | 4 |
| B2 | as B1 | 164.8 s | 0 | 1 |

Then, with Down held 4 frames before a quickdrop's Jump:

| Try | Build | Time | Ribauld HP left | Hits |
| --- | --- | --- | --- | --- |
| A3 | chaining on, no orb shots | 113.7 s | 0 | 2 |
| B3 | chain guard, orb shots | 136.1 s | 0 | 2 |
| A4 | as A3 | died 76.0 s | 339 | 3 |
| B4 | as B3 | 148.8 s | 0 | 3 |
| A5 | as A3 | 119.2 s | 0 | 3 |
| B5 | as B3 | died 138.5 s | 84 | 4 |

Over five tries each, both beat him 3 times with about the same hits, A in about 116 s and B in about 150 s, so both policies are off by
default now. The same session: the achievement guard (the user saw "Squeak By" unlock during a fight; `autoplay/README.md`).

Snapshot `tevi_inf_ribauld_beaten` (after try 11's conversations). Run log `autoplay/runs/2026-09-17_174242.917353.ndjson`.

**What was learned, for whoever fights next:**
- **One try per build says little**: his attack order differs every try; compare builds over several tries by time, HP left and hits.
- **Read the frames before a hit every frame**: rows every 3rd frame, or printed only when something changed, gave a wrong warning time (138)
  and hid which input made a double jump; `DJUMPING` at a hit is her knockback, not always a jump.
- **What still hits her on Infernal**: the bomb ring while she is in the air above him, a thrown orb arcing onto her, a `speeddown` shot, and his
  charge while a combo locks her.

**Open**: the bomb ring in the air; double jumps as dodge plans, their air time
counted; a quickdrop onto an orb (which way it pushes); the Charged Shot (MP full, a stronger Orbitar shot); a hitless run through a room of
normal enemies; hold-Attack combos; `exec` through the Quantum Console.

## 2026-09-17 (end of the session) — what six builds of the fight taught, and how to pick up

**The user, through the second half** (in order): *"stop being scared of the orbs all the time, melee/orbitar/quickdrop them and push them
onto the boss"*; *"play aggressivly & keep constant damage uptime. will make it faster to defeat the boss. think you might even be able to use
melee attacks when standing in the laser gaps"*; of the bomb ring, *"there should also be a gap to get in some more attacks instead of just
standing idle and watching"*; *"also try to walk closer towards the boss during lasers, not away from the boss. whenever its possible to do so
safely"*; *"always wanna try to stick as close to the boss as possible"*; of build F, *"i like the playstyle of this one, feels like its sticking
to the boss a lot. but its still doing quickdrops a bit to much/randomly when it don't have to"*; and the rule for them: *"quickdrop should only
be used to get back to the ground fast to dodge something, quickdrop ontop of an enemy to get iframes, or get back to the ground so you can do
melee attacks asap. not while it would distrupt attacking"*. Also: autoplay must never unlock an achievement, in any game (after TEVI gave
"Squeak By" mid-fight), and the idea filed in `ideas.md` about learning from a recording of the user's own play.

**Each build was five tries from the same snapshot, scored as the user asked — time, Ribauld's HP left, hits:**

| Build | What it added | Beaten | Time when beaten | Notes |
| --- | --- | --- | --- | --- |
| A | Down held 2 frames before a quickdrop's Jump; chaining on, no orb shots | 3 of 5 | 113.7-119.2 s | hitless once (115.4 s) |
| B | + blanket chain guard, Orbitar at a resting orb | 3 of 5 | 136.1-164.8 s | slower for the same hits |
| C | Down held 4 frames; chaining only while the target's hitstun outlasts the combo | 3 of 5 | 111.4-135.7 s | the defaults after it |
| D | orbs used actively (any orb between her and him) | 2 of 5 | 130.8-139.1 s | one death 100 HP at once |
| E | + swings nearer beams, red outline sooner, step plans toward him | 0 of 4 | – | contact hits while locked beside him |
| F | E backed out; orbs by him shot from outside the blast, never one flying at her | 0 of 3, 1 interrupted | – | hitless at 293 HP when a core call failed |

**What was learned:**
- **Sticking close costs hits.** Every close-range build took more of them, nearly all from his charge (16 frames of warning) while she was
  locked in a swing, or contact while locked. Her locks, measured every frame: a ground swing 20, the ground chain 20 then 17 then 19, an
  air swing 15-21. `RootFrames` was 18 and is now 22.
- **An enemy starts nothing while its hitstun runs** (337 of 339 of Ribauld's attack starts had none left), so a combo is safe while the
  stun left plus the fastest tell outlasts it, and each landed hit renews the stun. That is the chain guard now.
- **A blastorb is a 405-wide blast wherever it goes off**, so an orb hit next to the boss goes off on her too (83 HP), and her own Orbitar
  shot into an orb flying at her took 100 HP at once. Orb use and hugging pull against each other; F's rule (shoot one by him from outside
  the blast, melee only one far from him) is the attempt to have both and is not yet proven.
- **Tells must come from states an attack actually follows.** The bomb ring's pieces were born after he returned to `NORMAL`, so every idle
  moment predicted a ring and she stood still through it; counting how often an attack follows a state removed the ring hits entirely.
- **A hit is diagnosed from every frame before it, never from sampled rows.** The chunk runner now saves the 90 frames before each hit.
- **One try per build proves nothing**: five tries is the least that separates them, and even then 3 of 5 against 3 of 5 is a tie.

**Left as it is, outside the repo:** TEVI (Steam) running, idle in play at the Sewerways save point on the Infernal BBQ game (slot 40, HP 100),
the clock released, the save guard armed and the achievement guard installed (closing the game is the user's). The real save folder is
byte-identical to `TEVI.meshghost-backup-20260917-114515` (56 files, PowerShell, logs left out). No core or `mcpcall` running. Snapshots in
`autoplay/states/tevi/` as before plus `tevi_inf_ribauld_beaten`; `tells.json` holds the Ribauld tells including the orb throws.

**To pick up:** core and `mcpcall` built into the chat's scratch folder, `-listen 127.0.0.1:7872`, its own `-log`, calls from Bash. A try is:
release the clock, `restore tevi_inf_first_savepoint`, hold the clock, one `sequence` to Ribauld, `advance_text`, Confirm the Quickdrop window
after 45 frames of game time, then `reflex fight` in 600-frame chunks with the clock held between them, reading `recent` after each. Judge a
build over five tries by time, HP left and hits.

**Built but never measured** (deployed at the end, no try ran on it): the measured swing locks (`RootFrames` 22, `ComboRootFrames` 40)
and the quickdrop rule above. Measure them first.

**Open**: F's orb rule over five tries; the bomb ring while she is in the air; double jumps as dodge plans, their air time counted against them;
what a quickdrop onto an orb does; the Charged Shot; a hitless run through a room of normal enemies; hold-Attack combos; `exec` through the
game's Quantum Console; and the hardest difficulty once Infernal is clean.
