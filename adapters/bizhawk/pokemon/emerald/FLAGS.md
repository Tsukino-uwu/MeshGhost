# Pokémon Emerald — flag register

**A Lua adapter has no compile step**, so nothing here is a `constexpr` and nothing is compiled
out. Its switches are three kinds instead: local `false` constants that gate a diagnostic, values
read from the environment (or from a global set by the dev loader) at load time, and a runtime
*condition* — whether the ROM is patched — that silently selects between two entirely different
rendering paths. That last one is the most important row in this file and the least switch-shaped.

It is not a description of how the game works — that is `documentation.md` — and not a list of
compensations, which is `BANDAGES.md`. A switch can appear in both; this one says what it is, that
one says what it costs.

**Everything here lives in `meshghost_emerald.lua`.** Probe scripts have their own switches, and
they are documented in each probe's own header and indexed in
[probes/README.md](probes/README.md).

**Keep it in step with the code.** Add a switch, add its row. Change a default, fix its row in the
same edit.

## The kinds

| Kind | Shipped value | What it means |
|---|---|---|
| **Behaviour** | live | Real shipped behaviour. Changing it changes what a player sees. |
| **Probe** | `false` | A diagnostic. Off in every build a user runs. |
| **Runtime** | a default | Set by an environment variable or a loader-set global, for development only. |

There are no Dormant entries: retired approaches in this adapter were removed rather than gated.

## Behaviour — including the one that is not written as a switch at all

| Switch | Value | What it decides |
|---|---|---|
| **the ROM-patch branch** | `avatarAddrOffset == 0` | **Spawn where we can, draw where we cannot.** On a vanilla ROM a peer is a real spawned object event and the engine draws it; on an Archipelago-patched ROM the adapter falls back to the `gui.drawPixel` overlay. It is not a named flag — it is a comparison in the per-frame path — which is exactly why it is registered here. The reason is asymmetric risk: `gObjectEvents`' relocation under the patch is measured and applied, `gSprites`' is **not**, and a wrong *read* returns a wrong number while a wrong *write* corrupts whatever now occupies that address. `BANDAGES.md` carries it as a deliberate, temporary split; measuring the `gSprites` shift is what would close it. |
| `LOOPBACK_GHOST_OFFSET_TILES_X` | `2` (or `0`, see Runtime) | Dev-only, render-only sideways offset for a loopback ghost, so the echo of your own state can be told apart from your character. Never touches what goes on the wire. |
| `LOOPBACK_GHOST_OFFSET_TILES_Y` | `0` | Kept at zero deliberately: a same-row offset is what makes step timing comparable. |
| `GHOST_LOCAL_ID` | `255` (`LOCALID_PLAYER`) | **Load-bearing twice over, and neither reason is cosmetic.** It makes a ghost non-interactable *using the engine's own check* — `GetInteractedObjectEventScript` returns NULL outright for this id — which fixed a real bug found live 2026-08-18: talking to a ghost resolved a script through the map's template table, found nothing (a ghost has no template), and ran whatever was at that address, dumping the user into the slot-machine minigame. It is also the identity marker: "active, not the player, and this `localId`" is a state only our ghosts can be in, which is what stops an orphan sweep deactivating a real NPC after a map rebuild. See `_template/README.md`, "'The map changed' and 'the world was rebuilt' are different events". |
| `STEP_DURATION_FRAMES` | `walking = 16`, `running = 8` | Measured step lengths, used to interpolate a peer between tiles. Facts about the game, not dials — `documentation.md`. |
| `GAME_ID` / `ADAPTER_VERSION` | `"emerald"` / `"phase8-spawn"` | Protocol identity. `GAME_ID` must match the release's `games/pokemon/emerald/` folder name. |
| `BRIDGE_HOST` | `"127.0.0.1"` | Fixed on purpose. An adapter may hold a socket to its own local core and nothing else. |
| `BRIDGE_BASE_PORT` / `BRIDGE_PORT_COUNT` | `7778` / `8` | The adapter walks ports 7778-7785 for a core that will have it, so a second copy on one machine finds its own. |
| `HELLO_ANSWER_FRAMES` / `BUSY_PORT_COOLDOWN_FRAMES` | `90` (1.5 s) / `600` (10 s) | **Silence is not acceptance.** Something that accepts a connection and never answers is far more likely an unrelated program than a core; a port whose core said "busy" is re-probed only after a cooldown. |

**Addresses are not switches.** The file's many `*_ADDR` constants are cited facts from the
`pokeemerald` decompilation, each traceable per `CLAUDE.md`'s no-addresses-from-memory rule.
Changing one asserts a different fact about the ROM. They are not listed here; the citations live
at the constants and in `agent_docs/verified.md`.

## Probes — off, and they must stay off

The convention is a `DIAG_` prefix, matching TEVI's `DIAG_REDRAW_TRACE` and Pseudoregalia's
`_TRACE` family. Both of these are `false` and both carry a log budget, because an unbudgeted
per-frame log in an emulator adapter is the cheap way to make a session useless.

| Flag | Value | Budget | What it was for |
|---|---|---|---|
| `DIAG_STEP_CURVE` | `false` | `DIAG_STEP_CURVE_MAX_LOGS = 3600` | Logs our synthetic glide curve beside the real sprite's own pixel motion, frame by frame, to chase a live-reported "single-tile walk looks slightly off, with a snap at the end of the step". Gated to genuine glides only — a gate added because logging non-movement frames wasted the whole budget on a non-event. The budget is a full minute of real step-frames, deliberately generous so there is no rush between reloading the script and moving. |
| `DIAG_SCREENPOS_PARTS` | `false` | `DIAG_SCREENPOS_PARTS_MAX_LOGS = 200` | Breaks `playerScreenPos()` into its components, for the same investigation from the other end. |

**A diagnostic can break the thing it measures**, and here the specific hazard is the emulator's
script host: it charges per call across a managed boundary, so a scan that reads as one expression
is thousands of calls per frame. It does not error — it stalls, and you get **no log at all**,
which reads as "the probe found nothing" rather than "the probe never ran". Budget a probe's reads
before running it; `_template/probes.md` has the cheapest-first list.

## Runtime switches — environment variables and loader globals

All but `MESHGHOST_NO_AUTOSTART` are **development-only**; that one is a supported player
setting. None is set in a shipped release, and each falls back to a
default that is the shipping behaviour.

| Switch | How it is set | Default when unset | What it does |
|---|---|---|---|
| `MESHGHOST_NO_AUTOSTART` | environment (any value) | unset — the adapter starts a core itself | Turns autostart OFF, so the adapter uses only a core that is already running and never spawns one. **Supported configuration, not a debug switch**: an antivirus objecting to one program launching another is a real thing that happens to real players, and this is the documented answer — set it and run `meshghost.exe` by hand. Every adapter honours the same name. |
| `MESHGHOST_BRIDGE_PORT` | environment | unset — walk 7778-7785 | Pins the bridge port instead of walking. An explicit port is honoured and then *not* walked: someone who names a port means that port, and silently landing elsewhere would be worse than failing. |
| `MESHGHOST_LOOPBACK_TRAIL` | environment (any value) | unset — offset 2 tiles | Switches the loopback ghost from *offset* mode to *exact-trail* mode (offset 0). **Two genuinely different, both-valid loopback tests**, per the user: offset for judging rendering, animation and smoothing side by side, where an exact overlap makes the two impossible to tell apart; zero for verifying the ghost tracks the real position precisely, which an offset would hide. An environment variable rather than a code constant so switching costs a different `.local.bat` and not a script edit. |
| `MESHGHOST_FORCE_GHOST_GFX` | **global first, then environment** | unset — no forcing | Forces every ghost to a given `graphicsId` regardless of what the peer reports, so the **asymmetric** case can be tested at all: loopback echoes your own state, so "a peer on a bike while you walk" cannot otherwise be produced without a second machine. Read as a global first because that is what makes it usable mid-session — the dev loader loads its targets in order, so a one-line script listed *before* the adapter changes the value on a reload, where an environment variable would need the whole emulator restarted. |
| `MESHGHOST_EMERALD_DRAWN_OVERFLOW` | **global first, then environment** | unset — **off**, so peers past the engine's cap are simply not shown | Turns on the **drawn overflow tier**: every peer the object array had no room for is painted with the `gui.*` pixel path instead of vanishing, which is what makes *"every player/ghost visible all the time"* possible at all (the engine holds 16 object events; a screen shows ~150 tiles). **Off by default for one specific reason, not for polish:** a drawn ghost is painted after the PPU has finished, so it has none of the engine's occlusion and would paint over a text box or the START menu. The region those panels occupy has to be MEASURED on this game before this can ship on — see `BANDAGES.md` and `probes/uiregion_probe.lua`. Global first for the same reason as `MESHGHOST_FORCE_GHOST_GFX`: it can then be flipped by a one-line loader script without restarting the emulator. |
| `MESHGHOST_EMERALD_FAKE_PANEL_ROW` | **global first, then environment** | unset — no panel, nothing clipped | Pretends the game has drawn a UI panel starting at this screen row (0-19), so the drawn tier's **clipping** path can be exercised and watched without waiting for a real text box. Exists because the clip and the *detector* are separable: the clip is adapter logic that can be proved with a counter (row 0 clips every run — measured 2026-08-19, 1.1M runs skipped over 300 frames with 32 painted ghosts, and 0 with no peers), while the detector needs a real panel on screen. Never set in a shipped run. |
| `MESHGHOST_EMERALD_MAX_SPAWNED` | **global first, then environment** | unset — the real budget (`16 - the map's own cast - reserve`) | **Probe.** Caps how many peers may hold a real object slot, so everything past the cap falls to the DRAWN tier. Exists because proving the panel clipping needs a drawn ghost and a panel in the same frame, and reaching the real cap means ~14 synthetic peers — a second relay and a load generator for a question one peer can answer. Set it to `0` and the loopback ghost itself becomes the drawn tier's problem. Re-read every call, so it can be flipped mid-session from a one-line loader script. Never ship it set: it deliberately starves the tier that has the engine's animation, occlusion and collision. |
| `MESHGHOST_DEV_LOADER` | a **global**, set by `dev-scripts/bizhawk-dev-loader.lua` | unset — the adapter runs its own `while true ... emu.frameadvance()` loop | Decides who owns the frame loop. When the loader set it, the adapter publishes `MESHGHOST_DEV_TICK`/`MESHGHOST_DEV_UNLOAD` and lets the loader call it, so the script can be swapped and reloaded live; a player opening the file in the Lua Console sets neither global and gets the normal loop. Listed here because it is a global that changes control flow, which is exactly the shape this section exists to catch — not because a player would ever set it. |
| `MESHGHOST_GHOST_PEER_GFX` | global or environment | unset — **off, deliberately** | Opts in to drawing a peer with the peer's own graphic. **Off is not an oversight.** Every special state renders corrupted, confirmed on screen 2026-08-18, for a structural reason: normal Brendan/May is 16 px wide with one OAM and subsprite table, while both bikes, surfing, underwater and fishing are **32 wide** with different ones — and this code copies both pointers while also forcing `subspriteTableNum = 0`, a field the engine manages itself. Until that is solved, a peer's graphic is used only when it matches the local player's, which changes nothing visually but keeps the wire format and the plumbing exercised. |

**The pattern worth copying**, and the reason this section exists at all: a runtime switch can be
on without anyone choosing it — a variable exported in a shell weeks ago changes behaviour in a
build that looks identical. Prefer a default that *is* the shipping behaviour, and prefer the
global-then-environment shape when a switch needs to be flipped without restarting the emulator.

## When a comment and a value disagree

Believe the value, then find out why the comment drifted before changing either. `CLAUDE.md`
states the harder version: **a flag flip is not a revert** — a switch only reverts behaviour if it
gates the *work*, not merely the decision the work feeds.
