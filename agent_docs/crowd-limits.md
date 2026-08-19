# How many ghosts can a game actually hold?

**This is a first-class question for any adapter, and especially for an emulated one.** A modern
engine spawns actors until memory runs out; a 1998 handheld game has a fixed array of character
slots and a fixed hardware sprite budget, both decided long before anyone thought about
multiplayer. So "how many players can share a room" has a *per-game*, and often *per-map*, answer
that no amount of relay capacity changes.

**Ask it early.** It decides whether a game can host a crowd at all, what the adapter should do
when it cannot, and what a player is told when their friend is standing next to them and invisible.

## Method — measure it, don't reason about it

The rig that produced everything below, reusable for the next game:

1. **Generate real peers, not fake objects.** `meshghost-fakeadapter.exe` runs N synthetic clients
   in one process, each a genuine relay client sending genuine state:
   `-relay=127.0.0.1:7777 -room=default -game-id=<game> -area-id=<exactly what the adapter sends>
   -center=<player position> -radius=4 -dims=2 -clients=N -extras=@<file.json>`.
   This exercises the whole path — relay, core, bridge, adapter, engine — so the number that comes
   out is the number a real session would get. Poking objects straight into RAM would measure the
   engine and skip everything that decides whether the engine is ever asked.
   - `-extras` must be `@path` on Windows; a literal JSON argument gets mangled by shell quoting.
   - `-area-id` **must match what the adapter sends**, or every ghost is correctly despawned as
     "peer is somewhere else" and the measurement reads zero. Live case: walking into Elm's lab
     during a town-pinned flood emptied the screen instantly, which is the adapter being right.
   - The relay needs `-max-clients` raised (`80` here) and `-loopback` OFF, so the count is exact.
2. **Read the engine's own terms with a probe**: slots in use out of the array size, hardware
   sprite entries in use out of the hardware's, and how many ghosts the adapter actually spawned.
3. **Check the frame rate the same way**, by counting emulated frames over a wall-clock interval —
   "it looked fine" is not a measurement, and a game that quietly runs at 45fps is broken.
4. **Step the count up** (6, 12, 24, 36) and repeat **in more than one kind of map**. The answer
   changes with the map, and often changes for a different reason in each.

## Pokémon Crystal (Game Boy Color) — measured 2026-08-19

**Ceiling: 9 ghosts, in both maps tested, for two different reasons. Everything past that is
refused cleanly, and the emulator never leaves 60fps.**

| Where | Peers offered | Ghosts rendered | Object structs | Map objects | Hardware sprites | Frame rate |
|---|---|---|---|---|---|---|
| New Bark Town (outdoor) | 6 | 6 | 10 of 13 | 10 of 16 | 24–28 of 40 | 60fps |
| New Bark Town (outdoor) | 12 | **9** | **13 of 13 (full)** | 13 of 16 | 34–36 of 40 | 60fps |
| New Bark Town (outdoor) | 36 | **9** | **13 of 13 (full)** | 13 of 16 | 34–36 of 40 | **60fps** (600 frames / 10s) |
| Elm's lab (indoor) | 24 | **9** | 11 of 13 | **16 of 16 (full)** | **40 of 40 (saturated)** | **60fps** (600 frames / 10s) |

**The two pools, and which one runs out first.** Crystal has **13 object structs** and **16 map
objects** (`NUM_OBJECT_STRUCTS` / `NUM_OBJECTS`, from `pret/pokecrystal`'s
`constants/map_object_constants.asm`). Every map spends some of both on its own cast before a
ghost asks for one, and the two are not spent at the same rate:

- **Outdoors**, structs ran out first (13 of 13) while 3 map objects were still free — a struct is
  what an on-screen character needs.
- **Indoors**, map objects ran out first (16 of 16) while 2 structs were still free — the lab
  declares more map objects than it has characters visible at once.

So **the binding resource depends on the map**, and an adapter that reports only one of them will
sometimes say the wrong thing. That is why the "no room" log line names *which* pool ran out.

**Under both of those sits a hardware ceiling that no game can raise.** The Game Boy has **40
sprite entries** (`wShadowOAM`, `00:c400`–`00:c4a0`, 4 bytes each), and a raw dump showed each
overworld character using **exactly 4** of them, with every unused entry parked at `y=160`, one row
below the 144-line screen. **40 ÷ 4 = 10 characters on screen at once, ever** — player included.
In the lab the crowd pinned it at 40 of 40, i.e. the hardware completely saturated, and the user
confirmed **all ten still drew correctly, with no flicker or dropout**. (The Game Boy also drops
sprites past 10 *per scanline*; ten characters spread vertically never hit it. A row of characters
side by side would, and has not been tested.)

**What happens past the limit: nothing bad.** The extra peers are simply never given a body. With
36 peers offered against 9 slots, the game held 60fps exactly, no NPC was displaced or lost, and
nothing crashed. The adapter now logs it once a minute, naming the pool that ran out and how many
ghosts are present, because *"my friend is invisible"* and *"my friend is not connected"* look
identical from the player's chair.

**What this means for a real session.** Nine simultaneous visible peers on one map is far past
anything this project has planned, so Crystal's limit is not a constraint in practice — but it is
a *hard* one, and it arrives silently. A room of twelve players standing in one town would show
nine of each other, chosen by whoever arrived first.

## Pokémon Emerald (Game Boy Advance)

Measured separately in the same session; see the Emerald entry in `verified.md` and
`phases/phase8.md`. Emerald's array is `OBJECT_EVENTS_COUNT` and its hardware budget is the GBA's
128 OAM entries rather than the Game Boy's 40, so its ceiling is higher — but the same two-pool
shape applies, and the same method produces the number.

## For a new adapter

Put the answer in the adapter's `documentation.md` (it is a fact about the game, not a
compensation), and make the adapter **refuse cleanly and say so** rather than writing into a slot
it does not own. `adapters/_template/README.md` asks the question as part of bringing a game up.
