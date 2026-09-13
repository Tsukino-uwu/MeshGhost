# What Pokémon Crystal sends

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
- **What is in an update:** the four basics, plus up to 16 extras. Nine are in nearly every update;
  the rest only while something is happening (a ledge hop, an emote, a Fly landing, custom art).
- **Checked on arrival:** the MeshGhost client only passes on updates that are valid data. The
  checks below are the script's own.
- **Where:** everything is read in `getLocalState` and received in `renderRemote`
  (`meshghost_crystal.lua`).

## Saying hello

| Field | Value | What it does |
| --- | --- | --- |
| `game_id` | `"crystal"` | Only players running Crystal see each other. |
| `game_version` | the adapter's version | A room can refuse a client whose version differs. |
| `min_protocol_version` | `2` | The oldest client this adapter can talk to. |
| `render_all_areas` | `true` when ghosts across map connections are on | Asks the client for players on neighbouring maps too, so a ghost can be drawn across a map seam. |

## The basics

| Field | What this game puts in it | Example |
| --- | --- | --- |
| `area_id` | The map group and map number | `"24/3"` |
| `position` | Your tile, then your exact pixel position on the map | `[12, 9, 190, 144]` |
| `orientation` | Which way you face | `"down"` |
| `anim` | Whether you are walking | `"walk"` |

<details><summary>Details</summary>

| Field | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `area_id` | text | the map group and number bytes, `W_MAPGROUP` and `W_MAPNUMBER` (`areaId`) | must equal your own map, or the peer's map translated across a connection; otherwise the ghost is removed |
| `position` | list of 4 whole numbers | the player object's map X and Y, and the step progress along the facing (`getLocalState`) | the tile must be numbers, kept to 0–255 (−160–415 across a connection); the pixel pair must be numbers |
| `orientation` | text | the player object's direction (`getLocalState`) | looked up in the four directions; anything else means no facing |
| `anim` | text | whether the player object is mid-step (`getLocalState`) | only `"walk"` means walking |

</details>

## Movement & pose

| Key | On the other screen | Sent |
| --- | --- | --- |
| `act` | What the ghost is doing: standing, stepping, bumping a wall, spinning, fishing, landing from Fly | always |
| `face` | The stride and pose frame | always |
| `prog` | How far through the current step | always |
| `gait` | Walking, cycling or another speed | always |
| `yoff` | How high the sprite is lifted (a ledge hop) | always |
| `jump` | The ghost is hopping a ledge | while hopping a ledge |
| `entry` | How you arrived on this map; the other game uses it for Fly's landing | for a moment after entering a map |
| `fly` | Which Pokémon carries you down when you land from Fly | for a moment after landing from Fly |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `act` | whole number | the player object's action (`getLocalState`) | written to the ghost only if it is one of: stand, step, bump, spin, spin-flicker, fishing, sky-fall |
| `face` | whole number | the player object's facing frame (`getLocalState`) | must be a real number, then kept to 0–255 |
| `prog` | whole number, 0 to 16 | the step's remaining duration, turned into progress (`getLocalState`) | not checked yet |
| `gait` | whole number, 0 to 3 | the player object's step speed, held while standing (`getLocalState`) | not checked yet |
| `yoff` | whole number | the player object's sprite Y offset (`getLocalState`) | above 127 reads as negative, then kept to −96–96 |
| `jump` | true, or absent | the player object's step type is a hop (`getLocalState`) | anything present means hopping |
| `entry` | whole number | how the map was set up on entry (`getLocalState`) | only compared with the Fly value |
| `fly` | whole number | the lead party Pokémon's species (`getLocalState`) | a whole number from 1 to 251 before an icon is drawn |

</details>

## Looks

| Key | On the other screen | Sent |
| --- | --- | --- |
| `sprite` | Which sprite the ghost wears (walking, cycling, surfing…) | always |
| `gfx` | Proof that sprite looks the same in your game | always |
| `pal` | The sprite's palette | always |
| `clo` | The clothing colour | always |
| `emote` | The emote bubble over the ghost | while an emote shows |
| `arth` | Which custom running art the player wears, when your game does not have it | while wearing art your build may lack |
| `arti` | Which piece of that art this update carries | for a moment after changing art |
| `artd` | The piece itself | for a moment after changing art |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `sprite` | whole number | the player object's sprite (`getLocalState`) | a whole number from 1 to 255, and used only when `gfx` matches your own game's picture for it |
| `gfx` | whole number | a hash of that sprite's row in this cartridge's sprite table (`ENGINE.spriteSig`) | only compared with your own game's hash |
| `pal` | whole number | the player object's palette (`getLocalState`) | must be a real number, then kept to 0–7 |
| `clo` | whole number, colour | the palette slot's colour word (`ENGINE.clothing`) | must be a real number, then kept to a 15-bit colour |
| `emote` | whole number | the emote on screen matched against the cartridge's emote pictures (`ENGINE.playerEmote`) | a whole number from 0 to 11 before one is drawn |
| `arth` | whole number | a hash of the art (`ENGINE.wireArtChunk`) | a whole number that fits in 32 bits, and only for sprites that can carry art and do not match on your build |
| `arti` | whole number, 0 to 10 | which of the 11 pieces (`ENGINE.wireArtChunk`) | a whole number from 0 to 10 |
| `artd` | text | 35 bytes of the art, as hex (`ENGINE.wireArtChunk`) | exactly 70 lowercase hex characters; the assembled art must match `arth`; at most 4 pieces of art assembled at once |

</details>

## Other messages

| Message | Direction | What happens | Checked on arrival |
| --- | --- | --- | --- |
| `session_policy` | to the game | `ghost_collision` decides whether ghosts block you | only `"enabled"` or `"disabled"` changes anything |
| `despawn_remote` | to the game | The ghost is removed | needs a player id |
| `remote_name` | to the game | ignored — Crystal draws no nametags | — |
| `recording_state` | to the game | ignored — Crystal has no recording dot | — |

## When nothing is sent

In a menu, a battle or a warp the script keeps sending **the last place you stood**, standing still,
without the moment-only extras. Other players see your ghost waiting where you left the map screen.
Before you first reach the map screen nothing is sent at all.

## Different builds of the same game

Vanilla, Speedchoice and Archipelago can play together.

- **Sprites travel with a picture check** (`gfx`): a sprite that looks different on the watching
  build is not used. Speedchoice's table matches vanilla's; two Archipelago sprites differ, so
  Archipelago sends its own art for them (`arth`, `arti`, `artd`) and the watching game draws it.
- **A fourth gait** exists only on Archipelago, so `gait` 3 comes only from there.
- **`emote`, `entry` and `fly`** are sent only by builds whose addresses for them are known
  (vanilla and Speedchoice).
- **Ghosts across map connections** are off on Archipelago, so what an Archipelago player sees of a
  peer on the next map depends on their own build.
