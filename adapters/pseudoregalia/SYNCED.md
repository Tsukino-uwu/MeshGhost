# What Pseudoregalia sends

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
- **What is in an update:** the four basics, plus 37 extras. **Every extra is in every update** —
  a value that only means something sometimes (the thrown sword's position, say) is sent as zero or
  empty the rest of the time.
- **Checked on arrival:** the MeshGhost client only passes on updates that are valid data. The
  checks below are this game's own, and hold even against a client that is not ours.
- **Where:** everything is read in `game_thread_tick` and received in `handle_bridge_line`
  (`MeshGhostPseudo/Mod/src/Plugin.cpp`); the readers that pull a value out of an update are in
  `PeerJson.hpp`.

## Saying hello

| Field | Value | What it does |
| --- | --- | --- |
| `game_id` | `"pseudoregalia"` | Only players running Pseudoregalia see each other. |
| `game_version` | the adapter's version | A room can refuse a client whose version differs. |
| `min_protocol_version` | `2` | The oldest client this adapter can talk to. |
| `interpolate_orientation` | `true` | Asks the client for the two facings either side of the moment being drawn, so the ghost turns smoothly. |
| `input_tracks` | `true` | Asks the client to pass on a replay ghost's recorded button presses, for the input display. |

## The basics

| Field | What this game puts in it | Example |
| --- | --- | --- |
| `area_id` | The full name of the level you are in | `"World /Game/Maps/…:PersistentLevel"` |
| `position` | Where you stand, in the game's own units | `[1200.5, -340.0, 567.2]` |
| `orientation` | Pitch, yaw and roll, in degrees | `[0, 90, 0]` |
| `anim` | Always `"idle"` — the real pose travels in the extras | `"idle"` |

<details><summary>Details</summary>

| Field | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `area_id` | text | the world's `PersistentLevel` name (`game_thread_tick`) | not read — the MeshGhost client compares it to decide who is in your level |
| `position` | list of 3 numbers | `K2_GetActorLocation` on the player (`game_thread_tick`) | all three must be real numbers, or the update is skipped |
| `orientation` | list of 3 numbers | `K2_GetActorRotation` on the player (`game_thread_tick`) | any value that is not a real number turns all three to 0 |
| `anim` | text | fixed (`game_thread_tick`) | not read |
| `orientation_from`, `orientation_to`, `interp_t` | added by the MeshGhost client | — | all must be real numbers or the plain `orientation` is used; `interp_t` kept to its allowed range |
| `timestamp` | added by the MeshGhost client | — | must be a real number; used to line up a replay ghost's button presses |

</details>

## Movement & pose

| Key | On the other screen | Sent |
| --- | --- | --- |
| `move_state` | The ghost takes the same movement state (grounded, airborne, crouch, wall ride, pole, bubble…) | always |
| `action_state` | The same action (slide and other moves) | always |
| `anim_jump_type` | The same kind of jump (backflip, bubble boost, drop-down…) | always |
| `movement_mode` | The same engine movement mode (walking, falling, flying) | always |
| `h_speed` | How fast the ghost's animation thinks it is moving sideways | always |
| `v_speed` | How fast it thinks it is moving up or down | always |
| `land_count` | Plays the landing | counter |
| `jump_count` | Plays the jump | counter |
| `capsule_half` | The ghost crouches and slides to the same height | always |
| `slide_t` | The ghost is at the same point of the slide | always |
| `montage` | Which one-off animation is playing (attacks, throws, ledge grabs…), empty when none | always |
| `montage_count` | Starts that animation | counter |
| `montage_stop_count` | Stops it, including when it was cut short | counter |
| `bubble_charged` | The bubble's charged-jump flash | always |
| `shadow_on` | Shows or hides the ghost's blob shadow (the game hides it while sitting) | always |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `move_state` | whole number | `moveState` on the player (`game_thread_tick`) | kept to 0–255 before it is written to the ghost |
| `action_state` | whole number | `actionState` on the player (`game_thread_tick`) | kept to 0–255 |
| `anim_jump_type` | whole number | `animJumpType` on the player (`game_thread_tick`) | kept to 0–255 |
| `movement_mode` | whole number | `MovementMode` on `CharacterMovement` (`game_thread_tick`) | kept to 0–255 |
| `h_speed` | number | `horizontalSpeed` on the player (`game_thread_tick`) | must start like a number; size not checked yet |
| `v_speed` | number | `verticalSpeed` on the player (`game_thread_tick`) | must start like a number; size not checked yet |
| `land_count` | running total | each time `landed?` on the animation turns on (`game_thread_tick`) | acts only when it rises; a new ghost starts from the first value it gets |
| `jump_count` | running total | each time `jumped?` on the animation turns on (`game_thread_tick`) | acts only when it rises; a new ghost starts from the first value |
| `capsule_half` | number, 1 decimal | `CapsuleHalfHeight` on `CapsuleComponent` (`game_thread_tick`) | kept to 0–4096 |
| `slide_t` | number, 2 decimals | the slide timeline's track value (`game_thread_tick`) | kept to −1024–1024 |
| `montage` | text, asset path | the animation's current montage (`game_thread_tick`) | at most 512 bytes, only an asset your own game has loaded, and it must be a montage |
| `montage_count` | running total | each new montage (`game_thread_tick`) | acts only when it rises; a new ghost starts from the first value |
| `montage_stop_count` | running total | each time a montage ends (`game_thread_tick`) | acts only when it rises; a new ghost starts from the first value |
| `bubble_charged` | 0 or 1 | the pawn's bubble-charge flag, found by name when the game starts (`game_thread_tick`) | anything but 0 means on |
| `shadow_on` | 0 or 1 | `bVisible` on `BlobShadow` (`game_thread_tick`) | anything but 0 means shown; missing means shown |

</details>

## Looks

| Key | On the other screen | Sent |
| --- | --- | --- |
| `outfit_mesh` | The ghost wears the same outfit | always |
| `weapon_mesh` | The ghost's sword is the same model (a weapon mod's too, if the other player has it) | always |
| `weapon_equipped` | The sword is in the ghost's hand, or not | always |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `outfit_mesh` | text, asset path | the mesh on `VisualMesh` (`game_thread_tick`) | at most 512 bytes, only an asset your own game has loaded, and it must be a skeletal mesh; empty keeps the last outfit |
| `weapon_mesh` | text, asset path | the mesh on `WeaponMesh` (`game_thread_tick`) | at most 512 bytes, only an asset your own game has loaded, and it must be a skeletal mesh; empty keeps the last model |
| `weapon_equipped` | 0 or 1 | `weaponEquipped?` on the player (`game_thread_tick`) | anything but 0 means in hand |

</details>

## Effects & trails

| Key | On the other screen | Sent |
| --- | --- | --- |
| `afterimage_count` | Spawns a burst of afterimages behind the ghost | counter |
| `afterimage_n` | How many afterimages that burst has | always |
| `afterimage_color` | The colour of the trail, the ultra hop's blue included | always |
| `vfx` | Which of the player's own effects are showing (healing, charge glow, dust, slashes…) | always |
| `recall_glow` | The glow that says the sword can be called back | always |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `afterimage_count` | running total | each afterimage burst the game spawns (`game_thread_tick`) | acts only when it rises; a new ghost starts from the first value |
| `afterimage_n` | whole number | the size of that burst (`game_thread_tick`) | must be a real number from 1 to 64, otherwise 6 |
| `afterimage_color` | list of 3 numbers, 4 decimals | the afterimages' own colour (`game_thread_tick`) | each kept to −1024–1024; missing keeps the ghost's own colour |
| `vfx` | text: words separated by commas | the player's live effects (`game_thread_tick`) | only words in the effects list below are used; a count must be at most 10 digits; the effect drawn is always your own game's asset |
| `recall_glow` | 0 or 1 | whether the `NS_WeaponCallReady` effect on the player is active (`game_thread_tick`) | anything but 0 means on |

**The `vfx` words.** An effect that lasts is just its word, present while it shows (`heal`). A
quick burst is its word and a running total (`dl:7`) and is always there; the ghost bursts when the
total rises.

| Word | Effect | Kind | Checked on arrival |
| --- | --- | --- | --- |
| `heal` | `NS_Healing` — the healing glow | lasts | must match the list |
| `chg` | `NS_ProjectileCharged` — the charge glow in the right hand | lasts | must match the list |
| `hw` | `NS_HealWave` — the healing wave | burst | must match the list; count at most 10 digits |
| `hew` | `NS_HealEndwave` — the wave when healing ends | burst | must match the list; count at most 10 digits |
| `rsp` | `NS_RespawnSafe` — the aura on respawning | lasts | must match the list |
| `dl` | `NS_DustLand` — landing dust | burst | must match the list; count at most 10 digits |
| `bb` | `NS_BasicBurst` — a hit burst | burst | must match the list; count at most 10 digits |
| `sl` | `NS_PlayerSlash` — the slash arc, facing the same way | burst | must match the list; count at most 10 digits |
| `wk` | `NS_WallKickHit` — the wall kick impact | burst | must match the list; count at most 10 digits |
| `ks` | `NS_KickStab` — the kick flourish | lasts | must match the list |

</details>

## Combat & health

| Key | On the other screen | Sent |
| --- | --- | --- |
| `hurt_count` | The ghost flinches the way the player does when hit | counter |
| `death_count` | The ghost fades out the way the player does on dying | counter |
| `blink_count` | Nothing today — the ghost's response is switched off (`MIRROR_PLAYER_BLINK`) | counter |
| `prj` | The ranged shot is flying | always |
| `prj_vfx` | Which effect the shot is drawn with | always |
| `prj_pos` | Where the shot is | always |
| `prj_rot` | Which way it faces | always |

No health value is sent: only the moments you are hurt or die.

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `hurt_count` | running total | each drop of `CurrentHp` (`game_thread_tick`) | kept to 0–1,000,000,000; acts only when it rises; a new ghost starts from the first value |
| `death_count` | running total | each time `CurrentHp` reaches 0 (`game_thread_tick`) | kept to 0–1,000,000,000; acts only when it rises; a new ghost starts from the first value |
| `blink_count` | running total | stays 0 while `MIRROR_PLAYER_BLINK` is off (`game_thread_tick`) | kept to 0–1,000,000,000 |
| `prj` | 0 or 1 | the player's own `PRJ_PlayerCutter_C` shot, while it is active (`game_thread_tick`) | on only if `prj_pos` and `prj_rot` also read |
| `prj_vfx` | text, asset path | the shot's effect asset (`game_thread_tick`) | at most 512 bytes, only an asset your own game has loaded |
| `prj_pos` | list of 3 numbers, 1 decimal | the shot's location (`game_thread_tick`) | not checked yet |
| `prj_rot` | list of 3 numbers, 1 decimal | the shot's rotation (`game_thread_tick`) | not checked yet |

</details>

## Objects in the world: the thrown sword

| Key | On the other screen | Sent |
| --- | --- | --- |
| `weapon_thrown` | The ghost's sword is flying or stuck somewhere | always |
| `weapon_pos` | Where the sword is (zeros while in hand) | always |
| `weapon_rot` | Which way it points | always |
| `weapon_state` | Flying, or landed | always |
| `weapon_glow` | The glow ring under a landed sword | always |
| `weapon_bounce` | A burst where the sword hits a wall | counter |
| `weapon_class` | Nothing drawn — only written to the log | always |

<details><summary>Details</summary>

| Key | Type | Read from | Checked on arrival |
| --- | --- | --- | --- |
| `weapon_thrown` | 0 or 1 | `weaponRef` exists and is away from the world's origin (`game_thread_tick`) | anything but 0 means thrown |
| `weapon_pos` | list of 3 numbers, 1 decimal | the thrown sword's location (`game_thread_tick`) | used only when thrown and both lists read; values not checked yet |
| `weapon_rot` | list of 3 numbers, 1 decimal | the thrown sword's rotation (`game_thread_tick`) | used only when thrown and both lists read; values not checked yet |
| `weapon_state` | whole number | `weaponState` on the thrown sword (`game_thread_tick`) | kept to 0–255 |
| `weapon_glow` | text, asset path | `idleGlowVFX`'s asset, while landed (`game_thread_tick`) | at most 512 bytes, only an asset your own game has loaded; empty keeps the last one |
| `weapon_bounce` | running total | each sharp reversal of the sword's speed in flight (`game_thread_tick`) | acts only when it rises; a new ghost starts from the first value |
| `weapon_class` | text | the thrown sword's class, while thrown (`game_thread_tick`) | never used to find anything; empty keeps the last one |

</details>

## Other messages

| Message | Direction | What happens | Checked on arrival |
| --- | --- | --- | --- |
| `input_sample` | from the game | Your button presses and stick positions, for replays and the input display — only when `replay.inputs` is on in your `config.json` | — |
| `player_frozen` | from the game | Tells the client the game is paused, so a replay ghost pauses with you | — |
| `remote_name` | to the game | The name and colour on a ghost's nametag | colour must be `#RRGGBB`, otherwise the default; the MeshGhost client limits the name to 24 characters; at most 1024 names remembered |
| `remote_input` | to the game | A replay ghost's recorded button presses, shown in the input display | frames and times must be real numbers in range, otherwise that press is dropped; a capped number held at once |
| `recording_state` | to the game | Shows or hides the recording dot | a start time that is not a real positive number reads as 0 |
| `despawn_remote` | to the game | The ghost is removed | needs a player id |
| `session_policy` | to the game | ignored | — |

## When nothing is sent

On the main menu (the title screen is its own level, and the game has a player standing in it) and
while a level is changing, the game sends an empty update instead of your position. Other players
stop receiving you, and after 3 seconds of silence your ghost is removed from their game.

## Different builds of the same game

Assets travel by name, and a ghost only uses a name the watching game has loaded itself. A player
with a weapon or outfit mod shows up, to a player without that mod, in the outfit or sword model
the ghost already had.

## Taken from your own game, not sent

- **How far the ghost's shadow may fall**: the shadow's arm length is copied from your own player,
  because it is the same on every machine.
