# Pokémon Emerald — flag register

**A Lua adapter has no compile step**, so nothing here is a `constexpr` and nothing is compiled
out. Its switches are three kinds instead: local `false` constants that gate a diagnostic, values
read from the environment (or from a global set by the dev loader) at load time, and a runtime
*condition* — whether the ROM is patched — that silently withdraws three capabilities. That last
one is the most important row in this file and the least switch-shaped.

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
| **the ROM-patch branch** | `avatarAddrOffset == 0` | **Vanilla-only capabilities.** Not a named flag — a comparison in the per-frame path — which is exactly why it is registered here. It no longer decides the RENDERER: the spawn path used to fall back to the `gui.drawPixel` overlay on a patched ROM because `gSprites`' relocation was unmeasured, and `probes/gsprites_scan_probe.lua` closed that 2026-08-19 by measuring it (`gSprites` does not move; `gObjectEvents` does). Both builds now spawn. What it still gates is the three things that read **our own build's** addresses and have no measured patched equivalent: the **hardware-sprite tier** (declines, its peers falling to the painted one), the **cave flash-window clip** (declines, so a painted ghost still shows through a dark cave on a patched seed), and the **fishing alignment hook** (`BANDAGES.md` entry 3). |
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
| `MESHGHOST_BRIDGE_PORT` | **global first, then environment** | unset — walk 7778-7785 | Pins the bridge port instead of walking. An explicit port is honoured and then *not* walked: someone who names a port means that port, and silently landing elsewhere would be worse than failing. **This row said "environment" until 2026-08-25, and the read order is the whole point of the flag**: an environment variable is fixed when BizHawk launches, while a global can be set by whatever loads the script, which is how a dev loader pins an *already-running* instance. Emerald read only the environment until 2026-08-19, and a session that pinned the port by global was silently port-walked into another instance's core and attached to it. Crystal's row has been right throughout. |
| `MESHGHOST_EMERALD_DRAWN_DELAY_FRAMES` | global first, then environment, a number | unset — **8** | **Behaviour, not a probe.** How many frames the drawn tier lags the spawned one, so the two copies of a peer do not disagree about where it is mid-step. A number rather than a bool, so it is worth saying that the default is a measured value and not a round guess — change it only against a measurement, and never as a way to paper over a motion defect (`CLAUDE.md`'s rule against offering a rate change as the answer). |
| `MESHGHOST_EMERALD_GHOST_ELEVATION` | global first, then environment, a number | unset — the ghost takes the peer's own elevation | **Probe.** Forces every ghost onto one elevation, so a peer can be put deliberately above or below the player to exercise the engine's own elevation rules — bridges, ledges, the layered parts of a route — without needing a second player who happens to be standing there. Writes a real object-event field, so it changes what the engine does, not just what is drawn. |
| `MESHGHOST_EMERALD_NO_COLLISION` | global first, then environment (any value) | unset — ghosts are solid | **Probe, dev only: a ghost you can walk through, using the engine's own rule** rather than by not spawning one. Exists because a solid loopback ghost stands in the player's way and ruins any test of motion — the same confound Crystal's `GHOSTS_PASSABLE` removes. **Announces `PROBE FLAG IN USE` at startup**, which is what makes it self-identifying as a registrable switch and is why it belongs in this table; it was live in the source and absent here until 2026-08-25. |
| `MESHGHOST_FISH_ALIGN_HOOK` | global — **set by the adapter, not by you** | unset | **Storage, not a switch**, registered because it meets this file's own criterion: it changes hook registration across reloads. It holds the id of the fishing-alignment frame hook so a reload can `unregisterbyid` the previous one instead of stacking a second copy — the same reason `MESHGHOST_CRYSTAL_FROZEN` is a bare global. Clearing it by hand orphans a live hook that nothing can then unregister; the cure is reloading the script, not setting this. |
| `MESHGHOST_LOOPBACK_TRAIL` | environment (any value) | unset — offset 2 tiles | Switches the loopback ghost from *offset* mode to *exact-trail* mode (offset 0). **Two genuinely different, both-valid loopback tests**, per the user: offset for judging rendering, animation and smoothing side by side, where an exact overlap makes the two impossible to tell apart; zero for verifying the ghost tracks the real position precisely, which an offset would hide. An environment variable rather than a code constant so switching costs a different `.local.bat` and not a script edit. |
| `MESHGHOST_LOOPBACK_OFFSET_X` / `_Y` | global | unset — `2` / `0` | **Probe.** Where the loopback ghost's SPAWNED copy stands, in tiles from the player, so a loader script can place the copies for one particular question without a restart — e.g. *"OAM directly above me, spawned one tile to my right"* while judging occlusion, where the default spread puts the three copies on different ground. `MESHGHOST_LOOPBACK_TRAIL` still wins over both: that is the exact-trail mode and an offset would defeat it. The OAM and painted copies are placed relative to this one, so moving it moves all three unless their own compare deltas are adjusted too. Never ship it set. |
| `MESHGHOST_COMPARE_TIERS` | **global first, then environment** (any value) | unset — off | **Probe, and the intended dev default for judging the drawn tier.** Renders the ONE loopback ghost **twice, in the same frame, from the same peer state**: spawned two tiles to the right, painted two tiles to the left. What the painted renderer is missing — engine occlusion, a cave's darkness, a water reflection, a doorway — is a question about a *place*, and flipping a flag between two runs cannot answer it because the place has changed by the time the other renderer is on. **Deliberately not gated on the overflow tier's own flag**: the point is to look at the drawn tier while it is shipped off, so with the tier off the loopback ghost is the only peer painted, and with it on it is painted in addition to the real overflow. It also ignores `MESHGHOST_LOOPBACK_TRAIL`'s zero offset — two ghosts on the player's tile is the comparison this exists to avoid. Never applies to a real peer: only `"<id>-ghost"` is duplicated. Announces itself as `PROBE FLAG IN USE` at startup, because two ghosts where a session expects one is otherwise indistinguishable from a duplicate-spawn bug. User's request, 2026-08-19. |
| `MESHGHOST_EMERALD_ANIM_TRACE` | **global first, then environment** (any value) | unset — off | **Probe.** Writes one line per frame per ghost to `probes/animtrace.log` carrying the PLAYER's sprite animation state and the GHOST's **together** — `animNum`/`animCmdIndex`, the paused byte `+0x2C`, the flags byte `+0x3F`, `pos2`, what arrived on the wire, and the real **OAM entry** (`0x07000000`) each sprite is actually drawn from. Both halves on one line is the point: the fishing misalignment was two consumers disagreeing about which frame a value belonged to, which is invisible in any trace that follows one side at a time, and the OAM columns are what finally settled it when every struct field agreed while the screen did not. Buffered and flushed every 120 lines — never `console.log`, which visibly lags the emulator, and never a per-frame `io.open`, which is itself heavy enough to change what it measures. **Deliberately NOT folded into `MESHGHOST_COMPARE_TIERS`**, where it was originally written: compare mode is the intended dev default for judging the drawn tier, so leaving per-frame file I/O inside it would tax every future comparison with a diagnostic nobody asked for. Kept rather than deleted because bikes and surfing are the same class of state (`adapters/_template/probes.md`). Announces itself as `PROBE FLAG IN USE` at load. Never ship it set. |
| `MESHGHOST_EMERALD_PROFILE` | **global** (any value) | unset — off | **Probe.** Times the Lua side of every frame plus five named sections (send/drain/sync/shadows/draw), reported to the console once per 300 frames with the window's WORST frame — the number that matches a felt stutter. Cost is a handful of `os.clock` calls per frame, cheap enough to leave on for a whole ride, but it still announces nothing and ships unset. What it can and cannot see is the point: a small number here with low fps means the cost is in the emulator core or another script, not this one — that distinction exonerated the BuildOamBuffer hook (2026-08-20, `pitfalls.md`). |
| `MESHGHOST_EMERALD_NO_FISH_HOOK` | **global** (any value) | unset — hook registers | **Probe.** Skips registering the BuildOamBuffer `event.onmemoryexecute` hook, so its emulator-core cost can be priced by A/B — an execute breakpoint can push a core onto a slow per-instruction path, a cost invisible to any Lua-side timer. Measured 2026-08-20: 52.0 avg fps without vs 52.6 with on the same scripted ride, so the hook is effectively free on this build and the flag stays off. Setting it in a real session costs the fishing alignment (`verified.md` 2026-08-19) for nothing. |
| `MESHGHOST_FORCE_GHOST_GFX` | **global first, then environment** | unset — no forcing | Forces every ghost to a given `graphicsId` regardless of what the peer reports, so the **asymmetric** case can be tested at all: loopback echoes your own state, so "a peer on a bike while you walk" cannot otherwise be produced without a second machine. Read as a global first because that is what makes it usable mid-session — the dev loader loads its targets in order, so a one-line script listed *before* the adapter changes the value on a reload, where an environment variable would need the whole emulator restarted. |
| `MESHGHOST_EMERALD_DRAWN_OVERFLOW` | **global first, then environment** | unset — **off**, so peers past the engine's cap are simply not shown | Turns on the **drawn overflow tier**: every peer the object array had no room for is painted with the `gui.*` pixel path instead of vanishing, which is what makes *"every player/ghost visible all the time"* possible at all (the engine holds 16 object events; a screen shows ~150 tiles). **Off by default for one specific reason, not for polish:** a drawn ghost is painted after the PPU has finished, so it has none of the engine's occlusion and would paint over a text box or the START menu. The panel region is now measured and clipped for (`tiering.scanPanel()` reads BG0's tilemap; text box = rows 14-19, START menu = rows 0-13 right-hand columns, measured 2026-08-19 with `probes/textbox_probe.lua`; the hardware-register route is the recorded dead end in `probes/uiregion_probe.lua`), and the first clip driven by that real detector was counted the same day — but it has not been repeated under controlled play, so the default stays off. See `BANDAGES.md`. Global first for the same reason as `MESHGHOST_FORCE_GHOST_GFX`: it can then be flipped by a one-line loader script without restarting the emulator. |
| `MESHGHOST_EMERALD_FAKE_PANEL_ROW` | **global first, then environment** | unset — no panel, nothing clipped | Pretends the game has drawn a UI panel starting at this screen row (0-19), so the drawn tier's **clipping** path can be exercised and watched without waiting for a real text box. Exists because the clip and the *detector* are separable: the clip is adapter logic that can be proved with a counter (row 0 clips every run — measured 2026-08-19, 1.1M runs skipped over 300 frames with 32 painted ghosts, and 0 with no peers), while the detector needs a real panel on screen. Never set in a shipped run. |
| `MESHGHOST_EMERALD_TEST_PEER` | **global first, then environment** | unset -- no synthetic peer | **Probe.** Injects one synthetic standing peer -- `"g:n,x,y"`, where `x` may be the literal `px` for the player's own column -- so CROSS-MAP rendering is testable without a second client: the loopback ghost always shares the player's map, so it can never stand on a connected neighbor. Placed 3 tiles past a seam it exercises translation, the existence margin, and both tiers' rendering of a peer the local map does not contain. **Set it to `off` (or `none`) to retire a peer already injected** -- needed because this flag is normally set in the EMULATOR'S PROCESS ENVIRONMENT at launch, which outlives every script reload, and `nil or os.getenv(...)` means a Lua global cannot clear it. Before 2026-08-21 the only way to remove the synthetic peer was to relaunch BizHawk, i.e. close the user's game. Retiring it drops the peer and both tiers reap it by their normal departing-player paths. Never ship it set: the peer it fabricates answers to nobody. |
| `MESHGHOST_EMERALD_HW_OVERFLOW` | **global first, then environment** | unset — **off**, so the ladder stays spawn → drawn as before | Turns on the **hardware-sprite tier**, the middle rung of `spawn → OAM → drawn`. Peers the engine had no object slot for are given real GBA hardware sprite entries in `gMain.oamBuffer[64..119]` — the range above `gOamLimit` that the engine's per-frame path never writes and its VBlank transfer carries to the hardware anyway (`documentation.md`; the game parks its own wireless indicator at entry 125 for the same reason). The PPU then draws them, so they get **background priority and the live palette for free** — the occlusion and the fades the painted tier has to fake or simply lacks. Measured 2026-08-21 (`verified.md`): 56 hardware sprites cost nothing against a bare-emulator control, where painting the same 56 costs a third of the frame rate; spawned at its cap plus this at its ceiling, 67 characters, still 60.0 fps. **Vanilla only** — an Archipelago ROM relocates data, so there the tier declines and its peers fall through to the painted one, exactly like a tile-allocation failure does. Off by default until the on-screen behaviour has been judged by a person, not because of cost. Global first so a loader script can flip it without restarting the emulator. |
| `MESHGHOST_EMERALD_HW_PRIORITY` | global | unset — **2**, the engine's own overworld sprite priority | **Probe.** Overrides the OAM tier's sprite priority AND suppresses its stand-down under a semi-transparent sheet, so the "just draw in front of the fog" option can be LOOKED AT rather than argued about. It exists because the underwater conclusion was reached once, underwater, and generalised too far: a `2026-08-21` run in Mt Pyre's fog at priority 1 put the ghost in front exactly as predicted, and showed the artifact is one opaque block of sheet **per entry rectangle** rather than a blend that cannot happen at all. Keep it for the next such effect — the answer is a look, not a derivation. Never ship it set: priority 1 also lifts ghosts above the background priority that gives this tier its occlusion for free, which is the whole reason the tier exists. | 
| `MESHGHOST_EMERALD_MAX_SPAWNED` | **global first, then environment** | unset — the real budget (`16 - the map's own cast - reserve`) | **Probe.** Caps how many peers may hold a real object slot, so everything past the cap falls to the DRAWN tier. Exists because proving the panel clipping needs a drawn ghost and a panel in the same frame, and reaching the real cap means ~14 synthetic peers — a second relay and a load generator for a question one peer can answer. Set it to `0` and the loopback ghost itself becomes the drawn tier's problem. Re-read every call, so it can be flipped mid-session from a one-line loader script. Never ship it set: it deliberately starves the tier that has the engine's animation, occlusion and collision. |
| `MESHGHOST_SCRIPT_DIR`, `MESHGHOST_SCRIPT_DIR_EMERALD` | the **global** `MESHGHOST_SCRIPT_DIR` first, then the game-specific environment variable, then the plain one | unset — the script finds itself with `debug.getinfo` | Overrides where the adapter thinks it lives, which decides where it loads LuaSocket from and writes its log. Loaded with `--lua=<path>` BizHawk reports `source` as `[string "main"]` rather than a path, so without this the `io.popen` last resort runs on every launch — the console-window flash. **Game-specific name first on purpose**: an environment variable is process-wide and BizHawk runs every Lua script in one process, so a plain `MESHGHOST_SCRIPT_DIR` set for one adapter is inherited by the next one loaded (found live 2026-08-18, both adapters in one emulator). Registered late (2026-08-19), matching Crystal's row. |
| `MESHGHOST_DEV_LOADER` | a **global**, set by `dev-scripts/bizhawk-dev-loader.lua` | unset — the adapter runs its own `while true ... emu.frameadvance()` loop | Decides who owns the frame loop. When the loader set it, the adapter publishes `MESHGHOST_DEV_TICK`/`MESHGHOST_DEV_UNLOAD` and lets the loader call it, so the script can be swapped and reloaded live; a player opening the file in the Lua Console sets neither global and gets the normal loop. Listed here because it is a global that changes control flow, which is exactly the shape this section exists to catch — not because a player would ever set it. |
| `MESHGHOST_GHOST_PEER_GFX` | global or environment | unset — **off, deliberately** | Opts in to drawing a peer with the peer's own graphic. **Off is not an oversight.** Every special state renders corrupted, confirmed on screen 2026-08-18, for a structural reason: normal Brendan/May is 16 px wide with one OAM and subsprite table, while both bikes, surfing, underwater and fishing are **32 wide** with different ones — and this code copies both pointers while also forcing `subspriteTableNum = 0`, a field the engine manages itself. Until that is solved, a peer's graphic is used only when it matches the local player's, which changes nothing visually but keeps the wire format and the plumbing exercised. |

**The pattern worth copying**, and the reason this section exists at all: a runtime switch can be
on without anyone choosing it — a variable exported in a shell and forgotten changes behaviour in a
build that looks identical. Prefer a default that *is* the shipping behaviour, and prefer the
global-then-environment shape when a switch needs to be flipped without restarting the emulator.

## When a comment and a value disagree

Believe the value, then find out why the comment drifted before changing either. `CLAUDE.md`
states the harder version: **a flag flip is not a revert** — a switch only reverts behaviour if it
gates the *work*, not merely the decision the work feeds.

## Added 2026-08-21 (water/warp session)

| Flag | Where | Default | What it does |
| --- | --- | --- | --- |
| `MESHGHOST_EMERALD_DRAWN_COMPARE_DX` | global | unset — **-2** | Where the PAINTED comparison copy stands, in tiles from the player. Exists because the three copies stand in three columns and a shoreline is not a straight line: to tell *"this renderer is wrong"* from *"this copy is standing further from the water"*, two copies have to be put on the same tile and compared there. **A probe, not behaviour** — it only moves a dev-only comparison ghost. |

**Changed defaults, same session:** `MESHGHOST_EMERALD_HW_COMPARE_DX` / `_DY` moved from `0,-2` to
**`-6,0`**. They are relative to the SPAWNED ghost, which stands at `(+2, 0)` from the player, so
the hardware copy now sits two tiles LEFT of the painted one with all three tiers in the player's
row. It was stacked above the spawned copy until the surf blob and the reflection landed on this
tier and there was something UNDER each character to look at — two tiles of separation put every
copy's blob and reflection on top of the one below it. User's call, and the reason is in the
table's own comment.

## Added 2026-08-21 (dive session)

| Flag | Where | Default | What it does |
| --- | --- | --- | --- |
| `MESHGHOST_EMERALD_NO_ANIM_RESTART` | **global or environment** | unset — restarts suppressed only inside the 30-frame post-swap cooldown | **Probe.** Forces the engine-animation-restart suppression EVERYWHERE, not just near a graphic swap. This is the subtraction experiment that proved the grey/flash scramble was the engine's restart copy tearing mid-frame (`pitfalls.md`, 2026-08-21); it survives as the flag because re-running that experiment is how a recurrence would be diagnosed. Set, every ghost pose is driven purely by the wire mirror's boundary-time loads — fishing's engine-driven cast animation stops advancing between wire updates, which is why it must never ship set. |

## Added 2026-08-21 (dive session, later)

| Flag | Where | Default | What it does |
| --- | --- | --- | --- |
| `MESHGHOST_EMERALD_NO_BLOB` | global | unset — blobs spawn | **Probe.** Spawn ghosts but give them no surf blob (and no underwater bobber, which no longer exists as a sprite). Written to bisect a hard failure: diving with the adapter loaded black-screened the GAME, and this separated "a spawned ghost" from "the field effects attached to one". Kept because that bisect — adapter, then tier, then effect — is the shape any future "our code broke the game" hunt should take. Never ship it set: a surfing ghost without its blob is half a state. |
| `MESHGHOST_EMERALD_NO_BOBBER` | global | unset | **Probe.** Splits the pair above, so the surf blob and the underwater bobber can be told apart. It was the bobber, and it is gone entirely now (`spawnUnderwaterBobber`'s header); the flag survives because the split is the method, not the fix. |

## The tier ladder, and its one place-specific exception (2026-08-21)

| Where | Ladder |
| --- | --- |
| Everywhere | **spawn → OAM → drawn** |
| Under a screen-covering semi-transparent sheet — weather fog, underwater | **spawn → drawn** (the OAM rung declines) |

The hardware tier stands down wherever the engine is tiling the screen with semi-transparent
sprites, and this is a limit rather than a switch. Its entries live at OAM 64+, where ties at equal
priority are broken by entry number, and the engine's sheet sits at low entries at priority 2
(measured: twelve 64×64 objMode-1 sprites at entries 3–17 in Mt Pyre's fog, twenty underwater).
At normal priority nothing this tier draws can appear.

**Raising the priority does not rescue it, and the reason is worth keeping.** Priority is compared
before the entry number, so priority 1 does put our entries in front and the ghost appears — with
an opaque block of sheet over **each of our entries' own rectangles**: one 16×32 box in fog, and a
roughly 3×3-tile union underwater where the graphic is wider and the tier places more entries per
peer. The engine's own characters are in front of the same sheet with no artifact, so this is not
"a semi-transparent sprite cannot blend against another sprite" — that earlier reading was wrong.
They win at **equal priority on a lower entry number**, which changes nothing about the layer the
sheet blends against; outranking it on priority does, and the blend fails. Entries 0–63 are the
engine's own sprite list, rebuilt and blanked every frame, so that route is not open to us.

**The test is the screen, not the place** (`chooseHardware`): a count of objMode-1 sprites among
the engine's entries, four or more meaning covered. It was originally a test for *underwater*,
which is where it was found — and Mt Pyre's fog then reproduced the same bug on dry land, because
weather is not a place. Its peers become the painted tier's, which is drawn after the frame and
subject to none of this, so coverage is unchanged.
