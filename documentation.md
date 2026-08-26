
## Fly is a private cutscene, not an overworld event (2026-08-26)

`FlyFromAnim` / `FlyToAnim` (`engine/events/field_moves.asm`) zero `wStateFlags`, run their own
frame loop, and animate the flying figure through the cutscene sprite-animation system
(`InitSpriteAnimStruct`) with the current Pokémon's ICON as the bird — the overworld object system
is suspended throughout, and every character (NPCs included) is hidden: measured 2026-08-26, an
NPC's `OBJECT_FACING` reads STANDING (`$FF`, the drawn-nothing value) through the whole sequence.
On completion `FlyToAnim` zeroes all shadow OAM past the player's four entries. The player's own
map object never runs the skyfall: `Movement_skyfall` / `STEP_TYPE_SKYFALL` belong to map scripts
(the Burned Tower floor-fall, the Ruins chambers), not to Fly. So nothing about a Fly exists as
object state — a character watching another player fly has nothing in this engine to show.
