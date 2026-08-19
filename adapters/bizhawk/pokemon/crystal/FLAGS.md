# Pokémon Crystal — flag register

**A Lua adapter has no compile step**, so this adapter has no compile-time bools at all. Every
switch it has is a **runtime** one — an environment variable, a global set before the script is
`dofile()`'d, or a file sitting beside the script — and that makes the register more important
here, not less: a compile-time probe is compiled out of a shipped build, while a flag file only
needs someone to forget.

**This adapter writes game RAM** (object RAM only, never a save), so one of its switches lowers a
safety bar. It is `MESHGHOST_CRYSTAL_AP_TRY`, and it is the first row below for that reason.

It is not a description of how the game works — that is `documentation.md` — and not a list of
compensations, which is `BANDAGES.md`. A switch can appear in both; this one says what it is, that
one says what it costs.

**Everything here lives in `meshghost_crystal.lua`.** The probes have their own switches,
documented in each probe's header and indexed in [probes/README.md](probes/README.md).

## Runtime switches

| Switch | How it is set | Default when unset | What it does |
|---|---|---|---|
| `MESHGHOST_NO_AUTOSTART` | environment (any value) | unset — the adapter starts a core itself | Turns autostart OFF, so the adapter uses only a core that is already running and never spawns one. **Supported configuration, not a debug switch**: an antivirus objecting to one program launching another is a real thing that happens to real players, and this is the documented answer — set it and run `meshghost.exe` by hand. Every adapter honours the same name. |
| `MESHGHOST_CRYSTAL_AP_TRY` | `=1` in the environment, **or** a file named `ap_try.flag` beside the script | unset — a missing address **refuses to run** | **Lowers the bar from *measured* to *unconfirmed*, never to *invented*.** On a ROM build whose address table still has a `nil`, this substitutes a **named candidate** from that table's own `candidates` list and logs `UNCONFIRMED ADDRESS IN USE` on every startup, so a session run this way can always be told apart from a measured one afterwards. A missing *candidate* still refuses. Two ways to set it because an environment variable needs a BizHawk restart and the emulator is usually already running by the time anyone decides to try; **deleting the file is how the experiment ends** -- or, better, RENAME it to `ap_try.flag.off`, which parks it inertly right where you will look for it next time instead of making you re-create it from memory. `.gitignore` covers both names; `release.yml` checks only the exact live name, so a parked flag cannot fail a build. It also turns on a twice-a-second gate diagnostic that prints what the gate decided *and what it decided from*. **`release.yml` fails the build outright if `ap_try.flag` reaches the package** — the flag is gitignored, so that check exists to catch a stray local copy. |
| `MESHGHOST_CRYSTAL_STRICT` | `=1` in the environment | unset — an untested ROM runs on vanilla's table after saying so in its first log line | Turns "untested build, running anyway" into a refusal. The permissive default is the user's call (2026-08-18): every non-vanilla ROM is attempted, and a wall of caution on each startup is noise. The one line still earns its place by **identifying** the build, so a misbehaving ghost has its ROM named at the top of the log. |
| `MESHGHOST_CRYSTAL_STATUS_ADDR` | environment, a number | `0x1439` on the Archipelago table | Overrides the Archipelago build's `wMapStatus` candidate so two addresses can be compared in one session. It exists because this address has a live history worth not repeating: `0x0FB1` survived two snapshot runs, then a live run showed it flickering between 2 and 1 several times a second while standing still — the snapshots had only ever agreed because they sampled while phase-locked. `0x1439` held `2` across 1103 samples of walking. **The gate needs the behaviour, not the name**; do not "correct" this to a tidier address on the strength of a published label. |
| `MESHGHOST_BRIDGE_PORT` | global first, then environment | unset — walk 7778-7785 | Pins the bridge port instead of walking it. An explicit port is honoured and then *not* walked: someone who names a port means that port, and silently landing somewhere else would be worse than failing. Readable as a global so a second instance can get its own port without restarting an already-open emulator. |
| `MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE` | global first, then environment, a sprite id | unset — a ghost wears whatever the peer sent, falling back to the local player's sprite | **Probe, not behaviour.** Substitutes one sprite id for *every* peer, so "can a ghost wear a sprite this machine's player is not wearing" can be asked with one emulator and no peer of the other gender. Pick an id the current map has **resident** (`wUsedSprites`) — a non-resident id changes nothing by design, and that is the fallback working rather than the flag failing. Used on 2026-08-19 to establish the sprite id -> VRAM tile lookup: the ghost took `SPRITE_RIVAL`'s id and tile, matching byte for byte the engine's own object wearing that sprite. |
| `MESHGHOST_CRYSTAL_DRAW_OVERFLOW` | global first, then environment; `"0"` disables | unset — **ON** | **The drawn-overflow tier**, registered as a shipped compensation in [BANDAGES.md](BANDAGES.md). Peers the engine has no room for are painted over the emulator instead of not existing. **Default ON, where Emerald's equivalent is default OFF** — deliberate: Crystal's UI regions are locatable (a text box is the game's own frame tiles in the tilemap, a menu publishes `wMenuBorder*`), so a drawn ghost can be clipped out of them; Emerald's are not, so its tier would paint over text. |
| `MESHGHOST_SCRIPT_DIR`, `MESHGHOST_SCRIPT_DIR_CRYSTAL` | global first, then environment | unset — the script finds itself with `debug.getinfo` | Overrides where the adapter thinks it lives, which decides where it loads LuaSocket and writes its log. Set by whatever launched the script when it knows better. Registered late (2026-08-19) after an audit found it unregistered in both Lua adapters. |
| `MESHGHOST_DEV_LOADER` | global, set by `dev-scripts/bizhawk-dev-loader.lua` | unset — the adapter takes the frame loop | **Decides who owns the frame loop.** Set, the adapter hands its per-frame function to the loader instead of running `while true ... emu.frameadvance()`. Development only, and never set in a shipped configuration — the loader is not shipped. Emerald's register already carried this row; Crystal's did not until 2026-08-19. |
| `MESHGHOST_LOOPBACK_OFFSET_X` | global first, then environment | **`0`** | Dev-only, in tiles. **Crystal's default is 0 where the other three adapters ship a non-zero offset, and that is deliberate**, not an omission: this ghost is a real object event with real collision, so an offset is about not standing inside something solid rather than about telling two sprites apart. Set it to 1-2 for a side-by-side render comparison; leave it at 0 for a real two-machine session, where a peer's position is already their own. |

**No compile-time flags.** Two things do print in a normal run, both deliberately: the
experiment-mode gate line (gated behind `AP_TRY`, so silent unless asked for), and the drawn
tier's once-a-second summary of how many peers it painted and why the rest were not — which exists
because "half the screen is empty" needed a number separating "the peers never arrived" from "they
arrived and were not drawn" (2026-08-19).

## Behaviour — constants that decide what a player sees

| Constant | Value | What it decides |
|---|---|---|
| the address table | one per ROM build | **The biggest switch in the file, and it is a table rather than a flag.** `classifyRom()` picks `vanilla` or `archipelago` from the header title before anything reads or writes memory. Vanilla's entries come from our own hash-verified `pokecrystal` build; Archipelago's were each *measured*, because the patch moves WRAM non-uniformly (+7 for the coordinate block, +6 for the object array, −0x2A for the map-object table) and no constant offset recovers vanilla's. **A `nil` entry is a refusal, never a fallback** — falling back to vanilla's value for one entry would let the gate pass on a byte meaning something else and start writing object RAM at addresses nobody checked. `W_BATTLEMODE` on the Archipelago table is still `nil`. |
| `HARDWARE_CHARACTER_LIMIT` | `10` | **The Game Boy's own ceiling**, not a preference: 40 sprite entries at 4 per overworld character. The adapter stops spawning there, so nothing it draws flickers, and peers past it go to the drawn tier. |
| `RESERVED_STRUCTS_FOR_THE_GAME` | `3` | Object structs ghosts may never take, so the game's own cast always has somewhere to go. Fixes a measured failure: a crowd of peers held 11 of 13 structs and an NPC one tile from the player was simply not drawn. |
| `GHOST_RANGE_TILES` | `8` | Beyond this a ghost gives its slots back, which is what the engine's own characters do. Also why an off-screen peer no longer blocks a tile you cannot see. |
| `IDLE_FRAMES_BEFORE_PASSABLE` / `PUSH_FRAMES_BEFORE_PASSABLE` | `300` / `30` | The collision policy, the user's design: a peer that has not CHANGED TILE for five seconds stops blocking (turning on the spot is not activity), and a peer somebody is shoving into stops blocking in half a second — which is how doorways clear without the adapter knowing where the doors are. |
| the first-2px step application | `±2` px | **A shipped compensation**, and registered as such in `BANDAGES.md`. The engine applies its own first pixel increment in the frame it initiates a step; ours starts a frame later, so without this every step lands 2 px short and the error accumulates. |
| `FLAG1_WONT_DELETE` | `0x02` | Set on every ghost, or the engine culls it as soon as it leaves the visible window. A fact about the game (`documentation.md`), not a dial. |
| `STANDING` / `MAPSTATUS_HANDLE` / `UNASSIGNED` | `255` / `2` / `0xFF` | Observed engine values. Changing one asserts a different fact about the game. |
| `GAME_ID` / `GAME_VERSION` | `"crystal"` / `"phase9"` | Protocol identity. `GAME_ID` must match the release's `games/pokemon/crystal/` folder name. |
| `DOMAIN` / `ROM_DOMAIN` | `"WRAM"` / `"ROM"` | Which BizHawk memory domain the adapter reads and writes. `System Bus` and `WRAM` were confirmed to reach the same bank-1 bytes and agree exactly (`domain_probe.lua`); `WRAM` is the one used. |
| `BRIDGE_HOST` | `"127.0.0.1"` | Fixed on purpose. An adapter may hold a socket to its own local core and nothing else. |
| `BRIDGE_BASE_PORT` / `BRIDGE_PORT_COUNT` | `7778` / `8` | The port walk, so two copies of the game on one machine each find their own core rather than silently sharing one. Shape copied from Pseudoregalia's `BridgeClient`, which is the version that has been tested. |
| `HELLO_ANSWER_FRAMES` | `90` (1.5 s) | **Silence is not acceptance.** Something that accepts a connection and never answers is far more likely an unrelated program holding a port in our range than a core, and committing to it would strand the session with no ghosts and no explanation. |
| `BUSY_PORT_COOLDOWN_FRAMES` | `600` (10 s) | A port whose core answered "busy" is a live core that simply is not ours; re-probing it every sweep is noise. |
| `RECONNECT_FRAMES` | `120` (2 s) | Retry cadence for a dropped bridge. |

## When a comment and a value disagree

Believe the value, then find out why the comment drifted before changing either. `CLAUDE.md`
states the harder version: **a flag flip is not a revert** — a switch only reverts behaviour if it
gates the *work*, not merely the decision the work feeds.
