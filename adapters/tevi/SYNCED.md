# What TEVI sends

## Before adding anything to this file

**KEEP THIS SECTION when you copy this file.** It is repeated at the top of every adapter's
`SYNCED.md` so the rules are in front of whoever is about to edit a row.

- **This page is for players and developers alike.** It says what this game shares with other
  players, what their game does with it, and how each value is checked when it arrives. No history,
  no investigation notes, no "found on" dates — those go to `VERIFIED.md`, `UNVERIFIED.md` or the
  phase file.
- **Every row is read off the code, not off a record.** Check the send code and the receive code
  before writing or changing a row. A row names the game's own field and OUR function, never a line
  number.
- **Every key has a *Checked on arrival* cell, and it is never empty.** A value from another player
  can be anything, so a key with no check today says exactly `not checked yet`. That makes this file
  the checklist: `dev-scripts/preflight.ps1` fails when the code sends a key this page does not list
  (or the other way round), and it refuses a rising count of `not checked yet`.

---

- **How often:** your game hands the MeshGhost client an update every frame; the server sets how
  often it goes out to other players (15 a second unless the room chooses otherwise).
- **What is in an update:** the four basics, plus up to 26 extras. **Most extras are only there
  while something is happening** — a trail, an orb on screen, a bullet just fired — so a player
  standing still sends very little.
- **Checked on arrival:** the MeshGhost client only passes on updates that are valid data. The
  checks below are this game's own. A single extra of the wrong kind (text where a whole number
  belongs) makes the game skip that whole update.
- **Where:** everything is read in `Update` and sent by `SendLocalState`; updates are received in
  `DrainInto` and applied in `UpsertRemoteGhost` and the `ApplyGhost…` methods
  (`MeshGhostTevi/Plugin.cs`, `MeshGhostTevi/BridgeClient.cs`).

## Saying hello

| Field | Value | What it does |
| --- | --- | --- |
| `game_id` | `"tevi"` | Only players running TEVI see each other. |
| `game_version` | the adapter's version | A room can refuse a client whose version differs. |
| `min_protocol_version` | `2` | The oldest client this adapter can talk to. |

## The basics

| Field | What this game puts in it | Example |
| --- | --- | --- |
| `area_id` | The area number | `"3"` |
| `position` | Where you stand, in world units | `[412.5, -96.0]` |
| `orientation` | Which way you face | `"LEFT"` |
| `anim` | The name of the animation you are playing | `"idle"` |

<details><summary>Details</summary>

| Field | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `area_id` | text | `WorldManager.Area` (`Update`) | only compared with your own area, for the map marker |
| `position` | list of 2 numbers | the player's `transform.position` (`Update`) | any value that is not a real number drops the whole position; fewer than 2 numbers and nothing is drawn |
| `orientation` | text | `direction` on the player (`Update`) | `"RIGHT"` faces right, anything else faces left |
| `anim` | text | the animator's current clip name, or `aniStatus` if there is none (`Update`) | at most 96 characters, and your own game's animator must have a state by that name |

</details>

## Movement & pose

| Key | On the other screen | Sent |
| --- | --- | --- |
| `anim_t` | The ghost is at the same point of the animation | while a one-time animation plays, or during hit-stop |
| `pause` | The ghost freezes for the same hit-stop | while hit-stop is on |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `anim_t` | number, 0 to 1 | the animator's `normalizedTime`, wrapped (`Update`) | must be a real number; range not checked yet |
| `pause` | number, seconds | `GameSystem.GetTempPause()` (`Update`) | must be a real number; only "above 0" is used |

</details>

## The map

| Key | On the other screen | Sent |
| --- | --- | --- |
| `room_x` | Where your marker sits on their full map, and whether you are in the same room | always |
| `room_y` | The same, up and down | always |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `room_x` | whole number | `WorldManager.CurrentRoomX` (`Update`) | kept to ±100,000 before the marker is placed |
| `room_y` | whole number | `WorldManager.CurrentRoomY` (`Update`) | kept to ±100,000 before the marker is placed |

</details>

## Effects & trails

| Key | On the other screen | Sent |
| --- | --- | --- |
| `trail` | The afterimage trail: 1 for slide and quick-drop, 2 for dodge | while a trail runs |
| `trail_rate` | How often a trail image appears | while a slide or quick-drop trail runs |
| `trail_decay` | How fast each image fades | while a slide or quick-drop trail runs |
| `trail_rgba` | The trail's colour | while a slide or quick-drop trail runs |
| `trail_order` | Which layer the trail draws on | while a slide or quick-drop trail runs |
| `trail_fx` | Whether the trail images carry the game's extra effect | while a slide or quick-drop trail runs |
| `weapon_rgba` | The colour the weapon flashes during some combos | while the weapon strobes |
| `vfx_seq` | Plays a mirrored attack effect | counter |
| `vfx_id` | Which effect | with `vfx_seq` |
| `vfx_left` | Which way the effect faces | with `vfx_seq` |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `trail` | whole number | the slide, quick-drop and dodge bonuses on the player (`ReadTrailMode`) | 0 or less means none, 2 means dodge, anything else means 1 |
| `trail_rate` | number | the player's `SpriteAnimation` (`ReadTrailParams`) | must be a real number above 0, otherwise the game's default |
| `trail_decay` | number | the player's `SpriteAnimation` (`ReadTrailParams`) | must be a real number above 0, otherwise the game's default |
| `trail_rgba` | whole number, colour | the player's `SpriteAnimation` (`ReadTrailParams`) | any whole number reads as a colour |
| `trail_order` | whole number | the player's `SpriteAnimation` (`ReadTrailParams`) | not checked yet |
| `trail_fx` | true/false | the player's `SpriteAnimation` (`ReadTrailParams`) | true or false |
| `weapon_rgba` | whole number, colour | the weapon sprite's colour (`ReadWeaponStrobe`) | any whole number reads as a colour |
| `vfx_seq` | running total | each mirrored effect the game starts near the player (`WatchLocalVfx`) | acts only when it rises; a new ghost starts from the first value |
| `vfx_id` | whole number | the effect's pool number (`WatchLocalVfx`) | must be in the effects list below |
| `vfx_left` | true/false | the player's facing when it started (`WatchLocalVfx`) | true or false |

**The effects list.**

| `vfx_id` | Effect | Checked on arrival |
| --- | --- | --- |
| `56` | The ground combo's fourth-hit blast | must match the list |
| `0` | The cut-in star | must match the list |
| `37` | The perfect-timing extra on that hit | must match the list |

</details>

## Orbitars and core expansions

| Key | On the other screen | Sent |
| --- | --- | --- |
| `orbs` | The orbitars around the ghost, as they look right now | while an orb is shown |
| `orbfx_seq` | Plays the flash of an orb turning into a summon | counter |
| `orbfx_orb` | Which orb | with `orbfx_seq` |
| `orbfx_white` | Which of the two flashes | with `orbfx_seq` |
| `summons` | The summoned Celia or Sable, standing and animating | while a summon is out |
| `shield` | The boost shield around the summon | while the shield is up or animating |
| `plats` | The platforms under the shield | while the shield is up |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `orbs` | list of rows, 11 numbers each | each shown orb's renderers (`ReadOrbs`) | at most one row per orb; see the cells below |
| `orbfx_seq` | running total | each orb-to-summon flash (`WatchLocalOrbFx`) | acts only when it rises; a new ghost starts from the first value |
| `orbfx_orb` | whole number | which orb (`WatchLocalOrbFx`) | outside the ghost's orbs, the flash plays at the ghost instead |
| `orbfx_white` | true/false | which flash the game picked (`WatchLocalOrbFx`) | true or false |
| `summons` | list of rows, 11 cells each | the summon's own sprite and animator (`ReadSummons`) | see the cells below |
| `shield` | one row, 11 cells | the shield's transform and colours (`ReadShield`) | see the cells below |
| `plats` | list of rows, 4 cells each | each enabled platform (`ReadPlatforms`) | see the cells below |

**`orbs`, one row per orb.** A row with any cell that is not a real number is skipped.

| Cell | Carries | Checked on arrival |
| --- | --- | --- |
| 1 | which orb | must be 0 or 1 |
| 2–3 | offset from the player | real numbers |
| 4 | the orb's sprite, as a number in the game's orb table | not checked yet |
| 5 | its draw layer | not checked yet |
| 6 | the glow's sprite, as a number in the game's glow table | not checked yet |
| 7 | the glow's opacity × 100 | kept to 0–1 |
| 8 | the crystal's colour, −1 for none | any whole number reads as a colour |
| 9 | the crystal's opacity × 100 | kept to 0–1 |
| 10 | the crystal's rotation | real number |
| 11 | the charge ring's size × 100, 0 for none | not checked yet |

**`summons`, one row per summon.**

| Cell | Carries | Checked on arrival |
| --- | --- | --- |
| 1 | which summon | must not be empty; at most 4 different ones per ghost |
| 2 | the animator's name | only an animator your own game has |
| 3–4 | where it stands | real numbers |
| 5 | which way it faces | `"RIGHT"` faces right, anything else left |
| 6 | the clip it plays | that animator must have a state by that name |
| 7 | how far into the clip | kept to 0–1 |
| 8–9 | its scale | real numbers; size not checked yet |
| 10 | whether it is visible yet | true or false, missing means visible |
| 11 | the animator's speed | real number, otherwise 1; range not checked yet |

**`shield`.**

| Cell | Carries | Checked on arrival |
| --- | --- | --- |
| 1–3 | where it is | real numbers |
| 4 | its scale | real number; size not checked yet |
| 5–7 | its rotation | real numbers |
| 8–10 | its three colours | 8 hex digits each, otherwise unchanged |
| 11 | whether it is up | true or false, missing means up |

**`plats`, one row per platform.**

| Cell | Carries | Checked on arrival |
| --- | --- | --- |
| 1 | which platform | must be one the game has |
| 2–3 | where it is | real numbers |
| 4 | its colour | 8 hex digits, otherwise unchanged |

</details>

## Projectiles

| Key | On the other screen | Sent |
| --- | --- | --- |
| `bul` | Bullets the other player fired, flown by your game from where they started | for a moment after each shot |
| `buld` | Bullets that stopped early (a wall, a hit) | for a moment after each stop |
| `buldp` | Where each of those stopped | with `buld` |
| `bulf` | A bullet's behaviour changed mid-flight | when it changes |
| `flash` | The muzzle flash of a shot or charged shot | for a moment after each flash |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `bul` | list of rows, 15 cells each | each new bullet the player owns (`ReadBullets`) | a row shorter than 13 cells is skipped; no more live bullets than your game's own bullet pool; see the cells below |
| `buld` | list of numbers | bullets that died early (`ReadBulletDeaths`) | a value that is not a number is skipped; only a bullet this ghost already fired is stopped |
| `buldp` | list of numbers, pairs | where each stopped (`ReadBulletDeathPositions`) | real numbers, one pair per bullet, otherwise the bullet stops where it is |
| `bulf` | list of numbers, pairs | a bullet number and its new behaviour flags (`ReadBulletFlagUpdates`) | real numbers and a bullet this ghost fired; the flags themselves are not checked yet |
| `flash` | list of rows, 6 cells each | shot and charged-shot flashes near the player (`ReadFlashes`) | see the cells below |

**`bul`, one row per bullet.**

| Cell | Carries | Checked on arrival |
| --- | --- | --- |
| 1 | the bullet's number | fires only when above the last one seen; a new ghost starts from the first rows it gets |
| 2 | its type, as a number | not checked yet (the name in cell 15 wins when this build has it) |
| 3 | its sprite, as a number | only used to set a sprite below 91; otherwise not checked yet |
| 4–5 | where it started | real numbers, otherwise not fired |
| 6 | its angle | must be a number; infinity not checked yet |
| 7 | its speed | must be a number; infinity not checked yet |
| 8 | its scale | used only when above 0 |
| 9 | the effect's pool | must carry the effect kind below, otherwise the first pool that does |
| 10 | the effect's kind | must be 0–7 |
| 11 | the effect's scale | used only when above 0 |
| 12 | the effect's colour | 8 hex digits, otherwise white |
| 13 | whether it was fired facing left | true or false |
| 14 | how old it already is | at most 30 catch-up steps |
| 15 | the rest, packed as text: start size, counters, flags, life, delete time, tint, pool name, type name, sprite name | see below |

**`bul` cell 15, separated by `|`.**

| Part | Carries | Checked on arrival |
| --- | --- | --- |
| 1 | start size | must be a number above 0 |
| 2 | counters, as `slot:value` pairs | slot 0–9 and a real number |
| 3 | behaviour flags | not checked yet |
| 4 | life | not checked yet |
| 5 | delete time | not checked yet |
| 6 | tint | 8 hex digits, otherwise unchanged |
| 7 | effect pool's name | never used to find anything |
| 8 | type name | must be a type name this build parses; a number in its place is not checked yet |
| 9 | sprite name | must be a sprite name this build parses; a number in its place is not checked yet |

**`flash`, one row per flash.**

| Cell | Carries | Checked on arrival |
| --- | --- | --- |
| 1 | the flash's number | fires only when above the last one seen; a new ghost starts from the first rows it gets |
| 2 | its pool (7 for a shot, 12 for a charged shot) | must be a pool the game has; limiting it to 7 and 12 is not checked yet |
| 3–4 | where it is | real numbers |
| 5 | whether it faces left | true or false |
| 6 | its colour | 8 hex digits, otherwise white |

</details>

## Other messages

| Message | Direction | What happens | Checked on arrival |
| --- | --- | --- | --- |
| `despawn_remote` | to the game | The ghost is removed | needs a player id |
| `remote_name` | to the game | ignored — TEVI draws no nametags | — |
| `recording_state` | to the game | ignored — TEVI has no recording dot | — |
| `session_policy` | to the game | ignored — a TEVI ghost is never solid anyway | — |

## When nothing is sent

On the main menu and the title screen the game sends an empty update, drops its connection to the
MeshGhost client once, and removes every other player's ghost from your screen. Other players stop
receiving you, and after 3 seconds of silence your ghost is removed from their game. **The pause
overlay is not the main menu**: while paused you keep sending, and ghosts stay on screen.

## Different builds of the same game

The Steam and standalone releases number their bullet types and sprites differently, so each bullet
also carries the type and sprite by name, and a game that knows the name uses it instead of the
number. The effects list (`vfx_id`), the flash pools, the orb sprites and `area_id` still travel as
numbers.
