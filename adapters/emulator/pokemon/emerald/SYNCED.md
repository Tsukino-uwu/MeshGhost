# What Pokémon Emerald sends

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

- **How often:** the script hands the MeshGhost client an update every frame; the server sets how
  often it goes out to other players (15 a second unless the room chooses otherwise).
- **What is in an update:** the four basics, plus up to 18 extras. Fourteen are in every update
  (some as `null` when there is nothing to say); the door keys and `mspd` only when they apply.
- **Checked on arrival:** the MeshGhost client only passes on updates that are valid data. The
  checks below are the script's own.
- **Where:** the update is built by `encodeLocalState` from `getLocalState` and the reads in
  `runFrame`; updates are received in `handleBridgeLine` (`meshghost_emerald.lua`).

## Saying hello

| Field | Value | What it does |
| --- | --- | --- |
| `game_id` | `"emerald"` | Only players running Emerald see each other. |
| `game_version` | the adapter's version | A room can refuse a client whose version differs. |
| `min_protocol_version` | `2` | The oldest client this adapter can talk to. |
| `render_all_areas` | `true` | Asks the client for players on every map, so a ghost on a neighbouring map can be drawn across the seam. |

## The basics

| Field | What this game puts in it | Example |
| --- | --- | --- |
| `area_id` | The map group and map number | `"0:9"` |
| `position` | Your tile, smoothed between tiles while you move | `[12.5, 7]` |
| `orientation` | Which way you face | `"south"` |
| `anim` | Standing, walking or running | `"walking"` |

<details><summary>Details</summary>

| Field | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `area_id` | text | the map group and number in save block 1 (`getLocalState`) | compared with your map and the maps connected to it |
| `position` | list of 2 numbers | the tile in save block 1, ramped over the step (`runFrame`) | both must be present and real numbers, or the whole update is dropped |
| `orientation` | text | the player object's facing (`getLocalState`) | looked up in the four directions; anything else is ignored or read as south |
| `anim` | text | the player avatar's running state and dash flag (`getLocalState`) | looked up in the three names; anything else adds no speed |

</details>

## Movement & pose

| Key | On the other screen | Sent |
| --- | --- | --- |
| `act` | The movement the ghost performs (a step, a turn, a jump…) | always |
| `sanim` | Which animation the ghost's sprite plays | always |
| `sidx` | Which step of that animation | always |
| `spaused` | The sprite's animation is paused | always |
| `noanim` | The character may not animate right now | always |
| `pspeed` | The bike speed | always |
| `mspd` | Exactly how many pixels a frame the step moves | while the step speed reads 0–4 |
| `sox` | The sprite's sideways pixel offset | always |
| `soy` | The sprite's up-down pixel offset | always |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `act` | whole number | the player object's movement action (`runFrame`) | a whole number from 0 to 255 |
| `sanim` | whole number | the player sprite's animation number (`runFrame`) | a whole number from 0 to 255, and only while `gfx` is the same |
| `sidx` | whole number | the player sprite's animation command index (`runFrame`) | a whole number from 0 to 255, and only while `gfx` is the same |
| `spaused` | 0 or 1 | the player sprite's animation-paused bit (`runFrame`) | anything but 0 means paused |
| `noanim` | 0 or 1 | the player object's disable-animation bit (`runFrame`) | anything but 0 means on |
| `pspeed` | whole number | the player avatar's bike speed (`runFrame`) | a whole number from 0 to 4 |
| `mspd` | whole number, 0 to 4 | the player sprite's step speed (`runFrame`) | a whole number from 0 to 4 |
| `sox` | whole number | the player sprite's `pos2` X (`runFrame`) | kept to −32–32 |
| `soy` | whole number | the player sprite's `pos2` Y (`runFrame`) | kept to −32–32 |

</details>

## Looks

| Key | On the other screen | Sent |
| --- | --- | --- |
| `gender` | Which player character the ghost is | always |
| `gfx` | Which graphic the ghost wears (walking, a bike, surfing, a field move…) | always, `null` if unknown |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `gender` | text | the player's gender in save block 2 (`readLocalGender`) | `"male"` or `"female"`, otherwise male |
| `gfx` | whole number | the player object's graphics id (`localGraphicsId`) | a whole number from 0 to 255 whose entry in your own game's graphics table is real; a change is usually taken once two updates agree |

</details>

## Travel and doors

| Key | On the other screen | Sent |
| --- | --- | --- |
| `invis` | The player's character is hidden, as on the ferry | always |
| `boat` | The ferry the ghost rides | while on the ferry, otherwise `null` |
| `fly` | Fly's swoop: 1 while the bird swoops, 2 once the rider is on it | while flying, otherwise `null` |
| `flyk` | Where along the swoop | while flying, otherwise `null` |
| `dk` | A door opening or closing | while a door animates |
| `dx` | The door's tile, sideways | with `dk` |
| `dy` | The door's tile, up and down | with `dk` |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `invis` | 0 or 1 | the player object's invisible bit (`flyRide.sample`) | anything but 0 means hidden |
| `boat` | whole number | the boat object on the player's tile (`flyRide.sample`) | a whole number from 0 to 255; your game's graphics table decides whether it draws |
| `fly` | 1 or 2 | the Fly task and its bird sprite (`flyRide.sample`) | exactly 1 or 2 |
| `flyk` | whole number | the bird sprite's arc value (`flyRide.sample`) | a whole number from 0 to 255 |
| `dk` | text | the door task: `"o"` opening, `"c"` closing (`genderFrames.door.sample`) | must be `"o"`, `"c"` or `"h"`, otherwise all three door keys are dropped |
| `dx` | whole number | the door task's tile (`genderFrames.door.sample`) | a whole number from 0 to 1023 |
| `dy` | whole number | the door task's tile (`genderFrames.door.sample`) | a whole number from 0 to 1023 |

</details>

## Other messages

| Message | Direction | What happens | Checked on arrival |
| --- | --- | --- | --- |
| `session_policy` | to the game | `ghost_collision` decides whether ghosts block you | only `"enabled"` or `"disabled"` changes anything |
| `despawn_remote` | to the game | The ghost is removed | needs a player id |
| `remote_name` | to the game | ignored — Emerald draws no nametags | — |
| `recording_state` | to the game | ignored — Emerald has no recording dot | — |

## When nothing is sent

Until you reach the map screen, for a moment each time the map changes, and on a cartridge the
script has no addresses for, the script sends an empty update. Other players stop receiving you,
and after 3 seconds of silence your ghost is removed from their game.

## Different builds of the same game

Vanilla, Archipelago and the Speedchoice builds can play together; the update looks the same from all of them.

- **`gfx` is a number, not a picture check**: the watching game draws whatever its own graphics
  table holds at that number.
- **Doors** are sent by a patched build only after its player has opened a real door, because that
  is when the script learns where the door task lives.
- **`boat`, `fly` and `flyk`** read cartridge addresses shifted for each build; on a build whose
  shift is wrong they are always `null`.
