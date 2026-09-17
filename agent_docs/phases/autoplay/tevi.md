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
