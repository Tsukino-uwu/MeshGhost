# Autoplay: playing from the save's state, not from a route

Planned 2026-09-24 with the user, after the Emerald 1:1 route run beat the League at an in-game clock of 23:33, against
2:30 for a top human run and 4-6 hours for slower leaderboard runs. The gap was the game idling while each obstacle was
worked out by hand (`phases/autoplay/emerald.md`, 2026-09-24).

## The goal

The user's words: good at handling the game overall and anything it throws at you. That means several routes, and
Archipelago seeds, where key items, badges and HMs arrive in any order, a gym may not need beating, and an item may not
need picking up. So nothing may assume an order ("after NORMAN comes SURF"). A speedrun guide or `route.md` becomes
**advice layered on top**: priorities and bans ("skip this trainer", "fight here for EXP", "manipulate this RNG"), never
the program itself. The same engine plays without them, and faster with them.

## Three layers, each read from the game's own data

1. **What the save can do now.** Badges, the HMs the party knows and the field moves the badges allow, key items (the
   bikes, DIVE, the DEVON SCOPE, the MAGMA EMBLEM), story flags. Read every time, never assumed, the same on vanilla and on
   an Archipelago seed. Emerald's flag and item reads exist already (`observe`); what is missing is naming what they open.
2. **Where the save can get to, and what is worth doing there.** Maps, warps, connections and event tables from the ROM
   (`mapExits`, the scratch dumps), each obstacle tied to what clears it: water to SURF (0x15, 0x10, 0x12), a boulder
   to STRENGTH, a rock to ROCK SMASH, a waterfall (0x13) to WATERFALL, a mud slope (0xD0) to the MACH BIKE, cracked
   floor to the MACH BIKE or to a deliberate drop, a current room to a slide simulation, a blocking character to the
   story flag that moves it. A search over maps gives the reachable set; goals (unvisited checks, the trainer or scene
   that opens a path, the next story trigger) are ranked by reachability and cost. A new item grows the set and the
   plan updates itself.
3. **Getting there, and winning.** `goto` with every obstacle above handled, plus trainer sight: timed spinners (done,
   `3ab32129`), walkers avoided by their movement box (done, `ff33ed55`), walkers timed from that box (open). A battle
   loop inside the driver, doubles and switching included, fed by a **fight predictor**: damage ranges from the ROM's
   own tables (parties, base stats, moves, types), deciding the preparation (X items, healing, which move) before the
   fight, and whether it is winnable yet or needs a detour first.

## Order, each step tested by replaying stretches of the route run

1. **Obstacles in the planner**: boulders, rocks, waterfalls, currents, cracked floors, ledges either way, deep water,
   across maps. The scratch searches from the route run (boulder pushes over several floors, the current simulation,
   the elevation-aware BFS) move into the driver. Timed against the route run's Victory Road and Seafloor Cavern.
2. **The capability reader**: what the save holds and which obstacles that clears, on vanilla and on an Archipelago
   save.
3. **The goal chooser**: the reachable set and a ranked next goal. First real test: an Archipelago seed.
4. **The fight predictor and the battle loop.**

## What the route run already proved (2026-09-23/24)

RNG manipulation is reproducible from the LCRNG position; a turning trainer is passed from one tile outside its line on
a fresh turn away; a walker stays inside its template's box; a pair walking in place in step block each other's view;
STRENGTH is lost on every room change; a hidden item needs the player on its level; the TMs & HMs pocket is shown sorted;
some scenes must be walked into or later areas stay shut (Slateport's harbor).

## Out of scope here

Nothing that ships changes: autoplay stays a dev tool (`autoplay/README.md`). Data read from
the user's own ROM at run time is measurement; nothing from a decomp or a guide enters the repo as fact (`CLAUDE.md`).
