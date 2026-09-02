-- MeshGhost — Pokémon Crystal adapter
--
-- *** WRITES GAME RAM. *** Object RAM only, never a save, cosmetic only, vanilla Crystal V1.0
-- only. See agent_docs/architecture.md's 2026-08-17 ADR, and the ROM guard below.
--
-- WHAT MAKES THIS DIFFERENT FROM EMERALD'S ADAPTER
-- Emerald draws its ghost over the emulator with gui.* and a hand-rolled sprite decode. This one
-- SPAWNS A REAL IN-GAME OBJECT EVENT and lets Crystal render, animate and move it. The adapter
-- draws nothing, animates nothing and interpolates nothing.
--
-- The recipe below was established across Phase 9 and every step of it cost a live test; the full
-- derivation is in agent_docs/phases/phase9.md and the evidence in verified.md. In short:
--   * Copy a live NPC as the template, never the player (the player's MOVEMENT_TYPE means "driven
--     by input", so the engine leaves it to the input system).
--   * Cross-link map object <-> object struct.
--   * Take the PLAYER's sprite/tile/palette for appearance -- resident on every map, so no VRAM
--     allocation is needed, and the correct gender comes along for free.
--   * COMPUTE the screen coordinates; never copy them.
--   * Set WONT_DELETE, or the engine culls the ghost when it leaves the visible window.
--   * To move: write the step-initiation set once per tile while idle, and apply the first 2px
--     yourself -- the engine applies its first increment in the initiating frame and ours would
--     otherwise land 2px short, every step, cumulatively.
--
-- HOW TO RUN
--   1. Start a core (dev-scripts), or let one already be running.
--   2. Load the Crystal ROM in BizHawk, be in the overworld.
--   3. Lua Console -> Script -> Open, pick this file.
--      Log: meshghost_crystal_<timestamp>.log beside this script.

local GAME_ID = "crystal"
local GAME_VERSION = "phase9"

local BRIDGE_HOST = "127.0.0.1"

-- PORT WALK. A core serves exactly ONE adapter (agent_docs/contract.md): a second bridge
-- connection is answered with `reject` and closed. Two copies of one game on one machine is a
-- normal thing to do -- it is how most of this project's adapters were tested -- so an adapter
-- that takes a single fixed port makes the second copy either fail or, worse, silently share the
-- first core. Instead: probe 7778 upward and take the first core that answers `bridge_ready`.
-- Shape copied from Pseudoregalia's BridgeClient, which is the version that has been tested,
-- including the three things it got wrong first (see adapters/_template/PROTOCOL.md).
local BRIDGE_BASE_PORT = 7778
local BRIDGE_PORT_COUNT = 8

-- An explicit port is still honoured and then NOT walked: someone who names a port means that
-- port, and silently landing somewhere else would be worse than failing.
local BRIDGE_PORT_OVERRIDE = tonumber(MESHGHOST_BRIDGE_PORT or os.getenv("MESHGHOST_BRIDGE_PORT") or "")

local RECONNECT_FRAMES = 120
-- How long to leave a core alone after it says it cannot reach the relay. Long enough that the
-- adapter is not hammering a dead relay, short enough that a relay coming back is noticed within
-- a few seconds. 600 frames = 10s.
local RELAY_DOWN_BACKOFF_FRAMES = 600
-- Silence is NOT acceptance. Something that accepts a connection and never answers is far more
-- likely an unrelated program holding a port in our range than a core, and committing to it
-- strands the session with no ghosts and no explanation. 90 frames = 1.5s, matching Pseudoregalia.
local HELLO_ANSWER_FRAMES = 90
-- A port whose core said "busy" is a live core that simply is not ours; re-probing it every sweep
-- is noise. 600 frames = 10s.
local BUSY_PORT_COOLDOWN_FRAMES = 600

-- DEV-ONLY loopback offset, in tiles. A loopback relay echoes your own state back to you, so
-- without this the ghost spawns on the tile you are standing on — and this ghost is a real object
-- event with real collision, so that means standing inside something solid.
--
-- Offset to the SIDE rather than trailing behind, so the ghost can be compared against the real
-- character rather than hidden by it (user's standing preference for test ghosts). Default 2, the
-- same as Emerald's LOOPBACK_GHOST_OFFSET_TILES_X -- the user asked for Crystal to match it after
-- a side-by-side run of both on 2026-08-25: an exact trail hides the ghost behind the character,
-- which is the thing being judged. MESHGHOST_LOOPBACK_TRAIL (set to anything) forces 0 for the
-- exact-trail mode, same env-var name and meaning Emerald uses.
--
-- Applied ONLY to the "<id>-ghost" loopback echo, at its one use site -- a real peer's position is
-- already their own and must never be moved. That gate is why this can carry a nonzero default at
-- all; before it, 0 was the only value safe for a two-machine session.
-- Each of these can also be set as a GLOBAL before this file is dofile()'d, which is how a second
-- instance gets a different bridge port without restarting an already-open emulator to change an
-- environment variable. See run_second_client.lua.
local LOOPBACK_OFFSET_X = (os.getenv("MESHGHOST_LOOPBACK_TRAIL") and 0)
	or tonumber(MESHGHOST_LOOPBACK_OFFSET_X or os.getenv("MESHGHOST_LOOPBACK_OFFSET_X") or "") or 2

-- SIDE-BY-SIDE TIER COMPARISON (dev only, off by default) -- MESHGHOST_COMPARE_TIERS.
--
-- The loopback ghost is rendered TWICE from the same peer state: SPAWNED two tiles to the right,
-- where the engine draws it and gives it occlusion, palettes and whatever a cave or water does to
-- a character for free; PAINTED two tiles to the left, where it gets none of that unless we built
-- it. What the drawn tier is missing is a question about a place -- a dark cave, a water
-- reflection, a doorway -- and no amount of flag-flipping between two runs answers it, because
-- the place is gone by the time the other renderer is on. Both at once, in one frame, does.
--
-- The user's request and the intended dev default for eyeballing a BizHawk drawn tier,
-- 2026-08-19. It applies ONLY to the "<id>-ghost" loopback echo -- a real peer is never
-- duplicated -- and it supplies its own +2 for the spawned side when no offset was set, since two
-- ghosts stacked on the player is the comparison this exists to avoid.
local COMPARE_TIERS = (MESHGHOST_COMPARE_TIERS or os.getenv("MESHGHOST_COMPARE_TIERS")) and true or false
-- THE SHIPPED TIER IS DRAWN ONLY (user's call, 2026-09-02). The spawned tier -- a real object
-- event the engine walks -- stays in the file as a DEV opt-in: MESHGHOST_CRYSTAL_SPAWN_TIER=1,
-- or compare mode, whose whole point is the two tiers side by side. Why drawn, for THIS game and
-- not Emerald: on the first run after ADR 0044 the user watched the spawned ghost snap a little
-- whenever IT crossed a map seam ahead of or behind the player, and the painted one walk the same
-- seam clean; the painted tier also keeps a faster-cartridge peer at the right speed where the
-- engine cannot, never flaps between tiers mid-walk, and has no engine slot to run out of (Route
-- 39 leaves 2). What it gives up is the engine's own collision and scenery ordering, which the
-- shipped cosmetic default never promised. Cost is not the reason either way: 12 painted peers
-- measure the same as an empty screen (`crowd-limits.md`). Emerald keeps spawned -> OAM -> drawn
-- because there the drawn tier IS the expensive one. Registered in FLAGS.md. It lives as
-- `COMPARE.spawnTier` (below, beside the tier layout) and not as a local of its own: this main
-- chunk is AT Lua's 200-local limit -- `luac` refused the 201st on 2026-09-02.
-- MESHGHOST_CRYSTAL_STEP_LAG — WHERE THE SPAWNED GHOST'S 4.3 FRAMES GO. Off by default.
--
-- 2026-08-22 measured that a spawned ghost begins each step a mean 4.3 frames after the peer did
-- (worst 15), and attributed 1.5 of it to the wire and "the rest" to this adapter's own pipeline.
-- "The rest" is not something that can be fixed: it is three delays added together, and they have
-- three different answers. This separates them, on loopback, where the peer IS the player and
-- every frame involved is therefore knowable:
--
--   COMMIT   the frame the PLAYER's own object took the tile. MAP_X/Y are written at the START of
--            a step (stepGhost's own note depends on it), so this is the instant of commitment.
--   ARRIVE   the frame that same tile came back to us through the core.       wire  = ARRIVE-COMMIT
--   ISSUE    the frame stepGhost actually wrote the step.                     apply = ISSUE-ARRIVE
--                                                                             total = ISSUE-COMMIT
--
-- The engine acts on our write during the FOLLOWING frame, so what the eye sees is total + 1.
--
-- `blocked` is the one nameable reason `apply` is ever above zero: renderRemote refuses to touch a
-- ghost that is mid-step, so a tile arriving during the ghost's own walk waits for it to finish.
-- Counted per waiting frame. If `apply` is large while `blocked` stays near zero, the wait is
-- somewhere this is not looking -- which is the most useful thing it can say, because every fix
-- currently on the table assumes otherwise.
--
-- READ-ONLY: it writes no game memory and changes no decision. It costs two table lookups per
-- frame and one per arrival, which is why it is still gated -- `_template/probes.md`, a diagnostic
-- can break the thing it measures.
--
-- One table, not eight names: this file sits at Lua's 200-local limit (see COMPARE_TIERS above).
local stepLag = {
	on = (MESHGHOST_CRYSTAL_STEP_LAG or os.getenv("MESHGHOST_CRYSTAL_STEP_LAG")) == "1",
	commit = {},  -- "x,y" of a tile the player took -> the frame they took it
	seen = {},    -- per peer, the last tile we were told about, so a change is detectable
	open = {},    -- per peer, an arrival that has not been walked yet
	wire = {}, apply = {}, total = {}, -- histograms: frames -> how many steps took that long
	n = 0, blocked = 0, unknown = 0, at = 0,
}
-- ISSUE, and the end of the delay. Split rather than totalled: a frame lost on the wire and a frame
-- lost waiting for the ghost's own legs have nothing to do with each other and are fixed in
-- different files. Deliberately does no logging -- `logFile` is declared far below this point, and
-- a local declared below a function is a nil global inside it (the trap `_template/README.md`
-- names), so the report is built in tick() where the name is real.
stepLag.close = function(id)
	local o = stepLag.open[id]
	if not o then
		return
	end
	stepLag.open[id] = nil
	local now = emu.framecount()
	-- CLAMPED AT 40, NOT 20, and the exact min/max kept beside the histogram. At the shipped 250ms
	-- the interpolation delay alone is 15 frames, so a tighter clamp files an entire run in the top
	-- bucket and then reports a SPREAD OF ZERO -- the flattering answer, from a saturated
	-- instrument. The spread is the number this measurement exists for, so it is never allowed to
	-- come from a bucket edge: `lo`/`hi` are the raw values, outside the histogram entirely.
	local function bump(h, v)
		h.n, h.sum = (h.n or 0) + 1, (h.sum or 0) + v
		h.lo = math.min(h.lo or v, v)
		h.hi = math.max(h.hi or v, v)
		local k = v
		if k < 0 then
			k = 0
		elseif k > 40 then
			k = 40
		end
		h[k] = (h[k] or 0) + 1
	end
	bump(stepLag.wire, o.wire)
	bump(stepLag.apply, now - o.at)
	bump(stepLag.total, now - o.commit)
	stepLag.n = stepLag.n + 1
end
-- ONE TABLE, not five names. This file sits at Lua's 200-local limit for a main chunk and has hit
-- it twice on 2026-08-21, each time as a bare "LOAD FAILED" with the whole adapter not loading --
-- so related constants get grouped rather than each spending one of the 200.
--
-- The hardware copy sits furthest out, so the three renderers read left-to-right as
-- hardware, drawn, player, spawned. The user's layout, 2026-08-21.
-- The hardware copy sits furthest out, so the three renderers read left-to-right as
-- hardware, drawn, player, spawned. The user's layout, 2026-08-21.
--
-- `dy` shifts every copy vertically (negative is up; map Y grows downward), for a layout that puts
-- the renderers side by side rather than either side of the player -- tried 2026-08-25 as
-- { drawn = -3, spawned = -2, hw = -5, dy = -1 } and reverted to this on the user's call. Read the
-- trap at peerPixY before changing it: the shift belongs at the source, applied once.
local COMPARE = { drawn = -2, spawned = 3, hw = -4, dy = 0 }
-- The spawned-tier switch (see the SHIPPED TIER note above COMPARE_TIERS): compare mode implies
-- it, MESHGHOST_CRYSTAL_SPAWN_TIER=1 (global first, then environment) opts in without it.
COMPARE.spawnTier = COMPARE_TIERS
	or (MESHGHOST_CRYSTAL_SPAWN_TIER or os.getenv("MESHGHOST_CRYSTAL_SPAWN_TIER")) == "1"
-- The drawn copy lives in `overflow` under a key of its own, so it animates frame to frame like
-- any other drawn peer while never colliding with the spawned copy's entry under the real id.
function COMPARE.key(id) return id .. " (drawn copy)" end
function COMPARE.hwKey(id) return id .. " (hardware copy)" end

local DOMAIN = "WRAM"
local ROM_DOMAIN = "ROM"

----------------------------------------------------------------------------
-- Addresses. All from our own hash-verified pokecrystal build; see verified.md.
----------------------------------------------------------------------------

local function flat(cpu)
	if cpu < 0xD000 then
		return cpu - 0xC000
	end
	return 0x1000 + (cpu - 0xD000)
end

-- ONE TABLE PER ROM BUILD, selected by classifyRom() at startup. A build that rearranges WRAM
-- does not get vanilla's addresses "because they are close" -- it gets its own measured set or it
-- does not run at all. Every entry here is traceable: vanilla's to our own hash-verified
-- pokecrystal build, Archipelago's to a dated probe log (verified.md, 2026-08-18).
local ADDRESSES = {
	vanilla = {
		label = "vanilla Crystal V1.0",
		OBJECT_STRUCTS = flat(0xD4D6), -- 01:d4d6, 13 x 0x28
		MAP_OBJECTS = flat(0xD71E), -- 01:d71e, 16 x 0x10
		W_MAPGROUP = flat(0xDCB5),
		W_MAPNUMBER = flat(0xDCB6),
		-- the VISIBLE WINDOW origin, not the player
		W_YCOORD = flat(0xDCB7),
		W_XCOORD = flat(0xDCB8),
		W_MAPSTATUS = flat(0xD432),
		W_BATTLEMODE = flat(0xD22D),
		W_BGMAPOFFSETX = flat(0xD14C),
		W_BGMAPOFFSETY = flat(0xD14D),
		-- CROSS-MAP GHOSTS. `wMapConnections` is a direction bitmask followed by four 12-byte
		-- structs (north, south, west, east), rebuilt by the engine on every map load, so the
		-- current map's neighbours are always sitting here -- no ROM scan, unlike Emerald.
		-- `wMapWidth`/`wMapHeight` are OUR OWN dimensions in BLOCKS (a block is 2x2 tiles); a
		-- connection struct carries the NEIGHBOUR's width and never ours, so an east or south
		-- neighbour cannot be placed without them. Layout from pokecrystal's
		-- `macros/ram.asm` (`map_connection_struct`), addresses from our own hash-verified
		-- build's `pokecrystal.sym`; the arithmetic was measured across four driven crossings
		-- (UNVERIFIED.md, 2026-08-27).
		W_MAPCONNECTIONS = flat(0xD1A8),
		W_MAPHEIGHT = flat(0xD19E),
		W_MAPWIDTH = flat(0xD19F),
		-- 01:d154, 32 two-byte entries ending at 01:d194 (wUsedSpritesEnd), which is
		-- SPRITE_GFX_LIST_CAPACITY * 2. Each entry is [sprite id, VRAM tile base]: the id is put
		-- there by AddSpriteGFX as the map loads, and ArrangeUsedSprites then overwrites the
		-- second byte with the tile the sprite's graphics were actually placed at. So this table
		-- is the answer to "is sprite N loaded right now, and where" -- the question a peer's own
		-- appearance depends on. Read-only here; nothing writes into it.
		W_USEDSPRITES = flat(0xD154),
		-- 01:d0ed. Bit 0 is SPRITE_UPDATES_DISABLED_F: _UpdateSprites returns immediately unless it
		-- is SET, and while it is clear the game has cleared the sprite buffer itself (the START
		-- menu). The hardware tier reads it so it stays out exactly when the game wants nobody drawn.
		W_STATEFLAGS = flat(0xD0ED),
		-- OverworldSprites, 05:4736 -> bank 5 * 0x4000 + (0x4736 - 0x4000). Six bytes per entry
		-- (address, size, bank, type, palette), indexed by SPRITE_* - 1. Used by the drawn tier to
		-- read a peer's graphics straight from the cartridge.
		OVERWORLD_SPRITES_ROM = 0x14736,
		-- StepVectors, 01:4700 -> the same arithmetic, and our own build's pokecrystal.sym says
		-- so. It also settles the group COUNT without a byte being read: the next symbol is
		-- `GetStepVectorSign` at 01:4730, exactly 0x30 past the table, which is three groups of
		-- four four-byte rows and not a byte more. A HINT, not a constant -- ENGINE.gaitGroups
		-- re-checks the signature here and scans for it if this address is wrong, because a
		-- build we do not recognise is handed this table by the run-anyway fallback.
		STEP_VECTORS_ROM = 0x4700,
		-- THE CAMERA. `hSCX`/`hSCY`, from our own build's pokecrystal.sym, read on the SYSTEM BUS
		-- rather than the WRAM domain this table otherwise serves -- HRAM is not in it. These sat
		-- as inline literals until 2026-08-26, which `UNVERIFIED.md` had flagged on 2026-08-23 as
		-- the one pair bypassing this table; see the Archipelago entry below for what that cost.
		H_SCX = 0xFFCF,
		H_SCY = 0xFFD0,
		-- THE FISHING SHEET, and it is NOT FishingRodGFX. `Script_FishCastRod` does
		-- `loademote EMOTE_ROD` and then `callasm LoadFishingGFX` -- and the second overwrites
		-- what the first loaded. `engine/events/fishing_gfx.asm` copies four 2-tile blocks out of
		-- `chris_fish.2bpp` / `kris_fish.2bpp` into VRAM BANK 1: sprite tiles $02, $06 and $0a
		-- (the BOTTOM half of the standing down/up/left views) and $fc (the rod). So a fishing
		-- character is its own top half plus this sheet's bottom half, and the rod is this
		-- sheet's tiles 6-7 -- FishingRodGFX is on screen for a few frames at most and never
		-- during the pose. Measured on screen 2026-08-25: VRAM bank 1 $fc held a vertical line
		-- where FishingRodGFX tile 0 is a diagonal, which is what the user saw as a rod that
		-- looked *"sideways/weird"*. See UNVERIFIED.md.
		--
		-- FishingGFX, 2e:44f2 -> 0x2e * 0x4000 + (0x44f2 - 0x4000); KrisFishingGFX at 2e:4582.
		-- Nine tiles each, of which the engine uses the first eight. Which one a PEER gets is its
		-- own sprite id (SPRITE_CHRIS 1, SPRITE_KRIS $60) and never the local player's gender.
		-- VANILLA V1.0 ONLY -- gated on classifyRom() saying "known" below, because unlike the
		-- sprite table this one has no cheap signature and an unknown build would paint whatever
		-- is there.
		FISHING_GFX_ROM = 0xB84F2,
		FISHING_GFX_ROM_KRIS = 0xB8582,
		-- `JumpShadowGFX`, 41:4550 -> 0x41 * 0x4000 + (0x4550 - 0x4000). ONE tile, and the
		-- neighbour of `FishingRodGFX` at 41:4560 -- which is not a coincidence:
		-- `data/sprites/emotes.asm` loads BOTH to the same vtile $fc on demand, so VRAM $fc holds
		-- the jump shadow normally and the fishing rod while somebody is fishing. That is exactly
		-- why this is read from the cartridge rather than from VRAM: a peer hopping a ledge while
		-- THIS machine's player has a rod out would otherwise cast a fishing rod for a shadow.
		-- VANILLA V1.0 ONLY, gated on classifyRom() below, same as the fishing sheet.
		SHADOW_GFX_ROM = 0x104550,
		-- Emotes, 05:444d -> 0x5 * 0x4000 + (0x444d - 0x4000). Twelve six-byte entries --
		-- `dw graphics, db length, db bank, dw vtile` (`data/sprites/emotes.asm`) -- so this
		-- table is how a receiver turns "emote number N" back into pixels. The "!" over a
		-- character's head is one of these, and it is a SEPARATE map object, not a pose.
		EMOTES_ROM = 0x1444D,
		-- THE FLYING POKEMON. `FlyFunction_InitGFX` reads wCurPartyMon, takes that party slot's
		-- species, and loads THAT MON'S ICON as the thing the player rides -- so a peer's fly is
		-- only reproducible if its species crosses the wire. All four are vanilla V1.0 and gated
		-- on classifyRom() saying "known", like the fishing graphics: an unknown build would read
		-- a species out of the wrong place and paint whatever the pointer landed on.
		--
		-- MonMenuIcons, 23:6ac4 -> 0x23 * 0x4000 + (0x6ac4 - 0x4000). One byte per species,
		-- indexed species-1 (`ReadMonMenuIcon`), giving an ICON index -- several species share an
		-- icon, which is why this indirection exists at all.
		-- IconPointers, 23:6bbf -> the same arithmetic. Two bytes per icon, an address inside
		-- bank 0x23 (`BANK(Icons)`), eight tiles each: two 2x2 frames.
		-- THE GAME'S OWN "the overworld sprite engine is running" byte, and the positive answer
		-- to "may a character be shown at all right now" -- the user's own framing, 2026-08-26,
		-- after ghosts painted over the party menu and the fly map screen on an adapter reload:
		-- *"no check if they can't spawn/show there? just a check that they should be hidden"* --
		-- the deny-list problem in one sentence. `DisableSpriteUpdates` (home/sprite_updates.asm)
		-- sets this FALSE and is what every full-screen UI calls; polarity measured live from the
		-- prepared fly savestate: 0 on the fly map screen, 1 on the overworld AND 1 through the
		-- landing animation, which is why the painted descent still draws.
		W_SPRITEUPDATESON = flat(0xC2CE),
		W_CURPARTYMON = flat(0xD109),
		W_PARTYSPECIES = flat(0xDCD8),
		MON_ICONS_ROM = 0x8EAC4,
		ICON_POINTERS_ROM = 0x8EBBF,
		ICONS_BANK = 0x23,
	},

	-- Archipelago's Crystal patch. MEASURED, never derived -- three separate vanilla relationships
	-- failed on this build before these four were established the hard way (verified.md):
	-- the coordinate block moved +7, the object array +6, and the map-object table -0x2A. Deltas
	-- from vanilla are noted only to show they disagree; nothing here is computed from them.
	--
	-- INCOMPLETE ON PURPOSE. The nil entries below have not been measured, and a nil is what makes
	-- this table refuse to run rather than silently write somewhere plausible. Fill one in only
	-- from a probe log, never from the delta of its neighbour -- that is exactly the reasoning
	-- that produced the three failures above.
	archipelago = {
		label = "Archipelago-patched Crystal",
		OBJECT_STRUCTS = 0x14DC, -- vanilla+6; player in slot 0, NPCs in 1-2, zeroes after
		MAP_OBJECTS = 0x16F4, -- vanilla-0x2A; struct_id/sprite/y/x agree with the array both ways
		W_YCOORD = 0x1CBE, -- vanilla+7; moved -1 walking up, +1 walking back down
		W_XCOORD = 0x1CBF, -- vanilla+7; moved with left/right only
		-- Measured by watching WHEN they change, not whether: across ten map transitions these
		-- two moved only on the transition itself, while seven candidates that survived two
		-- snapshot runs turned out to move constantly WITHIN a map. The group held 24 throughout
		-- (every map visited was in one group) and the number tracked each door.
		W_MAPGROUP = 0x1CBC,
		W_MAPNUMBER = 0x1CBD,
		-- So the block IS four consecutive bytes at vanilla+7 after all -- group, number, Y, X at
		-- 0x1CBC-0x1CBF. What was wrong in the refuted derivation was the LABEL: AP publishes 7359
		-- as wMapGroup and it is the X coordinate, three bytes past where the name implied.
		-- 0x0FB1 is the byte the GATE wants, and the name is provisional. It reads 2 during
		-- normal overworld play, 0 in a battle, and 1 while a map is entering (the reload after a
		-- battle ends) -- three values behaving exactly like wMapStatus's own. But Phase 9
		-- established on VANILLA that wMapStatus alone lets a battle through, and this byte does
		-- not, so it may well be something else that happens to track play state. The gate needs
		-- the behaviour, not the name; do not "correct" this to a tidier address on the strength
		-- of the label. Measured across two state runs plus two battle runs (verified.md).
		-- 0x0FB1 was the single survivor of two snapshot runs, and a live run then showed it
		-- FLICKERING between 2 and 1 several times a second while simply standing in the
		-- overworld -- so it is not wMapStatus, and the snapshots only ever agreed because they
		-- sampled while standing still and phase-locked. 0x1439 is vanilla+7 and held 2 across
		-- 1103 samples of walking. Override with MESHGHOST_CRYSTAL_STATUS_ADDR to compare.
		W_MAPSTATUS = tonumber(os.getenv("MESHGHOST_CRYSTAL_STATUS_ADDR") or "") or 0x1439,
		-- MEASURED 2026-08-19 by fighting a TRAINER battle -- the rival's Totodile in Cherrygrove
		-- City -- after two wild battles on Route 30. Ten candidates all read 1 in a wild battle;
		-- 0x1234 was the only one that read 2 in the trainer battle, held it for the whole fight
		-- and returned to 0 when it ended. 0x015A, the other candidate, read 1 in BOTH, which is
		-- what rules it out. Vanilla semantics confirmed on this build: 0 outside, 1 wild,
		-- 2 trainer. It is also vanilla's 0xD22D -> flat 0x122D plus 7, the same delta the
		-- coordinate block moved -- corroboration, not the derivation. See verified.md.
		W_BATTLEMODE = 0x1234,
		-- MEASURED 2026-08-19 by scanning the patched ROM for the table's own signature -- a run
		-- of 6-byte entries whose address is 0x4000-0x7FFF, size is 192 or 64 bytes, type is 1-3
		-- and palette is 0-7. The same scan finds vanilla's table at its known 0x14736 with 102
		-- entries, which is what makes the method trustworthy rather than a guess; on the patched
		-- ROM it finds 102 entries at 0x14564. Cross-checked by content: 97 of the 102 sprites'
		-- graphics are byte-identical between the two ROMs, including CHRIS, KRIS and RED, and the
		-- five that differ are the tail the patch adds. See verified.md.
		OVERWORLD_SPRITES_ROM = 0x14564,
		-- MEASURED 2026-08-26 the same way, and it is the entry that makes this build's faster
		-- bike work at all. Scanning for the table's own signature (see ENGINE.gaitGroups) finds
		-- it at 0x004700 on Crystal V1.0, V1.1 and speedchoice 8.1 alike -- one hit each, all
		-- three carrying vanilla's three groups -- and at 0x0048C9 on an Archipelago seed, where
		-- it carries FOUR: a fourth group of 8 pixels a tick for 2 ticks, a tile in two frames.
		-- The patch appends it into the index space vanilla's own `and $0F` already reserves, so
		-- no engine change was needed on their side and none is needed here beyond knowing it is
		-- there. Same hint-not-constant status as vanilla's above: re-checked at load.
		STEP_VECTORS_ROM = 0x48C9,
		-- THE CAMERA, AND IT IS NOT WHERE VANILLA KEEPS IT. Vanilla's $FFCF/$FFD0 are DEAD BYTES
		-- on this build: across a 35-second run of real walking they never changed once, on either
		-- axis, while the adapter read them every frame as the clock its drawn tier is anchored to.
		--
		-- That is the exact failure `UNVERIFIED.md` predicted on 2026-08-23 -- "HRAM always reads,
		-- so a wrong entry would produce a believable scroll value and the graceful fallback would
		-- never fire" -- and it did not surface until a mixed vanilla/Archipelago room was run for
		-- the first time on 2026-08-26. The symptom was not a missing ghost or an error: a peer
		-- STANDING PERFECTLY STILL was painted gliding across the ground as the local player
		-- walked, and stuck at the edge of the screen once the player got far enough away. The
		-- vanilla client, same adapter, same peer, was correct throughout.
		--
		-- MEASURED, never derived, by sweeping all 127 bytes of HRAM for the camera's own
		-- signature -- constant while standing, changing several times WITHIN a step, moving on
		-- one axis only, walking a run of evenly spaced values (`probes/ap_hram_scroll_probe.lua`):
		--   $FFC7  still 0, 404 changes on left/right vs 28 on up/down, gap 2 on 39 of 39 steps
		--   $FFC8  still 0, 394 changes on up/down vs 0 on left/right, gap 2 on 38 of 39 steps
		-- The pair is adjacent and in vanilla's own X-then-Y order, and both are vanilla-8. That
		-- delta is corroboration AFTER the fact and not the derivation -- each was measured on its
		-- own, which is the rule this build's other four entries exist to enforce.
		--
		-- $FFC7's 28 stray up/down changes are a walk not being perfectly axis-pure, and they are
		-- why the probe's FIRST version reported zero X candidates: it filtered on "moved on one
		-- axis ONLY" before printing anything. A filter applied before you look is a guess about
		-- the answer (`_template/probes.md`), and that one discarded the right address.
		H_SCX = 0xFFC7,
		H_SCY = 0xFFC8,

		-- NOT the table. These are the leading unconfirmed candidates for the entries still nil
		-- above, used only when MESHGHOST_CRYSTAL_AP_TRY=1 asks for a deliberate experiment, and
		-- logged as unconfirmed every time. Kept separate from the real fields on purpose: a
		-- candidate that can be read by ordinary code eventually gets treated as measured.
		-- 0x015A sat here as the leading W_BATTLEMODE candidate until 2026-08-19, when a trainer
		-- battle showed it reading 1 exactly as it does in a wild one. Refuted, not measured.
		candidates = {},
		-- Pixel scroll offsets, and the only pair here measured by CORRELATION rather than by a
		-- filter: across 137 real tile steps, 0x1153 moved on 70 of 70 X steps and 1 of 67 Y
		-- steps, 0x1154 the exact mirror. They sweep 0,2,4..254 within a step, which is the shape
		-- nothing else in this region has. (Also vanilla+7, noticed after the fact, not before.)
		W_BGMAPOFFSETX = 0x1153,
		W_BGMAPOFFSETY = 0x1154,
		-- W_MAPCONNECTIONS / W_MAPWIDTH / W_MAPHEIGHT are deliberately ABSENT: unmeasured on this
		-- build, and nil switches cross-map ghosts off here rather than reading a plausible
		-- address. Vanilla's offsets are NOT transferable -- this build moved the coordinate block
		-- +7 and the object array +6, and no third relationship has ever held on it. Measure the
		-- block with probes/connections_probe.lua (MESHGHOST_CRYSTAL_CONN_ADDR tests a candidate)
		-- before filling these in.
	},
}

-- Assigned once, from the selected table, before the main loop runs.
local OBJECT_STRUCTS, MAP_OBJECTS
local W_MAPGROUP, W_MAPNUMBER, W_YCOORD, W_XCOORD
local W_MAPSTATUS, W_BATTLEMODE, W_BGMAPOFFSETX, W_BGMAPOFFSETY
-- nil on any build where it has not been measured (Archipelago's), which switches the peer's own
-- appearance off rather than reading a plausible address.
local W_USEDSPRITES, W_STATEFLAGS
local USED_SPRITES_CAPACITY = 32 -- SPRITE_GFX_LIST_CAPACITY

local OBJECT_LENGTH, MAPOBJECT_LENGTH = 0x28, 0x10
local NUM_OBJECT_STRUCTS, NUM_MAP_OBJECTS = 13, 16

local M_STRUCT_ID, M_SPRITE, M_Y, M_X = 0x00, 0x01, 0x02, 0x03
local F_SPRITE, F_MAP_OBJECT_INDEX, F_SPRITE_TILE = 0x00, 0x01, 0x02

-- SPRITEMOVEDATA_STANDING_DOWN/UP/LEFT/RIGHT are 0x06..0x09, in the same down/up/left/right order
-- this adapter uses for `dir` everywhere else, so the entry for a direction is simply 6 + dir.
--
-- All four have the same movement FUNCTION -- SPRITEMOVEFN_STANDING, "stand and do nothing else"
-- -- which is what a ghost needs between the steps we drive it through. They differ only in the
-- facing they restore, and that difference matters: when a movement ends, StepFunction_Restore
-- calls RestoreDefaultMovement (which re-reads MAPOBJECT_MOVEMENT) and then GetInitialFacing, and
-- writes the result into OBJECT_DIRECTION. So this byte is re-read after EVERY step, not only when
-- the engine first builds the object -- pinning all four directions to the DOWN entry would turn
-- the ghost to face down for a frame at the end of every step.
local SPRITEMOVEDATA_STANDING_BY_DIR = { [0] = 0x06, [1] = 0x07, [2] = 0x08, [3] = 0x09 }
local F_FLAGS1, F_PALETTE = 0x04, 0x06
local F_WALKING, F_DIRECTION, F_STEP_TYPE, F_STEP_DURATION = 0x07, 0x08, 0x09, 0x0A
local F_ACTION, F_FACING = 0x0B, 0x0D
local F_MAP_X, F_MAP_Y = 0x10, 0x11
local F_LAST_MAP_X, F_LAST_MAP_Y = 0x12, 0x13
local F_INIT_X, F_INIT_Y = 0x14, 0x15
local F_SPRITE_X, F_SPRITE_Y = 0x17, 0x18

-- THREE ENGINE CONSTANTS ON ONE NAME. Each was a plain local and each is used once or twice;
-- together they cost three of Lua's 200 for a main chunk, which this file is AT -- adding two
-- names for the emote work below stopped it loading outright (2026-08-26, the fourth time this
-- has bitten; `adapters/emulator/CLAUDE.md`). Grouping is the standing answer.
local ENGINE = {
	WONT_DELETE = 0x02, -- OBJECT_FLAGS1 bit: the engine's own culler leaves this object alone
	UNASSIGNED = 0xFF, -- OBJECT_MAP_OBJECT_INDEX for an object with no map-object entry
	MAPSTATUS_HANDLE = 2, -- wMapStatus while the overworld is the thing on screen
	-- The emote work hangs here for the same reason. `playerEmote` is a FIELD rather than a local
	-- because it must be visible to getLocalState (which is defined above the VRAM and cartridge
	-- readers it needs) while being DEFINED below them -- the file's own "a local declared BELOW a
	-- function is a nil global inside it" trap, avoided by going through this table.
	emoteIds = {}, -- the 16 bytes at VRAM $f8 -> which Emotes entry they are (-1 for none)
}

-- THE "!" OVER A CHARACTER'S HEAD, and everything this file needs to carry one across the wire.
--
-- ONE TABLE, ONE NAME. This file is at Lua's 200-local ceiling for a main chunk -- adding two
-- plain locals for the two constants below was enough to stop it loading at all (2026-08-26,
-- which is the fourth time; `adapters/emulator/CLAUDE.md`). Everything for this feature therefore
-- hangs here.
--
-- An emote is NOT a pose the character adopts: `SpawnEmote` creates a separate map object at the
-- character's own tile, flagged EMOTE_OBJECT, sitting 16px above it, whose facing is FACING_EMOTE
-- -- four ABSOLUTE tiles $f8-$fb. So nothing about it reaches a peer through the character's own
-- action or facing byte, which is why a ghost has never had one.
local emote = {
	F_YOFF = 0x1A, -- OBJECT_SPRITE_Y_OFFSET
	FLAG1 = 0x80, -- EMOTE_OBJECT, bit 7 of OBJECT_FLAGS1
	PAL = 5, -- PAL_OW_EMOTE
	VTILE = 0xF8, -- where the 4-tile emotes are loaded, and what FacingEmote names
	LIFT = 16, -- how far above the character's own tile the box sits
	rom = nil, -- the Emotes table, resolved at startup from the address block
	gfx = {}, -- emote index -> flat ROM offset of its graphics, memoised

	-- THE LEDGE HOP AND ITS SHADOW hang here too, and for the same reason: this file is at Lua's
	-- 200-local ceiling for a main chunk, so a feature gets one table rather than six names.
	-- They belong beside the emote rather than anywhere else because they are the SAME KIND of
	-- thing -- the jump shadow is a separate map object flagged EMOTE_OBJECT, exactly like the
	-- "!", which is why the emote scan used to mistake one for the other.
	F_STEP_INDEX = 0x1C, -- OBJECT_STEP_INDEX, the anon-jumptable index (which phase runs next)
	F_JUMP_HEIGHT = 0x1F, -- OBJECT_JUMP_HEIGHT, what UpdateJumpPosition accumulates
	-- `FacingShadow` (data/sprites/facings.asm): two sprites, both ABSOLUTE_TILE_ID $fc, at
	-- (y 0, x 0) and (y 0, x 8) with the second X-flipped -- a 16x8 smudge.
	-- `MovementFunction_Shadow` puts it at OBJECT_SPRITE_Y_OFFSET = 1 * TILE_WIDTH + 6 = 14 for a
	-- character facing DOWN or UP and 1 * TILE_WIDTH + 4 = 12 facing LEFT or RIGHT, with an X
	-- offset of 0. Confirmed live 2026-08-26: the shadow object under a downward hop read y=+14.
	SHADOW_DY = { [0] = 14, [1] = 14, [2] = 12, [3] = 12 },
}
local STANDING = 255

----------------------------------------------------------------------------
-- Logging
----------------------------------------------------------------------------

-- Under BizHawk, debug.getinfo's `source` is "main" rather than "@<path>", so it yields nothing
-- usable — which is exactly why Emerald's own scriptDir() carries a pwd fallback, and why omitting
-- one here produced four failed paths on the first run (2026-08-18).
--
-- The working directory IS the script's directory when BizHawk loads a Lua file, confirmed live:
-- `cd` returned C:\dev\MeshGhost\adapters\emulator\pokemon\crystal. So pwd is the primary answer here, not
-- the fallback.
local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		local dir = info.source:sub(2):match("^(.*)[/\\]")
		-- Only an ABSOLUTE answer counts. A relative one ("." from a dofile) satisfies this branch,
		-- skips the pwd fallback below, and then fails where it matters -- LuaSocket is loaded with
		-- package.loadlib, and Windows resolves a relative DLL path against the PROCESS directory
		-- (BizHawk's), never the working directory, so "./../emerald/lib/x64/" cannot work even when
		-- the folder is sitting right there. Cost this exact failure twice on 2026-08-18: once from
		-- an empty source under BizHawk, once from loading this file through run_second_client.lua.
		if dir and #dir > 0 and (dir:match("^%a:") or dir:match("^[/\\]")) then
			return dir
		end
	end
	-- MESHGHOST_SCRIPT_DIR, if whatever launched us set it. Free, absolute, and spawns nothing.
	-- Needed because `--lua=<path>` makes BizHawk report `source` as `[string "main"]` rather
	-- than a path, so the branch above cannot answer at all in that case.
	-- Game-specific FIRST -- see the same note in Emerald's adapter: an env var is process-wide,
	-- BizHawk runs every script in one process, so a shared name leaks one adapter's folder into
	-- the next one loaded.
	local fromEnv = MESHGHOST_SCRIPT_DIR
		or os.getenv("MESHGHOST_SCRIPT_DIR_CRYSTAL")
		or os.getenv("MESHGHOST_SCRIPT_DIR")
	if fromEnv and fromEnv ~= "" then
		return (fromEnv:gsub("[/\\]$", ""))
	end

	-- Last resort. It answers with the WORKING directory rather than this script's, so it is only
	-- right when the two agree, and it spawns a real `cmd` -- the console window that flashes on
	-- launch. Removing it outright on 2026-08-18 broke Emerald's `--lua=` loading instantly, which
	-- is how the "unreachable fallback" comment was shown to be wrong; kept here for the same
	-- reason, and now reached only when nothing better was offered.
	local p = io.popen and io.popen("cd")
	if p then
		local out = p:read("*l")
		p:close()
		if out and #out > 0 then
			return out
		end
	end
	return "."
end

local SCRIPT_DIR = scriptDir()
-- Prefer a logs/ subfolder, so the adapter folder stays readable across a session that reloads
-- the script many times (each run opens its own timestamped file). No mkdir needed: io.open fails
-- when the directory is absent, and that failure IS the fallback.
--
-- THE NAME CARRIES THIS EMULATOR'S PROCESS ID, and that is not decoration. Two emulators running
-- the same game (a vanilla ROM and a patched seed, which is the normal two-instance session here)
-- run this same script, and a name resolved only to the SECOND collides whenever both reload in
-- the same second -- which is exactly what a control-file edit or a shared restart does. Both then
-- hold the same file open and their lines interleave mid-write, producing mangled lines where one
-- write landed inside another. Found live on the Emerald adapter 2026-08-19 and back-ported here
-- unchanged, because this file has the identical shape; a pid cannot collide while both processes
-- exist, where a port can (the bridge port is walked when it is not pinned).
local logfile
do
	local okPid, pid = pcall(function()
		luanet.load_assembly("System")
		return luanet.import_type("System.Diagnostics.Process").GetCurrentProcess().Id
	end)
	-- No pid available (a BizHawk build without luanet): fall back to a pinned bridge port, and
	-- then to the clock's fractional part -- any discriminator beats none, because the failure
	-- being prevented is silent corruption of the file rather than a missing one.
	local tag = (okPid and pid) or BRIDGE_PORT_OVERRIDE
		or math.floor((os.clock() % 1) * 100000)
	local name = string.format("meshghost_crystal_%s_%s.log", os.date("%Y%m%d_%H%M%S"), tostring(tag))
	logfile = io.open(SCRIPT_DIR .. "/logs/" .. name, "w") or io.open(SCRIPT_DIR .. "/" .. name, "w")
	-- BUFFER IT. Every log line used to be followed by a flush, which is a synchronous disk write
	-- on the game thread -- and the game thread is the emulator. Measured 2026-08-21: a script
	-- whose ONLY per-second work was writing one log line produced exactly one 63-78ms stall every
	-- second, four to five frames, while the frame-rate average still read 59.7. That is precisely
	-- what the user had been reporting for the whole session -- *"choppy/laggy"* on a game that
	-- measured full speed. `logFile` is called every second by the drawn tier whenever peers are
	-- present, so this was shipping to players, not just to the dev rig.
	if logfile then
		pcall(function() logfile:setvbuf("full", 16384) end)
	end
end

local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
	end
end

-- File only. A per-tick diagnostic in the Lua Console scrolls the startup lines out of view, and
-- those name the ROM and every address in use -- which is what a reader actually needs
-- (probes.md: detail to the log file, headlines to the console).
--
-- DELIBERATELY UNFLUSHED, and this is the line that mattered: the drawn tier calls it once a
-- second whenever peers are present, and a flush is a synchronous disk write on the emulator's own
-- thread. Measured 2026-08-21: 63-83ms per write, four to five frames, every second, while the
-- frame-rate average still read 59.7fps. The buffer is pushed to disk on the timer in tick() and
-- by close() on the way out. `log` above still flushes -- it is rare, and an error worth printing
-- is worth having on disk before whatever follows it.
local function logFile(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end

-- WHERE THE BRIDGE PORT RANGE STARTS, from the player's own config.json.
--
-- Until 2026-08-28 this script walked 7778-7785 whatever that file said, so a player who moved
-- the port moved the CLIENT and not the script, and the two then never found each other -- the
-- config did not fail loudly, it silently broke the connection. Reported on Pseudoregalia as
-- "setting the config to 7780 it still starts at 7778"; the same defect, in a different language.
--
-- Read by hand rather than with a JSON parser: the shape is fixed ("host:port", quoted) and one
-- key does not justify a parser. Anything unrecognised leaves the default alone.
--
-- IN A do ... end BLOCK ON PURPOSE. This file is a few names below Lua's 200-local ceiling for a
-- main chunk (adapters/emulator/CLAUDE.md), and locals inside a block are released at its end, so
-- this costs none of them. Past that ceiling the script does not load AT ALL -- not loudly, just
-- absent, which reads exactly like a dead relay.
--
-- MESHGHOST_BRIDGE_PORT still wins over this: pinning one port for one run is a stronger
-- statement than saying where a range begins.
--
-- NOTE THE EXPLICIT "/" -- unlike Emerald's, this file's SCRIPT_DIR carries no trailing
-- separator, which every other path expression here also spells out.
do
	local candidates = {
		SCRIPT_DIR .. "/../../../config.json",
		SCRIPT_DIR .. "/../../../../config.json",
		SCRIPT_DIR .. "/config.json",
	}
	for _, path in ipairs(candidates) do
		local f = io.open(path, "r")
		if f then
			local text = f:read("*a")
			f:close()
			local port = tonumber(string.match(text or "",
				'"local_game_bridge"%s*:%s*"[^"]*:(%d+)"'))
			if port and port >= 1 and port <= 65535 and port ~= BRIDGE_BASE_PORT then
				log(string.format(
					"MeshGhost: bridge ports %d-%d, from local_game_bridge in config.json",
					port, port + BRIDGE_PORT_COUNT - 1))
				BRIDGE_BASE_PORT = port
			end
			-- First readable config wins, even if it has no such key: a later file is a
			-- different install's, and silently preferring it would be worse than the default.
			break
		end
	end
end

----------------------------------------------------------------------------
-- LuaSocket. Same bootstrap as Emerald's adapter -- lua54.dll must be pre-loaded by full path
-- first, because Windows' LoadLibrary does not search the loading DLL's own directory for it.
-- See agent_docs/architecture.md's Phase 3 ADR for the full derivation.
----------------------------------------------------------------------------

local function loadSocketCore()
	if package.config:sub(1, 1) ~= "\\" then
		error("MeshGhost: only Windows is supported by the vendored LuaSocket binary so far.")
	end
	-- The vendored pair lives beside Emerald's adapter today. Try next to this script first (so a
	-- shipped per-game folder works), then Emerald's copy, then the same paths relative to the working
	-- directory — because `debug.getinfo` is not dependable under BizHawk, which is exactly why
	-- Emerald's own scriptDir() carries a pwd fallback. Getting this wrong produced an empty log
	-- and an unexplained error on the first run, 2026-08-18.
	--
	-- Every attempt is logged. A loader that fails silently is what made that first failure take a
	-- round trip to diagnose.
	-- There used to be an io.popen("cd") here building one more candidate path from the working
	-- directory. It ran unconditionally, so EVERY launch spawned a `cmd` and flashed a console
	-- window -- the user spotted it on screen. Removed 2026-08-18: SCRIPT_DIR is resolved from
	-- debug.getinfo and is the reliable answer, so the candidates below already cover every real
	-- layout without paying a process for it.

	local candidates = {
		SCRIPT_DIR .. "/lib/x64/",
		SCRIPT_DIR .. "/../emerald/lib/x64/",
		"adapters/emulator/pokemon/emerald/lib/x64/",
	}
	for _, dir in ipairs(candidates) do
		pcall(function()
			package.loadlib(dir .. "lua54.dll", "meshghost_force_preload")
		end)
		local ok, fn = pcall(package.loadlib, dir .. "socket-windows-5-4.dll",
			"luaopen_socket_core")
		if ok and type(fn) == "function" then
			log("MeshGhost: LuaSocket loaded from " .. dir)
			return fn()
		end
		log("MeshGhost: no LuaSocket at " .. dir)
	end
	error("MeshGhost: could not load the vendored LuaSocket binary from any of the paths above.")
end

local socketCore = loadSocketCore()

----------------------------------------------------------------------------
-- Minimal JSON. Encode only what we send; decode enough for what we receive.
----------------------------------------------------------------------------

local ESCAPES = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function jsonEscape(s)
	return (s:gsub('[%c"\\]', function(c)
		return ESCAPES[c] or string.format("\\u%04x", c:byte())
	end))
end

local function jsonEncode(v)
	local t = type(v)
	if v == nil then
		return "null"
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "number" then
		return string.format("%.14g", v)
	elseif t == "string" then
		return '"' .. jsonEscape(v) .. '"'
	elseif t == "table" then
		if v[1] ~= nil or next(v) == nil then
			local parts = {}
			for _, item in ipairs(v) do
				parts[#parts + 1] = jsonEncode(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, item in pairs(v) do
			parts[#parts + 1] = '"' .. jsonEscape(tostring(k)) .. '":' .. jsonEncode(item)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

-- Small recursive-descent decoder. Enough for the bridge's messages; not a general JSON library.
--
-- IT MUST NOT LOOP ON TRUNCATED INPUT, and until 2026-08-25 it did. Both container loops below are
-- `while true`, and neither checked for the end of the string: on `{"a":1` with no closing brace,
-- the fallthrough at the bottom of `parseValue` advanced `pos` by one and returned nil, so the
-- loop went on asking for the next key forever. **The `pcall` at the bottom is no protection** --
-- an infinite loop raises nothing to catch, and in BizHawk it freezes the emulator rather than
-- dropping a message. The other six copies of this decoder in the repo were written from a
-- guarded shape and error out instead; this one was written fresh and had neither guard. Not
-- reachable from a relay -- the core emits well-formed JSON and the framing only splits on
-- newlines -- but "the sender is well behaved" is exactly the assumption worth not resting on.
local function jsonDecode(s)
	local pos = 1
	-- Depth is function-scope on purpose: this file sits at Lua's 200-local ceiling, and a
	-- file-scope name here would be spent for a counter. The cap is far above anything the bridge
	-- sends (a state message nests three deep) and far below what would exhaust the Lua stack.
	local depth = 0
	local function skip()
		while pos <= #s and s:sub(pos, pos):match("[ \t\r\n]") do
			pos = pos + 1
		end
	end
	local parseValue
	local function parseString()
		pos = pos + 1
		local out = {}
		while pos <= #s do
			local c = s:sub(pos, pos)
			if c == '"' then
				pos = pos + 1
				return table.concat(out)
			elseif c == "\\" then
				local n = s:sub(pos + 1, pos + 1)
				local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
				if n == "u" then
					out[#out + 1] = "?"
					pos = pos + 6
				else
					out[#out + 1] = map[n] or n
					pos = pos + 2
				end
			else
				out[#out + 1] = c
				pos = pos + 1
			end
		end
		return table.concat(out)
	end
	parseValue = function()
		depth = depth + 1
		if depth > 64 then
			error("json: too deeply nested")
		end
		skip()
		local c = s:sub(pos, pos)
		if pos > #s then
			error("json: unexpected end of input")
		end
		if c == '"' then
			depth = depth - 1
			return parseString()
		elseif c == "{" then
			pos = pos + 1
			local obj = {}
			skip()
			if s:sub(pos, pos) == "}" then
				pos = pos + 1
				depth = depth - 1
				return obj
			end
			while true do
				skip()
				if pos > #s then
					error("json: unterminated object")
				end
				local k = parseString()
				skip()
				pos = pos + 1 -- ':'
				obj[k] = parseValue()
				skip()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "}" then
					depth = depth - 1
					return obj
				elseif d ~= "," then
					error("json: expected ',' or '}'")
				end
			end
		elseif c == "[" then
			pos = pos + 1
			local arr = {}
			skip()
			if s:sub(pos, pos) == "]" then
				pos = pos + 1
				depth = depth - 1
				return arr
			end
			while true do
				if pos > #s then
					error("json: unterminated array")
				end
				arr[#arr + 1] = parseValue()
				skip()
				local d = s:sub(pos, pos)
				pos = pos + 1
				if d == "]" then
					depth = depth - 1
					return arr
				elseif d ~= "," then
					error("json: expected ',' or ']'")
				end
			end
		elseif s:sub(pos, pos + 3) == "true" then
			pos = pos + 4
			depth = depth - 1
			return true
		elseif s:sub(pos, pos + 4) == "false" then
			pos = pos + 5
			depth = depth - 1
			return false
		elseif s:sub(pos, pos + 3) == "null" then
			pos = pos + 4
			depth = depth - 1
			return nil
		else
			local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if num then
				pos = pos + #num
				depth = depth - 1
				return tonumber(num)
			end
			-- NO SILENT ADVANCE. This used to be `pos = pos + 1; return nil`, which is what let a
			-- truncated container loop forever: the caller saw a value, asked for the next one,
			-- and got the same nothing again. A byte that begins no value is a malformed message,
			-- and the pcall below turns that into a dropped line -- which is the correct outcome.
			error("json: unexpected character")
		end
	end
	local ok, result = pcall(parseValue)
	if ok then
		return result
	end
	return nil
end

----------------------------------------------------------------------------
-- Memory helpers and the ROM guard
----------------------------------------------------------------------------

local function u8(addr, domain)
	-- A NIL ADDRESS MUST NOT READ AS ZERO. BizHawk's memory.read_u8(nil) succeeds and returns 0
	-- rather than failing -- measured 2026-08-19, not assumed. An unmeasured entry in an ADDRESSES
	-- table is nil by design, and phase9.md's promise is that the adapter then "refuses rather
	-- than writing somewhere plausible". Without this guard that promise was not kept: nil read as
	-- byte 0, so `u8(W_BATTLEMODE) == 0` was silently ALWAYS TRUE on any build with that entry
	-- unmeasured -- i.e. the adapter believed no battle was ever happening, and drew ghosts over
	-- the battle screen. Reported by the user on the Archipelago build, whose W_BATTLEMODE was nil
	-- until it was measured that same day.
	if addr == nil then
		return nil
	end
	local ok, v = pcall(memory.read_u8, addr, domain or DOMAIN)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

local function w8(addr, value)
	pcall(memory.write_u8, addr, value, DOMAIN)
end

-- ROM classification, three-way rather than pass/fail (user's call, 2026-08-18).
--
--   "known"        vanilla V1.0 — the addresses below were derived from a byte-identical build.
--   "archipelago"  Archipelago's Crystal patch, which rearranges WRAM non-uniformly. It no longer
--                  means "refuse": it selects ADDRESSES.archipelago, a measured set of its own.
--                  It still refuses while that set is incomplete — see the startup check, which
--                  names the missing entries rather than falling back to vanilla's. Falling back
--                  would be the corrupting case this class exists to prevent.
--   "unknown"      anything else — another revision, a romhack, a translation. **Warn loudly and
--                  RUN.** Refusing guarantees an untested-but-fine ROM does not work, where trying
--                  it might. The cost of being wrong is bounded: this adapter writes only object
--                  RAM and never a save, so the worst case is a visual mess cleared by a map
--                  reload or a reset.
local function classifyRom()
	local t = {}
	for i = 0, 9 do
		local c = u8(0x134 + i, ROM_DOMAIN)
		if not c then
			return "unknown", "could not read the ROM domain at all"
		end
		t[#t + 1] = string.char(c)
	end
	local title = table.concat(t)
	if title == "PM_CRYSTAL"
		and u8(0x14E, ROM_DOMAIN) == 0x12 and u8(0x14F, ROM_DOMAIN) == 0x9F then
		return "known", "vanilla Crystal V1.0", "vanilla"
	end
	-- Archipelago renames the header, which is a cheaper and stronger signal than the checksum --
	-- and seed-independent, which the checksum is not: every seed patches different item data on
	-- top of one shared base recompile. Emerald's adapter relies on the same property for its own
	-- Archipelago addresses; if a future world update recompiles that base, the measured addresses
	-- move and the fingerprint check below is what notices.
	if title:sub(1, 3) == "AP_" then
		return "archipelago", string.format("ROM title %q — Archipelago's Crystal patch", title),
			"archipelago"
	end
	return "unknown", string.format("ROM title %q, checksum %02X%02X — not a build these addresses "
		.. "were derived from", title, u8(0x14E, ROM_DOMAIN) or 0, u8(0x14F, ROM_DOMAIN) or 0),
		"vanilla"
end

-- ONE GAIT GROUP OF `StepVectors`, or nil if these sixteen bytes are not one.
--
-- The table is four `db x, y, duration, speed` rows per gait, in this file's own down/up/left/
-- right order (`engine/overworld/map_objects.asm`), and every gait crosses the same 16px tile --
-- so a group for stride `s` is 0,s / 0,-s / -s,0 / s,0, all four carrying the same duration, and
-- `s * duration` is 16. That last identity is what makes the shape rare rather than merely
-- plausible: it rejects any run of bytes that happens to look like four little vectors.
--
-- Reads the ROM directly rather than through u8(), which pcalls every byte -- this runs over a
-- 16 KB window once at startup on an unrecognised build, and the domain and range are both fixed.
-- Returns the STRIDE, because the caller needs it to check the groups are in increasing order.
--
-- On ENGINE rather than as two more top-level locals: this file is at Lua's 200-local ceiling for
-- a main chunk and has been stopped from loading by one name four times (`emulator/CLAUDE.md`).
function ENGINE.gaitAt(off)
	local s = memory.read_u8(off + 1, ROM_DOMAIN)
	local d = memory.read_u8(off + 2, ROM_DOMAIN)
	if not s or not d or s == 0 or d == 0 or s * d ~= 16 then
		return nil
	end
	local neg = (256 - s) & 0xFF
	local want = { 0, s, d, s, 0, neg, d, s, neg, 0, d, s, s, 0, d, s }
	for i = 1, 16 do
		if memory.read_u8(off + i - 1, ROM_DOMAIN) ~= want[i] then
			return nil
		end
	end
	return s
end

-- HOW MANY GAITS THIS CARTRIDGE HAS -- asked of the ROM, never assumed from the build's name.
--
-- WHY THIS IS A MEASUREMENT AND NOT A CONSTANT PER BUILD. The number decides what this adapter
-- may WRITE into a ghost's walking byte, and writing a group the cartridge does not have sends
-- `GetStepVector` past the end of its own table to read whatever follows it as a movement vector.
-- That is a CROSS-BUILD hazard rather than a per-build one, and it is new with the wire: a peer
-- on a four-gait cartridge reports gait 3 to a receiver on a three-gait one, which is a state no
-- single-player session can reach. So the receiver has to answer from its own ROM, and a build
-- nobody has seen has to get a real answer rather than vanilla's by default.
--
-- Anchored on the three groups vanilla defines: a table that does not begin 1px/16, 2px/8, 4px/4
-- is not this table, whatever else it resembles. Measured 2026-08-26 across four cartridges --
-- Crystal V1.0, V1.1, speedchoice 8.1 and an Archipelago seed -- and the anchor found exactly one
-- hit in each, which is what makes it a signature rather than a filter.
--
-- The address is taken from the build's own table when there is one and scanned for otherwise.
-- Both measured addresses sit in bank 1, which is where `map_objects.asm` itself lives, so that
-- is the window a build we do not recognise gets searched. Not finding it is not an error: three
-- is what every un-patched Crystal has, and it is the answer that cannot write out of bounds.
function ENGINE.gaitGroups(base)
	if not base then
		for off = 0x4000, 0x8000 - 48 do
			-- One read filters almost every offset: the first byte of the slow group is the zero
			-- x-component of a step DOWN. Only the survivors pay for the full check.
			if memory.read_u8(off, ROM_DOMAIN) == 0 and ENGINE.gaitAt(off) == 1 then
				local n = ENGINE.gaitGroups(off)
				if n then
					return n, off
				end
			end
		end
		return nil
	end
	if ENGINE.gaitAt(base) ~= 1 or ENGINE.gaitAt(base + 16) ~= 2
		or ENGINE.gaitAt(base + 32) ~= 4 then
		return nil
	end
	local n, last = 3, 4
	while true do
		local s = ENGINE.gaitAt(base + n * 16)
		-- STRICTLY FASTER, or it is not a further gait. What follows the table is ordinary code,
		-- and code that happened to satisfy the shape would otherwise be counted as a gait we may
		-- write -- which is the exact write this whole function exists to prevent.
		if not s or s <= last then
			return n, base
		end
		n, last = n + 1, s
	end
end

-- The in-game gate. Established empirically in Phase 9, and BOTH terms were needed: wMapStatus
-- alone lets a battle through, and adding the event/script flags makes it flicker every step.
-- IS THE OVERWORLD THE THING ON SCREEN RIGHT NOW?
--
-- A POSITIVE test, never a list of things to avoid. A battle, a full-screen menu, an evolution
-- screen, the naming screen, the Pokedex, a cutscene and the title screen are all one case -- "not
-- the overworld" -- and a deny-list of them will never be finished, while every entry it is
-- missing shows up as a ghost painted over that screen. Two such reports arrived on 2026-08-19,
-- one for menus and one for battles; see pitfalls.md.
--
-- Every term must be a KNOWN value. `nil` is "this build has not been measured here", and it makes
-- the answer no -- it must never be allowed to satisfy a term by accident, which is what happened
-- before u8() guarded a nil address (see there).
local function inPlay()
	local status, battle = u8(W_MAPSTATUS), u8(W_BATTLEMODE)
	local group, number = u8(W_MAPGROUP), u8(W_MAPNUMBER)
	local playerSprite = u8(OBJECT_STRUCTS + F_SPRITE)
	if status == nil or battle == nil or group == nil or number == nil or playerSprite == nil then
		return false -- an unmeasured address, or a read that failed: refuse rather than guess
	end
	return status == ENGINE.MAPSTATUS_HANDLE
		and battle == 0
		and not (group == 0 and number == 0)
		and playerSprite ~= 0
end

local function areaId()
	return string.format("%d/%d", u8(W_MAPGROUP) or -1, u8(W_MAPNUMBER) or -1)
end

-- ===== CROSS-MAP GHOSTS: a peer across a route seam is visible, a peer in a house is not =====
--
-- The user's ask, 2026-08-27: *"going between routes/having the ghosts visible in other routes.
-- similar to how we did it in emerald"*.
--
-- The game's own map system draws this line for us. Maps join two ways: CONNECTIONS (route
-- touching town -- seamless, you can see across) and WARPS (doors, cave mouths). A house is only
-- ever reached by warp, so "translate peers on maps CONNECTED to mine, hide everyone else" is
-- routes-visible-houses-hidden with NO house special case -- measured, interiors carry mask=00.
-- It is also the distance cull of last resort: two maps away is not in my connection list, so
-- that peer does not exist for me at all.
--
-- EVERYTHING LIVES ON THIS ONE TABLE. This chunk sits at 197 of Lua's 200 top-level locals, and
-- past the ceiling the file does not misbehave -- it silently fails to load, which reads exactly
-- like a dead relay. One name, not eight.
--
-- HOW: translated AT INGEST into the local map's tile frame (see renderRemote), so every stage
-- downstream -- the range cull, both tiers, collision, the painted copy -- sees ordinary local
-- coordinates and needs no changes at all.
--
-- Structures and arithmetic: measured 2026-08-27, four driven crossings, one per direction, with
-- probes/connections_probe.lua and probes/seam_drive.lua. Full evidence in UNVERIFIED.md.
-- ON `ENGINE` RATHER THAN A NEW TOP-LEVEL LOCAL: this chunk is at Lua's 200-local ceiling and
-- a new name here does not error, it silently stops the file loading. ENGINE is the right home
-- anyway -- map connections are a fact about the engine, which is what that table holds.
ENGINE.xmap = {
	-- Filled from the selected address table at startup. nil on any build where the block has not
	-- been measured (Archipelago's), which switches this whole feature off rather than reading a
	-- plausible address -- `armed()` is the single gate.
	connAt = nil, wAt = nil, hAt = nil,
	conns = nil, connsFor = nil, ourW = 0, ourH = 0,
	-- Which (peer, their map, our map) triples have already been announced, so the cross-map
	-- line is written once per crossing instead of sixty times a second. Cleared with the rest
	-- of the per-map bookkeeping is NOT wanted: re-announcing on every map change is noise.
	said = {},
	-- EAST 0x01, WEST 0x02, SOUTH 0x04, NORTH 0x08 -- constants/map_data_constants.asm's
	-- shift_const order. The struct order in WRAM is north, south, west, east.
	DIRS = {
		{ name = "north", bit = 0x08, at = 1 },
		{ name = "south", bit = 0x04, at = 13 },
		{ name = "west", bit = 0x02, at = 25 },
		{ name = "east", bit = 0x01, at = 37 },
	},
}

-- A coordinate one tile past the west or north edge is stored as 255, not -1.
function ENGINE.xmap.signed8(v) return (v > 127) and (v - 256) or v end

function ENGINE.xmap.armed()
	return ENGINE.xmap.connAt ~= nil and ENGINE.xmap.wAt ~= nil and ENGINE.xmap.hAt ~= nil
end


-- Rebuilt when the local map changes, not every frame: the engine writes this block on map load
-- and never between loads, and re-reading 49 bytes a frame is exactly the shape this project keeps
-- warning about.
--
-- THE BITMASK IS AUTHORITATIVE AND THE UNFLAGGED STRUCTS ARE STALE. A direction the mask does not
-- claim still holds the PREVIOUS map's values -- measured on map 1/14, where south read 255/14 and
-- east read 255/12 while the mask said north+west. Reading a struct without checking its bit first
-- adopts an offset belonging to a map you already left.
function ENGINE.xmap.build(localKey)
	-- KEEP THE MAP WE JUST LEFT. Whether a map change was a seam or a warp is a question about the
	-- DEPARTING map's connections, and the answer is destroyed by this rebuild -- so the previous
	-- set is kept rather than assumed to still be current when the question is asked.
	--
	-- It has to be, because the rebuild usually happens FIRST: `receive()` runs before the
	-- map-change block in tick(), so on the frame you cross a seam an arriving peer state
	-- re-translates against the new map and rebuilds this table before anything asks what the old
	-- one was connected to. The first version of the seam test read `connsFor` and was therefore
	-- false every single time for the player doing the crossing -- which is precisely who saw the
	-- flicker, and precisely who did not get the fix meant for them.
	-- ...and only when the outgoing set is worth keeping. A build that caught the map mid-load can
	-- produce an EMPTY conns with a perfectly valid width -- the dimensions and the connection
	-- structs are not written on the same frame -- and stashing that emptiness over a good set
	-- loses the only record of what the map we are leaving was joined to. Measured 2026-08-27:
	-- crossings out of Route 40 misclassified as warps 4 times in 45 while the opposite direction
	-- was correct 45 out of 45, which is what a poisoned per-map cache looks like.
	if ENGINE.xmap.connsFor ~= localKey and next(ENGINE.xmap.conns or {}) ~= nil then
		ENGINE.xmap.prevConns, ENGINE.xmap.prevFor = ENGINE.xmap.conns, ENGINE.xmap.connsFor
		-- The DEPARTING map's own extent, kept for the same reason as its connections: the
		-- east/south rebase below is expressed in terms of the map being left, and that number is
		-- gone the moment this rebuild finishes.
		ENGINE.xmap.prevW, ENGINE.xmap.prevH = ENGINE.xmap.ourW, ENGINE.xmap.ourH
	end
	ENGINE.xmap.conns, ENGINE.xmap.connsFor = {}, localKey
	ENGINE.xmap.ourW = (u8(ENGINE.xmap.wAt) or 0) * 2   -- wMapWidth/wMapHeight are in BLOCKS, 2x2 tiles each
	ENGINE.xmap.ourH = (u8(ENGINE.xmap.hAt) or 0) * 2
	-- A BUILD THAT LANDS MID-LOAD MUST NOT BE CACHED. The engine has not written wMapWidth yet on
	-- the first frames of a map load, so this reads 0 and there is nothing to build -- but leaving
	-- `connsFor` set to this map would cache that emptiness FOREVER, because every later call is
	-- skipped by the `connsFor ~= here` guard that decides whether to rebuild.
	--
	-- The consequence was not a missing translation, it was a MISCLASSIFIED MAP CHANGE: with no
	-- connections recorded for the map being left, the seam test finds nothing naming the map
	-- being entered, calls a genuine seam crossing a WARP, and runs the full teardown -- which
	-- clears the painted tier and leaves the peer undrawn until it re-registers. Measured
	-- 2026-08-27 on the user's back-and-forth repro: one crossing in a lap classified WARP and the
	-- trace shows exactly 7 consecutive frames with neither tier holding the peer. Walking across
	-- and straight back makes builds land mid-load often, which is why pacing the seam shows it
	-- constantly and a single crossing usually does not.
	--
	-- Clearing `connsFor` costs one re-read on the next frame and makes the failure self-healing.
	if ENGINE.xmap.ourW <= 0 or ENGINE.xmap.ourH <= 0 then
		ENGINE.xmap.connsFor = nil
		return
	end
	local mask = u8(ENGINE.xmap.connAt) or 0
	for _, d in ipairs(ENGINE.xmap.DIRS) do
		if (mask & d.bit) ~= 0 then
			local at = ENGINE.xmap.connAt + d.at
			local g, n = u8(at + 0) or 0, u8(at + 1) or 0
			ENGINE.xmap.conns[g .. "/" .. n] = {
				dir = d.name,
				yOff = u8(at + 8) or 0,
				xOff = u8(at + 9) or 0,
			}
		end
	end
end

-- Translate a peer standing on a CONNECTED neighbour into our own tile frame, or leave it alone.
--
-- Each connection has an ALONG-axis field and a CROSS-axis field, and which is which flips with
-- the axis. The cross-axis field is a signed shift along the seam. The along-axis field is the
-- coordinate you LAND on in the neighbour -- 0 arriving from the east or south, and
-- (neighbourExtent - 1) arriving from the west or north -- so the negative directions recover the
-- neighbour's extent from it as `off + 1`, and the positive directions need our own.
--
-- `ConnectedMapWidth` is deliberately unused: it is always the neighbour's WIDTH, so on the
-- vertical axis it answers the wrong question. The first north form was built on it and landed a
-- peer 16 tiles out; the probe's own self-check caught it (UNVERIFIED.md, 2026-08-27).
--
-- Returns the translated x, y -- or nil, meaning "not on a map connected to mine", which every
-- caller treats exactly as it treated a foreign area_id before this feature existed.
-- THE INVERSE OF `translate`, for the frame change that happens when WE cross a seam.
--
-- Everything the painted tier is holding about a peer -- its model position, its painted position,
-- the tile it was last on -- is expressed in the map we are LEAVING. Crossing into the peer's own
-- map does not move the peer, but it does retire the coordinate frame those numbers are written
-- in, and they are wrong by exactly the translation that has just stopped applying.
--
-- Neither clearing nor keeping them works, and both were shipped and watched failing (2026-08-27):
-- clearing leaves the painted tier with nothing while a fresh model rebuilds, which is a gap;
-- keeping them leaves a model 20 tiles from the peer, so the promotion places the engine object on
-- that stale tile, the engine reclaims a slot it considers invalid, and the adapter respawns --
-- the user, twice: *"it still despawn/respawn the ghost that was in another route whenever you
-- walk into that route"*. Rebasing is the third option and the only correct one.
--
-- `from` is the map we left and `to` the one we arrived on. Returns the tile delta to ADD to a
-- coordinate in `from`'s frame to express it in `to`'s, or nil when the two are not connected --
-- a warp, where the caller falls back to clearing because nothing survives a warp anyway.
function ENGINE.xmap.rebaseDelta(from, to)
	local conns, ourW, ourH
	if ENGINE.xmap.connsFor == from then
		conns, ourW, ourH = ENGINE.xmap.conns, ENGINE.xmap.ourW, ENGINE.xmap.ourH
	elseif ENGINE.xmap.prevFor == from then
		conns, ourW, ourH = ENGINE.xmap.prevConns, ENGINE.xmap.prevW, ENGINE.xmap.prevH
	end
	local c = conns and conns[to]
	if not c or not ourW or ourW <= 0 then return nil end
	-- Each line is `translate` solved for the other side. Read them against it: whatever it
	-- subtracts, this adds.
	if c.dir == "west" then
		return c.xOff + 1, ENGINE.xmap.signed8(c.yOff)
	elseif c.dir == "east" then
		return -ourW, ENGINE.xmap.signed8(c.yOff)
	elseif c.dir == "north" then
		return ENGINE.xmap.signed8(c.xOff), c.yOff + 1
	end
	return ENGINE.xmap.signed8(c.xOff), -ourH
end

-- Shift one painted entry into the new frame. Tile-valued fields move by the tile delta and
-- pixel-valued ones by sixteen times it; both lists are explicit rather than inferred from the
-- field name, because a position this misses is not a crash, it is a ghost a few tiles off.
function ENGINE.xmap.rebaseEntry(o, dx, dy)
	if type(o) ~= "table" then return end
	for _, k in ipairs({ "x", "lastX" }) do
		if type(o[k]) == "number" then o[k] = o[k] + dx end
	end
	for _, k in ipairs({ "y", "lastY" }) do
		if type(o[k]) == "number" then o[k] = o[k] + dy end
	end
	-- modelX/Y are MAP-pixel positions and move with the frame. paintedX/Y are SCREEN positions
	-- and are deliberately NOT here: the screen is continuous across a seam, so shifting them
	-- manufactured a false TWITCH on every crossing and nothing else.
	if type(o.modelX) == "number" then o.modelX = o.modelX + dx * 16 end
	if type(o.modelY) == "number" then o.modelY = o.modelY + dy * 16 end
end

function ENGINE.xmap.translate(srcArea, sx, sy)
	local c = ENGINE.xmap.conns and ENGINE.xmap.conns[srcArea]
	if not c then return nil end
	if c.dir == "west" then
		return sx - (c.xOff + 1), sy - ENGINE.xmap.signed8(c.yOff)
	elseif c.dir == "east" then
		return sx + ENGINE.xmap.ourW, sy - ENGINE.xmap.signed8(c.yOff)
	elseif c.dir == "north" then
		return sx - ENGINE.xmap.signed8(c.xOff), sy - (c.yOff + 1)
	end
	return sx - ENGINE.xmap.signed8(c.xOff), sy + ENGINE.xmap.ourH
end

----------------------------------------------------------------------------
-- get_local_state
----------------------------------------------------------------------------

local DIR_NAMES = { [0] = "down", [4] = "up", [8] = "left", [12] = "right" }

-- ONE LETTER PER DIRECTION, DERIVED -- never written out by hand again.
--
-- Three instruments each hand-rolled this as the literal "durl", which is down/up/RIGHT/LEFT where
-- this adapter's dir index is down/up/LEFT/right. Every left and right label in all three was
-- therefore swapped at once, which inverted a MEASURED conclusion about the scroll registers'
-- sign convention and shipped a rendering that sent ghosts off the screen (2026-08-23). Nothing
-- was wrong with the measurement; the labels lied about which direction had been measured.
--
-- Derived from DIR_NAMES so it cannot diverge from it: a dir index is the engine's facing byte
-- divided by four, and the letter is that name's initial. If DIR_NAMES ever changes, this follows.
-- ON `DIR_NAMES` itself, not a new top-level local: this file sits at 197 of Lua's 200 and adding
-- one crossed the ceiling on the first try, which does not error -- it silently fails to load.
-- A string key cannot collide with the numeric facing bytes this table is keyed by.
DIR_NAMES.letter = {}
for i = 0, 3 do
	DIR_NAMES.letter[i] = (DIR_NAMES[i * 4] or "?"):sub(1, 1)
end
-- A label is data: assert it rather than trusting the eye that wrote it. Cheap, once, at load.
assert(table.concat(DIR_NAMES.letter, "", 0, 3) == "dulr",
	"DIR_NAMES.letter disagrees with DIR_NAMES -- a direction table changed without its labels")

-- THE ENGINE'S THREE GAITS, from its own table rather than from this file's assumptions.
--
-- `GetStepVector` (engine/overworld/map_objects.asm) indexes `StepVectors` with
-- `OBJECT_WALKING & $0F`, and the table is three groups of four directions:
--   0-3  slow    1px per tick, 16 ticks
--   4-7  normal  2px per tick,  8 ticks
--   8-11 fast    4px per tick,  4 ticks
-- Every group crosses one 16px tile; what differs is how long it takes. Indexed here by group
-- number (0/1/2) so a gait is one small integer everywhere -- on the wire, in the progress
-- calculation, and in the write that starts a ghost's step.
--
-- MEASURED, not assumed (2026-08-25, on the running game while biking a lap): the player's own
-- OBJECT_WALKING held 08 and 09 -- group 2, fast -- with OBJECT_STEP_DURATION counting 3, 2, 1.
-- Walking holds 4-7. So the byte carries the gait and nothing else has to be inferred.
--
-- GROUP 3 IS NOT VANILLA'S, AND IT IS STILL THE ENGINE'S. `GetStepVector` masks the walking byte
-- with $0F, which is sixteen entries' worth of index for a table vanilla fills only twelve of --
-- so the room for a fourth gait is something vanilla left, not something a patch invents, and a
-- patched build can fill it without touching a single line of the routine that reads it. One
-- does: measured 2026-08-26 by scanning four cartridges for the table's own byte signature (see
-- ENGINE.gaitGroups below), three vanilla-derived builds carry three groups and the Archipelago
-- patch carries four, the fourth being 8 pixels a tick for 2 ticks -- a tile in two frames.
--
-- Listing it here costs a vanilla session nothing, because nothing on a three-group cartridge
-- ever writes index 12-15 and so nothing ever reads this row. What it buys is that every piece of
-- arithmetic in this file that already asks "how fast is this peer's gait" -- the progress the
-- sender puts on the wire, the drawn tier's stride and its camera-copy budget, the duration the
-- spawned tier writes -- gets the right answer for a peer on a build that has one, with no
-- branch anywhere asking which build that is.
--
-- WHAT IT DOES NOT DECIDE is whether this cartridge may be told to walk at it. That is
-- ENGINE.gaits(), and it is a separate question because the answer differs between the two ends
-- of the wire: a peer reports the gait its own ROM gave it, and the receiver has to answer from
-- its own.
local GAIT_PX = { [0] = 1, [1] = 2, [2] = 4, [3] = 8 }
local GAIT_TICKS = { [0] = 16, [1] = 8, [2] = 4, [3] = 2 }

-- The gait this cartridge may be TOLD to walk at, clamped to what its own table can index. A peer
-- faster than anything here is stepped at this ROM's fastest instead, and is meanwhile kept off
-- the spawned tier entirely (see `paceable` in renderRemote) so the clamp is a floor under a
-- decision already made rather than the thing a player sees.
--
-- IT LIVES HERE, DIRECTLY BELOW THE TABLE IT READS, AND THAT IS THE WHOLE POINT. It was first
-- written 100 lines above, beside ENGINE.gaitGroups, where the two obviously belong together --
-- and `GAIT_PX` is a local declared BELOW that point, so inside the function the name resolved to
-- a nil GLOBAL. The file parsed, loaded, ran, and threw `attempt to index a nil value (global
-- 'GAIT_PX')` on the first frame a peer actually stepped, which the dev loader answered by
-- unloading the whole adapter mid-session (2026-08-26). `luac -p` cannot see this and never could:
-- it proves the file parses, not that a name resolves. This file's own pitfall, hit for the fifth
-- time -- see `agent_docs/pitfalls.md`, "a local declared BELOW a function is a nil global inside
-- it". Anything reading GAIT_PX or GAIT_TICKS goes below this line or on a table.
function ENGINE.gait(g)
	if not GAIT_PX[g] then
		return 1
	end
	local max = (ENGINE.gaits or 3) - 1
	return g > max and max or g
end

-- IS THE CAMERA PAIR ACTUALLY THE CAMERA ON THIS BUILD? Asked of the running game, once, and only
-- while the local player is genuinely mid-step.
--
-- THE HOLE THIS FILLS. Every other address in this adapter fails loudly on a build it was not
-- measured for -- a nil entry refuses, and a wrong WRAM read tends to break the in-play gate. The
-- camera pair cannot: it lives in HRAM, which always reads, so a wrong address returns a
-- plausible small number every frame and the `or W_BGMAPOFFSET` fallback beside it never fires.
-- `UNVERIFIED.md` predicted precisely that on 2026-08-23 and it came true on 2026-08-26 -- on the
-- Archipelago build the adapter had been reading two DEAD BYTES as its camera clock, and what
-- reached the screen was a peer standing perfectly still painted gliding across the ground.
--
-- The test is the same one the probe uses, reduced to what can be asked for free every frame: a
-- camera MUST change while the player is walking. Sixty seconds of the player mid-step with two
-- or fewer distinct values on both registers is not a camera, whatever else it is. On a build
-- where the pair is right this arms in the first step or two and then costs one comparison.
--
-- IT DEMOTES RATHER THAN REFUSES. `wPlayerBGMapOffset` is measured on both builds and is a worse
-- clock -- a per-frame delta rather than an absolute, disagreeing with the camera on ~9% of
-- frames (`documentation.md`) -- but a worse clock is enormously better than a dead one, and a
-- ghost that is slightly rough beats a ghost that slides across the map. It says so once, by
-- address, so the next session measures the pair instead of rediscovering the symptom.
ENGINE.camSeen = {}
function ENGINE.camCheck(hcx, hcy)
	if ENGINE.camDead or ENGINE.camOk then
		return
	end
	-- ONLY WHILE THE PLAYER IS MID-STEP. A camera is *supposed* to hold still otherwise, so
	-- counting standing frames would be counting the thing that makes a dead byte look alive.
	if (u8(OBJECT_STRUCTS + F_WALKING) or STANDING) == STANDING then
		return
	end
	local n = (ENGINE.camWalked or 0) + 1
	ENGINE.camWalked = n
	local s = ENGINE.camSeen
	if hcx then s["x" .. hcx] = true end
	if hcy then s["y" .. hcy] = true end
	local nx, ny = 0, 0
	for k in pairs(s) do
		if k:sub(1, 1) == "x" then nx = nx + 1 else ny = ny + 1 end
	end
	-- Three distinct values on either axis is a register that is being written as the world
	-- scrolls; that is enough, and stopping there keeps this off the frame budget for good.
	if nx > 2 or ny > 2 then
		ENGINE.camOk = true
		return
	end
	if n >= 3600 then -- a full minute of WALKING, not of wall-clock
		ENGINE.camDead = true
		log(string.format("MeshGhost: $%04X/$%04X do not behave like the camera on this ROM -- "
			.. "%d distinct X and %d distinct Y across %d frames of the player actually walking. "
			.. "Falling back to the BG map offset, which is measured on this build but is a "
			.. "per-frame delta rather than an absolute scroll, so a painted peer will be rougher "
			.. "than it should be. MEASURE the camera pair on this build "
			.. "(probes/ap_hram_scroll_probe.lua) and put it in this adapter's address table.",
			ENGINE.scxAddr or 0, ENGINE.scyAddr or 0, nx, ny, n))
	end
end

-- Which gait an object is walking at, or nil while it is standing (the byte is $FF then and says
-- nothing). The caller decides what a standing object should be reported as.
local function stepGait(base)
	local w = u8(base + F_WALKING) or STANDING
	if w == STANDING then
		return nil
	end
	local group = (w & 0x0F) // 4
	if not GAIT_PX[group] then
		return nil
	end
	return group
end

-- Held across the standing frames between steps. A gait read only while mid-step would be missing
-- at exactly the moment a receiver needs it -- the frame a peer STARTS moving -- so the last one
-- actually observed is what gets sent, defaulting to a normal walk before anything has been seen.
local lastGait = 1

-- The gait to SEND: this object's own if it is mid-step, otherwise the last one it was seen at.
local function rememberGait(base)
	local group = stepGait(base)
	if group then
		lastGait = group
	end
	return lastGait
end

-- Pixels travelled into the current step, 0-16, at whatever gait the object is walking.
local function stepProgress(base)
	local group = stepGait(base)
	if not group then
		return 0
	end
	local dur = u8(base + F_STEP_DURATION) or 0
	local px = (GAIT_TICKS[group] - dur) * GAIT_PX[group]
	if px < 0 then px = 0 end
	if px > 16 then px = 16 end
	return px
end

local function getLocalState()
	if not inPlay() then
		return nil -- a menu, a battle, a warp: nothing meaningful to send
	end
	-- DEV ONLY: MESHGHOST_CRYSTAL_FREEZE_STATE pins what this client SENDS to the first state it
	-- ever sent, so a loopback ghost stops mirroring the player and stands still while the player
	-- walks around it. Asked for 2026-08-22 to test collision and hitboxes by walking INTO a ghost,
	-- which a ghost that copies your every move can never let you do.
	--
	-- It freezes the SEND side rather than the receive side on purpose: one place, and both tiers
	-- see exactly the same frozen peer, so the spawned and painted copies stay comparable. Note the
	-- area is frozen too, so changing map while this is on leaves the ghost describing a map it is
	-- no longer on -- fine for a local test, useless for anything else. Never set in a release.
	-- A BARE GLOBAL, not a local and not a field on one of this file's tables. Every table here
	-- (`playerHistory`, `facingFrames`) is declared HUNDREDS of lines below this function, so
	-- naming one resolves to nil and throws on the first tick -- which is exactly what happened
	-- 2026-08-22, and is the third time this file has hit the trap `pitfalls.md` records as "a
	-- local declared BELOW a function is a nil global inside it". A global also costs nothing
	-- against Lua's 200-local ceiling, which this file sits at.
	if MESHGHOST_CRYSTAL_FREEZE_STATE and MESHGHOST_CRYSTAL_FROZEN then
		return MESHGHOST_CRYSTAL_FROZEN
	end
	local base = OBJECT_STRUCTS
	local facing = u8(base + F_DIRECTION) or 0
	return {
		area_id = areaId(),
		-- FOUR COMPONENTS. `position` is `[]float64` and VARIABLE LENGTH by contract -- two for
		-- Emerald, three for Pseudoregalia, up to eight -- and `core/interp.go` interpolates every
		-- one of them. `extras` is opaque by contract and is NOT interpolated.
		--
		-- Sending only whole tiles means the core spends a whole step interpolating between two
		-- IDENTICAL values and outputs a constant, then lurches when the tile changes. Measured at
		-- the shipped 250ms before this change: of 1911 messages, 1838 carried no movement at all
		-- and the 72 that did jumped 4-6px. That is the staircase, and no renderer can undo it --
		-- the smooth motion is simply not on the wire.
		--
		-- Components 3 and 4 are the character's position in MAP PIXELS, absolute rather than an
		-- offset: a tile index and an offset-from-destination are redundant, and interpolating them
		-- independently cancels at a boundary because the tile rises by one exactly as the offset
		-- falls by sixteen. One continuous quantity has no boundary to disagree across.
		--
		-- Components 1 and 2 keep their meaning exactly, so the spawned tier -- confirmed good on
		-- screen -- reads what it always did.
		position = (function()
			local mx, my = u8(base + F_MAP_X) or 0, u8(base + F_MAP_Y) or 0
			local px, py = mx * 16, my * 16
			if (u8(base + F_WALKING) or STANDING) ~= STANDING then
				-- MAP_X/Y are written at the START of a step and already name the DESTINATION, so
				-- the character is `16 - prog` pixels short of it, back along the way it came.
				local back = stepProgress(base) - 16
				local d = (facing // 4) & 3
				if d == 0 then py = py + back
				elseif d == 1 then py = py - back
				elseif d == 2 then px = px - back
				else px = px + back end
			end
			return { mx, my, px, py }
		end)(),
		orientation = DIR_NAMES[facing] or "down",
		anim = ((u8(base + F_WALKING) or STANDING) ~= STANDING) and "walk" or "idle",
		-- `act` is OBJECT_ACTION, the byte the engine itself uses to decide which animation an
		-- object is playing -- fishing, bumping a wall, spinning on a spin tile, the "!" emote,
		-- the Fly landing. It is one byte for all of them because Crystal indexes a table with
		-- it (ObjectActionPairPointers), so a ghost that carries the peer's action byte gets the
		-- animation played by the game rather than imitated by us. phase9.md's enumeration.
		-- `prog` is how far through its current step this character is, in PIXELS (0-16), and it is
		-- the peer's own truth rather than something the receiver infers from arrival times.
		--
		-- The painted tier has no sub-tile position without it: the wire carries tiles, so a peer
		-- can only be drawn ON a tile, and a step becomes a 16px jump. The spawned tier never had
		-- this problem because the ENGINE interpolates for it.
		--
		-- Derived from the engine's own countdown: a normal step is 8 frames at 2px
		-- (StepVectors), and OBJECT_STEP_DURATION counts down through it, so pixels travelled is
		-- (8 - duration) * 2. Zero while standing, which is exactly right.
		-- `face` is OBJECT_FACING, and only its low two bits matter to a receiver: the stride index
		-- the ENGINE chose for this character, which is what says which foot a stepping frame is
		-- on. Down and up mirror their stepping view between strides; left and right cannot, since
		-- there the flip is what says which way the character looks. A receiver never has to know
		-- which case it is in -- it looks up the frame the engine drew for that stride.
		--
		-- One byte, and per STEP rather than per frame, so it is nothing like the smoothness-
		-- critical values `pitfalls.md` warns must not ride in `extras`.
		-- `gait` is the group number above, so a receiver steps a ghost at the pace the peer is
		-- actually moving instead of assuming a walk. One byte, changing only when the player
		-- mounts or dismounts.
		-- `yoff` is OBJECT_SPRITE_Y_OFFSET (0x1a), the engine's own vertical nudge on top of the
		-- character's tile position -- the ONE field that carries every up-and-down a character
		-- does without changing tile. The bite wiggle is this alternating 0/1 for eight ticks
		-- (`StepFunction_GotBite`), and the Fly, Dig and Teleport falls are the same byte over a
		-- longer arc. Without it a ghost stands perfectly still through all of them; the user,
		-- 2026-08-26: *"they are supposed to shake/wiggle a bit & get a !, above their head"*.
		-- Signed, two's complement in one byte, exactly as the engine stores it.
		--
		-- `emote` is the "!" and its family -- see playerEmote() for why it is a scan and a tile
		-- match rather than a field. nil for no emote, which is nearly always.
		-- `entry` is HOW THIS PLAYER LAST ENTERED THE MAP -- the engine's own MAPSETUP_* byte
		-- (see ENGINE.entryAddr at the bottom of the file), latched at the warp and attached for
		-- ~4s afterwards, which spans the Fly cutscene's own silence. A receiver that sees a
		-- position jump wearing $FC (MAPSETUP_FLY) knows the peer arrived from the sky and can
		-- say so; every other value is sent as-is and currently ignored. Opaque engine
		-- vocabulary, exactly like `act`.
		-- `jump` is TRUE WHILE THIS PLAYER IS HOPPING A LEDGE, and it is the one thing about a hop
		-- that is not already on the wire. `JumpStep` (engine/overworld/movement.asm) writes
		-- OBJECT_ACTION_STEP and the ordinary walking gait, so `act` says "walking" and `gait` says
		-- "walking" -- the ONLY field that distinguishes a hop from a step is OBJECT_STEP_TYPE,
		-- which is STEP_TYPE_PLAYER_JUMP (9) for the player's own object across both tiles.
		--
		-- Sent as a bool rather than the raw step type on purpose. The receiver does not want the
		-- peer's step type -- it must never write 9 onto a ghost, because that is the PLAYER's jump
		-- and `StepFunction_PlayerJump` drives wPlayerStepFlags and the camera. What it wants is
		-- STEP_TYPE_NPC_JUMP (8), the same animation for an object that is not the centred one.
		-- So the wire carries the QUESTION ("is this peer hopping?") and each side answers it in
		-- its own vocabulary, which is what keeps `act`-style opacity without inviting a
		-- copy-the-byte bug.
		-- `gfx` is what makes `sprite` readable by anyone but ourselves: the signature of this
		-- cartridge's own sprite table (see ENGINE.gfxSig at the bottom of the file). A sprite id
		-- is an index, and a patch may repoint an entry without moving the table -- so the id
		-- alone is a number two clients can agree on and still disagree about. Constant for the
		-- session; sent every state because a receiver that joins late has no earlier packet to
		-- have read it from.
		extras = { sprite = u8(base + F_SPRITE) or 0,
			-- The signature of THIS SPRITE's own table row, not of the whole table. See
			-- ENGINE.spriteSig: a receiver wears the id only if its own cartridge describes that id
			-- the same way, so a bike or a surf blob crosses between builds that agree about it
			-- while a repointed id falls back on its own.
			gfx = ENGINE.spriteSig(u8(base + F_SPRITE) or 0),
			act = u8(base + F_ACTION) or 0,
			prog = stepProgress(base), face = u8(base + F_FACING) or 0,
			gait = rememberGait(base), yoff = u8(base + 0x1A) or 0,
			jump = ((u8(base + F_STEP_TYPE) or 0) == 9) or nil,
			emote = ENGINE.playerEmote(),
			entry = (ENGINE.entryAt and emu.framecount() - ENGINE.entryAt < 240)
				and ENGINE.entry or nil,
			-- The species that carried this player, for the same window as `entry`. One byte, and
			-- only ever non-nil around a fly.
			fly = (ENGINE.entry == 0xFC and ENGINE.entryAt
				and emu.framecount() - ENGINE.entryAt < 240) and ENGINE.flySpecies or nil },
	}
end

-- Wrap the above so the freeze flag captures exactly one real sample and then repeats it.
local getLocalStateLive = getLocalState
function getLocalState()
	local st = getLocalStateLive()
	if MESHGHOST_CRYSTAL_FREEZE_STATE and st and not MESHGHOST_CRYSTAL_FROZEN then
		MESHGHOST_CRYSTAL_FROZEN = st
		logFile("FREEZE: peers pinned to " .. tostring(st.position[1]) .. ","
			.. tostring(st.position[2]) .. " -- both ghosts will stand still while you walk")
	end
	return st
end

----------------------------------------------------------------------------
-- Ghosts: spawn, move, despawn. The Phase 9 recipe.
----------------------------------------------------------------------------

local ghosts = {} -- player_id -> { mo, st, mo_base, st_base, area }

-- Peers the engine had no room for. They are DRAWN instead of spawned (see the drawn tier below),
-- so every peer is visible even past the game's own limits -- the user's requirement, 2026-08-19.
local overflow = {} -- player_id -> { x, y, sprite }

-- Per-peer activity, for the collision policy: the frame each peer last CHANGED TILE, and the
-- frame until which it has been made passable by someone shoving into it.
local activity = {} -- player_id -> { x, y, movedAt, passableUntil }
local policyFrames = 0

function ghostCount()
	local n = 0
	for _ in pairs(ghosts) do
		n = n + 1
	end
	return n
end

-- Rate limit for the map-is-full line below; see spawnGhost.
local fullLoggedAt = nil

-- ALLOCATE FROM THE TOP DOWN, because the engine allocates from the bottom up.
--
-- Two reasons, and the second is a real bug the user found on 2026-08-19:
--   * Taking slots from the opposite end keeps ghosts and the game's own characters out of each
--     other's way as both pools fill.
--   * The Game Boy draws at most 10 sprites on a scanline and keeps the FIRST TEN IN OAM ORDER,
--     which follows struct order. Allocating low put ghosts ahead of the game's own cast in that
--     queue, so when a crowd shared a row the NPCs were the ones that lost halves of themselves --
--     watched on screen, and confirmed by a probe counting sprites per scanline. Allocating high
--     inverts it: when the hardware has to drop someone, it drops a GHOST. Emerald's adapter
--     already allocates from the top for the same reason.
local function freeMapObject()
	for i = NUM_MAP_OBJECTS - 1, 1, -1 do
		if u8(MAP_OBJECTS + i * MAPOBJECT_LENGTH + M_SPRITE) == 0 then
			return i
		end
	end
end

-- Structs the engine must always be able to get, no matter how many peers turn up.
--
-- THIS IS NOT TUNING, IT IS A BUG FIX. The engine hands a struct to each of its own characters as
-- they come into range and takes it back when they leave; a ghost carries ENGINE.WONT_DELETE, so
-- it holds one FOREVER, anywhere on the map. With a crowd of peers standing around, ghosts held
-- 11 of the 13 structs and the game had none left for itself -- measured 2026-08-19 with an NPC
-- standing ONE TILE from the player and simply not drawn, plus its own cast flickering in and out
-- as slots happened to free up. The user saw both before the probe did.
--
-- Ghosts are guests in this array. Three is enough for the NPCs that can be near the player at
-- once on the maps measured; the cost is a lower ghost ceiling (9 -> 6 in New Bark Town), which is
-- the right trade in a heartbeat: a peer who does not appear is a missing ghost, an NPC who does
-- not appear is the player's own game breaking.
local RESERVED_STRUCTS_FOR_THE_GAME = 3

-- The Game Boy draws at most 10 sprites on a scanline, and an overworld character is 4 of them
-- (2x2 of 8x8 tiles) -- so ten characters is the hardware's own ceiling and the eleventh loses
-- pieces of itself, whoever it is. Spawning past that does not add a peer, it adds FLICKER.
--
-- The user's call, 2026-08-19, asked directly: "cap it... i don't want things to pop in/out all
-- the time. i want every player/ghost to be visible all the time instead." So the adapter stops
-- at what the hardware can actually draw, and everything it does draw is solid. Peers past the
-- cap are cleanly absent -- the same honest absence as a peer past the slot limit -- until the
-- drawn-overflow tier exists to carry them (agent_docs/ideas.md).
local HARDWARE_CHARACTER_LIMIT = 10

-- How far a peer can be before its ghost gives its slots back. The visible window is 10x9 tiles,
-- so this keeps a ghost alive a little past the edge -- far enough that walking toward a peer
-- never shows a character appearing out of nothing, close enough that a peer across the map is
-- not holding a struct the game needs. See renderRemote for what this fixes.
local GHOST_RANGE_TILES = 8

-- COLLISION POLICY (user's design, 2026-08-19). A spawned ghost is a real object and blocks its
-- tile, which is right while a peer is playing and wrong the moment they wander off for coffee on
-- a doorstep. Rather than inventing a collision flag, a peer that should not be blocking is
-- rendered by the DRAWN tier instead -- a drawn ghost has no tile at all, so it cannot block
-- anything, and its engine slot goes to somebody who is actually moving.
--
-- Two rules decide it:
--   IDLE. A peer that has not CHANGED TILE for this long stops blocking. Turning on the spot does
--   not count as activity, deliberately -- the user's words: "include just facing directions as
--   nothing... have you actually move a tile or something to be considered active".
--
--   RAISED FROM 5 SECONDS TO ONE MINUTE, 2026-08-26, on the user's request. Five seconds turned
--   out to describe "stood still briefly" rather than "wandered off": a peer reading a sign, in a
--   menu, or in a battle is idle by this test within moments, and demoting them costs the engine's
--   own animation, occlusion and collision for as long as they stay put. A minute is much closer
--   to the thing the rule is actually for.
--
--   WHAT RAISING IT DOES NOT COST, and this is why it is safe: the BLOCKED rule below is
--   independent and unchanged, so a player pressing into an idle ghost still gets past in half a
--   second. Doorways and chokepoints never depended on this timer.
--
--   WHAT IT DOES COST: an idle peer holds an engine object struct for a minute instead of five
--   seconds. Crystal has 13, and RESERVED_STRUCTS_FOR_THE_GAME keeps 3 of them for the game's own
--   cast -- so in a crowd, more peers will be on the drawn tier at any moment. That is the
--   intended failure direction (a peer is painted rather than absent) and `crowd-limits.md` has
--   the measured numbers, but a busy room is where to look if the game's own NPCs start going
--   missing.
--
--   IT IS NOT COVERING FOR THE HANDOVER, and the order of events matters. The stale-overlay fix
--   earlier the same day removed the persistent third character, and the user then reported the
--   brief down-facing copy looked gone with it -- *"it looked like the 'always facing down' thing
--   was fixed. thats why i suggested also increasing the timer now"*. So this is a design change
--   made on top of a seam that appears healthy, not a rate change used to hide one.
--
--   What it does still do is make the demote/promote pair much rarer, so it is worth knowing that
--   this timer now stands between anyone and that seam. "Looked fixed" is one session's
--   observation, and from here it gets twelve times less exposure: if a handover artefact is ever
--   suspected again, lower this FIRST to get the event rate back, rather than concluding from a
--   quiet session that the seam is fine.
local IDLE_FRAMES_BEFORE_PASSABLE = 3600 -- one minute
--   BLOCKED. If the player is pressing INTO a ghost and not moving, that ghost stops blocking
--   almost immediately. This is what makes doorways and route exits work without the adapter
--   needing to know where they are: the map's warp table lives in ROM behind a bank pointer, and
--   a rule based on "someone is trying to get past you" covers every chokepoint, not just doors.
local PUSH_FRAMES_BEFORE_PASSABLE = 30 -- half a second of shoving
local PASSABLE_HOLD_FRAMES = 180 -- and it stays passable for a few seconds afterwards

-- HOW FAR INTO ITS STEP THE PEER MUST BE BEFORE THE GHOST TAKES ONE, in pixels of 16.
--
-- The spawned tier used to start a step the moment the peer's TILE changed, and that is the wrong
-- clock. `position` carries the peer's tile in [1],[2] and its map pixels in [3],[4]; the core lerps
-- all four the same way, because nothing in `core/` may know which is which (ADR 2026-08-20). But a
-- tile index only ever moves in WHOLE STEPS -- MAP_X/Y jump to the destination the instant a step
-- begins -- so lerping it turns an exact instant into a ramp as long as the gap between samples, and
-- `math.floor` crosses that ramp at a moment that depends on where the jump fell between them.
--
-- Measured 2026-08-23 across three rigs: the spread of the ghost's step-start lag was 3 frames at the
-- shipped 20Hz, 0 frames at 100Hz, and 3 frames again at 20Hz with the shipped 250ms interpolation --
-- i.e. exactly the relay's sample interval, every time. Interpolation delay changes WHEN a sample is
-- rendered, never how far apart samples are, so it could not help and did not.
--
-- The pixel position has no such problem: a walking character's pixels really are continuous, so
-- lerping them is correct and the value can be trusted between samples. This reads the peer's
-- progress from THEM instead, and starts the ghost's step at a fixed progress rather than at a
-- floor() crossing. The lag becomes a constant, and a constant lag has nothing to be judged against
-- -- what a player can see is the lag CHANGING from step to step, which is the walk/hesitate/walk the
-- user reported as *"slightly behind/slow/late"* (2026-08-22).
--
-- 4 of 16 pixels: comfortably past the ~2 frames of pipeline the same measurement showed to be
-- irreducible (flat 2 at 100Hz, every step), and a quarter of a step of standing lag, which is less
-- than the tile-change trigger was already paying on average.
--
-- SET IT TO 0 TO REVERT EXACTLY. Zero means "step as soon as the tile says so", which is the old
-- behaviour, and it gates the work rather than the decision -- a flag that only moved the choice
-- would leave this cost running while claiming to be off (`CLAUDE.md`).
--
-- It cannot help at `-interp=0ms`, and that is not a defect in it: with interpolation off the pixel
-- position is the newest 20Hz sample and jumps in threes like everything else. The dev rig removes
-- the very mechanism this leans on, so judge it at shipped settings.
local STEP_TRIGGER_PROG = 4

-- hJoypadDown and its four direction bits. ONE TABLE, not five names: see the local-limit note
-- beside COMPARE_TIERS -- this file compiles at 200 and these five were four of the last ones.
local JOY = { addr = 0xFFA4, right = 0x01, left = 0x02, up = 0x04, down = 0x08 }

-- Should this peer be solid right now? See the collision policy constants above.
--
-- Returns false when the peer is idle, or when the player is shoving into it -- and the caller
-- then renders it through the drawn tier, which has no collision at all.
-- Per-FRAME state for the policy, refreshed once by beginPolicyFrame() rather than re-read for
-- every peer. With a crowd this is the difference between a handful of memory reads a frame and
-- several hundred: measured 2026-08-19, the per-peer version cost ~9% of the frame rate on its
-- own (60fps -> 54.5) with a screen full of peers and nothing drawn at all.
local frameState = { px = 0, py = 0, standing = true, wantX = 0, wantY = 0 }

local function beginPolicyFrame()
	policyFrames = policyFrames + 1 -- ONCE per frame; incrementing per peer made the idle timeout
	                                -- mean itself divided by the number of peers.
	local px, py = u8(OBJECT_STRUCTS + F_MAP_X) or 0, u8(OBJECT_STRUCTS + F_MAP_Y) or 0
	frameState.px, frameState.py = px, py
	frameState.standing = (u8(OBJECT_STRUCTS + F_WALKING) or STANDING) == STANDING
	frameState.wantX, frameState.wantY = px, py
	if frameState.standing then
		local joy = memory.read_u8(JOY.addr, "System Bus") or 0
		if (joy & JOY.right) ~= 0 then frameState.wantX = px + 1
		elseif (joy & JOY.left) ~= 0 then frameState.wantX = px - 1
		elseif (joy & JOY.down) ~= 0 then frameState.wantY = py + 1
		elseif (joy & JOY.up) ~= 0 then frameState.wantY = py - 1 end
	end
end

-- OBJECT_ACTION values that mean "standing on this tile doing nothing in particular": the two
-- the engine gives an ordinary walking character, plus 0, which is the uninitialised entry.
-- Anything else is an animation in progress -- see ACTIONS.peer.
-- Both sets live on ONE table rather than two, because this file is close to Lua's 200-local
-- limit in its main chunk and every top-level name spends one of them. Hit for real 2026-08-21.
local ACTIONS = {}
ACTIONS.idle = { [0] = true, [1] = true, [2] = true }

local function shouldBlock(id, x, y, act)
	-- DEV ONLY, and it pairs with MESHGHOST_CRYSTAL_FREEZE_STATE: a frozen peer is by definition
	-- idle, so both shipped anti-stuck rules below would fire within seconds -- the five-second
	-- idle rule makes it passable AND demotes it to the painted tier (which has no collision at
	-- all), and pushing into it makes it passable on purpose. Either one ends a hitbox test before
	-- it starts. Holding it solid is the only way to walk into the same ghost twice.
	--
	-- Testing those two rules THEMSELVES means turning this off: they are real shipped behaviour,
	-- not something in the way.
	-- DEV ONLY: nothing blocks, ever. Asked for 2026-08-23, while judging the drawn tier's motion:
	-- *"im still unsure if we are just running into the spawned ghosts collission"* -- and the
	-- suspicion is well founded, because both shipped escape hatches are unreachable for a ghost
	-- that is WALKING. The idle rule needs a full minute on one tile (five seconds until
	-- 2026-08-26) and the shove rule needs the player standing still and pressing into it; a moving
	-- ghost satisfies neither, so it blocks for as long as it keeps moving. The user's own
	-- observation, which is the tell: *"it was perfect while the spawned ghost was standing
	-- still"* -- a standing ghost eventually goes passable and stops being in the way. Note the
	-- raised timer makes THIS flag matter more, not less: the wait it removes is now twelve times
	-- longer.
	--
	-- A bumped player stutters no matter how good the ghost is, so this confound has to be
	-- removable before any judgement of motion can be trusted.
	--
	-- Note what it does, because it is not a collision flag: this adapter has none. "Not blocking"
	-- IS "rendered by the drawn tier" by design, so with this on the peer appears as a DRAWN ghost
	-- rather than a spawned one. Nothing to walk into, and nothing spawned to compare against.
	if MESHGHOST_CRYSTAL_GHOSTS_PASSABLE then
		return false
	end
	if MESHGHOST_CRYSTAL_FREEZE_STATE then
		return true
	end
	local a = activity[id]
	if not a then
		a = { x = x, y = y, movedAt = policyFrames, passableUntil = 0 }
		activity[id] = a
	end
	if a.x ~= x or a.y ~= y then
		-- REMEMBER THE TILE IT IS STEPPING OUT OF, because the engine blocks on both. The player's
		-- own step tests its destination with `IsNPCAtCoord`, which compares each object's current
		-- coords AND its `LAST_MAP_X`/`LAST_MAP_Y` (`engine/overworld/npc_movement.asm`), so a
		-- character part-way through a step is a two-tile obstacle. The shove rule below only ever
		-- compared the current one, which is why shoving a MOVING ghost never released it.
		a.lastX, a.lastY = a.x, a.y
		a.x, a.y, a.movedAt = x, y, policyFrames
	end
	-- A peer who is FISHING has not changed tile for a while and is emphatically not idle. The
	-- five-second rule exists to give the engine back a slot nobody is using and to stop an
	-- unseen ghost being an invisible wall; a peer playing an animation is neither of those, and
	-- dropping them to the drawn tier would be the one place their animation is not rendered.
	if act ~= nil and not ACTIONS.idle[act] then
		a.movedAt = policyFrames
	end

	-- Is the player pressing INTO this peer's tile without getting anywhere? Facing alone is not
	-- enough: a player can stand facing a friend all day. The d-pad has to be held, and the
	-- player has to still be standing (a successful step means nothing was blocking).
	-- BOTH TILES, for the reason recorded where `lastX` is set: a walking peer occupies the tile it
	-- is leaving as well as the one it is entering, so a player shoving into a moving ghost is very
	-- often pressing into the tile this rule was not looking at. The old tile only counts while the
	-- peer is actually mid-step -- a step is ~16 frames, and past that it has plainly left, so
	-- honouring it forever would make a standing ghost passable from a tile it is nowhere near.
	local fs = frameState
	local into = (fs.wantX == x and fs.wantY == y)
		or (a.lastX ~= nil and policyFrames - a.movedAt <= 20
			and fs.wantX == a.lastX and fs.wantY == a.lastY)
	if fs.standing and (fs.wantX ~= fs.px or fs.wantY ~= fs.py) and into then
		a.pushedFor = (a.pushedFor or 0) + 1
		if a.pushedFor >= PUSH_FRAMES_BEFORE_PASSABLE then
			a.passableUntil = policyFrames + PASSABLE_HOLD_FRAMES
		end
	else
		a.pushedFor = 0
	end

	if policyFrames < (a.passableUntil or 0) then
		return false
	end
	return (policyFrames - a.movedAt) < IDLE_FRAMES_BEFORE_PASSABLE
end

-- THE PRIORITY ORDER, in the user's words (2026-08-19): "npc's always shown, ghosts try to fill,
-- drawn otherwise". So the budget is computed from the game's needs first, not from what happens
-- to be free at this instant:
--
--   1. The game's own characters near the player are counted BEFORE any ghost is placed, and
--      their slots are simply not on offer. An NPC walking into view never has to compete with a
--      ghost for one, which is the failure the user watched: a crowd of peers left an NPC one
--      tile away undrawn.
--   2. Ghosts fill whatever the hardware can still draw.
--   3. Anything past that is the drawn-overflow tier's problem (plans.md, phase 9.1) -- absent
--      for now, and absent cleanly rather than flickering.
--
-- Counting near map objects rather than live structs is deliberate: a struct appears only once a
-- character is already in range, so budgeting from structs reserves the slot one moment too late.
local function gameCharactersNearby()
	local px, py = u8(OBJECT_STRUCTS + F_MAP_X) or 0, u8(OBJECT_STRUCTS + F_MAP_Y) or 0
	local ours = {}
	for _, g in pairs(ghosts) do
		ours[g.mo] = true
	end
	local n = 1 -- the player, who always has one
	for i = 1, NUM_MAP_OBJECTS - 1 do
		if not ours[i] then
			local base = MAP_OBJECTS + i * MAPOBJECT_LENGTH
			if (u8(base + M_SPRITE) or 0) ~= 0 then
				local mx, my = u8(base + M_X) or 0, u8(base + M_Y) or 0
				if math.max(math.abs(mx - px), math.abs(my - py)) <= GHOST_RANGE_TILES then
					n = n + 1
				end
			end
		end
	end
	return n
end

-- How many ghosts the hardware can still draw here, after the game's own cast is paid for.
local function ghostBudget()
	return HARDWARE_CHARACTER_LIMIT - gameCharactersNearby()
end


local function freeStruct()
	local free = {}
	for i = 1, NUM_OBJECT_STRUCTS - 1 do
		if u8(OBJECT_STRUCTS + i * OBJECT_LENGTH + F_SPRITE) == 0 then
			free[#free + 1] = i
		end
	end
	if #free <= RESERVED_STRUCTS_FOR_THE_GAME then
		return nil
	end
	-- Never take the game past what it can draw without flicker, and never spend a slot the
	-- game's own cast is going to need.
	if ghostCount() >= ghostBudget() then
		return nil
	end
	return free[#free] -- the highest free index; see freeMapObject for why
end

-- An object the engine is driving, to use as a behaviour template. Skips anything wearing the
-- player's sprite, which would be one of our own ghosts rather than a real NPC.
local function findTemplateNpc()
	local playerSprite = u8(OBJECT_STRUCTS + F_SPRITE)
	for i = 1, NUM_MAP_OBJECTS - 1 do
		local base = MAP_OBJECTS + i * MAPOBJECT_LENGTH
		local sprite = u8(base + M_SPRITE) or 0
		local id = u8(base + M_STRUCT_ID)
		if sprite ~= 0 and sprite ~= playerSprite and id and id ~= ENGINE.UNASSIGNED
			and id < NUM_OBJECT_STRUCTS then
			return i, id
		end
	end
end

-- Is sprite `id` loaded on THIS map right now, and at which VRAM tile?
--
-- A peer sends the sprite id they are wearing, but an id is not a picture: the tiles have to be
-- resident locally, and Crystal decides what is resident per map (the map's own objects indoors,
-- a fixed per-region list outdoors) plus the local player's own sprite. So the honest answer to
-- "show the peer as themselves" is: only when the game already has those tiles. This returns nil
-- otherwise, and the caller falls back to the local player's sprite -- today's behaviour, which
-- is at least always drawable. Loading a peer's tiles that are NOT resident is a separate and
-- much larger job (VRAM allocation), still open in phases/phase9.md.
local function residentSpriteTile(id)
	if not W_USEDSPRITES or not id or id == 0 then
		return nil
	end
	for i = 0, USED_SPRITES_CAPACITY - 1 do
		local entry = W_USEDSPRITES + i * 2
		local sprite = u8(entry)
		if not sprite or sprite == 0 then
			return nil -- the list is packed; a zero is the end of it
		end
		if sprite == id then
			return u8(entry + 1)
		end
	end
	return nil
end

-- Give a ghost the peer's own sprite when its tiles happen to be resident, otherwise leave it
-- wearing the local player's. Returns true when the peer's own was applied.
-- PROBE FLAG, off unless set. Substitutes one sprite id for every peer, so "does a ghost wear a
-- sprite the local player is not wearing" can be asked without a second machine and a peer of the
-- other gender. Pick an id the current map actually has loaded (an NPC standing on it) -- a
-- non-resident id changes nothing by design, which is the fallback working, not a failure.
local FORCE_PEER_SPRITE = tonumber(MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE
	or os.getenv("MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE") or "")
if FORCE_PEER_SPRITE then
	-- SAY SO, every startup, the way AP_TRY does. A global survives a dev-loader reload -- the
	-- loader swaps SCRIPTS, not the Lua state -- so one set for an experiment stays set for
	-- every later run in that emulator, silently. Live case 2026-08-19: a forced SPRITE_RIVAL
	-- left over from a probe made a ghost look like the player indoors and like an NPC outdoors,
	-- which is precisely the shape of a real bug (sprite 4 is resident outdoors and not in Elm's
	-- lab), and cost the user a report. A probe that changes what is on screen has to announce
	-- itself in the log the session is read from.
	log(string.format("PROBE FLAG IN USE: every peer is forced to sprite %d "
		.. "(MESHGHOST_CRYSTAL_FORCE_PEER_SPRITE). Ghosts will NOT look like their peers.",
		FORCE_PEER_SPRITE))
end

if COMPARE_TIERS then
	log("PROBE FLAG IN USE: MESHGHOST_COMPARE_TIERS -- the loopback ghost is rendered TWICE, "
		.. "spawned 2 tiles right and painted 2 tiles left. Two ghosts is the flag, not a bug.")
end
if COMPARE.spawnTier then
	log("MeshGhost: spawned tier ON (" .. (COMPARE_TIERS and "compare mode" or "MESHGHOST_CRYSTAL_SPAWN_TIER")
		.. ") -- a peer that can be a real object is one; the shipped default is drawn only.")
else
	log("MeshGhost: drawn tier only (the shipped default since 2026-09-02); "
		.. "MESHGHOST_CRYSTAL_SPAWN_TIER=1 re-enables spawned ghosts.")
end

local function applyPeerSprite(g, id)
	-- NO GHOST IS NOT AN ERROR, and this is the fix for an adapter that DIES on a map change.
	-- renderRemote drops `g` to nil the instant stillOurs() reports the slot is the game's again,
	-- and then calls straight through to here -- so this ran on nil every time a peer's ghost went
	-- stale, threw `attempt to index a nil value (local 'g')`, and the dev loader unloaded the
	-- WHOLE adapter. User, 2026-08-26: the ghosts stop following *"when going to different
	-- routes"*, which is precisely when a map load rebuilds the array. The loader log had been
	-- recording it by name all along -- one line, easy to scroll past, and it looks nothing like
	-- a bug in whatever was being worked on at the time.
	if g == nil then
		return false
	end
	id = FORCE_PEER_SPRITE or id
	local tile = residentSpriteTile(id)
	if not tile then
		return false
	end
	if u8(g.st_base + F_SPRITE) == id and u8(g.st_base + F_SPRITE_TILE) == tile then
		return true -- already wearing it; writing every frame would fight nothing but cost reads
	end
	-- RE-CHECK THE CROSS-LINKS HERE, because this function WRITES INTO A MAP OBJECT and sits
	-- 1,200 lines above stillOurs(), so it cannot call it. Without this, a caller that forgets to
	-- validate stamps a peer's sprite id onto whatever the game has put in that slot -- a real
	-- NPC wearing a ghost's graphic until the next map load.
	--
	-- And the later guard CANNOT catch it: `g.sprite = id` below updates the very value
	-- stillOurs() compares against, so after this write the check agrees by construction. A guard
	-- whose expectation is set by the write it guards has stopped being a guard -- the same shape
	-- as reading back the value you just wrote. It has to be caught BEFORE the write.
	--
	-- IT SAYS SO THE FIRST TIME IT EVER FIRES, and that line is the whole evidence for keeping it.
	-- The reported symptom this was written against -- trainers on other routes drawn with the
	-- wrong sprite (user, 2026-08-26) -- is NOT established as this code's doing; the crash above
	-- is. If this line never appears in a session where that symptom does, the cause is elsewhere
	-- and this check is dead weight a later session should delete on evidence rather than on a
	-- guess. A bare global, not a local: the file is at 197 of Lua's 200 (`emulator/CLAUDE.md`).
	if u8(g.mo_base + M_STRUCT_ID) ~= g.st or u8(g.st_base + F_MAP_OBJECT_INDEX) ~= g.mo then
		if not meshghostSpriteGuardFired then
			meshghostSpriteGuardFired = true
			log(string.format("MeshGhost: REFUSED a sprite write onto slot mo=%d/st=%d -- its "
				.. "cross-links say it is the game's object now, not our ghost's. If you are "
				.. "seeing an NPC wearing the wrong sprite, this is the cause.", g.mo, g.st))
		end
		return false
	end
	w8(g.st_base + F_SPRITE, id)
	w8(g.st_base + F_SPRITE_TILE, tile)
	w8(g.mo_base + M_SPRITE, id)
	g.sprite = id -- keep stillOurs()'s expectation in step with what the ghost now wears
	return true
end

-- Is the camera on a tile boundary?
--
-- screenCoords() below is only valid when it is, and that is measured, not assumed. Walking out
-- of Elm's lab put a fresh ghost a few pixels off its tile while walking IN was always fine
-- (user, 2026-08-19) -- because leaving a building drops the player into a scripted step out of
-- the doorway, so the ghost is spawned mid-scroll. A transition probe logged every object's
-- screen coordinate against what screenCoords() would compute for it, frame by frame across a
-- map load: the two agree exactly whenever both scroll offsets are multiples of 16, and disagree
-- by the sub-tile remainder whenever they are not -- the window origin advances a whole tile
-- while the pixel offset still carries the leftover, so the formula subtracts it twice.
--
-- The engine keeps every object's screen position itself once it exists; this only decides WHEN
-- it is safe to compute one from scratch. So a deferral costs a frame or two, never a wrong
-- placement that then persists for the life of the ghost.
local function cameraSettled()
	return (u8(W_BGMAPOFFSETX) or 0) % 16 == 0 and (u8(W_BGMAPOFFSETY) or 0) % 16 == 0
end

-- ---------------------------------------------------------------------------
-- The drawn tier: peers the engine has no room for
-- ---------------------------------------------------------------------------
--
-- Everything above this point asks the GAME to render a peer, which is the whole design of this
-- adapter. But the engine has 13 character slots and the Game Boy can draw 10 characters at once,
-- and a full room has more peers than that -- so past the cap a peer would simply not exist.
--
-- The user's call, 2026-08-19: "cap it, and just draw extras instead... i want every player/ghost
-- to be visible all the time instead." So peers past the cap are PAINTED over the emulator's
-- output, which is subject to none of the engine's limits because it happens after the PPU has
-- finished. Spawned ghosts stay the good tier; this is the overflow.
--
-- THIS IS A BANDAGE and is registered as one in BANDAGES.md: no engine animation, no collision,
-- no draw priority, and occlusion that we have to re-implement rather than get for free.
--
-- Pixels come from VRAM, not from ROM. A peer's sprite is already loaded (wUsedSprites says at
-- which tile), so the drawn tier reads the same tiles the engine is drawing the spawned ghosts
-- from -- 4 tiles of 2bpp, 16 bytes each, in a 2x2 block.
local DRAW_OVERFLOW = (MESHGHOST_CRYSTAL_DRAW_OVERFLOW or os.getenv("MESHGHOST_CRYSTAL_DRAW_OVERFLOW")) ~= "0"

-- THE GAME'S OWN COLOURS, not an approximation of them.
--
-- The first version hardcoded a white/red/black palette and the user's verdict was immediate:
-- "the crystal sprites look really pale, compared to the player". They were -- a drawn ghost
-- stood beside a spawned one wearing the real thing.
--
-- wOBPals1 (05:d040 -> flat 0x5040, WRAM bank 5 in this domain's flat layout) holds the eight
-- object palettes the game is actually using, four BGR555 colours each. Read them and a drawn
-- ghost is coloured by the same bytes the hardware is colouring the spawned ghosts with.
local W_OBPALS = 0x5040

local function paletteColors(palIndex)
	local base = W_OBPALS + (palIndex & 7) * 8
	local colors = { [0] = nil } -- colour 0 of an object palette is transparent
	for i = 1, 3 do
		local lo = u8(base + i * 2) or 0
		local hi = u8(base + i * 2 + 1) or 0
		local c = lo | (hi << 8)
		-- BGR555 -> 8 bits per channel. The <<3 | >>2 scaling keeps white at 0xFF rather than
		-- 0xF8, which is what makes a hand-rolled conversion look washed out.
		local r = ((c & 0x1F) << 3) | ((c & 0x1F) >> 2)
		local g = (((c >> 5) & 0x1F) << 3) | (((c >> 5) & 0x1F) >> 2)
		local b = (((c >> 10) & 0x1F) << 3) | (((c >> 10) & 0x1F) >> 2)
		colors[i] = 0xFF000000 | (r << 16) | (g << 8) | b
	end
	return colors
end

-- Decoded tiles are cached, and drawn as horizontal RUNS rather than pixels.
--
-- Both are about cost, and the cost is the whole feasibility question: filling a screen means
-- ~80 characters, and a character is 256 pixels, so the naive version is ~20,000 gui calls per
-- frame. Emerald has already shown this project what a few thousand per-frame calls do to an
-- emulator (60fps -> 3fps, 2026-08-19). A run of same-coloured pixels is one drawLine instead of
-- up to eight drawPixels, and a tile's decode is reused by every character wearing that sprite.
--
-- THE CACHE MUST BE INVALIDATED WHEN THE TILES BEHIND AN INDEX CHANGE, and until 2026-08-25 the
-- comment here claimed a map load did that while NOTHING IN THIS FILE EVER CLEARED IT. See
-- invalidateTileCache below -- the fault this hid is worth reading before touching either.
local VRAM_BANK1 = 0x2000
local tileCache = {}

-- WHAT WENT WRONG, measured on screen 2026-08-25, and the shape is worth keeping.
--
-- The user surfed on the compare rig and reported the SPAWNED ghost as a correct surf blob and the
-- DRAWN one as the walking character standing on the sea -- the same peer, the same frame, two
-- renderers disagreeing. MESHGHOST_CRYSTAL_SPRITE_TRACE had already shown both being pointed at
-- the same place: `peerSprite=83 -> vram 0`, with the local player also at base 0. So the source
-- was right and the pixels were wrong, which leaves exactly one thing between them.
--
-- Mounting the surf blob rewrites the player's sprite tiles IN PLACE -- same VRAM base, new
-- graphics, and NO map load. The spawned ghost is drawn by the PPU straight from live VRAM, so it
-- followed. The drawn tier decodes VRAM itself and cached that decode by tile index forever, so it
-- kept painting the walking character's pixels at indices the game had since overwritten.
--
-- IT ALSO EXPLAINS THE REPORT THAT CAME FIRST, which two earlier theories could not: after coming
-- ashore, *"swapping between walking [and] surf sprite only when walking downwards"*. Only the
-- indices already IN the cache were stale; the ones first decoded while surfing came back with
-- blob pixels and stayed. So a direction whose stepping tiles happened to be decoded on the water
-- kept them on land, and the ghost mixed the two per frame -- per DIRECTION, which is what made it
-- look like a facing bug. UNVERIFIED.md carries the two refuted theories; the arrangement cache
-- really cannot produce surf art, and this one can, because it caches PIXELS rather than offsets.
--
-- `wUsedSprites` is the record of which sprite sits at which VRAM base, so it moves exactly when
-- the graphics behind an index do -- including the surf mount, which no map/coordinate signal
-- sees. The map is folded in as well because that is what the old comment promised and a map load
-- rebuilds VRAM wholesale. Cartridge decodes are KEPT: ROM does not change, they are keyed by a
-- string, and they are the expensive ones.
local tileCacheSig = nil
local function invalidateTileCache()
	local sig = (u8(W_MAPGROUP) or 0) * 256 + (u8(W_MAPNUMBER) or 0)
	if W_USEDSPRITES then
		for i = 0, USED_SPRITES_CAPACITY - 1 do
			local id = u8(W_USEDSPRITES + i * 2)
			if not id or id == 0 then
				break
			end
			sig = (sig * 31 + id * 256 + (u8(W_USEDSPRITES + i * 2 + 1) or 0)) % 0x3FFFFFFF
		end
	end
	if sig == tileCacheSig then
		return
	end
	tileCacheSig = sig
	local kept = {}
	for k, v in pairs(tileCache) do
		if type(k) == "string" then -- "rom:<offset>": the cartridge cannot have moved
			kept[k] = v
		end
	end
	tileCache = kept
end

-- SPRITE GRAPHICS STRAIGHT FROM THE CARTRIDGE, for a peer whose sprite this map never loaded.
--
-- The drawn tier reading VRAM can only show sprites the game already put there -- which is why a
-- peer of the other gender still looks like the local player: Crystal loads the map's own cast
-- plus YOUR sprite, and never theirs. Reading the tiles out of ROM removes that limit entirely,
-- and it is a thing only the drawn tier can do (a spawned ghost needs tiles the hardware can
-- reach, i.e. in VRAM).
--
-- The table is `OverworldSprites` at 05:4736, from our own hash-verified pokecrystal build, and
-- its shape is stated by the game's own struct (constants/sprite_data_constants.asm):
--   0-1 address, 2 size in BYTES (192 = 12 tiles), 3 bank, 4 type, 5 palette
-- six bytes per entry, indexed by SPRITE_* - 1 (the table's own comment: "entries correspond to
-- SPRITE_* constants", which start at 1).
-- Assigned from the selected address table, and NIL on any build where nobody has measured it.
local OVERWORLD_SPRITES_ROM, EMOTES_ROM
local SPRITEDATA_STRIDE = 6

local function romByte(offset)
	return memory.read_u8(offset, ROM_DOMAIN) or 0
end

-- IS THERE AN EMOTE OVER THE PLAYER'S HEAD, AND WHICH ONE?
--
-- `SpawnEmote` builds a separate map object at the character's own tile, flagged EMOTE_OBJECT
-- (`OBJECT_FLAGS1` bit 7), so this is a scan and not a field. Nothing in WRAM records WHICH emote
-- was loaded -- `LoadEmote` takes it in a register and copies the tiles -- so the identity is
-- recovered the only way it can be: by matching the tiles the game actually loaded against the
-- `Emotes` table in the cartridge. That is the engine's own answer read back, rather than a guess
-- from context, and it means a peer gets the RIGHT emote (the "!", a heart, a sleep bubble) and
-- not whichever one this code was written for.
--
-- Returns the emote's index into `Emotes`, or nil. Cheap in the common case: the scan stops at
-- the first emote object, and the tile match runs only when the loaded tiles have changed.
function ENGINE.playerEmote()
	if not EMOTES_ROM then
		return nil -- no address for this build; a peer simply gets no emote
	end
	local px, py = u8(OBJECT_STRUCTS + F_MAP_X), u8(OBJECT_STRUCTS + F_MAP_Y)
	local found = false
	for i = 1, NUM_OBJECT_STRUCTS - 1 do
		local b = OBJECT_STRUCTS + i * OBJECT_LENGTH
		-- EMOTE_OBJECT IS NOT "THIS IS AN EMOTE" -- it is "this is an attached decoration object",
		-- and THREE of them set it. `data/sprites/map_objects.asm` gives SPRITEMOVEDATA_SHADOW,
		-- _EMOTE and _SCREENSHAKE all the same flags1 byte
		-- (`WONT_DELETE | FIXED_FACING | SLIDING | EMOTE_OBJECT`), so the flag plus "on the
		-- player's tile" matched the JUMP SHADOW as readily as the "!". The user, watching a ledge
		-- hop on the compare rig 2026-08-26: *"the drawn ghost is doing a '!' emote while jumping,
		-- its not supposed to do that"* -- `SpawnShadow` puts a shadow object on the hopping
		-- character's own tile for the length of the hop, this scan called it an emote, and the
		-- tile match below then named whichever emote happened to be resident.
		--
		-- THE ACTION BYTE IS THE DISCRIMINATOR, and it is maintained rather than merely initial:
		-- `MovementFunction_Emote` writes OBJECT_ACTION_EMOTE (8) and `MovementFunction_Shadow`
		-- writes OBJECT_ACTION_SHADOW (7) every time each runs
		-- (`engine/overworld/map_objects.asm`), so this is a live field and not a value that could
		-- have been overwritten since spawn. Screenshake's object holds OBJECT_ACTION_00.
		--
		-- Note this is the SAME fact that made `OBJECT_ACTION_EMOTE` wrong to write onto a ghost's
		-- body (see ACTIONS.peer): the emote is a separate object, not a pose. It was read there
		-- and not here, which is why the send side kept a bug the receive side had already fixed.
		if (u8(b + F_SPRITE) or 0) ~= 0
			and ((u8(b + F_FLAGS1) or 0) & 0x80) ~= 0 -- EMOTE_OBJECT: decoration, not necessarily "!"
			and (u8(b + F_ACTION) or 0) == 8 -- OBJECT_ACTION_EMOTE, the half that means emote
			and u8(b + F_MAP_X) == px and u8(b + F_MAP_Y) == py then
			found = true
			break
		end
	end
	if not found then
		return nil
	end
	-- WHICH ONE. The four-tile emotes all load at $f8, in VRAM bank 1 alongside the characters, so
	-- the first tile there identifies the set. Sixteen bytes, and the answer is memoised against
	-- them, so a bite that holds for a second costs one comparison rather than sixty.
	local key = {}
	for i = 0, 15 do
		-- Read straight through `memory` rather than via this file's own `readVram`, which is
		-- declared BELOW this function and would therefore be a nil global here -- the trap this
		-- file already carries twice. VRAM_BANK1 is visible; the helper is not.
		key[#key + 1] = string.char(memory.read_u8(VRAM_BANK1 + 0xF8 * 16 + i, "VRAM") or 0)
	end
	key = table.concat(key)
	if ENGINE.emoteIds[key] ~= nil then
		local v = ENGINE.emoteIds[key]
		return (v >= 0) and v or nil
	end
	local answer = -1
	for idx = 0, 11 do
		local e = EMOTES_ROM + idx * 6
		-- dw graphics, db length, db bank, dw vtile -- and only the ones that load at $f8 can be
		-- what is sitting there.
		if (romByte(e + 4) | (romByte(e + 5) << 8)) == 0x8F80 then
			local gfx = romByte(e + 3) * 0x4000 + ((romByte(e) | (romByte(e + 1) << 8)) - 0x4000)
			local same = true
			for i = 0, 15 do
				if romByte(gfx + i) ~= string.byte(key, i + 1) then
					same = false
					break
				end
			end
			if same then
				answer = idx
				break
			end
		end
	end
	ENGINE.emoteIds[key] = answer
	return (answer >= 0) and answer or nil
end

-- Returns the ROM offset of a sprite's graphics, its size in bytes, and the palette the game
-- itself assigns it -- or nil for a sprite id the table does not cover.
local function spriteGfxInRom(spriteId)
	if not OVERWORLD_SPRITES_ROM or not spriteId or spriteId < 1 or spriteId > 255 then
		return nil
	end
	local entry = OVERWORLD_SPRITES_ROM + (spriteId - 1) * SPRITEDATA_STRIDE
	local addr = romByte(entry) | (romByte(entry + 1) << 8)
	local size, bank, palette = romByte(entry + 2), romByte(entry + 3), romByte(entry + 5)
	if size == 0 or bank == 0 or addr < 0x4000 then
		return nil -- not a banked graphics pointer; refuse rather than read somewhere plausible
	end
	return bank * 0x4000 + (addr - 0x4000), size, palette
end

-- key: a VRAM tile index, or "rom:<offset>" for cartridge graphics.
local function decodeTileAt(key, readByte, base)
	local cached = tileCache[key]
	if cached then
		return cached
	end
	-- VRAM BANK 1, not bank 0. The BizHawk domain lays both banks flat (16 KB), bank 1 starting at
	-- 0x2000, and the OAM attribute byte's bit 3 selects the bank -- a live dump of this game's own
	-- characters reads attr=8 and attr=0x28, so bit 3 is set and the graphics are in bank 1.
	-- Reading bank 0 decodes whatever unrelated tiles sit at the same index, which draws as
	-- garbage: found on screen 2026-08-19, the first thing the user said about the drawn tier.
	local rows = {}
	for row = 0, 7 do
		local lo = readByte(base + row * 2)
		local hi = readByte(base + row * 2 + 1)
		local runs, runStart, runIdx = {}, nil, nil
		for bit = 0, 8 do -- 8 is one past the end, to close the final run
			local idx = nil
			if bit < 8 then
				local mask = 1 << (7 - bit)
				idx = ((lo & mask) ~= 0 and 1 or 0) | (((hi & mask) ~= 0 and 1 or 0) << 1)
				if idx == 0 then idx = nil end -- colour 0 is transparent
			end
			if idx ~= runIdx then
				if runIdx then
					runs[#runs + 1] = { x = runStart, len = bit - runStart, idx = runIdx }
				end
				runStart, runIdx = bit, idx
			end
		end
		rows[row] = runs
	end
	tileCache[key] = rows
	return rows
end

local function readVram(a) return memory.read_u8(a, "VRAM") or 0 end

local function decodeTile(tileIndex)
	return decodeTileAt(tileIndex, readVram, VRAM_BANK1 + tileIndex * 16)
end

-- The same, for a tile inside a sprite's cartridge graphics.
local function decodeRomTile(gfxOffset, tileWithinSprite)
	local at = gfxOffset + tileWithinSprite * 16
	return decodeTileAt("rom:" .. at, romByte, at)
end

local function drawRows(rows, sx, sy, colors, xflip)
	for row = 0, 7 do
		local y = sy + row
		if y >= 0 and y < 144 then
			for _, run in ipairs(rows[row]) do
				local rx = xflip and (8 - run.x - run.len) or run.x
				local x1 = sx + rx
				local x2 = x1 + run.len - 1
				if x2 >= 0 and x1 < 160 then
					local color = colors[run.idx]
					if color then
						gui.drawLine(math.max(x1, 0), y, math.min(x2, 159), y, color)
					end
				end
			end
		end
	end
end

-- WHICH FOUR TILES, AND FLIPPED HOW -- learned from the engine, not guessed.
--
-- A walking sprite is six views of four tiles -- three standing and three stepping (see
-- `documentation.md`) -- and how those become a facing plus a stride is the engine's business: it
-- picks tile ids and per-sprite x-flips as it builds OAM. So
-- rather than reverse-engineer the layout, the drawn tier WATCHES the local player -- who is
-- always object struct 0 and always has the first four OAM entries -- and records what the engine
-- used for each facing. A drawn peer facing the same way then renders with exactly those tiles.
--
-- This is the same principle as calibrating the screen position against OAM: the engine is
-- already doing the work correctly every frame, so read its answer instead of recomputing it.
-- It also means the mapping is automatically right for whichever sprite the player is wearing.
-- facing (0..3) -> { stand = <frame>, step = { [0..3] = <frame> } }, where a frame is the four OAM
-- parts the engine used. `stand` is the standing view, which the engine also draws for the middle
-- of every step; `step` is the stepping view, keyed by the stride index the engine itself chose
-- (the low two bits of OBJECT_FACING) so the two feet cannot be confused with each other.
--
-- WHICH LIST A FRAME BELONGS IN IS READ OFF THE ART, not off what the player was doing when it was
-- sampled: bit 0x80 of the tile offset separates a sprite's standing views from its stepping ones.
-- Deriving it means arrival order cannot decide anything, which is the mistake the first version
-- of this cache made twice.
local facingFrames = {}

local function readPlayerOamFrame()
	local frame = {}
	-- THE ENGINE DRAWS NOTHING FOR A CHARACTER WHOSE FACING IS STANDING, so if the player's is,
	-- OAM entries 0-3 belong to somebody else BY DEFINITION and nothing here is the player's art.
	--
	-- Measured 2026-08-26 (`probes/fly_probe.lua`): through a Fly the player's own object holds
	-- facing $FF for the whole animation -- the game hides the player object and animates the
	-- sequence some other way -- while OAM entry 0 read tile offsets $84 and $88, alternating.
	-- Both of those PASS the `(offset & 0x7F) < 12` art test below, so the learner filed another
	-- character's stepping views as the player's own artwork for whatever direction the player
	-- happened to be facing, and the cache keeps what it learns for the session. That is the
	-- user's *"drawn ghost just looks weird/bad sprite during fly"*, 2026-08-26.
	--
	-- The y-range test below cannot catch this: those entries have perfectly normal y values,
	-- because they are a real character that really is on screen. The only thing that separates
	-- "the player's four entries" from "someone else's four entries" here is whether the player is
	-- being drawn at all, and OBJECT_FACING is the engine's own answer -- `SetFacingStanding` sets
	-- it to STANDING precisely so `_UpdateSprites` skips the object (map_objects.asm).
	--
	-- Fourth entry in the same family: the fishing session (2026-08-26) established that the
	-- player does not own OAM 0-3 unconditionally, and 2026-08-22 found the learner adopting a
	-- spawned ghost's entries. Same hole, a different way in.
	if (u8(OBJECT_STRUCTS + F_FACING) or 0) == STANDING then
		return nil
	end
	local playerTileBase = u8(OBJECT_STRUCTS + F_SPRITE_TILE) or 0
	for i = 0, 3 do
		local y = memory.read_u8(i * 4, "OAM") or 0
		if y == 0 or y >= 160 then
			return nil -- the player is not on screen this frame; learn nothing
		end
		-- THE ENTRY MUST ACTUALLY BE THE PLAYER'S, and until 2026-08-22 nothing checked.
		--
		-- These four entries are assumed to be the local player's four sprites -- that assumption
		-- is load-bearing here and in the tier's own anchor calibration. It is not guaranteed: the
		-- engine lays OAM out in its own order, and with a spawned ghost on screen (compare mode
		-- puts one two tiles away) another character can occupy 0-3. The offset is computed
		-- against the PLAYER's tile base, so a frame captured from a different sprite comes out
		-- 128-ish instead of 0-11 -- garbage arrangements that then get filed as the player's
		-- artwork for that facing and, because the cache keeps the first two and never clears,
		-- stay for the session. Measured with MESHGHOST_CRYSTAL_FACING_TRACE: four of the eight
		-- learned frames were out of range, and the two facings with NO valid frame were exactly
		-- the two the user reported swapping (2026-08-22).
		--
		-- A character's own art is `(offset & 0x7F) < 12`, NOT `offset < 12`, and that mask is the
		-- whole reason this tier animates at all.
		--
		-- A sprite has SIX views, not three: three standing views at its tile base + 0..11, and
		-- three STEPPING views at its tile base + 0x80 + 0..11. Measured 2026-08-22 on two
		-- characters at two different bases in one session -- the player (base 0x00, stepping at
		-- 0x80-0x8B) and an Olivine NPC (base 0x30, standing at 0x38-0x3B, stepping at 0xB8-0xBB)
		-- -- so the 0x80 is relative to the character's own base rather than an absolute block.
		-- `documentation.md` has the layout.
		--
		-- THE NARROWER RULE WAS THIS TIER'S MISSING ANIMATION. Written the same day to stop the
		-- learner adopting another character's OAM entries, `offset >= 12` also rejected every
		-- stepping frame as foreign -- so the only mid-step art it could ever accept was the pass
		-- frame, which is the standing art, and `entry.step` stayed empty in all four directions
		-- for a whole session. The user, 2026-08-22, on the result: the drawn ghost is *"perfect
		-- but not animated"*. The guard was right about the danger and wrong about the boundary.
		--
		-- The mask keeps the guard's actual job: the Olivine NPC's tiles decode to offset 0x38 and
		-- 0xB8 from the PLAYER's base, and `& 0x7F` leaves both at 0x38 -- still rejected.
		local tile = memory.read_u8(i * 4 + 2, "OAM") or 0
		local offset = (tile - playerTileBase) & 0xFF
		-- 12 and 0x7F as literals on purpose: this file is at 197 of Lua's 200 top-level locals
		-- and has failed to load silently four times from crossing it. The names they would have
		-- had are in the comment above instead.
		if (offset & 0x7F) >= 12 then
			return nil
		end
		frame[i + 1] = {
			-- an OFFSET within the sprite's own graphics, not an absolute VRAM tile: that is what
			-- lets the same learned arrangement be applied to a sprite read from the cartridge,
			-- which has its own tiles and no VRAM home at all.
			offset = offset,
			tile = memory.read_u8(i * 4 + 2, "OAM") or 0,
			xflip = ((memory.read_u8(i * 4 + 3, "OAM") or 0) & 0x20) ~= 0,
			-- Raw screen position for now; normalised against the frame's own top-left below.
			dx = memory.read_u8(i * 4 + 1, "OAM") or 0,
			dy = y,
		}
	end

	-- MEASURE THE PARTS FROM THE FRAME'S TOP-LEFT, NOT FROM ENTRY 0.
	--
	-- The engine emits a character's four entries MIRRORED when the sprite is flipped, so entry 0
	-- is the top-LEFT part facing one way and the top-RIGHT part facing the other. Taking it as the
	-- origin therefore negates every dx on a flipped frame: measured 2026-08-22, right-facing came
	-- back `[8F@0,0 9F@-8,0 10F@0,8 11F@-8,8]` where every other facing gave `@0,0 @8,0 @0,8 @8,8`.
	-- The character then draws 8px to the LEFT of where it belongs, and only when facing right --
	-- the one direction whose art is the mirrored side view. The user: *"when facing right, the
	-- drawn ghost gets offset a bit to the left. it does not do that for any of the other
	-- directions"*.
	--
	-- THIS FILE ALREADY KNEW. The tier's own anchor calibration takes the MINIMUM x across the four
	-- entries for exactly this reason -- see the 2026-08-19 entry in pitfalls.md, where calibrating
	-- on entry 0 made the origin alternate by 8px as the player turned. That fix was never carried
	-- across to the learner, which is the third time in one session a correct rule was found living
	-- in one code path and missing from its sibling.
	--
	-- The minimum is invariant under the flip, because the SET of four positions is the same either
	-- way -- only which entry reports which member changes.
	local minX, minY = 255, 255
	for i = 1, 4 do
		if frame[i].dx < minX then minX = frame[i].dx end
		if frame[i].dy < minY then minY = frame[i].dy end
	end
	for i = 1, 4 do
		frame[i].dx = frame[i].dx - minX
		frame[i].dy = frame[i].dy - minY
	end
	return frame
end

local function sameFrame(a, b)
	if not a or not b then
		return false
	end
	for i = 1, 4 do
		if a[i].offset ~= b[i].offset or a[i].xflip ~= b[i].xflip then
			return false
		end
	end
	return true
end

-- PAIR THE ARTWORK WITH THE STATE IT WAS DRAWN FROM.
--
-- `readPlayerOamFrame` reads OAM, which is what the engine DREW LAST FRAME; `F_DIRECTION` is what
-- the struct says THIS frame. This file already established that skew for the player's screen
-- position -- see "PAIR OAM WITH THE FRAME OAM WAS BUILT FROM" in drawOverflow, where mixing the
-- two produced a ghost racing its destination. The same rule was never applied to the LEARNER.
--
-- At the instant the player turns, the two disagree by exactly one frame, so the OLD direction's
-- artwork is filed under the NEW direction. `facingFrames` is never cleared, so that poisoned
-- entry lasts the rest of the session -- and because a direction holds several stride frames, a
-- poisoned one sits alongside a good one and the tier alternates between them. On screen that is a
-- ghost swapping between two facings while walking in one direction.
--
-- The user, 2026-08-22: *"going right has the 'facing down/right constantly' issue"* -- having
-- watched the same fault sit on LEFT before a reload and move to RIGHT after one. That movement is
-- the tell, and it is what identified this: the learner runs downstream of drawOverflow's early
-- returns, so anything changing when the tier returns early re-samples the race and re-rolls which
-- direction gets poisoned. Nothing about the turn itself changed.
--
-- So the pair is only learned when the previous call was the IMMEDIATELY preceding frame, and the
-- direction used is the one that was current then -- the state the pixels in OAM actually came
-- from. A gap means the two halves describe different moments and the frame is simply not learned;
-- one skipped sample costs nothing, a poisoned entry costs the session.
-- PAIR THE ARTWORK WITH THE DIRECTION IT WAS DRAWN FOR.
--
-- OAM holds what the engine DREW LAST FRAME; F_DIRECTION is what the struct says THIS frame. At a
-- turn they disagree by one frame, so the old view's art is filed under the new direction. This
-- file already established that same skew for the player's screen position ("PAIR OAM WITH THE
-- FRAME OAM WAS BUILT FROM", in drawOverflow); it was never applied to the learner.
--
-- MEASURED, not inferred (MESHGHOST_CRYSTAL_FACING_TRACE, 2026-08-22): with the out-of-range
-- guard in readPlayerOamFrame in place, DOWN still accepted side-view art [8F 9F 10F 11F] and UP
-- still accepted down art [0 1 2 3] -- while `dir` read the target facing on both lines. Art from
-- the previous direction, filed under the current one.
--
-- THIS FIX ALONE IS NOT ENOUGH AND WAS BRIEFLY REVERTED FOR LOOKING LIKE A REGRESSION. The two
-- defects are independent: without the range guard the learner also picks up ANOTHER sprite's
-- entries, and those dominate, so pairing alone made three facings worse instead of one better.
-- Neither half works without the other -- the union is the fix, which is the shape CLAUDE.md warns
-- about after a run of single-variable negatives.
local function learnFacingFromPlayer()
	local dirNow = ((u8(OBJECT_STRUCTS + F_DIRECTION) or 0) // 4) & 3
	local prev = facingFrames.prev
	-- On facingFrames rather than a new top-level name: this file is at 197 of Lua's 200 locals.
	-- A string key cannot collide with the numeric facings 0..3, and nothing iterates this table.
	-- emu.framecount() rather than this file's own `drawFrames`, which is declared ~400 lines
	-- BELOW here and would silently resolve to a nil global.
	local nowFrame = emu.framecount()
	-- `face` is OBJECT_FACING, which is a direction AND a stride index in one byte
	-- (`documentation.md`): STEP_DOWN_0..3 are four entries of one list. Its low two bits are the
	-- engine's own answer to "which foot", and they are paired with the art the same way the
	-- direction is -- from the frame the pixels were built from, never from this one.
	facingFrames.prev = { dir = dirNow, at = nowFrame, face = u8(OBJECT_STRUCTS + F_FACING) or 0 }

	local frame = readPlayerOamFrame()
	if not frame then
		return
	end
	if not prev or prev.at ~= nowFrame - 1 then
		return -- not a contiguous pair: the art and the direction would describe different moments
	end
	local facing = prev.dir
	local entry = facingFrames[facing]
	if not entry then
		entry = { step = {} }
		facingFrames[facing] = entry
	end
	-- The group check guards the STANDING frame too, and has to run before it: `entry.stand` is
	-- rewritten every idle frame and `drawCharacter` falls back to it, so one contaminated sample
	-- there shows up the moment a peer stops. It was the second half of the same hole.
	-- WHICH GROUP A FACING WEARS IS A PROPERTY OF THE SPRITE FORMAT, NOT SOMETHING TO LEARN.
	--
	-- A walking sprite is views of four tiles: DOWN is tiles 0-3, UP is 4-7, and LEFT/RIGHT share
	-- 8-11, told apart by the hardware flip rather than by separate art -- and each has a stepping
	-- twin 0x80 higher, which the mask above folds onto the same group. Measured
	-- with MESHGHOST_CRYSTAL_FACING_TRACE across several sessions on 2026-08-22, every clean
	-- sample agreeing: facing 0 -> [0 1 2 3], 1 -> [4 5 6 7], 2 -> [8 9 10 11], 3 -> the same four
	-- flipped.
	--
	-- THE FIRST VERSION LEARNED THIS PER FACING AND THAT WAS THE BUG. Taking the group from the
	-- first sample means one contaminated sample locks a facing to the wrong view -- and then the
	-- check ENFORCES it, rejecting every correct frame that follows. Seen immediately: UP locked
	-- to group 0 on its first sample and the ghost faced down whether the peer walked up or down,
	-- with the log showing `facing=1 group=0` and nothing further ever accepted. A rule that
	-- protects whatever arrived first is only as good as the first arrival.
	--
	-- Deriving it instead makes contamination unable to win regardless of arrival order, which is
	-- the point: our own spawned ghost wears the player's sprite AND tile base, so a frame taken
	-- from its OAM entries is indistinguishable from ours except by which view it holds.
	-- MASKED, because a stepping frame carries the same view in the same place, 0x80 higher. Its
	-- group is therefore `(offset & 0x7F) // 4` -- without the mask a stepping frame's group comes
	-- out at 32-34 and every one of them is rejected by the check below, which is the second half
	-- of the same defect as the range guard above.
	-- ALL FOUR PARTS, NOT JUST THE FIRST -- measured 2026-08-26. This read `frame[1]` alone, so a
	-- frame whose first tile was the player's and whose others were not passed every check below.
	-- The trace caught it outright: the DOWN standing view alternating between
	-- `[0,1,2,3]` (correct) and `[0,1,9,3]` -- tile 9 is left/right artwork, group 2, sitting in
	-- the bottom-left corner of a downward-facing character, which is a visibly garbled sprite.
	-- One foreign part is all it takes, and validating one part cannot see it.
	--
	-- Why a foreign part gets in at all is already written down (`pitfalls.md`, 2026-08-26): the
	-- player does not own OAM entries 0-3 unconditionally -- another object can occupy one of them
	-- -- so a "frame" assembled from those four entries is not guaranteed to be one character's.
	-- The group test is the only thing standing between that and the cache.
	local group = (frame[1].offset & 0x7F) // 4
	for gi = 2, 4 do
		if ((frame[gi].offset & 0x7F) // 4) ~= group then
			return
		end
	end
	if group ~= ((facing == 0) and 0 or (facing == 1) and 1 or 2) then
		return
	end
	-- LEFT AND RIGHT SHARE ONE VIEW, so the group alone cannot separate them -- the FLIP does.
	--
	-- There is no left-facing art and no right-facing art: there is one side view, drawn as-is for
	-- one direction and mirrored by the hardware for the other. Measured on 2026-08-22, every clean
	-- sample agreeing: facing 2 takes it unflipped, facing 3 takes it mirrored.
	--
	-- So the group check passes a right-facing frame for LEFT and vice versa, and the pair then
	-- alternates -- the user: *"left/right is constantly flipping the sprite around"*. Up and down
	-- were unaffected because their views are group 0 and group 1, which the group rule already
	-- separates. Deliberately NOT applied to those two: their walk cycle is produced BY mirroring,
	-- so both flips are legitimate there and requiring one would reject half the animation.
	if group == 2 and frame[1].xflip ~= (facing == 3) then
		return
	end
	-- FILE THE FRAME BY WHAT THE ART IS, NOT BY WHAT THE PLAYER WAS DOING.
	--
	-- The old rule read F_WALKING and called anything mid-step a "walk frame". That is a question
	-- about the player, and it gets the wrong answer twice: the PASS frame is drawn mid-step and is
	-- byte-identical to the standing art, so it landed in the walk list; and with two slots filled
	-- on arrival order, which frame a direction ended up alternating depended on when sampling
	-- started. `phase9.md` already has the general form of this -- a rule that protects whatever
	-- arrived first is only as good as the first arrival.
	--
	-- Bit 0x80 of the offset says it outright, because that is exactly what distinguishes the two
	-- halves of a sprite's graphics: clear means a standing view, set means a stepping view. So the
	-- art files itself and arrival order stops mattering.
	if (frame[1].offset & 0x80) == 0 then
		-- TRACED TOO, and it was not until 2026-08-26. This branch stores and returns ABOVE the
		-- trace at the bottom of the function, so for its whole life the instrument could only see
		-- STEPPING frames -- and a session hunting a garbled STANDING pose logged nothing at all
		-- while the fault was on screen. An instrument blind to one of its two paths reads exactly
		-- like a quiet system. Edge-triggered on the arrangement so an idle player (which rewrites
		-- this slot every frame) does not flood the log.
		if MESHGHOST_CRYSTAL_FACING_TRACE then
			local k = string.format("%d:%d@%d,%d|%d@%d,%d|%d@%d,%d|%d@%d,%d", facing,
				frame[1].offset, frame[1].dx, frame[1].dy, frame[2].offset, frame[2].dx, frame[2].dy,
				frame[3].offset, frame[3].dx, frame[3].dy, frame[4].offset, frame[4].dx, frame[4].dy)
			facingFrames.standLast = facingFrames.standLast or {}
			if facingFrames.standLast[facing] ~= k then
				facingFrames.standLast[facing] = k
				-- emu.framecount(), NOT drawFrames -- which is declared ~700 lines BELOW this
				-- function and is therefore a nil GLOBAL here. The trace at the bottom of this
				-- same function carries that warning in its own comment, and this line was
				-- written anyway; it cost one deploy with a TICK ERROR per frame.
				logFile(string.format("facing-trace: f=%d STAND facing=%d [%s]",
					emu.framecount(), facing, k))
			end
		end
		entry.stand = frame
		return
	end
	-- A STEPPING view, filed under the stride index the ENGINE chose for it -- the low two bits of
	-- OBJECT_FACING, paired with the art the same way the direction is.
	--
	-- Keyed rather than appended, so a direction cannot end up alternating two copies of the same
	-- foot, and so a later sample corrects an earlier one instead of being locked out. Measured
	-- 2026-08-22: walking down, the stepping view is drawn unflipped at stride 1 and 2 and mirrored
	-- at stride 0 and 3 -- the two feet. Left and right have only one stepping view each, because
	-- there the flip is what says which way the character looks, so their four strides all agree.
	local stride = (prev.face or 0) & 3
	if entry.step[stride] and sameFrame(entry.step[stride], frame) then
		return
	end
	-- A FACING MAY ONLY WEAR ART FROM ITS OWN TILE GROUP.
	--
	-- A view is four tiles: measured 2026-08-22, down is group 0, up group 1, and left/right share
	-- group 2, told apart by the hardware flip, with each view's stepping twin 0x80 higher. So every
	-- frame a facing accepts must come from one group -- two groups under one facing means the tier
	-- alternates between two different views, which is the character visibly changing where it
	-- looks while walking in a straight line.
	--
	-- WHY THE EARLIER GUARDS WERE NOT ENOUGH. The range check in readPlayerOamFrame only rejects a
	-- sprite with a DIFFERENT tile base. Our own spawned ghost wears the local player's sprite id
	-- and tile base (that is the fallback when a peer's own sprite is not resident), so its OAM
	-- entries decode to perfectly in-range offsets -- the player's tiles, arranged for whichever way
	-- the GHOST is facing. Nothing about the frame itself says it is not ours.
	--
	-- Hence a rule about the DESTINATION rather than the source: whatever the entries turn out to
	-- belong to, art that disagrees with everything already learned for this facing is not this
	-- facing's art. Measured before and after -- four mixed-group acceptances in one session
	-- beforehand, and they arrived ~2000 frames in, once the ghost was up and facing elsewhere,
	-- which is why the tier looked correct at first and then degraded in all four directions.
	entry.step[stride] = frame
	-- TRACE, off unless MESHGHOST_CRYSTAL_FACING_TRACE is set. Edge-triggered by construction: a
	-- direction has one standing view and four stride slots, and a slot only logs when its art
	-- CHANGES, so this fires a handful of times a session and costs nothing per frame. File only --
	-- one console line a second was measured at 63-83ms.
	--
	-- WHAT IT IS FOR. `facingFrames` is never cleared, so a sample that gets past the guards above
	-- stays for the session. Logging what actually lands here, with the state it was captured in,
	-- is what tells a contaminated sample from a legitimate stride -- the two are
	-- indistinguishable afterwards, and that ambiguity cost four wrong fixes on 2026-08-22.
	if MESHGHOST_CRYSTAL_FACING_TRACE then
		local parts = {}
		for i = 1, 4 do
			parts[i] = string.format("%d%s@%d,%d", frame[i].offset,
				frame[i].xflip and "F" or "", frame[i].dx, frame[i].dy)
		end
		-- THE INVARIANT, so the log settles this instead of the user's eyes. A view is four tiles
		-- and a facing may only wear its own: down is group 0, up group 1, left/right group 2,
		-- masked so a stepping view lands in the same group as the standing one it mirrors. Two
		-- groups under one facing IS the bug this was built for -- the tier alternates them and the
		-- character visibly changes where it looks while walking in a straight line.
		logFile(string.format(
			"facing-trace: f=%d LEARNED facing=%d stride=%d group=%d dir=%d face=%02X [%s]%s",
			emu.framecount(), facing, stride, group, dirNow, prev.face or 0,
			table.concat(parts, " "),
			(group ~= ((facing == 0) and 0 or (facing == 1) and 1 or 2)
				or (group == 2 and frame[1].xflip ~= (facing == 3)))
				and "  *** WRONG VIEW FOR THIS FACING -- STILL BROKEN ***" or ""))
	end
end

-- WHICH FRAME A PEER IS ON, DERIVED FROM THE PEER'S OWN STEP RATHER THAN FROM A TIMER HERE.
--
-- The engine drives a spawned ghost's animation for us; a drawn one has nobody to drive it, so
-- this is the one piece of animation the adapter genuinely has to do itself. It is registered as
-- part of the drawn tier's cost in BANDAGES.md.
--
-- IT IS NOT A TIMER, and that is the whole design. This used to alternate two frames every 8
-- frames on a free-running counter (`WALK_FRAME_HOLD`), which cannot be 1:1 by construction: a
-- counter here has no relationship to where the peer actually is in its step, so the feet drift
-- against the body no matter what the constant is. Tuning it would have been the "rate change as
-- the answer" that CLAUDE.md rules out.
--
-- Instead the frame is a function of the peer's OWN sub-tile progress, which is already on the
-- wire as `extras.prog` and needed no new field. Measured 2026-08-22 across four directions, the
-- partition is exact and has no overlap:
--
--   prog 14, 0, 2, 4      -> the STEPPING view (tiles base + 0x80 + view)
--   prog 6, 8, 10, 12     -> the PASS view     (tiles base + view)
--
-- Eight frames of sixteen, which is the DUTY CYCLE the player's own sprite runs: the period was
-- already right at a wider band and only the width was wrong, measured as 10 frames of 16 against
-- the player's 8.
--
-- so the test is simply "outside the middle of the step". The band SPANS THE TILE BOUNDARY on
-- purpose -- 14 is the start of the next step, not the end of this one -- and that is what makes
-- it one contiguous burst of 8 frames per tile rather than two short ones. Corrected 2026-08-22
-- after printing the ghost's cadence against the player's, one character a frame:
--
--   player ....SSSSSSSS....      one burst of 8
--   ghost  .SSSS........SS.      the same burst, split at the boundary -- the user: the walking
--                                animation is *"a bit fast"*, which is what two bursts look like `extras.prog` has now paid three times:
-- it was added for positioning, then fixed the painted stride's spacing, and now selects the
-- frame. Sending the fact instead of a symptom is why.
--
-- WHICH FOOT comes from `extras.face`, the peer's OBJECT_FACING -- direction and stride index in
-- one byte, which is how the engine itself stores it. Down and up mirror their stepping view
-- between strides (the two feet); left and right cannot, because there the flip is what says
-- which way the character looks. Nothing here needs to know which case it is in: the stride index
-- selects a learned frame, and whichever the engine drew for the local player is what a peer gets.
--
-- On `facingFrames` rather than a new top-level name: this file is at 197 of Lua's 200 top-level
-- locals and has failed to load silently four times from crossing it. A string key cannot collide
-- with the numeric facings 0..3, and nothing iterates this table.
-- DERIVE A FACING NOBODY HAS WALKED YET, from one somebody has.
--
-- The cache is learned by watching the LOCAL player, so a facing this player has not used since
-- the adapter loaded has no entry at all -- and `pick` then returned nil and every caller fell
-- back to the standing DOWN view. That is invisible most of the time, because a player faces all
-- four ways within seconds of moving, and glaring the moment a peer wears a sprite the local
-- player never wears: the user, 2026-08-26, on an Archipelago peer's bike seen from vanilla --
-- *"left is left, and up/down/right = down"*. Confirmed by walking one step in each direction,
-- after which every facing rendered correctly for the rest of the session.
--
-- WHAT MAY BE DERIVED AND WHAT MAY NOT. The ARRANGEMENT -- which quadrant each of the four parts
-- occupies, and the stepping twin 0x80 higher -- is learned from the engine and is never invented
-- here. Only the tile GROUP is substituted, and this file already states that a group is "a
-- property of the sprite format, not something to learn": DOWN is tiles 0-3, UP is 4-7, and
-- LEFT/RIGHT share 8-11, told apart by the hardware flip rather than by separate art.
--
-- So a derived frame is a measured arrangement pointed at a different group, plus the flip when
-- crossing between left and right -- where the parts mirror, which is why `dx` is reflected across
-- the 8-pixel frame. Nothing is drawn from nothing: with no learned entry at all this still
-- returns nil and the caller's own fallback stands.
-- ON `facingFrames` RATHER THAN A TOP-LEVEL LOCAL: this file sits at Lua's 200-local ceiling for
-- a main chunk, and adding this as a plain `local function` crossed it on the first try -- which
-- does not error at runtime, it stops the file compiling (`emulator/CLAUDE.md`). Fifth time.
function facingFrames.derive(facing)
	-- KEYED BY DIRECTION INDEX 0-3, NOT BY THE FACING BYTE. The cache is filled with `prev.dir` and
	-- read with `o.facing`, both of which are `(OBJECT_DIRECTION // 4) & 3` -- down, up, left,
	-- right. The first version of this function indexed its group table with the raw facing bytes
	-- 0/4/8/12, so only DOWN ever matched and the other three derived nothing: the user, 2026-08-26,
	-- on a bike that had at least got left right before -- *"always facing 'down' when on the bike
	-- now, for all 4 directions"*. Strictly worse than the fallback it replaced, which is what a
	-- wrong lookup key buys, and it type-checks perfectly.
	--
	-- Groups per `documentation.md`: down 0-3, up 4-7, left and right share 8-11 and are told apart
	-- by the hardware flip. Dir 3 is RIGHT, the flipped one.
	local GROUP = { [0] = 0, [1] = 4, [2] = 8, [3] = 8 }
	local base = GROUP[facing]
	if not base then
		return nil
	end
	-- DECLARED, and this line is not optional. Written first as a bare `out = out or {...}` inside
	-- the loop below, which makes it a GLOBAL: it would survive between calls, so the entry derived
	-- for one direction would be handed back for the next one and never rebuilt. It compiles, it
	-- runs, and `luac -p` has nothing to say about it -- the same class of fault as the GAIT_PX
	-- nil-global earlier today, in the opposite direction.
	local out
	-- WHEN NOTHING HAS BEEN LEARNED AT ALL, BUILD THE SOURCE FROM THE FORMAT ITSELF.
	--
	-- Remapping a learned facing only works if SOME facing has been learned, and the cache is
	-- filled by watching the LOCAL player -- so a client whose player has not moved since the
	-- adapter loaded has an empty cache and every peer falls back to the standing DOWN view. That
	-- is not a corner case: it is a player standing still watching someone ride past, which is
	-- exactly the session that produced *"stuck in the idle bike pose"*. Measured rather than
	-- guessed, after four wrong hypotheses: `481 of 6341 peer-frames stepped; not stepped: 446
	-- mid-step, 5414 idle` -- 446 frames where the peer was genuinely mid-step and no step frame
	-- existed to draw.
	--
	-- Every number below is measured and recorded elsewhere in this repo, which is the only reason
	-- it may be written down rather than observed:
	--   * a walking sprite is 24 tiles -- 12 standing, 12 stepping at +0x80 (`documentation.md`,
	--     and confirmed 2026-08-26 by reading the cartridge: sprite table entries are 0x180 apart,
	--     384 bytes, and all 12 stepping tiles of the BIKE differ from its standing ones);
	--   * groups are down 0-3, up 4-7, left/right 8-11 shared, told apart by the hardware flip;
	--   * the four parts sit at (0,0) (8,0) (0,8) (8,8), measured 2026-08-22 across every facing,
	--     with the flipped side view mirroring them.
	--
	-- A LEARNED ENTRY ALWAYS WINS, and a slot derived from one wins over this: it is consulted LAST,
	-- per slot, after the loop below has taken everything it can.
	--
	-- It began as an early return guarded on "nothing learned at all", and that guard was almost
	-- never true, so it never ran. The learner rewrites `entry.stand` EVERY IDLE FRAME for whatever
	-- direction the local player is standing in, so the cache always holds at least one stand-only
	-- entry -- and the loop below would then remap exactly that, producing a derived facing with a
	-- standing frame and no stepping frames. Measured after the fix that was meant to end this:
	-- `288 of 2792 stepped; not stepped: 260 mid-step` -- half the moving frames still standing.
	local function seedPart(i, stepping)
		local flip = (facing == 3)
		return {
			offset = (stepping and 0x80 or 0) + base + i,
			xflip = flip,
			dx = flip and (8 - ((i % 2) * 8)) or ((i % 2) * 8),
			dy = (i // 2) * 8,
		}
	end
	local function seedFrame(stepping)
		return { seedPart(0, stepping), seedPart(1, stepping),
			seedPart(2, stepping), seedPart(3, stepping) }
	end
	for _, src in ipairs({ 0, 1, 2, 3 }) do
		local e = facingFrames[src]
		local from = GROUP[src]
		if e and src ~= facing and from then
			local mirror = (src == 3) ~= (facing == 3)
			local function remap(f)
				if not f then
					return nil
				end
				local out = {}
				for i = 1, 4 do
					local p = f[i]
					if not p then
						return nil
					end
					-- NOT `mirror and (not p.xflip) or p.xflip`. That is the Lua and/or ternary
					-- trap, and it cannot express this: when `mirror` is true and `p.xflip` is
					-- ALSO true, the middle term is `false`, so the `or` falls through and hands
					-- back `p.xflip` -- true. The flip therefore never CLEARS, only ever sets.
					--
					-- What it looked like on screen: the local player walks into a route facing
					-- right, so RIGHT is the learned entry and draws correctly, while down, left
					-- and up are all derived FROM right and each inherits a flip that should have
					-- been undone -- three mirrored facings out of four. The user, 2026-08-27:
					-- *"its when looking down/left/up (after entering the same route as someone
					-- else), facing right looks correct"*.
					--
					-- Pre-existing, and nothing to do with cross-map ghosts -- it reproduces on
					-- c0c6cf2 with none of that work applied. Cross-map only made it easy to hit,
					-- because a peer arriving from another route is very likely facing a direction
					-- this player has not turned to yet on this map, which is exactly when a
					-- DERIVED entry is used instead of a learned one.
					--
					-- `dx` on the next line reads the same way and is SAFE, which is why the two
					-- were written alike: `8 - p.dx` is 0 when p.dx is 8, and 0 is truthy in Lua.
					-- Only a `false` middle term triggers this, and xflip is the only boolean here.
					local xf = p.xflip and true or false
					if mirror then xf = not xf end
					out[i] = {
						offset = (p.offset & 0x80) | (base + ((p.offset & 0x7F) - from)),
						xflip = xf,
						-- The frame is two tiles wide and `dx` is measured from its own top-left,
						-- so reflecting it is `8 - dx`. Only when crossing the flip boundary.
						dx = mirror and (8 - p.dx) or p.dx,
						dy = p.dy,
					}
				end
				return out
			end
			-- FILL EVERY SLOT THIS SOURCE CAN, AND KEEP LOOKING FOR THE REST.
			--
			-- The first version returned the first source that yielded ANYTHING, so a facing whose
			-- STANDING frame had been learned but whose stepping frames had not would win outright
			-- -- and a derived entry with a stand and no steps sends `pick` straight to the idle
			-- pose. On screen that is a bike that never pedals: the user, 2026-08-26, with the
			-- facings by then correct -- *"its just stuck in the idle 'bike' pose when moving
			-- around"*. The stepping views were sitting in another direction's entry all along.
			--
			-- Slots are therefore filled independently and the search continues until the entry is
			-- complete or the sources run out. `mirror` and `from` differ per source, which is
			-- exactly why this happens inside the loop rather than by picking one winner first.
			out = out or { step = {}, derived = true }
			out.stand = out.stand or remap(e.stand)
			for i = 0, 3 do
				out.step[i] = out.step[i] or remap(e.step[i])
			end
			if out.stand and out.step[0] and out.step[1] and out.step[2] and out.step[3] then
				return out
			end
		end
	end
	-- Whatever was gathered, complete or not: a partial entry still beats the caller's down-facing
	-- fallback, and `pick` degrades inside it exactly as it does for a learned one.
	-- ANY SLOT STILL EMPTY GETS THE FORMAT'S OWN ANSWER. Without this a peer can be left holding a
	-- standing frame and no stepping frames, which is not a missing detail -- it is a character
	-- that never animates, which is the whole symptom this function has been chasing.
	out = out or { step = {}, derived = true }
	out.stand = out.stand or seedFrame(false)
	for i = 0, 3 do
		out.step[i] = out.step[i] or seedFrame(true)
	end
	return out
end

function facingFrames.pick(facing, walking, prog, stride)
	local entry = facing and facingFrames[facing]
	if not entry then
		-- NOT CACHED INTO facingFrames[facing], deliberately: a derived entry must never be
		-- mistaken for a learned one, and the moment the local player does face this way the real
		-- arrangement should take over without anything having to invalidate a substitute.
		entry = facing and facingFrames.derive(facing) or nil
	end
	if not entry then
		return nil -- nothing learned for any facing yet; each caller has its own fallback
	end
	-- No prog band here any more (2026-08-25): the caller's `walking` now encodes the engine's
	-- own stand/step alternation, read off the peer's face byte (see facingFrames.pose). The band
	-- was this function re-deriving that alternation from step progress, which is only correct at
	-- the walk -- at the bike it alternated per tile instead of per stride and the pedalling ran
	-- at double speed.
	if walking then
		local f = entry.step[(stride or 0) & 3]
		-- A LEARNED ENTRY CAN BE STAND-ONLY, AND THAT IS THE COMMON CASE, NOT A RARE ONE.
		--
		-- `entry.stand` is rewritten EVERY IDLE FRAME for whatever direction the local player is
		-- standing in, while `entry.step` is only filled by that player actually WALKING that way.
		-- So a client whose player is standing still -- which is exactly the client watching a peer
		-- ride past -- holds a learned entry with a standing frame and no stepping frames at all.
		-- `derive` never got a look in, because it is only consulted when a facing has NO entry.
		--
		-- Result on screen: a peer that never animates. Four fixes aimed at `derive` missed it
		-- entirely for this reason, and the counter said so throughout -- `288 of 2792 stepped; not
		-- stepped: 260 mid-step`, half the moving frames drawing a stand.
		--
		-- So the fallback chain is completed here rather than deepened: learned step -> any learned
		-- step for this facing -> a DERIVED step (remapped from another facing, or the sprite
		-- format's own arrangement) -> and only then the standing frame.
		if not f and not (entry.step[0] or entry.step[1] or entry.step[2] or entry.step[3]) then
			local d = facingFrames.derive(facing)
			if d then
				f = d.step[(stride or 0) & 3] or d.step[0]
			end
		end
		-- ANY STEPPING VIEW BEATS THE STANDING ONE. A slot is only filled once the local player has
		-- walked that way on that stride, so a direction can stay short one indefinitely -- and
		-- falling back to `stand` there DROPS THE WHOLE STEP, which on screen is a walk cycle that
		-- skips beats and reads as too fast. The user, 2026-08-22: up, down and left looked normal
		-- while *"walking right still feels fast"* -- right being the direction whose slots had not
		-- all been seen.
		--
		-- For left and right the substitution is EXACT: the side view has no mirrored twin to
		-- alternate with, because there the flip is what says which way the character looks, so all
		-- four strides hold the same image. For up and down it is the wrong foot for one step,
		-- which is a far smaller error than missing the step entirely.
		for i = 0, 3 do
			if f then break end
			f = entry.step[i]
		end
		if f then
			return f
		end
	end
	return entry.stand or entry.step[0] or entry.step[1] or entry.step[2] or entry.step[3]
end

-- THE POSE FOR AN ANIMATION THAT DOES NOT MOVE THE CHARACTER.
--
-- The drawn tier derives its pose from POSITION -- which direction the peer walked and how far
-- through the step it is -- so by construction it cannot show anything the character does while
-- standing on one tile. Bump was fixed as a special case on 2026-08-23; spin, the turn in place,
-- fishing, the Dig/Teleport flicker and the Fly landing were left, and they are the same gap.
--
-- ONE RULE INSTEAD OF FIVE, and it is the engine's own. `OBJECT_FACING` is not a direction: it is
-- literally the index into `Facings` (`data/sprites/facings.asm`), the table the engine looks up
-- to decide which tiles to emit for a character this frame. So a peer's facing byte -- already on
-- the wire as `extras.face` -- states the pose outright, and the whole job here is to read it the
-- way `_UpdateSprites` does rather than to reconstruct it from where the peer is standing.
--
-- What the table says, all of it from the decomp (`constants/map_object_constants.asm` for the
-- values, `data/sprites/facings.asm` for the art, `engine/overworld/map_object_action.asm` for
-- which action produces which facing) -- `documentation.md` has the full enumeration:
--
--   0x00-0x0F  FACING_STEP_<DIR>_<0..3>: direction = byte // 4, stride = byte & 3. Strides 0 and 2
--              are the STANDING view, 1 and 3 the two STEPPING ones -- which is the same
--              "stepping on odd strides" the bump fix measured, stated by the table.
--   0x10-0x13  FACING_FISH_DOWN/UP/LEFT/RIGHT: the character's own STANDING view for that
--              direction, plus one extra sprite for the rod (see facingFrames.ROD).
--   0x14       FACING_EMOTE. NOT REACHABLE FOR A PLAYER -- the "!" is a SEPARATE map object
--              (SpawnEmote, flagged EMOTE_OBJECT_F), so the player's own action byte never
--              becomes OBJECT_ACTION_EMOTE. phase9.md's 2026-08-19 enumeration had this wrong.
--   0xFF       STANDING (-1): the engine skips the object entirely, drawing nothing.
--
-- So `act` only decides WHETHER to trust the facing byte over the position-derived pose. While a
-- peer is walking normally (actions 0/1/2) the position-derived pose is strictly better, because
-- it is phase-locked to the peer's own sub-tile progress rather than to a byte sampled at the send
-- rate -- that is the measured duty cycle in facingFrames.pick, and it is not thrown away here.
--
-- Returns facing, walking, stride, hide, rod.
-- On `facingFrames` rather than a new top-level name: this file sits at Lua's 200-local ceiling.
function facingFrames.pose(act, face, facing, moving, stride)
	if act == nil or ACTIONS.idle[act] then
		-- ORDINARY WALKING READS THE FACE BYTE TOO (2026-08-25). This branch used to fall through
		-- to the position-derived pose on the reasoning that prog is "phase-locked to the peer's
		-- own sub-tile progress" -- and the partition it fed was measured EXACT at the walk
		-- (2026-08-22). Both true, and still wrong at any other gait: the engine's walk cycle is
		-- NOT a function of step progress. `SetFacingStepAction` advances OBJECT_STEP_FRAME once
		-- per action tick and takes the stride from bits 2-3 -- a FIXED clock, one stride per 8
		-- video frames, the same speed walking or biking -- and `data/sprites/facings.asm` says
		-- strides 0/2 are the STANDING view, 1 the stepping view, 3 the stepping view mirrored.
		-- At the walk (16 frames a tile) the fixed clock and prog happen to align, which is why
		-- the prog partition measured exact and nobody noticed the assumption. On the bike (8
		-- frames a tile) prog laps the clock and the drawn ghost pedalled at double speed -- the
		-- user: *"the drawn ghost is doing the 'biking' animation way faster"*.
		--
		-- The wire's `face` byte IS the peer's own step-frame clock, already engine-paced at every
		-- gait, so the pose is read off it exactly as the bump/spin/fish branches below have
		-- always done. `moving` still gates the stepping view: a peer that stops mid-packet holds
		-- its last stride byte, and the engine itself stands a stopped character.
		if face and face < 0x10 then
			local fs = face & 3
			return facing, moving and ((fs & 1) == 1), fs, false, nil
		end
		return facing, moving, stride, false, nil
	end
	-- OBJECT_ACTION_SPIN_FLICKER (5) calls SetFacingCounterclockwiseSpin2, which spins the
	-- direction and then sets OBJECT_FACING to STANDING -- so the character is INVISIBLE on that
	-- frame. StepFunction_DigTo alternates it with OBJECT_ACTION_SPIN every other engine tick,
	-- and that alternation IS the Dig/Teleport flicker. Checked as an action as well as a facing
	-- because a peer's `face` and `act` are sampled from the same packet but the action is the
	-- thing the engine keys on.
	if act == 5 or face == 0xFF then
		return facing, false, 0, true, nil
	end
	if face and face >= 0x10 and face <= 0x13 then
		-- FACING_FISH_* are in the same DOWN/UP/LEFT/RIGHT order as this adapter's dir index.
		return face - 0x10, false, 0, false, face - 0x10
	end
	if face and face < 0x10 then
		local s = face & 3
		return (face // 4) & 3, (s & 1) == 1, s, false, nil
	end
	-- 0x14 and above are scenery facings (the emote box, a shadow, the Copycat dolls, boulder
	-- dust, shaking grass). A player object never holds one; show the peer standing rather than
	-- guess at art we have not learned.
	return facing, false, 0, false, nil
end

-- THE FISHING ROD, which is the one part of a fishing pose that is not the character's own art.
-- FacingFishDown/Up/Left/Right each add a fifth sprite with ABSOLUTE_TILE_ID set, meaning the
-- tile id is used as-is rather than added to the character's tile base: $fc for the vertical rod
-- and $fd for the horizontal one, which are FishingRodGFX tiles 0 and 1. Positions and the flip
-- are the engine's own, read off `data/sprites/facings.asm` (the rows are `db y, x, attr, tile`).
-- Keyed by this adapter's dir index; `t` is the tile within FishingRodGFX.
facingFrames.ROD = {
	[0] = { dx = 0, dy = 16, t = 6 }, -- down: below the character
	[1] = { dx = 0, dy = -8, t = 6 }, -- up: above it
	[2] = { dx = -8, dy = 5, t = 7, flip = true }, -- left
	[3] = { dx = 16, dy = 5, t = 7 }, -- right
}

-- THE FLYING POKEMON'S ICON, and the descent the engine flies it in on.
--
-- `FlyToAnim` does not animate the player's map object at all -- it hides every character and runs
-- a cutscene sprite whose graphics are the icon of the mon in `wCurPartyMon`
-- (`FlyFunction_InitGFX`, `engine/events/field_moves.asm`). So a peer's landing is only 1:1 if the
-- ghost becomes that Pokemon for the descent, which is what these two functions are for.
--
-- SPECIES -> GRAPHICS is two hops, both in bank 0x23: `MonMenuIcons[species - 1]` gives an ICON
-- index (several species share one), and `IconPointers[icon]` gives the address of its eight
-- tiles. Memoised per species -- neither table can change.
facingFrames.iconRom = {}
facingFrames.iconGfx = function(species)
	if not facingFrames.iconTbl or not facingFrames.iconPtrs or not species
		or species < 1 or species > 251 then
		return nil
	end
	local cached = facingFrames.iconRom[species]
	if cached ~= nil then
		return (cached ~= false) and cached or nil
	end
	local icon = romByte(facingFrames.iconTbl + species - 1)
	local e = facingFrames.iconPtrs + icon * 2
	local addr = romByte(e) | (romByte(e + 1) << 8)
	local at = (addr >= 0x4000) and (facingFrames.iconBank * 0x4000 + (addr - 0x4000)) or false
	facingFrames.iconRom[species] = at
	return at or nil
end

-- THE ENGINE'S OWN LANDING CURVE, read off `SpriteAnimFunc_FlyTo` rather than invented.
--
-- The cutscene sprite starts at `depixel 31, 10` -- y = 252, which wraps to just above the screen
-- -- and adds 2 to its y every frame until it reaches 84, its resting line: 44 frames. In the same
-- frames `VAR4` decays 88 -> 0 by 2, and `VAR3` counts up feeding `Sprites_Cosine`, whose result
-- (`a = d * cos(a * pi/32)`) becomes the sprite's X offset. So the mon SPIRALS down: swinging
-- side to side, the swing shrinking to nothing exactly as it settles.
--
-- Expressed here relative to the LANDING TILE rather than to the screen, because a ghost lands on
-- its own tile and not at the screen's centre: at frame k the icon is `88 - 2k` pixels above its
-- destination and `(88 - 2k) * cos(k * pi/32)` pixels to the side. Height and swing share the one
-- decaying amplitude, which is the engine's arithmetic and not a coincidence worth re-deriving.
facingFrames.FLY_FRAMES = 44
facingFrames.flyOffset = function(k)
	local amp = 88 - 2 * k
	if amp < 0 then amp = 0 end
	return math.floor(amp * math.cos(k * math.pi / 32) + 0.5), -amp
end

-- Which of the icon's two frames, and flipped or not. `.Frameset_RedWalk` holds each for 8 frames
-- and x-flips the second one every other cycle: A, B, A, B-flipped.
facingFrames.flyFrame = function(k)
	local cycle = (k // 8) % 4
	return (cycle == 1 or cycle == 3) and 4 or 0, cycle == 3
end

-- The icon's four tiles, from `.OAMData_RedWalk`: a 2x2 block, tiles 0..3 left-to-right then
-- top-to-bottom, drawn here from the block's own top-left rather than the engine's centre anchor.
facingFrames.ICON_BOX = {
	{ dx = 0, dy = 0, t = 0 }, { dx = 8, dy = 0, t = 1 },
	{ dx = 0, dy = 8, t = 2 }, { dx = 8, dy = 8, t = 3 },
}

-- WHERE ONE EMOTE'S FOUR TILES LIVE IN THE CARTRIDGE, memoised.
--
-- `Emotes` is twelve six-byte entries -- `dw graphics, db length, db bank, dw vtile` -- so this is
-- the same banked-pointer arithmetic the sprite table needs. Read from ROM rather than from VRAM
-- $f8 for the reason the fishing rod is: those tiles hold whatever the LOCAL game last loaded
-- there, which on a receiving machine has nothing to do with what the peer is doing.
facingFrames.emoteGfx = function(idx)
	if not EMOTES_ROM or not idx or idx < 0 or idx > 11 then
		return nil
	end
	local cached = facingFrames.emoteRom[idx]
	if cached ~= nil then
		return (cached ~= false) and cached or nil
	end
	local e = EMOTES_ROM + idx * 6
	local addr, bank = romByte(e) | (romByte(e + 1) << 8), romByte(e + 3)
	local at = (bank ~= 0 and addr >= 0x4000) and (bank * 0x4000 + (addr - 0x4000)) or false
	facingFrames.emoteRom[idx] = at
	return at or nil
end
facingFrames.emoteRom = {}

-- The four tiles of an emote box, in FacingEmote's own arrangement: $f8 $f9 over $fa $fb, which
-- are graphics tiles 0..3. The box sits one tile ABOVE the character (the emote object's own
-- OBJECT_SPRITE_Y_OFFSET is -16), and in PAL_OW_EMOTE (5) rather than the character's palette.
facingFrames.EMOTE_BOX = {
	{ dx = 0, dy = 0, t = 0 }, { dx = 8, dy = 0, t = 1 },
	{ dx = 0, dy = 8, t = 2 }, { dx = 8, dy = 8, t = 3 },
}

-- WHICH FISHING SHEET A PEER GETS, from the peer's own sprite id rather than from wPlayerGender.
-- A receiving machine's local gender says nothing about the peer, and in a two-player session the
-- two are routinely different. nil means "not a player sprite, or not a build we have this
-- address for" -- the peer is then drawn without the fishing half rather than with somebody
-- else's art.
function facingFrames.fishRom(spriteId)
	if not facingFrames.fishChris then
		return nil
	end
	if spriteId == 0x60 then -- SPRITE_KRIS
		return facingFrames.fishKris
	end
	if spriteId == 0x01 then -- SPRITE_CHRIS
		return facingFrames.fishChris
	end
	return nil
end

-- The bottom half of a standing view is what the fishing sheet replaces, and this is the whole
-- mapping: sprite tile offsets 2,3 (down), 6,7 (up) and 10,11 (left, and right x-flipped) become
-- fishing tiles 0..5 in that order. `engine/events/fishing_gfx.asm` loads them as three 2-tile
-- blocks at $02, $06 and $0a. Returns nil for a tile the sheet does not replace.
function facingFrames.fishTile(offset)
	if offset > 11 or (offset % 4) < 2 then
		return nil
	end
	return (offset // 4) * 2 + (offset % 2)
end

-- source is { vram = <tile base> } for a sprite the map has loaded, or { rom = <gfx offset> } for
-- one read straight from the cartridge. Everything else is identical, which is the point: the
-- arrangement is learned once from the engine and applies to both.
local function drawCharacter(source, sx, sy, palIndex, facing, walking, prog, stride, fishRom)
	local colors = paletteColors(palIndex or 0)
	local frame = facingFrames.pick(facing, walking, prog or 0, stride)
	local function partRows(offset)
		-- A FISHING CHARACTER IS TWO SHEETS. The engine replaces the bottom half of the standing
		-- view in place (LoadFishingGFX, see FISHING_GFX_ROM), so the top half is the peer's own
		-- art and the bottom half is the fishing sheet's -- and on a receiving machine those tiles
		-- hold the peer's WALKING art, because the local player is not fishing. Reading the
		-- cartridge is the only way to get the half the engine would have swapped in.
		if fishRom then
			local ft = facingFrames.fishTile(offset)
			if ft then
				return decodeRomTile(fishRom, ft)
			end
		end
		if source.rom then
			-- THE CARTRIDGE LAYOUT IS NOT THE VRAM LAYOUT, and an offset carries the VRAM one.
			--
			-- In VRAM a character's stepping views sit 0x80 above its standing ones; in ROM the
			-- graphics are one contiguous block, so they sit directly after them. Measured
			-- 2026-08-22 by matching every VRAM tile back to the ROM tile it equals, on two sprites
			-- at two different bases, every pair agreeing: base+0..11 are ROM tiles 0..11, and
			-- base+0x80..0x8B are ROM tiles 12..23.
			--
			-- So a sprite's graphics are 24 tiles even though the header's own size field reports
			-- 12 -- that field describes the standing half only. Handing a 0x80-ish offset straight
			-- to the cartridge would read 2 KB past the sprite and draw whatever is there.
			return decodeRomTile(source.rom,
				((offset & 0x80) ~= 0) and (12 + (offset & 0x7F)) or offset)
		end
		return decodeTile((source.vram + offset) & 0xFF)
	end

	if frame then
		-- COMPOSE THE WHOLE CHARACTER, THEN DECOMPOSE IT INTO MAXIMAL RECTANGLES (2026-08-25).
		--
		-- Drawing tile-by-tile, row-by-row issued ~76 overlay primitives per character and the
		-- compare rig draws a peer twice: ~152 a frame, ~9,100 a second. BizHawk composites every
		-- one, and that cost is invisible from inside Lua -- the adapter measured 25ms of each
		-- second with a flat 60fps while the user was watching it stutter. Merging runs
		-- vertically first gained ~5%: character art is dithered, so identical runs rarely repeat
		-- straight down, and per-tile rows can never merge ACROSS the 8px tile seam either.
		--
		-- A 16x16 colour matrix has neither limit. Filling it costs 256 table writes -- nothing --
		-- and a greedy maximal-rectangle pass over it merges freely in both axes and across all
		-- four tiles, which is where the real reduction is. Exactly the same pixels: every cell is
		-- covered once, by the largest uniform rectangle whose top-left it is.
		-- The engine's own arrangement for this facing: which tile of the sprite goes where, and
		-- which way round.
		--
		-- DRAWING IS NOT THE COST, measured 2026-08-25 and worth keeping because it looks like an
		-- obvious suspect. The tier issues ~58 overlay primitives per character (~116 a frame with
		-- the compare rig), which reads as a lot -- so it was cut to ~2 with a whole-character
		-- rectangle decomposition, and then to exactly 1 with a diagnostic that drew each ghost as
		-- a single block. The user watched all three and the stutter never moved. Both changes
		-- were reverted: they were bought with an unverified change to what reaches the screen and
		-- paid for nothing. Look elsewhere before touching this again.
		for _, part in ipairs(frame) do
			drawRows(partRows(part.offset), sx + part.dx, sy + part.dy, colors, part.xflip)
		end
		return
	end
	-- Nothing learned for that facing yet (the player has not faced that way since the map
	-- loaded). The sprite's own first frame is a reasonable stand-in and is never wrong-looking,
	-- only wrong-facing.
	drawRows(partRows(0), sx, sy, colors)
	drawRows(partRows(1), sx + 8, sy, colors)
	drawRows(partRows(2), sx, sy + 8, colors)
	drawRows(partRows(3), sx + 8, sy + 8, colors)
end

-- ---------------------------------------------------------------------------
-- The HARDWARE tier: peers drawn by the Game Boy itself, not painted over it
-- ---------------------------------------------------------------------------
--
-- The middle rung of spawned -> hardware -> drawn, and the user's request, 2026-08-21. A peer here
-- is written straight into the game's sprite buffer, so the PPU draws it: the game's own live
-- palettes including day/night and fades, correct ordering against the game's own cast, and no
-- per-pixel Lua at all -- four bytes an entry instead of decoding and blitting tiles.
--
-- WHAT IT HONESTLY IS NOT, measured from the decomp before a line was written, because the case
-- for this tier was overstated when it was first proposed and the correction matters:
--
--   * IT ADDS ALMOST NO CAPACITY. It draws from the same 40 entries the engine already fills:
--     34-36 of 40 outdoors, 40 of 40 indoors (crowd-limits.md). That is zero to one extra
--     character, and in a clump the per-scanline limit bites first. The case for it is quality.
--   * IT DOES NOT GET OCCLUSION FREE. A Crystal text box is background tiles with the BG-to-OAM
--     priority bit CLEAR (TextboxPalette, home/text.asm:100), and the hardware window is parked
--     off-screen during normal play -- so a hardware sprite draws IN FRONT of a text box. This tier
--     therefore reuses the drawn tier's clipping rather than claiming to inherit any.
--   * IT INHERITS THE SPAWNED TIER'S RESIDENCY LIMIT. An OAM entry names a VRAM tile, so a peer
--     wearing a sprite this map never loaded cannot go here. Only the drawn tier reads the
--     cartridge, which is why it stays the bottom rung rather than this one.
--
-- HOW THE BUFFER WORKS (engine/overworld/map_objects.asm:2730, _UpdateSprites):
--   * `hUsedSpriteIndex` (00:ffbd) is a BYTE offset, reset to 0 every frame, and InitSprites
--     appends each visible character at 4 entries of 4 bytes;
--   * `.fill` then writes OAM_YCOORD_HIDDEN (160) into the Y byte of every remaining entry;
--   * the buffer reaches the hardware at VBlank.
-- So the free tail starts at `hUsedSpriteIndex` and our entries must be written AFTER the fill and
-- before the DMA. Whether the adapter's once-a-frame tick lands in that window is the one thing
-- that could not be settled from the source, so `verify()` below reads the hardware OAM back and
-- says plainly if nothing arrived, instead of drawing nothing and looking innocent.
local OAM_TIER = (MESHGHOST_CRYSTAL_OAM_OVERFLOW or os.getenv("MESHGHOST_CRYSTAL_OAM_OVERFLOW")) == "1"

local oam = {
	SHADOW = 0x400, -- wShadowOAM, 00:c400 -> flat
	ENTRIES = 40,
	next = nil, -- next entry index to write, counting DOWN from the top
	floor = 0, -- entries below this belong to the engine this frame
	placed = 0,
	landed = nil, -- has anything we wrote ever reached the hardware?
	checked = 0,
}

-- Once a frame, before any peer is placed: where does the engine's own use end, and are sprite
-- updates even running? `_UpdateSprites` returns immediately unless SPRITE_UPDATES_DISABLED_F is
-- SET (`ret z` on the bit test), and while it is not running the START menu has cleared the buffer
-- -- which is exactly when the game intends characters to be invisible, so we stay out.
function oam.beginFrame()
	oam.placed = 0
	oam.next = nil
	if not OAM_TIER then
		return
	end
	local flags = u8(W_STATEFLAGS)
	if not flags or (flags & 0x01) == 0 then
		return -- sprite updates disabled: the game is hiding everyone, and so do we
	end
	local used = memory.read_u8(0xFFBD, "System Bus")
	if type(used) ~= "number" then
		return
	end
	-- Allocate DOWNWARD from the last entry, so that when the hardware runs out of per-scanline
	-- sprites it drops a GHOST rather than one of the game's own characters. Same reasoning as the
	-- spawned tier's top-down struct allocation.
	oam.floor = used // 4
	oam.next = oam.ENTRIES - 1
end

-- One peer, four entries. Returns false when there is no room, so the caller falls through to the
-- drawn tier rather than the peer vanishing.
function oam.place(sx, sy, tileBase, palIndex, facing, walking, prog, stride)
	if not oam.next or oam.next - 3 < oam.floor then
		return false
	end
	-- The same picker the painted tier uses, deliberately: two rungs drawing the same peer from
	-- different frames is a comparison that says nothing, and COMPARE_TIERS exists to put them side
	-- by side. An offset of 0x80-ish needs no translation here -- an OAM entry names a VRAM tile,
	-- and the VRAM layout is what the offset was learned in.
	local frame = facingFrames.pick(facing, walking, prog or 0, stride)
	if not frame then
		return false -- nothing learned for this facing yet; the drawn tier has a fallback, we do not
	end

	for i, part in ipairs(frame) do
		local at = oam.SHADOW + (oam.next - (i - 1)) * 4
		-- OAM_Y_OFS / OAM_X_OFS are 16 and 8 (constants/hardware.inc:980) -- an OAM coordinate is
		-- the screen position plus those, which is how the hardware addresses off-screen edges.
		w8(at, (sy + part.dy + 16) & 0xFF)
		w8(at + 1, (sx + part.dx + 8) & 0xFF)
		w8(at + 2, (tileBase + part.offset) & 0xFF)
		-- Attributes: CGB palette in bits 0-2, VRAM bank in bit 3, X flip in bit 5. The priority
		-- bit is deliberately LEFT CLEAR: setting it would put the peer behind every non-zero
		-- background colour, i.e. behind the scenery it is standing on, which is worse than the
		-- text-box problem it would be trying to solve.
		w8(at + 3, (palIndex & 0x07) | 0x08 | (part.xflip and 0x20 or 0))
	end
	oam.next = oam.next - 4
	oam.placed = oam.placed + 1
	return true
end

-- Did any of it reach the hardware? Read from the OAM domain -- what the DMA actually delivered --
-- never from the shadow bytes we wrote, which would only prove that the write happened.
function oam.verify()
	if not OAM_TIER or oam.placed == 0 or oam.landed ~= nil then
		return
	end
	oam.checked = oam.checked + 1
	if oam.checked < 120 then
		return
	end
	-- Dump the whole entry, not just its Y. "Something arrived" and "something VISIBLE arrived" are
	-- different claims, and the gap between them is where a wrong tile id or a wrong attribute byte
	-- hides: the entry is present, on screen, and draws nothing anyone can see.
	local y = memory.read_u8((oam.ENTRIES - 1) * 4, "OAM")
	local parts = {}
	for i = 0, 3 do
		local at = (oam.ENTRIES - 1 - i) * 4
		parts[#parts + 1] = string.format("[%d] y=%s x=%s tile=%s attr=%s", oam.ENTRIES - 1 - i,
			tostring(memory.read_u8(at, "OAM")), tostring(memory.read_u8(at + 1, "OAM")),
			tostring(memory.read_u8(at + 2, "OAM")), tostring(memory.read_u8(at + 3, "OAM")))
	end
	log("MeshGhost: hardware tier, as the DMA delivered it -- " .. table.concat(parts, "  "))
	oam.landed = (type(y) == "number" and y ~= 160 and y ~= 0)
	if oam.landed then
		log("MeshGhost: the hardware tier is reaching the screen (entry 39 read back from OAM).")
	else
		log("MeshGhost: the hardware tier wrote entries but NOTHING reached the hardware -- the "
			.. "engine refills the buffer after we write, so these peers are invisible. Falling "
			.. "back to the drawn tier is the correct fix, not writing harder.")
	end
end

local function screenCoords(mx, my)
	local wx, wy = u8(W_XCOORD) or 0, u8(W_YCOORD) or 0
	local bx, by = u8(W_BGMAPOFFSETX) or 0, u8(W_BGMAPOFFSETY) or 0
	return (((mx - wx) & 0x0F) * 16 - bx) & 0xFF, (((my - wy) & 0x0F) * 16 - by) & 0xFF
end

-- Screen coordinates that are correct on EVERY frame, mid-scroll included -- the reason
-- `screenCoords` above cannot be is that `wXCoord` and `wBGMapOffset*` update at different moments
-- within a step, so the pair is only coherent at tile boundaries; placement done mid-scroll from
-- them bakes in a one-off error, which is what the `cameraSettled()` gates existed to avoid.
--
-- This one anchors on the PLAYER'S OWN OBJECT instead: the engine maintains struct 0's sprite
-- coords and step countdown coherently on every frame (they are how the player is drawn), and the
-- camera is centred on the player, so for any world position
--     screen = playerSpriteXY + (worldPx - playerWorldPx)
-- with the player's world pixels derived exactly as the send path derives them (MAP_X names the
-- step's DESTINATION from its first frame; the character is 16-prog short of it, back along the
-- facing). Every term is the engine's own, read in one frame -- nothing here is our arithmetic
-- disagreeing with the engine's.
--
-- Written 2026-08-25 for the promotion path: the settled-camera gate meant a ghost could only
-- spawn during the camera's 1-2 frame boundary breath, and the model's own tile boundary -- which
-- the promotion must land on -- runs on a clock a constant phase away from it. Waiting for both
-- rode the 24-frame cap and landed mid-step, which was the user's snap.
local function liveScreenCoords(mx, my)
	local base = OBJECT_STRUCTS -- struct 0: the player
	local psx = u8(base + F_SPRITE_X) or 0
	local psy = u8(base + F_SPRITE_Y) or 0
	local pmx = (u8(base + F_MAP_X) or 0) * 16
	local pmy = (u8(base + F_MAP_Y) or 0) * 16
	if (u8(base + F_WALKING) or STANDING) ~= STANDING then
		local back = stepProgress(base) - 16
		local d = ((u8(base + F_DIRECTION) or 0) // 4) & 3
		if d == 0 then pmy = pmy + back
		elseif d == 1 then pmy = pmy - back
		elseif d == 2 then pmx = pmx - back
		else pmx = pmx + back end
	end
	return (psx + mx * 16 - pmx) & 0xFF, (psy + my * 16 - pmy) & 0xFF
end

-- Is the object we recorded still the object we made?
--
-- Everything the adapter writes goes through a slot number it wrote down earlier, and the game
-- rebuilds that array from ROM on every map load and every battle. So before writing, check the
-- three things we set ourselves are all still there: the cross-link both ways, and the sprite the
-- ghost was given. A rebuilt slot holding a real NPC fails this, and the entry is dropped instead
-- of being driven around or zeroed — the identity check phase9.md asks for, at the point where
-- being wrong costs someone else's NPC.
local function stillOurs(g)
	return g ~= nil
		and u8(g.mo_base + M_STRUCT_ID) == g.st
		and u8(g.st_base + F_MAP_OBJECT_INDEX) == g.mo
		and (g.sprite == nil or u8(g.st_base + F_SPRITE) == g.sprite)
end

local function despawnGhost(id)
	local g = ghosts[id]
	if not g then
		return
	end
	if not stillOurs(g) then
		-- Those bytes belong to the game again. Forget the entry; zeroing it would delete
		-- whatever the map load put there.
		ghosts[id] = nil
		log("MeshGhost: dropped stale bookkeeping for " .. id .. " (its slot is the game's again)")
		return
	end
	w8(g.st_base + F_SPRITE, 0)
	for off = 0, MAPOBJECT_LENGTH - 1 do
		w8(g.mo_base + off, 0)
	end
	ghosts[id] = nil
	log("MeshGhost: despawned " .. id)
end

-- Tell the engine what this object should do when it is not mid-step: stand, facing `dir`.
--
-- This is the fix for the snap the user reported on 2026-08-21 (*"a small snap once arriving at
-- the intended tile"*). spawnGhost copies a live NPC's whole template, movement byte included, and
-- when our step finishes the engine sets STEP_TYPE_FROM_MOVEMENT and dispatches on that byte. On a
-- template taken from a WANDERING NPC that means MovementFunction_RandomWalkXY, so for the frame
-- between our steps the ghost chose a direction of its own. posediff_probe.lua caught it exactly:
-- one frame per step where the facing jumped to an unrelated direction (9 -> 2 -> 8 while walking
-- left) and STEP_DURATION held values nothing in this adapter writes.
--
-- Both bytes are written because both are read: the object struct's is what
-- GetSpriteMovementFunction dispatches on, and the MAP OBJECT's is what RestoreDefaultMovement
-- re-reads at the end of every movement before GetInitialFacing turns the object to face it.
local function setGhostStanding(stBase, moBase, dir)
	local entry = SPRITEMOVEDATA_STANDING_BY_DIR[dir] or SPRITEMOVEDATA_STANDING_BY_DIR[0]
	w8(stBase + 0x03, entry) -- OBJECT_MOVEMENT_TYPE
	w8(moBase + 0x04, entry) -- MAPOBJECT_MOVEMENT
end

local function spawnGhost(id, x, y, peerSprite)
	-- No settled-camera gate any more: liveScreenCoords is exact mid-scroll (see it), and the gate
	-- was costing far more than the error it prevented -- it pinned every promotion to the
	-- camera's 1-2 frame boundary breath, a clock the model's own boundary is out of phase with.
	local srcMo, srcSt = findTemplateNpc()
	if not srcMo then
		return nil -- no template on this map; try again next frame
	end
	local mo, st = freeMapObject(), freeStruct()
	if not mo or not st then
		-- The map is FULL: this peer gets no body until one frees up. Say so, once a minute, and
		-- say which pool ran out -- because "my friend is invisible" and "my friend is not
		-- connected" look identical from the player's chair, and the answer differs per map.
		-- Crystal has 13 object structs and 16 map objects (pokecrystal's own
		-- NUM_OBJECT_STRUCTS / NUM_OBJECTS), and every map spends some of both on its own NPCs:
		-- New Bark Town leaves 9 for ghosts and runs out of STRUCTS first, Elm's lab also leaves
		-- 9 and runs out of MAP OBJECTS first. Measured 2026-08-19, agent_docs/crowd-limits.md.
		-- os.time(), not the frame counter: bridgeFrames is declared further down this file, so
		-- reading it here would resolve to a nil GLOBAL and throw at the exact moment a map
		-- fills up -- the forward-reference trap dev-scripts/lua-forward-refs.py exists for.
		local now = os.time()
		if not fullLoggedAt or (now - fullLoggedAt) >= 60 then
			fullLoggedAt = now
			log(string.format("MeshGhost: no room for %s on this map -- %s slots are all in use. "
				.. "Ghosts already here: %d. This is the game's own limit, not an error.",
				id, (not st) and "object struct" or "map object", ghostCount()))
		end
		return nil
	end

	local srcMoBase = MAP_OBJECTS + srcMo * MAPOBJECT_LENGTH
	local srcStBase = OBJECT_STRUCTS + srcSt * OBJECT_LENGTH
	local moBase = MAP_OBJECTS + mo * MAPOBJECT_LENGTH
	local stBase = OBJECT_STRUCTS + st * OBJECT_LENGTH

	for off = 0, MAPOBJECT_LENGTH - 1 do
		w8(moBase + off, u8(srcMoBase + off) or 0)
	end
	for off = 0, OBJECT_LENGTH - 1 do
		w8(stBase + off, u8(srcStBase + off) or 0)
	end

	w8(moBase + M_X, x)
	w8(moBase + M_Y, y)
	w8(moBase + M_STRUCT_ID, st)
	w8(stBase + F_MAP_OBJECT_INDEX, mo)
	for _, off in ipairs({ F_MAP_X, F_LAST_MAP_X, F_INIT_X }) do
		w8(stBase + off, x)
	end
	for _, off in ipairs({ F_MAP_Y, F_LAST_MAP_Y, F_INIT_Y }) do
		w8(stBase + off, y)
	end

	-- The player's sprite is resident on every map, so this needs no VRAM allocation and the
	-- correct gender comes along with it.
	w8(stBase + F_SPRITE, u8(OBJECT_STRUCTS + F_SPRITE) or 0)
	w8(stBase + F_SPRITE_TILE, u8(OBJECT_STRUCTS + F_SPRITE_TILE) or 0)
	w8(stBase + F_PALETTE, u8(OBJECT_STRUCTS + F_PALETTE) or 0)
	w8(moBase + M_SPRITE, u8(OBJECT_STRUCTS + F_SPRITE) or 0)

	local sx, sy = liveScreenCoords(x, y)
	w8(stBase + F_SPRITE_X, sx)
	w8(stBase + F_SPRITE_Y, sy)

	-- NORMALISE THE INHERITED FLAGS, do not merely add ours.
	--
	-- The whole template struct is copied from a live NPC, FLAGS1 included, so a ghost inherits
	-- whatever that character happened to be. Measured on Route 39, 2026-08-21: flags1 read 0x2E --
	-- WONT_DELETE plus **FIXED_FACING and SLIDING** -- because the templates available there are
	-- SPRITEMOVEDATA_STILL objects (the fruit tree, the Tauros), and STILL carries exactly those two
	-- (data/sprites/map_objects.asm).
	--
	-- SLIDING is why a ghost walked without ever animating: SetFacingStepAction tests it FIRST and
	-- jumps to SetFacingCurrent, so OBJECT_STEP_FRAME is never advanced and the walk cycle never
	-- runs. posediff_probe.lua caught the ghost at frame=0 through whole steps while the player's
	-- ran 7, 8, 9. FIXED_FACING is the same class: InitStep skips writing OBJECT_DIRECTION with it
	-- set, so the ghost cannot turn.
	--
	-- This is why the fault looked intermittent -- it depended entirely on which NPC the map
	-- offered. A ghost's flags must describe a GHOST, not its donor. Found only because the user
	-- chose the busiest map in the game to test on; a quiet room would have passed.
	local flags1 = (u8(stBase + F_FLAGS1) or 0) | ENGINE.WONT_DELETE
	flags1 = flags1 & ~0x08 -- SLIDING: suppresses the walk animation
	flags1 = flags1 & ~0x04 -- FIXED_FACING: suppresses turning
	w8(stBase + F_FLAGS1, flags1)

	-- NORMALISE THE MOVEMENT TYPE, and this is not tidiness -- it is the fix for the snap the user
	-- reported on 2026-08-21: *"it still snaps towards the end of the movement, when the ghost is
	-- close to done arriving onto the next tile"*.
	--
	-- The whole template is copied from a live NPC, movement type included. When our step finishes,
	-- the engine sets STEP_TYPE_FROM_MOVEMENT and dispatches on that byte
	-- (GetSpriteMovementFunction -> SpriteMovementData). Template an NPC that WANDERS and the byte
	-- says SPRITEMOVEDATA_WANDER, so for the one frame between our steps the engine runs
	-- MovementFunction_RandomWalkXY and the ghost picks a direction of its own.
	--
	-- Measured, not reasoned: posediff_probe.lua caught exactly one frame per step where the
	-- ghost's FACING jumped to an unrelated direction (9 -> 2 -> 8 while walking left) and its
	-- STEP_DURATION held a value nothing in this adapter writes. One frame of the wrong facing at
	-- the end of every step is precisely "a small snap on arrival".
	--
	-- The SPRITEMOVEDATA_STANDING_* entries all use SPRITEMOVEFN_STANDING, which does nothing but
	-- end the movement and stand. Which of the four is chosen decides the facing the engine
	-- restores at the end of each step, so stepGhost() re-pins it per direction; the spawn just
	-- needs a benign starting value.
	setGhostStanding(stBase, moBase, ((u8(stBase + F_DIRECTION) or 0) // 4) & 3)

	-- NORMALISE WHAT THE GHOST *IS*, the same way its flags and its movement are normalised above,
	-- and for the same reason: the template is a live NPC and everything that character was comes
	-- across in the copy. This is the third fault of that shape and the worst of them.
	--
	-- User, 2026-08-23: a spawned ghost raised the trainer `!` and the game hung; it recurred on a
	-- second route. The donor on the first one read
	--   05 2E 17 0F 09 00 FF FF 82 04 82 5B FF FF 00 00
	-- and bytes 8 and 9 are the whole story: byte 8's low nibble is MAPOBJECT_TYPE (its high nibble
	-- is the palette, one byte shared) and it held 2 = OBJECTTYPE_TRAINER, while byte 9 is
	-- MAPOBJECT_SIGHT_RANGE and held 4. The ghost was a trainer with a four-tile sightline, and it
	-- WALKS -- so it eventually spotted the player from somewhere no trainer stands, raised the `!`
	-- and ran a battle script for a trainer that is not on that tile. Field layout:
	-- pokecrystal `constants/map_object_constants.asm:82-99`; type values `constants/
	-- script_constants.asm:137-145` (`const_def`, so SCRIPT=0, ITEMBALL=1, TRAINER=2).
	--
	-- OBJECTTYPE_3 is the right thing for a ghost to BE. `engine/overworld/events.asm`'s
	-- ObjectEventTypeArray dispatches a faced object on this nibble, and types 3-6 are dummy
	-- entries whose handlers are `xor a / ret` -- face one and nothing happens. Type 0 (SCRIPT) and
	-- type 1 (ITEMBALL) both DEREFERENCE MAPOBJECT_SCRIPT_POINTER, so leaving a ghost as either
	-- while blanking the pointer would trade a trainer hang for a jump through a null pointer. A
	-- ghost is not a script, not an item and not a trainer; it is a character you can walk up to
	-- and face, and nothing more.
	--
	-- Only the ghost's own map object is touched. The donor is read and never written, so no NPC
	-- on the map changes -- which is what separates this from cloning the PLAYER instead, tried
	-- first on 2026-08-23 and reverted within the hour: the player's map object and 0x28-byte
	-- object struct carry the engine's own driving state, and copying them broke camera follow and
	-- displaced the map's objects. The donor was never the thing to change; the four bytes that say
	-- what the copy IS are.
	local palette = (u8(moBase + 0x08) or 0) & 0xF0 -- MAPOBJECT_PALETTE, high nibble of byte 8
	w8(moBase + 0x08, palette | 3)                  -- MAPOBJECT_TYPE = OBJECTTYPE_3 (a no-op event)
	w8(moBase + 0x09, 0)                            -- MAPOBJECT_SIGHT_RANGE: a ghost sees nobody
	w8(moBase + 0x0A, 0)                            -- MAPOBJECT_SCRIPT_POINTER, low
	w8(moBase + 0x0B, 0)                            -- ...and high; never read at type 3
	w8(moBase + 0x0C, 0xFF)                         -- MAPOBJECT_EVENT_FLAG: the "no flag" sentinel
	w8(moBase + 0x0D, 0xFF)                         -- both donors seen carried FF FF here

	ghosts[id] = { mo = mo, st = st, mo_base = moBase, st_base = stBase, area = areaId(),
		sprite = u8(stBase + F_SPRITE) }

	-- ...unless the peer's own sprite is already loaded on this map, in which case they get to
	-- look like themselves rather than like whoever is sitting at this machine.
	local own = applyPeerSprite(ghosts[id], peerSprite)

	-- READ THE TYPE BACK OUT OF THE GAME, do not report the value just written. `_CheckTrainerBattle`
	-- (pokecrystal `home/trainers.asm:13`) scans MAP OBJECTS and rejects on this nibble first, so
	-- this byte is the entire difference between a ghost and a trainer -- and the donor it was
	-- cloned from is worth having on the same line, because a `2` here would name the NPC to blame.
	local gotType = (u8(moBase + 0x08) or 0) & 0x0F
	log(string.format("MeshGhost: spawned %s at %d,%d (map object %d <-> struct %d, type %d, "
		.. "cloned from map object %d)%s", id, x, y, mo, st, gotType, srcMo,
		own and " wearing its own sprite" or ""))
	return ghosts[id]
end

-- Paint every peer the engine had no room for. Called once per frame; BizHawk clears its own
-- drawing layer each frame, so this redraws rather than accumulating.
--
-- Occlusion, which a drawn character does not get for free: skip anything inside the game's UI.
-- Crystal's text box is a compile-time constant -- the bottom six rows, full width
-- (TEXTBOX_Y = SCREEN_HEIGHT - TEXTBOX_HEIGHT, from the decomp) -- and its menus publish their
-- own rectangle in wMenuBorder*, which strobes back to zero as the menu redraws, so the last
-- non-zero one is latched. Measured 2026-08-19; see verified.md.
-- wMenuBorderTop/Left/Bottom/Right, 00:cf82-cf85, tile coordinates. Menus fill these in; text
-- boxes do not (measured 2026-08-19 -- a text box left them at zero), which is why the two panels
-- are handled separately below.
-- The menu rectangle the game publishes (wMenuBorder*), one table rather than four names.
local MENUBOX = { top = 0x0F82, left = 0x0F83, bottom = 0x0F84, right = 0x0F85 }

-- Is a UI panel on screen at all? Both a menu and a text box drive the Game Boy's window layer
-- (WY leaves its parked 144), and both strobe it, so this latches for a moment rather than
-- trusting a single frame. A HEURISTIC, and labelled as one: it decides only whether a DRAWN
-- ghost is painted, never anything about game state, and the spawned tier -- which is most
-- ghosts -- is occluded by the game itself and needs none of this.
local UI_LATCH_FRAMES = 20
local uiSeenAt, drawFrames = nil, 0

-- The player's step progress as of the frame OAM was built; see the pairing note in drawOverflow.
-- A few frames of the player's own position, so a peer's state can be compared against the moment
-- it describes rather than against now. PEER_STATE_AGE is the measured loopback round trip.
-- One table, not three names: this file lives at Lua's 200-local ceiling and has hit it three
-- times tonight, each as a bare LOAD FAILED with the whole adapter not loading.
-- `age` is the measured loopback round trip in frames.
-- `age` is the ONE knob on this tier, and it trades two artefacts against each other in a known
-- direction: too high and the ghost races its destination, too low and it snaps backwards at each
-- tile boundary. 4 was the measured round trip and read as fast; 2 splits it. Tuned by eye on
-- purpose -- what matters is which way to turn it, which is written here so the next person does
-- not rediscover the direction.
-- Also carries `settle`: frames left to wait after the world was rebuilt, so the painted tier does
-- not draw over a fade-in. One table rather than another name -- this file is at Lua's 200-local
-- ceiling and hit it four times tonight, every one a bare LOAD FAILED with nothing loaded.
-- age was 2 until 2026-08-23, chosen to match the wire delay when the ghost's position WAS the
-- wire's -- both sides of the paint subtraction late together, coherently. The model changed
-- underneath it: it now walks in real time on the camera's own frames, and subtracting a
-- two-frame-old reference from a real-time position turns every camera irregularity (the 4px
-- frames, the boundary breaths) into a two-frame-late wobble -- the per-step stutter that
-- survived every fix aimed at the model's motion, because it was never in the model.
local playerHistory = { size = 12, age = 0, settle = 0 }

-- WY IS NOT THE SIGNAL, and using it cost half the screen.
--
-- First version latched on the Game Boy's window register leaving its parked 144, on the theory
-- that any UI panel drives it. It does -- but so does normal play: this game toggles WY several
-- times a second with nothing open, so the latch was permanently on and every drawn ghost below
-- row 12 was hidden. The user's report was exact: "all of the bottom half is empty".
--
-- What IS reliable is the menu rectangle the game publishes (wMenuBorder*, measured 2026-08-19),
-- so that is the only thing consulted. Text boxes do not publish one and are not clipped yet --
-- a drawn ghost can currently paint over a text box, which is an honest known gap rather than a
-- heuristic that hides things it should not. The spawned tier, which is most ghosts, is occluded
-- by the game itself either way.
local function uiPanelOpen()
	return uiSeenAt ~= nil and (drawFrames - uiSeenAt) < UI_LATCH_FRAMES
end

-- IS A TEXT BOX OPEN? Read the background tilemap and look for the box's own corner.
--
-- The decomp settles this: LoadFrame copies the six frame tiles ('┌' to '┘') to `vTiles2 tile
-- '┌'`, which its own comment gives as $79 -- so a text box's top-left corner is tile 121 and the
-- edge beside it is 122, whichever of the nine frame STYLES the player has chosen (the style
-- changes the graphics copied into those ids, not the ids). Measured live the same day: with a
-- box open the tilemap read 121,122 at row 12, and 30,31 (map terrain) with it closed.
--
-- Row 12 because the box is a constant: TEXTBOX_Y = SCREEN_HEIGHT - TEXTBOX_HEIGHT = 18 - 6.
-- One table for the same reason as JOY above. `lo`/`hi` are 0x9800/0x9C00 as VRAM offsets,
-- selected by LCDC bit 3; `corner`/`edge` are the frame tiles LoadFrame copies; `row` is
-- TEXTBOX_Y = SCREEN_HEIGHT - TEXTBOX_HEIGHT = 18 - 6.
local TEXTBOX = { lo = 0x1800, hi = 0x1C00, row = 12, corner = 121, edge = 122 }
-- Whatever `wMenuBorder*` holds at ADAPTER LOAD is refused until it changes, the same way a
-- warp-teardown's leavings are (see the not-inPlay() branch in drawOverflow): a mid-session
-- reload cannot tell a live menu's rectangle from one a Fly left behind earlier in the same session, and trusting
-- it re-creates the hidden-ghost state the snapshot exists to end. If a menu genuinely is open at
-- load, its close writes zero, the slot moves, and everything after is trusted -- self-healing in
-- one menu cycle, in the direction that paints too much rather than hides too much.
TEXTBOX.stale = string.format("%d,%d,%d,%d", u8(MENUBOX.top) or 0, u8(MENUBOX.left) or 0,
	u8(MENUBOX.bottom) or 0, u8(MENUBOX.right) or 0)

local function textBoxOpen()
	local lcdc = memory.read_u8(0xFF40, "System Bus") or 0
	local map = ((lcdc & 0x08) ~= 0) and TEXTBOX.hi or TEXTBOX.lo
	local row = map + TEXTBOX.row * 32
	-- Three cells, not one. Terrain shares this index space, so a single tile matching 121 could
	-- be a hillside; a corner AND its edge AND the far end of the same row being frame tiles is
	-- the box. Cheap, and it cannot be imitated by one unlucky tile.
	local left = memory.read_u8(row, "VRAM") or 0
	local next1 = memory.read_u8(row + 1, "VRAM") or 0
	local right = memory.read_u8(row + 19, "VRAM") or 0
	return left == TEXTBOX.corner and next1 == TEXTBOX.edge
		and right >= TEXTBOX.corner and right <= TEXTBOX.corner + 5
end


-- DIAGNOSTIC, off unless MESHGHOST_CRYSTAL_UI_DEBUG is set. Answers the only question that
-- matters when the user says "a ghost is drawn over a menu" and the counters say peers are being
-- hidden: WHICH peers were painted, WHERE they sat, and what rectangle the adapter thought it was
-- protecting. A count of 21 hidden is compatible with 20 more painted straight over the panel --
-- that is exactly the gap this dump closes, and it is why the count was never enough on its own.
-- An env var cannot be changed without relaunching the emulator, and this has to be switchable
-- during a live session someone is watching -- so a global works too, set by a dev-loader script
-- before or after this file loads. Read once per frame, never per peer.
local UI_DEBUG_ENV = (os.getenv("MESHGHOST_CRYSTAL_UI_DEBUG") or "") ~= ""

-- THE COMPARE RIG'S MEASUREMENTS ARE NOW THEIR OWN SWITCH (2026-08-25). COMPARE_TIERS grew a
-- per-frame instrument surface -- histograms, register audits, an OAM-window scan, per-frame
-- string.format, a ring search -- and the user, mid-comparison: *"can you fix/remove the script
-- lag? makes it hard to tell/compare"*. A diagnostic heavy enough to drop frames desyncs the two
-- tiers it exists to compare (CLAUDE.md's probe rule, met from the cost side). So COMPARE_TIERS
-- alone now means WATCHING -- two copies rendered, the once-a-second summaries -- and the
-- per-frame instruments run only when MESHGHOST_CRYSTAL_COMPARE_STATS is also set (global or
-- environment), which a measuring session sets and a judging session leaves off.
-- On `facingFrames`: the 200-local ceiling, hit for the second time tonight. The environment is
-- read ONCE -- this gate runs several times per frame in the hot paths it exists to lighten, and
-- os.getenv per call would be the probe costing what it saves.
facingFrames.statsEnv = (os.getenv("MESHGHOST_CRYSTAL_COMPARE_STATS") or "") ~= ""
function facingFrames.stats()
	return COMPARE_TIERS
		and (facingFrames.statsEnv or _G.MESHGHOST_CRYSTAL_COMPARE_STATS == true)
end

local lastMenuBox = nil
-- Which object struct the drawn tier is measuring from; held across frames on purpose (see
-- drawOverflow), and cleared when the world is rebuilt.
local anchorIndex = nil

-- THE CAMERA IS SAMPLED EVERY FRAME, ABOVE EVERY EARLY RETURN. (2026-08-23.)
--
-- This used to live inside the per-peer draw loop, below all of `drawOverflow`'s gates (UI open,
-- settle window, transition hold, no peers). `drawFrames` advances at the top of that function,
-- so every gated frame left `camX` stale and the next sample saw SEVERAL frames of scrolling as
-- one delta -- which the plausibility test then rejected as a register rebase and absorbed.
--
-- Measured before moving it: one run had five gaps (one of 14 frames, four over 25) and exactly
-- five rejected 'implausible' camera moves. They are the same five events. The camera never
-- jumped; the adapter was not looking, then read its own blindness as the game doing something
-- and threw away that much real scroll. The drift `K` spent the rest of the run repaying, one
-- visible pixel per frame, was manufactured here -- which is the *jitter right before stopping*.
--
-- A GLOBAL, like `drawOverflow` beside it, because this file sits at 197 of Lua's 200 locals and
-- has hit that ceiling as a bare LOAD FAILED four times. It must also be called BEFORE any early
-- return, which is the entire point of it being its own function.
function meshghostSampleCamera()
	if facingFrames.camFrame ~= drawFrames then
		-- HOW MANY FRAMES SINCE THIS LAST RAN? It should always be 1, and since this
		-- was hoisted out of the per-peer loop it should STAY 1 -- this is the
		-- regression check on that move, not just a diagnosis of the old shape.
		-- It used to sit below every early return `drawOverflow` has (UI open,
		-- settle window, transition hold, no peers), and each skipped frame left
		-- `camX` stale, so the next sample saw several frames of scrolling as ONE delta
		-- -- and a multi-frame delta is exactly what the plausibility test below
		-- rejects as a "rebase" and absorbs. The rejected sizes (16/20/22/24px) are
		-- 8-12 frames of ordinary 2px scrolling, which is the prediction this
		-- histogram tests. If gaps > 1 are common, the camera accumulator is
		-- missing real motion and the drift K repays is manufactured right here.
		if facingFrames.stats() and facingFrames.camFrame then
			local g = drawFrames - facingFrames.camFrame
			if g > 24 then g = 25 end
			facingFrames.camGap = facingFrames.camGap or {}
			facingFrames.camGap[g] = (facingFrames.camGap[g] or 0) + 1
		end
		facingFrames.camFrame = drawFrames
		-- THE CAMERA IS hSCX/hSCY. Measured 2026-08-23, after the source said so.
		--
		-- This read `wPlayerBGMapOffsetX/Y` and called it "the register the screen
		-- is actually scrolled by". It is not, and the audit below priced the
		-- mistake: 30 of 340 frames disagreed with the real scroll, in three shapes
		-- that are each a reported symptom --
		--   * screen moved 2px, offset register said NOTHING (x15): the ghost is
		--     blind to real camera motion and silently falls behind, which is the
		--     drift `K` was being asked to repay;
		--   * offset register moved, screen did NOT (x9): the ghost steps on a
		--     frame the world is still, which is this block's own definition of
		--     on-screen jitter, arriving from the clock itself;
		--   * offset said 24 where the screen moved 22 (x4): large, and rejected as
		--     "implausible" below, so 22px of REAL scroll was absorbed and never
		--     painted -- a visible jump at the moment it happens.
		-- Negated, not re-signed downstream: `ScrollScreen` ADDS the step vector to
		-- hSC where `_HandlePlayerStep` SUBTRACTS it from the offset
		-- (`player_step.asm:29-47`), so `dOff == -dHSC` and negating the source
		-- leaves every sign convention, the plausibility test and `K` untouched.
		-- FROM THE PER-BUILD TABLE, not an inline literal, since 2026-08-26. `UNVERIFIED.md` had
		-- flagged this pair on 2026-08-23 as the one address in the adapter bypassing that table,
		-- and named the consequence exactly: the Archipelago build's values were ASSUMED, HRAM
		-- always reads, so a wrong pair returns a believable scroll value and the `or` fallback
		-- below never fires. It was wrong -- vanilla's $FFCF/$FFD0 are dead bytes there -- and the
		-- symptom was a peer standing still being painted gliding across the ground.
		--
		-- `camDead` is what makes that self-diagnosing rather than something that has to be
		-- noticed by eye on each new build: see ENGINE.camCheck below. Until it has decided, and
		-- forever on a build where the pair is right, this reads the camera as it always did.
		local hcx = not ENGINE.camDead and u8(ENGINE.scxAddr, "System Bus") or nil
		local hcy = not ENGINE.camDead and u8(ENGINE.scyAddr, "System Bus") or nil
		ENGINE.camCheck(hcx, hcy)
		local scx = hcx and ((256 - hcx) % 256) or (u8(W_BGMAPOFFSETX) or 0)
		local scy = hcy and ((256 - hcy) % 256) or (u8(W_BGMAPOFFSETY) or 0)
		-- WAS THIS REGISTER EVER THE CAMERA? Read from `pret/pokecrystal`, not
		-- guessed (2026-08-23):
		--   * `wPlayerBGMapOffsetX/Y` ($d14c/$d14d) is commented in `ram/wram.asm`
		--     as "used in FollowNotExact; unit is pixels". `ApplyBGMapAnchorToObjects`
		--     (`engine/overworld/map_objects.asm:2768`), called from `_UpdateSprites`
		--     EVERY FRAME, reads it, adds it to every object's sprite X/Y, and then
		--     ZEROES IT (`:2800`). It is a per-frame delta the engine consumes and
		--     resets -- NOT an absolute scroll position.
		--   * The screen is actually scrolled by `hSCX`/`hSCY` ($ffcf/$ffd0, from
		--     `pokecrystal.sym`), updated by `ScrollScreen`
		--     (`engine/overworld/player_step.asm:37`) from the same
		--     `wPlayerStepVector`, but ADDING where the offset above SUBTRACTS
		--     (`:29-34`) -- which is where the "both registers run inverted" reading
		--     came from.
		-- So this block's claim that it integrates "the register the screen is
		-- actually scrolled by -- it cannot disagree with what the player sees" is
		-- FALSE as written. This measures the size of that lie before anything is
		-- changed: if the two mirror each other, every frame has dOff == -dH.
		if facingFrames.stats() then
			local hx, hy = hcx, hcy
			-- The OLD source, read explicitly. Using `scx`/`scy` here would compare
			-- hSC against itself now that they come from it, and report a perfect
			-- score forever -- a check that cannot fail is not a check.
			local ox = u8(W_BGMAPOFFSETX) or 0
			local oy = u8(W_BGMAPOFFSETY) or 0
			if hx and hy then
				if facingFrames.hX then
					local dhx = ((hx - facingFrames.hX + 128) % 256) - 128
					local dhy = ((hy - facingFrames.hY + 128) % 256) - 128
					local dox = ((ox - (facingFrames.hOX or ox) + 128) % 256) - 128
					local doy = ((oy - (facingFrames.hOY or oy) + 128) % 256) - 128
					facingFrames.hN = (facingFrames.hN or 0) + 1
					if dox == -dhx and doy == -dhy then
						facingFrames.hAgree = (facingFrames.hAgree or 0) + 1
					else
						facingFrames.hDis = (facingFrames.hDis or 0) + 1
						local k = string.format("off %+d,%+d vs hSC %+d,%+d",
							dox, doy, dhx, dhy)
						facingFrames.hD = facingFrames.hD or {}
						facingFrames.hD[k] = (facingFrames.hD[k] or 0) + 1
					end
				end
				facingFrames.hX, facingFrames.hY = hx, hy
				facingFrames.hOX, facingFrames.hOY = ox, oy
			else
				facingFrames.hNoRead = (facingFrames.hNoRead or 0) + 1
			end
		end
		if facingFrames.camX ~= nil
			and (scx ~= facingFrames.camX or scy ~= facingFrames.camY) then
			-- ONLY A PLAUSIBLE SCROLL IS MOTION. A real camera frame moves 2 or 4px
			-- on ONE axis; the event probe caught 8px DIAGONAL register jumps on the
			-- first frame of each walk (`cam=8`, dsx and dsy together), and painting
			-- those as motion was the 1-tile snap-back the user saw at every walk
			-- start once everything else was clean. An implausible delta is the
			-- register being REBASED (or read mid-update): it is absorbed into the
			-- accumulator AND the calibration constant in the same frame, so the
			-- painted position provably cannot move because of it.
			local pdx = ((scx - facingFrames.camX + 128) % 256) - 128
			local pdy = ((scy - facingFrames.camY + 128) % 256) - 128
			local pcd = math.abs(pdx) + math.abs(pdy)
			-- EVERY DELTA, BEFORE THE TEST THAT MIGHT REJECT IT. The histogram used to sit in the
			-- accepted branch, so it could only ever report deltas that passed -- and then said
			-- "no 8px deltas at turbo" when 8px deltas being thrown away was the entire fault.
			-- `probes.md`, for the third time in one session: dump everything, filter afterwards.
			facingFrames.camHist = facingFrames.camHist or {}
			facingFrames.camHist[pcd] = (facingFrames.camHist[pcd] or 0) + 1

			-- THE GAITS THIS CARTRIDGE HAS, not the two vanilla happens to have.
			--
			-- This read `pcd == 2 or pcd == 4` -- the walk and the bike -- and anything else was
			-- treated as a register rebase and ABSORBED: camMoved false, camDelta zero, the motion
			-- folded into camA. That is right for a real rebase (a map load moves the registers
			-- with no walking behind it) and catastrophic for a real 8px scroll, because the screen
			-- moves and the painted ghost does not. On the Archipelago build's fourth gait that is
			-- every fast frame, which is exactly the glide and snap the user has been reporting:
			-- *"it looks fine when walking, running and biking but looks snap/glide with turbo
			-- bike"*. Walking is 2 and both running and the ordinary bike are 4 -- the two values
			-- this test already knew -- so the discriminator points straight at the missing one.
			--
			-- ENGINE.gaits is measured off the cartridge's own StepVectors at load, so this accepts
			-- exactly the strides the engine can actually produce here and nothing more: three
			-- groups means 1, 2 and 4, four means 8 as well. A build with a fifth gait would widen
			-- it without this line changing.
			local ok = false
			for g = 0, (ENGINE.gaits or 3) - 1 do
				if pcd == GAIT_PX[g] then
					ok = true
				end
			end
			local plausible = ok and (pdx == 0 or pdy == 0)
			if not plausible then
				facingFrames.camAX = (facingFrames.camAX or 0) + pdx
				facingFrames.camAY = (facingFrames.camAY or 0) + pdy
				if facingFrames.camKX then
					-- MINUS, not plus. The paint is `model + camA + K` on BOTH axes, so a
					-- rebase absorbed into camA is cancelled only by the OPPOSITE change in
					-- K. Y already did that; X ADDED, so every X rebase moved the painted
					-- ghost by twice the rebase instead of leaving it still -- the one thing
					-- "absorbed invisibly" is supposed to mean. Found 2026-08-23 by algebra,
					-- not by a probe: the two axes disagreed in a way no convention justifies.
					facingFrames.camKX = facingFrames.camKX - pdx
					facingFrames.camKY = facingFrames.camKY - pdy
				end
				facingFrames.camMoved = false
				facingFrames.camDelta = 0
				facingFrames.camStillFor = (facingFrames.camStillFor or 99) + 1
				facingFrames.camX, facingFrames.camY = scx, scy
				if COMPARE_TIERS then
					facingFrames.camRebase = (facingFrames.camRebase or 0) + 1
					-- WHAT the rejected moves actually are, not just how many.
					-- Runs keep showing roughly ONE rebase per park -- 8 against 7
					-- parks, 19 against 19 -- which is too regular to be the
					-- occasional register rebase this branch was written for. If
					-- these are REAL camera motion at every stop, absorbing them
					-- means the screen moved and the painted ghost did not, which
					-- is a jitter at exactly the moment the user reports one.
					-- The deltas name them; a repeated pair is a mechanism.
					local key = string.format("%+d,%+d", pdx, pdy)
					facingFrames.camRebaseD = facingFrames.camRebaseD or {}
					facingFrames.camRebaseD[key] =
						(facingFrames.camRebaseD[key] or 0) + 1
				end
			else
			facingFrames.camMoved, facingFrames.camStillFor = true, 0
			-- HOW FAR the camera moved this frame, not just whether. The scroll
			-- registers are u8 and wrap at 256, so the delta is taken the short
			-- way round. After the +-/boundary fixes the residue was ONE 2px slip
			-- per tile, metronomic -- the signature of the camera doing something
			-- once per tile that a fixed 2px hop cannot match. Measured below and
			-- histogrammed on the MODEL line; the hop mirrors it, clamped to the
			-- engine's own gaits (2px walk, 4px bike).
			local dxw = ((scx - facingFrames.camX + 128) % 256) - 128
			local dyw = ((scy - facingFrames.camY + 128) % 256) - 128
			-- The camera's ACCUMULATED world position, wrap-unrolled. This is the
			-- screen's true origin, integrated from the register the screen is
			-- actually scrolled by -- it cannot disagree with what the player
			-- sees, which no quantity derived from tile+progress can promise.
			facingFrames.camAX = (facingFrames.camAX or 0) + dxw
			facingFrames.camAY = (facingFrames.camAY or 0) + dyw
			-- THE SIGN CONVENTION, measured instead of assumed -- the assumption
			-- just sent every ghost off the screen. Each camera move is recorded
			-- against the direction the player was actually walking; one lap of
			-- the square yields the full map (which register, which sign, per
			-- direction), and the camera-frame paint can then be rebuilt on data.
			if facingFrames.stats() then
				local np = playerHistory[(playerHistory.n % playerHistory.size) + 1]
				local pdir = (np and np.dir) or 9
				facingFrames.camSign = facingFrames.camSign or {}
				local key = string.format("%s:%+d,%+d",
					DIR_NAMES.letter[pdir] or "?", dxw, dyw)
				facingFrames.camSign[key] = (facingFrames.camSign[key] or 0) + 1
			end
			local cd = math.abs(dxw) + math.abs(dyw)
			-- EVERY CAMERA DELTA, BINNED, always on. The engine scrolls in whole gait strides and
			-- never an odd pixel (`documentation.md`), so this histogram is the shape of the
			-- world's own motion as this adapter sees it -- and if the adapter's view of the camera
			-- is out of phase with the PPU, this is where it shows: a turbo ride should read almost
			-- entirely 0 and 8, alternating, because the object clock runs at half the video rate.
			-- Anything reading 4 during a turbo ride means the sample is landing mid-scroll, and a
			-- half-stride error at 8px is a quarter tile every frame.
			--
			-- Free: one table index per frame, printed once a second, and it is the measurement the
			-- residual glide is waiting on -- the model has already been acquitted by its own
			-- counters (0px behind, 0 catch-up, 0 resyncs across a full turbo ride).
			if cd > 8 then cd = 8 end
			facingFrames.camDelta = cd
			if facingFrames.stats() then
				facingFrames.camD = facingFrames.camD or {}
				facingFrames.camD[cd] = (facingFrames.camD[cd] or 0) + 1
			end
			end
		else
			facingFrames.camMoved = false
			facingFrames.camDelta = 0
			facingFrames.camStillFor = (facingFrames.camStillFor or 99) + 1
		end
		facingFrames.camX, facingFrames.camY = scx, scy
	end
end

function drawOverflow()
	drawFrames = drawFrames + 1
	-- BEFORE EVERY GATE BELOW, for the same reason the camera sampler is: a frame where the game
	-- reloaded sprite graphics and this did not run is a frame painted from tiles that no longer
	-- exist, and the tier has early returns.
	invalidateTileCache()
	-- BEFORE EVERY GATE BELOW. The camera accumulator must not miss a frame; see the note on
	-- meshghostSampleCamera above for what missing them cost.
	meshghostSampleCamera()
	-- COMPARE_TIERS keeps this running even with the tier switched off: the comparison ghost is
	-- the only thing `overflow` holds in that configuration, and looking at it is the point.
	-- CLEAR BEFORE EVERY EARLY RETURN.
	--
	-- BizHawk's drawing layer PERSISTS until something replaces or clears it, so a frame in which
	-- this tier draws nothing leaves the previous frame's painted peers on screen -- frozen, and
	-- looking exactly like a ghost that is being drawn when it should not be. The user, 2026-08-21:
	-- the painted ghost stays visible through both halves of a door transition, which is precisely
	-- the window where every gate here returns early and nothing repaints.
	--
	-- So the tier stops by CLEARING rather than by falling silent. Cheap, and it makes "draw
	-- nothing" mean nothing on screen instead of whatever was there last.
	-- WHY it stopped, not just that it did. Six different early returns share this one function and
	-- the stats line reported none of them -- so "1 peer waiting, 0 drawn" named a symptom with no
	-- way to tell a text box from a stale history gate. Counted per reason and printed with the
	-- tier totals; a counter that cannot say why is what turned this into several wrong guesses.
	local function stopDrawing(why)
		if why then
			facingFrames.stopWhy = facingFrames.stopWhy or {}
			facingFrames.stopWhy[why] = (facingFrames.stopWhy[why] or 0) + 1
			-- The reason for THIS frame, so the per-frame trace can attribute a blank frame to a
			-- cause instead of leaving a cumulative total to be guessed at.
			facingFrames.stopLast, facingFrames.stopLastAt = why, policyFrames
		end
		pcall(function() gui.clearGraphics() end)
	end

	-- TICK THE HOLD BEFORE ANY EARLY RETURN, so it overlaps the crossing instead of following it.
	--
	-- MEASURED, not reasoned (probes/paintgate_probe.lua, 14 crossings, zero variance): the hold
	-- is armed when the map id changes, which happens PART-WAY through a crossing while the world
	-- is still being rebuilt -- and the counter used to be decremented BELOW the inPlay() check,
	-- which is false for that whole stretch (33 frames going in, 37 coming out). So none of the 30
	-- frames were spent during the crossing. The two windows ran end to end, and the tier stayed
	-- blank for ~65 frames to serve a 30-frame hold. The user, 2026-08-22: *"the drawn ghost takes
	-- a while to become visible again"*.
	--
	-- Ticking it here spends the hold DURING the rebuild, so what is left when the game is ready
	-- is the only delay anyone sees: measured at 5 frames going in and 2 coming out, against 30
	-- and 30 before. The 30 is deliberately unchanged -- this was an ordering fault, and tuning
	-- the constant would have hidden it rather than fixed it.
	-- TICK THE HOLD BEFORE ANY EARLY RETURN, so it overlaps the crossing instead of following it.
	--
	-- MEASURED, not reasoned (probes/paintgate_probe.lua, 14 crossings, zero variance): the hold is
	-- armed when the map id changes, which happens PART-WAY through a crossing while the world is
	-- still being rebuilt -- and the counter used to be decremented BELOW the inPlay() check, which
	-- is false for that whole stretch (33 frames going in, 37 coming out). So none of the 30 frames
	-- were spent during the crossing: the two windows ran end to end and the tier stayed blank for
	-- ~65 frames to serve a 30-frame hold. The user, 2026-08-22: *"the drawn ghost takes a while to
	-- become visible again"*.
	--
	-- Ticking it here spends the hold DURING the rebuild, so what is left when the game is ready is
	-- the only delay anyone sees: 5 frames going in and 2 coming out. The 30 is deliberately
	-- unchanged -- this was an ordering fault, and tuning the constant would have hidden it.
	--
	-- HISTORY NOTE, because this was reverted once and the revert was wrong. It shipped alongside a
	-- FIRST attempt at the stale-reference fix that CLEARED the player history ring, and that
	-- combination wiggled; the wiggle belonged to the clearing (an empty ring makes the aged lookup
	-- fall through to this frame's own sample -- a wrong reference, not a missing one). With the
	-- readiness gate below in its place, the user tested this and reported *"no wiggle"*. The
	-- regression named in that same message was the drawn tier's FACING, which is a separate,
	-- pre-existing fault that re-rolls on every reload. Attributing it here cost a revert.
	-- ...EXCEPT ACROSS A SEAM, WHICH HAS NO FADE TO PAINT OVER.
	--
	-- The window above is armed by the map-LOAD byte and re-armed every frame that byte is
	-- stamped, so it runs 30 frames past the end of the load. Walking a route seam is a map load,
	-- and walking back and forth across one re-arms it before it can ever expire -- so the painted
	-- tier is held off indefinitely and the peer is simply never drawn. Measured 2026-08-27 on the
	-- user's own repro: `settling` was the reason 577 frames went unpainted in one shuttle run,
	-- more than every other cause combined, and the user saw it as *"stays invisible if constantly
	-- going left/right across the seam"*.
	--
	-- Both of the window's jobs are warp jobs. A warp fades the screen and this stops the tier
	-- painting over the fade; walking across a connection does not fade at all. The other job --
	-- not reading a tile base while wUsedSprites is being repopulated -- is already done per peer
	-- and per frame by the sprite-tile check downstream, which declines that peer specifically
	-- instead of blanking the tier.
	-- ...EXCEPT ACROSS A SEAM, WHICH HAS NO FADE TO PAINT OVER.
	--
	-- This window is armed by the map-LOAD byte and re-armed every frame that byte is stamped, so
	-- it runs 30 frames past the end of the load. Walking a route seam is a map load, and walking
	-- back and forth across one re-arms it before it can expire -- so the painted tier is held off
	-- indefinitely and the peer is never drawn at all. Measured 2026-08-27 on the user's repro:
	-- `settling` accounted for 577 unpainted frames in one shuttle run, more than every other
	-- cause combined.
	--
	-- Both of the window's jobs are warp jobs. A warp fades the screen and this stops the tier
	-- painting over the fade; walking across a connection does not fade at all. The other job --
	-- not reading a tile base while wUsedSprites is repopulates -- is already done per peer by the
	-- sprite-tile check downstream, which declines that peer specifically instead of blanking the
	-- whole tier.
	--
	-- SUSPECTED ONCE OF CAUSING A GLITCHY SPRITE AND CLEARED BY BISECT, 2026-08-27. The window's
	-- own arming comment predicts exactly that symptom, which made this the obvious culprit -- but
	-- reverting the whole feature to c0c6cf2 left the glitchy sprite still on screen, so it is
	-- PRE-EXISTING and nothing to do with cross-map ghosts. Recorded because the prediction is
	-- convincing and will make this the first suspect again next time.
	local seamRecently = ENGINE.xmap.seamAt
		and (policyFrames - ENGINE.xmap.seamAt) < 60
	-- DRAINED, NOT MERELY BYPASSED. The first version of this bypass only held `settling` false,
	-- and the counter below decrements ONLY while settling is true -- so the 30 frames froze
	-- instead of being spent, and fired in full the moment the seam window expired. Measured
	-- 2026-08-27: twenty-eight separate vanishes of exactly 30 frames each, all tagged `settling`,
	-- starting exactly 60 frames after a crossing. The user: *"its still going away sometimes a
	-- bit afterwards"* -- the window had been deferred, not removed. Zeroing is safe because the
	-- arming site is untouched: a real warp inside the seam window still re-arms 30 fresh frames.
	if seamRecently and playerHistory.settle > 0 then
		playerHistory.settle = 0
	end
	local settling = playerHistory.settle > 0
	if settling then
		playerHistory.settle = playerHistory.settle - 1
	end

	if not inPlay() then
		-- THE OVERWORLD IS BEING TORN DOWN (a warp, a battle, a connection loss), and NO MENU
		-- RECTANGLE SURVIVES THAT. This is where the stale-rectangle clear had to live, and the
		-- first placement -- the area-change block -- was wrong in exactly the reported case:
		-- flying to the town you are ALREADY in keeps the same area id, so the clear never fired,
		-- and the rectangle Fly's menu left behind went on hiding painted peers (the user,
		-- 2026-08-26, after that fix shipped: *"the spawned ghost was still invisible while using
		-- fly"*). wMapStatus leaves HANDLE across every warp, same-map ones included -- the
		-- 2026-08-23 transition_probe measurement below -- so this branch runs for all of them,
		-- while an overlaid menu or text box never brings the status here at all.
		uiSeenAt, lastMenuBox = nil, nil
		-- AND REMEMBER WHAT THE TEARDOWN LEFT IN THE SLOT, because clearing our latch alone is
		-- useless: the game never zeroes `wMenuBorder*` after a warp-teardown, so the level test
		-- re-reads the same stale coordinates one frame after landing and re-latches. Measured on
		-- the user's own re-test (2026-08-26, the SECOND failed fix for this symptom): after the
		-- fly, every debug line showed the fly menu's `0,10,17,19` frozen in the slot with nothing
		-- on screen. So the latch site refuses exactly this value until the slot CHANGES -- a real
		-- menu always changes it (a different rectangle, or the zero a normal close writes). While
		-- a battle keeps this branch live the snapshot tracks the battle UI's own writes, so the
		-- value held at the return to the overworld is whatever the battle left, which is equally
		-- stale and equally refused. On TEXTBOX to spare a top-level local (three names from the
		-- ceiling).
		TEXTBOX.stale = string.format("%d,%d,%d,%d", u8(MENUBOX.top) or 0,
			u8(MENUBOX.left) or 0, u8(MENUBOX.bottom) or 0, u8(MENUBOX.right) or 0)
		-- ...UNLESS THE WORLD WAS JUST REBUILT BY A SEAM CROSSING. `wMenuBorder*` is not
		-- meaningful for a few frames after a map load -- the game does not zero it and has not
		-- yet written it -- so this live read sees a rectangle that is stale by definition. That
		-- is the same fact the teardown branch above already acts on; it was applied to our cached
		-- latch and never to the live test.
		--
		-- Measured 2026-08-27 with the per-frame trace: exactly six frames blocked by `textbox`
		-- immediately after every seam crossing, and drawing resuming on the seventh. The user:
		-- *"its still going invisible when going between the routes"*. A real text box cannot open
		-- during a seam crossing -- you are walking -- so ignoring it briefly costs nothing, and
		-- the window is short enough that a genuine box opened right after arriving still gates
		-- the tier.
		--
		-- MIS-LABELLED AS "textbox" WHEN THIS COUNTER WAS FIRST ADDED, which cost a wrong reading:
		-- this branch is `not inPlay()`, the overworld being torn down or rebuilt, and a text box
		-- is only one of the things that reaches it. The tag says what the branch IS.
		--
		-- A 20-frame bypass was tried here on 2026-08-27 and REVERTED the same day. The theory was
		-- that the menu bytes are stale for a few frames after a map load; the user then said what
		-- the screen actually shows -- Crystal draws the ROUTE/TOWN NAME banner on every crossing,
		-- so this is a real text box and refusing to paint is correct. Bypassing it would paint
		-- the ghost ON TOP of that banner, because a painted peer is drawn after the PPU and only
		-- a spawned one is hidden by the engine for free. It also did not fix the symptom. Left
		-- here as a dated negative result so the same theory is not re-derived: the banner needs
		-- CLIPPING (the panel-rectangle path drawOverflow already has), never a bypass.
		--
		-- ...UNLESS WE JUST WALKED ACROSS A SEAM. `inPlay()` goes false for exactly SIX frames
		-- while the connection strip loads, but a seam crossing is not a teardown: the player
		-- keeps walking, the screen never fades, and the world on either side is continuous.
		-- Blanking the painted tier there is the crossing flicker.
		--
		-- TWO EARLIER VERSIONS OF THIS BYPASS FAILED, and the difference is worth keeping:
		--   1. First try was blamed for a glitchy sprite and reverted -- wrongly, the glitch was
		--      facingFrames.derive keeping a mirror it should have dropped (80316b2), reproduced
		--      on c0c6cf2 with none of this applied.
		--   2. Second try genuinely failed: it removed the six `not-in-play` frames and the trace
		--      showed the SAME six frames blocked as `off screen` instead. The position pipeline
		--      needed a standing anchor, the player is mid-step by definition while crossing, and
		--      the fallback read the window origin and scroll registers mid-rebuild.
		-- The bypass is only safe PAIRED with the corrected walking-player anchor in the anchor
		-- block below, which keeps a valid position reference through exactly these frames. If
		-- that anchor is ever removed, this must go back to an unconditional stop.
		if not (ENGINE.xmap.seamAt and (policyFrames - ENGINE.xmap.seamAt) < 15) then
			stopDrawing("not-in-play")
			return
		end
	end
	if not DRAW_OVERFLOW and not COMPARE_TIERS then
		stopDrawing("menu")
		return
	end
	-- THE POSITIVE GATE: characters may only be painted while the game itself is running its
	-- overworld sprite engine. Every full-screen UI -- the party menu, the fly map, the PC --
	-- calls DisableSpriteUpdates on the way in, so this one byte covers the entire family the
	-- deny-list approach kept losing to, stale rectangles included. See W_SPRITEUPDATESON in the
	-- address table for the measurement.
	if ENGINE.sprOn and (u8(ENGINE.sprOn) or 0) == 0 then
		stopDrawing("sprites-off")
		return
	end

	-- LET A REBUILT WORLD SETTLE BEFORE PAINTING ON IT.
	--
	-- The user, 2026-08-21: the painted ghost shows while walking in and out of a house. The
	-- positive gate pitfalls.md asks for does not catch it, and transition_probe.lua says why:
	-- across a door crossing wMapStatus drops to ENTER and comes back to HANDLE the moment the new
	-- map is entered, while the screen is still fading in -- and Crystal never touches the OBJ
	-- palette shadow during that fade (objBrightness read a flat 99 through every crossing), so
	-- there is no lighting signal to match the way Emerald's painted tier matches one.
	--
	-- What IS reliable is that the world was just rebuilt. `lastArea` already changes on exactly
	-- that event, so the tier holds off for a moment afterwards. This is not a deny-list of screens
	-- -- it is the same "the world is being rebuilt" fact the spawned tier already acts on, applied
	-- to the tier that paints outside the engine and therefore cannot be hidden by it.
	if settling then
		stopDrawing("settling")
		return
	end
	learnFacingFromPlayer()
	local uiOpen = uiPanelOpen()
	local boxOpen = textBoxOpen()
	local t, l, b, r = u8(MENUBOX.top), u8(MENUBOX.left), u8(MENUBOX.bottom), u8(MENUBOX.right)
	-- MEASURED 2026-08-26, twice, and both measurements are load-bearing:
	--
	-- * The coordinates are non-zero while a menu is up and zeroed when it closes NORMALLY
	--   (`probes/menu_state_table.lua`: set at frame 9 of the open, cleared at frame 9 of the
	--   close). A menu torn down by a warp instead -- Fly -- skips the clear; that case is
	--   handled at the not-inPlay() branch above, because wMapStatus leaves HANDLE on every warp.
	-- * `wMenuBorder*` IS ONE SHARED SCRATCH SLOT: it describes the most recent box DRAWN, not
	--   the union of what is on screen. Caught live: the party menu publishes a full-screen
	--   0,0,17,19 -- and choosing Surf where it cannot be used draws a "can't use that here" text
	--   box whose 12,0,17,19 REPLACES it. A single remembered rectangle then protects the bottom
	--   six rows of a screen that is entirely menu, and the ghost was painted at y=4 over the
	--   party list (the user: *"a weird sprite showed up in my pokemon inventory"*), persisting
	--   because nothing ever re-publishes the covered menu's rectangle.
	--
	-- So `lastMenuBox` is a LIST: every distinct rectangle published while the latch is alive
	-- stays in it, and a peer inside ANY of them is hidden. Stacked UI is the normal case, not the
	-- edge case. The list dies with the latch, exactly as the single rectangle did -- over-hiding
	-- for the latch's 20 frames after everything closes is invisible; under-hiding is the fault
	-- this line of fixes keeps paying for. Capped defensively; the screen is 20x18 tiles and a
	-- session that publishes more distinct rectangles than the cap is already somewhere strange.
	-- THE STALE VALUE A TEARDOWN LEFT BEHIND IS REFUSED UNTIL THE SLOT MOVES. See the snapshot at
	-- the not-inPlay() branch: after a warp the game leaves the last menu's coordinates in the
	-- slot forever, and a latch cleared during the warp simply refills from them on landing.
	local rectKey = string.format("%d,%d,%d,%d", t or 0, l or 0, b or 0, r or 0)
	if TEXTBOX.stale and rectKey ~= TEXTBOX.stale then
		TEXTBOX.stale = nil -- the slot changed: whatever it says now is the game speaking, trust it
	end
	if (b or 0) > 0 and (r or 0) > 0 and not TEXTBOX.stale then
		local top, left, bottom, right = t * 8, l * 8, (b + 1) * 8, (r + 1) * 8
		lastMenuBox = lastMenuBox or {}
		local known = false
		for _, box in ipairs(lastMenuBox) do
			if box.top == top and box.left == left and box.bottom == bottom
				and box.right == right then
				known = true
				break
			end
		end
		if not known and #lastMenuBox < 8 then
			lastMenuBox[#lastMenuBox + 1] =
				{ top = top, left = left, bottom = bottom, right = right }
		end
		uiSeenAt = drawFrames -- the rectangle strobes to zero as the menu redraws; latch it
	elseif not uiOpen then
		lastMenuBox = nil -- no panel is up, so every remembered rectangle is stale
	end

	local nWanted, nDrawn, nNoTile, nOffScreen, nHidden, nFromRom = 0, 0, 0, 0, 0, 0
	local nOam = 0
	oam.beginFrame()
	-- Animation and facing are the two things a drawn peer has to do for itself, and a
	-- screenshot cannot settle either: one frame cannot see a walk cycle, and a peer that is
	-- merely facing the wrong way still looks like a character. So they are counted instead --
	-- how many drawn peers were rendered on a WALK frame this frame, and how many had a facing
	-- at all. `nNoFacing` is the one that matters: it counts peers rendered from the sprite's
	-- raw first frame because nothing has been learned for that facing yet, which is the state
	-- that looks exactly like broken animation.
	-- `nWalking` was here, per-frame, and is gone: a per-frame count printed once a second is a
	-- sample of the log's own timing. The stepping count is cumulative, on `facingFrames`.
	local nNoFacing = 0
	local UI_DEBUG = UI_DEBUG_ENV or _G.MESHGHOST_CRYSTAL_UI_DEBUG == true
	local paintedSamples = {}
	local offSample = nil

	-- IS THE OVERWORLD ON SCREEN AT ALL? If it is not, paint nothing.
	--
	-- A POSITIVE test, deliberately, rather than a deny-list. Two user reports on 2026-08-19 --
	-- ghosts over a full-screen MENU, ghosts inside a BATTLE -- are one defect: the drawn tier
	-- paints after the frame with none of the engine's context, so everything not explicitly
	-- excluded gets painted over. A list of screens to avoid (battle, menu, evolution, naming,
	-- Pokedex, cutscene, title) will never be finished, and every entry missing from it is a bug
	-- someone has to see first. Asking instead "is the overworld what is on screen" is one
	-- question with one answer.
	--
	-- A FULL-SCREEN menu (POKeMON, BAG, the PokeGear) publishes no wMenuBorder* rectangle, so
	-- there is nothing to clip against -- and it happens to trip textBoxOpen(), so the adapter
	-- protected only the bottom six rows and painted ghosts over the whole top two-thirds of the
	-- menu. Reported by the user 2026-08-19: "the ghost is being drawn while in the menu's",
	-- against counters that said peers were being hidden. Both were true; see pitfalls.md.
	--
	-- The test is the engine's own output rather than another guess at game state, and it follows
	-- from what this tier IS: the drawn tier paints ALONGSIDE the characters the engine renders.
	-- If the engine is rendering no characters at all, there is nothing to paint alongside, the
	-- anchor this code calibrates against does not exist either, and the honest answer is to draw
	-- nothing. Measured 2026-08-19 across a full sweep: overworld 28-34 live sprite entries, the
	-- START menu 28-30 (map still behind it, ghosts correctly clipped by its rectangle), a text
	-- box 30+ (map still there) -- and a full-screen submenu exactly 0.
	--
	-- Deliberately NOT a state flag: wStateFlags bit 0 was tried first and strobes between 01,
	-- 40 and 41 within a single state, the same way the WY-alone heuristic did.
	local liveSprites, playerSpriteEntries = 0, 0
	for i = 0, 39 do
		local y = memory.read_u8(i * 4, "OAM") or 0
		if y > 0 and y < 160 then
			liveSprites = liveSprites + 1
			if i < 4 then
				playerSpriteEntries = playerSpriteEntries + 1
			end
		end
	end
	-- The second term is the stronger one, and it is not a new assumption: this tier ALREADY
	-- treats OAM entries 0-3 as the local player's four sprites -- that is what the anchor
	-- calibration below measures its screen positions against. So "is the engine drawing this
	-- player's character right now" is answerable from the same four bytes, and if it is not, the
	-- calibration has nothing valid to work from either. It catches what a state flag misses: the
	-- ENCOUNTER TRANSITION, where the overworld is already gone but wBattleMode is still 0 (the
	-- Archipelago agent measured wMapStatus never leaving 2 through an entire battle on that
	-- build, so wBattleMode is the only battle term there and this is its gap).
	if liveSprites == 0 or playerSpriteEntries == 0 then
		stopDrawing("no-live-sprites")
		return
	end

	-- ANCHOR ON A CHARACTER THAT IS STANDING STILL, and measure everything else from it in TILES.
	--
	-- No scroll arithmetic at all: a reference object's OAM entry is its true position in screen
	-- pixels, and a peer N tiles away is N*16 pixels away. That is exact whatever the camera is
	-- doing, which is the point -- the previous version worked in the engine's own scrolled space
	-- and was only correct at the instants the engine recomputes it. In between, the hardware
	-- scrolls and the drawn peers did not follow: measured as 64 discontinuities of 8 and 16 px
	-- in a 20-second walk, and reported by the user as ghosts snapping around while moving.
	--
	-- STANDING is what makes a reference usable. A character mid-step has already had its MAP_X/Y
	-- written to the tile it is walking TO (that is how this engine initiates a step), while its
	-- sprite is still up to a whole tile behind -- so anchoring on a walking character, the player
	-- included, is wrong by exactly the 16 px seen above.
	-- STICK TO ONE ANCHOR. Choosing the first standing character each frame looks harmless and is
	-- not: characters differ by a few pixels in how their sprite sits relative to their tile (an
	-- idle animation, a different sprite shape), so switching anchor moves every drawn peer by
	-- that difference. Measured: the first version cut the jumps from 64 to 39 and the survivors
	-- were all exactly +/-8 px horizontally -- the adapter alternating between two anchors.
	--
	-- So: keep last frame's anchor while it is still standing and still on this map; only choose
	-- again when it is not, and prefer the player, whose sprite-to-tile relationship is the one
	-- everything else is calibrated against anyway.
	local function usable(i)
		local base = OBJECT_STRUCTS + i * OBJECT_LENGTH
		return (u8(base + F_SPRITE) or 0) ~= 0
			and (u8(base + F_WALKING) or STANDING) == STANDING
	end

	if not (anchorIndex and usable(anchorIndex)) then
		anchorIndex = nil
		if usable(0) then
			anchorIndex = 0
		else
			for i = 1, NUM_OBJECT_STRUCTS - 1 do
				if usable(i) then
					anchorIndex = i
					break
				end
			end
		end
	end

	local anchorTileX, anchorTileY, anchorPx, anchorPy = nil, nil, nil, nil
	if anchorIndex then
		local base = OBJECT_STRUCTS + anchorIndex * OBJECT_LENGTH
		anchorTileX, anchorTileY = u8(base + F_MAP_X), u8(base + F_MAP_Y)
		anchorPx, anchorPy = u8(base + F_SPRITE_X) or 0, u8(base + F_SPRITE_Y) or 0
	elseif (u8(OBJECT_STRUCTS + F_SPRITE) or 0) ~= 0 then
		-- NOBODY IS STANDING: anchor on the WALKING PLAYER, with the mid-step error corrected
		-- rather than accepted.
		--
		-- The standing requirement exists because MAP_X/Y is written at the START of a step and
		-- names the DESTINATION while the sprite is still up to 16px behind -- so a walking anchor
		-- pairs a tile with a sprite position that does not belong to it yet. But that error is
		-- not unknowable: it is `16 - stepProgress` back along the walk, which is EXACTLY the
		-- correction getLocalState applies to our own outgoing pixel position every frame. Pairing
		-- F_SPRITE_X/Y minus that vector with MAP_X/Y makes the walking player as exact an anchor
		-- as a standing one.
		--
		-- Why this exists (2026-08-27): crossing a route seam. The player is mid-step by
		-- definition while crossing, so no anchor qualified, and the old fallback below computed
		-- the position from the window origin and scroll registers -- which are mid-rebuild for
		-- the handful of frames of the map switch, so every peer read as "off screen" and the
		-- ghost blinked out. Measured: bypassing the not-in-play gate alone just moved the six
		-- blocked frames from `not-in-play` to `off screen`; the missing piece was a position
		-- reference that stays valid mid-step and mid-load, which the player's own struct is.
		--
		-- Deliberately NOT stored in anchorIndex: the sticky-anchor rule keeps preferring a
		-- standing character next frame, and a derived anchor must never be mistaken for one.
		local base = OBJECT_STRUCTS
		anchorTileX, anchorTileY = u8(base + F_MAP_X), u8(base + F_MAP_Y)
		anchorPx, anchorPy = u8(base + F_SPRITE_X) or 0, u8(base + F_SPRITE_Y) or 0
		if (u8(base + F_WALKING) or STANDING) ~= STANDING then
			-- The same per-direction arithmetic as the send side, applied in reverse: the sprite
			-- is `back` short of the destination tile, so the pixel that PAIRS with MAP_X/Y is
			-- the sprite position minus that shortfall.
			local back = stepProgress(base) - 16
			local d = ((u8(base + F_DIRECTION) or 0) // 4) & 3
			if d == 0 then anchorPy = anchorPy - back
			elseif d == 1 then anchorPy = anchorPy + back
			elseif d == 2 then anchorPx = anchorPx + back
			else anchorPx = anchorPx - back end
		end
	end
	-- The engine's sprite space and the screen differ by a constant this frame; the player's own
	-- OAM entry gives it, and it is valid whether or not the PLAYER is the anchor.
	-- THE CORNER, not entry 0. A character occupies four OAM entries in a 2x2, and which one the
	-- engine writes first is not stable -- it swaps with facing, because a flipped sprite is
	-- emitted in the mirrored order. Reading entry 0 therefore gives an x that alternates by 8 px
	-- as the player turns, and every drawn peer inherited that: measured as 37 jumps of exactly
	-- +/-8 px in a 20-second walk, which survived two other fixes because neither was the cause.
	-- The minimum across the four is the character's top-left corner, which does not care about
	-- ordering or flips.
	--
	-- AND THE PLAYER DOES NOT OWN ENTRIES 0-3. `InitSprites` emits by PRIORITY -- HIGH, then NORM,
	-- then LOW, and only within a class in struct order -- so the first four entries belong to the
	-- highest-priority object that has a sprite, which is the player only when nothing outranks it.
	-- The "!" over a character's head does: `SpawnEmote` creates a HIGH_PRIORITY object sitting
	-- 16px above the tile, so while it is on screen entries 0-3 are the EMOTE'S and this
	-- calibration reads a y a whole tile too high. Every painted peer then moves up a tile and back
	-- -- the user, watching a fishing bite, 2026-08-26: *"if i catch a fish, the 2 ghosts move back
	-- 1 tile"*. Measured the same day: the player's own OAM y went 76 -> 60 on the frame the emote
	-- object appeared, with its tile, sprite position and offsets all provably unchanged.
	--
	-- FIND THE PLAYER'S ENTRIES BY THEIR TILE IDS instead of by their position in the list. A
	-- sprite's graphics occupy a 12-tile block (standing) plus the same block 0x80 above it
	-- (stepping), so an entry belongs to the player exactly when its tile is inside the player's
	-- own block -- and everything that displaces it is drawn from ABSOLUTE tiles ($f8-$fb for an
	-- emote, $fc-$fd for a fishing rod), which are outside any block by construction. The run ends
	-- at the first entry that does not match, which is also what keeps a fishing player's FIFTH
	-- sprite (the rod) out of the corner.
	local playerOamX, playerOamY = 255, 255
	local pBase, pFound = (u8(OBJECT_STRUCTS + F_SPRITE_TILE) or 0) & 0x7F, 0
	for i = 0, oam.ENTRIES - 1 do
		local y = memory.read_u8(i * 4, "OAM") or 255
		if y >= 160 then -- OAM_YCOORD_HIDDEN, what `.fill` writes into every unused entry
			break -- the engine packs from 0 and hides the tail, so there is nothing past here
		end
		local d = ((memory.read_u8(i * 4 + 2, "OAM") or 255) - pBase) & 0xFF
		if d <= 0x0B or (d >= 0x80 and d <= 0x8B) then
			local x = memory.read_u8(i * 4 + 1, "OAM") or 255
			if y < playerOamY then playerOamY = y end
			if x < playerOamX then playerOamX = x end
			pFound = pFound + 1
			if pFound >= 4 then
				break -- a character is four body entries, and the player is the first object in
				-- struct order wearing this block -- a ghost wearing the same sprite comes later
			end
		elseif pFound > 0 then
			break -- the player's own run has ended; anything further is somebody else
		end
	end
	if pFound == 0 then
		-- The player is not in the buffer at all (facing STANDING, or the engine skipped it).
		-- Fall back to what this read did before, so a frame with no match behaves as it always
		-- has rather than painting at 255,255.
		for i = 0, 3 do
			local y = memory.read_u8(i * 4, "OAM") or 255
			local x = memory.read_u8(i * 4 + 1, "OAM") or 255
			if y < playerOamY then playerOamY = y end
			if x < playerOamX then playerOamX = x end
		end
	end
	-- CALIBRATED EVERY FRAME, and it must be: this is the term that tracks the CAMERA, so freezing
	-- it stops the painted copy following the scroll at all.
	--
	-- It was frozen on 2026-08-21 to kill a +/-2px wiggle -- the two sides of this subtraction live
	-- one frame apart, OAM holding what the engine built last frame against a struct field from
	-- this one, so mid-walk they disagree by the per-frame step delta. That is a real defect, but
	-- the cure was far worse than the disease: with calX held, the painted position stayed put while
	-- the world scrolled under it and then jumped a whole tile when the destination caught up. The
	-- user saw a ghost teleport two tiles ahead and snap back.
	--
	-- So: per-frame, wiggle and all, until the phase error is fixed at its source rather than by
	-- refusing to look. A 2px oscillation is a blemish; a two-tile teleport is a broken ghost.
	-- ONE HISTORY ENTRY PER FRAME, recorded here beside the OAM read rather than inside the
	-- per-peer loop -- in the loop it advanced once per PEER, so "four frames ago" became two with
	-- two copies on screen, and the aged reference moved faster than the player did.
	--
	-- The OAM origin is stored WITH the tile and offset it belongs to. Ageing the offset while
	-- leaving the origin current makes the two motions add up, which reads as a ghost racing to its
	-- destination -- exactly what the user saw.
	do
		local h = playerHistory
		h.n = (h.n or 0) + 1
		-- How many samples have been recorded since the world was last rebuilt. See the readiness
		-- gate below: the entries themselves are never cleared, so this is the only thing that can
		-- tell a current-map sample from one describing the map we just left.
		h.since = (h.since or 0) + 1
		h[(h.n % h.size) + 1] = {
			oamX = playerOamX, oamY = playerOamY,
			tx = u8(OBJECT_STRUCTS + F_MAP_X) or 0, ty = u8(OBJECT_STRUCTS + F_MAP_Y) or 0,
			prog = stepProgress(OBJECT_STRUCTS),
			walking = (u8(OBJECT_STRUCTS + F_WALKING) or STANDING) ~= STANDING,
			dir = ((u8(OBJECT_STRUCTS + F_DIRECTION) or 0) // 4) & 3,
		}
		-- THE ENGINE'S MOVEMENT TICK, observed rather than assumed. The world moves 2px every
		-- other frame and the player's step progress advances on exactly those frames, so the
		-- frame parity on which `prog` changes IS the engine's clock. A drawn ghost has to move on
		-- the same one: moving on the other parity shifts the ghost 2px relative to the player on
		-- every frame, which is a shake, not a walk.
		--
		-- Latched, so a standing player (no ticks to see) leaves the last known phase in place
		-- rather than resetting it to a guess. Written here, next to the sample it is derived
		-- from, so the two can never be read from different frames.
		local nowProg = stepProgress(OBJECT_STRUCTS)
		if facingFrames.lastPlayerProg and nowProg ~= facingFrames.lastPlayerProg then
			local parity = emu.framecount() % 2
			if COMPARE_TIERS then
				facingFrames.paritySeen = facingFrames.paritySeen or {}
				facingFrames.paritySeen[parity] = (facingFrames.paritySeen[parity] or 0) + 1
				-- THE PLAYER'S OWN RHYTHM, as the thing the ghost's has to be compared against.
				-- "The ghost moves every 1 to 3 frames" means nothing until the player's own figure
				-- is on the line beside it -- the engine is irregular too, and the target is to
				-- match its irregularity rather than to be metronomic.
				if facingFrames.playerGapAt then
					local g = emu.framecount() - facingFrames.playerGapAt
					if g > 8 then g = 8 end
					facingFrames.playerGap = facingFrames.playerGap or {}
					facingFrames.playerGap[g] = (facingFrames.playerGap[g] or 0) + 1
				end
				facingFrames.playerGapAt = emu.framecount()
			end
			facingFrames.tickParity = parity
		end
		facingFrames.lastPlayerProg = nowProg
	end

	-- DO NOT PAINT UNTIL THE AGED REFERENCE IS A REAL SAMPLE OF THIS MAP.
	--
	-- The painted position is measured against the player as they were `age` frames ago, because
	-- the peer's own state is that old. Straight after a map load the ring still holds the
	-- PREVIOUS map's samples -- a different tile, a different camera -- so the first painted frames
	-- place the ghost against a world that is gone. The user, 2026-08-22: *"when going outside, the
	-- drawn ghost first appears in a weird location, and then appears where its supposed to be
	-- afterwards"*.
	--
	-- WAITING is the fix; CLEARING is not, and that distinction cost a regression. Wiping the ring
	-- was tried first (2026-08-22) and made the aged lookup miss, which falls through to
	-- `hist[(hist.n % hist.size) + 1]` -- the sample written THIS frame. That is not a safe
	-- fallback, it is a different and wrong reference: two frames placed against a player two
	-- frames too new, then a snap back as the ring refilled. Once per crossing, and with the door
	-- test walking upward into the doorway it fired constantly -- the user saw it as the ghost
	-- wiggling while simply walking up, which is nothing like where the change had been aimed.
	--
	-- So the entries are left alone and the tier simply declines to paint until enough of them
	-- describe the map we are actually on. `age + 1` because the lookup reaches back exactly
	-- `age` pushes; at that point every term in the position belongs to one world again.
	if (playerHistory.since or 0) <= playerHistory.age then
		stopDrawing("history-not-ready")
		return
	end

	local calX = (playerOamX - 8) - (u8(OBJECT_STRUCTS + F_SPRITE_X) or 0)
	local calY = (playerOamY - 16) - (u8(OBJECT_STRUCTS + F_SPRITE_Y) or 0)

	if anchorTileX then
		-- Anchor available: screen position of its tile, then tile deltas from there.
		anchorPx = anchorPx + calX
		anchorPy = anchorPy + calY
	end
	-- With the tier switched off but COMPARE_TIERS on, the comparison ghost is the only thing that
	-- may be painted -- `overflow` still fills with real peers the engine had no room for, and
	-- painting those would be the tier running under a flag that says it is off.
	local paintable = overflow
	if not DRAW_OVERFLOW then
		paintable = {}
		for pid, po in pairs(overflow) do if po.compare then paintable[pid] = po end end
	end
	for id, o in pairs(paintable) do
		nWanted = nWanted + 1
		-- Is this peer moving? Its own position changes are the only signal a drawn ghost has --
		-- nothing in the engine is animating it. A peer that has changed tile within the last
		-- half second is treated as walking, which is roughly how long a step takes.
		if o.lastX ~= o.x or o.lastY ~= o.y then
			-- Keep the tile it came FROM, not just the one it is on. Without it the painted copy
			-- has no sub-tile position at all and can only ever jump a whole tile at a time -- the
			-- user, 2026-08-21: *"the drawn ghost teleports a full tile, every time you walk a
			-- tile"*. The wire carries tiles; the spawned tier gets its glide from the engine
			-- sliding the sprite 2px a frame, and the painted tier has to do that itself.
			o.fromX, o.fromY = o.lastX, o.lastY
			o.lastX, o.lastY, o.movedAt = o.x, o.y, drawFrames
		end
		-- Resident tiles first -- they are what the engine is drawing everyone else from, so a
		-- drawn peer beside a spawned one matches exactly. Failing that, read the peer's sprite
		-- out of the cartridge, which is how a peer wearing a sprite THIS map never loaded (the
		-- other gender, most obviously) gets to look like themselves.
		local source, palette = nil, u8(OBJECT_STRUCTS + F_PALETTE) or 0
		-- RESIDENT TILES ARE NOT RESIDENT DURING A FLY. `FlyFunction_InitGFX` loads cutscene
		-- graphics -- the leaves, and the flying mon's icon -- while the sequence runs, so the
		-- VRAM under a sprite's base holds something else for its duration and goes back
		-- afterwards. Measured 2026-08-26 by adding a 16-byte signature of the actual pixels to
		-- the sprite trace: `sig` went 0906 -> 036A -> 0906 across every single fly, while the
		-- BASE never moved off 0 -- which is why the trace, keyed on the address alone, had sat
		-- silent through four of them. Right address, wrong asset, exactly as the fishing rod was.
		--
		-- So during a local fly the peer is drawn from the CARTRIDGE instead, which is the path
		-- that already exists for a peer wearing a sprite this map never loaded. Same tiles the
		-- game itself would use, unaffected by what the cutscene is doing to VRAM.
		--
		-- VALIDATED AGAINST THE CARTRIDGE, which is the only reference that cannot be poisoned.
		--
		-- Two weaker versions failed first, both today. A 240-frame fly window expired while the
		-- tiles were still swapped (`f=11374 -> rom`, `f=11587 -> vram sig=036A`, restore only at
		-- `f=11750`). Replacing it with "remember the signature seen while not flying" then failed
		-- on the FIRST fly of a run and worked on the second and third -- because `FlyFromAnim`
		-- runs BEFORE the warp, so the swap begins at the DEPARTURE, before `hMapEntryMethod` is
		-- stamped: the not-flying test was still true, and the cutscene's own signature was
		-- learned as the reference. A learned reference is only as good as the moment it was
		-- taken, and that moment was inside the event it was meant to detect.
		--
		-- The cartridge has no such window. The engine copies a sprite's graphics into VRAM
		-- verbatim, so the first tile at a resident base must equal the first tile of that
		-- sprite's ROM graphics; if it does not, those pixels belong to something else right now
		-- and the peer is drawn from the ROM instead. No timer, no learning, nothing to poison,
		-- and it covers every borrower of sprite VRAM rather than Fly alone. The ROM side is
		-- memoised per sprite id -- it cannot change -- so the per-frame cost is 16 VRAM reads.
		local tile = residentSpriteTile(o.sprite)
		if tile and OVERWORLD_SPRITES_ROM then
			local want = facingFrames.romSig and facingFrames.romSig[o.sprite]
			if want == nil then
				local g = spriteGfxInRom(o.sprite)
				want = false
				if g then
					want = 0
					for b = 0, 15 do
						want = (want + romByte(g + b)) & 0xFFFF
					end
				end
				facingFrames.romSig = facingFrames.romSig or {}
				facingFrames.romSig[o.sprite] = want
			end
			if want then
				-- VRAM_BANK1, the same place `decodeTile` reads -- character graphics live in
				-- bank 1 and BizHawk's VRAM domain lays both banks flat. The first version of
				-- this check read bank 0, so it compared unrelated tiles against the cartridge,
				-- never matched, and quietly moved EVERY peer onto the ROM path in ordinary play
				-- ("1 from the cartridge" with nothing happening). The file already carries this
				-- warning at `decodeTileAt` -- from the first thing the user ever said about the
				-- drawn tier, 2026-08-19 -- and it still had to be rediscovered here.
				local have = 0
				for b = 0, 15 do
					have = (have + (readVram(VRAM_BANK1 + tile * 16 + b) or 0)) & 0xFFFF
				end
				if have ~= want then
					local was = tile
					tile = nil -- not this sprite's pixels right now; fall through to the cartridge
					-- COUNTED, because whether this ever fires is an open question. Read the
					-- comment above: the swap it was built for was measured in VRAM bank 0, and
					-- once the read was corrected to bank 1 the signature held steady through
					-- two clean flies. So this may be guarding nothing. One line, once, so a
					-- later session can settle it instead of assuming either way.
					if not facingFrames.vramMismatch then
						facingFrames.vramMismatch = true
						logFile(string.format("resident tiles for sprite %s did not match the "
							.. "cartridge (base %d) -- drawing from ROM instead. FIRST TIME this "
							.. "session; if this line never appears, the check is dead weight.",
							tostring(o.sprite), was or -1))
					end
				end
			end
		end
		if tile then
			source = { vram = tile }
		else
			local gfx, _, pal = spriteGfxInRom(o.sprite)
			if gfx then
				source, palette = { rom = gfx }, pal
				nFromRom = nFromRom + 1
			else
				-- LAST RESORT: THIS MACHINE'S OWN PLAYER, AND FROM THE CARTRIDGE IF IT HAS TO BE.
				--
				-- This used to ask only `residentSpriteTile`, which needs `W_USEDSPRITES` -- and
				-- that address is unmeasured on the Archipelago build, so on that build the
				-- last-resort path was itself unavailable and a peer with no other source was
				-- simply not drawn. It went unnoticed while `o.sprite` was always set, because
				-- the ROM branch above caught every peer first. The `gfx` gate (see peerSprite in
				-- renderRemote) drops a peer's sprite id when its cartridge numbers sprites
				-- differently from ours, which made this the live path for the first time --
				-- measured 2026-08-26 as `1 peers waiting, 0 drawn, 1 no sprite tiles`, once a
				-- second, forever, with a peer standing right there.
				--
				-- The local player's own id is meaningful on our own ROM by construction, so the
				-- cartridge can always answer for it wherever the sprite table has been measured.
				-- That is a better fallback than the old one on EVERY build, not only that one:
				-- "wear this machine's player" was always the intent, and residency was never the
				-- thing that decided whether we could honour it.
				local mine = u8(OBJECT_STRUCTS + F_SPRITE)
				local own = residentSpriteTile(mine)
				if own then
					source = { vram = own }
				else
					local g, _, p = spriteGfxInRom(mine)
					if g then
						source, palette = { rom = g }, p
						nFromRom = nFromRom + 1
					end
				end
			end
		end
		if not source then nNoTile = nNoTile + 1 end
		-- SPRITE TRACE, off unless MESHGHOST_CRYSTAL_SPRITE_TRACE is set. EDGE-TRIGGERED: it logs
		-- only when the answer to "which graphics is this peer being drawn from" CHANGES, so a
		-- steady session writes one line and a swapping one writes a line per swap.
		--
		-- WHAT IT IS FOR, 2026-08-25. The user, after surfing and coming back ashore: the drawn
		-- ghost *"is swapping between walking [and] surf sprite only when walking downwards"*.
		-- Two mechanisms were reasoned from this file and BOTH fail to explain "downwards only":
		--   * the peer's sprite id is not oscillating -- measured the same day with a read-only
		--     probe on the player's own OBJECT_SPRITE byte, which held 1 on land and 83 while
		--     surfing across 5,490 frames with four clean transitions and no flicker; and
		--   * the arrangement cache cannot be the source of surf ART, because a learned frame
		--     stores an OFFSET within whatever sprite it was captured from, and SurfSpriteGFX is
		--     a 12-tile WALKING_SPRITE exactly like ChrisSpriteGFX (`data/sprites/sprites.asm`)
		--     -- so a blob-learned offset applied to the walking base still draws walking tiles.
		-- What neither of those can rule out is THIS line: `o.sprite` arriving right and the
		-- source coming out wrong anyway, via a wUsedSprites entry that has moved. So the trace
		-- names the peer's sprite, which branch was taken, and the tile base or ROM offset it
		-- landed on -- which is the one fact that separates "wrong id" from "right id, wrong
		-- tiles", and cannot be recovered from the screen afterwards.
		if facingFrames.sprTrace == nil then
			facingFrames.sprTrace = (os.getenv("MESHGHOST_CRYSTAL_SPRITE_TRACE") or "") ~= ""
		end
		if facingFrames.sprTrace or _G.MESHGHOST_CRYSTAL_SPRITE_TRACE == true then
			local kind = source and (source.vram and "vram" or "rom") or "none"
			local where = source and (source.vram or source.rom) or -1
			-- A SIGNATURE OF THE PIXELS, not just the address they came from. The base can hold
			-- perfectly steady while the CONTENT under it changes -- which is the whole fishing-rod
			-- lesson (right address, wrong asset) and the live suspicion for the garbled fly
			-- landing: `FlyFunction_InitGFX` loads cutscene graphics during the sequence, so VRAM
			-- at a resident sprite's base may not be that sprite for the duration. Keying the
			-- edge-trigger on this makes a content swap announce itself; the address alone never
			-- could, and did not -- the trace sat silent from frame 304 through four flies.
			local sig = 0
			if source and source.vram then
				for b = 0, 15 do
					sig = (sig + (readVram(VRAM_BANK1 + source.vram * 16 + b) or 0)) & 0xFFFF
				end
			end
			local key = string.format("%s/%s/%s/%s/%04X", tostring(o.sprite), kind, tostring(where),
				tostring(o.facing), sig)
			facingFrames.sprLast = facingFrames.sprLast or {}
			if facingFrames.sprLast[id] ~= key then
				facingFrames.sprLast[id] = key
				logFile(string.format("sprite-trace: f=%d %s peerSprite=%s -> %s %s sig=%04X "
					.. "(facing=%s, local sprite=%s at base=%s)", drawFrames, id,
					tostring(o.sprite), kind, tostring(where), sig, tostring(o.facing),
					tostring(u8(OBJECT_STRUCTS + F_SPRITE)),
					tostring(u8(OBJECT_STRUCTS + F_SPRITE_TILE))))
			end
		end
		if source then
			-- SIGNED screen coordinates, computed here rather than borrowed from screenCoords().
			-- That helper answers in the engine's sprite space, which is taken mod 256 and offset
			-- by 16 -- fine for the engine, wrong here: a peer above or left of the camera wraps
			-- to ~240 and reads as "off screen". Live case 2026-08-19: 40 of 83 waiting peers
			-- discarded that way, which the user saw as half a screen never filling.
			-- The engine's own formula, then the wrap undone. Crystal addresses its tilemap
			-- MODULO 16 tiles and subtracts a pixel scroll of up to 255, so a character left of
			-- or above the camera comes out near 256 rather than negative. Taking that back to a
			-- signed value is what puts the left column and the top rows on screen; without it
			-- they read as "off screen" and simply never draw.
			-- The engine's OWN formula, which a probe confirmed matches every real object's
			-- sprite position exactly at rest (off=0,0 for all 13, 2026-08-19) -- then its
			-- wrapped 0-255 answer converted back to a screen position. A character left of or
			-- above the camera comes back near 256, not negative, and reading that as "off
			-- screen" is what left rows and columns empty. Y is +16 in this space (the player at
			-- tile row 8 with the window at row 4 reads 80, not 64).
			local sx, sy
			if anchorTileX then
				-- Tile deltas from a standing character: no scroll arithmetic, so nothing to be
				-- out of date. Signed on purpose -- a peer left of or above the anchor is a
				-- negative delta, not a wrapped one.
				sx = anchorPx + (o.x - anchorTileX) * 16
				sy = anchorPy + (o.y - anchorTileY) * 16
			else
				-- Nobody is standing still this frame (an empty map while the player walks).
				-- Fall back to the engine-space computation, which is right at rest and drifts by
				-- at most a tile mid-step -- better than not drawing at all.
				sx, sy = screenCoords(o.x, o.y)
				sx = sx + calX
				sy = sy + calY
			end
			-- EVERY position in this pipeline is arithmetic on BYTES -- sprite coordinates,
			-- map coordinates, the window origin -- so the true screen position only exists
			-- modulo 256, and both branches can hand back an alias: the user's drawn copy sat
			-- at "screen -224,-196", which is 32,60 seen through exactly this (2026-08-21). It
			-- was then discarded as off screen, which is why the drawn ghost did not move and
			-- why a peer released from the spawned tier while idle VANISHED instead of being
			-- painted. One normalisation for both branches: fold into [-16, 240), the window
			-- where a 16px character can touch the 160x144 screen. This is the mod-window done
			-- properly, not a compensating offset -- a genuinely off-screen character still
			-- lands outside the on-screen test below and is still discarded.
			sx = ((sx % 256) + 272) % 256 - 16
			sy = ((sy % 256) + 272) % 256 - 16

			-- SUB-TILE POSITION, computed so the CAMERA CANCELS rather than being corrected for.
			--
			-- Two earlier attempts failed the same way (2026-08-21): both added a smooth term on
			-- top of `sx`, which is the destination TILE's position and already carries the
			-- camera's scroll -- arriving in a lump about twelve frames into the step. Smooth plus
			-- quantised is two motions for one step, and the user saw exactly that.
			--
			-- The model that works has no camera term at all. Every character's screen position is
			-- the PLAYER's screen position plus their offset from the player, and the player's own
			-- sprite is smooth and always readable:
			--
			--     painted = playerScreen + (peerTile - playerTile)*16 - playerProgress + peerProgress
			--
			-- The camera moved the player and the world together, so it appears on neither side.
			-- `playerProgress` is how far the player is into their own step, `peerProgress` the
			-- same for the peer, sent as extras.prog because only the peer knows it. For a peer
			-- moving in step the two cancel and the offset is constant -- nothing to snap.
			-- COMPARE THE PEER AGAINST WHERE THE PLAYER WAS WHEN ITS STATE WAS CURRENT.
			--
			-- The peer's state is 3-5 frames old (posediff measured the round trip). Subtracting a
			-- FRESH local reference from a STALE remote one is the last artefact left on this tier:
			-- the instant the player completes a step their tile advances and their offset resets,
			-- while the peer still describes the previous tile -- a full 16px of disagreement that
			-- closes as the peer catches up. The user saw it as a backward snap at every tile
			-- boundary, and it survived turning interpolation on because it is not a network
			-- problem, it is a comparison between two different moments.
			--
			-- So the player's own position is kept for a few frames and the sample matching the
			-- peer's age is used. Same idea as the core's interpolation, applied to the reference
			-- rather than to the peer.
			local hist = playerHistory
			local aged = hist[((hist.n - hist.age) % hist.size) + 1]
				or hist[(hist.n % hist.size) + 1]

			local pTile = { x = aged.tx, y = aged.ty }
			local pProg = aged.prog
			local pDir = aged.dir
			local peerProg = tonumber(o.prog) or 0

			-- Progress is a distance; it becomes a displacement through the direction each is
			-- facing. down/up/left/right, the adapter's own dir order everywhere else.
			local function displace(dir, px)
				if dir == 0 then return 0, px end
				if dir == 1 then return 0, -px end
				if dir == 2 then return -px, 0 end
				return px, 0
			end
			-- MAP_X/MAP_Y ARE THE DESTINATION, written at the START of a step -- this adapter's own
			-- movement recipe depends on that, and it is what makes the sign here easy to get
			-- wrong. A character part-way through a step is therefore at
			--     destination - (16 - progress)
			-- along the direction it is moving, NOT at destination + progress. Getting that
			-- backwards drives the ghost past its target and then back, which is direction-shaped:
			-- the user saw it snap backwards walking up and wiggle walking down (2026-08-21).
			local function offsetFromDest(dir, prog, walking)
				if not walking then
					return 0, 0
				end
				return displace(dir, prog - 16)
			end

			-- PAIR OAM WITH THE FRAME OAM WAS BUILT FROM.
			--
			-- playerOamX/Y is what the engine DREW last frame; pProg is read from the struct THIS
			-- frame. Subtracting one from the other mixes two frames, and mid-step they differ by
			-- exactly the per-frame step delta -- a +/-2px oscillation, which is the drawn ghost's
			-- wiggle. Neither value is wrong; pairing them is.
			--
			-- So the player's progress is used one frame late, to match the OAM it is being paired
			-- with. pitfalls.md's "a script's writes land between frames" is the same defect on the
			-- write side; this is its reading twin.
			local ppx, ppy = offsetFromDest(pDir, pProg, aged.walking)
			-- The peer's own `offsetFromDest` used to be taken here and is gone with the position
			-- rework below: the model walks from the destination tile itself, so converting a
			-- progress back into an offset is a step that no longer happens.

			-- THE GHOST WALKS; IT IS NOT PLACED. (user's call, 2026-08-23)
			--
			-- Painting wherever the interpolated position said produced a position that was right
			-- on average and wrong every frame. Measured over 198 moving frames at the shipped
			-- 250ms: mean 0.970 px/frame -- the player's own walking speed -- but only 65 of those
			-- frames advanced a whole pixel, against 58 at 0.75px and 52 at 1.25px. The core
			-- interpolates on wall-clock time and this adapter samples it once per emulated frame,
			-- and emulated frames are not exactly 16.667ms apart, so every sample lands a different
			-- fraction of a pixel along. Rounded to the screen grid that paints 1,1,2,1,2,1 -- and
			-- a walking character in this game never moves 2px in a frame. `phase9.md`.
			--
			-- Two other suspects were measured and cleared first: the two clocks do not beat (660
			-- of 660 frames received exactly one message), and the aged player reference is a fixed
			-- 2-frame lookup, so it cannot wobble.
			--
			-- So the wire says WHERE THE PEER IS GOING and this walks there at the engine's own
			-- pace: one whole pixel a frame, 16 frames a tile, which is what `o.x`/`o.y` already
			-- describe -- they are the DESTINATION tile, written at the start of a step. A step
			-- therefore appears as 16px of distance and is walked off in 16 frames, with no rate
			-- invented here and nothing to round. It is the same reason the SPAWNED tier looks
			-- right: there the engine moves the ghost. Here we move it the way the engine would.
			local tX, tY = o.x * 16, o.y * 16
			if not o.modelX then
				o.modelX, o.modelY = tX, tY
			end
			-- RESYNC RATHER THAN WALK, past a tile and a half. A map change, a respawn, a peer
			-- that stopped sending -- anything that moves a peer further than a step can carry it
			-- is a teleport, and walking it off at 1px/frame would send the ghost gliding across
			-- the map. A character does not do that either.
			-- THE RHYTHM, NOT JUST THE POSITIONS. User, 2026-08-23, after the 2px grid landed:
			-- *"it looks a bit better now... the jittering got reduced by like half"*. Halved is
			-- not fixed, and every positional instrument now reads clean -- the ghost only occupies
			-- engine-legal pixels and never moves more than 2px in a frame. What none of them
			-- measures is WHEN it moves. A character that steps 2px after one frame, then after
			-- three, then after one covers exactly the right ground on exactly the right pixels and
			-- still does not walk like the engine, whose own gaps have a pattern of their own
			-- (measured 64 even against 32 odd -- irregular, but its own irregularity, not ours).
			--
			-- So: the gap in frames between successive 2px moves, for the ghost and for the player,
			-- from the same log line. If the player's gaps cluster and the ghost's do not, the
			-- remaining half of the jitter is the pacing and not the placement.
			if facingFrames.stats() and o.only == "drawn" then
				local now = emu.framecount()
				if o.modelX ~= facingFrames.gapLastX or o.modelY ~= facingFrames.gapLastY then
					if facingFrames.gapLastAt then
						local g = now - facingFrames.gapLastAt
						if g > 8 then g = 8 end
						facingFrames.ghostGap = facingFrames.ghostGap or {}
						facingFrames.ghostGap[g] = (facingFrames.ghostGap[g] or 0) + 1
					end
					facingFrames.gapLastAt = now
					facingFrames.gapLastX, facingFrames.gapLastY = o.modelX, o.modelY
				end
			end
			-- IS THE MODEL AHEAD OF THE PEER, AND BY HOW MUCH? User, 2026-08-23: walking up and
			-- down constantly, *"it still feels like the drawn ghost is a bit ahead of the spawned
			-- ghost, and it also looks jittery"*.
			--
			-- The spawned tier is known to start each step a mean 4.3 frames late (`unverified.md`),
			-- so "ahead of the spawned ghost" is partly that tier's own lag and says nothing on its
			-- own. The question that can be answered is whether this tier leads the PEER -- and the
			-- interpolated pixel position is still arriving even though it is no longer painted
			-- from, which makes it exactly the reference to check against. SIGNED, because "ahead"
			-- and "behind" are different faults with different fixes and an absolute value erases
			-- the distinction.
			if facingFrames.stats() and o.only == "drawn" and o.pixX and o.pixY then
				local lead = (o.facing == 0 or o.facing == 1)
					and (o.modelY - o.pixY) or (o.modelX - o.pixX)
				if o.facing == 1 or o.facing == 2 then lead = -lead end -- toward travel
				local lk = math.floor(lead + 0.5)
				if lk > 8 then lk = 8 end
				if lk < -8 then lk = -8 end
				facingFrames.lead = facingFrames.lead or {}
				facingFrames.lead[lk] = (facingFrames.lead[lk] or 0) + 1
			end
			-- HOW FAR BEHIND THE MODEL EVER GETS, and how often it gives up and snaps. A model that
			-- tracks and a model that resyncs every other step both paint a ghost in about the
			-- right place; only these two numbers tell them apart, and "it looked fine" would not.
			if facingFrames.stats() then
				local behind = math.abs(o.modelX - tX) + math.abs(o.modelY - tY)
				facingFrames.modelMax = math.max(facingFrames.modelMax or 0, behind)
			end
			if o.pixX and o.pixY then
				-- QUANTISE THE POSITION, NOT THE TIME. (2026-08-23, third attempt and the one the
				-- measurements point at rather than away from.)
				--
				-- Attempt one walked the ghost 1px a frame: smoother than the game, because the
				-- game moves 2px at a time and never 1. Attempt two moved 2px on every other frame
				-- and produced a ghost that shakes -- the engine's tick is NOT on a fixed frame
				-- parity, measured at even 64 against odd 32, so a ghost locked to a parity moves
				-- on the frames the player does not, and relative to a camera locked on the player
				-- that is 2px of shake every frame. (It also reads in a painted-movement histogram
				-- as a flawless uniform 2px, which is why the user saw it before the numbers did.)
				--
				-- There is nothing to guess. The interpolated position already carries the peer's
				-- timing, correct to a mean 0.970 px/frame; its only defect was landing on
				-- fractional pixels the engine would never draw. So round it onto the engine's own
				-- 2px grid: the ghost can then only ever occupy a position the engine could have
				-- produced, and it gets there on the peer's schedule rather than on a schedule
				-- invented here. A monotone input stays monotone, so this cannot oscillate.
				-- ...AND THE RHYTHM ON TOP OF IT, which is the other half of walking like the
				-- engine. Measured 2026-08-23 with both bodies' gaps on one line: the player moves
				-- 2px every 2 frames, 91 times out of 93 -- a metronome. Quantising position alone
				-- got the ghost to 73 of 92, the rest arriving after 1 frame or after 3, and the
				-- user saw exactly that residue: *"the jittering got reduced by like half"*.
				--
				-- The phase is LATCHED AT THE START OF EACH BURST rather than fixed. That is what
				-- the earlier parity attempt got wrong: within one bout of walking the engine's
				-- tick is firmly on one parity (measured odd 95 against even 1), but a later bout
				-- can begin on the other, so a parity latched once and kept is right for a while
				-- and then exactly wrong -- which is the shake that reading showed.
				--
				-- The quantised interpolated position stays the authority for WHERE; this only
				-- decides WHEN the model is allowed to take its 2px. The peer's true speed is
				-- 2px per 2 frames, so honouring the rhythm cannot make the ghost fall behind.
				-- THE MODEL RUNS ON BOTH STREAMS -- tried without it, at 0ms, and refuted the same
				-- hour. The raw stream is engine-quantised in SPACE but not in arrival TIME: ~7%
				-- of walking frames receive 0 or 2 messages (measured, ARRIVALS histogram), so a
				-- verbatim copy lurches 4px on every double arrival -- the user, on the bypass:
				-- *"now its jittering constantly instead, this made it worse"*. The model's real
				-- job was never "fix interpolation"; it is "fix arrival timing", and both streams
				-- have arrival timing.
				local qx = math.floor(o.pixX / 2 + 0.5) * 2
				local qy = math.floor(o.pixY / 2 + 0.5) * 2
				-- The model is born TILE-ALIGNED, from the destination tile rather than from the
				-- interpolated position: every later move is a committed 16px step, so whatever
				-- alignment it starts with it keeps forever -- born mid-step, it would stand
				-- between tiles for the rest of the session.
				if not o.modelX then
					o.modelX, o.modelY = tX, tY
				end
				-- THE PHASE MUST SURVIVE A CATCH-UP, and it must be the ENGINE's phase.
				--
				-- User, 2026-08-23, on the version that latched on the first frame it wanted to
				-- move and cleared the moment it arrived: *"moving 1 tile looks good/perfect...
				-- moving like 4-5+ tiles and it starts to look really jittery"*. A fault that grows
				-- with the length of the walk is not a constant offset and not a rounding error --
				-- it is something that REPEATS. The model reaches its target and waits many times
				-- inside a long walk, and each of those cleared the phase, so a five-tile walk
				-- re-latched many times where a one-tile walk latched once. Every re-latch is a
				-- fresh coin toss on parity, and half of them land in anti-phase with the player.
				--
				-- So: the phase is only released after the ghost has genuinely STOPPED (half a
				-- second of stillness), not when it happens to be momentarily up to date. And it is
				-- taken from the engine's own observed tick when one has been seen, rather than
				-- from whichever frame we first wanted to move on -- there is a right answer
				-- available, so guessing is not required.
				-- "Wants to move" is now: mid-step (committed distance unfinished), or a target at
				-- least half a tile away -- NOT any 2px of disagreement, which is mostly noise.
				local wants = (o.stepLeft or 0) > 0
					or (math.abs(qx - o.modelX) + math.abs(qy - o.modelY)) >= 8
				if not wants then
					o.modelStill = (o.modelStill or 0) + 1
					if o.modelStill >= 30 then
						o.modelPhase = nil
					end
				else
					o.modelStill = 0
					if o.modelPhase == nil then
						o.modelPhase = facingFrames.tickParity or (emu.framecount() % 2)
						if COMPARE_TIERS then
							facingFrames.relatch = (facingFrames.relatch or 0) + 1
						end
					end
					-- FOLLOW THE ENGINE'S BEAT, don't just remember it. The latch was taken once per
					-- walk, and a lag frame flips the engine's parity mid-walk -- the tick pauses
					-- for a frame while `emu.framecount()` does not. After one of those the ghost
					-- is anti-phase for the REST of the walk: a constant 2px shake that starts
					-- somewhere in a long walk and never clears, which is the user's *"constant
					-- weird thing after moving far sometimes"* -- long walks have more lag frames
					-- to catch. `tickParity` is re-observed on every advance of the player's own
					-- step progress, so it survives what the latch cannot.
					if facingFrames.tickParity ~= nil
						and o.modelPhase ~= facingFrames.tickParity then
						o.modelPhase = facingFrames.tickParity
						if COMPARE_TIERS then
							facingFrames.phaseFollow = (facingFrames.phaseFollow or 0) + 1
						end
					end
					-- COMMIT WHOLE TILES, THE WAY THE ENGINE DOES. (2026-08-23, and it replaces
					-- three failed catch-up policies in a row.)
					--
					-- The previous model consulted the noisy target every beat, mid-step. Whenever
					-- the target stalled for a beat -- pure wire noise -- the model waited with it,
					-- the camera kept scrolling, and the ghost visibly slipped 2px backward on
					-- screen. The screen trace caught it as isolated `-` marks aligned with prog
					-- stalls. Every catch-up policy tried (instant, three-beat, hysteresis) only
					-- redistributed those slips: too eager stuttered, too patient let lag grow to
					-- the emergency snap, and the user duly reported "stuttering constantly", then
					-- "snapping back~ constantly", then both again. The policies were not the
					-- problem; consulting the target mid-step was.
					--
					-- A Crystal character CANNOT stop mid-tile. Once a step starts the engine
					-- finishes the 16px, and decisions happen only at tile boundaries. So the
					-- model now does the same: at a boundary it looks at the target ONCE -- at
					-- least half a tile away on some axis means commit a full 16px step toward it
					-- -- and mid-step it looks at nothing. Wire noise can now only ever DELAY a
					-- step at a boundary, where a pause is tile-aligned and looks like a player
					-- hesitating, never interrupt one mid-stride.
					--
					-- Catch-up survives in one place, with one meaning: more than 1.5 tiles behind
					-- for three consecutive boundaries arms the bike gait (4px per beat, the
					-- engine's own) until caught up. The forward-only guard is gone because
					-- direction is locked per committed step and cannot oscillate by construction.
					-- THE CAMERA IS THE CLOCK -- read, not inferred. The parity detector derived
					-- the engine's tick from when this script happened to observe the player's
					-- step progress change, and that observation is noisy: 106 "beat corrections"
					-- in one run, each one a correction of the DETECTOR, injected straight into
					-- the model's timing as a lost or gained move. The jitter being chased was, by
					-- then, mostly the instrument's.
					--
					-- The definition of on-screen jitter is "the ghost moves on frames the camera
					-- does not". So the ghost moves exactly on the frames the background scroll
					-- register CHANGES -- the same clock it is judged against, no inference in the
					-- loop. The two-frame minimum still applies: a camera scrolling every frame is
					-- the bike gait, and a walking ghost following every other camera frame is a
					-- walker's pace on tick frames. Only when the camera has been still (the local
					-- player parked while a ghost still owes distance) does the model fall back to
					-- its own two-frame beat, where there is nothing on screen to be relative to.
					-- EIGHT still frames, not two, before the model free-runs. The camera pauses
					-- 1-2 frames at EVERY player step boundary (the same two standing frames the
					-- `anim` documentation records), and a 2-frame fallback treated each of those
					-- micro-pauses as "camera parked": the model took a free step during the
					-- breath, then owed it back when the scroll resumed -- a `+`/`-` pair at
					-- tile-boundary rhythm, in every direction equally (mined from the screen
					-- trace, 30-39 marks per direction), which is what the user was still seeing
					-- on flowing corners. A real stop is far longer than a boundary breath; eight
					-- frames tells them apart, and the peer-still-walking case merely starts its
					-- free-run a few frames later, where there is nothing on screen to slip
					-- against anyway.
					-- THE PEER'S OWN STATE ENDS A STEP, not a count of still camera frames.
					--
					-- The eight-frame rule is about not STARTING work on the camera's boundary
					-- breath, and it stays for that. It was also holding the REMAINDER OF A
					-- COMMITTED STEP hostage, which the 2026-08-25 three-way trace caught at every
					-- one of 22 stops: `2.2.2.2.2.2.2.......2.2.2` -- a 7-frame freeze mid-step,
					-- then the last 6px. The user: *"drawn stopping a bit fast whenever
					-- pausing/stopping at the end"*.
					--
					-- The first fix shortened the wait to three frames for a committed remainder.
					-- That was a tuned constant standing in for the real question, which is not
					-- "how long has the camera been still" but "HAS THE PEER STOPPED" -- and that
					-- is on the wire, in `o.walking` (the peer's own anim), not something to infer
					-- from our screen. This file has made the same correction twice before (K's
					-- `stable` guard, the camera-as-clock): when the invariant itself is available,
					-- a proxy is what leaves a residue.
					--
					-- So: a committed step whose PEER has already finished walking is owed
					-- outright, and the model finishes it on its own beat with no camera consent.
					-- The mid-walk breath is untouched, because there the peer IS still walking --
					-- which is exactly the case the eight-frame rule was written to protect, and
					-- it keeps it.
					-- A CAMERA-BEAT DELAY WAS TRIED HERE TWICE ON 2026-08-25 AND REVERTED TWICE --
					-- kept as a note because "delay the drawn model to the spawned tier's clock"
					-- is the obvious answer to the tiers sitting ~3 frames apart in loopback, and
					-- both shapes of it put a defect straight on screen. A 3-frame queue on the
					-- camera beat landed the model's moves on the opposite parity from the
					-- camera's and the paint cancellation became a +-4px per-frame sawtooth (118
					-- of 249 frames moving 4px relative). A 2-frame queue kept parity on paper
					-- and still sawtoothed (103 of 205) -- the camera's cadence carries parity
					-- slips (player rhythm 1:12 3:13 in the same run), and every slip re-crosses
					-- the beats -- and the user watched the drawn ghost stop following outright.
					-- The model's beat and the paint's origin are one decision (the 2026-08-25
					-- note above says so for the player-sprite attempt); a tier alignment has to
					-- delay the model's INPUTS, never its clock.
					local due = facingFrames.camMoved
						or (((((o.stepLeft or 0) > 0 and not o.walking)
								or (facingFrames.camStillFor or 99) >= 8))
							and (emu.framecount() % 2) == o.modelPhase)
					-- THE DRAWN MODEL'S BEAT WAS TRIED ON THE PLAYER'S OWN SPRITE AND REVERTED,
					-- 2026-08-25 -- kept as a note because it is the obvious next idea and it is
					-- WRONG in a way only the raw frames show. The observation that prompted it is
					-- real: the player advances at 649, 651, 652, 654 (gaps 2, 1, 2) while this
					-- camera-clocked model advances at 647, 649, 651, 653 -- a perfect 2 every
					-- time, i.e. smoother than the game. Two attempts:
					--   * ORing `pSprMoved` in. By construction that can only fire EARLIER, so the
					--     trace came back byte-identical -- which is what said the theory had not
					--     actually been tested yet.
					--   * REPLACING the camera beat while the local player walks. The model's beat
					--     did not change and the PAINT started wobbling (25 -> 23 -> 25), because
					--     the painted position is the camera formula: moving the model on frames
					--     the camera did not move puts the disagreement straight on screen.
					-- So the model's beat and the paint's origin are one decision, not two, and
					-- the camera owns both. Matching the engine's irregular rhythm needs the paint
					-- moved off the camera formula first; that is a bigger change than a trigger.
					-- The remaining difference is a constant one-frame phase, which is the
					-- invisible kind -- unlike everything that has been fixed above it.
					if due then
						-- The boundary decision, as a function the frame can take TWICE: the
						-- camera's occasional 4px frame lands wherever it likes, including with
						-- 2px left in the committed step, and splitting the 4 across two frames
						-- was itself a per-tile stutter -- the `-.+` pairs, the user's "still
						-- looks stuttery for every step". Rolling across the boundary in one
						-- frame keeps the model's displacement equal to the camera's, always.
						local function decideBoundary()
							local dx, dy = qx - o.modelX, qy - o.modelY
							local adx, ady = math.abs(dx), math.abs(dy)
							-- ARM AT 8px OVER TWO BOUNDARIES, not 24 over three. With the paint now
							-- showing the model's true pace against the camera, the KPAINT dump
							-- measured the cost of the lazy threshold in absolute pixels: walking
							-- one horizontal side, sx slid 14 -> 2 -- boundary stalls losing 1-2px
							-- per tile that nothing repaid until a full 24px stood, which a 9-tile
							-- side never reached. The user watched exactly that: *"pushed
							-- backwards a bit / gliding backward during moving"*. Two lagged
							-- boundaries is already real lag, and the repayment is on-beat bike
							-- hops, so arming early costs nothing visible.
							-- Band 12/6, not 8/4: with chaining in place the model hovers a few
							-- pixels behind the live target by construction (level would mean no
							-- headroom to commit into), and an 8px trigger sat INSIDE that hover --
							-- the catch-up cycled hot, visible as `<-.+.+` clusters. Twelve is
							-- outside the hover; six keeps the repayment from overshooting into
							-- another stall.
							--
							-- IN STRIDES, NOT PIXELS (2026-08-25). 12/6 was measured at the walk,
							-- and the hover it sits outside of is built from per-frame echo and
							-- cushion terms that all scale with the gait -- so on the bike the
							-- ordinary hover reached the 12px line and catch-up cycled hot through
							-- plain riding, repaying on frames the camera did not move. The user,
							-- with both tiers side by side: *"both ghosts are moving at different
							-- speeds on the bike"* -- the drawn one was in repayment most of the
							-- time. 12/6 at the walk's 2px stride is 6/3 strides; stated that way
							-- it holds at every gait instead of only the one it was tuned on.
							local st = GAIT_PX[o.gait or 1] or 2
							if adx + ady >= 6 * st then
								o.lagBeats = (o.lagBeats or 0) + 1
							elseif adx + ady < 3 * st then
								o.lagBeats, o.catchup = 0, nil
							end
							if (o.lagBeats or 0) >= 2 then
								o.catchup = true
							end
							if adx + ady > 48 then
								-- Three tiles out is a teleport, not a walk. Snap to the TILE, so
								-- the model stays grid-aligned.
								o.modelX, o.modelY, o.stepLeft = tX, tY, 0
								if COMPARE_TIERS then
									facingFrames.modelSnaps = (facingFrames.modelSnaps or 0) + 1
								end
							elseif adx >= ady and adx >= 8 then
								o.stepDX, o.stepDY = (dx > 0 and 1 or -1), 0
								o.stepLeft = 16
							elseif ady > adx and ady >= 8 then
								o.stepDX, o.stepDY = 0, (dy > 0 and 1 or -1)
								o.stepLeft = 16
							elseif o.walking and adx + ady >= 3 * st then
								-- COMMIT EARLY WHEN THE PEER SAYS IT IS WALKING -- but not
								-- INSTANTLY, because the commit threshold is also the CUSHION.
								--
								-- Once walking, the model moves at exactly the camera's speed, so
								-- whatever gap it starts with is the gap it keeps -- and every
								-- tile boundary re-checks that gap against the wire's arrival
								-- jitter (measured at plus/minus 2-4px). Committing at 2px started
								-- the ghost almost immediately and left a cushion thinner than the
								-- jitter: at 2-4 boundaries per side the target was momentarily
								-- under 2px ahead and the model stalled a beat, each stall one
								-- visible 2px slip -- the user's "2-4 jitters per walking
								-- direction", localized mid-side at prog-0000 boundary holds in
								-- the trace. Six pixels buys three beats of cushion, which the
								-- jitter cannot pierce, at the price of one extra slip frame at
								-- the walk start -- the transition the user reports NOT seeing.
								-- The walking flag still gates it: a standing peer's noise never
								-- commits, and a peer reporting mid-step can only stop
								-- tile-aligned, so the committed tile is never a guess.
								if adx >= ady then
									o.stepDX, o.stepDY = (dx > 0 and 1 or -1), 0
								else
									o.stepDX, o.stepDY = 0, (dy > 0 and 1 or -1)
								end
								o.stepLeft = 16
							elseif o.walking and adx + ady >= st
								and drawFrames - (o.modelMovedAt or -99) <= 2 then
								-- CHAINING: a model that finished a tile within the last two
								-- frames and whose peer is still walking is mid-gait, not at
								-- rest, and holding it to the cold-start cushion is what bled
								-- 1-2px per tile into the backward glide. Two pixels of headroom
								-- is enough here: the arrival gap the cushion protects against
								-- can only DELAY this commit a beat, and the early catch-up above
								-- now repays that promptly instead of letting it stack.
								if adx >= ady then
									o.stepDX, o.stepDY = (dx > 0 and 1 or -1), 0
								else
									o.stepDX, o.stepDY = 0, (dy > 0 and 1 or -1)
								end
								o.stepLeft = 16
							end
						end
						-- NEVER ON CONSECUTIVE FRAMES unless the camera itself did -- its law, our
						-- law. A parity flip is honoured by waiting a frame, exactly as the camera
						-- lost one (the `++--` lesson); a 4px camera frame is honoured by moving
						-- 4px in that frame, exactly as the camera gained one.
						--
						-- THE BUDGET MIRRORS THE CAMERA'S OWN DELTA. The ghost is level exactly
						-- when its world displacement equals the camera's, frame by frame -- so
						-- on a camera frame the model moves as far as the camera did, clamped to
						-- the engine's gaits (2px walk, 4px bike; measured per-frame camera
						-- deltas: 2px:24 4px:3 8px:1). On fallback frames the camera is parked
						-- and 2px is the walker's pace.
						-- A 4px camera frame may arrive ONE frame after the camera's previous move
						-- (it is two engine ticks merged), and the two-frame rule then blocked the
						-- model from matching it: a 4px backward drop (`<`), repaid later. The rule
						-- exists to stop the MODEL inventing consecutive moves; when the CAMERA
						-- itself moved consecutively, matching it is the law, not a violation.
						-- COPY THE CAMERA, UNCONDITIONALLY. The "never on consecutive frames" rule
						-- assumed the engine never scrolls on consecutive frames; the event probe
						-- caught the assumption being false in one line, repeated at every snap the
						-- user reported: `cam=2 gap=1 bud=0` -- an ordinary 2px camera tick one
						-- frame after the previous one, and the gap rule zeroing the model's budget
						-- exactly then. The rule exists so the model cannot INVENT moves; copying
						-- the camera is not inventing. On a camera frame the model's budget IS the
						-- camera's delta (clamped to the bike's 4px); the gap discipline survives
						-- only in the camera-parked fallback, where the model is on its own clock.
						local mgap = drawFrames - (o.modelMovedAt or -99)
						local budget = 0
						-- THE PEER'S GAIT, not a pair of constants covering both cases. `4` was the
						-- bike's stride and `2` the walk's, applied to every peer whatever it was
						-- doing -- so a walking peer could be handed a 4px frame and a biking one
						-- was floored at a walker's 2px. `extras.gait` now carries the engine's own
						-- group (StepVectors: 1/2/4 px), so both bounds are the same number and
						-- that number is the peer's.
						local stride = GAIT_PX[o.gait or 1] or 2
						if facingFrames.camMoved then
							-- THE PEER'S STRIDE IS A FLOOR HERE, NOT A CEILING -- and it used to be
							-- both, which is the bug.
							--
							-- Two different quantities were being clamped with one number. How fast
							-- the PEER moves through the world is bounded by its own gait: that is
							-- the 1:1 rule, and the floor below is what enforces it. How far the
							-- WORLD moved underneath it is not motion at all -- it is the frame of
							-- reference changing, and a peer standing perfectly still has to shift
							-- on screen by exactly the camera's delta or it is not standing on its
							-- tile any more.
							--
							-- Clamping DOWN to the peer's stride made a stationary peer compensate
							-- only as fast as that peer could have walked. It was already wrong
							-- whenever the local player moved faster than the peer -- a walker
							-- watched from a bike drifted 2px of every 4 -- and the Archipelago
							-- build's fourth gait made it impossible to miss: 8px of camera against
							-- a 2px idle walker is 6px of slide per frame. The user, 2026-08-26:
							-- *"the vanilla ghost is gliding/sliding around when idle, if the
							-- archipelago player is using the fast bike mode ... its probly gliding
							-- as it can't keep up with the faster camera speed"*. It is exactly
							-- that, and the diagnosis was theirs.
							--
							-- `camDelta` is already clamped to 8 where it is sampled, so this cannot
							-- run away on a rebase.
							budget = facingFrames.camDelta or stride
							-- THE FLOOR APPLIES ONLY TO A PEER THAT IS ACTUALLY MOVING.
							--
							-- MEASURED 2026-08-26, and it refutes the assumption the whole budget
							-- rested on: during a turbo ride the camera histogram reads
							-- `2px:8 4px:52` -- NOT ONE 8px delta. The engine's object clock runs
							-- at half the video rate, so a gait of 8px per TICK scrolls the world
							-- 4px per FRAME. `GAIT_PX` is per tick and the camera is per frame, and
							-- those are not the same number.
							--
							-- So flooring the budget at the peer's stride moved a STANDING peer 8px
							-- on a frame the world moved 4: the ghost races ahead and is pulled
							-- back, every camera frame. That is the glide, and the floor I added
							-- earlier today to fix the opposite problem is what guarantees it at
							-- turbo. Both clamps were wrong for the same underlying reason -- one
							-- number was covering two different quantities.
							--
							-- The world moving under a peer is the camera's delta, exactly, whatever
							-- the peer's gait. The peer's own locomotion is bounded by its stride,
							-- and only exists while it is stepping. Hence the condition: a moving
							-- peer still gets its stride as a floor (that is what fixed the walker
							-- watched from a bike), a stationary one tracks the camera and nothing
							-- else. The user's discriminator says this is the axis -- walking,
							-- running and the ordinary bike all look right, only turbo does not,
							-- and turbo is the only gait whose per-tick stride exceeds the camera's
							-- per-frame delta.
							if o.walking and budget < stride then
								budget = stride
							end
						elseif mgap >= 2 then
							-- NEVER FASTER THAN THE GAME'S OWN WALK. (2026-08-23, the shipped-250ms
							-- case.) This is the camera-parked fallback, and the camera only parks
							-- for eight frames once the PLAYER has stopped -- so this 4px catch-up
							-- could never fire mid-walk, and fired every time the player came to
							-- rest. It was not a repayment spread over a walk; it was a debt dumped
							-- at the end of one, at exactly double the walker's 2px. The user, at
							-- shipped settings: *"the drawn ghost is snapping towards its last
							-- target tile whenever the player stop"* -- with the same rig clean at
							-- `-interp=0ms`, because with no wire delay there is no debt to repay.
							--
							-- A ghost a quarter second behind SHOULD still be walking a quarter
							-- second after the player stops. Doing that at the engine's own pace is
							-- 1:1; covering the same ground at double pace is a ghost doing what no
							-- player can. Constant lag is invisible on screen and a change of SPEED
							-- is not, so trading the first for the second was never a good trade.
							--
							-- Measured before it was changed: 85 frames in one run took this branch
							-- with catch-up armed, and `0 resyncs` ruled out both snap-to-tile
							-- paths, leaving this as the only code that can move the model faster
							-- than a walk. `catchup` still arms and still counts, so the walk-side
							-- bleed it was built to repay stays visible on the MODEL walk line; if
							-- the backward glide returns, the fix belongs on the walking side (the
							-- 12/6 arming band), not in a burst at the end.
							-- The engine's own pace FOR THIS GAIT. The reasoning above -- that
							-- covering ground faster than the game's own walk is a ghost doing what
							-- no player can -- is about the WALK's 2px, and on a bike the engine's
							-- own pace is 4px. Hard-coding the walker's number made the model fall
							-- behind on every bike step the camera did not clock, which is what a
							-- turn on the spot is: the user, 2026-08-25, on the two copies drifting
							-- apart *"while moving around on the bike... like turning around on
							-- it"*.
							budget = stride
							if o.catchup and COMPARE_TIERS then
								facingFrames.freeCatchup = (facingFrames.freeCatchup or 0) + 1
							end
						end
						o.dbgState = facingFrames.stats() and string.format("cam=%d gap=%d bud=%d step=%d dist=%d,%d cu=%s",
							facingFrames.camDelta or 0, mgap, budget, o.stepLeft or 0,
							qx - o.modelX, qy - o.modelY, tostring(o.catchup or false)) or o.dbgState
						for _ = 1, 2 do
							if budget <= 0 then break end
							if (o.stepLeft or 0) == 0 then
								decideBoundary()
								if (o.stepLeft or 0) == 0 then break end
							end
							local mv = budget
							if mv > o.stepLeft then mv = o.stepLeft end
							o.modelX = o.modelX + (o.stepDX or 0) * mv
							o.modelY = o.modelY + (o.stepDY or 0) * mv
							o.stepLeft = o.stepLeft - mv
							budget = budget - mv
							if o.catchup and COMPARE_TIERS then
								facingFrames.catchupFrames = (facingFrames.catchupFrames or 0) + 1
							end
							-- The legs read this. Position and pose come off ONE clock, and this
							-- is the tick of that clock.
							o.modelMovedAt = drawFrames
						end
					end
				end
			elseif math.abs(o.modelX - tX) > 24 or math.abs(o.modelY - tY) > 24 then
				-- COUNTED UNCONDITIONALLY, and the gate that used to be here is the reason this
				-- resync has never been measured. It only incremented under COMPARE_TIERS -- a rig
				-- that renders a second copy of the peer and therefore cannot be switched on to
				-- investigate how the FIRST one looks. So the one number that says whether this
				-- branch fires was unavailable in every session that cared. One increment.
				--
				-- WHY IT IS THE SUSPECT FOR THE TURBO BIKE. 24px is three frames of an 8px gait and
				-- twelve of a 2px walk, so a threshold that was effectively unreachable at walking
				-- pace becomes routine at the Archipelago build's fourth gait -- and this branch
				-- does not ease the model anywhere, it assigns. That is a snap by construction.
				-- The user, 2026-08-26, with the gliding already fixed: *"still gliding/snapping a
				-- bit when using turbo mode on the bike"*.
				--
				-- NOT RAISED, NOT TUNED. The threshold is not the thing to change on a hunch -- it
				-- exists to recover a model that has genuinely lost its peer, and widening it just
				-- makes the recovery later and larger. Measure whether it fires first.
				facingFrames.modelSnaps = (facingFrames.modelSnaps or 0) + 1
				facingFrames.modelSnapPx = math.max(facingFrames.modelSnapPx or 0,
					math.max(math.abs(o.modelX - tX), math.abs(o.modelY - tY)))
				o.modelX, o.modelY = tX, tY
			else
				-- TWO PIXELS ON EVERY OTHER FRAME, because that is the engine's own quantum and
				-- not a rate chosen to make something look better.
				--
				-- Measured 2026-08-23, after a 1px-per-frame model had already fixed the left and
				-- right axes: the background scroll moves 0, 2 or 4 pixels and NEVER 1, and the
				-- player's sprite does not move at all (the world scrolls past a fixed sprite).
				-- There is no odd pixel anywhere to find. A tile is 8 ticks of 2px, which is what
				-- `stepProgress`'s `(8 - STEP_DURATION) * 2` has been saying all along -- it is not
				-- a lossy reading of a finer value, it is the value.
				--
				-- So a 1px-per-frame ghost is SMOOTHER THAN THE GAME, which fails the bar from the
				-- other side: the player steps and the ghost glides. Matching the quantum makes
				-- both sides of the subtraction move in the same units, which is the only way the
				-- difference between them can be still.
				--
				-- ON THE ENGINE'S TICK, NOT AN ARBITRARY ONE. This was `emu.framecount() % 2 == 0`,
				-- and that is the whole difference between a ghost that walks beside the player and
				-- one that shakes.
				--
				-- The engine moves the world 2px every OTHER frame. Which frame is not ours to
				-- pick: if the ghost moves on the frames the player does not, then RELATIVE to the
				-- player it shifts 2px on every single frame, and a ghost is always seen relative to
				-- the player because the camera is locked to them. That reads on screen as a
                -- constant shake, and -- the trap -- it reads in a histogram of painted movement as
				-- a beautifully uniform "2px every frame". The user saw it immediately
				-- (*"left/right also looks the same/bad"*) while the numbers said the stutter was
				-- gone. The metrics were the suspect and the metrics were wrong.
				--
				-- The engine's tick is observable: the player's own step progress advances on it.
				-- The parity is LATCHED, because a standing player has no ticks to observe and the
				-- ghost still has to walk; the last observed phase is the right guess and it is
				-- corrected the moment the player moves again.
				local moveThisFrame = (emu.framecount() % 2) == (facingFrames.tickParity or 0)
				if moveThisFrame then
					local dx, dy = tX - o.modelX, tY - o.modelY
					local sx2 = (dx > 0 and 2) or (dx < 0 and -2) or 0
					local sy2 = (dy > 0 and 2) or (dy < 0 and -2) or 0
					-- Never overshoot: the last hop of a step can be a single pixel if a resync or
					-- an odd starting offset left the model off the 2px grid.
					if math.abs(dx) < 2 then sx2 = dx end
					if math.abs(dy) < 2 then sy2 = dy end
					o.modelX, o.modelY = o.modelX + sx2, o.modelY + sy2
				end
			end
			local gx = o.modelX - pTile.x * 16
			local gy = o.modelY - pTile.y * 16

			-- THE STRIDE COMES FROM THE SAME SMOOTH QUANTITY THE POSITION DOES.
			--
			-- The walk cycle is chosen by how far into its step the peer is, and that was read from
			-- `extras.prog` -- which the core does NOT interpolate, because `extras` is opaque by
			-- contract. So once the POSITION became smooth, the peer glided while its legs were
			-- still being driven by a stale, jumpy value: the stepping-frame band triggered
			-- erratically and the cycle flickered. The user: one tile *"looks fine"*, walking
			-- continuously *"still looks a bit fast/jittery"* -- which is what an animation running
			-- off a different clock from the body looks like.
			--
			-- The progress is already in the interpolated position: the peer's tile names its
			-- DESTINATION, so how far short of it the peer is IS the progress. Derived rather than
			-- sent, so there is nothing new on the wire and nothing that can disagree with the
			-- position it is drawn at.
			-- ...and it comes from the MODEL now, so the legs and the body run off one clock.
			--
			-- AS A DISTANCE, not as a signed offset. The previous form was `16 + (pixX - x*16)`,
			-- which is only correct when the peer is moving in the direction that makes that
			-- difference negative -- right and down. Walking LEFT the destination tile is the
			-- smaller number, so the term is positive all the way through the step, the progress
			-- pins at 16 for its whole duration, and 16 is inside the stepping band: the ghost
			-- holds one stepping image for the entire step instead of running a cycle. Left and up
			-- had been getting a different animation from right and down, from one sign.
			--
			-- How far is left to go is the same quantity in all four directions, so there is no
			-- sign to get wrong.
			-- ASSIGNED, not declared. This was `local stepProg = ...` and nothing ever read it --
			-- a dead local sitting under a comment explaining why the stride had to come from the
			-- same quantity as the body. Everything downstream (the stepping band, the frame
			-- picker, the counters) went on reading the raw `extras.prog`, which is the value the
			-- comment says was the problem. Lua reports neither the dead local nor the unread
			-- intention; only reading the uses does.
			-- FROM DISTANCE TRAVELLED, not from distance remaining to a destination that moves.
			--
			-- User, 2026-08-23: *"still look jittery/weird choppy animation speeds while moving
			-- around"* -- said at a point where every positional instrument was clean (0 and 2px
			-- only, no 4px in any direction, no resyncs). The complaint was the LEGS, and position
			-- probes are blind to those.
			--
			-- The evidence was in a histogram already being printed. Progress counts across a run:
			-- `0:134 2:166 4:220 6:224 8:228 10:224 12:212 14:114 16:64`. A step that runs cleanly
			-- from 0 to 16 visits every value about equally; the end of the step was showing up
			-- three times less often than the middle. The destination tile advances when the PEER
			-- starts its next step, and the model -- which tracks the interpolated position, a
			-- little behind that -- had its remaining distance reset to 16 before it ever counted
			-- down to 0. So the walk cycle was restarted a few pixels early, every step, and the
			-- last images of the cycle were mostly never drawn.
			--
			-- Distance travelled has no such dependency: a character's legs are a function of how
			-- far it has moved, and the model's own position modulo the tile grid gives exactly
			-- that -- it cycles 0..14 continuously no matter when the destination changes hands.
			-- Measured on the axis of travel only, so that a residual pixel on the perpendicular
			-- axis (after a turn, or a correction) cannot leak into the walk cycle and hold it.
			-- THE AXIS COMES FROM WHERE THE GHOST IS GOING, not from the facing it reports.
			--
			-- Reading it off `o.facing` means one flickering frame of orientation on the wire
			-- switches which coordinate measures progress, and the walk cycle jumps to an unrelated
			-- value for that frame. The cadence trace showed exactly that shape once the position
			-- was clean: the player alternating a tidy eight frames on, eight off, and the ghost
			-- doing `UUUuUUUU` and `LLllllllllLl` -- single-frame dropouts inside an otherwise
			-- correct burst, which is what "choppy" looks like when it is one frame wide.
			--
			-- The destination says the axis without consulting anything that can flicker, and it is
			-- held when the ghost is between steps so that a stationary frame does not reset it.
			if tX ~= o.modelX then
				o.progAxis = "x"
			elseif tY ~= o.modelY then
				o.progAxis = "y"
			end
			local along = (o.progAxis == "x") and o.modelX or o.modelY
			peerProg = math.floor(along) % 16
			-- Up and left travel towards SMALLER coordinates, so their progress through a tile runs
			-- the other way. Without this the cycle plays backwards in two of the four directions.
			if o.facing == 1 or o.facing == 2 then
				peerProg = (16 - peerProg) % 16
			end
			sx = math.floor((aged.oamX or playerOamX) - 8 + gx - ppx + 0.5)
			sy = math.floor((aged.oamY or playerOamY) - 16 + gy - ppy + 0.5)

			-- PAINT AGAINST THE CAMERA ITSELF, not against tile+progress. (2026-08-23, and it is
			-- the last seam.) The formula above derives the screen origin from the player's tile
			-- and step progress -- two values that hand over on DIFFERENT frames at every step
			-- boundary. The old renderer's ghost term came from the same machinery, so the seams
			-- cancelled inside each character; the model's term has no seam, so the reference's
			-- showed alone: a -2/+2 pair at every tile, named column-exact by the six-line
			-- cadence trace (model mirroring the camera perfectly, screen still marking).
			--
			-- The camera's true position is readable, accumulated above from the scroll register
			-- the screen is actually moved by. Ghost screen position = model - camera + K, one
			-- coordinate frame, all integers. K is unknowable a priori (the accumulator has no
			-- absolute origin) but constant, so it is CALIBRATED from the tile formula whenever
			-- the camera has been parked half a second -- the one state where that formula has no
			-- seam to mis-align -- and recalibrates itself after every map change the same way.
			-- ...WITH THE REGISTER'S SIGNS MEASURED, NOT ASSUMED. The first version of this
			-- subtracted both axes and sent every ghost off the screen within minutes -- the
			-- assumption had only ever been checked as magnitudes. One instrumented lap gave the
			-- convention per direction (2026-08-23, `CAMERA signs by walk dir` in the log):
			-- walking right/left moves the X register +2/-2 while walking down/up moves the Y
			-- register -2/+2. **That lap's CONCLUSION -- "X matches map pixels, Y is inverted, so
			-- the axes are treated differently" -- WAS WRONG, and the block below says why**: the
			-- instrument's direction string was mislabelled, so every left/right reading was
			-- swapped. Both registers run inverted, the paint adds `camA` on both axes, and there
			-- is no axis asymmetry to look for. Left here because the refuted version is the
			-- intuitive one and will be re-derived by anyone who measures magnitudes only.
			-- K has no absolute origin, so it is calibrated from the tile formula
			-- whenever the camera has been parked half a second -- the one state where that
			-- formula has no seam -- which also re-calibrates it after every map change.
			if o.modelX then
				-- BOTH registers run inverted to map pixels, X exactly as Y. The sign map first
				-- said X matched -- because the instrument's direction string was "durl" where the
				-- adapter's order is down/up/LEFT/RIGHT, so every left/right label was swapped and
				-- the X conclusion inverted with it. The numeric dump settled it beyond labels:
				-- walking left, modelX + camAX held constant (196,196,196,196) while
				-- modelX - camAX raced. One character of a debug string cost one full wrong paint.
				-- ONE FORMULA, ALWAYS. K MOVES; THE PAINT DOES NOT SWITCH SOURCE.
				--
				-- This used to CALIBRATE while the camera was parked and PAINT from the camera only
				-- while it moved -- an `if`/`elseif`, so the painted position changed which formula
				-- produced it on the exact frame the camera went still. That frame is the one the
				-- player is looking at when they stop, and the two formulas do not agree: the tile
				-- one is anchored to the player's tile and step progress, the camera one to the
				-- scroll accumulator, and between two parks they drift apart by the walk-side
				-- bleed. Whatever they had drifted apart by was paid in a single frame, as a jump.
				--
				-- That is the SECOND cause of the end-of-walk snap, and the reason capping the
				-- catch-up (above) only made it intermittent instead of curing it: the two are
				-- independent, both fire when the camera parks, and the survivor's size depends on
				-- accumulated drift, so it shows on some walks and not others. The user, after the
				-- first fix: *"the drawn ghost is still doing the weird ending snap, but just
				-- sometimes"* -- and "sometimes" is the tell that a magnitude, not a trigger, is
				-- what varies.
				--
				-- So the paint is now the camera formula on every frame, and the park only nudges K
				-- toward what the tile formula says -- one pixel per frame. K is meant to be a
				-- CONSTANT; a correction to it is an admission of accumulated error, and paying
				-- that back a pixel at a time while the player stands still is invisible, where
				-- paying it in one frame is exactly the artefact being chased.
				--
				-- A big disagreement is not drift and must not be crawled: a map change or a warp
				-- moves the camera's origin wholesale, K is meaningless across it, and a jump there
				-- is correct. Sixteen pixels -- one tile -- separates the two cases.
				if (facingFrames.camStillFor or 0) >= 8 then
					local wantKX = sx - o.modelX - (facingFrames.camAX or 0)
					local wantKY = sy - o.modelY - (facingFrames.camAY or 0)
					if not facingFrames.camKX then
						facingFrames.camKX, facingFrames.camKY = wantKX, wantKY
					else
						local ddx = wantKX - facingFrames.camKX
						local ddy = wantKY - facingFrames.camKY
						-- IS THE TARGET STANDING STILL? By algebra `wantK` is entirely player-side
						-- (`oamX - 8 - pTile.x*16 - ppx - camAX`, with `modelX` cancelling), so
						-- while the camera is parked it MUST be constant and K must converge within
						-- as many frames as it has pixels to travel. The run says otherwise: 158
						-- nudge frames against 21px of park-entry drift, with only 3 reversals --
						-- steady chasing, not oscillation. So either the cancellation is not exact
						-- (`sx` is floored while `o.modelX` is subtracted unrounded, so a FRACTIONAL
						-- model position leaves a residue that moves as the ghost free-runs), or a
						-- term assumed constant is not. This counts both, and `kFrac` separates them.
						-- CORRECT K ONLY AGAINST A REFERENCE THAT HAS SETTLED. (2026-08-23.)
						--
						-- "The camera has been parked 8 frames" was standing in for "the player has
						-- stopped", and it is not the same thing: the per-term counter below caught
						-- the target moving on 54 parked frames, of which 27 were the player's STEP
						-- PROGRESS still advancing and 6 the player's TILE handing over. The camera
						-- register goes quiet for a beat at the start of a step before it begins
						-- scrolling, so this branch runs over the opening frames of a new walk with
						-- `camStillFor` still high from the previous stop -- and nudges K toward a
						-- reference that is mid-handover. K is supposed to be a CONSTANT, so every
						-- such nudge is a corruption injected at a walk's start and paid back as
						-- visible motion at its end. That is the "jitter right before stopping".
						--
						-- The guard is the invariant itself rather than another proxy: only correct
						-- on a frame where the target is IDENTICAL to the previous frame's. A proxy
						-- ("player not walking") is one more flag that can be stale at exactly the
						-- handover being guarded against; equality of the thing being chased cannot
						-- be. One settled frame is all it costs, and parks last far longer.
						local stable = (facingFrames.kWantX == wantKX
							and facingFrames.kWantY == wantKY)
						facingFrames.kStable = stable
						-- HOW LONG it has been stable, because two frames of equality is not
						-- settled. KSETTLE (2026-08-25, the bike lap): at EVERY park the target
						-- sat exactly 3px off at stillness 8 and was back to true by 16, with all
						-- three run deltas zero -- a transient of at most 8 frames, plateau-shaped,
						-- so it PASSES a two-frame equality check and the nudge chased it down and
						-- back at every stop (24px repaid against 12px of drift, ~2 nudge
						-- reversals per park -- the 2:1 signature). That chase was the user's
						-- *"drift from their current tile"*: 3px out and 3px back at every park.
						-- Eight frames of sustained equality outlasts the measured transient, and
						-- parks last hundreds of frames, so real drift still gets repaid in full.
						facingFrames.kStableFor = stable and ((facingFrames.kStableFor or 0) + 1) or 0
						-- OUTSIDE the probe guard, deliberately. `stable` is now SHIPPED behaviour,
						-- so the state it compares against has to advance whether or not the probe
						-- is on -- inside the guard, a build with COMPARE_TIERS off would find
						-- `kWantX` frozen at nil, `stable` false forever, and K never corrected at
						-- all. That is the "a flag that gates the decision but not the work" trap
						-- this project has already been bitten by, arriving from the other side.
						facingFrames.kWantX, facingFrames.kWantY = wantKX, wantKY
						if facingFrames.stats() then
							if facingFrames.kWantPrev and not stable then
								facingFrames.kWantMoves = (facingFrames.kWantMoves or 0) + 1
							end
							facingFrames.kWantPrev = true
							-- WHICH TERM IS MOVING? `wantKX = oamX - 8 - pTile.x*16 - ppx - camAX`,
							-- and while the camera is parked `camAX` cannot change (a camera move
							-- resets `camStillFor` and this whole branch stops running). `modelX`
							-- cancels and is never fractional (measured). So a moving target has to
							-- be the player's own OAM position, tile, or step progress -- all three
							-- of which are supposed to be settled once the player has stopped.
							-- Counted separately because they fail for different reasons: `oamX` is
							-- read out of OAM, where the adapter's OWN drawn ghost also lives.
							local cOam = (aged.oamX or playerOamX)
							if facingFrames.kTOam and cOam ~= facingFrames.kTOam then
								facingFrames.kTOamN = (facingFrames.kTOamN or 0) + 1
							end
							if facingFrames.kTTile and pTile.x ~= facingFrames.kTTile then
								facingFrames.kTTileN = (facingFrames.kTTileN or 0) + 1
							end
							if facingFrames.kTPpx and ppx ~= facingFrames.kTPpx then
								facingFrames.kTPpxN = (facingFrames.kTPpxN or 0) + 1
							end
							if facingFrames.kTCam and (facingFrames.camAX or 0) ~= facingFrames.kTCam then
								facingFrames.kTCamN = (facingFrames.kTCamN or 0) + 1
							end
							facingFrames.kTOam, facingFrames.kTTile = cOam, pTile.x
							facingFrames.kTPpx, facingFrames.kTCam = ppx, (facingFrames.camAX or 0)
							if o.modelX % 1 ~= 0 or o.modelY % 1 ~= 0 then
								facingFrames.kFrac = (facingFrames.kFrac or 0) + 1
							end
						end
						-- THE DRIFT A WALK ACTUALLY PRODUCED, sampled ONCE per park.
						--
						-- `camStillFor` counts still camera frames and is reset to 0 by any camera
						-- move, so it passes through exactly 8 once per park -- the first frame this
						-- branch runs after a walk. K has not been touched since the previous park,
						-- so `ddx`/`ddy` on that frame ARE the disagreement the whole walk built up.
						-- That is the bleed, measured directly, instead of inferred from how much
						-- repayment work the nudge below did (see the counter note there).
						--
						-- Stamped by frame because this block is inside the per-peer draw loop and
						-- `facingFrames` is shared: two drawn peers would otherwise count one park
						-- twice.
						-- HOW dd EVOLVES ACROSS THE PARK (2026-08-25). KPARK caught dd=-3 at
						-- every entry with ALL run deltas zero -- so nothing leaks during the run,
						-- and the -3 must be a transient in the reference that later resolves
						-- (the nudge chasing it down and back is exactly the 2:1 repaid-to-drift
						-- ratio on the MODEL line). This prints dd at stillness 8..64 in steps of
						-- 8; if it decays to 0 on its own the fix is to WAIT, not to repay.
						-- Silent while healthy (the fix landed 2026-08-25 and a verification lap
						-- read 0,0 at every sample): it speaks again only if a park is entered
						-- with a nonzero disagreement, which is the regression this watches for.
						if COMPARE_TIERS and (ddx ~= 0 or ddy ~= 0)
							and (facingFrames.camStillFor or 0) >= 8
							and (facingFrames.camStillFor or 0) <= 64
							and (facingFrames.camStillFor % 8) == 0
							and facingFrames.kSettleAt ~= drawFrames then
							facingFrames.kSettleAt = drawFrames
							logFile(string.format("  KSETTLE f%d still=%d dd=%d,%d",
								drawFrames, facingFrames.camStillFor, ddx, ddy))
						end
						-- Sampled at 16, not 8: KSETTLE showed the reference settles between
						-- stillness 8 and 16, so a sample at 8 measured the TRANSIENT and called
						-- it the walk's bleed. At 16 it measures what the walk actually left.
						if COMPARE_TIERS and (facingFrames.camStillFor or 0) == 16
							and facingFrames.kParkAt ~= drawFrames then
							facingFrames.kParkAt = drawFrames
							local d = math.abs(ddx) + math.abs(ddy)
							facingFrames.kParks = (facingFrames.kParks or 0) + 1
							facingFrames.kParkSum = (facingFrames.kParkSum or 0) + d
							if d > (facingFrames.kParkMax or 0) then facingFrames.kParkMax = d end
							-- PER DIRECTION, because the user's report is directional: the jitter is
							-- on the DOWN leg's stop and nowhere else (2026-08-23). A total cannot
							-- test that claim -- if down's parks carry the drift and the other three
							-- do not, the cause is something the down direction does differently
							-- (sign convention, the progress reversal, which axis the camera moves),
							-- and if all four are equal the direction is a coincidence of where the
							-- walk/stop phase happens to place a mid-leg stop.
							-- DECOMPOSE THE RUN, one line per park (2026-08-25, the bike session).
							-- The identity is ddx = Δtarget - Δmodel - ΔcamA since the previous
							-- park (K untouched between parks, by construction). For a loopback
							-- peer the target's screen position is the same at every park, the
							-- model walks +16 per tile and camA scrolls -16 per tile -- so each
							-- delta has a predicted value, and the term whose delta is OFF its
							-- prediction is the term that carries the park drift. A total like
							-- kParkSum can say HOW MUCH bleeds per park; only this can say WHO.
							local tgtX = wantKX + o.modelX + (facingFrames.camAX or 0)
							local tgtY = wantKY + o.modelY + (facingFrames.camAY or 0)
							if facingFrames.kRunTgtX then
								logFile(string.format(
									"  KPARK f%d dir=%s dd=%d,%d run: target=%d,%d model=%d,%d camA=%d,%d",
									drawFrames, DIR_NAMES.letter[pDir] or "?", ddx, ddy,
									tgtX - facingFrames.kRunTgtX, tgtY - facingFrames.kRunTgtY,
									o.modelX - facingFrames.kRunModX, o.modelY - facingFrames.kRunModY,
									(facingFrames.camAX or 0) - facingFrames.kRunCamX,
									(facingFrames.camAY or 0) - facingFrames.kRunCamY))
							end
							facingFrames.kRunTgtX, facingFrames.kRunTgtY = tgtX, tgtY
							facingFrames.kRunModX, facingFrames.kRunModY = o.modelX, o.modelY
							facingFrames.kRunCamX = facingFrames.camAX or 0
							facingFrames.kRunCamY = facingFrames.camAY or 0
							local dl = DIR_NAMES.letter[pDir] or "?"
							facingFrames.kParkDir = facingFrames.kParkDir or {}
							local b = facingFrames.kParkDir[dl] or { n = 0, sum = 0, max = 0 }
							b.n, b.sum = b.n + 1, b.sum + d
							if d > b.max then b.max = d end
							facingFrames.kParkDir[dl] = b
						end
						-- A DEADBAND, AND 2px STEPS, BECAUSE 1px DOES NOT EXIST IN THIS GAME.
						--
						-- The first version of this repaid drift a pixel at a time and the user saw
						-- it: *"it made a small jitter at some stops now"*. That is the trap this
						-- file already documents from the other direction -- the background scroll
						-- moves 0, 2 or 4 pixels and NEVER 1, so a ghost that moves 1px is SMOOTHER
						-- THAN THE GAME and reads as shimmer rather than as motion. A correction is
						-- still motion; it does not get its own units.
						--
						-- The deadband matters more than the step size. K being slightly wrong is a
						-- CONSTANT offset in the painted position, and a constant offset is
						-- invisible -- the ghost simply sits a pixel or two off, forever, and
						-- nobody can see it against a moving world. Correcting it is a CHANGE, and
						-- changes are what the eye catches. So small disagreements are now left
						-- alone entirely: after the handover fix above, the worst park measured 2px,
						-- which is inside the band and costs nothing to ignore.
						--
						-- Four pixels is the threshold because 2px is one engine tick and would
						-- re-trigger forever on the ordinary jitter of the two formulas; 4px is
						-- real drift, and is repaid in 2px units that look like an ordinary step.
						if math.abs(ddx) > 16 or math.abs(ddy) > 16 then
							facingFrames.camKX, facingFrames.camKY = wantKX, wantKY
						elseif o.modelMovedAt ~= drawFrames
							and (facingFrames.kStableFor or 0) >= 8 then
							-- ON THE MODEL'S OFF-FRAMES, ONE PIXEL AT A TIME. Two better-sounding rules
							-- were tried against the user's eyes and both were worse; the trail is kept
							-- because each is the obvious next idea.
							--
							-- A DEADBAND (ignore drift under 4px, on the theory that a constant offset is
							-- invisible and only CHANGES are seen). The theory is right and the rule is
							-- not: with repayment switched off below the band, drift simply walked up to
							-- 16px per park -- the snap threshold -- instead of staying at the 2px this
							-- rule holds it to. The drift is continuous, so the repayment has to be too.
							--
							-- WAITING FOR ARRIVAL, then repaying 2px on the engine's tick (so the ghost's
							-- final approach is untouched and the correction is an engine-sized step).
							-- The user: *"now its overshooting, and then gliding back ... added a snap to
							-- every single stop"*. Two pixels is coarser than the drift it chases, so it
							-- overshoots and is dragged back, and paying a whole park's debt in a burst
							-- after arrival is a snap by construction -- the same fault as the original,
							-- moved later in time. Repaying continuously and finely is what makes it
							-- invisible; the size of each correction is the thing that must stay small.
							--
							-- What survives: the paint never switches formula (that was the 14px snap),
							-- and K is nudged 1px only on a frame the model itself did not move, so the
							-- painted position can never advance faster than the engine's walk. The
							-- residue is the user's *"jitter right before stopping"* -- real, small, and
							-- NOT to be chased with a bigger correction. Its cause is upstream, in the
							-- disagreement between the camera accumulator and the player tile+progress
							-- formula -- and HOW BIG that disagreement is, is now measured honestly by
							-- `kParkSum`/`kParks` above rather than inferred from this counter, which
							-- used to inflate it quadratically. Read the new numbers before theorising
							-- about the size or the shape of the bleed. `unverified.md`.
							if ddx ~= 0 then
								facingFrames.camKX = facingFrames.camKX + (ddx > 0 and 1 or -1)
							end
							if ddy ~= 0 then
								facingFrames.camKY = facingFrames.camKY + (ddy > 0 and 1 or -1)
							end
							if COMPARE_TIERS and (ddx ~= 0 or ddy ~= 0) then
								-- PIXELS ACTUALLY REPAID: one per axis per nudge frame, which is
								-- exactly what the two lines above move.
								--
								-- This counter used to add the whole REMAINING disagreement every
								-- nudge frame while repaying 1px of it, so one 14px park scored
								-- 14+13+...+1 = 105. The inflation is quadratic in the drift, and
								-- the "206px repaid against only 5 camera rebases" reading that
								-- concluded a continuous bleed exists was built on it -- 206 is
								-- what a couple of ordinary parks produce under the old sum, not
								-- 206px of anything. Found 2026-08-23 by reading the counter, not
								-- by running it: a measurement whose units were never checked.
								-- `kParkSum` above is the honest total.
								facingFrames.kFix = (facingFrames.kFix or 0)
									+ (ddx ~= 0 and 1 or 0) + (ddy ~= 0 and 1 or 0)
								-- How many frames the repayment was busy for. Paired with the pixel
								-- count it says whether the nudge is keeping up: a park's drift
								-- should clear in about as many frames as it has pixels, and a
								-- nudge count far larger than the drift means it is chasing
								-- something that keeps coming back rather than paying a debt down.
								facingFrames.kNudges = (facingFrames.kNudges or 0) + 1
								-- IS IT PAYING A DEBT, OR OSCILLATING? The two are indistinguishable
								-- in a total: 53px of drift repaid over 411 nudge frames is either a
								-- slow corrector or a fast one that keeps undoing itself, and those
								-- want opposite fixes. A reversal counter tells them apart with no
								-- ambiguity -- paying down a real debt is one sign until it lands,
								-- so reversals should be at most one per park.
								--
								-- Suspected mechanism if this comes back high: `sx` is floored while
								-- `o.modelX` is subtracted unrounded, so `ddx` carries a sub-pixel
								-- residue, and the nudge has no deadband whatsoever (`ddx ~= 0`).
								-- Half a pixel of permanent residue is enough to toggle forever.
								local sgx = (ddx > 0) and 1 or ((ddx < 0) and -1 or 0)
								local sgy = (ddy > 0) and 1 or ((ddy < 0) and -1 or 0)
								if sgx ~= 0 and facingFrames.kSgX and sgx ~= facingFrames.kSgX then
									facingFrames.kFlips = (facingFrames.kFlips or 0) + 1
								end
								if sgy ~= 0 and facingFrames.kSgY and sgy ~= facingFrames.kSgY then
									facingFrames.kFlips = (facingFrames.kFlips or 0) + 1
								end
								if sgx ~= 0 then facingFrames.kSgX = sgx end
								if sgy ~= 0 then facingFrames.kSgY = sgy end
							end
						end
					end
				end
				if facingFrames.camKX then
					sx = math.floor(o.modelX + (facingFrames.camAX or 0) + facingFrames.camKX + 0.5)
					sy = math.floor(o.modelY + (facingFrames.camAY or 0) + facingFrames.camKY + 0.5)
					-- RAW NUMBERS, because the symbol-pushing has been wrong twice: every value in
					-- the sum, every 15 frames, while this peer walks. Whatever term drifts, drifts
					-- in plain sight.
					-- EVENT-TRIGGERED: whenever the painted position jumps 2px or more against
					-- the previous frame, dump the model state OF THAT FRAME -- the sampling probe
					-- averaged over 15 frames and could not see the mechanism of a 1-frame event.
					if facingFrames.stats() and o.only == "drawn" then
						local jump = facingFrames.kLastSX
							and (math.abs(sx - facingFrames.kLastSX) >= 2
								or math.abs(sy - facingFrames.kLastSY) >= 2)
						if jump then
							logFile(string.format("  KJUMP f%d dsx=%d dsy=%d %s",
								drawFrames, sx - facingFrames.kLastSX, sy - facingFrames.kLastSY,
								o.dbgState or "?"))
						end
						facingFrames.kLastSX, facingFrames.kLastSY = sx, sy
					end
				end
			end

			-- WHICH HALF OF THE SUM IS JUMPING. The painted position is the ghost's own motion
			-- (`gy`) plus a PLAYER REFERENCE (`oamY - ppy`), and after the cadence rework the
			-- horizontal axis came out clean while the vertical still showed 3px steps -- 13 of
			-- them walking down, against one 2px step walking left. The two axes run identical
			-- code, so the difference has to be in the values, and a histogram of the finished
			-- position cannot say which term carried it. These two can: `gy` is 0 or 1 by
			-- construction now, so anything above that in the reference is the player side.
			if facingFrames.stats() and o.only == "drawn" then
				local refY = (aged.oamY or playerOamY) - ppy
				local refX = (aged.oamX or playerOamX) - ppx
				if facingFrames.lastRefY then
					facingFrames.refD = facingFrames.refD or {}
					facingFrames.ghostD = facingFrames.ghostD or {}
					local vertical = (o.facing == 0 or o.facing == 1)
					local rd = math.floor(math.abs((vertical and refY or refX)
						- (vertical and facingFrames.lastRefY or facingFrames.lastRefX)) + 0.5)
					local gd = math.floor(math.abs((vertical and gy or gx)
						- (vertical and facingFrames.lastGY or facingFrames.lastGX)) + 0.5)
					local key = (vertical and "v" or "h")
					facingFrames.refD[key] = facingFrames.refD[key] or {}
					facingFrames.ghostD[key] = facingFrames.ghostD[key] or {}
					if rd > 6 then rd = 6 end
					if gd > 6 then gd = 6 end
					facingFrames.refD[key][rd] = (facingFrames.refD[key][rd] or 0) + 1
					facingFrames.ghostD[key][gd] = (facingFrames.ghostD[key][gd] or 0) + 1
				end
				-- ON `facingFrames`, NOT ON `o`. The peer entry is rebuilt from scratch every time a
				-- state message arrives, which is every frame, so a previous value parked on it is
				-- nil by the time the next frame reads it -- the trap this file already warns about
				-- two hundred lines down, walked into anyway. It cost one live run: the instrument
				-- printed nothing at all, which at least fails loudly rather than reading zero.
				facingFrames.lastRefY, facingFrames.lastRefX = refY, refX
				facingFrames.lastGY, facingFrames.lastGX = gy, gx
				-- WHERE THE ODD PIXEL LIVES. `stepProgress` is `(8 - STEP_DURATION) * 2`, so it can
				-- only ever be even -- 8 ticks for a tile the character crosses in 16 frames. The
				-- pixels in between are on screen and are not in that value, which is why the
				-- player reference moves 0,2,0,2 and never 1.
				--
				-- Two candidates carry 1px resolution and both are already read by this adapter:
				-- the background scroll registers, and the player's own OAM Y. Which one actually
				-- advances every frame is a question about a running game, so it is measured here
				-- rather than assumed -- no address or behaviour from memory (`CLAUDE.md`).
				local scr = u8(W_BGMAPOFFSETY)
				local oy = playerOamY
				if scr and facingFrames.lastScroll then
					local sd = math.abs(scr - facingFrames.lastScroll)
					if sd > 6 then sd = 6 end
					facingFrames.scrollD = facingFrames.scrollD or {}
					facingFrames.scrollD[sd] = (facingFrames.scrollD[sd] or 0) + 1
				end
				if oy and facingFrames.lastOamY then
					local od = math.abs(oy - facingFrames.lastOamY)
					if od > 6 then od = 6 end
					facingFrames.oamD = facingFrames.oamD or {}
					facingFrames.oamD[od] = (facingFrames.oamD[od] or 0) + 1
				end
				facingFrames.lastScroll, facingFrames.lastOamY = scr, oy
			end

			local onScreen = sx > -16 and sx < 160 and sy > -16 and sy < 144
			if not onScreen then
				nOffScreen = nOffScreen + 1
				if COMPARE_TIERS and drawFrames % 60 == 0 then
					logFile(string.format("  copy %-28s OFF SCREEN at screen %d,%d (map %d,%d)",
						id, sx, sy, o.x, o.y))
				end
				if not offSample then
					offSample = string.format("%s at map %d,%d -> screen %d,%d (window %d,%d)",
						id, o.x, o.y, sx, sy, u8(W_XCOORD) or 0, u8(W_YCOORD) or 0)
				end
			end
			if onScreen then
				local hidden = false
				-- The text box occupies the bottom six rows at full width, always.
				if boxOpen and sy + 16 > TEXTBOX.row * 8 then
					hidden = true
				end
				if uiOpen and lastMenuBox then
					-- ANY live rectangle hides -- see the list's construction above for why one
					-- was never enough.
					for _, box in ipairs(lastMenuBox) do
						if sx + 16 > box.left and sx < box.right
							and sy + 16 > box.top and sy < box.bottom then
							hidden = true
							break
						end
					end
				end
				if hidden then
					nHidden = nHidden + 1
				else
					-- COUNT WHAT THE QUESTION ACTUALLY IS: peers rendered on a STEPPING frame.
					-- The count itself is taken below, where `stepLatch` is decided, because that
					-- latch IS the stepping view being chosen. Counting anything earlier counts an
					-- INPUT: `moving`, the turn rearm and the latch all sit between the prog band
					-- and the image on screen, so the band can read 45% while the ghost never once
					-- steps -- and a band that agrees with the renderer today diverges the next
					-- time either side is touched, which is how this counter was already wrong once
					-- (it used to count peers that had merely CHANGED TILE recently, healthy-looking
					-- all through a session where no stepping frame was drawn at all; `phase9.md`).
					--
					-- CUMULATIVE, because the line below is printed once a second and a frame
					-- count sampled once a second cannot see a cadence that changes every two
					-- frames. The instantaneous version read a flat zero for 117 consecutive
					-- samples, which is not a measurement of the animation -- it is a measurement
					-- of when the log happens to fire. `pitfalls.md` has the same mistake under
					-- "painted positions were only ever sampled once a second".
					-- On facingFrames rather than new top-level names: 197 of Lua's 200 locals.
					-- ONE IMAGE PER STEP, LATCHED -- the stride index must not advance INSIDE a
					-- stepping burst.
					--
					-- OBJECT_FACING counts 0..3 THROUGH a step, not once per step: measured
					-- 2026-08-22, one step walking up runs face 05 -> 06 -> 07. The stepping view
					-- is mirrored at strides 0 and 3 and upright at 1 and 2, so reading the stride
					-- fresh every frame mirrors the character part-way through a single foot-plant.
					-- The user, watching exactly that: *"kinda looks as if the drawn ghost is
					-- walking/doing the animation really fast"*.
					--
					-- The engine shows ONE image for the whole burst. So the stride is taken once,
					-- when the peer ENTERS the stepping band, and held until it leaves. That
					-- reproduces the engine's own alternation for free rather than imposing one:
					-- measured across three consecutive steps, the bursts begin at face 05, 07 and
					-- 05 -- upright, mirrored, upright, which is what alternating feet is.
					-- A PEER BETWEEN STEPS IS NOT A PEER STANDING STILL.
					--
					-- `anim` is "walk" only while OBJECT_STEP_DURATION is counting, and it reads
					-- STANDING for the two frames at the top of each step (prog 0). Gating the
					-- stepping view on it therefore drops the ghost back to the standing view in
					-- the MIDDLE of a burst -- which is the split the cadence trace shows, and the
					-- whole of the "a bit fast" report. So a peer counts as walking through a short
					-- gap: long enough to cross the boundary, far too short to hold a genuinely
					-- idle peer on a stepping frame.
					o.idleFor = o.walking and 0 or ((o.idleFor or 99) + 1)
					-- A TURN ENDS A BURST. The grace above exists to carry the stepping view across
					-- the two not-walking frames at a TILE BOUNDARY; a direction change also looks
					-- like a short not-walking gap and would be carried the same way, which gives
					-- the ghost a step the peer never took.
					--
					-- Measured 2026-08-22 with the direction printed into the cadence trace. On a
					-- turn the engine holds the STANDING view while the character pivots and only
					-- then steps -- `...LLLLLLLLl rrrrrrr RRRRRRRR` -- while the ghost went
					-- `...LLLLRRRR`, straight from one burst into the next with nothing between.
					-- One extra beat, only on turns, which is exactly the user's *"still doing
					-- right a bit fast sometimes"* with the other three directions reading fine.
					-- A TURN LASTS LONGER THAN ONE FRAME. The orientation on the wire can flicker for
					-- a single frame, and treating that as a pivot suppresses the stepping view for
					-- exactly one frame -- a hole punched in the middle of an otherwise correct
					-- burst. The cadence trace shows it as `RRRRrRRR` and `DDdD` against a player
					-- running a tidy eight-on eight-off, and one frame is all it takes to read as
					-- choppy legs (user, 2026-08-23: *"the legs are still acting up"*).
					--
					-- So a new facing has to survive a frame before it counts as a turn. A real
					-- pivot easily clears that; a one-frame flicker never does.
					if o.facing ~= o.lastFacing and o.facing == o.facingSeen then
						-- REARM, don't just clear. Clearing the latch is not enough: the peer is
						-- usually already `walking` when its facing changes, so the band re-fires on
						-- the very next frame and the ghost steps straight out of the turn anyway --
						-- measured as ghost `LLLLRRRR` against player `Lll rrrrr RRRRRRRR`.
						--
						-- The engine stands through the pivot and steps afterwards. So a turn
						-- suppresses the stepping view until the peer has passed through the
						-- STANDING half of a step once; the next burst then begins on its own at the
						-- following boundary, in phase, with no duration invented here.
						o.lastFacing, o.idleFor, o.stepLatch, o.rearm = o.facing, 99, nil, true
					end
					-- What the facing was last frame, for the confirmation above. Kept here rather
					-- than folded into `lastFacing`, which means something different: that one is
					-- the facing of the current BURST and must not move on a flicker.
					o.facingSeen = o.facing
					-- CLEAR ON THE PEER'S NEXT REAL STEP, not after a whole standing half.
					--
					-- Waiting for the standing band meant a turn cost the ghost most of a step
					-- before it animated again: measured at ~12 frames held against the player's
					-- ~5, and the user felt it as the drawn ghost starting its *"movement
					-- animations a bit slow/late"*.
					--
					-- What the engine actually does is pivot with the standing view while the
					-- character is NOT stepping, then step. `anim` already carries exactly that --
					-- Crystal turns in place, so a pivot reads as not-walking. So the rearm lasts
					-- precisely as long as the pivot does and no longer, and a direction change
					-- taken without pausing (walking true throughout) clears it the same frame,
					-- which is right: nothing paused, so nothing should wait.
					if o.rearm and o.walking then
						o.rearm = nil
					end
					-- THE LEGS RUN OFF THE MODEL, exactly as the body does. `o.walking` is the wire's
					-- flag and it describes the peer NOW; the model walks a position a quarter
					-- second older. Every time the peer stops, the flag goes false while the model
					-- still has ~15 frames of walking left to finish, the three-frame grace runs
					-- out, and the legs freeze mid-stride while the body glides on -- once per
					-- pause, which under a driver pausing at every corner is constant. The wire
					-- flag also flickers standing at the top of each of the PEER's steps, at a
					-- phase that has nothing to do with where the MODEL is in its own step.
					--
					-- The model knows whether it is moving; that is the flag with the right clock.
					-- The window is 2 because the model moves every other frame: a gap of two
					-- frames is the walk itself, a gap of three is a stop.
					local modelActive = o.modelMovedAt ~= nil
						and (drawFrames - o.modelMovedAt) <= 2
					local moving = (modelActive or o.walking or o.idleFor <= 3) and not o.rearm
					if moving and (peerProg <= 4 or peerProg >= 14) then
						if not o.stepLatch then
							o.stepLatch = ((o.face or 0) & 3) + 1 -- +1 so 0 is not falsy
						end
					else
						o.stepLatch = nil
					end
					-- HERE, and cumulatively, with the total it was counted out of beside it.
					--
					-- The instantaneous version of this count -- a per-frame local printed once a
					-- second -- reported "0 on a stepping frame" in 439 of 441 samples on
					-- 2026-08-22, while the cumulative band counter reported 107 of 238 walking
					-- frames in the same run, and the two were read as a contradiction that had to
					-- be fixed before the stride could be judged. They never disagreed. A ghost is
					-- walking for about 1% of the frames in a run, so a single frame sampled once a
					-- second catches a stepping ghost about twice in 441 tries: that instrument was
					-- reporting when the log fires, not what the ghost does. The same mistake is
					-- written up two comments above, about the counter it was replaced with, and it
					-- was made again anyway in the line right beside it.
					--
					-- A DENOMINATOR IS PART OF THE READING. `nStepDrawn` alone cannot be told apart
					-- from a probe that looked twice; `nDrawnFrames` says how much was looked at.
					facingFrames.nDrawnFrames = (facingFrames.nDrawnFrames or 0) + 1
					if o.stepLatch then
						facingFrames.nStepDrawn = (facingFrames.nStepDrawn or 0) + 1
					end
					-- AND WHY A STEPPING FRAME WAS REFUSED, which is the only thing that separates
					-- "the peer sent nothing to step on" from "the renderer suppressed it". Both
					-- draw a standing ghost and neither can be told from the other on screen.
					-- IDLE IS TESTED FIRST, and not off `moving`. `rearm` is set the first time a
					-- peer's facing is seen at all (its `lastFacing` starts nil) and is cleared
					-- only by a real step, so a peer that spawns and stands there carries it for
					-- the whole run -- which is harmless in the renderer, since the first walking
					-- frame clears it before `moving` is computed, and a lie in a counter. Read
					-- literally on the first run of this instrument: a ghost that had never moved
					-- reported "111 held by a turn", i.e. the one reason that was certainly not
					-- why. An instrument's categories have to be exclusive in the way a reader
					-- assumes they are, or the count is worse than no count.
					if not o.stepLatch then
						if not o.walking and (o.idleFor or 99) > 3 then
							facingFrames.nNoStepIdle = (facingFrames.nNoStepIdle or 0) + 1
						elseif o.rearm then
							facingFrames.nNoStepRearm = (facingFrames.nNoStepRearm or 0) + 1
						else
							facingFrames.nNoStepMidStep = (facingFrames.nNoStepMidStep or 0) + 1
						end
					end
					-- THE INVARIANT, SIDE BY SIDE. "A bit fast" is a claim about CADENCE, and a
					-- cadence cannot be read off counts or off a once-a-second sample. So each
					-- frame appends one character per renderer -- `S` for the stepping view, `.`
					-- for the standing one -- and the two strings are printed together. If the
					-- ghost's pattern matches the player's, the walk cycle is the engine's own; if
					-- it has more bursts, or shorter ones, the difference is visible in the log
					-- instead of being characterised by eye a fourth time.
					-- BEHIND THE STATS GATE, not COMPARE_TIERS (2026-08-25). This block builds six
					-- trace strings ONE CHARACTER A FRAME, and Lua has no mutable strings: every
					-- append allocates a new string and discards the old, six times a frame, plus
					-- the per-frame arithmetic feeding them. It ran for anyone using the compare
					-- rig -- which is anyone comparing the two tiers, i.e. exactly the sessions
					-- where the game has to be at full speed to judge anything. The user, after
					-- five separate probes were found live at once: *"remove/disable all the
					-- probes that are active anywhere in the lua. probes have lagged things
					-- before"*. They have, and this file is where that lesson was written down.
					--
					-- The rig now RENDERS by default and MEASURES only when asked. The traces are
					-- worth keeping -- they are what read the walk cadence in the first place --
					-- so they live behind MESHGHOST_CRYSTAL_COMPARE_STATS with the rest.
					if facingFrames.stats() and o.only == "drawn" then
						-- The DIRECTION is encoded into the character, upper case for a stepping
						-- view and lower case for a standing one, so a single direction can be read
						-- out of a mixed walk. "Right feels fast and the others do not" is a claim
						-- about one direction, and a trace that cannot separate them cannot test it.
						local mine = DIR_NAMES.letter[o.facing or 0] or "?"
						if o.stepLatch ~= nil then mine = mine:upper() end
						-- NAME THE DROPOUT. The progress trace below proved the band is entered and
						-- left on time -- values held two frames each, cycling cleanly -- and yet
						-- single frames still fall out of a burst, at a progress value that is
						-- squarely INSIDE the band. So the cause is the `moving` gate, and the two
						-- ways it can say no are worth telling apart on the line itself rather than
						-- reasoning about: `z` is a turn suppression, `x` is the peer being judged
						-- not-walking. A lowercase letter here now means only "out of band", which
						-- is the one explanation already ruled out.
						if o.walking and o.stepLatch == nil and (peerProg <= 4 or peerProg >= 14) then
							mine = o.rearm and "z" or "x"
						end
						-- THE INVARIANT FOR THE SIDE VIEW: left and right share one image and are
						-- told apart ONLY by the hardware flip, so a frame whose flip disagrees
						-- with the facing is the character momentarily looking the other way. One
						-- such frame in a walk is a visible jolt and would read as "fast". `!`
						-- marks it, so the log says whether that is happening instead of the eye.
						local chosen = facingFrames.pick(o.facing, moving, peerProg,
							o.stepLatch and (o.stepLatch - 1) or 0)
						if chosen and (o.facing == 2 or o.facing == 3)
							and chosen[1].xflip ~= (o.facing == 3) then
							mine = "!"
						end
						-- MEASURE THE TILE THAT IS DRAWN, not the latch that suggests one.
						--
						-- This trace was asymmetric and had been all along: the player's character
						-- came from `readPlayerOamFrame()` -- the actual OAM the engine blitted --
						-- while the ghost's came from `o.stepLatch`, a variable that FEEDS the
						-- choice. So the two lines never compared the same kind of thing, and
						-- anything going wrong after the latch, inside `pick`, was invisible to
						-- the one instrument built to catch it, while every reading looked clean.
						-- `_template/probes.md` states this rule outright -- measure what is DRAWN,
						-- not the fields that feed it -- and it was broken here in the exact shape
						-- the rule describes. `x`/`z`/`!` above stay: they explain a disagreement,
						-- but the letter's case now reports the drawn tile.
						if chosen and mine ~= "!" then
							local stepping = (chosen[1].offset & 0x80) ~= 0
							mine = stepping and mine:upper() or mine:lower()
						end
						local pf = readPlayerOamFrame()
						local theirs = "?"
						if pf then
							local pd = ((u8(OBJECT_STRUCTS + F_DIRECTION) or 0) // 4) & 3
							theirs = DIR_NAMES.letter[pd] or "?"
							if (pf[1].offset & 0x80) ~= 0 then theirs = theirs:upper() end
						end
						facingFrames.tPeer = (facingFrames.tPeer or "") .. mine
						facingFrames.tPlayer = (facingFrames.tPlayer or "") .. theirs
						-- THE PROGRESS VALUE ITSELF, one character a frame under the other two.
						-- The bursts are the right length now and still drop a single frame here
						-- and there, and neither of the lines above can say why: they show the
						-- OUTCOME. This shows the input the band is tested against, so a dropout is
						-- either a progress value that jumped out of the band and back -- visible
						-- as a break in an otherwise ascending run -- or it is not, and the cause
						-- is `moving`/`rearm` instead. One character wide, so it lines up column
						-- for column with the frame that went wrong.
						facingFrames.tProg = (facingFrames.tProg or "")
							.. string.sub("01234567", (peerProg // 2) % 8 + 1, (peerProg // 2) % 8 + 1)
						-- THE PIXELS THEMSELVES, signed, in the same columns. Added 2026-08-23 when
						-- the user reported constant backward snapping while every model counter
						-- read clean -- the model's own resync counter said 0, so whatever snaps is
						-- BELOW the model, in the paint. Every instrument to this point measured
						-- the model; none watched the screen position the eye actually watches.
						-- `.` steady, `+` 2px with travel, `-` 2px AGAINST travel (the snap), `<`/
						-- `>` anything larger, `o` an odd pixel (which the engine never draws).
						-- A `-` column names the frame; the prog/cadence columns above it name what
						-- the renderer thought it was doing at that moment.
						local sdc = "."
						if facingFrames.lastPX then
							local vert = (o.facing == 0 or o.facing == 1)
							local sd = vert and (sy - facingFrames.lastPY)
								or (sx - facingFrames.lastPX)
							-- THE PERPENDICULAR AXIS TOO. This line read pure dots while the user
							-- still saw a tiny jitter (2026-08-23) -- and it only measured along
							-- the FACING axis, so any sideways wobble was invisible to it. `x`
							-- marks a frame where the ghost moved on the axis it is NOT walking
							-- along, which a walking character never does.
							local sp = vert and (sx - facingFrames.lastPX)
								or (sy - facingFrames.lastPY)
							if o.facing == 1 or o.facing == 2 then sd = -sd end
							if sp ~= 0 then sdc = "x"
							elseif sd ~= 0 then
								if (sd % 2) ~= 0 then sdc = "o"
								elseif sd == 2 then sdc = "+"
								elseif sd == -2 then sdc = "-"
								elseif sd > 2 then sdc = ">"
								else sdc = "<" end
							end
						end
						facingFrames.lastPX, facingFrames.lastPY = sx, sy
						facingFrames.tScreen = (facingFrames.tScreen or "") .. sdc
						-- EVERY TERM, SIGNED, IN THE SAME COLUMNS -- the anti-theory instrument.
						-- The screen delta is model minus reference, painted under a camera that
						-- scrolls independently; three quantities, and a mark on the screen line
						-- cannot say which one produced it. These two lines plus the camera line
						-- make the subtraction readable per frame: model delta along travel, then
						-- reference delta along travel ('+' forward, '-' back, '#' big), then the
						-- camera's own delta as a digit. Whichever line wobbles owns the fault.
						local function sdChar(d)
							if d == 0 then return "."
							elseif d == 2 then return "+"
							elseif d == -2 then return "-"
							else return "#" end
						end
						local vert2 = (o.facing == 0 or o.facing == 1)
						local md = vert2 and ((o.modelY or 0) - (facingFrames.lastMY or o.modelY or 0))
							or ((o.modelX or 0) - (facingFrames.lastMX or o.modelX or 0))
						local rrX = (aged.oamX or playerOamX) - ppx
						local rrY = (aged.oamY or playerOamY) - ppy
						local rd = vert2 and (rrY - (facingFrames.lastRY or rrY))
							or (rrX - (facingFrames.lastRX or rrX))
						if o.facing == 1 or o.facing == 2 then md, rd = -md, -rd end
						facingFrames.lastMX, facingFrames.lastMY = o.modelX, o.modelY
						facingFrames.lastRX, facingFrames.lastRY = rrX, rrY
						facingFrames.tModel = (facingFrames.tModel or "") .. sdChar(md)
						facingFrames.tRef = (facingFrames.tRef or "") .. sdChar(rd)
						facingFrames.tCam = (facingFrames.tCam or "")
							.. tostring(math.min(9, facingFrames.camDelta or 0))
						if #facingFrames.tPeer >= 60 then
							logFile("  cadence ghost  " .. facingFrames.tPeer)
							logFile("  cadence player " .. facingFrames.tPlayer)
							logFile("  cadence prog   " .. (facingFrames.tProg or ""))
							logFile("  cadence screen " .. (facingFrames.tScreen or ""))
							logFile("  cadence model  " .. (facingFrames.tModel or ""))
							logFile("  cadence ref    " .. (facingFrames.tRef or ""))
							logFile("  cadence cam    " .. (facingFrames.tCam or ""))
							facingFrames.tPeer, facingFrames.tPlayer = "", ""
							facingFrames.tProg, facingFrames.tScreen = "", ""
							facingFrames.tModel, facingFrames.tRef, facingFrames.tCam = "", "", ""
						end
					end
					if o.walking then
						facingFrames.nWalkFrames = (facingFrames.nWalkFrames or 0) + 1
						if peerProg < 6 or peerProg > 12 then
							facingFrames.nStepFrames = (facingFrames.nStepFrames or 0) + 1
						end
						facingFrames.progSeen = facingFrames.progSeen or {}
						facingFrames.progSeen[peerProg] = (facingFrames.progSeen[peerProg] or 0) + 1
					end
					if o.facing == nil then nNoFacing = nNoFacing + 1 end
					if UI_DEBUG and (boxOpen or uiOpen) and #paintedSamples < 8 then
						paintedSamples[#paintedSamples + 1] =
							string.format("%s@%d,%d", id, sx, sy)
					end
					-- THE MIDDLE RUNG FIRST. A peer whose tiles are resident in VRAM can be handed
					-- to the hardware, which draws it with the game's own live palettes and orders
					-- it against the game's own cast. It declines when the buffer has no room or
					-- nothing has been learned for this facing, and then the peer is painted
					-- exactly as before -- a peer never disappears because a tier said no.
					-- COMPARE_TIERS only: say where every copy went and where it thinks it is. Three
					-- renderers disagreeing is exactly the case a count cannot describe -- "2 off
					-- screen" does not say WHICH, at what coordinate, or which rung claimed it.
					if COMPARE_TIERS and drawFrames % 60 == 0 then
						-- walking/prog/face are the three inputs the frame picker uses. They are
						-- printed beside the position because "the ghost is in the right place and
						-- on the wrong frame" and "the ghost is on the wrong frame because it does
						-- not think it is walking" look identical on screen.
						logFile(string.format("  copy %-28s only=%-6s map %d,%d screen %d,%d "
							.. "facing=%s vram=%s walking=%s prog=%s face=%s",
							id, tostring(o.only), o.x, o.y, sx, sy, tostring(o.facing),
							tostring(source.vram), tostring(o.walking), tostring(o.prog),
							tostring(o.face)))
					end

					-- THE TWITCH DETECTOR. Painted positions were only ever sampled once a second,
					-- which is blind to per-frame jitter by construction -- and the user could see
					-- jitter the samples denied (2026-08-21). This compares every frame's painted
					-- position against the last one and logs only the discontinuities: a smooth
					-- walk moves 2px a frame, so any jump past 4px between consecutive frames is a
					-- twitch, named with the position it jumped from and to.
					if o.paintedX and (math.abs(sx - o.paintedX) > 4 or math.abs(sy - o.paintedY) > 4) then
						logFile(string.format("  TWITCH %-24s painted %d,%d -> %d,%d (%+d,%+d)",
							id, o.paintedX, o.paintedY, sx, sy, sx - o.paintedX, sy - o.paintedY))
					end
					-- THE DISTRIBUTION, NOT JUST THE OUTLIERS. The detector above only fires past
					-- 4px, so a walk that moves 2px every frame and 4px at every tile boundary --
					-- a visible hitch once per tile -- reads as ZERO twitches and looks perfect in
					-- the log. The user, 2026-08-22: *"still stuttering/small snap kinda when
					-- moving to the next tile"*, with the detector reporting nothing at all.
					-- A smooth step is the SAME delta every frame; anything else is the fault,
					-- however small, so every delta is counted rather than only the large ones.
					-- PER DIRECTION, because the report is about ONE of them. The user, 2026-08-22,
					-- after the walk cycle was matched frame for frame: right *"sometimes looks
					-- fine but other times it looks fast/weird"*, with left, up and down reading
					-- correct -- and they identified it as the ghost SHIFTING POSITION rather than
					-- the legs being wrong. A histogram pooled across all four directions cannot
					-- test that claim: three clean directions bury one dirty one.
					-- HOW MANY FRAMES BEHIND THE PLAYER IS THIS PEER, REALLY?
					--
					-- Only answerable on loopback, and there it is exact: the peer's state IS the
					-- player's own state from some frames ago, so the ring entry that MATCHES it
					-- names the round trip -- adapter to core to relay and back. That number bounds
					-- everything: "the ghost starts its animation late" cannot be fixed below it by
					-- any amount of renderer work, and knowing it stops the pipeline being
					-- mistaken for a defect in the drawing.
					--
					-- Matched on tile AND progress together, because a tile alone repeats across a
					-- step and would match the wrong frame.
					if facingFrames.stats() and o.only == "drawn" and o.walking then
						local h = playerHistory
						for age = 0, h.size - 1 do
							local e = h[((h.n - age) % h.size) + 1]
							if e and e.tx == o.x - COMPARE.drawn and e.ty == o.y
								and e.prog == peerProg then
								facingFrames.lagSeen = facingFrames.lagSeen or {}
								facingFrames.lagSeen[age] = (facingFrames.lagSeen[age] or 0) + 1
								break
							end
						end
					end
					if o.paintedX and o.walking and facingFrames.stats() then
						facingFrames.stepDelta = facingFrames.stepDelta or {}
						local k = DIR_NAMES.letter[o.facing or 0] or "?"
						facingFrames.stepDelta[k] = facingFrames.stepDelta[k] or {}
						local d = math.abs(sx - o.paintedX) + math.abs(sy - o.paintedY)
						facingFrames.stepDelta[k][d] = (facingFrames.stepDelta[k][d] or 0) + 1
					end
					o.paintedX, o.paintedY = sx, sy

					-- WHAT THE PEER IS DOING, not just where it is -- see facingFrames.pose. One
					-- call, used by both rendering tiers, so the hardware tier cannot drift back
					-- into showing an animation the drawn one shows and vice versa.
					local poseFacing, poseWalking, poseStride, poseHide, poseRod =
						facingFrames.pose(o.act, o.face, o.facing, moving,
							o.stepLatch and (o.stepLatch - 1) or 0)
					-- A LANDING PEER IS THE POKEMON, NOT THE CHARACTER. For the whole descent the
					-- engine draws no character at all -- `FlyToAnim` hides them and flies a
					-- cutscene sprite carrying the mon's icon -- so the ghost is hidden here and
					-- the icon painted below in its place.
					-- NO ICON MEANS NO SPECIAL LANDING -- it must never mean an invisible peer.
					-- The parking write and this hide together draw nothing for 44 frames, which
					-- is correct only while something is painted in the Pokemon's place; when the
					-- species is missing (an unrecognised ROM, an older client, or the wire fault
					-- being chased on 2026-08-26) the peer simply vanished instead. The user saw
					-- exactly that: *"both ghosts were invisible when flying to another town"*.
					-- So the hide is conditional on having the icon to show.
					local flyIcon = o.drop and o.flyMon and facingFrames.iconGfx(o.flyMon) or nil
					if flyIcon then
						poseHide = true
					end
					local onHardware = false
					if source.vram and o.only ~= "drawn" and not poseHide then
						onHardware = oam.place(sx, sy, source.vram, palette, poseFacing,
							poseWalking, peerProg, poseStride)
					end
					if onHardware then
						nOam = nOam + 1
					elseif o.only == "hw" then
						nOam = nOam -- pinned to a rung that had no room: show nothing rather than
						-- quietly painting it, which would make the comparison a lie
					elseif flyIcon then
						-- THE DESCENT, on the engine's own curve (see facingFrames.flyOffset):
						-- `88 - 2k` pixels above the landing tile and the same amount times
						-- cos(k * pi/32) to the side, so the swing decays into the landing exactly
						-- as the game's does. Two frames of art alternating every 8, the fourth
						-- x-flipped, from `.Frameset_RedWalk`.
						facingFrames.iconPaints = (facingFrames.iconPaints or 0) + 1
						local fdx, fdy = facingFrames.flyOffset(o.drop)
						local fbase, fflip = facingFrames.flyFrame(o.drop)
						nDrawn = nDrawn + 1
						for _, part in ipairs(facingFrames.ICON_BOX) do
							drawRows(decodeRomTile(flyIcon, fbase + part.t),
								sx + fdx + (fflip and (8 - part.dx) or part.dx), sy + fdy + part.dy,
								paletteColors(0), fflip)
						end
					elseif poseHide then
						nDrawn = nDrawn -- the engine itself draws nothing for this peer on this
						-- frame (OBJECT_FACING is STANDING), so neither do we. Not counted as
						-- painted, because it was not.
					else
						nDrawn = nDrawn + 1
						-- the palette the local player's own sprite is drawn with, which is the one
						-- these tiles were coloured for
						-- A BUMPING PEER IS ANIMATING WITHOUT MOVING, and `moving` cannot see it.
						--
						-- The user, 2026-08-23: *"when standing idle, and walking into a wall. the
						-- drawn ghost is not doing the 'walking' animation like the player & spawned
						-- ghost does"*. The spawned tier gets this for free -- it hands the engine
						-- the peer's OBJECT_ACTION and the engine animates -- while this tier DERIVES
						-- its pose from position and sub-tile progress, so anything that animates on
						-- the spot is invisible to it by construction. Bump is simply the first one
						-- noticed; spin, fishing, the emote and the Fly landing are all the same gap.
						--
						-- Measured before it was written (probes/bump_probe.lua, 2026-08-23): while
						-- the player holds a direction into a wall, OBJECT_WALKING stays STANDING --
						-- which is why this peer arrives as `anim="idle"` and `moving` is false --
						-- OBJECT_ACTION reads 3 (BUMP), and OBJECT_FACING alternates 1,2 about every
						-- twelve frames. That alternation IS the walk-in-place; it is already on the
						-- wire as `extras.face` and was being thrown away here.
						--
						-- `peerProg` needs no special case: with no step running, OBJECT_STEP_DURATION
						-- is 0 and `stepProgress` is therefore 16, which already sits inside the
						-- stepping-view band `pick` tests for. Only the `moving` flag and the stride
						-- source have to change.
						--
						-- 3 as a literal, and the stride masked to two bits, for the reason the rest
						-- of this file gives: it sits at Lua's 200-local ceiling and a name here
						-- would cost one. OBJECT_ACTION_BUMP is 3 in
						-- `constants/map_object_constants.asm`; `documentation.md` lists the set.
						-- A BUMP ALTERNATES STANDING AND STEPPING; it does not cycle stride images.
						--
						-- First attempt passed `walking = true` for the whole bump, which makes
						-- `pick` return a STEPPING frame every time and cycle through the strides.
						-- The user: *"now the drawn is doing it but it looks slow/weird"*. It was
						-- doing something the player never does.
						--
						-- Measured instead of reasoned (probes/bump_probe.lua, run-length encoded so
						-- the cadence is readable). Holding into a wall, the tile the engine actually
						-- draws for the player alternates between the character's own art at
						-- `base + 0x00` -- the STANDING view -- and `base + 0x80`, the STEPPING view,
						-- in 16-frame runs, while OBJECT_FACING walks 0,1,2,3:
						--
						--   facing 2: 0x80 x3, 0x00 x13    facing 3: 0x00 x3, 0x80 x13
						--   facing 0: 0x80 x3, 0x00 x13    facing 1: 0x00 x3, 0x80 x13
						--
						-- So the image is STEPPING on odd strides and STANDING on even ones, each
						-- for 16 frames, and the 3/13 split is the block changing three frames
						-- before the facing does. Matching the 13-frame majority reproduces the
						-- cadence; the 3-frame lead-in is left alone rather than special-cased.
						--
						-- `stride & 1` rather than `face & 1` so it holds in every direction:
						-- OBJECT_FACING is `dir * 4 + stride` (setGhostStanding writes `dir * 4`),
						-- so masking to two bits removes the direction and leaves the stride, which
						-- is what the alternation is actually keyed on. Only the DOWN wall was
						-- measured -- the other three are this arithmetic, not an observation.
						--
						-- THE CODE THIS DESCRIBES MOVED, 2026-08-25: it is now the general rule in
						-- `facingFrames.pose`, which reads the facing byte the way the engine's
						-- own facing table does and so covers spin, fishing and the Fly landing
						-- too. The measurement above is unchanged and is what that rule returns
						-- for action 3; it is kept here because it is the evidence.
						-- HOLD THE DRAWN COPY STILL FOR THE HANDOVER FRAMES.
						--
						-- The blink at promotion is not a missing frame -- that was measured and
						-- closed. What is left is a 2px hop BACKWARD, and this is where it comes
						-- from: the drawn copy goes on tracking the peer, which by definition has
						-- just started moving (that is what triggers the promotion), while the
						-- engine object is parked on its tile until it takes its own step. So the
						-- two disagree by however far the model walked during the handover, and the
						-- engine's copy appears behind where the painted one just was.
						--
						-- Traced 2026-08-23 with the paint position and the live OAM count on one
						-- line: `f=1093 PAINTED at 112,76 oam=16` then `f=1094 PAINTED at 112,78
						-- oam=16`, and the object arrives tile-aligned at 76. Two pixels, once per
						-- promotion, and a promotion happens every time a peer starts walking after
						-- standing still -- the user: *"flickering slightly whenever it moves 1 tile
						-- after having being despawned/respawned"*, and *"only... not anywhere else"*.
						--
						-- Latched rather than recomputed, because the first handover frame is the
						-- one where the two tiers provably agree (the model's discarded sub-tile
						-- remainder measures 0.0px there). Safe to store on `o`: during a handover
						-- renderRemote returns before rebuilding the entry, so this table persists.
						if o.handover then
							if not o.handoverSX then
								o.handoverSX, o.handoverSY = sx, sy
							end
							sx, sy = o.handoverSX, o.handoverSY
						end
						if stepLag.on and stepLag.traceUntil and drawFrames <= stepLag.traceUntil then
							-- THE LIVE OAM COUNT ON THE SAME LINE, so the paint clock and the engine
							-- clock can be compared without lining up two logs. A character is four
							-- entries, so the count stepping up by four is the engine's copy
							-- arriving; that is what decides whether the handover overlaps or leaves
							-- a hole, and it is the only pair of numbers that answers it.
							local live = 0
							for e = 0, 39 do
								local ey = memory.read_u8(e * 4, "OAM") or 0
								if ey ~= 0 and ey < 160 then
									live = live + 1
								end
							end
							logFile(string.format("handover trace f=%d %s PAINTED at %d,%d "
								.. "(handover=%s, spawned=%s, oam=%d)", drawFrames, id, sx, sy,
								tostring(o.handover), tostring(ghosts[id] ~= nil), live))
							-- TEMP (2026-08-25): the raw OAM window, not a match verdict. The
							-- release condition is being rewritten to wait for the engine's copy
							-- to actually appear, and picking what to test for off a computed
							-- boolean is how the 08-23 probe produced two confident wrong answers
							-- (UNVERIFIED.md, "only the last one could have been right"). Print
							-- the entries and read the mapping off them.
							local near = {}
							for e = 0, 39 do
								local ey = memory.read_u8(e * 4, "OAM") or 0
								local ex = memory.read_u8(e * 4 + 1, "OAM") or 0
								if ey ~= 0 and ey < 160 then
									near[#near + 1] = string.format("%d:%d,%d", e, ex, ey)
								end
							end
							logFile(string.format("  OAM f=%d expect x=%d y=%d | %s",
								drawFrames, sx + 8, sy + 16, table.concat(near, " ")))
						end
						-- The pose was computed above, once, for both tiers. What used to be here
						-- was the BUMP special case alone; it is now the general rule, which
						-- covers spin, the turn in place, fishing and the Fly landing without a
						-- branch each. The two lines it replaced are still exactly what happens
						-- for action 3: facing byte 0x00-0x0F, stride = byte & 3, stepping on the
						-- odd strides.
						local fishRom = poseRod and facingFrames.fishRom(o.sprite) or nil
						-- THE EMOTE BOX FIRST, and at the UNBOBBED position. It is a separate
						-- object in the engine and it does not share the character's own vertical
						-- nudge -- a character bobbing under a "!" is exactly what the game draws.
						local emoteRom = o.emote and facingFrames.emoteGfx(o.emote) or nil
						if emoteRom then
							local ec = paletteColors(5) -- PAL_OW_EMOTE, the box's own palette
							for _, part in ipairs(facingFrames.EMOTE_BOX) do
								drawRows(decodeRomTile(emoteRom, part.t),
									sx + part.dx, sy - 16 + part.dy, ec)
							end
						end
						-- THE SHADOW UNDER A HOPPING PEER, and it is drawn HERE -- before the yoff
						-- is applied and before the character -- for two reasons that are both
						-- about what a shadow IS.
						--
						-- BEFORE THE YOFF: the shadow stays on the GROUND while the character
						-- rises off it. In the engine it is a separate object that never gets the
						-- hop's sprite offset, so its screen position is the character's TILE
						-- position -- which is exactly what `sy` still holds on this line and
						-- stops holding on the next. Adding the arc to the shadow too would give
						-- a shadow glued to the character's feet, which reads as no hop at all.
						--
						-- BEFORE THE CHARACTER: `SPRITEMOVEDATA_SHADOW`'s flags2 is LOW_PRIORITY,
						-- so the engine draws it behind. The painted tier has no priority bits, so
						-- draw order IS priority here.
						--
						-- Two sprites from ONE tile: `FacingShadow` (data/sprites/facings.asm) is
						-- `db 0, 0, ABSOLUTE_TILE_ID, $fc` and `db 0, 8, ABSOLUTE_TILE_ID |
						-- OAM_XFLIP, $fc` -- the same tile twice, the right half mirrored, making
						-- a 16x8 smudge. Read from the cartridge rather than VRAM $fc: see
						-- SHADOW_GFX_ROM for the reason (a local player fishing overwrites it).
						if o.jump and facingFrames.shadowRom then
							local sc = paletteColors(emote.PAL) -- PAL_OW_EMOTE, the shadow's own
							local sdy = emote.SHADOW_DY[poseFacing] or emote.SHADOW_DY[0]
							drawRows(decodeRomTile(facingFrames.shadowRom, 0), sx, sy + sdy, sc)
							drawRows(decodeRomTile(facingFrames.shadowRom, 0),
								sx + 8, sy + sdy, sc, true)
						end
						-- OBJECT_SPRITE_Y_OFFSET is ADDED to the character's screen position by
						-- the engine, and screen y grows downward, so it is added here too. This
						-- is the bite wiggle, the Fly fall and a ledge hop's arc, all of them,
						-- because the engine expresses all of them in this one byte.
						if o.yoff and o.yoff ~= 0 then
							sy = sy + o.yoff
						end
						drawCharacter(source, sx, sy, palette, poseFacing,
							poseWalking, peerProg, poseStride, fishRom)
						if poseRod and fishRom then
							-- The fifth sprite of a fishing pose. Drawn AFTER the character so it
							-- overlaps the same way the engine's OAM order does (the rod entry is
							-- appended last in FacingFish*), and in the character's own palette,
							-- which is what the engine gives it: the rod's row has
							-- ABSOLUTE_TILE_ID but not RELATIVE_ATTRIBUTES, and the palette comes
							-- from the object either way.
							local r = facingFrames.ROD[poseRod]
							if r then
								drawRows(decodeRomTile(fishRom, r.t),
									sx + r.dx, sy + r.dy, paletteColors(palette or 0), r.flip)
							end
						end
					end
				end
			end
		end
	end

	-- DREW NOBODY? THEN CLEAR. This is the last gate, and it is the one that was missing.
	--
	-- Every `stopDrawing()` above is on an EARLY RETURN -- a battle, a menu, a map crossing, the
	-- player's own sprites not on screen. They were written for the 2026-08-21 report of a painted
	-- ghost surviving a door transition, and they cover the cases where this function bails out.
	-- None of them covers the ordinary case where the function runs all the way through and simply
	-- has nobody left to paint, because `overflow` is empty.
	--
	-- WHICH IS EXACTLY WHAT A PROMOTION DOES. A peer that starts walking after standing still is
	-- moved from the painted tier to the spawned one: `overflow[id]` is cleared, the engine takes
	-- over, and this loop runs zero times from that frame on. BizHawk's drawing layer PERSISTS
	-- until something replaces or clears it -- this file says so twenty lines up, from a measured
	-- symptom -- so the last frame this tier painted stays on screen. Frozen. Forever.
	--
	-- That is the "third, static ghost". User, 2026-08-26, and every clause of it is this bug:
	-- *"whenever you move after the despawn/respawn"*, *"only 1 orphan at a time, never multiple
	-- per player"*, *"goes away if i go out and go idle again"* (the peer is demoted, this loop
	-- paints again, and the fresh paint replaces the stale pixels), and it *"stayed forever if i
	-- went inside a house"* -- a map change rebuilds the object arrays and clears an engine
	-- orphan, but it has no effect whatever on an overlay nobody is repainting.
	--
	-- IT IS ALSO WHY EVERY INSTRUMENT SAID THE ARRAYS WERE CLEAN, and they were: across three
	-- probe logs and many promotion cycles the object array never held two of ours and never held
	-- a third character. It never could. The extra character was never in the game at all -- and
	-- a screenshot cannot see it either, because BizHawk does not capture the Lua overlay.
	--
	-- The counter, not a recomputation of the condition: `nDrawn` is what the summary below
	-- reports, so the clear and the log can never disagree about whether anything was painted.
	if nDrawn == 0 then
		stopDrawing("nothing-drawn")
	end
	-- PER-FRAME COUNTERS, stashed for the XTRACE block. The per-second tiers report prints these
	-- same locals but only on the frame it fires, which made a 20-frame gap unreadable: every
	-- report landed on a healthy frame and said "0 off screen, 0 no tile", and that was taken as
	-- true of the gap. A per-frame instrument may only be trusted alongside per-frame counters.
	if ENGINE.xmap.traceUntil and policyFrames <= ENGINE.xmap.traceUntil then
		facingFrames.dbgCounts = string.format("want=%d drawn=%d oam=%d noTile=%d off=%d hid=%d",
			nWanted, nDrawn, nOam, nNoTile, nOffScreen, nHidden)
	end

	if UI_DEBUG and (boxOpen or uiOpen) and drawFrames % 15 == 0 then
		local rects = "none"
		if lastMenuBox then
			-- The whole list, because the union IS the fix -- one printed rectangle is how the
			-- party-menu hole hid behind a healthy-looking line.
			local parts = {}
			for _, box in ipairs(lastMenuBox) do
				parts[#parts + 1] = string.format("l=%d t=%d r=%d b=%d",
					box.left, box.top, box.right, box.bottom)
			end
			rects = table.concat(parts, " | ")
		end
		logFile(string.format("UI DEBUG: boxOpen=%s uiOpen=%s stale=%s coords=%d,%d,%d,%d "
			.. "rect=%s wy=%d wx=%d "
			.. "-- %d painted, %d hidden; painted at: %s",
			tostring(boxOpen), tostring(uiOpen), tostring(TEXTBOX.stale),
			t or -1, l or -1, b or -1, r or -1,
			rects,
			memory.read_u8(0xFF4A, "System Bus") or 0, memory.read_u8(0xFF4B, "System Bus") or 0,
			nDrawn, nHidden,
			(#paintedSamples > 0) and table.concat(paintedSamples, " ") or "(none)"))
	end

	-- Once a second, say what the drawn tier actually did. "Half the screen is empty" needs a
	-- number that separates "the peers never arrived" from "they arrived and were not drawn".
	oam.verify()

	-- WHO IS THE ADAPTER ACTUALLY HOLDING? The tier COUNTS reported "1 drawn, 0 spawned" while the
	-- user watched a painted copy sitting on top of a spawned object that was plainly being driven.
	-- The counts and the screen disagreed, and a count cannot say WHICH ids are in which table. This
	-- names them, and flags the case that must never happen: one peer in `ghosts` AND in `overflow`
	-- in the same frame, which is that peer rendered twice.
	if drawFrames % 60 == 0 then
		local spawnedIds, paintedIds, both = {}, {}, {}
		for gid in pairs(ghosts) do
			spawnedIds[#spawnedIds + 1] = gid
		end
		for oid in pairs(overflow) do
			paintedIds[#paintedIds + 1] = oid
			if ghosts[oid] then
				both[#both + 1] = oid
			end
		end
		if #both > 0 then
			logFile("DOUBLE-RENDERED: " .. table.concat(both, ", ")
				.. " -- in BOTH tiers this frame, so that peer is on screen twice")
		end
		if #spawnedIds > 0 or #paintedIds > 0 then
			logFile(string.format("  holding: spawned{%s} painted{%s}",
				table.concat(spawnedIds, ","), table.concat(paintedIds, ",")))
		end
	end

	if drawFrames % 60 == 0 and nWanted > 0 then
		logFile(string.format("tiers: %d on hardware. "
			.. "drawn tier: %d peers waiting, %d drawn (%d from the cartridge), "
			.. "%d no sprite tiles, %d off screen, %d hidden by UI, %d spawned as real objects; "
			.. "stepping view drawn on %d of %d peer-frames so far, %d with no facing yet%s",
			nOam, nWanted, nDrawn, nFromRom, nNoTile, nOffScreen, nHidden, ghostCount(),
			facingFrames.nStepDrawn or 0, facingFrames.nDrawnFrames or 0, nNoFacing,
			(function()
				local w = facingFrames.stopWhy
				if not w then return "" end
				local parts = {}
				for k, v in pairs(w) do parts[#parts + 1] = string.format("%s:%d", k, v) end
				table.sort(parts)
				return "; NOT DRAWN because -- " .. table.concat(parts, " ")
			end)()))
		-- THE RESYNC, REPORTED WITHOUT THE COMPARE RIG. It used to be visible only on the MODEL
		-- walk line, which is gated behind the measuring rig -- so the number that says whether a
		-- painted peer is being SNAPPED rather than walked could not be read in an ordinary
		-- session. Only when it has fired, so a clean run stays silent.
		-- HOW FAR BEHIND, AND WHAT IT DID ABOUT IT -- the three numbers that describe a glide.
		--
		-- All three already existed and all three printed only on the MODEL walk line, which is
		-- gated behind MESHGHOST_CRYSTAL_COMPARE_STATS -- a rig heavy enough that the user reported
		-- the game *"laggy when the scripts are running"*, and a probe that drops frames desyncs
		-- exactly the pacing it was turned on to measure. So the shape of a glide has never been
		-- readable in an ordinary session.
		--
		-- `furthest behind` is the lag in pixels: a model that is smoothly 6px behind looks fine,
		-- one that swings between 0 and 20 is the glide. `backward refused` counts frames where the
		-- model wanted to move AWAY from its target -- a peer's own reversal arriving late. And
		-- `catch-up` counts frames spent repaying, which is where a snap would live if it is not
		-- the resync. Three integers, once a second, only while a peer is on the drawn tier.
		if nDrawn > 0 then
			logFile(string.format("  model pacing: furthest behind %dpx (a step is 16px), "
				.. "%d backward refused, %d catch-up frames",
				facingFrames.modelMax or 0, facingFrames.backwards or 0,
				facingFrames.catchupFrames or 0))
			-- The camera's own motion, as this adapter sees it. The engine scrolls whole gait
			-- strides and never an odd pixel, so a bin outside {0,2,4,8} is this adapter sampling
			-- mid-scroll rather than the game doing something new.
			if facingFrames.camHist then
				local b = {}
				for px = 0, 16 do
					local n = facingFrames.camHist[px]
					if n then
						b[#b + 1] = string.format("%dpx:%d", px, n)
					end
				end
				logFile("  camera deltas: " .. table.concat(b, " "))
			end
		end
		if (facingFrames.modelSnaps or 0) > 0 then
			logFile(string.format("  model resyncs: %d so far, worst %dpx past the 24px threshold "
				.. "-- each one is a painted peer being ASSIGNED its position rather than walked "
				.. "there, which is a snap on screen",
				facingFrames.modelSnaps, (facingFrames.modelSnapPx or 0) - 24))
		end
		-- EVERY prog value a drawn peer was rendered at, cumulatively. Which values arrive is the
		-- whole question behind "the stride never runs": the frame is a function of prog, so a prog
		-- that never leaves the middle of a step can only ever draw the standing view.
		if facingFrames.lagSeen then
			local l, tot, sum = {}, 0, 0
			for age = 0, 15 do
				local c = facingFrames.lagSeen[age]
				if c then
					l[#l + 1] = string.format("%df:%d", age, c)
					tot = tot + c
					sum = sum + age * c
				end
			end
			logFile(string.format("  loopback round trip, matched against the player's own history:"
				.. " %s   (mean %.1f frames -- the floor for how late a ghost can start)",
				table.concat(l, " "), (tot > 0) and (sum / tot) or 0))
		end
		if facingFrames.stepDelta then
			for _, k in ipairs({ "d", "u", "l", "r" }) do
				local per = facingFrames.stepDelta[k]
				if per then
					local d, tot, bad = {}, 0, 0
					for v = 0, 32 do
						if per[v] then
							d[#d + 1] = string.format("%dpx:%d", v, per[v])
							tot = tot + per[v]
							if v > 0 then bad = bad + per[v] end
						end
					end
					-- The ghost is offset to the side and the core is at -interp=0ms, so a peer
					-- that tracks the player perfectly moves 0px RELATIVE to them on every frame.
					-- Any non-zero bucket is the defect, and its size is how far it jumps.
					logFile(string.format("  painted movement, facing %s: %s   (%d of %d frames "
						.. "moved relative to the player)", k, table.concat(d, " "), bad, tot))
				end
			end
		end
		if facingFrames.progSeen then
			local seen = {}
			for v = 0, 16 do
				if facingFrames.progSeen[v] then
					seen[#seen + 1] = string.format("%d:%d", v, facingFrames.progSeen[v])
				end
			end
			logFile(string.format("  peer step progress, all frames: %d walking, %d of them in the "
				.. "stepping band | prog counts %s", facingFrames.nWalkFrames or 0,
				facingFrames.nStepFrames or 0, table.concat(seen, " ")))
		end
		-- OUTSIDE the guard above, which only fires once a peer has walked. A run where the ghost
		-- never stepped is exactly the run this line has to describe, and inside that guard it
		-- would print nothing -- indistinguishable from not having looked.
		if (facingFrames.nDrawnFrames or 0) > 0 then
			-- THE INPUT AND THE OUTPUT ON ADJACENT LINES. The band above is what the peer sent;
			-- the line below is what was drawn from it. A gap between them is the renderer
			-- refusing to step, and the reasons say which of the three refusals did it -- the
			-- distinction that "the ghost stands there" cannot make on screen.
			logFile(string.format("  MODEL walk: furthest behind its destination %.0fpx (a step is "
				.. "16px), %d resyncs, %d backward steps refused, "
				.. "%d beat corrections, %d catch-up frames, %d of them free-running at rest"
				.. " | K drift %dpx over %d parks (worst %dpx), %dpx repaid on %d nudge frames,"
				.. " %d direction reversals"
				.. " | %d camera rebases",
				facingFrames.modelMax or 0, facingFrames.modelSnaps or 0,
				facingFrames.backwards or 0, facingFrames.phaseFollow or 0,
				facingFrames.catchupFrames or 0, facingFrames.freeCatchup or 0,
				facingFrames.kParkSum or 0, facingFrames.kParks or 0,
				facingFrames.kParkMax or 0, facingFrames.kFix or 0,
				facingFrames.kNudges or 0, facingFrames.kFlips or 0,
				facingFrames.camRebase or 0))
			-- THE DIRECTIONAL BREAKDOWN, on its own line so the totals line stays readable. This
			-- is the line that tests the user's "only on the down leg's stop" report.
			if facingFrames.kParkDir then
				local ds = {}
				-- LOWERCASE, and taken from `DIR_NAMES.letter` itself rather than written out --
				-- the letters are the initials of "down"/"up"/"left"/"right", so `d u l r`. Typing
				-- them uppercase here made this whole line print nothing at all on its first run,
				-- which is indistinguishable from "no parks happened". Same class of fault as the
				-- hand-rolled "durl" that table's own comment was written about.
				for i = 0, 3 do
					local dl = DIR_NAMES.letter[i]
					local b = facingFrames.kParkDir[dl]
					if b then
						ds[#ds + 1] = string.format("%s %d parks avg %.1fpx worst %dpx",
							dl, b.n, b.sum / b.n, b.max)
					end
				end
				if #ds > 0 then
					logFile("  K drift by direction of travel: " .. table.concat(ds, " | "))
				end
			end
			-- THE TWO QUESTIONS THE TOTALS CANNOT ANSWER. `wantK` moving while the camera is parked
			-- contradicts the algebra (every term is player-side), and `kFrac` says whether a
			-- fractional model position is the reason the `modelX` cancellation is inexact.
			logFile(string.format("  K target moved on %d parked frames, model was fractional on %d"
				.. " (target should be CONSTANT while parked -- if it is not, the paint's"
				.. " modelX cancellation is not exact or a 'constant' term is moving)",
				facingFrames.kWantMoves or 0, facingFrames.kFrac or 0))
			-- FRAME GAPS IN THE CAMERA SAMPLING. Anything other than 1 is a frame whose scrolling
			-- was never seen, and its pixels are then either absorbed as a fake rebase or folded
			-- into one oversized delta.
			if facingFrames.camGap then
				local gs = {}
				for g = 1, 25 do
					if facingFrames.camGap[g] then
						gs[#gs + 1] = string.format("%s%d frame%s:%d", g == 25 and ">" or "",
							g, g == 1 and "" or "s", facingFrames.camGap[g])
					end
				end
				logFile("  camera sampling gaps (1 = every frame, anything more is motion never "
					.. "seen): " .. table.concat(gs, " "))
			end
			-- WHICH of the four terms moved, on those parked frames. `camA` should be structurally
			-- incapable of moving here; if it is nonzero this branch is running when it should not.
			logFile(string.format("    of those, the term that moved was: player OAM %d,"
				.. " player tile %d, step progress %d, camera accumulator %d",
				facingFrames.kTOamN or 0, facingFrames.kTTileN or 0,
				facingFrames.kTPpxN or 0, facingFrames.kTCamN or 0))
			-- What the implausible-branch rejected, by delta. One repeated pair at ~one per park is
			-- a mechanism being misclassified, not a register rebase.
			if facingFrames.camRebaseD then
				local rs = {}
				for k, v in pairs(facingFrames.camRebaseD) do
					rs[#rs + 1] = string.format("%s:%d", k, v)
				end
				table.sort(rs)
				logFile("  camera moves REJECTED as implausible (absorbed, never painted): "
					.. table.concat(rs, " "))
			end
			-- THE REGISTER AUDIT. `wPlayerBGMapOffset` is a per-frame delta the engine zeroes every
			-- frame; `hSCX`/`hSCY` is what the screen is scrolled by. If these disagree at all, the
			-- model is clocked off the wrong quantity and every downstream reading inherits it.
			if (facingFrames.hN or 0) > 0 then
				logFile(string.format("  CAMERA REGISTER AUDIT: %d frames compared, %d agree"
					.. " (dOff == -dHSC), %d DISAGREE, %d unreadable",
					facingFrames.hN or 0, facingFrames.hAgree or 0,
					facingFrames.hDis or 0, facingFrames.hNoRead or 0))
				if facingFrames.hD then
					local hs, i = {}, 0
					for k, v in pairs(facingFrames.hD) do
						i = i + 1
						if i <= 12 then hs[#hs + 1] = string.format("[%s] x%d", k, v) end
					end
					table.sort(hs)
					logFile("    disagreements (up to 12 shapes): " .. table.concat(hs, " "))
				end
			elseif (facingFrames.hNoRead or 0) > 0 then
				logFile(string.format("  CAMERA REGISTER AUDIT: hSCX/hSCY UNREADABLE on %d frames"
					.. " -- the System Bus domain name or the addresses are wrong, so this audit"
					.. " says nothing", facingFrames.hNoRead))
			end
			-- The camera's own per-frame movement, histogrammed: the clock the model mirrors.
			if facingFrames.camD then
				local cds = {}
				for v = 1, 8 do
					if facingFrames.camD[v] then
						cds[#cds + 1] = string.format("%dpx:%d", v, facingFrames.camD[v])
					end
				end
				logFile("  CAMERA per-frame deltas: " .. table.concat(cds, " "))
				if facingFrames.camSign then
					local ss = {}
					for k, v in pairs(facingFrames.camSign) do
						ss[#ss + 1] = string.format("%s:%d", k, v)
					end
					table.sort(ss)
					logFile("  CAMERA signs by walk dir: " .. table.concat(ss, " "))
				end
			end
			-- ONE PARITY SHOULD DOMINATE. If the engine's movement tick were not tied to frame
			-- parity at all this would read roughly 50/50, and locking the ghost to it would be
			-- meaningless -- so the number that justifies the fix is printed beside it.
			if facingFrames.ghostGap or facingFrames.playerGap then
				local function gaps(t)
					local o2 = {}
					for v = 1, 8 do
						if t and t[v] then o2[#o2 + 1] = string.format("%d:%d", v, t[v]) end
					end
					return table.concat(o2, " ")
				end
				logFile(string.format("  RHYTHM, frames between moves | player %s | ghost %s",
					gaps(facingFrames.playerGap), gaps(facingFrames.ghostGap)))
			end
			if facingFrames.paritySeen then
				logFile(string.format("  ENGINE tick parity: even %d, odd %d (locked to %d) | "
					.. "ghost lead over the peer %s",
					facingFrames.paritySeen[0] or 0, facingFrames.paritySeen[1] or 0,
					facingFrames.tickParity or -1,
					(function()
						local t = {}
						for v = -8, 8 do
							if facingFrames.lead and facingFrames.lead[v] then
								t[#t + 1] = string.format("%+d:%d", v, facingFrames.lead[v])
							end
						end
						return table.concat(t, " ")
					end)()))
			end
			-- The two 1px candidates, side by side with the quantised value they would replace.
			if facingFrames.scrollD or facingFrames.oamD then
				local function hist(t)
					local o2 = {}
					for v = 0, 6 do
						if t and t[v] then o2[#o2 + 1] = string.format("%d:%d", v, t[v]) end
					end
					return table.concat(o2, " ")
				end
				logFile(string.format("  1PX SOURCE | bg scroll Y moved %s | player OAM Y moved %s",
					hist(facingFrames.scrollD), hist(facingFrames.oamD)))
			end
			if facingFrames.refD then
				for _, key in ipairs({ "v", "h" }) do
					local rr, gg = {}, {}
					for v = 0, 6 do
						local r = facingFrames.refD[key] and facingFrames.refD[key][v]
						local g = facingFrames.ghostD[key] and facingFrames.ghostD[key][v]
						if r then rr[#rr + 1] = string.format("%d:%d", v, r) end
						if g then gg[#gg + 1] = string.format("%d:%d", v, g) end
					end
					if #rr > 0 or #gg > 0 then
						logFile(string.format("  TERMS %s | player reference moved %s | ghost moved %s",
							(key == "v") and "walking up/down " or "walking left/right",
							table.concat(rr, " "), table.concat(gg, " ")))
					end
				end
			end
			logFile(string.format("  stepping view drawn on %d of %d peer-frames; not stepped: "
				.. "%d mid-step, %d idle, %d held by a turn",
				facingFrames.nStepDrawn or 0, facingFrames.nDrawnFrames or 0,
				facingFrames.nNoStepMidStep or 0, facingFrames.nNoStepIdle or 0,
				facingFrames.nNoStepRearm or 0))
		end
		-- Reported cumulatively, so it describes the RUN and not whichever second it fired in.
		if facingFrames.wire and facingFrames.wire.msgs > 0 then
			local w = facingFrames.wire
			local d = {}
			for v = 1, 9 do
				if w.dist[v] then
					d[#d + 1] = string.format("%s:%d", (v == 9) and ">=9px" or (v .. "px"), w.dist[v])
				end
			end
			logFile(string.format("  WIRE: %d messages, %d carried no movement, %d moved | %s",
				w.msgs, w.same, w.moved, table.concat(d, " ")))
			-- THE TWO CLOCKS, side by side. A run where every rendered frame got exactly one
			-- message is a run where the wire's smoothness reaches the screen intact; anything in
			-- the 0 and 2 buckets is a frame that painted nothing new followed by one that skipped
			-- a pixel, which is the stutter, and it is arithmetic rather than opinion.
			if w.perFrame then
				local pf, tot = {}, 0
				for v = 0, 6 do
					if w.perFrame[v] then
						pf[#pf + 1] = string.format("%d:%d", v, w.perFrame[v])
						tot = tot + w.perFrame[v]
					end
				end
				logFile(string.format("  ARRIVALS per rendered frame over %d frames: %s",
					tot, table.concat(pf, " ")))
			end
			-- QUARTER-PIXEL buckets and a mean. The player walks a whole number of pixels a frame;
			-- a peer that does not is being rounded to the screen grid, and the leftover is the
			-- stutter.
			if w.fine and w.nmoved and w.nmoved > 0 then
				local fq = {}
				for v = 0, 20 do
					if w.fine[v] then
						fq[#fq + 1] = string.format("%.2f:%d", v / 4, w.fine[v])
					end
				end
				logFile(string.format("  WIRE sub-pixel: %d moves under 5px, mean %.3f px/frame | %s"
					.. " | %d jumps over 5px, largest %.1fpx",
					w.nmoved, w.sum / w.nmoved, table.concat(fq, " "),
					w.big or 0, w.max or 0))
			end
		end
		if offSample then
			logFile("drawn tier: example of one it discarded -- " .. offSample)
		end
	end
end

-- The inverse of DIR_NAMES: a peer sends orientation as a name, and we need the numeric dir.
local ORIENTATION_TO_DIR = { down = 0, up = 1, left = 2, right = 3 }

local DELTA_TO_DIR = { ["0,1"] = 0, ["0,-1"] = 1, ["-1,0"] = 2, ["1,0"] = 3 }

-- The OBJECT_ACTION values a PLAYER's object can legitimately hold. The engine's own table
-- (ObjectActionPairPointers, engine/overworld/map_object_action.asm) has 17 entries, but most of
-- them are scenery -- the Copycat dolls, the Sudowoodo tree, boulder dust, shaking grass, a
-- shadow -- which the player object is never set to. A peer offering one of those is either a
-- different build or a client we should not trust, so it is ignored rather than written: inbound
-- state is peer-controlled and this one ends in a memory write.
-- The OBJECT_ACTION values a PLAYER's object can legitimately hold.
ACTIONS.peer = {
	[1] = true, -- OBJECT_ACTION_STAND
	[2] = true, -- OBJECT_ACTION_STEP
	[3] = true, -- OBJECT_ACTION_BUMP          (walking into a wall)
	[4] = true, -- OBJECT_ACTION_SPIN          (spin tiles)
	[5] = true, -- OBJECT_ACTION_SPIN_FLICKER  (the teleport/dig spin)
	[6] = true, -- OBJECT_ACTION_FISHING
	[16] = true, -- OBJECT_ACTION_SKYFALL      (the Fly landing)
}
-- OBJECT_ACTION_EMOTE (8) IS DELIBERATELY ABSENT, and used to be here. The "!" over a character's
-- head is not a pose that character adopts: `SpawnEmote` (engine/overworld/map_objects.asm)
-- creates a SEPARATE map object flagged EMOTE_OBJECT_F, so a player's own action byte never
-- becomes 8 and a peer sending it is not a peer who is emoting. Writing it would have been
-- actively wrong rather than merely useless -- FacingEmote replaces all four of the character's
-- parts with the emote box's absolute tiles, so the ghost's BODY would vanish and be replaced by
-- a box drawn on its own tile instead of above it (the -2 tile Y offset is set by
-- MovementFunction_Emote, which our write does not go through). phase9.md's 2026-08-19
-- enumeration listed the emote alongside spin as one action byte; that row was wrong.

-- Give the ghost the peer's action byte and let Crystal animate it.
--
-- This is the whole of the spawned tier's animation work, and the reason it is one line rather
-- than one branch per animation: HandleObjectAction runs for every object on every frame and
-- DERIVES OBJECT_FACING from OBJECT_ACTION (map_objects.asm calls it with
-- ObjectActionPairPointers). So the action byte selects the animation, and writing FACING
-- ourselves would be inert -- the engine overwrites it before anything is drawn.
--
-- Safe to leave written: once a ghost is idle its step function is STEP_TYPE_STANDING, which
-- touches OBJECT_WALKING and nothing else. ACTION is only reset when the object re-enters its
-- movement function (MovementFunction_Standing sets OBJECT_ACTION_STAND), which happens at the
-- END of a step -- so an action written while idle persists, and a step overwrites it with
-- OBJECT_ACTION_STEP, which is correct.
local function applyPeerAction(g, act)
	if act == nil or not ACTIONS.peer[act] then
		return
	end
	if u8(g.st_base + F_ACTION) ~= act then
		w8(g.st_base + F_ACTION, act)
	end

	-- AND STOP THE ENGINE OVERWRITING IT. Writing the action alone made this function one of TWO
	-- WRITERS on the same field, which `adapters/CLAUDE.md` already names as its own bug class:
	-- an idle ghost is pinned to SPRITEMOVEDATA_STANDING_* by setGhostStanding, and the engine's
	-- `MovementFunction_Standing` (engine/overworld/map_objects.asm) then does exactly two things
	-- that undo us -- it writes OBJECT_ACTION back to OBJECT_ACTION_STAND, and sets
	-- STEP_TYPE_RESTORE, whose `.Reset` calls RestoreDefaultMovement and GetInitialFacing and so
	-- resets OBJECT_DIRECTION too. Our write and the engine's then race every tick, which is why
	-- a spinning peer's ghost span only when it happened to win.
	--
	-- MEASURED, not reasoned (2026-08-26, whirlpool_drive + the adapter's own STEP_LAG):
	--   open water, no spin -- apply spread 0 wide, 0 frames blocked mid-step
	--   into the whirlpool  -- apply spread 8 wide, 37-133 frames blocked
	-- and the ghost read `walk=255 stype=5 dur=0` on every spin frame. Step type 5 is
	-- STEP_TYPE_RESTORE, and this adapter only ever writes 2 -- the same unexplained signature
	-- `UNVERIFIED.md` recorded on 2026-08-23 ("the ENGINE has put the object into a step type of
	-- its own choosing"), whose suspected cause was RestoreDefaultMovement and was never pinned.
	-- It is: the trigger is a peer action, and this is where it comes in.
	--
	-- STEP_TYPE_STANDING (4) is the inert one. `StepFunction_Standing` sets OBJECT_WALKING and
	-- NOTHING else -- no action, no direction -- so the peer's own bytes stand, and every "is this
	-- ghost idle" test elsewhere still reads STANDING exactly as before. Only applied while the
	-- ghost is already idle: this runs below renderRemote's `walking ~= STANDING` return, so a
	-- real step is never interrupted, and stepGhost writes step type 2 again on the next step.
	if u8(g.st_base + F_WALKING) == STANDING then
		local st = u8(g.st_base + F_STEP_TYPE)
		if st == 1 or st == 5 then -- FROM_MOVEMENT, RESTORE: the two that reach MovementFunction_Standing
			w8(g.st_base + F_STEP_TYPE, 4) -- STEP_TYPE_STANDING
		end
	end
end

-- THE SHADOW UNDER A HOPPING GHOST -- a real map object, built the way the engine builds its own.
--
-- `adapters/CLAUDE.md`: *"if the game spawns something alongside it, the ghost needs that too"*,
-- and it names shadows. The player's hop gets one from `SpawnShadow`, which `JumpStep` calls -- and
-- the ghost's hop is written straight into OBJECT_STEP_TYPE, so it bypasses that call and would
-- otherwise sail over the ledge casting nothing. **The shadow is not decoration; it is the half of
-- a hop that tells you the character is off the ground.**
--
-- BUILT FROM `CopyTempObjectToObjectStruct` (engine/overworld/player_object.asm), field for field,
-- rather than from the template it is fed -- that routine is what actually decides what a temp
-- object holds, and the template is only three of its bytes. Every value below is cited:
--   * SPRITE / MAP_OBJECT_INDEX = $ff. `CopyTempObjectData` loads -1 into both. Confirmed live
--     2026-08-26: the shadow under the player's own hop read `s=255 m=FF`.
--   * MOVEMENT_TYPE = $1b, SPRITEMOVEDATA_SHADOW. Derived from `constants/map_object_constants.asm`
--     and CHECKED AGAINST A CONTROL: the same derivation gives STANDING_DOWN..RIGHT = $06..$09,
--     which is exactly what `SPRITEMOVEDATA_STANDING_BY_DIR` in this file has always held.
--   * FLAGS1 = $8e = WONT_DELETE|FIXED_FACING|SLIDING|EMOTE_OBJECT, FLAGS2 = $01 = LOW_PRIORITY,
--     both from `data/sprites/map_objects.asm`'s SPRITEMOVEDATA_SHADOW block via
--     `CopySpriteMovementData`. The live shadow read `f2=01`, which confirms the bit order.
--   * PALETTE = 5, PAL_OW_EMOTE, from the same block.
--   * STEP_TYPE = 0 (STEP_TYPE_RESET) and FACING = STANDING: the two the copy routine writes last,
--     and the reset is what hands the object to `MovementFunction_Shadow` on the next tick.
--
-- AND THEN THE ENGINE DOES THE REST, which is the point of building a real object instead of
-- painting one. `MovementFunction_Shadow` sets the action, parks the sprite at the right offset
-- for the parent's direction, takes its LIFETIME from the parent's own step duration, switches to
-- STEP_TYPE_TRACKING_OBJECT so it follows the hop, and deletes itself at the end. None of that is
-- reimplemented here and none of it can drift from the game.
--
-- OBJECT_RANGE IS AN OBJECT-STRUCT INDEX, NOT A MAP-OBJECT ONE. `InitMovementField1dField1e` reads
-- it and calls `GetObjectStruct`, which indexes `wObjectStructs` -- so the CONSUMER settles it.
-- Worth stating because `CopyTempObjectData` fills that field from `hMapObjectIndex`, whose name
-- says the opposite, and because the engine's own shadows are spawned on the PLAYER, where struct
-- and map object are both 0 and the mistake is invisible. A ghost is struct 12 / map object 15,
-- where it is not.
--
-- DECLINES QUIETLY WHEN THE MAP IS FULL. A shadow costs an object struct, exactly as it does for
-- the game itself -- `SpawnShadow` calls `FindFirstEmptyObjectStruct` and gives up if there is
-- none. A crowded map therefore drops the shadow before it drops a character, which is the right
-- way round.
emote.shadow = function(g)
	local st = freeStruct()
	if not st then
		return -- no room; the hop still happens, without a shadow, exactly as the engine degrades
	end
	local b = OBJECT_STRUCTS + st * OBJECT_LENGTH
	-- Zeroed first. `freeStruct` only promises the sprite byte is clear, so every other field is
	-- whatever the last occupant left -- and this object is about to be handed to the engine.
	for off = 0, OBJECT_LENGTH - 1 do
		w8(b + off, 0)
	end
	w8(b + F_SPRITE, 0xFF)
	w8(b + F_MAP_OBJECT_INDEX, 0xFF)
	w8(b + 0x02, 0x00) -- OBJECT_SPRITE_TILE
	w8(b + 0x03, 0x1B) -- OBJECT_MOVEMENT_TYPE = SPRITEMOVEDATA_SHADOW
	w8(b + F_FLAGS1, 0x8E)
	w8(b + 0x05, 0x01) -- OBJECT_FLAGS2 = LOW_PRIORITY
	w8(b + F_PALETTE, emote.PAL)
	w8(b + F_FACING, STANDING)
	local sx, sy = u8(g.st_base + F_MAP_X) or 0, u8(g.st_base + F_MAP_Y) or 0
	for _, off in ipairs({ F_MAP_X, F_LAST_MAP_X, F_INIT_X }) do
		w8(b + off, sx)
	end
	for _, off in ipairs({ F_MAP_Y, F_LAST_MAP_Y, F_INIT_Y }) do
		w8(b + off, sy)
	end
	w8(b + 0x20, g.st) -- OBJECT_RANGE: the struct this shadow tracks
	-- LAST, because it is what starts the object running -- everything above has to be in place
	-- before the engine looks at it.
	w8(b + F_STEP_TYPE, 0) -- STEP_TYPE_RESET
end

local function stepGhost(g, dir, gait, jumping)
	local x = (u8(g.st_base + F_MAP_X) or 0) + ((dir == 3) and 1 or (dir == 2) and -1 or 0)
	local y = (u8(g.st_base + F_MAP_Y) or 0) + ((dir == 0) and 1 or (dir == 1) and -1 or 0)

	-- Re-pinned per step: this decides the facing the engine restores when the step ENDS, so it has
	-- to follow the direction being walked rather than stay at whatever the spawn chose.
	setGhostStanding(g.st_base, g.mo_base, dir)

	-- THE PEER'S GAIT, NOT A CONSTANT. `4 + dir` is the NORMAL row of StepVectors, and writing it
	-- unconditionally stepped a biking peer's ghost at walking pace: it fell a tile behind per
	-- step and the catch-up path then snapped it forward. The user, watching a bike lap on the
	-- compare rig 2026-08-25: *"the spawned ghost is really slow, and sometimes teleports to keep
	-- up"*, having said first that the two ghosts *"moved at really different speeds from each
	-- other"* -- the painted tier already carried the 4px stride and only this one did not.
	--
	-- Note what is NOT happening here: no rate was tuned. The group and its duration are the
	-- engine's own two numbers for the gait the peer reported, and a gait this file does not know
	-- cannot be invented -- an unknown value falls back to a normal walk.
	--
	-- AND NOT A GAIT THIS CARTRIDGE HAS NO ROW FOR. `GetStepVector` masks with $0F and indexes
	-- straight in, so a group past the end of THIS ROM's table is not a slow ghost or a refused
	-- write -- it is the engine reading the bytes after the table as a movement vector. Vanilla's
	-- table ends exactly where `GetStepVectorSign` begins. That can only happen across builds: a
	-- peer on a cartridge with a faster gait reports it honestly and this receiver may not have
	-- it. Such a peer is already being kept off this tier (`paceable`), so the clamp is the floor
	-- under that decision rather than the thing anyone sees.
	local group = ENGINE.gait(gait)
	w8(g.st_base + F_WALKING, group * 4 + dir)
	w8(g.st_base + F_DIRECTION, dir * 4)
	w8(g.st_base + F_FACING, dir * 4)
	-- STEP TYPE 2, AND NOT THE PLAYER'S 6 -- TRIED, AND IT MOVES THE CAMERA.
	--
	-- The player's own object walks on step type 6 and crosses a tile in 15.8 frames, where a ghost
	-- on type 2 crosses in 14.2, so copying the player's looked like the obvious way to make a
	-- ghost's motion a true copy rather than merely a similar one. It is not: **type 6 is the
	-- step type that SCROLLS THE CAMERA**, because moving the player is what it is for. Given to a
	-- ghost it drags the whole view around -- the user, within seconds of it loading, 2026-08-22:
	-- *"this moved/drifted the whole game camera"*.
	--
	-- So the difference in pace is the price of a ghost not being the player, and 2 is correct.
	-- Recorded here because "match the player's step type" is an obvious-looking idea that will be
	-- had again, and the reason it fails is invisible until it is on screen.
	w8(g.st_base + F_STEP_TYPE, 2)
	-- EIGHT TICKS, NOT SEVEN, BECAUSE A TILE IS 16px AND A STEP VECTOR IS 2px.
	--
	-- This was 7, which walks the sprite 14px across a 16px tile -- so every single step ended 2px
	-- short of the tile it had already been told it was standing on. That is the drift the user
	-- saw as the ghost *"slowly slid[ing] of its intended tile"*, and the snap they saw afterwards
	-- was the re-anchor taking those 2px back at the end of every step.
	--
	-- The 2px compensation that used to sit at the bottom of this function existed to paper over
	-- exactly this, and it was removed first: with it gone the re-anchor still reported 2px on
	-- essentially every step, which is what isolated the cause to the step length itself rather
	-- than to the sprite write. Two subtractions, one measurement each, no third guess.
	--
	-- 8 x 2 = 16 is not a tuned value, it is the tile. `stepProgress` elsewhere in this file
	-- already derives progress as `(8 - duration) * 2`, i.e. it has assumed a duration of 8 all
	-- along -- so the sender and the mover disagreed by one tick.
	w8(g.st_base + F_STEP_DURATION, GAIT_TICKS[group])
	w8(g.st_base + F_ACTION, 2)
	w8(g.st_base + F_MAP_X, x)
	w8(g.st_base + F_MAP_Y, y)

	-- A LEDGE HOP IS A REAL ENGINE JUMP, NOT A WALK WITH A COPIED ARC.
	--
	-- `StepFunction_NPCJump` (step type 8) is self-contained and does the WHOLE hop: `.Jump`
	-- crosses the first tile calling `UpdateJumpPosition` every tick, calls `GetNextTile` to take
	-- the second, `.Land` crosses that one the same way, and it hands itself back to
	-- STEP_TYPE_FROM_MOVEMENT at the end. So two tiles, both halves of the arc, and the correct
	-- pace -- from the game's own code, on the game's own clock.
	--
	-- THE ARC IS NOT COPIED, IT IS GENERATED. `UpdateJumpPosition` accumulates OBJECT_JUMP_HEIGHT
	-- by the step vector's speed and indexes `.y_offsets` with `height >> 1`, so across 2 tiles x 8
	-- ticks the height runs 0..32 and the index walks the full sixteen-entry table exactly once.
	-- **That is why a hop cannot be assembled out of two one-tile jumps**: one tile only reaches
	-- index 7, which is the rising half ending at -12 and never coming down.
	--
	-- STEP_TYPE_NPC_JUMP (8), NEVER THE PLAYER'S 9. `StepFunction_PlayerJump` is a different
	-- function that drives `wPlayerStepFlags` and is the step type the CAMERA follows -- the same
	-- trap already recorded above for step type 6 versus 2, which dragged the whole view around
	-- when a ghost was given the player's walking type. The peer sends "is this a hop", not its own
	-- step type, precisely so this byte cannot be copied across by accident.
	--
	-- OBJECT_STEP_INDEX (0x1c) MUST BE ZEROED. It is the anon-jumptable index
	-- (`ObjectStep_AnonJumptable`), i.e. which of `.Jump`/`.Land` runs next. A ghost that has been
	-- through any other two-phase step function still holds that function's index, and starting a
	-- hop at `.Land` gives one tile and half an arc.
	if jumping then
		w8(g.st_base + emote.F_JUMP_HEIGHT, 0)
		w8(g.st_base + emote.F_STEP_INDEX, 0)
		w8(g.st_base + F_STEP_TYPE, 8)
		emote.shadow(g)
	end
	-- THE 2px COMPENSATION IS GONE, and the re-anchor is what proved it wrong.
	--
	-- This used to add one step vector to the sprite's SCREEN position here, on the reasoning that
	-- the engine applies its own first 2px in the frame it initiates a step while ours starts a
	-- frame later, so a step would otherwise land 2px short. The error it was correcting was never
	-- measured -- only the theory was.
	--
	-- Measured 2026-08-22, once a standing ghost started being re-anchored to its own tile: the
	-- correction needed was **2px, on essentially every step**, which is precisely the size of the
	-- compensation above and in the direction that undoes it. A compensation whose exact value has
	-- to be taken back every step is not compensating for anything; it IS the error. Left in, it
	-- accumulated -- the user, with a screenshot of the ghost sitting off the grid: *"the spawned
	-- ghost gets offset/slowly slides of its intended tile when walking around"*.
	--
	-- Isolating by subtraction rather than guessing a third correction on top: `CLAUDE.md`. The
	-- re-anchor stays as a bound and as the instrument that says whether this was right -- if it
	-- goes quiet, nothing is drifting.
	--
	-- 2026-08-22, MEASURED with both step machines side by side (probes, stepcmp): the player takes
	-- 14 frames and 7 duration ticks to cross a tile; the ghost at 7 ticks came up 2px short, and
	-- at 8 ticks landed exactly but took 15 frames -- a frame slower per tile, which accumulates
	-- and is what the user saw as the spawned ghost being *"a bit delayed/slow"*.
	--
	-- So the missing 2px is real and is the frame the engine spends INITIATING a step, which our
	-- ghost never gets because the step is set up a frame later. It is recovered here rather than
	-- by lengthening the step, so the ghost keeps the player's pace exactly.
	-- AND THE COMPENSATION IS GONE AGAIN, because 8 ticks already cover the tile.
	--
	-- Adding the missing 2px here made the ghost land correctly and MOVE WRONG: it is one lump in
	-- the frame the step starts, on a frame the engine also moves, so that frame travels 4px in an
	-- otherwise 2px walk. Measured as 7 moves of 2px against the player's 6, and seen as the user's
	-- *"keeping up but snapping"*. A correction applied all at once is a snap however small it is.

	-- READ BACK the one field whose absence makes the engine run away.
	--
	-- OBJECT_WALKING's low nibble indexes StepVectors, which has 12 entries. STANDING is 255, so a
	-- nibble of 15 -- and if the step type still says "walk", the engine reads a step vector from
	-- whatever follows that table and applies it every frame until the duration runs out. That is
	-- the "went all the way up/down and off the screen" the user reported on 2026-08-21, and
	-- orphan_probe.lua caught the struct in exactly that state: WALKING=255 alongside the step type
	-- and duration this function had just written.
	--
	-- So this asks the game what it actually holds rather than trusting the write above, and only
	-- says anything when the two disagree -- silent in a healthy session.
	local back = u8(g.st_base + F_WALKING)
	if back ~= 4 + dir then
		log(string.format("MeshGhost: WROTE WALKING=%d TO STRUCT %d AND IT READS BACK %s "
			.. "(step_type=%s duration=%s). The engine walks on the step type, so this is the "
			.. "state that sends a ghost off the screen.",
			4 + dir, g.st, tostring(back), tostring(u8(g.st_base + F_STEP_TYPE)),
			tostring(u8(g.st_base + F_STEP_DURATION))))
	end
end

-- How often a ghost had to be snapped rather than walked. Counted because a teleport is the ONLY
-- thing in this adapter that can move a ghost discontinuously, so "does it feel like it snaps?"
-- and "is this being called?" are the same question -- and the answer decides whether the fix is
-- about drift or about something else entirely. Reported once a second and only when it is not
-- zero, so a healthy session stays silent.
local snaps = { n = 0, at = 0, runaways = 0 }

local function teleportGhost(g, x, y)
	-- A warp's path is not walkable; the queue would make the ghost walk toward where the peer
	-- USED to be after a teleport placed it where the peer IS.
	g.path, g.pathX, g.pathY = nil, nil, nil
	-- Ungated 2026-08-25 along with spawnGhost: liveScreenCoords is exact mid-scroll, and this
	-- gate was the documented cause of a ghost FREEZING through continuous walking and then
	-- visibly jumping when the player paused (the step-decision comment below).
	snaps.n = snaps.n + 1
	w8(g.st_base + F_WALKING, STANDING)
	w8(g.st_base + F_STEP_DURATION, 0)
	for _, off in ipairs({ F_MAP_X, F_LAST_MAP_X, F_INIT_X }) do
		w8(g.st_base + off, x)
	end
	for _, off in ipairs({ F_MAP_Y, F_LAST_MAP_Y, F_INIT_Y }) do
		w8(g.st_base + off, y)
	end
	w8(g.mo_base + M_X, x)
	w8(g.mo_base + M_Y, y)
	local sx, sy = liveScreenCoords(x, y)
	w8(g.st_base + F_SPRITE_X, sx)
	w8(g.st_base + F_SPRITE_Y, sy)
	-- STEP_TYPE_SKYFALL used to be written here, and is not any more: a landing peer is now the
	-- flying Pokemon's icon for the whole descent (BANDAGES.md #3, retired 2026-08-26), so no
	-- character falls and the engine's floor-fall has nothing to do.
end

-- Inbound state is peer-controlled: bound every number before it reaches a memory write.
-- HOLD THE PAINTED COPY UNTIL THE ENGINE'S COPY IS ACTUALLY ON SCREEN, not for a fixed number of
-- frames. ONE local, because this file sits near Lua's 200-name ceiling.
--
-- The 2026-08-23 fix held the drawn copy for exactly one extra frame, on a measurement that said
-- the engine object reaches OAM at handover+2. Re-measured 2026-08-25 across five promotions of
-- the 9x9 square drive, it reaches OAM at handover+4 every time -- so the copy was released two
-- frames early and the one-frame hole the fix was aimed at was still there:
--
--   f=1093  painted at 112,68   oam=16   (engine object absent)
--   f=1094  painted at 112,68   oam=16   (engine object absent)
--   f=1095  released                     oam=16   <- NOBODY DRAWS THE PEER
--   f=1096  --                           oam=20   <- entries 16-19 appear at 120,76/128,76/120,84/128,84
--
-- A frame count was the wrong instrument for a question about another clock. This asks the engine
-- directly: the object's own four OAM entries, at the LATCHED paint position plus the Game Boy's
-- sprite offsets (x+8, y+16 -- confirmed against the raw entry list above, not a computed match).
-- The object is parked on its tile for the whole handover, so the latched position is where it
-- lands.
--
-- Returns true while the drawn copy must be KEPT. Bounded at 8 frames so a peer whose object never
-- appears -- hidden behind UI, off screen, a slot lost to the game -- cannot pin the painted copy
-- on screen forever. Costs a 40-entry OAM scan per frame only while a handover is pending, which
-- is at most those 8 frames per promotion.
-- THE PEER'S PATH, NOT ITS LATEST TILE (2026-08-25).
--
-- The spawned ghost used to step toward wherever the peer IS. Trailing by the echo, that
-- truncates every quick reversal: the peer rides to a tile, turns on it, and by the time the
-- ghost has closed the distance the target is already back PAST it -- so the ghost turned
-- 1-2 tiles short, in open ground, and the tile the peer actually turned on was never visited.
-- The user, on a 3-tile up/down bike drill: *"like reversing instead of hitting the
-- walls/stopping. mid movement reverse"*. The chain-overshoot counter proved the shape: full
-- retraces of the turn tile logged at ONE end only -- the other end was being cut.
--
-- So each NEW peer tile is queued, and the ghost walks the queue in order, reaching every tile
-- the peer stood on -- including the one it turned on -- before following it back. The queue is
-- tiny and self-limiting: at 3 entries the ghost is a full step-chain behind, which is the
-- catch-up/teleport regime, and the queue is dropped so those paths see the live target exactly
-- as before. A teleport also clears it (a warp's path is not walkable).
-- On `facingFrames` and with the cap as a literal, because this file sits AT Lua's 200-local
-- ceiling: two new top-level locals here pushed it to 201 and the adapter refused to compile --
-- the wall emulator/CLAUDE.md warns about, hit live while adding this very function.
function facingFrames.pathGoal(g, x, y, cx, cy)
	local q = g.path
	if g.pathX ~= x or g.pathY ~= y then
		-- A new target. Queue the PREVIOUS one if the ghost has not reached it yet -- it is a
		-- tile the peer stood on that the ghost still owes a visit.
		if g.pathX ~= nil and (g.pathX ~= cx or g.pathY ~= cy)
			and math.abs(g.pathX - x) + math.abs(g.pathY - y) == 1 then
			q = q or {}
			q[#q + 1] = { g.pathX, g.pathY }
			g.path = q
		end
		g.pathX, g.pathY = x, y
	end
	if q then
		-- Drop reached and stale entries from the front.
		while q[1] and ((q[1][1] == cx and q[1][2] == cy)
			or (q[1][1] == x and q[1][2] == y)) do
			table.remove(q, 1)
		end
		if #q > 3 then
			g.path = nil -- too far behind: the deficit paths below want the live target
		elseif q[1] then
			return q[1][1], q[1][2]
		end
	end
	return x, y
end

local function holdHandover(o)
	if not (o and o.handover) then
		return false
	end
	if drawFrames - o.handover > 8 then
		return false
	end
	if not o.handoverSX then
		-- The latch is taken by the draw loop, which may not have run yet this frame. No position
		-- to test against means the handover has certainly not completed.
		return true
	end
	-- WITHIN A STRIDE, not exact (2026-08-25). The exact match was written for a promotion out of
	-- IDLE, where the body arrives standing on the latched tile. A peer promoted WHILE MOVING --
	-- every bike promotion -- has its body stepping away from the latch from its first engine
	-- tick, so the exact match never hit, the hold always ran its full 8 frames, and the user saw
	-- the painted copy and the moving body as *"a 2nd ghost when moving again (after the
	-- despawn)"* -- two bodies drawing half a tile apart at bike pace. The hold's job is only to
	-- cover the frames before the body reaches OAM at all; one engine tick of tolerance per axis
	-- (the fast gait's 4px) recognises a body that has arrived and already moved.
	local wx, wy = o.handoverSX + 8, o.handoverSY + 16
	for e = 0, 39 do
		local ex = memory.read_u8(e * 4 + 1, "OAM") or 0
		local ey = memory.read_u8(e * 4, "OAM") or 0
		if math.abs(ex - wx) <= 8 and math.abs(ey - wy) <= 8 then
			return false
		end
	end
	return true
end

local function renderRemote(id, state)
	if not inPlay() or type(state) ~= "table" then
		return
	end
	if state.extras ~= nil and type(state.extras) ~= "table" then
		-- Every extras read below indexes it; a number or boolean here raised, and
		-- until the main loop was guarded that killed the script. Treated as absent.
		-- 2026-09-02 adversarial review.
		state.extras = nil
	end
	local pos = state.position
	if type(pos) ~= "table" or type(pos[1]) ~= "number" or type(pos[2]) ~= "number" then
		return
	end

	-- CROSS-MAP GHOSTS, TRANSLATED AT INGEST. A peer standing on a map CONNECTED to ours is
	-- rewritten into our own tile frame right here, so everything below -- the area gate, the
	-- range cull, both tiers, collision, the painted copy -- sees ordinary local coordinates and
	-- needed no changes at all. A peer anywhere else keeps its own area_id and is hidden by the
	-- gate below, exactly as before this feature existed.
	--
	-- `state` is a freshly decoded message, never a cached one, so rewriting it in place is safe.
	--
	-- The range cull a few hundred lines down is what keeps this cheap: a translated peer far
	-- along a neighbouring route is simply out of range and holds nothing. Nothing here needs its
	-- own distance test.
	if ENGINE.xmap.armed() and state.area_id ~= nil then
		local here = areaId()
		if ENGINE.xmap.connsFor ~= here then
ENGINE.xmap.build(here) end
		if state.area_id ~= here then
			local tx, ty = ENGINE.xmap.translate(state.area_id, pos[1], pos[2])
			if tx then
				-- COMPONENTS 3 AND 4 MOVE TOO, and forgetting them is why the first version of
				-- this feature made every cross-map peer look like it was teleporting tile to
				-- tile. `position` carries the tile in [1],[2] and the character's position in
				-- ABSOLUTE MAP PIXELS in [3],[4] -- and the smooth motion lives entirely in the
				-- pixel pair, because the tile pair is a staircase by construction. Translating
				-- the tiles alone left the pixels describing a point on the NEIGHBOUR's map, so
				-- the drawn tier had nothing usable to glide along and fell back to whole tiles.
				-- The user, 2026-08-27: *"going around in another route still looks
				-- snap/teleporting ish to someone watching from another route"*.
				--
				-- Same delta, in pixels. Applied BEFORE [1],[2] are overwritten, because the
				-- delta is defined against the untranslated values.
				local dx, dy = tx - pos[1], ty - pos[2]
				if type(pos[3]) == "number" then pos[3] = pos[3] + dx * 16 end
				if type(pos[4]) == "number" then pos[4] = pos[4] + dy * 16 end
				-- ONCE per peer per (their map -> our map) pair, never per frame: this is the one
				-- line that says the feature is actually live rather than a peer happening to be
				-- on our own map, and a per-frame version of it would cost the frame rate it is
				-- reporting on (adapters/emulator/CLAUDE.md).
				local k = id .. "|" .. state.area_id .. "|" .. here
				if not ENGINE.xmap.said[k] then
					ENGINE.xmap.said[k] = true
					-- %s, not %d: a fractional tile (the core interpolates position, and a
					-- peer may send anything) makes Lua 5.4's %d raise, and this log runs
					-- inside the frame. Found by the 2026-09-02 adversarial review.
					log(string.format("cross-map: %s is on %s, %s,%s -- translated to %s,%s on"
						.. " our %s (via its %s connection)", id, state.area_id, pos[1], pos[2],
						tx, ty, here,
						(ENGINE.xmap.conns[state.area_id] or {}).dir or "?"))
				end
				state.area_id, pos[1], pos[2] = here, tx, ty
			end
		end
	end
	-- When did we last hear from this peer? Kept on the activity record, which already exists per
	-- peer, so this costs no new bookkeeping. tick() uses it to forget peers that stop sending --
	-- see the sweep there for why a peer can vanish without ever being despawned.
	local a = activity[id]
	if not a then
		a = { x = -1, y = -1, movedAt = policyFrames, passableUntil = 0 }
		activity[id] = a
	end
	a.seenAt = policyFrames

	-- Declared HERE, above every use. They were previously declared after the compare block that
	-- reads them, so those two copies resolved a nonexistent GLOBAL instead: prog and walking came
	-- out nil, the sub-tile offset was zero, and the painted copy could only land on the
	-- destination tile -- the user saw it teleport rather than walk (2026-08-21). Lua gives no
	-- warning for this; a use-before-declaration is a silent nil, not an error.
	-- WIRE INSTRUMENT, COMPARE_TIERS only. Measures ONE thing at ONE point: how the peer's position
	-- changes between consecutive messages as they ARRIVE, before any tier touches it.
	--
	-- Built this way because the previous version could not be trusted. It reported "1 distinct
	-- peer position this second" and that was read as the sub-tile component being frozen -- when
	-- `square_drive` simply pauses at corners, so a stationary second had been sampled and taken as
	-- evidence. A whole change was reverted on it. So: no per-second snapshots, no gating on a
	-- `walking` flag that can be stale, and the count of UNCHANGED messages is reported beside the
	-- changed ones, because "nothing moved" and "nothing was sampled" have to be distinguishable.
	if facingFrames.stats() then
		local w = facingFrames.wire
		if not w then
			w = { msgs = 0, same = 0, moved = 0, dist = {} }
			facingFrames.wire = w
		end
		w.msgs = w.msgs + 1
		-- HOW MANY MESSAGES LANDED ON EACH RENDERED FRAME, zero-message frames included.
		--
		-- The wire histogram below says the peer's position arrives one pixel at a time, and the
		-- painted histogram says the ghost's SCREEN position moves 2-3px on about a quarter of the
		-- frames it moves at all. Both can be true at once: the core interpolates on wall-clock and
		-- the emulator renders on its own, so at a nominal 60 of each the two drift against one
		-- another, and a frame that receives nothing is followed by one that receives two. The
		-- adapter paints the newest position, so those become a 0px frame and a 2px frame -- a
		-- stutter built entirely out of smooth data.
		--
		-- Nothing else in the log can see this. A per-message instrument cannot: every one of those
		-- messages is a clean 1px. A per-second rate cannot either -- it reads exactly 60/s, which
		-- is the average being complained about. It takes counting the two clocks against each
		-- other, one frame at a time.
		local wf = emu.framecount()
		if w.frame ~= wf then
			if w.frame then
				w.perFrame = w.perFrame or {}
				local n = w.inFrame or 0
				w.perFrame[n] = (w.perFrame[n] or 0) + 1
				-- THE FRAMES THAT RECEIVED NOTHING, which are the whole point and which a handler
				-- that only runs on arrival can never be called for. They are counted by the gap
				-- between the frame numbers instead.
				local gap = wf - w.frame - 1
				if gap > 0 and gap < 600 then
					w.perFrame[0] = (w.perFrame[0] or 0) + gap
				end
			end
			w.frame, w.inFrame = wf, 0
		end
		w.inFrame = (w.inFrame or 0) + 1
		local px = (type(pos[3]) == "number") and pos[3] or (pos[1] * 16)
		local py = (type(pos[4]) == "number") and pos[4] or (pos[2] * 16)
		if w.lx then
			local d = math.abs(px - w.lx) + math.abs(py - w.ly)
			-- THE SUB-PIXEL TRUTH, because the whole-pixel histogram below cannot tell 0.5px from
			-- 1.49px -- it rounds to an integer key and clamps the lowest bucket to 1, so it reports
			-- a confident "1px" for anything in that range. That was fine while it was answering
			-- "are whole tiles arriving?", and it is the wrong instrument for the question it is
			-- being asked now.
			--
			-- The question now: with -interp=0ms the peer's positions are the player's OWN past
			-- integers, so the ghost paints exactly as the player did; at the shipped 250ms the core
			-- INTERPOLATES, and a peer advancing a fractional number of pixels a frame has to be
			-- rounded to an integer screen pixel, which paints 2,2,1,2,2,1... That is a correct
			-- rendering of fractional motion and it reads as a stutter beside a player moving in
			-- even steps -- and it would appear at shipped settings ONLY, which is exactly when it
			-- is reported.
			--
			-- So: quarter-pixel buckets, plus the running total and count, which give the mean
			-- speed. A mean that is not the player's own pixels-per-frame is the defect, stated as
			-- a number instead of as "a bit jittery".
			if d >= 0.01 then
				w.fine = w.fine or {}
				local fk = math.floor(d * 4 + 0.5)
				-- A CLAMPED BUCKET MUST NOT FEED THE MEAN. First run of this instrument reported
				-- "mean 2.708 px/frame" over a histogram whose own contents average 1.01 -- because
				-- ONE move of about 98px (a map change, or the ghost being replaced) was filed
				-- under the top bucket, where it looks like a single 5px sample, while `sum`
				-- carried all 98 of it. The number that would have been quoted was nearly three
				-- times the truth, from a probe written this same session to be trustworthy.
				--
				-- So the mean is taken over IN-RANGE moves only, and the outliers are reported
				-- separately with the largest one's actual size -- a jump is a different event from
				-- a stutter and averaging the two describes neither.
				if fk > 20 then
					w.big = (w.big or 0) + 1
					w.max = math.max(w.max or 0, d)
				else
					w.fine[fk] = (w.fine[fk] or 0) + 1
					w.sum = (w.sum or 0) + d
					w.nmoved = (w.nmoved or 0) + 1
				end
			end
			if d < 0.5 then
				w.same = w.same + 1
			else
				w.moved = w.moved + 1
				-- ROUNDED TO AN INTEGER KEY. An interpolated position is a FLOAT, so bucketing by
				-- the raw value files 2.5px under the key 2.5 -- which the report, looping over
				-- integers, never reads. First run: 224 movements recorded and 2 reported. An
				-- instrument that silently drops 99% of its samples is worse than none, and this
				-- one was built THIS session specifically to be trustworthy.
				local k = math.floor(d + 0.5)
				if k < 1 then k = 1 end
				if k > 9 then k = 9 end -- 9 means "9px or more", i.e. a jump
				w.dist[k] = (w.dist[k] or 0) + 1
			end
		end
		w.lx, w.ly = px, py
	end
	-- The peer's position in MAP PIXELS, interpolated by the core in lockstep with the tile because
	-- it rides in `position` rather than in `extras`. nil from a peer that does not send it, and the
	-- drawn tier then falls back to the `extras.prog` path, which is still correct with
	-- interpolation off.
	local peerPixX = (type(pos[3]) == "number") and pos[3] or nil
	local peerPixY = (type(pos[4]) == "number") and pos[4] or nil
	-- COMPARE.dy, applied ONCE at the source rather than at each place a position is written.
	-- Every tier reads this pixel position -- the spawned object, the drawn copy, and the
	-- drawn-overflow entry a peer falls back to while it has no engine slot -- and shifting it per
	-- site is how the first attempt broke: the overflow sites kept the unshifted pixY, so the ghost
	-- dropped a tile the moment it despawned and snapped back on respawn (user, 2026-08-25). The
	-- tile-level `y` below is shifted to match, once, for the same reason. Inert while dy is 0.
	if COMPARE_TIERS and peerPixY and id:match("%-ghost$") then
		peerPixY = peerPixY + COMPARE.dy * 16
	end
	-- The peer's gait group (0 slow / 1 normal / 2 fast), defaulting to a normal walk for a peer
	-- that does not send one -- an older client, or one whose adapter predates the field.
	local peerGait = state.extras and tonumber(state.extras.gait) or 1
	local peerProg = state.extras and tonumber(state.extras.prog) or nil
	local peerWalking = (state.anim == "walk")
	-- Only the low two bits are used, but the whole byte is carried so a log shows the direction
	-- the sender was in as well as the stride -- the pair is what makes a facing trace readable.
	local peerFace = state.extras and tonumber(state.extras.face) or nil
	-- The engine's own vertical nudge, signed. A peer on an older build sends nothing, which reads
	-- as nil and leaves the ghost exactly where it was drawn before.
	-- IS THIS PEER HOPPING A LEDGE. See the send side for why this is a question rather than the
	-- peer's own step type: the receiver must write STEP_TYPE_NPC_JUMP (8) and never the player's
	-- STEP_TYPE_PLAYER_JUMP (9), which drives the camera.
	local peerJump = state.extras and state.extras.jump and true or false
	local peerYoff = state.extras and tonumber(state.extras.yoff) or nil
	if peerYoff and peerYoff > 127 then peerYoff = peerYoff - 256 end
	-- CLAMPED TO THE ENGINE'S OWN ENVELOPE, once, here, so both tiers get the same number.
	-- ±96 is not a taste value: `StepFunction_SkyfallTop` writes exactly $60 and the fall in
	-- `StepFunction_Skyfall` runs `Sine` scaled by $60, so -96..+96 is the whole range this byte
	-- ever holds in the game (a jump arc reaches -12, the bite wiggle 1). Inbound state is
	-- peer-controlled and this value now ends in a memory write on the spawned tier as well as an
	-- offset on the drawn one, so it is floored and bounded before either sees it -- the same
	-- treatment `ACTIONS.peer` gives the action byte.
	if peerYoff then
		peerYoff = math.floor(peerYoff)
		if peerYoff > 96 then peerYoff = 96 elseif peerYoff < -96 then peerYoff = -96 end
	end
	local peerEmote = state.extras and tonumber(state.extras.emote) or nil
	-- What the peer's own object is DOING, in the engine's own terms. Floored before it can reach
	-- a write, and checked against ACTIONS.peer there; a peer on an older build sends no `act` at
	-- all, which reads as nil and leaves the ghost animating exactly as it did before.
	--
	-- DECLARED HERE, ABOVE EVERY USE, and that is the whole reason it moved. It used to sit ~130
	-- lines below this point, which was fine while only the spawned tier read it -- but the drawn
	-- tier's entries are built ABOVE that, including the MESHGHOST_COMPARE_TIERS copy, and a local
	-- referenced above its declaration is a nil GLOBAL in Lua, silently. So `act` reached the
	-- comparison copy as nil and the bump animation would have looked simply not to work, on the
	-- exact rig used to judge it. Fourth time this file has hit that trap (`pitfalls.md`).
	local peerActRaw = state.extras and tonumber(state.extras.act) or nil
	local peerAct = peerActRaw and math.floor(peerActRaw) or nil

	local isLoopback = id:match("%-ghost$") ~= nil
	local baseX = math.floor(pos[1])
	-- Loopback only. A real peer already stands where they stand, and the offset exists solely so
	-- an echo of yourself is not hidden underneath you.
	local offsetX = isLoopback and LOOPBACK_OFFSET_X or 0
	-- Compare mode OVERRIDES the loopback offset outright rather than only filling in for a 0:
	-- the two copies' placement is the whole point of the mode, and LOOPBACK_OFFSET_X's own
	-- default (2) would otherwise leave the spawned copy wherever that default happens to put it.
	if COMPARE_TIERS and isLoopback then offsetX = COMPARE.spawned end
	local x, y = baseX + offsetX, math.floor(pos[2])
	if COMPARE_TIERS and isLoopback then y = y + COMPARE.dy end
	-- A TRANSLATED PEER LEGITIMATELY HAS NEGATIVE COORDINATES, and this guard used to discard it.
	--
	-- The guard's real subject is "a coordinate that cannot be written into the engine's u8
	-- fields", which was the same thing as "off the map" for as long as every peer stood on OUR
	-- map. Cross-map translation broke that: a peer one tile across the WEST seam is at x = -1 by
	-- construction, so this returned before the area gate, the range cull and the overflow update
	-- had run -- leaving the drawn entry frozen at wherever it last was and never cleared. The
	-- user, 2026-08-27: *"when walking away far, the ghost is still stuck/drawn at the edge of the
	-- screen until going into a house or coming close to the other player again"*. Both of those
	-- recoveries are this guard letting go: approaching brings x back above 0, and a house is not
	-- a connected map so the peer is never translated and its own coordinates are positive.
	--
	-- So the u8 question moves to where u8s are actually written -- the SPAWNED tier, which is
	-- gated on the peer standing inside our own map (see `inOurMap` below). What is
	-- left here is only a sanity bound on a corrupt or absurd message. The window is generous
	-- because the range cull below is the real limit: anything surviving it is within
	-- GHOST_RANGE_TILES of the player regardless of what this allows.
	local lo, hi = 0, 255
	if ENGINE.xmap.armed() then lo, hi = -160, 415 end
	if x < lo or x > hi or y < lo or y > hi then
		return
	end


	-- STEP_LAG: ARRIVE. The peer's destination tile as it reaches us, against the frame the PLAYER
	-- committed to that same tile. Loopback only -- off it the peer is somebody else and there is no
	-- COMMIT frame to subtract, which is a limit of the measurement and not of the fault.
	--
	-- Taken BEFORE every gate below rather than after: a tile this function then declines to act on
	-- is not a tile that did not arrive, it is precisely the delay being measured. Recording it at
	-- the point of action instead would make the instrument agree with itself and say nothing.
	if stepLag.on and isLoopback then
		local key = baseX .. "," .. y
		if stepLag.seen[id] ~= key then
			stepLag.seen[id] = key
			local at = stepLag.commit[key]
			if at then
				local now = emu.framecount()
				stepLag.open[id] = { at = now, wire = now - at, commit = at }
			else
				-- The player never took this tile. On loopback that means the ring has forgotten it
				-- (a stall longer than the map's worth of tiles) or `offsetX` is not what this
				-- assumes -- either way the sample is unusable. Counted, so a run whose numbers came
				-- mostly from nowhere is visible as such instead of averaging into the answer.
				stepLag.open[id] = nil
				stepLag.unknown = stepLag.unknown + 1
			end
		end
	end

	-- A peer in a different area has no meaningful position here -- in EITHER tier. Clearing only
	-- the spawned one left the drawn tier painting peers from the map you just walked out of.
	if state.area_id ~= areaId() then
		despawnGhost(id)
		overflow[id] = nil
		overflow[COMPARE.key(id)] = nil
		overflow[COMPARE.hwKey(id)] = nil
		return
	end

	-- A PEER THAT ARRIVES BY FLY DROPS OUT OF THE SKY. `extras.entry` is the sender's own
	-- MAPSETUP_* byte (see getLocalState); $FC is MAPSETUP_FLY. The user's call, 2026-08-26,
	-- choosing between this and a plain teleport-in: the engine cannot show another character
	-- FLYING (the fly itself is a private cutscene, `documentation.md`), but it can absolutely
	-- drop one -- STEP_TYPE_SKYFALL is the same fall the Burned Tower floor gives the player.
	--
	-- The drop starts when the flag is worn AND the peer's tile jumps, which is the landing
	-- reaching us; one drop per flag-wearing, so the peer walking away afterwards cannot
	-- retrigger it. 64 frames total, matching the engine's own StepFunction_Skyfall at the
	-- measured 2-frames-per-engine-tick: 16 ticks hidden, then 16 ticks falling from -96 to 0 on
	-- a quarter sine -- the very curve the engine computes (`Sine` scaled by $60). The SPAWNED
	-- ghost runs the real thing (see teleportGhost); this block drives the PAINTED copies, so the
	-- tiers land in step with each other.
	-- THE SPECIES THAT CARRIED THIS PEER. Declared HERE, above every use -- it was missing
	-- entirely for three live cycles, and Lua gave no hint: an undeclared name is a nil GLOBAL,
	-- so `peerFly` simply read nil at both sites while `extras.fly` was arriving perfectly. The
	-- log said so outright once the received keys were printed -- `fly=155` on one line and
	-- `wireFly=nil` on the next, from the same state, in the same trace block. Fifth time this
	-- file has been bitten by a use-before-declaration (`pitfalls.md`), and the first four are
	-- documented within a few hundred lines of here.
	local peerFly = state.extras and tonumber(state.extras.fly) or nil
	-- ARMED BELOW THE AREA GATE AND AFTER THE WORLD HAS SETTLED, so t=0 is the first frame this
	-- peer is actually renderable here -- which is the whole of the cross-town fault. Measured
	-- 2026-08-26 with the trace: `f=3659 hide t=0 ghost=false` then `f=3691 fall t=32 ghost=true
	-- step=14`. The envelope started at the LANDING, but on a cross-town fly the map is still
	-- loading then, so no ghost object can exist for ~32 frames: the painted copy ran its hide and
	-- began falling while the engine tier had not started at all, and the engine's own 64-frame
	-- fall then ran on from there. Two tiers, two clocks, half an envelope apart -- the user:
	-- *"the drawn ghost is just dropping down and not doing it properly, the spawned ghost is
	-- kinda just teleporting"*. A same-town fly never showed it because nothing is reloading, so
	-- the ghost is placeable on the very frame the drop arms and both clocks start together.
	local peerEntry = state.extras and tonumber(state.extras.entry) or nil
	-- THE MAP RELOADING WHILE THE PEER WEARS THE FLAG IS ITSELF A LANDING, whatever the
	-- coordinates say. The geometry test below exists for a REMOTE peer landing in our view --
	-- there a tile jump is the only evidence we get. But a fly to the town you are already in can
	-- land you on the very tile you left from, and the game plays the whole landing anyway; on
	-- that fly the position never jumps and the drop never armed (measured 2026-08-26: one
	-- `flagged` trace line, no hide, no fall, wireFly arriving fine). Our own map load is the
	-- settle window, so: flag worn while the world rebuilds -> a landing is pending, armed the
	-- moment the world settles. A real remote peer flying tile-to-same-tile in our view still
	-- gets no drop -- there is genuinely no signal for that case -- and that is recorded as a
	-- known limit, not silently.
	if peerEntry == 0xFC and (playerHistory.settle or 0) > 0 then
		a.flyPending = true
	end
	if peerEntry == 0xFC and not a.dropDone and (playerHistory.settle or 0) == 0 then
		-- EITHER a tile jump, OR no previous position to compare against. The second half is the
		-- CROSS-MAP fly, and leaving it out is why that case still blinked in while a same-town
		-- fly fell correctly (the user, 2026-08-26: *"it looks fine when landing now, but only if
		-- its flying to the same town"*). Arriving on a different map clears this peer's whole
		-- bookkeeping -- ghosts, painted entries, and the last-known tile this comparison needs --
		-- so there is no `flyX` left to jump FROM and the drop could never arm. A peer wearing
		-- MAPSETUP_FLY that we have no previous position for has, by definition, just arrived
		-- somewhere: that IS the landing.
		if a.flyPending or (not a.flyX) or a.flyArea ~= state.area_id
			or (math.abs(x - a.flyX) + math.abs(y - a.flyY)) > 3 then
			a.dropAt, a.dropDone, a.flyPending = drawFrames, true, nil
		end
	elseif peerEntry ~= 0xFC then
		a.dropDone, a.flyPending = nil, nil -- the flag was shed; the next fly is a new drop
	end
	local dropT = a.dropAt and (drawFrames - a.dropAt) or nil
	-- LATCHED THE MOMENT IT ARRIVES, not once the drop is already running -- which is the whole of
	-- the "no Pokemon sprite" fault. `extras.fly` reaches us with the peer's first post-fly state
	-- and the drop arms LATER, because it waits for the world to settle: a latch gated on `dropT`
	-- could only catch the species on a frame where it happened to still be on the wire, and it
	-- never was. Measured 2026-08-26 by logging the received keys -- `fly=155` arriving while that
	-- same run's `heldFly` stayed nil through every phase of the landing.
	--
	-- It also has to outlive the sender's window, which closes well before a distant peer has
	-- finished landing. So it is held until the peer sheds the fly flag with no drop in progress.
	if peerFly then
		a.flySpecies = peerFly
	elseif peerEntry ~= 0xFC and not dropT then
		a.flySpecies = nil
	end

	-- BRACKET EVERY FLY WITH A FULL CACHE DUMP. The garbled sprite survives the landing and the
	-- cache is never cleared except by an adapter reload -- which is exactly what deploying a fix
	-- does, so the evidence has been destroyed by every attempt to look at it. Dumping on the drop
	-- and again two seconds later puts the before and after of each fly in the log, so a session
	-- that garbles on the third fly says which sample did it and when.
	if _G.MESHGHOST_CRYSTAL_FACING_TRACE and dropT and (dropT == 0 or dropT == 120) then
		for fc = 0, 3 do
			local e = facingFrames[fc]
			if e then
				local parts = {}
				if e.stand then
					parts[#parts + 1] = "stand=" .. table.concat({ e.stand[1].offset,
						e.stand[2].offset, e.stand[3].offset, e.stand[4].offset }, ",")
				end
				for st = 0, 3 do
					if e.step[st] then
						parts[#parts + 1] = string.format("step%d=%s", st,
							table.concat({ e.step[st][1].offset, e.step[st][2].offset,
								e.step[st][3].offset, e.step[st][4].offset }, ","))
					end
				end
				logFile(string.format("cache-dump: f=%d t=%d facing=%d %s", drawFrames, dropT, fc,
					(#parts > 0) and table.concat(parts, "  ") or "(empty)"))
			end
		end
	end
	-- FLY TRACE, off unless MESHGHOST_CRYSTAL_FLY_TRACE is set. Three live cycles have now been
	-- spent guessing which placement path a landing takes, so this prints the whole envelope
	-- instead: when it armed and why, what the peer is reporting, whether the ghost object exists,
	-- and what the engine has done with its step type. Edge-triggered on the phase so a drop is a
	-- handful of lines, not 64.
	if _G.MESHGHOST_CRYSTAL_FLY_TRACE and (dropT or peerEntry == 0xFC) then
		local ph = dropT and ((dropT < 32) and "hide" or "fall") or "flagged"
		if ENGINE.flyPh ~= ph or ENGINE.flyId ~= id then
			ENGINE.flyPh, ENGINE.flyId = ph, id
			local gg = ghosts[id]
			-- EVERY KEY THAT ACTUALLY ARRIVED, because `entry` crosses the wire and `fly` does
			-- not while both are built by one table literal under the same guard -- which is not
			-- possible unless one of them was never put there. Reading the received keys settles
			-- whether this is a send fault or a receive fault; nothing else has.
			local ks = {}
			for k2, v2 in pairs(state.extras or {}) do
				ks[#ks + 1] = k2 .. "=" .. tostring(v2)
			end
			table.sort(ks)
			logFile("fly-extras: " .. table.concat(ks, " "))
			logFile(string.format("fly: f=%d %s %s t=%s entry=%s wireFly=%s heldFly=%s icon=%s "
				.. "area=%s at %d,%d (was %s,%s area %s) ghost=%s facing=%s armed=%s",
				drawFrames, id, ph, tostring(dropT), tostring(peerEntry),
				tostring(peerFly), tostring(a.flySpecies),
				tostring(a.flySpecies and facingFrames.iconGfx(a.flySpecies)),
				tostring(state.area_id), x, y, tostring(a.flyX), tostring(a.flyY),
				tostring(a.flyArea), tostring(gg ~= nil),
				gg and tostring(u8(gg.st_base + F_FACING)) or "-",
				tostring(a.skyfallArmed))
				.. string.format(" ov=%s ovDrop=%s iconPaints=%s",
					tostring(overflow[id] ~= nil),
					tostring(overflow[id] and overflow[id].drop),
					tostring(facingFrames.iconPaints or 0)))
		end
	end
	-- 44 FRAMES, WHICH IS THE ENGINE'S OWN LANDING and not a duration of ours:
	-- `SpriteAnimFunc_FlyTo` moves 2px a frame from a wrapped 252 to its resting 84.
	if dropT and (dropT >= facingFrames.FLY_FRAMES or dropT < 0) then
		a.dropAt, dropT = nil, nil
	end
	-- UPDATED LAST, BELOW THE TRACE, because a trace that prints the value it has just written
	-- says nothing -- the first version of this line printed `was 20,26` for a peer standing at
	-- 20,26 and hid the arming condition completely.
	--
	-- THE AREA IS PART OF THE COMPARISON, not decoration. Map coordinates are map-LOCAL, so a
	-- cross-town landing routinely reads as a SHORT hop -- fly from tile 10,5 on one map to 12,6
	-- on another and the distance test sees three tiles and declines to arm. Comparing two
	-- positions from different maps is meaningless in the first place; a changed area IS the jump.
	--
	-- AND FROZEN WHILE A LANDING IS PENDING, which is the whole of the fifth attempt. Adding the
	-- settle gate above stopped the drop arming DURING the map load, correctly -- but this line
	-- went on running through those frames, so by the time the world had settled the "previous"
	-- position WAS the landing tile and the area matched it. The jump had been consumed by the
	-- very window that was suppressing the decision, and the drop then never armed at all: the
	-- trace showed one `flagged t=nil` line and no hide or fall phase on either tier.
	--
	-- So while a peer wears MAPSETUP_FLY and has not yet dropped, its last-known position is held
	-- as of BEFORE the fly. `dropDone` releases it, and a peer that never lands (a fly that is
	-- cancelled) simply resumes updating when the flag expires.
	if not (peerEntry == 0xFC and not a.dropDone) then
		a.flyX, a.flyY, a.flyArea = x, y, state.area_id
	end
	if dropT and dropT >= 32 then
		-- -96 rising to 0; overrides the peer's own (zero) yoff for the painted tiers only. The
		-- spawned ghost's write is guarded separately, because its engine owns the byte mid-fall.
		peerYoff = -96 + math.floor(96 * math.sin(((dropT - 32) / 32) * (math.pi / 2)))
	end

	-- A ghost that is nowhere near the player gives its slots back, because the engine's own
	-- characters do. This is not an optimisation, it is the fix for two symptoms the user saw
	-- within a minute of each other on 2026-08-19:
	--   * NPCs popping in and out. Crystal hands a struct to each of its characters as they come
	--     into range and takes it back when they leave. A ghost carries ENGINE.WONT_DELETE, so it
	--     held one FOREVER -- and a crowd of peers held nearly all 13, leaving the game none for
	--     its own cast. Measured: an NPC standing ONE TILE from the player, simply not drawn.
	--   * Invisible collisions. A ghost off the screen still occupied its tile, so the player
	--     walked into a solid character they could not see. An NPC that far away is not there.
	-- Beyond the visible window (10x9 tiles), so a ghost exists slightly before it can be seen and
	-- nothing pops in at the screen edge.
	local px, py = u8(OBJECT_STRUCTS + F_MAP_X) or 0, u8(OBJECT_STRUCTS + F_MAP_Y) or 0
	if math.max(math.abs(x - px), math.abs(y - py)) > GHOST_RANGE_TILES then
		despawnGhost(id)
		-- `overflow[id]` TOO -- the real drawn entry, not just the two COMPARE copies. Without it
		-- this gate despawns the object and leaves the painted ghost behind, frozen at its last
		-- position, and the draw loop keeps painting it at the edge of the screen forever. It went
		-- unnoticed until cross-map ghosts existed because the AREA gate above (which does clear
		-- it) caught every distant peer first: a peer far enough to be out of range was almost
		-- always on another map. Translating connected maps into our own frame moved that peer
		-- from the area gate to this one, and the leak became visible immediately -- the user,
		-- 2026-08-27: *"when walking far away from someone while in another route, you get
		-- stuck/drawn at the edge of their screen"*, and it cleared on entering a building,
		-- which is the area gate finally firing.
		overflow[id] = nil
		overflow[COMPARE.key(id)] = nil
		overflow[COMPARE.hwKey(id)] = nil
		return
	end

	-- MESHGHOST_COMPARE_TIERS: the same peer, painted on the other side of the player, so the two
	-- renderers can be judged against each other in one frame. Written every frame like any drawn
	-- peer, and carrying its own movement history so it animates rather than sliding.
	if COMPARE_TIERS and isLoopback then
		local ck = COMPARE.key(id)
		local prev = overflow[ck]
		-- Each copy is PINNED to one renderer, or the comparison quietly collapses: with the
		-- hardware tier on, every resident peer is claimed by it first and nothing is ever painted,
		-- so the drawn copy would silently become a second hardware copy. `only` says which rung a
		-- copy belongs to and the draw loop honours it.
		-- Only when the hardware tier is actually ON. Pinned to a rung that is switched off, this
		-- copy renders nothing and still counts as a peer waiting -- a phantom in every tier total.
		local hk = COMPARE.hwKey(id)
		local hprev = overflow[hk]
		overflow[hk] = OAM_TIER and { prog = peerProg, walking = peerWalking, face = peerFace, act = peerAct, gait = peerGait,
			yoff = peerYoff, emote = peerEmote, jump = peerJump, drop = dropT, flyMon = a.flySpecies,
			-- The pixel position is ABSOLUTE, so a copy placed elsewhere needs it moved by the same
			-- whole tiles or it paints at the peer's real location instead of this copy's.
			pixX = peerPixX and (peerPixX + COMPARE.hw * 16), pixY = peerPixY,
			compare = true, only = "hw", x = baseX + COMPARE.hw, y = y,
			sprite = FORCE_PEER_SPRITE or (state.extras and tonumber(state.extras.sprite)) or nil,
			facing = ORIENTATION_TO_DIR[state.orientation],
			lastX = hprev and hprev.lastX, lastY = hprev and hprev.lastY,
			movedAt = hprev and hprev.movedAt,
			fromX = hprev and hprev.fromX, fromY = hprev and hprev.fromY,
			paintedX = hprev and hprev.paintedX, paintedY = hprev and hprev.paintedY,
			stepLatch = hprev and hprev.stepLatch,
			idleFor = hprev and hprev.idleFor,
			lastFacing = hprev and hprev.lastFacing,
			rearm = hprev and hprev.rearm } or nil

		-- THE DRAWN COMPARE COPY RUNS ON THE SPAWNED TIER'S CLOCK, by seeing the peer LATE --
		-- its INPUTS are delayed, never its beat (2026-08-25, the user's call: *"i want both
		-- ghosts to be 1:1 / identical to the player. that also means they have to work/look the
		-- same to each other"*). The spawned ghost cannot act sooner than ~3 frames after the
		-- player (2 of loopback echo + the engine acting the frame after a write); the drawn
		-- model, paced by the live camera, sat at ~0 -- two correct renderers on two clocks,
		-- ~6px apart on every bike run. Delaying the CAMERA BEAT instead was tried twice the
		-- same evening and reverted twice (the note at the model's `due` gate) -- the paint's
		-- cancellation needs the model moving on live camera frames. Feeding the model
		-- three-arrivals-old targets keeps every clock live and simply starts each committed
		-- step where the spawned tier starts its own; Emerald's tiers agree with each other for
		-- exactly this reason -- one clock, the wire's.
		--
		-- Compare copy only: a REAL peer's model is wire-driven already, on the same footing as
		-- the spawned tier, and the shipped tier is untouched.
		local dv = a.dring
		if not dv then dv = { n = 0 }; a.dring = dv end
		dv.n = dv.n + 1
		dv[(dv.n % 4) + 1] = { baseX, y, peerProg, peerWalking, peerFace, peerAct, peerGait,
			peerPixX, peerPixY, state.orientation,
			state.extras and tonumber(state.extras.sprite) or nil, peerYoff, peerEmote, peerJump }
		local dO = (dv.n > 3) and dv[((dv.n - 3) % 4) + 1] or dv[(dv.n % 4) + 1]
		overflow[ck] = { prog = dO[3], walking = dO[4], face = dO[5], act = dO[6], gait = dO[7],
			yoff = dO[12], emote = dO[13], jump = dO[14], drop = dropT, flyMon = a.flySpecies,
			pixX = dO[8] and (dO[8] + COMPARE.drawn * 16), pixY = dO[9],
			compare = true, only = "drawn", x = dO[1] + COMPARE.drawn, y = dO[2],
			sprite = FORCE_PEER_SPRITE or dO[11],
			facing = ORIENTATION_TO_DIR[dO[10]],
			lastX = prev and prev.lastX, lastY = prev and prev.lastY, movedAt = prev and prev.movedAt,
			fromX = prev and prev.fromX, fromY = prev and prev.fromY,
			-- CARRIED, like every other cross-frame value here. Without this the twitch detector
			-- and the movement histogram compare against nil on nearly every frame and can never
			-- fire: this entry is rebuilt each time a peer state arrives, which is every frame.
			-- Found 2026-08-22, after "0 twitches" was read as evidence that nothing jumped.
			paintedX = prev and prev.paintedX, paintedY = prev and prev.paintedY,
			-- THE MODELLED WALK, carried like everything else here: it IS the ghost's position
			-- between wire updates, so losing it every message would defeat the whole point.
			modelX = prev and prev.modelX, modelY = prev and prev.modelY,
			modelPhase = prev and prev.modelPhase,
			modelStill = prev and prev.modelStill,
			modelMovedAt = prev and prev.modelMovedAt,
			lagBeats = prev and prev.lagBeats, catchup = prev and prev.catchup,
			stepDX = prev and prev.stepDX, stepDY = prev and prev.stepDY, stepLeft = prev and prev.stepLeft, dbgState = prev and prev.dbgState,
			progAxis = prev and prev.progAxis,
			facingSeen = prev and prev.facingSeen,
			stepLatch = prev and prev.stepLatch,
			idleFor = prev and prev.idleFor,
			lastFacing = prev and prev.lastFacing,
			rearm = prev and prev.rearm }
	end

	-- FORCE_PEER_SPRITE substitutes here rather than only inside applyPeerSprite, so the probe
	-- flag reaches BOTH tiers. It claimed to substitute "every peer" and did not touch the drawn
	-- one, which made a test of the cartridge path silently measure nothing (2026-08-19).
	--
	-- AND ONLY IF THE PEER'S CARTRIDGE NUMBERS ITS SPRITES THE WAY OURS DOES. `extras.gfx` is the
	-- signature of the sprite table the peer read that id out of; ours is ENGINE.gfxSig. Equal
	-- means the id indexes the same character on both, and a peer on an Archipelago seed is worn
	-- correctly by another Archipelago client. Unequal -- or absent, which is a peer whose build
	-- has no measured table -- means we do not know what the id names here, and the answer is to
	-- drop it rather than draw a confident wrong character: with `peerSprite` nil the ghost wears
	-- this machine's own player sprite in both tiers, exactly as it did before any of this.
	--
	-- The peer still MOVES correctly -- gait is a group number and portable, which the sprite id
	-- is not. That split is the whole cross-build story: pace crosses, appearance does not. The
	-- user's call, 2026-08-26: show whatever this ROM has, but *"match the 'speed' if someone is
	-- moving faster when running or on a faster bike"*.
	--
	-- FORCE_PEER_SPRITE is deliberately still ahead of the gate: it is a probe asking this machine
	-- to draw an id of its own choosing, and its id is by construction one of ours.
	local peerSprite = FORCE_PEER_SPRITE
		or (function()
			local id = state.extras and tonumber(state.extras.sprite)
			if not id or id == 0 then
				return nil
			end
			-- DOES THIS CARTRIDGE DESCRIBE THAT ID THE SAME WAY? Not "do our whole tables agree",
			-- which refused 97 portable sprites to protect against 5 (see ENGINE.spriteSig). A
			-- peer's own row against ours, for that one id.
			local mine = ENGINE.spriteSig(id)
			return (mine and tonumber(state.extras.gfx) == mine) and id or nil
		end)()
		or nil

	-- A peer that should not be blocking is DRAWN rather than spawned: no tile, no collision,
	-- and its engine slot freed for a peer who is actually moving.
	-- The OTHER reason to draw a peer rather than spawn one, added 2026-08-21: a spawned ghost can
	-- only wear a sprite whose tiles this map has already loaded, and the sprites that say "I am
	-- on a bike" or "I am surfing" (wPlayerState -> SPRITE_*_BIKE / SPRITE_SURF, documentation.md)
	-- are loaded only when the LOCAL player is doing the same thing. So a surfing peer used to be
	-- spawned wearing this machine's walking sprite -- a character standing on the sea.
	--
	-- The drawn tier reads the cartridge, so it can wear anything (phase9.md, step 30). Sending a
	-- peer there costs engine-driven animation and collision; keeping them spawned costs showing
	-- the wrong character entirely. The look is what the peer is telling us about, so the look wins
	-- -- the same "collision is a rendering decision" call as the idle rule below.
	--
	-- `not W_USEDSPRITES` is "this build has not been measured here" (Archipelago's table), not
	-- "nothing is resident". Without the list there is no residency question to ask, so the peer
	-- is spawned exactly as before rather than every peer on that build being quietly demoted.
	--
	-- AND the clause that matters most, missing in the first version and caught the same day by
	-- the adapter's own drawn-tier line reading "0 spawned as real objects, 1 drawn": a peer whose
	-- sprite is the one THIS MACHINE's player is wearing is always wearable, whether or not it
	-- appears in wUsedSprites. That list is what the map loaded; the local player's own sprite is
	-- resident by construction and is also the fallback a ghost gets anyway, so "not in the list"
	-- says nothing about whether the ghost can look right. Without this every peer of the same
	-- gender and state -- which is every peer in a loopback session, and most peers in a real one
	-- -- was demoted to the drawn tier, quietly turning the good tier off.
	local localSprite = u8(OBJECT_STRUCTS + F_SPRITE)
	-- NO RESIDENCY LIST IS "SEND IT TO THE DRAWN TIER", NOT "SPAWN IT ANYWAY".
	--
	-- This used to read `not W_USEDSPRITES` as wearable=true, on the reasoning that without the
	-- list there is no residency question to ask, so a peer should be spawned exactly as before.
	-- That is right for a peer wearing OUR sprite and wrong for every other one, because the
	-- spawned tier then cannot apply the peer's sprite at all (`applyPeerSprite` needs the list)
	-- and the ghost silently keeps whatever it was cloned from -- which is this machine's own
	-- player. So on the Archipelago build, where the list is unmeasured, mounting a bike locally
	-- mounted the peer's ghost too: the user, 2026-08-26, after the per-sprite gate had already
	-- fixed the same symptom on the other client -- *"getting on the bike in archipelago, still
	-- mimic its on its own ghost"*.
	--
	-- The drawn tier has no such problem: it reads the cartridge, so it can wear any id whether or
	-- not the tiles are loaded. A peer we cannot dress correctly on the engine tier belongs there
	-- -- the same "the look is what the peer is telling us about, so the look wins" trade the
	-- residency branch below already makes, extended to the build that cannot answer the question.
	local wearable = peerSprite == nil
		or peerSprite == localSprite
		or (W_USEDSPRITES ~= nil and residentSpriteTile(peerSprite) ~= nil)

	-- THE SPEED VERSION OF THE SAME QUESTION, and the third thing this tier decision now weighs.
	-- `wearable` asks whether this cartridge can make a ghost LOOK like the peer; this asks
	-- whether it can make one MOVE like the peer. A build that adds a gait -- Archipelago's
	-- fourth, 8px a tick -- puts a peer on the wire moving faster than anything this ROM's
	-- StepVectors can be told to walk at, and the spawned tier's only honest answer is the wrong
	-- speed: the ghost falls a tile behind every step and the catch-up path snaps it forward,
	-- which is exactly the defect stepGhost's own gait comment records from 2026-08-25.
	--
	-- The drawn tier has no such ceiling. It moves the peer in Lua pixels, so it can walk at 8px a
	-- tick on a cartridge that has never heard of 8px a tick -- `GAIT_PX[3]` is arithmetic here,
	-- not an index into the game's table. The peer therefore keeps the RIGHT SPEED and loses the
	-- engine's own integration, which is the same trade `wearable` already makes and the same way
	-- round: what the peer is telling us about wins. The user's call, 2026-08-26 -- show whatever
	-- this ROM has, but *"match the 'speed' if someone is moving faster when running or on a
	-- faster bike"*.
	--
	-- Note this is the ONLY term of the three that can be true on one machine and false on
	-- another for the same peer at the same instant, which is why it is asked of ENGINE.gaits --
	-- this cartridge's own measured count -- and never of the peer's gait alone.
	local paceable = peerGait <= (ENGINE.gaits or 3) - 1

	-- Called unconditionally, even when `wearable` has already decided the answer: it is what keeps
	-- each peer's movement bookkeeping current, so a peer who dismounts is not immediately judged
	-- idle on the strength of a timestamp that stopped being updated while they were on the bike.
	local blocking = shouldBlock(id, x, y, peerAct)

	-- STEP_LAG: WHY THIS PEER IS NOT SPAWNED. The instrument above can only measure a tier the peer
	-- is actually on, and a run that produces no spawned steps looks identical to a run where the
	-- lag is zero. So the refusal names itself, once a second, rather than being inferred from a
	-- count of zero.
	if stepLag.on and (not COMPARE.spawnTier or not wearable or not blocking or not paceable)
		and policyFrames - (stepLag.whyAt or -999) >= 60 then
		stepLag.whyAt = policyFrames
		local a = activity[id]
		logFile(string.format("MeshGhost: %s stays on the drawn tier -- wearable=%s blocking=%s "
			.. "paceable=%s (peer sprite %s, local %s; idle for %s frames, passable for "
			.. "another %s)", id,
			tostring(wearable), tostring(blocking), tostring(paceable),
			tostring(peerSprite), tostring(localSprite),
			a and tostring(policyFrames - a.movedAt) or "?",
			a and tostring((a.passableUntil or 0) - policyFrames) or "?"))
	end

	-- The tier switch first: the shipped default never spawns, and the three engine terms only
	-- matter once someone has opted the spawned tier back in (dev, or compare mode).
	if not COMPARE.spawnTier or not wearable or not blocking or not paceable then
		if ghosts[id] then
			-- NAME THE TRANSITION. The user saw the same peer rendered twice for a few frames while
			-- walking (2026-08-21): a peer flapping between the spawned and painted tiers passes
			-- through frames where the engine object is still on screen and the painted copy is
			-- already drawn on the same tile. Which side flips it, and why, is the whole question --
			-- a count cannot answer it, a transition line can. Throttled by nature: it only fires on
			-- an actual tier change.
			logFile(string.format("tier: %s spawned -> painted (%s)", id,
				(not wearable) and "sprite not resident here"
					or (not paceable) and "gait faster than this ROM's engine has a step for"
					or "idle/shoved: not blocking"))
			despawnGhost(id)
		end
		local prev = overflow[id]
		overflow[id] = { prog = peerProg, walking = peerWalking, face = peerFace, act = peerAct, gait = peerGait,
			yoff = peerYoff, emote = peerEmote, jump = peerJump, drop = dropT, flyMon = a.flySpecies,
			pixX = peerPixX and (peerPixX + offsetX * 16), pixY = peerPixY,
			x = x, y = y, sprite = peerSprite,
			facing = ORIENTATION_TO_DIR[state.orientation],
			lastX = prev and prev.lastX, lastY = prev and prev.lastY, movedAt = prev and prev.movedAt,
			fromX = prev and prev.fromX, fromY = prev and prev.fromY,
			-- CARRIED, like every other cross-frame value here. Without this the twitch detector
			-- and the movement histogram compare against nil on nearly every frame and can never
			-- fire: this entry is rebuilt each time a peer state arrives, which is every frame.
			-- Found 2026-08-22, after "0 twitches" was read as evidence that nothing jumped.
			paintedX = prev and prev.paintedX, paintedY = prev and prev.paintedY,
			-- THE MODELLED WALK, carried like everything else here: it IS the ghost's position
			-- between wire updates, so losing it every message would defeat the whole point.
			modelX = prev and prev.modelX, modelY = prev and prev.modelY,
			modelPhase = prev and prev.modelPhase,
			modelStill = prev and prev.modelStill,
			modelMovedAt = prev and prev.modelMovedAt,
			lagBeats = prev and prev.lagBeats, catchup = prev and prev.catchup,
			stepDX = prev and prev.stepDX, stepDY = prev and prev.stepDY, stepLeft = prev and prev.stepLeft, dbgState = prev and prev.dbgState,
			progAxis = prev and prev.progAxis,
			facingSeen = prev and prev.facingSeen,
			stepLatch = prev and prev.stepLatch,
			idleFor = prev and prev.idleFor,
			lastFacing = prev and prev.lastFacing,
			rearm = prev and prev.rearm }
		return
	end

	local g = ghosts[id]

	-- IS THIS PEER STANDING ON OUR OWN MAP AT ALL?
	--
	-- Cross-map translation routinely places a peer OUTSIDE our map -- one tile across the west
	-- seam is x = -1 -- and a real engine object cannot live there: the engine culls an object
	-- outside its own map, and every coordinate written for one goes into a u8, where -1 becomes
	-- 255 and puts the ghost across the map. So an off-map peer takes no engine slot and is
	-- carried by the painted tier, promoting the moment it steps onto our map -- well before the
	-- screen could show it doing anything else. Emerald draws the same line at its own border.
	--
	-- Coordinates are OBJECT space -- map space plus the 4-tile border -- so our tiles run
	-- 4 .. 3 + extent. FAIL OPEN when cross-map is not armed: `ourW`/`ourH` are 0 on a build whose
	-- connection block is unmeasured, and gating on them there would refuse every spawn on the map
	-- rather than none.
	local inOurMap = not ENGINE.xmap.armed() or ENGINE.xmap.ourW <= 0
		or (x >= 4 and y >= 4
			and x <= 3 + ENGINE.xmap.ourW and y <= 3 + ENGINE.xmap.ourH)
	-- A ghost that WAS ours and whose peer has since walked off our map is handed back NOW, rather
	-- than being stepped toward a coordinate that cannot be written. The spawn gate below only
	-- stops new objects; without this an existing one keeps being driven off the edge.
	if g and not inOurMap then
		despawnGhost(id)
		g = nil
		-- AND DO NOT HAND THE TILES STRAIGHT BACK. `adapters/CLAUDE.md`: never re-use a despawned
		-- entity's resources in the same tick that despawned it -- the engine has not finished with
		-- them, and Emerald's scrambled ghost was exactly this. A peer walking the seam boundary
		-- steps in and out of our map repeatedly, so without a cooldown this frees and re-claims
		-- the same tiles every couple of frames. The user, 2026-08-27, watching a peer arrive into
		-- their route: *"the 'sprite' is glitchy on the ghost"* -- a regression from the despawn
		-- above, which did not exist before cross-map peers could leave our map at all.
		a.reclaimAt = policyFrames
	end
	-- Free on one tick, allocate on a later one.
	if a.reclaimAt and (policyFrames - a.reclaimAt) < 8 then
		inOurMap = false
	end

	-- TWO FRAMES, NOT ONE, AND IT IS NOT AN OVERLAP -- IT IS A GAP BEING CLOSED.
	--
	-- Measured 2026-08-23, dumping hardware OAM every frame across four promotions: an object this
	-- adapter creates has NO OAM entries on the frame it is created OR on the next one, and first
	-- appears on the SECOND frame after. The drawn copy was being released after one, so there was
	-- exactly one frame on which neither tier drew the peer. The user, on a ghost that had been
	-- standing still and then took a step: *"the spawned ghost still 'flicker' whenever it has been
	-- idle/despawned, and then moves 1 tile"*, and *"at the start of moving from idle to another
	-- tile"* -- a promotion happens every time a peer starts walking, so it fires constantly.
	--
	-- The old comment here described this as releasing "once a frame has actually been drawn with
	-- both", which was the intention and never what happened: the measurement says the two are
	-- never on screen together at all, so what was called an overlap was a one-frame hole. Keeping
	-- the drawn copy for the second frame makes the handover exact rather than overlapping -- drawn
	-- on the promotion frame and the one after, engine-owned from the frame it can actually draw.
	--
	-- Safe to hold: the promotion places the object on the drawn model's own tile, and the model's
	-- sub-tile remainder measures 0.0px at that instant (logged under MESHGHOST_CRYSTAL_STEP_LAG),
	-- so the two agree on the pixel for as long as this lasts.
	if g and overflow[id] and not holdHandover(overflow[id]) then
		overflow[id] = nil
	end
	if not g then
		-- PROMOTE ONTO THE TILE THE DRAWN GHOST IS ACTUALLY OVER, not the peer's current tile.
		--
		-- A ghost that stands still is demoted to the drawn tier by the idle rule and its engine
		-- object is DESPAWNED; the moment the peer moves again it is promoted back and a fresh
		-- object is placed. So "starts to walk after being idle" is a re-spawn, every time -- the
		-- live log shows the demote/despawn/respawn cycle repeating for as long as a session runs.
		--
		-- The two tiers do not agree about where the peer is at that instant. The drawn tier paints
		-- a smooth model position; the spawned tier puts a real object on a tile. The promotion is
		-- TRIGGERED by the peer moving, so it always fires just as the model has begun sliding off
		-- the tile -- and placing the object on the peer's current tile pays that whole
		-- disagreement in one frame. The user: *"the spawned ghost is teleporting 1 tile whenever
		-- it starts to walk after being idle/respawned"*.
		--
		-- Placing it on the MODEL's tile instead hands over where the ghost visibly was, and lets
		-- the ordinary step logic below walk it the rest of the way -- animated, grid-aligned, at
		-- the engine's own pace. The sub-tile remainder is deliberately NOT carried across: an
		-- object parked between tiles is exactly what the standing re-anchor exists to destroy, so
		-- it would be undone within a frame and the ghost would jump anyway.
		local px, py = x, y
		local ov = overflow[id]
		if ov and ov.modelX then
			local mtx, mty = math.floor(ov.modelX / 16), math.floor(ov.modelY / 16)
			-- ...and only when a spawn is actually on the table. A peer outside our map is never
			-- placeable (`inOurMap`), so without this the line fires EVERY FRAME for as long as a
			-- cross-map peer is on screen -- measured at 2,556 writes in one 45-second run, which
			-- is per-frame file I/O on the emulator's own thread and exactly the cost
			-- `adapters/emulator/CLAUDE.md` warns about. The handover it describes cannot happen
			-- for a peer that cannot be handed over.
			if inOurMap and (mtx ~= x or mty ~= y) then
				-- The size of the handover, in tiles, logged whether or not it is acted on: if this
				-- stops appearing the cause has moved, and if it appears with the jump gone it was
				-- never the cause. A counter that vanishes with its fix proves nothing.
				logFile(string.format("MeshGhost: %s promoted across a %+d,%+d tile handover "
					.. "(drawn model at %d,%d, peer at %d,%d) -- placed on the model's tile",
					id, mtx - x, mty - y, mtx, mty, x, y))
				px, py = mtx, mty
			end
			-- THE SUB-TILE REMAINDER THAT IS DROPPED, in pixels, which the tile-level line above
			-- cannot show. The promotion places a real object on a TILE, while the drawn model it
			-- takes over from is somewhere between two -- so the peer jumps by whatever that
			-- remainder was, every single promotion, even when both agree on the tile and the line
			-- above stays silent. A promotion happens every time a peer starts walking after
			-- standing still, which is what the user is describing: *"the spawned ghost still
			-- 'flicker' whenever it has been idle/despawned, and then moves 1 tile"*, *"at the
			-- start of moving from idle to another tile"*. Measured before it is called the cause.
			local remX = ov.modelX - math.floor(ov.modelX / 16) * 16
			local remY = ov.modelY - math.floor(ov.modelY / 16) * 16
			-- DO NOT PROMOTE MID-STEP. The 08-23 comment above assumed the remainder is 0.0 at
			-- promotion because the model had only just started moving. Since the model began
			-- stepping off the peer's PROGRESS (later that same day), it no longer is: measured
			-- 2026-08-25 across three promotions of the 9x9 square drive, the model is 10px into
			-- its tile every time -- the peer's tile change arrives when their step COMPLETES, so
			-- the progress-driven model is most of a step in before the promotion can fire. The
			-- object lands tile-aligned, so those 10px were paid as a visible backward snap on the
			-- ghost's first tile after every respawn (user: *"'snaps' a bit when moving the first
			-- tile after respawning"*).
			--
			-- The remainder cannot be carried onto the object (the standing re-anchor destroys a
			-- between-tiles object within a frame -- above). So WAIT for it to drain instead: the
			-- model reaches its tile boundary within a step (16px at 2px per engine tick), the
			-- paint keeps tracking it the whole way, and the object then lands exactly where the
			-- painted copy is standing. Bounded at 24 frames -- past that (a model wedged
			-- mid-tile, which a parked model never is) the old snap is the lesser evil versus a
			-- peer stuck on the painted tier.
			-- The boundary is detected as a TILE CROSSING, not as remainder == 0. The first
			-- version tested `rem < 1` and the trace showed later promotions riding the 24-frame
			-- cap and landing 2-14px mid-step: a model in its 4px catch-up gait goes 14 -> 18 -> 2
			-- and never touches 0, so an equality-shaped test misses the boundary it is waiting
			-- for. The crossing itself cannot be missed -- floor(model/16) changes on exactly one
			-- frame -- and the landing error is bounded by half the model's own quantum.
			local mtile = math.floor(ov.modelX / 16) * 256 + math.floor(ov.modelY / 16)
			local crossed = ov.promoteTile ~= nil and ov.promoteTile ~= mtile
			ov.promoteTile = mtile
			if (remX >= 1 or remY >= 1) and not crossed and (ov.promoteWait or 0) < 24 then
				ov.promoteWait = (ov.promoteWait or 0) + 1
				if stepLag.on then
					logFile(string.format("  defer f=%d %s rem %.1f,%.1f wait %d",
						drawFrames, id, remX, remY, ov.promoteWait))
				end
				px = nil
			elseif stepLag.on then
				stepLag.rem = stepLag.rem or {}
				local k = math.floor(math.max(remX, remY))
				stepLag.rem[k] = (stepLag.rem[k] or 0) + 1
				logFile(string.format("MeshGhost: %s promoted -- drawn model was %.1f,%.1f px into "
					.. "its tile after %d deferred frames (the object lands tile-aligned)",
					id, remX, remY, ov.promoteWait or 0))
			end
		end
		-- Try the good tier first, every frame: a slot may have freed up since last time.
		-- (px == nil is the mid-step deferral above -- stay painted this frame.)
		-- A TRANSLATED PEER MAY STAND OUTSIDE OUR MAP, AND A REAL OBJECT MAY NOT.
		--
		-- Cross-map translation puts a peer on a connected neighbour into our tile frame, which
		-- routinely lands them one or more tiles PAST our own edge -- a peer just across the west
		-- seam sits at map x = -1. The engine culls an object outside its own map the frame it is
		-- created, so promoting one starts the allocate/cull/allocate loop that
		-- `adapters/CLAUDE.md` warns about: measured 2026-08-27 as 485 consecutive promote
		-- attempts in one session with `0 spawned as real objects` to show for them, and the user
		-- saw it as a cross-map peer that *"look[s] like teleporting/snapping"* on every tile.
		--
		-- So a peer outside our bounds simply takes no slot. It still EXISTS -- the painted tier
		-- carries it, which is what makes it visible across the seam at all -- and it promotes to
		-- a real object the moment it steps onto our map, which is before the screen can show it
		-- doing anything else. Emerald draws the same line for the same reason.
		--
		-- Coordinates here are OBJECT space, which is map space + 4 (the map border), so our own
		-- tiles run 4 .. 3 + extent. FAIL OPEN when cross-map is not armed: `ourW`/`ourH` are 0 on
		-- a build whose connection block is unmeasured, and gating on them there would refuse
		-- every spawn on the map rather than none.
		-- `inOurMap` is decided above from the peer's own tile. `px,py` is the promote tile, which
		-- is the drawn model's rather than the peer's and can differ by one -- so it is bounded
		-- here too: the peer being on our map does not by itself prove the tile we are about to
		-- write is.
		local placeable = inOurMap and px and px >= 4 and py >= 4
			and (ENGINE.xmap.ourW <= 0
				or (px <= 3 + ENGINE.xmap.ourW and py <= 3 + ENGINE.xmap.ourH))
		if placeable and not dropT and spawnGhost(id, px, py, peerSprite) then
			-- FACE THE WAY THE PEER IS FACING, IMMEDIATELY.
			--
			-- `spawnGhost` pins the new object's standing facing to whatever direction the TEMPLATE
			-- it was cloned from happened to be facing, and leans on `stepGhost` re-pinning it on
			-- the first step. That was nearly free while the first step was issued on the very next
			-- frame; it stopped being free when STEP_TRIGGER_PROG started holding that step back
			-- until the peer is four pixels into its own, so a wrong facing now sits on screen for
			-- several frames instead of one. The user, after the handover hop was fixed: *"the
			-- facing direction is a bit weird when its happening now"*.
			--
			-- A latent fault that a later change made visible, not a new one -- and it is the same
			-- inherited-donor-identity family as the trainer clone (`pitfalls.md`): a ghost must
			-- describe the PEER, never the character whose struct it was copied from.
			--
			-- All three writes, the same set `stepGhost` makes: the movement byte decides what the
			-- engine restores when a step ends, and DIRECTION/FACING are what is drawn until then.
			-- A GHOST SPAWNED DURING A FLY LANDING FALLS ONTO ITS TILE. The cross-map fly
			-- reaches the engine tier through this spawn, never through the teleport or the
			-- catch-up walk -- which is exactly why the drop is armed on the envelope rather than
			-- on any one placement path. The blanket "never on a spawn" this replaces was written
			-- to stop a PROMOTION dropping from the sky, and the envelope already guarantees that:
			-- it exists only when the peer wears MAPSETUP_FLY, which a peer that merely started
			-- walking never does.
			local g2, want2 = ghosts[id], ORIENTATION_TO_DIR[state.orientation]
			if g2 and want2 then
				setGhostStanding(g2.st_base, g2.mo_base, want2)
				w8(g2.st_base + F_DIRECTION, want2 * 4)
				w8(g2.st_base + F_FACING, want2 * 4)
			end
			-- WHICH WAY DID IT ACTUALLY END UP FACING? Read back from the object, not from `want2`
			-- -- reporting the value just written proves only that the write happened.
			--
			-- Added 2026-08-26 for the report that a briefly-appearing ghost is *"always looking
			-- down, no matter what direction the player was facing"*. Down is dir 0, which is what
			-- every fallback in this path degrades to: `ORIENTATION_TO_DIR` missing an orientation
			-- makes `want2` nil and skips the re-pin entirely, leaving whatever the cloned TEMPLATE
			-- NPC happened to be facing; and `setGhostStanding` falls back to
			-- SPRITEMOVEDATA_STANDING_BY_DIR[0] for an unknown direction. Those are different bugs
			-- with one symptom, and only the peer's own reported orientation beside the byte that
			-- reached the object tells them apart.
			--
			-- One line per SPAWN, which already logs a line -- nothing per frame.
			--
			-- AND THE SPRITE ON THE SAME LINE, because facing is only one of the fields a fresh
			-- clone inherits from its donor. The user's question, 2026-08-26: *"what about
			-- bike/surf etc as well? not just facing direction?"* -- and it is the same shape.
			-- `spawnGhost` copies a template NPC wholesale, so until each field is re-pinned the
			-- ghost is wearing that NPC's identity, and a peer who is BIKING or SURFING says so
			-- only through its sprite id. If `applyPeerSprite` refused -- the tiles are not
			-- resident, or the peer's cartridge numbers sprites differently from ours and the
			-- `gfx` gate dropped the id -- the ghost stands there as this machine's own walking
			-- character while its peer is on a bike, which is the same class of wrong as facing
			-- down while the peer faces up, and equally invisible in a log that reports neither.
			--
			-- Three values, all read back from the object rather than from what we meant to write.
			if g2 then
				logFile(string.format("MeshGhost: %s spawned facing %s wearing sprite %s "
					.. "(peer orientation %q -> dir %s; peer sprite %s, local %s; object now "
					.. "DIRECTION=%s FACING=%s)", id,
					DIR_NAMES[(u8(g2.st_base + F_DIRECTION) or 0)] or "?",
					tostring(u8(g2.st_base + F_SPRITE)),
					tostring(state.orientation), tostring(want2),
					tostring(peerSprite), tostring(u8(OBJECT_STRUCTS + F_SPRITE)),
					tostring(u8(g2.st_base + F_DIRECTION)), tostring(u8(g2.st_base + F_FACING))))
			end
			if overflow[id] then
				logFile(string.format("tier: %s painted -> spawned", id))
				-- OVERLAP THE TWO TIERS, do not butt them together -- and release on EVIDENCE.
				--
				-- Dropping the drawn copy on the same frame the engine object is created leaves a
				-- single frame in which NEITHER draws the peer: this adapter paints during its own
				-- tick, while a freshly created object is not in the engine's sprite list until the
				-- engine next builds one. One missing frame is a blink, and that is what was left
				-- after the tile handover was fixed -- the user: *"its not teleporting now, but it
				-- 'flickers' real quick"*.
				--
				-- Keeping the entry costs frames where both draw the peer, and that is invisible for
				-- the reason the fix above exists: they now agree on the tile, so the two are the
				-- same character in the same place. A gap is visible; an exact overlap is not.
				--
				-- ONE FRAME WAS NOT ENOUGH. It was measured at FOUR in Crystal, so the blink
				-- survived its own fix (2026-08-25). `holdHandover` therefore holds for up to 8
				-- frames and releases when it SEES the object's entries in OAM, bounded so a peer
				-- whose object never appears cannot pin the painted copy on screen. This comment
				-- described the one-frame version until 2026-08-27.
				overflow[id].handover = drawFrames
				-- STEP_LAG: watch the next few frames of the handover from the PAINT side. The
				-- counting probes say the drawn copy covers the frames before the engine draws the
				-- object, and the user still sees a blink -- so the question is no longer "how many
				-- frames" but "was it actually painted on them". Screenshots cannot answer it:
				-- client.screenshot captures the emulated framebuffer WITHOUT BizHawk's Lua overlay,
				-- so the drawn tier is invisible to every screenshot ever taken of it (2026-08-23).
				if stepLag.on then
					-- +8, matching holdHandover's own cap: the window has to outlast the hold or
					-- the trace stops before the frame that decides whether it worked.
					stepLag.traceUntil = drawFrames + 8
				end
			else
				overflow[id] = nil
			end
		else
			local prev = overflow[id]
			overflow[id] = { prog = peerProg, walking = peerWalking, face = peerFace, act = peerAct, gait = peerGait,
			yoff = peerYoff, emote = peerEmote, jump = peerJump, drop = dropT, flyMon = a.flySpecies,
			pixX = peerPixX and (peerPixX + offsetX * 16), pixY = peerPixY,
			x = x, y = y, sprite = peerSprite,
				facing = ORIENTATION_TO_DIR[state.orientation],
				lastX = prev and prev.lastX, lastY = prev and prev.lastY,
				movedAt = prev and prev.movedAt,
				fromX = prev and prev.fromX, fromY = prev and prev.fromY,
			-- CARRIED, like every other cross-frame value here. Without this the twitch detector
			-- and the movement histogram compare against nil on nearly every frame and can never
			-- fire: this entry is rebuilt each time a peer state arrives, which is every frame.
			-- Found 2026-08-22, after "0 twitches" was read as evidence that nothing jumped.
			paintedX = prev and prev.paintedX, paintedY = prev and prev.paintedY,
			-- THE MODELLED WALK, carried like everything else here: it IS the ghost's position
			-- between wire updates, so losing it every message would defeat the whole point.
			modelX = prev and prev.modelX, modelY = prev and prev.modelY,
			modelPhase = prev and prev.modelPhase,
			modelStill = prev and prev.modelStill,
			modelMovedAt = prev and prev.modelMovedAt,
			lagBeats = prev and prev.lagBeats, catchup = prev and prev.catchup,
			stepDX = prev and prev.stepDX, stepDY = prev and prev.stepDY, stepLeft = prev and prev.stepLeft, dbgState = prev and prev.dbgState,
			progAxis = prev and prev.progAxis,
			-- The mid-step promotion deferral's own counter. Carried ONLY here (this rebuild runs on
			-- every deferred frame); the demotion-path rebuilds deliberately drop it, so each idle
			-- period starts its wait from zero.
			promoteWait = prev and prev.promoteWait,
			promoteTile = prev and prev.promoteTile,
			facingSeen = prev and prev.facingSeen,
			stepLatch = prev and prev.stepLatch,
			idleFor = prev and prev.idleFor,
			lastFacing = prev and prev.lastFacing,
			rearm = prev and prev.rearm }
		end
		return
	end
	-- ...and this unconditional clear is why the handover above had never done anything. It runs on
	-- every frame for a spawned peer, so the entry the promotion had deliberately kept was wiped
	-- one frame later whatever `handover` said. Both release points have to honour it or neither
	-- does. Found 2026-08-23 while measuring why the blink survived a fix aimed straight at it.
	if not holdHandover(overflow[id]) then
		overflow[id] = nil
	end
	if g and not stillOurs(g) then
		-- A map load, a battle, OR A SAVESTATE LOAD rebuilt the array under us. Drop the entry
		-- rather than write steps into whatever the game has put in that slot.
		log("MeshGhost: " .. id .. "'s slot is the game's again — respawning")
		ghosts[id], g = nil, nil
		-- AND RETURN, BECAUSE EVERYTHING BELOW THIS POINT DEREFERENCES `g`.
		--
		-- This block's own comment used to say "and spawn again below". There is no spawn below --
		-- the promotion lives in the `if not g then` block ABOVE, which has already been passed by
		-- the time this runs. So clearing `g` and falling through walked straight into
		-- `u8(g.st_base + F_WALKING)` with `g` nil, which throws, **and a tick error makes the dev
		-- loader unload the adapter** -- so the visible symptom is not a wrong ghost, it is every
		-- ghost vanishing at once and the script appearing to have died. The user, 2026-08-26:
		-- *"think me reloading a savestate broke the script ?"* -- it did, exactly here.
		--
		-- Returning hands the peer to the next frame, which enters `if not g then` and either
		-- promotes it cleanly or paints it on the drawn tier. That costs at most one frame in which
		-- the peer is not drawn, on a frame where the game has just rebuilt its whole object array
		-- anyway.
		--
		-- Related but NOT the same fix as the map-change crash closed earlier on 2026-08-26: that
		-- one stopped the adapter throwing when a map change invalidated a slot, and this is the
		-- second door into the same room. Two paths reaching one unguarded dereference is the
		-- shape to look for if a third appears.
		return
	end
	-- A peer's sprite is not fixed for the session: it changes with their state (on a bike, and
	-- with the gender the sprite tables are keyed on), and what is RESIDENT changes under us on
	-- every map load. So this is re-checked here rather than only at spawn.
	applyPeerSprite(g, peerSprite)

	-- AN IMPOSSIBLE STATE, AND THE ONE THAT SENDS A GHOST OFF THE SCREEN.
	--
	-- OBJECT_WALKING saying STANDING while OBJECT_STEP_TYPE still says "walk" is not a state the
	-- engine produces for its own objects: the step functions always set the two together. But
	-- orphan_probe.lua caught our ghost holding exactly it on 2026-08-21 -- and it is ruinous,
	-- because StepVectors has 12 entries and GetStepVector indexes it with WALKING's low nibble.
	-- STANDING is 255, so the nibble is 15, and the engine reads a step vector out of whatever
	-- follows that table and applies it every frame until the duration runs out. What the user saw:
	-- *"it gets dragged off screen"*.
	--
	-- The cause is not yet pinned -- stepGhost's own write reads back correct every time, so the
	-- state arrives BETWEEN our steps -- so this repairs rather than explains, and says so. The
	-- repair is the engine's own "the movement ended" path (STEP_TYPE_FROM_MOVEMENT), which lands
	-- the object in MovementFunction_Standing and then STEP_TYPE_RESTORE, exactly as a step that
	-- finished normally would. Registered in BANDAGES.md as a compensation with an unknown cause.
	local walking = u8(g.st_base + F_WALKING) or STANDING
	local stepType = u8(g.st_base + F_STEP_TYPE) or 0

	-- A FLY LANDING IS PLACED, NEVER TRAVELLED TO -- and hanging the fall on `teleportGhost`
	-- alone was wrong, because a fly landing hardly ever reaches that branch. The user,
	-- 2026-08-26: *"the spawned ghost does not do this / it just walks towards where its supposed
	-- to be afterwards"*. Both of the real paths bypassed it: a SAME-town fly usually lands
	-- within three tiles, which is the short-deficit case that WALKS, and a cross-town fly
	-- rebuilds the world, so the ghost is freshly spawned rather than moved. The teleport branch
	-- is the one case a fly rarely takes.
	--
	-- So the drop is armed HERE, above every movement decision, on the envelope rather than on a
	-- path: while `dropT` is live the ghost belongs at its landing tile, falling onto it. Armed
	-- once per drop (the envelope only exists when the peer wears MAPSETUP_FLY *and* its tile
	-- jumped), and this function then returns until the engine's own skyfall finishes -- nothing
	-- may step, chain or catch-up a ghost that is in mid-air.
	-- DURING A LANDING THE ENGINE OBJECT IS PARKED AND INVISIBLE, which is what the game does to
	-- the flier itself: no character is drawn anywhere in Crystal for the length of a fly. The
	-- descent belongs to the painted icon above; this tier's job is to be waiting, in the right
	-- place, wearing the right facing, at the instant the icon lands.
	--
	-- This replaces STEP_TYPE_SKYFALL, which was BANDAGES.md #3 -- the Burned Tower floor-fall
	-- borrowed because it was the closest thing the engine would do to a character. It is not
	-- needed once the ghost stops being a character for those 44 frames.
	-- A DROPPING PEER IS A PAINTED PEER, full stop. The engine object has no part in a landing --
	-- the descent is the Pokemon's icon, which only the painted tier can draw -- and the painted
	-- tier only registers a peer the spawned tier is not holding. The first version PARKED the
	-- object invisible instead, which on a cross-town fly (where the object is freshly spawned)
	-- left the real position with a parked ghost, no painted entry, and therefore no icon:
	-- measured 2026-08-26, `ov=false iconPaints=44` -- one copy's worth -- against the same-town
	-- run's `ov=true iconPaints=88`. So the object is released for the drop's duration; the peer
	-- falls as the icon, lands painted on its tile, and the ordinary promotion machinery gives it
	-- back an engine object the next time it moves.
	if dropT and a.flySpecies and facingFrames.iconGfx(a.flySpecies) then
		despawnGhost(id)
		return
	end

	if walking == STANDING and (stepType == 2 or stepType == 7) then
		w8(g.st_base + F_STEP_TYPE, 1) -- STEP_TYPE_FROM_MOVEMENT
		w8(g.st_base + F_STEP_DURATION, 0)
		snaps.runaways = (snaps.runaways or 0) + 1
	end

	-- Only act while the ghost is idle; interrupting a step is what makes a character teleport
	-- while animating.
	-- ICE: A PEER THAT MOVES WITHOUT ANIMATING, and the bit that reproduces it.
	--
	-- The user, 2026-08-26, watching both tiers on Ice Path: the DRAWN ghost glides correctly and
	-- *"the spawned ghost is still doing the walking animation when gliding on the ice"*. The
	-- drawn tier is right because it derives its pose from the peer's own `face`/`act` bytes; the
	-- spawned tier is wrong because the ENGINE animates it, and the engine does not know the peer
	-- is on ice.
	--
	-- MEASURED (`probes/ice_probe.lua`, driven across real ice): a gliding player reads
	-- `walk=10 stype=6 act=1 face=08` -- moving at the FAST gait (group 2), with
	-- `OBJECT_ACTION_STAND` and a facing stride that does not advance. An ordinary walking step
	-- carries action 2 (STEP). So "moving while STANDING" is the game's own description of a
	-- glide, and it is already on the wire as `extras.act`.
	--
	-- WHY NOT JUST WRITE THE ACTION. `applyPeerAction` sits BELOW the mid-step return just after
	-- this, so while the ghost walks its own step -- exactly when the engine advances the stride
	-- -- the peer's STAND never gets written. Writing it every tick from up here would put us in
	-- a per-tick race with the engine's own step function, which is the two-writers bug
	-- `adapters/CLAUDE.md` names and which this file already hit once today with SPIN.
	--
	-- SO USE THE ENGINE'S OWN SUPPRESSION INSTEAD. `SetFacingStepAction`
	-- (`engine/overworld/map_object_action.asm:46`) tests `SLIDING_F` FIRST and jumps to
	-- `SetFacingCurrent`, never touching `OBJECT_STEP_FRAME` -- the walk cycle simply does not
	-- run. It is a bit the engine READS and never writes, so there is nothing to race. This file
	-- already clears it at spawn (a donor template carries it and a permanently-sliding ghost
	-- never animates at all); this maintains it per frame instead.
	--
	-- NOTE THE PLAYER DOES NOT WEAR THIS BIT -- `ice_probe` measured `SLIDING seen SET = false`
	-- across a whole glide, which killed the obvious "mirror the peer's SLIDING bit" fix before
	-- it was built. We are reproducing the EFFECT the peer's engine produced by another route,
	-- which is `adapters/CLAUDE.md`'s "copy what the effect DOES, not the structure that does it".
	if g and peerAct ~= nil then
		local fl = u8(g.st_base + F_FLAGS1) or 0
		local glide = peerWalking and peerAct == 1 -- moving, but posed STANDING: an ice slide
		if glide ~= ((fl & 0x08) ~= 0) then
			w8(g.st_base + F_FLAGS1, glide and (fl | 0x08) or (fl & ~0x08))
		end
	end

	-- THE PEER'S VERTICAL NUDGE, ON THE SPAWNED GHOST'S OWN OBJECT.
	--
	-- `emote.F_YOFF` was defined when `yoff` went on the wire for fishing (2026-08-26) and then never
	-- read: only the drawn tier applied the byte, by adding it to the sprite's screen y. So a
	-- spawned ghost showed no bite wiggle, no Fly fall and no ledge-hop arc -- it stood perfectly
	-- still through every one of them while the painted copy beside it moved.
	--
	-- One write is all it takes because the engine already reads this field when it builds OAM:
	-- `_UpdateSprites` adds OBJECT_SPRITE_Y_OFFSET to OBJECT_SPRITE_Y (map_objects.asm), and
	-- nothing on a ghost's step path writes it back -- `StepFunction_NPCWalk`, which is the step
	-- type 2 a ghost walks on, calls `Stubbed_UpdateYOffset`, which is dummied out to a bare `ret`.
	--
	-- ABOVE THE MID-STEP RETURN, WHICH IS THE PART THAT WAS WRONG. This write was moved above the
	-- IDLE branch when it was added, with a comment saying why -- "a ledge hop changes tile while
	-- the arc is running" -- and that was the right reason applied to the wrong branch. The
	-- `walking ~= STANDING` return below it is a HARD return, so from the moment a ghost started
	-- moving the byte stopped being written entirely, which is precisely the window a hop's arc
	-- occupies.
	--
	-- MEASURED, 2026-08-26 (`probes/ledge_drive.lua` + `probes/fly_probe.lua`), one hop:
	--   player yoff  -4 -6 -8 -8 -10 -11 -11 -12 -12 -12 -11 -11 -10 -9 -8 -6 -6 -4
	--   ghost  yoff  -4 -6 then FROZEN AT -6 for the whole rest of the hop
	-- The ghost's action went to 2 (stepping) on the frame its arc froze. That is this return, and
	-- nothing else -- the byte was arriving on the wire the entire time.
	--
	-- Safe to write mid-step for the reason two paragraphs up: no step path of a ghost's writes
	-- this field, so there is no second writer to race.
	-- AND STAND OFF WHILE THE ENGINE IS GENERATING THIS FIELD ITSELF.
	--
	-- A ghost on STEP_TYPE_NPC_JUMP (8) is running `StepFunction_NPCJump`, which calls
	-- `UpdateJumpPosition` every tick -- and that writes OBJECT_SPRITE_Y_OFFSET. Copying the peer's
	-- byte on top of it would make this the SECOND writer on one field, which `adapters/CLAUDE.md`
	-- names as its own bug class and which Emerald has already paid for once (the underwater bob
	-- driven from both the wire and our own code, seen as the ghost *"moving really fast/weird"*).
	--
	-- The engine's copy is also strictly better than ours: it is generated on the ghost's own clock
	-- from its own accumulated JUMP_HEIGHT, so it cannot arrive late, cannot be sampled at the send
	-- rate, and cannot freeze if a packet is dropped. The wire's `yoff` still drives every OTHER
	-- vertical -- the bite wiggle, the Fly fall -- where no engine mechanism is running on our side.
	-- `peerJump` AS WELL AS THE GHOST'S OWN STEP TYPE, because the two are not simultaneous. The
	-- peer starts hopping a few frames before its ghost is issued the jump, and in that window the
	-- old condition still copied the peer's arc onto a ghost that was standing still -- measured
	-- 2026-08-26 as a `-6 -> -4` wobble on the ghost right at the take-off, where the engine's own
	-- curve then restarted from 0. Standing off for the whole hop, from the first packet that says
	-- one is happening, leaves the ghost at 0 until its own jump begins and generates the lot.
	if g and peerYoff ~= nil and not peerJump and (u8(g.st_base + F_STEP_TYPE) or 0) ~= 8
		and u8(g.st_base + emote.F_YOFF) ~= (peerYoff & 0xFF) then
		w8(g.st_base + emote.F_YOFF, peerYoff & 0xFF)
	end

	if walking ~= STANDING then
		-- CHAIN A CONSECUTIVE STEP THE WAY THE ENGINE CHAINS ITS OWN (2026-08-25).
		--
		-- Waiting for STANDING costs ~2 frames per boundary that the engine's own walkers never
		-- pay: the engine lands the ghost, this tick only SEES it standing a frame later, writes,
		-- and the engine acts the frame after that -- while a real walking character's movement
		-- function rolls straight into its next step (StepFunction_FromMovement). Measured with
		-- MESHGHOST_CRYSTAL_STEP_LAG on a bike lap: apply 1-2 frames of every step's lag was this
		-- handoff, and the user, with the drawn twin alongside: *"the spawned one is lagging
		-- after the drawn ghost a bit"*.
		--
		-- The engine itself makes the chain safe: `GetStepVector` re-reads OBJECT_WALKING every
		-- tick, and `StepFunction_NPCWalk` ends a step purely on OBJECT_STEP_DURATION reaching
		-- zero (engine/overworld/map_objects.asm:1550) -- the same mechanism as its own
		-- STEP_TYPE_CONTINUE_WALK. So on the step's LAST tick, when the peer is already exactly
		-- one tile further IN THE SAME DIRECTION at the SAME GAIT, the duration is topped back up
		-- and the map coords moved on -- and the engine never sees a boundary. Nothing else needs
		-- writing: direction, facing (whose low bits are the walk-cycle subframe, which a rewrite
		-- would reset), the walking byte and the movement byte are all already correct, which is
		-- why this is not a call to stepGhost.
		--
		-- PLUS ONE, because the ending step is still OWED its final tick. Each engine pass moves
		-- the sprite and THEN decrements, so a step chained at duration 1 has only received 3 of
		-- its 4 AddStepVector calls -- the first version wrote a plain full duration and every
		-- chained step landed one stride short, which the re-anchor reported as +-4px per chain,
		-- sign following travel (47 corrections in the first verification lap). The +1 makes the
		-- next step's passes 1 owed + a full step: measured back to zero corrections.
		--
		-- `CopyCoordsTileToLastCoordsTile` is what the skipped landing would have done, so its
		-- write happens here instead; without it the collision system keeps the tile before last
		-- occupied. A turn, a gait change, a multi-tile deficit or a drawn-tier peer all fall
		-- through to the landing path below, unchanged -- the engine cannot turn mid-step and
		-- neither can this.
		local chx, chy = u8(g.st_base + F_MAP_X) or 0, u8(g.st_base + F_MAP_Y) or 0
		local pgx, pgy = facingFrames.pathGoal(g, x, y, chx, chy)
		local chDir = DELTA_TO_DIR[string.format("%d,%d", pgx - chx, pgy - chy)]
		-- Clamped to this cartridge's own table, exactly as stepGhost's is, and for the same
		-- reason: the guard below compares the walking byte the engine is CURRENTLY carrying
		-- against `chGroup * 4 + chDir`, so an unclamped group would never match what stepGhost
		-- actually wrote and every chain would be refused -- the slow, correct-looking failure.
		local chGroup = ENGINE.gait(peerGait)
		-- ONLY ON EVIDENCE OF CONTINUATION (2026-08-25, same day as the chain itself). The chain
		-- commits on the step's LAST tick from an arrival that is 2-3 frames stale, and a
		-- mid-motion reversal lives in exactly that window: the ghost chained one tile PAST the
		-- tile the peer turned on and then had to walk back -- an overshoot-and-return the player
		-- never made, which at bike speed the user read as the ghost *"reversing instead of
		-- hitting the walls/stopping. mid movement reverse"*. The landing path this replaced had
		-- absorbed reversal news by accident, in the 3-4 frames it wasted.
		--
		-- So the stale position alone is no longer enough: the same arrival must also say the
		-- peer is still WALKING, FACING the chain's direction. An instant reversal turns the
		-- direction byte the moment its new step starts and reads as standing for the beat
		-- between steps, so the bait packets fail one guard or the other; a genuine continuation
		-- passes both. A refused chain costs nothing -- the landing path below still takes the
		-- step, at its old pace.
		if chDir and stepType == 2 and (u8(g.st_base + F_STEP_DURATION) or 0) == 1
			and (walking & 0x0F) == chGroup * 4 + chDir
			and peerWalking and ORIENTATION_TO_DIR[state.orientation] == chDir then
			-- The residual, counted: a chain whose very next step reverses within a step's worth
			-- of frames is an overshoot the guard did not catch (a packet sent before the peer
			-- itself knew). Read by the overshoot check in stepGhost's caller below.
			g.chainAt, g.chainDir = drawFrames, chDir
			w8(g.st_base + F_LAST_MAP_X, chx)
			w8(g.st_base + F_LAST_MAP_Y, chy)
			w8(g.st_base + F_STEP_DURATION, GAIT_TICKS[chGroup] + 1)
			w8(g.st_base + F_MAP_X, pgx)
			w8(g.st_base + F_MAP_Y, pgy)
			if stepLag.on then
				stepLag.close(id)
			end
			return
		end
		-- STEP_LAG: the one nameable reason a step waits after arriving. A tile that lands while the
		-- ghost is still walking the previous one cannot be acted on, and every frame of that wait
		-- is a frame the ghost is behind its peer.
		if stepLag.on and stepLag.open[id] then
			stepLag.blocked = stepLag.blocked + 1
			-- WHAT the ghost is busy doing, not just that it is busy (2026-08-26). The whirlpool
			-- case shows 37-133 blocked frames per report while a step is 16 -- so the ghost reads
			-- as walking for several steps' worth of frames at a stretch, and the counter alone
			-- cannot say what state is holding it there. Throttled to one line per 15 blocked
			-- frames, so it costs nothing outside the exact condition under investigation.
			if (stepLag.blocked % 15) == 1 then
				logFile(string.format(
					"blocked f=%d %s walk=%d stype=%d dur=%d act=%d ghost %d,%d peer %d,%d",
					drawFrames, id, walking, stepType, u8(g.st_base + F_STEP_DURATION) or 0,
					u8(g.st_base + F_ACTION) or 0,
					u8(g.st_base + F_MAP_X) or 0, u8(g.st_base + F_MAP_Y) or 0, x, y))
			end
		end
		return
	end

	local cx, cy = u8(g.st_base + F_MAP_X) or 0, u8(g.st_base + F_MAP_Y) or 0

	-- RE-ANCHOR THE SPRITE TO ITS TILE WHENEVER THE GHOST IS STANDING.
	--
	-- `stepGhost` advances the sprite's SCREEN position by adding a delta each step, to make up the
	-- 2px the engine applies in the frame it starts a step and we cannot. An accumulating
	-- correction has no way back: every frame that is missed, doubled, or lands while the camera is
	-- moving leaves an error that is never removed, so the ghost slides further off its tile the
	-- longer it walks. The user, 2026-08-22, with a screenshot showing it sitting visibly off the
	-- grid down and to the right while the painted copy and the player stayed aligned: *"the
	-- spawned ghost gets offset/slowly slides of its intended tile when walking around"*.
	--
	-- A standing ghost's screen position is not a matter of opinion: it is `screenCoords` of the
	-- tile it is on, which is exactly what `teleportGhost` writes. So the drift is discarded at
	-- every idle frame and can never exceed one step. This is a correction, not a model change --
	-- the per-step delta still does the mid-step work, it just no longer gets to keep its mistakes.
	--
	-- Guarded on the camera for the same reason the teleport is: mid-scroll the window registers
	-- describe a frame that is still being built, so the "correct" position would be wrong.
	--
	-- The size of each correction is logged rather than applied silently, because it says WHERE the
	-- drift comes from: a steady 2px per step is the compensation being wrong, while occasional
	-- large jumps are frames lost somewhere else. Silent in a healthy session.
	if cameraSettled() then
		local wantX, wantY = screenCoords(cx, cy)
		local haveX, haveY = u8(g.st_base + F_SPRITE_X) or 0, u8(g.st_base + F_SPRITE_Y) or 0
		if haveX ~= wantX or haveY ~= wantY then
			local ddx = ((wantX - haveX + 128) & 0xFF) - 128
			local ddy = ((wantY - haveY + 128) & 0xFF) - 128
			w8(g.st_base + F_SPRITE_X, wantX)
			w8(g.st_base + F_SPRITE_Y, wantY)
			snaps.drift = (snaps.drift or 0) + 1
			-- SIGNED, and the lack of a sign cost this investigation two passes. Logging only the
			-- magnitude made "the step lands 2px SHORT" and "the compensation overshoots by 2px"
			-- print the identical line, so two opposite faults were indistinguishable and the same
			-- number was read as confirming whichever theory was current. A correction's direction
			-- is the whole of its diagnosis.
			snaps.driftPx = math.max(snaps.driftPx or 0, math.abs(ddx) + math.abs(ddy))
			snaps.driftDir = string.format("%+d,%+d", ddx, ddy)
			if math.abs(ddx) + math.abs(ddy) > 2 then
				-- NAME THE STATE, do not just report the size. A 16px correction is a WHOLE TILE,
				-- and the difference between "a step advanced MAP_X and the sprite never followed"
				-- and "the sprite was moved by something else" is entirely in the step machinery --
				-- which this line used to leave to be guessed at from timestamps. Four of these
				-- appeared in the 2026-08-23 square run, all +16,+0, evenly spaced, and correlating
				-- them from outside the adapter ruled out promotions and got no further.
				logFile(string.format("MeshGhost: re-anchored %s to its tile by %+d,%+d px "
					.. "(a drift bigger than one step's compensation) -- tile %d,%d last %d,%d "
					.. "walking=%s step_type=%s duration=%s action=%s facing=%s",
					id, ddx, ddy, cx, cy,
					u8(g.st_base + F_LAST_MAP_X) or 0, u8(g.st_base + F_LAST_MAP_Y) or 0,
					tostring(u8(g.st_base + F_WALKING)), tostring(u8(g.st_base + F_STEP_TYPE)),
					tostring(u8(g.st_base + F_STEP_DURATION)),
					tostring(u8(g.st_base + F_ACTION)), tostring(u8(g.st_base + F_FACING))))
			end
		end
	end
	-- (The peer's vertical nudge is written ABOVE the mid-step return, near the top of this
	-- function -- it used to be here, which meant a moving ghost never received it. See the block
	-- there for the measurement that moved it.)
	if cx == x and cy == y then
		-- Not moving, but the peer may have TURNED IN PLACE — a real and common action in this
		-- game, and one the ghost missed entirely until 2026-08-18 because renderRemote only ever
		-- looked at position. Facing then came from whichever way the ghost last walked.
		--
		-- DIRECTION and FACING both take dir*4. FACING's low bits are the walk-cycle subframe the
		-- engine advances during a step, so writing the base value while idle is safe; doing it
		-- mid-step would fight the animation, which is why this sits behind the idle check.
		local want = ORIENTATION_TO_DIR[state.orientation]
		if want and u8(g.st_base + F_DIRECTION) ~= want * 4 then
			w8(g.st_base + F_DIRECTION, want * 4)
			w8(g.st_base + F_FACING, want * 4)
			-- A turn has to survive the engine's own restore, which re-reads the movement byte and
			-- turns the object to face whatever it names -- so the byte moves with the turn.
			setGhostStanding(g.st_base, g.mo_base, want)
		end
		-- Standing still is not the same as doing nothing: fishing, bumping a wall, spinning on a
		-- spin tile, the "!" emote and the Fly landing all happen without the peer changing tile,
		-- and until 2026-08-21 a ghost showed none of them. The direction is set first because
		-- the action handlers that need one (fishing) read it via GetSpriteDirection.
		applyPeerAction(g, peerAct)
		return
	end
	local gx, gy = facingFrames.pathGoal(g, x, y, cx, cy)
	local dx, dy = gx - cx, gy - cy
	local dir = DELTA_TO_DIR[string.format("%d,%d", dx, dy)]

	-- STEP_LAG: WHAT THE PATH QUEUE DECIDED, on every frame the ghost is standing and owes a move.
	-- Added 2026-08-26. The measured fault is that a peer oscillating between two tiles has its
	-- INTERMEDIATE moves dropped -- 6 player arrivals on the whirlpool tile against 3 for the
	-- ghost, every taken step correctly 5 frames behind -- and `pathGoal` is the function whose
	-- whole job is to stop that. The existing `ghost step` line only prints when a step IS issued,
	-- so a frame with a deficit and no step is invisible, which is exactly the frame in question.
	-- Bounded: one line per standing frame that owes a move, i.e. only while the ghost is behind.
	if stepLag.on and (cx ~= x or cy ~= y) then
		logFile(string.format(
			"path f=%d %s ghost %d,%d peer %d,%d goal %d,%d dir=%s q=%d pathXY=%s,%s",
			drawFrames, id, cx, cy, x, y, gx, gy, tostring(dir),
			g.path and #g.path or 0, tostring(g.pathX), tostring(g.pathY)))
	end

	-- WAIT FOR THE PEER TO BE `STEP_TRIGGER_PROG` PIXELS INTO ITS STEP, rather than for its tile
	-- index to change. See that constant for why the tile is the wrong clock.
	--
	-- Only for the ONE-TILE case. A ghost that is already behind (the catch-up walk below) or a peer
	-- that has warped (the teleport) is not in phase with anything, so making either wait would add
	-- delay to the two paths that exist because the ghost is late already.
	--
	-- The peer's map pixels are absolute and carry no loopback offset, so the destination is compared
	-- in the peer's own frame (`baseX`), not in the shifted one the ghost lives in. Mixing those puts
	-- the offset into the progress and the ghost never steps at all.
	if dir and STEP_TRIGGER_PROG > 0 and peerPixX and peerPixY then
		-- The peer is `16 - prog` pixels short of its destination, along the way it came -- the same
		-- relation the drawn tier's `offsetFromDest` rests on, read backwards.
		local short = math.abs(peerPixX - baseX * 16) + math.abs(peerPixY - y * 16)
		local prog = 16 - short
		-- A peer more than a tile from its own destination is not mid-step in any useful sense (a
		-- warp, a map load, a sample from the world we just left). Let it through rather than
		-- stalling the ghost on a number that means nothing.
		if short >= 0 and short <= 16 and prog < STEP_TRIGGER_PROG then
			stepLag.waits = (stepLag.waits or 0) + 1
			return
		end
	end

	-- STEP_LAG: EVERY STEP THE SPAWNED GHOST TAKES, with which branch issued it and how far
	-- behind it was. The user sees a snap 2-3 tiles into a walk after a respawn, and every
	-- positional instrument reads clean (0 teleports, 0 re-anchors, 0 snap reports) -- so the
	-- question is the RHYTHM: the gap in frames between successive steps, against the peer's own.
	-- One line per commanded step, so bounded at walk rate.
	if stepLag.on then
		logFile(string.format("ghost step f=%d %s %s ghost %d,%d -> peer %d,%d deficit %d prog=%s",
			drawFrames, id, dir and "inphase" or "catchup", cx, cy, x, y,
			math.abs(dx) + math.abs(dy), tostring(peerProg)))
	end
	if dir then
		-- NO CLOCK GATE HERE, and that is a measured decision (2026-08-25). A gate issuing
		-- this on camera-move frames was added to chase a 1-frame parity slip and then removed:
		-- the raw three-way trace shows the spawned ghost already advancing on EXACTLY the
		-- player's frames, constant separation, because the engine moves both. The "slip" was an
		-- artefact of the aggregate the analysis started from -- a per-frame delta histogram over
		-- a series that also contains starts and stops -- and it did not survive printing the
		-- frames themselves. The gate did suppress a duplicate issue on the following frame, which
		-- `stepGhost`'s own standing check already makes harmless.
		if stepLag.on then
			stepLag.close(id)
		end
		-- REVERSAL RETRACE, counted. A step opposite a recent chain is the ghost turning on the
		-- same tile the peer turned on -- with the path queue this is the CORRECT shape at every
		-- quick reversal, so the line exists to show reversals reaching the turn tile rather
		-- than to flag a fault. Before the queue it fired at only ONE end of an up/down drill,
		-- which is what proved the other end was being cut short.
		if g.chainDir and dir == (g.chainDir ~ 1)
			and drawFrames - (g.chainAt or -999) <= 16 then
			logFile(string.format("reversal retrace: %s chained %s at f=%d, reversing %s at f=%d",
				id, DIR_NAMES.letter[g.chainDir] or "?", g.chainAt or -1,
				DIR_NAMES.letter[dir] or "?", drawFrames))
		end
		-- THE HOP GOES THROUGH THE IN-PHASE PATH ONLY, never the catch-up one below. A jump
		-- crosses TWO tiles by itself, so issuing one while the ghost is already behind would
		-- overshoot the peer -- and catch-up is an abnormal path whose whole job is to close a
		-- deficit by the shortest legal walk. A peer that hops while its ghost is lagging simply
		-- walks the ledge; that is a worse-looking frame than a hop and a better one than a ghost
		-- two tiles past where it should be.
		stepGhost(g, dir, peerGait, peerJump) -- one tile: walk it, so the game animates the step
	elseif math.abs(dx) + math.abs(dy) <= 3 then
		-- A SHORT deficit is walked, not snapped. The old rule teleported for anything past one
		-- tile, and a ghost falls two tiles behind in perfectly ordinary play -- a missed idle
		-- window, a 3-frame loopback lag, one skipped step. Worse, teleportGhost waits for a
		-- settled camera, so during continuous walking the ghost FROZE until the player paused and
		-- then visibly jumped (the user's "teleporting around a bit", 2026-08-21). One real step
		-- per idle window toward the target catches up at double the peer's pace (the ghost walks
		-- every window, the peer only every other), stays animated the whole way, and never snaps.
		-- The larger axis first, so a diagonal deficit walks an L rather than dithering.
		local stepDir
		if math.abs(dx) >= math.abs(dy) then
			stepDir = (dx > 0) and 3 or 2
		else
			stepDir = (dy > 0) and 0 or 1
		end
		if stepLag.on then
			stepLag.close(id)
		end
		stepGhost(g, stepDir, peerGait)
	else
		-- A far snap that arrives wearing MAPSETUP_FLY is a landing: the ghost falls onto the
		-- tile instead of blinking onto it. `dropT ~= nil` rather than the raw flag, so the
		-- engine fall and the painted copies' drop share one start frame and one envelope.
		teleportGhost(g, x, y, dropT ~= nil) -- genuinely far (a warp, a long silence): snap, don't fake a walk
	end
end

----------------------------------------------------------------------------
-- Bridge
----------------------------------------------------------------------------

local sock, connected, ready = nil, false, false
local rxBuffer = ""
local sinceRetry = 0

local function disconnect(why)
	if sock then
		pcall(function()
			sock:close()
		end)
	end
	sock, connected, ready, rxBuffer = nil, false, false, ""
	for id in pairs(ghosts) do
		despawnGhost(id)
	end
	overflow = {} -- drawn peers leave with the connection, the same as spawned ones
	-- AND WIPE WHAT WAS ALREADY PAINTED, because forgetting a peer does not un-draw it.
	--
	-- The spawned tier's ghosts are real engine objects, so despawning them above genuinely removes
	-- them. A drawn peer is pixels on BizHawk's overlay, and those persist until something clears
	-- the canvas or paints over it. Nothing does either after this point: `drawOverflow()` is the
	-- LAST call in tick(), and tick() returns early at `if not connected then return end` -- so the
	-- final frame painted before the bridge dropped stays on screen for the rest of the session.
	--
	-- What that looks like is not "a leftover sprite", which is why it was mis-diagnosed twice. It
	-- is painted in SCREEN pixels, so as the player walks and the camera scrolls it holds the same
	-- spot on the display and appears to FOLLOW them, frozen in one pose. The user, 2026-08-23,
	-- reproducing it deliberately by killing the core and relay with both tiers up: *"the spawned
	-- ghost went away, but the drawn one is 'stuck/static' and still on the screen"*, and then
	-- *"its stuck in a static pose, but still following the player around"*. It is also why ghosts
	-- were still on screen after the previous session's server was shut down.
	--
	-- `drawOverflow`'s own `stopDrawing()` is the same one line and exists for the same reason (a
	-- door transition, where every gate returns early and nothing repaints). It is a local inside
	-- that function and cannot be reached from here, so the call is repeated rather than hoisted --
	-- hoisting it would put a drawing primitive in the bridge's scope for one caller.
	pcall(function() gui.clearGraphics() end)
	if why then
		log("MeshGhost: bridge lost (" .. why .. ")")
	end
end

local function send(obj)
	if not sock then
		return
	end
	local line = jsonEncode(obj) .. "\n"
	local ok, err = sock:send(line)
	if not ok and err ~= "timeout" then
		disconnect(tostring(err))
	end
end

-- Ports that answered but would not have us, with the frame their cooldown ends.
local busyUntil = {}
local currentPort = nil
local helloSentAtFrame = nil
local bridgeFrames = 0
-- Set when a core reports the relay is unreachable; until then, do not walk ports or spawn cores.
local relayDownUntil = 0

local function markPortBusy(port, why)
	if port then
		busyUntil[port] = bridgeFrames + BUSY_PORT_COOLDOWN_FRAMES
		log(string.format("MeshGhost: port %d %s — skipping it for %ds.",
			port, why, BUSY_PORT_COOLDOWN_FRAMES // 60))
	end
end

local function tryPort(port)
	local s = socketCore.tcp()
	if not s then
		return false
	end
	s:settimeout(0.05)
	local ok = s:connect(BRIDGE_HOST, port)
	if not ok then
		pcall(function()
			s:close()
		end)
		return false
	end
	s:settimeout(0)
	sock, connected, ready, rxBuffer = s, true, false, ""
	currentPort, helloSentAtFrame = port, bridgeFrames
	-- Log the port, always. With a walk, "connected" no longer implies a known port, and the port
	-- is the first thing anyone needs when two instances start behaving as one.
	log(string.format("MeshGhost: bridge connected on %s:%d", BRIDGE_HOST, port))
	-- `render_all_areas` (ADR 0036) tells the core to stop applying its own cross-area equality
	-- filter and deliver every remote regardless of area_id, because THIS ADAPTER now owns area
	-- visibility. Without it the core despawns every peer at every seam crossing: an echoed
	-- area_id lags a real crossing by one delivery and an equality test cannot know two maps are
	-- connected, so the pop would be one the adapter could not prevent from its side.
	--
	-- Sent ONLY when cross-map is actually armed. On a build where the connection block is
	-- unmeasured there is nothing to replace the core's filter with, and taking it away would be
	-- a straight regression -- the adapter's own gate would still hide the peers, but the core
	-- would be shipping states across the bridge for nothing.
	send({ type = "hello", payload = { game_id = GAME_ID, game_version = GAME_VERSION,
		render_all_areas = ENGINE.xmap.armed() or nil } })
	return true
end

-- One sweep across the whole range per cooldown, NOT one port per cooldown: each candidate costs
-- at most the 50ms connect timeout against a closed port (usually far less, since a refused
-- connection is immediate on loopback), whereas one port per 2s would take 16 seconds to find a
-- free core eight ports up.
-- The first port in the range with NOTHING listening, as seen by the last sweep -- where
-- autostart puts a new core. Taken from the sweep rather than assuming BRIDGE_BASE_PORT: with two
-- copies of the game running, the base port is the FIRST copy's core, and spawning there produces
-- a core that cannot bind and exits instantly, leaving the second emulator with none. Found live
-- on Emerald, 2026-08-18. A port that answered and then rejected us is somebody else's core, not
-- a free one, and is skipped by busyUntil rather than recorded here.
local firstFreePort = nil

local function connect()
	if BRIDGE_PORT_OVERRIDE then
		firstFreePort = BRIDGE_PORT_OVERRIDE
		-- The cooldown applies here TOO. It was checked only in the walk below, so an override --
		-- which every dev launcher sets, and which any two-instance setup needs -- retried the
		-- same port on the very next frame while markPortBusy had just printed "skipping it for
		-- 10s". Found in Emerald live 2026-08-28 and fixed in both, since the shape is identical.
		if (busyUntil[BRIDGE_PORT_OVERRIDE] or 0) <= bridgeFrames then
			tryPort(BRIDGE_PORT_OVERRIDE)
		end
		return
	end
	firstFreePort = nil
	for i = 0, BRIDGE_PORT_COUNT - 1 do
		local port = BRIDGE_BASE_PORT + i
		if (busyUntil[port] or 0) <= bridgeFrames then
			if tryPort(port) then
				return
			end
			if not firstFreePort then
				firstFreePort = port
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Autostart: start a core ourselves, and let it die with the emulator.
--
-- os.execute and io.popen cannot do this without a visible console: both run `cmd /c ...`, so the
-- window belongs to the shell doing the launching and hiding the child cannot help (all five
-- shell variants were watched flashing, 2026-08-18). luanet -- NLua's .NET bridge, which BizHawk
-- exposes -- builds System.Diagnostics.Process directly with UseShellExecute=false and
-- CreateNoWindow=true, and that is genuinely invisible (confirmed against a window-showing
-- control). GetCurrentProcess().Id is EmuHawk's pid, so -exit-with-pid gives auto-close for free.
-- See agent_docs/environment.md and dev-scripts/bizhawk-spawn-probe.lua.
local coreChild, coreSpawnFrame, coreSpawnFailed = nil, nil, false
local AUTOSTART = os.getenv("MESHGHOST_NO_AUTOSTART") == nil

-- meshghost.exe is not shipped inside game folders (9 MB, once per game), so look where it
-- actually lives: the release root is three levels up from games/pokemon/crystal, a source
-- checkout four up. Beside the script wins if someone deliberately put one there.
local function findCoreExe()
	local candidates = {
		SCRIPT_DIR .. "/meshghost.exe",
		SCRIPT_DIR .. "/../../../meshghost.exe",
		SCRIPT_DIR .. "/../../../../meshghost.exe",
	}
	for _, path in ipairs(candidates) do
		local f = io.open(path, "rb")
		if f then
			f:close()
			return path
		end
	end
	return nil
end

local function coreStillRunning()
	if not coreChild then
		return false
	end
	local ok, exited = pcall(function() return coreChild.HasExited end)
	if not ok then
		return false
	end
	return not exited
end

local function startCore(port)
	-- THE WALK MOVED OFF OUR OWN CHILD'S PORT WHILE THE CHILD IS ALIVE: another instance reached
	-- it first and it answered us busy. Read as "my child is running, so I have a core", nothing
	-- below would ever spawn again and the walk would find silence on every other port for the
	-- rest of the session -- watched on TEVI's launcher 2026-09-02, fixed there and in
	-- Pseudoregalia's, mirrored here. The child is forgotten, never killed: a game is using it.
	-- The port rides in coreSpawnFrame (a table since 2026-09-02) because this file cannot afford
	-- another local (the 200-local ceiling, emulator/CLAUDE.md).
	-- Forgotten ONLY when that port answered "busy" (coreSpawnFrame.busy, set by the reject
	-- handler), never because the cursor moved on -- the first version forgot the child on
	-- silence too, and two instances restarting together then chased each other's fresh cores
	-- round the range (Emerald, 2026-09-02: three cores for two games, the emulator at 3fps).
	if coreStillRunning() and coreSpawnFrame and coreSpawnFrame.busy and port then
		console.log(string.format("MeshGhost: the core this script started on port %d is serving another instance -- leaving it and starting another on port %d.", coreSpawnFrame.port, port))
		coreChild = nil
	end
	if not AUTOSTART or coreSpawnFailed or coreStillRunning() then
		return
	end
	-- Every port in the range is somebody else's core; spawning would just fail to bind.
	if not port then
		return
	end
	-- A core takes a moment to bind. Spawning again before then is how you get a pile of
	-- processes fighting over one port.
	if coreSpawnFrame and (bridgeFrames - coreSpawnFrame.frame) < 300 then
		return
	end

	local exe = findCoreExe()
	if not exe then
		coreSpawnFailed = true
		log("MeshGhost: meshghost.exe not found near this script -- not starting a core. "
			.. "Start it yourself, or put a copy beside this file.")
		return
	end

	coreSpawnFrame = { frame = bridgeFrames, port = port }
	local ok, err = pcall(function()
		luanet.load_assembly("System") -- without this, import_type returns nil
		local Process = luanet.import_type("System.Diagnostics.Process")
		local StartInfo = luanet.import_type("System.Diagnostics.ProcessStartInfo")
		local si = StartInfo()
		si.FileName = exe
		-- No relay settings: the core reads config.json from its own directory, which is the file
		-- a player edits. Passing -relay here would silently override it.
		si.Arguments = string.format("-exit-with-pid=%d -bridge=%s:%d",
			Process.GetCurrentProcess().Id, BRIDGE_HOST, port)
		-- THE CORE READS ITS config.json FROM ITS WORKING DIRECTORY, so it has to be the
		-- directory the exe lives in -- which is where the player's config.json is, and where
		-- every README says to keep the pair together.
		--
		-- Without this the child inherits the emulator's working directory, finds no config.json
		-- there, and silently falls back to built-in defaults: connect_to 127.0.0.1:7777, the
		-- player's own machine. Someone who edited the release-root config.json to reach a
		-- friend's host would autostart a core that quietly ignored it and connected to nobody,
		-- with a log line in a folder they were never told to look in. Measured 2026-08-28 with
		-- a staged release, which reported exactly that:
		--   "no config file at ...\games\pokemon\emerald\config.json -- using built-in defaults"
		--
		-- TEVI (WorkingDirectory) and Pseudoregalia (CreateProcessW's lpCurrentDirectory) have
		-- always set this; these two adapters were the pair that did not.
		si.WorkingDirectory = (exe:gsub("meshghost%.exe$", ""))
		si.UseShellExecute = false
		si.CreateNoWindow = true
		coreChild = Process.Start(si)
	end)
	if not ok then
		coreSpawnFailed = true
		log("MeshGhost: could not start a core: " .. tostring(err))
		return
	end
	log(string.format("MeshGhost: started a core (no window) on bridge port %d; "
		.. "it will exit with the emulator.", port))
end

local function handle(msg)
	if type(msg) ~= "table" then
		return
	end
	local t, p = msg.type, msg.payload or {}
	if t == "bridge_ready" then
		ready = true
		log("MeshGhost: bridge_ready — this core is ours")
	elseif t == "reject" then
		local reason = tostring(p.reason)
		log("MeshGhost: rejected (" .. reason .. ")")
		-- ONE rejection means something different from the others, and treating them alike costs
		-- the player their frame rate. "busy" means this core has an adapter, so the answer is to
		-- try the next port. **"cannot reach the relay" means this core is perfectly good and the
		-- RELAY is unavailable** -- walking on finds nothing, every port gets marked busy, and the
		-- adapter then starts spawning fresh cores at the retry cadence. Emerald was measured at
		-- 5fps doing exactly that while a relay was full (2026-08-19). Wait for the same core
		-- instead: it retries the relay by itself, and reconnects when the relay comes back.
		if reason:find("relay", 1, true) then
			relayDownUntil = bridgeFrames + RELAY_DOWN_BACKOFF_FRAMES
			disconnect(nil)
			return
		end
		-- The reason is carried rather than guessed at: every rejection used to be reported as
		-- "already has an adapter", so the line above could print the truth and this one
		-- contradict it. Not BRANCHING on a reason is the rule; inventing one is not.
		if reason:find("busy", 1, true) and coreSpawnFrame and currentPort == coreSpawnFrame.port then
			coreSpawnFrame.busy = true -- our own child has another game: startCore may forget it
		end
		markPortBusy(currentPort, "refused us (" .. reason .. ")")
		disconnect(nil)
	elseif t == "render_remote" then
		renderRemote(tostring(p.player_id), p.state)
	elseif t == "despawn_remote" then
		-- BOTH tiers, and the activity record with them. despawnGhost only knows about spawned
		-- ghosts, so before this the drawn tier kept painting a peer who had left -- forever, and
		-- invisibly to every count except the one that says how many peers are waiting. Found by
		-- killing 20 of 89 synthetic peers and watching the number not move (2026-08-19).
		local gone = tostring(p.player_id)
		despawnGhost(gone)
		overflow[gone] = nil
		overflow[COMPARE.key(gone)] = nil
		overflow[COMPARE.hwKey(gone)] = nil
		activity[gone] = nil
	end
end

local function receive()
	if not sock then
		return
	end
	local chunk, err, partial = sock:receive(4096)
	local data = chunk or partial
	if data and #data > 0 then
		rxBuffer = rxBuffer .. data
	elseif err and err ~= "timeout" then
		disconnect(tostring(err))
		return
	end
	while true do
		local nl = rxBuffer:find("\n", 1, true)
		if not nl then
			break
		end
		local line = rxBuffer:sub(1, nl - 1)
		rxBuffer = rxBuffer:sub(nl + 1)
		if #line > 0 then
			handle(jsonDecode(line))
		end
	end
end

----------------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------------

local romClass, romWhy, romTable = classifyRom()
log("=== MeshGhost — Pokémon Crystal ===")

-- Select the address set BEFORE anything reads or writes memory. An unknown ROM still gets
-- vanilla's, which is the deliberate run-anyway case; an Archipelago ROM gets its own or none.
local A = ADDRESSES[romTable or "vanilla"]
OBJECT_STRUCTS, MAP_OBJECTS = A.OBJECT_STRUCTS, A.MAP_OBJECTS
W_MAPGROUP, W_MAPNUMBER = A.W_MAPGROUP, A.W_MAPNUMBER
W_YCOORD, W_XCOORD = A.W_YCOORD, A.W_XCOORD
W_MAPSTATUS, W_BATTLEMODE = A.W_MAPSTATUS, A.W_BATTLEMODE
W_BGMAPOFFSETX, W_BGMAPOFFSETY = A.W_BGMAPOFFSETX, A.W_BGMAPOFFSETY
-- Cross-map ghosts. All three or none: nil on a build where the block is unmeasured, and
-- ENGINE.xmap.armed() then keeps the whole feature off rather than translating against a guess.
ENGINE.xmap.connAt, ENGINE.xmap.wAt, ENGINE.xmap.hAt = A.W_MAPCONNECTIONS, A.W_MAPWIDTH, A.W_MAPHEIGHT
W_USEDSPRITES = A.W_USEDSPRITES -- optional: nil means "peer appearance off on this build"
W_STATEFLAGS = A.W_STATEFLAGS -- optional: nil turns the hardware tier off on that build
OVERWORLD_SPRITES_ROM = A.OVERWORLD_SPRITES_ROM -- optional: nil means "no cartridge graphics here"
-- The fishing rod's cartridge graphics, and ONLY on the ROM whose hash we built ourselves.
-- Unlike the sprite table above this one has no six-byte signature worth checking -- two tiles of
-- art look like any other two tiles -- so the gate is the ROM identity rather than the contents.
-- nil means a fishing peer's body is drawn and its rod is not, which is a missing detail rather
-- than a wrong one. On `facingFrames` rather than a new top-level local: 200-local ceiling.
EMOTES_ROM = (romClass == "known") and A.EMOTES_ROM or nil
-- The flying Pokemon's icon, same ROM gate and same reasoning as the fishing graphics below.
facingFrames.iconTbl = (romClass == "known") and A.MON_ICONS_ROM or nil
facingFrames.iconPtrs = (romClass == "known") and A.ICON_POINTERS_ROM or nil
facingFrames.iconBank = A.ICONS_BANK
ENGINE.curPartyMon, ENGINE.partySpecies = A.W_CURPARTYMON, A.W_PARTYSPECIES
ENGINE.sprOn = A.W_SPRITEUPDATESON -- nil on an unmeasured build: the gate simply never fires
facingFrames.fishChris = (romClass == "known") and A.FISHING_GFX_ROM or nil
facingFrames.fishKris = (romClass == "known") and A.FISHING_GFX_ROM_KRIS or nil
facingFrames.shadowRom = (romClass == "known") and A.SHADOW_GFX_ROM or nil
-- HOW THE PLAYER LAST ENTERED A MAP. `hMapEntryMethod` ($ff9f -- HRAM, unbanked, read via the
-- System Bus, NOT the WRAM domain the address table above serves) is stamped with a MAPSETUP_*
-- value at every map load and zeroed in the same routine that hands the overworld back
-- (`engine/overworld/events.asm`; the address from our own build's pokecrystal.sym, the values
-- from `constants/map_setup_constants.asm`). $FC is MAPSETUP_FLY, which is what lets a peer's
-- ghost drop out of the sky when its player arrives by Fly. Gated on ROM identity like the
-- fishing graphics: HRAM is as rearrangeable by a patch as WRAM, and this one is unmeasured on
-- any other build. nil means peers on that build simply appear, which is what they did before.
ENGINE.entryAddr = (romClass == "known") and 0xFF9F or nil

-- HOW MANY GAITS THIS CARTRIDGE HAS. Asked of the ROM at startup because it is the one capability
-- that has to be answered for the REMOTE end: a peer on a build with a faster gait than ours
-- reports it, and this is what decides whether the engine can be told to walk at it or whether
-- that peer belongs on the drawn tier, which can move at any speed because it moves in Lua.
--
-- The address table's entry is a hint that gets re-checked, not a value that gets trusted -- an
-- unrecognised build is handed vanilla's addresses by the run-anyway fallback, and a wrong offset
-- here would count groups out of unrelated bytes. When the hint fails, bank 1 is searched for the
-- table's own signature, which is what makes a build nobody has measured still get a real answer.
-- THE CAMERA, per build. HRAM, so the System Bus rather than the WRAM domain the rest of this
-- block serves. Vanilla's pair is from our own hash-verified build's pokecrystal.sym; the
-- Archipelago build's was measured 2026-08-26 after vanilla's turned out to be dead bytes there.
-- An unrecognised build gets vanilla's by way of the run-anyway fallback, exactly as it gets every
-- other address -- and ENGINE.camCheck is what notices when that is wrong, since this is the one
-- pair that cannot fail loudly on its own.
ENGINE.scxAddr, ENGINE.scyAddr = A.H_SCX, A.H_SCY

ENGINE.gaits = ENGINE.gaitGroups(A.STEP_VECTORS_ROM)
if not ENGINE.gaits then
	local found, at = ENGINE.gaitGroups(nil)
	ENGINE.gaits = found
	log(found
		and string.format("MeshGhost: the step-vector table is not at 0x%05X on this ROM; found "
			.. "it at 0x%05X with %d gaits", A.STEP_VECTORS_ROM or 0, at, found)
		or "MeshGhost: could not find the step-vector table on this ROM -- assuming vanilla's "
			.. "three gaits, which is the answer that cannot write past the end of it.")
end
ENGINE.gaits = ENGINE.gaits or 3
if ENGINE.gaits > 3 then
	log(string.format("MeshGhost: this ROM carries %d gaits, %d more than vanilla -- peers moving "
		.. "at one will be stepped at it.", ENGINE.gaits, ENGINE.gaits - 3))
end

-- CHECK THE TABLE IS WHERE WE THINK IT IS, before anything reads a graphics pointer out of it.
-- An address is measured per ROM build, but a build nobody has seen still gets vanilla's table by
-- way of the untested-build fallback, and a wrong ROM offset paints garbage rather than failing.
-- SPRITE_CHRIS is entry 0 and is the same on both builds measured (address 0x4000, 192 bytes,
-- bank 0x30, WALKING_SPRITE, palette 0), so it is a cheap six-byte assertion.
if OVERWORLD_SPRITES_ROM then
	local e = OVERWORLD_SPRITES_ROM
	local addr = (memory.read_u8(e, ROM_DOMAIN) or 0) | ((memory.read_u8(e + 1, ROM_DOMAIN) or 0) << 8)
	local size = memory.read_u8(e + 2, ROM_DOMAIN) or 0
	local bank = memory.read_u8(e + 3, ROM_DOMAIN) or 0
	local kind = memory.read_u8(e + 4, ROM_DOMAIN) or 0
	if not (addr >= 0x4000 and addr < 0x8000 and (size == 192 or size == 64)
		and bank > 0 and bank < 0x80 and kind >= 1 and kind <= 3) then
		log(string.format("MeshGhost: the sprite table is not at 0x%05X on this ROM "
			.. "(read addr=0x%04X size=%d bank=0x%02X type=%d) -- drawing peers from the "
			.. "cartridge is OFF, and they will wear this machine's sprite instead.",
			OVERWORLD_SPRITES_ROM, addr, size, bank, kind))
		OVERWORLD_SPRITES_ROM = nil
	end
end

-- WHETHER A SPRITE ID MEANS THE SAME CHARACTER ON TWO CARTRIDGES -- one number, computed from the
-- sprite table itself, put on the wire beside the id and compared for equality by the receiver.
--
-- A sprite id is not portable and never was. `extras.sprite` is an index into OverworldSprites,
-- and a patch is free to repoint an entry without moving the table or changing its length:
-- measured 2026-08-26, an Archipelago seed keeps vanilla's 102 entries and repoints five of them,
-- ids $62-$66 among them. So a peer on that build reporting sprite $65 to a vanilla receiver asks
-- it to draw vanilla's $65, which is a different character entirely -- not garbage, which is
-- worse, because nothing about it looks like a fault.
--
-- The signature is a 32-bit FNV-1a over the table's own 612 bytes, which is exactly the question
-- worth asking: two cartridges whose sprite tables are byte-identical assign the same graphics to
-- the same ids, whatever else differs between them. Measured across four: Crystal V1.0 and V1.1
-- agree (so ids ARE portable between those two, and a build-name comparison would have wrongly
-- said otherwise), while speedchoice 8.1 and the Archipelago seed each differ from vanilla and
-- from each other. Two Archipelago seeds share one base recompile and so share this number --
-- which is the case the user asked for: *"fine to do it for archipelago itself, so other
-- archipelago roms can see it"*.
--
-- Nil when this build has no measured sprite table. A receiver then cannot match, refuses the
-- peer's id, and falls back to this machine's own player sprite -- the behaviour a peer already
-- got here before any of this, so the unmeasured case loses nothing.
--
-- Costs one number per state packet, and it is the cheapest correct answer available: the room's
-- `game_version` cannot carry it, because a room refuses a client whose version disagrees and
-- letting a vanilla and an Archipelago player share a room is the entire point of this work.
if OVERWORLD_SPRITES_ROM then
	local h = 2166136261
	-- NUM_OVERWORLD_SPRITES, 102 -- `constants/sprite_constants.asm` counts the overworld list
	-- and stops before the special ids above it. The Archipelago seed keeps that length too, so
	-- this window covers both tables exactly; a build that shortened it would simply be hashing a
	-- few bytes of whatever follows, which changes nothing about a comparison for equality.
	for i = 0, 102 * SPRITEDATA_STRIDE - 1 do
		h = ((h ~ (memory.read_u8(OVERWORLD_SPRITES_ROM + i, ROM_DOMAIN) or 0)) * 16777619)
			& 0xFFFFFFFF
	end
	ENGINE.gfxSig = h
	log(string.format("MeshGhost: sprite-table signature %08X -- a peer's own sprite is worn only "
		.. "by a client whose cartridge reports the same number.", h))
end

-- PER SPRITE, NOT PER TABLE -- and this is the gate that actually ships.
--
-- The whole-table signature above was too blunt by an order of magnitude. Measured 2026-08-26:
-- vanilla and the Archipelago seed differ in FIVE of 102 sprite entries (ids $62-$66). The other
-- 97 are byte-identical, and they include every one that matters here -- Chris, Kris, both bikes,
-- the surf blob. Refusing a peer's sprite because the tables disagree SOMEWHERE threw away 97
-- sprites to protect against 5, and that is exactly what the user reported the same evening:
--
--   * on the Archipelago client a peer's ghost MIMICKED the local player -- with the id refused,
--     the drawn tier fell back to "wear this machine's own player sprite", read live every frame,
--     so mounting a bike locally mounted the ghost too;
--   * on the vanilla client an Archipelago peer was never shown mounting anything at all.
--
-- Both are one gate being wrong. The user's standard, and it is the right one: *"the other ghost
-- is not supposed to mimic what the player itself is doing"*, and *"the ghost is supposed to show
-- what its doing to the vanilla player"*.
--
-- So the question moves from "do our cartridges agree about EVERY sprite?" to "do they agree about
-- THIS ONE?", which is answerable exactly: hash the six bytes of that id's own row in
-- OverworldSprites (address, size, bank, type, palette) and compare. Equal means the id indexes
-- the same graphics on both machines and can be worn as-is; unequal means it does not, and only
-- that id falls back.
--
-- IT IS ALSO WHY NO STATE VOCABULARY IS NEEDED FOR THIS. The mount is ALREADY on the wire: a
-- player's own sprite id changes when they mount (measured the same day -- the player's
-- OBJECT_SPRITE went 1 -> 2 on the bike, alongside wPlayerState 0 -> 1), so a peer that can wear
-- its own id is a peer whose bike, surf blob and running pose come across for free.
--
-- Memoised: six ROM reads per sprite id, once. A session touches a handful of ids.
ENGINE.spriteSigs = {}
function ENGINE.spriteSig(id)
	if not OVERWORLD_SPRITES_ROM or not id or id < 1 or id > 255 then
		return nil
	end
	local c = ENGINE.spriteSigs[id]
	if c then
		return c
	end
	local e = OVERWORLD_SPRITES_ROM + (id - 1) * SPRITEDATA_STRIDE
	local v = 2166136261
	for i = 0, SPRITEDATA_STRIDE - 1 do
		v = ((v ~ (memory.read_u8(e + i, ROM_DOMAIN) or 0)) * 16777619) & 0xFFFFFFFF
	end
	ENGINE.spriteSigs[id] = v
	return v
end

if romClass == "known" then
	log("ROM: " .. romWhy .. " — addresses verified against a byte-identical build.")
elseif romClass == "archipelago" then
	log("ROM: " .. romWhy .. " — using its own measured address set.")
else
	-- One line, whatever the ROM. Toned down from a multi-line warning on the user's call
	-- (2026-08-18): every non-vanilla ROM is attempted, so a wall of caution on each startup is
	-- noise rather than information.
	--
	-- It still IDENTIFIES the ROM, which is the part that earns its place: if a ghost misbehaves
	-- on an untested build, the first line of the log already says which build it was. That is
	-- diagnostic value, not a warning.
	if os.getenv("MESHGHOST_CRYSTAL_STRICT") == "1" then
		log("REFUSING TO RUN (strict mode): " .. romWhy)
		return
	end
	log("ROM: untested — " .. romWhy .. ". Running anyway; object RAM only, never a save.")
end

-- A missing address is a refusal, never a fallback. Falling back to vanilla's value for one entry
-- is worse than not running: the gate would read a byte that means something else on this build,
-- pass, and start WRITING object RAM at addresses that were never checked.
-- Opt-in two ways, because the env var needs a BizHawk restart and an emulator is usually already
-- running by the time anyone decides to try: MESHGHOST_CRYSTAL_AP_TRY=1, or a file named
-- ap_try.flag beside this script. Deleting the file is how the experiment ends.
local TRY = os.getenv("MESHGHOST_CRYSTAL_AP_TRY") == "1"
if not TRY then
	local f = io.open(SCRIPT_DIR .. "/ap_try.flag", "r")
	if f then
		f:close()
		TRY = true
	end
end
local missing = {}
for _, name in ipairs({ "OBJECT_STRUCTS", "MAP_OBJECTS", "W_MAPGROUP", "W_MAPNUMBER", "W_YCOORD",
	"W_XCOORD", "W_MAPSTATUS", "W_BATTLEMODE", "W_BGMAPOFFSETX", "W_BGMAPOFFSETY" }) do
	if A[name] == nil then
		-- MESHGHOST_CRYSTAL_AP_TRY=1 is a deliberate experiment, never a default and never a
		-- fallback: it substitutes a NAMED candidate and says so on every startup, so a session
		-- run this way can always be told apart from a measured one afterwards. A missing
		-- candidate still refuses -- the flag lowers the bar to "unconfirmed", not to "invented".
		local c = TRY and A.candidates and A.candidates[name]
		if c then
			_G["__ap_try_" .. name] = c
			log(string.format("UNCONFIRMED ADDRESS IN USE: %s = 0x%04X (MESHGHOST_CRYSTAL_AP_TRY=1)",
				name, c))
		elseif TRY and name:match("^W_BGMAPOFFSET") then
			-- Not an address at all: zero makes screenCoords() position by whole tiles, which is
			-- visibly right on a tile boundary and up to a tile out mid-step.
			_G["__ap_try_" .. name] = 0
			log(string.format("NO ADDRESS FOR %s: using 0, so ghosts are positioned per TILE and "
				.. "will lag within a step.", name))
		else
			missing[#missing + 1] = name
		end
	end
end
if TRY then
	W_BATTLEMODE = W_BATTLEMODE or _G["__ap_try_W_BATTLEMODE"]
	W_BGMAPOFFSETX = W_BGMAPOFFSETX or _G["__ap_try_W_BGMAPOFFSETX"]
	W_BGMAPOFFSETY = W_BGMAPOFFSETY or _G["__ap_try_W_BGMAPOFFSETY"]
	log("This session is an EXPERIMENT: at least one address is unconfirmed. Nothing seen here")
	log("may be written to verified.md as a fact about the game.")
end
if #missing > 0 then
	log(string.format("REFUSING TO RUN on %s: %d address(es) not yet measured — %s.",
		A.label, #missing, table.concat(missing, ", ")))
	log("These are deliberately nil rather than guessed. Measure them with the probes beside this")
	log("script (see the adapter README), then fill them into ADDRESSES." .. (romTable or "?") .. ".")
	return
end

if BRIDGE_PORT_OVERRIDE then
	log(string.format("Bridge target %s:%d (MESHGHOST_BRIDGE_PORT is set, so no port walk).",
		BRIDGE_HOST, BRIDGE_PORT_OVERRIDE))
else
	log(string.format("Bridge: walking %s:%d-%d for a core that will have us. Two copies on one "
		.. "machine each find their own.", BRIDGE_HOST, BRIDGE_BASE_PORT,
		BRIDGE_BASE_PORT + BRIDGE_PORT_COUNT - 1))
end

local lastArea = nil

-- Experiment-mode diagnostic (ap_try.flag / MESHGHOST_CRYSTAL_AP_TRY=1 only). Prints, twice a
-- second, what the gate DECIDED and what it decided it from -- the Phase 9 lesson that a gate's
-- inputs beside its verdict is the thing worth logging, because a gate that silently says "no"
-- and a bridge that silently drops look identical from outside.
local diagFrames, diagLastKey = 0, nil
function diagnose(state)
	if not TRY then
		return
	end
	diagFrames = diagFrames + 1
	local key = state and (state.area_id .. "|" .. state.position[1] .. "," .. state.position[2]
		.. "|" .. state.orientation .. "|" .. state.anim) or "NO STATE"
	if diagFrames % 30 ~= 0 and key == diagLastKey then
		return
	end
	diagLastKey = key
	if state then
		logFile(string.format("gate: SENDING area=%s pos=%d,%d %s %s sprite=%s ghosts=%d "
			.. "[0FB1=%s 1439=%s]", state.area_id, state.position[1], state.position[2],
			state.orientation, state.anim, tostring(state.extras and state.extras.sprite),
			ghostCount(), tostring(u8(0x0FB1)), tostring(u8(0x1439))))
	else
		logFile(string.format("gate: NOT SENDING — status(0x%04X)=%s wants %d, battle(0x%04X)=%s "
			.. "wants 0, map=%s/%s [0FB1=%s 1439=%s]", W_MAPSTATUS, tostring(u8(W_MAPSTATUS)),
			ENGINE.MAPSTATUS_HANDLE, W_BATTLEMODE, tostring(u8(W_BATTLEMODE)), tostring(u8(W_MAPGROUP)),
			tostring(u8(W_MAPNUMBER)), tostring(u8(0x0FB1)), tostring(u8(0x1439))))
	end
end

local function tick()
	bridgeFrames = bridgeFrames + 1

	-- LATCHED EVERY FRAME, because the byte lives only inside the map-load window -- set at the
	-- warp, cleared by the same routine that sets wMapStatus back to HANDLE -- and getLocalState
	-- refuses to sample anything during that window. By the time the player is sendable again the
	-- byte is already zero, so the send side reads this latch instead of the byte. See the
	-- ENGINE.entryAddr note at startup for what the byte is and why it is ROM-gated.
	if ENGINE.entryAddr then
		local m = memory.read_u8(ENGINE.entryAddr, "System Bus") or 0
		if m ~= 0 then
			ENGINE.entry, ENGINE.entryAt = m, emu.framecount()
			-- LATCHED WITH THE ENTRY BYTE, not read later: `wCurPartyMon` is the party cursor and
			-- moves the moment the player opens a menu again, so by the time a peer's ghost is
			-- ready to show the landing the answer would already be a different Pokemon.
			if m == 0xFC then
				local slot = ENGINE.curPartyMon and u8(ENGINE.curPartyMon) or nil
				local sp = (slot and slot < 6 and ENGINE.partySpecies)
					and u8(ENGINE.partySpecies + slot) or nil
				if sp and sp > 0 then
					ENGINE.flySpecies = sp
				end
				-- ONE LINE PER FLY, and it exists because the first live run reported
				-- `wireFly=nil` while `entry=252` arrived fine: the map-entry byte crossed the
				-- wire and the species did not, which puts the fault in exactly these three
				-- reads. Naming all of them means the next run cannot be ambiguous about which.
				if _G.MESHGHOST_CRYSTAL_FLY_TRACE and ENGINE.flyLoggedAt ~= ENGINE.entryAt then
					ENGINE.flyLoggedAt = ENGINE.entryAt
					logFile(string.format("fly-latch: f=%d curPartyMon addr=%s slot=%s "
						.. "partySpecies addr=%s species=%s -> flySpecies=%s",
						emu.framecount(), tostring(ENGINE.curPartyMon), tostring(slot),
						tostring(ENGINE.partySpecies), tostring(sp),
						tostring(ENGINE.flySpecies)))
				end
			end
			-- AND HOLD THE PAINTED TIER OFF WHILE THE WORLD IS BEING REBUILT. This window was
			-- already the intent -- "do not paint over the fade-in" -- but it was armed only by an
			-- AREA CHANGE, and a warp that lands you on the map you were already on never changes
			-- the area. Same blind spot as the stale menu rectangle earlier today, same cause: an
			-- area change is a proper subset of a map load, and this byte is the map load itself.
			-- Suspected cause of *"a somewhat glitched sprite"* during a same-town fly landing:
			-- the tier paints from resident VRAM tiles, and wUsedSprites is being repopulated
			-- across exactly these frames, so a tile base read mid-rebuild points at art the game
			-- has not finished loading. Re-armed every frame the byte is stamped, so the window
			-- runs 30 frames past the end of the load rather than 30 from its start.
			playerHistory.settle = 30
		end
	end

	if not connected then
		if bridgeFrames < relayDownUntil then
			return -- a core told us the relay is down; give it time rather than spawning another
		end
		sinceRetry = sinceRetry + 1
		if sinceRetry >= RECONNECT_FRAMES then
			sinceRetry = 0
			if coreChild and coreSpawnFrame and coreSpawnFrame.port and not coreSpawnFrame.busy
				and coreStillRunning() then
				-- OUR OWN CHILD IS ALIVE: wait on its port, never sweep past it (Emerald, 2026-09-02:
				-- sweeping is how a second instance attaches to a core the first just started).
				tryPort(coreSpawnFrame.port)
			else
				connect()
			end
			-- Only after a full sweep found nothing to join. A core already running -- started by
			-- hand, by a dev script, or by another copy of the game -- is used as-is, which is
			-- what stops autostart from ever producing a second one.
			if not connected then
				startCore(firstFreePort)
			end
		end
		return
	end

	-- A connection that never got an answer is not a connection worth keeping. Dropping it costs
	-- nothing if it really was an old core (the walk just finds or starts another); staying
	-- attached to a squatter costs the whole session.
	if not ready and helloSentAtFrame and bridgeFrames - helloSentAtFrame > HELLO_ANSWER_FRAMES then
		markPortBusy(currentPort, "never answered our hello, so it is not a core we can use")
		disconnect(nil)
		return
	end

	beginPolicyFrame()

	-- Push the log buffer to disk on a timer rather than per line: once every five seconds costs
	-- one frame's hitch every five seconds instead of one every second, and the file is never more
	-- than that far behind if someone is tailing it.
	if logfile and bridgeFrames % 300 == 0 then
		pcall(function() logfile:flush() end)
	end

	-- A ghost that has to be snapped is a ghost that fell behind the peer it is following; walking
	-- it would have looked like walking. Silent at zero.
	if snaps.runaways > 0 and bridgeFrames - snaps.at >= 60 then
		log(string.format("MeshGhost: repaired %d ghost%s found standing while the engine still "
			.. "thought they were mid-step -- the state that drags a ghost off screen. Cause not "
			.. "yet found; BANDAGES.md.", snaps.runaways, (snaps.runaways == 1) and "" or "s"))
		snaps.runaways, snaps.at = 0, bridgeFrames
	end

	-- How much the spawned tier's sprite had drifted off its tile, and how far the worst one was.
	-- Steady 2px corrections mean the per-step compensation is simply wrong; occasional big ones
	-- mean frames are being lost elsewhere. Silent when nothing drifts.
	if (snaps.drift or 0) > 0 and bridgeFrames - snaps.at >= 60 then
		logFile(string.format("MeshGhost: re-anchored a spawned ghost to its tile %d time%s this "
			.. "second, worst %d px off, last correction %s", snaps.drift,
			(snaps.drift == 1) and "" or "s", snaps.driftPx or 0,
			snaps.driftDir or "?"))
		snaps.drift, snaps.driftPx = 0, 0
	end
	if snaps.n > 0 and bridgeFrames - snaps.at >= 60 then
		log(string.format("MeshGhost: %d ghost snap%s in the last second (a snap is a jump the "
			.. "player can see -- it means a ghost could not walk to where its peer already was)",
			snaps.n, (snaps.n == 1) and "" or "s"))
		snaps.n, snaps.at = 0, bridgeFrames
	end

	-- STEP_LAG: THE THREE-WAY MOVEMENT TRACE -- player, spawned ghost, drawn model, one line, one
	-- frame, whenever any of them moved. Exists for the user's 1:1 double-check (2026-08-25):
	-- *"see if the drawn & spawned ghosts actually match up exactly/identical to the player"*, with
	-- one named suspect -- *"maybe drawn stopping a bit fast whenever pausing/stopping at the end?"*.
	--
	-- Raw values, not verdicts (a boolean cannot be sanity-checked): map-space pixels for all
	-- three, derived for the player and the spawned ghost EXACTLY as the send path derives them
	-- (destination tile minus 16-prog back along the facing), and the drawn tier reported twice --
	-- the model that feeds the paint AND the screen position actually painted last frame, because
	-- what is DRAWN is the evidence and the model is merely what feeds it. Frames where nothing
	-- moved are omitted; the frame number makes stillness exact anyway. Analysis is offline: shift
	-- each ghost series by its best-fit constant lag and diff against the player's, stop shapes
	-- included. Coverage is printed at each summary tick so the trace says what it could not see.
	if stepLag.on then
		local mt = stepLag.mv
		if not mt then
			mt = { last = "" }
			stepLag.mv = mt
		end
		local parts = {}
		local base = OBJECT_STRUCTS
		local function mappx(sb)
			local mx, my = (u8(sb + F_MAP_X) or 0) * 16, (u8(sb + F_MAP_Y) or 0) * 16
			if (u8(sb + F_WALKING) or STANDING) ~= STANDING then
				local back = stepProgress(sb) - 16
				local d = ((u8(sb + F_DIRECTION) or 0) // 4) & 3
				if d == 0 then my = my + back
				elseif d == 1 then my = my - back
				elseif d == 2 then mx = mx - back
				else mx = mx + back end
			end
			return mx, my
		end
		local px, py = mappx(base)
		-- The struct's own screen coords too (engine-maintained): field-derived map px can carry a
		-- one-frame skew at step boundaries that the drawn sprite does not, and the DIFFERENCE
		-- between the ghost's and the player's screen coords is camera-free, so it is the drawn
		-- truth the map-px derivation must be checked against.
		parts[#parts + 1] = string.format("P=%d,%d Ps=%d,%d", px, py,
			u8(base + F_SPRITE_X) or 0, u8(base + F_SPRITE_Y) or 0)
		for id, g in pairs(ghosts) do
			if stillOurs(g) then
				local gx, gy = mappx(g.st_base)
				parts[#parts + 1] = string.format("S[%s]=%d,%d Ss=%d,%d", id, gx, gy,
					u8(g.st_base + F_SPRITE_X) or 0, u8(g.st_base + F_SPRITE_Y) or 0)
			end
		end
		for key, o in pairs(overflow) do
			if o.modelX then
				parts[#parts + 1] = string.format("M[%s]=%d,%d paint=%s,%s", key,
					math.floor(o.modelX), math.floor(o.modelY),
					tostring(o.paintedX), tostring(o.paintedY))
			end
		end
		local line = table.concat(parts, " ")
		if line ~= mt.last then
			mt.last = line
			mt.lines = (mt.lines or 0) + 1
			logFile(string.format("mv f=%d %s", bridgeFrames, line))
		end
	end

	-- STEP_LAG: COMMIT. The frame the player's own object took a tile, recorded before receive() so
	-- the frame is always on the books before anything that could echo it back is read. MAP_X/Y are
	-- written at the START of a step, so a change here is the instant of commitment, not of arrival
	-- -- the same fact stepGhost's step recipe rests on.
	if stepLag.on then
		local ck = (u8(OBJECT_STRUCTS + F_MAP_X) or 0) .. "," .. (u8(OBJECT_STRUCTS + F_MAP_Y) or 0)
		if stepLag.lastCommit ~= ck then
			stepLag.lastCommit = ck
			stepLag.commit[ck] = emu.framecount()
		end
		if stepLag.n > 0 and bridgeFrames - stepLag.at >= 300 then
			local function hist(h)
				local out, keys = {}, {}
				for k in pairs(h) do
					if type(k) == "number" then
						keys[#keys + 1] = k
					end
				end
				table.sort(keys)
				for _, k in ipairs(keys) do
					out[#out + 1] = string.format("%d:%d", k, h[k])
				end
				-- SPREAD FIRST. The mean is the number that gets quoted and the least useful one
				-- here: a lag that is always 6 frames is invisible on screen, and one that wanders
				-- between 2 and 9 is the stutter, at the same mean.
				return string.format("spread %d-%d (%d wide), mean %.2f over %d [%s]",
					h.lo or 0, h.hi or 0, (h.hi or 0) - (h.lo or 0),
					(h.n or 0) > 0 and h.sum / h.n or 0, h.n or 0, table.concat(out, " "))
			end
			-- THE THREE NUMBERS SEPARATELY, and the sample count with each, because a mean over four
			-- steps is not a measurement. `unknown` says how many arrivals had no player frame to
			-- subtract -- if it rivals `n`, the run says nothing and the histograms are noise.
			logFile(string.format("MeshGhost: step lag over %d steps -- wire %s | apply %s | "
				.. "total %s | %d frames blocked mid-step, %d arrivals with no player frame. "
				.. "The engine acts the frame AFTER our write, so what is seen is total + 1.",
				stepLag.n, hist(stepLag.wire), hist(stepLag.apply), hist(stepLag.total),
				stepLag.blocked, stepLag.unknown)
				.. string.format(" %d frames held for STEP_TRIGGER_PROG=%d.",
					stepLag.waits or 0, STEP_TRIGGER_PROG))
			stepLag.wire, stepLag.apply, stepLag.total = {}, {}, {}
			stepLag.n, stepLag.blocked, stepLag.unknown, stepLag.waits = 0, 0, 0, 0
			stepLag.at = bridgeFrames
		end
	end

	receive()
	if not connected then
		return
	end

	-- FORGET A PEER THAT HAS STOPPED SENDING.
	--
	-- Until 2026-08-21 nothing here ever timed a peer out: a ghost lived until an explicit
	-- `despawn_remote` arrived, an area change, or the bridge dropping. A peer who simply goes
	-- quiet -- their game crashed, their machine slept, their client was killed -- was spawned or
	-- painted at their last position forever.
	--
	-- Found the hard way, and the dev rig is what exposed it: every time the core re-registers with
	-- the relay it is issued a NEW player id, so the loopback ghost becomes "p17-ghost" while
	-- "p16-ghost" is still on screen with nobody sending for it. Sixteen reconnections in one
	-- session, and the user's report was exact -- *"a weird 'static' ghost"* that survived
	-- savestates, because it was never in the game's memory at all: it was OUR painted overlay of a
	-- peer that no longer exists. Nothing in the arrays to find, which is why the sweep came back
	-- empty.
	--
	-- Three seconds at 60fps. Long enough that ordinary jitter, a slow frame or a paused emulator
	-- on the other end never trips it; short enough that a dead peer does not stand around.
	if bridgeFrames % 30 == 0 then
		for id, a in pairs(activity) do
			if a.seenAt and policyFrames - a.seenAt > 180 then
				log("MeshGhost: " .. id .. " stopped sending — removing their ghost")
				despawnGhost(id)
				overflow[id] = nil
				overflow[COMPARE.key(id)] = nil
		overflow[COMPARE.hwKey(id)] = nil
				activity[id] = nil
			end
		end
	end

	-- Object state is rebuilt from ROM on every map load, and a battle exit is also a map
	-- re-entry — so a ghost never survives either. Drop our bookkeeping rather than leaving
	-- entries pointing at slots the game has since reused.
	--
	-- FORGET, never despawn: by the time we notice, those bytes belong to the game again, and
	-- writing zeroes into them would delete one of its NPCs.
	--
	-- A BATTLE IS NOT A MAP CHANGE, and treating it as one is a bug in its own right. The first
	-- version of this also cleared the bookkeeping whenever wMapStatus left ENGINE.MAPSTATUS_HANDLE, on
	-- the theory that a battle rebuilds the array the way a map load does. The user watched it:
	-- leaving a wild battle produced TWO ghosts (2026-08-19). The old object had survived the
	-- battle perfectly well — so forgetting it only meant spawning a second one beside it, with
	-- nothing left tracking the first. The area check stays because a map change really does
	-- rebuild the array; everything else is left to stillOurs(), which asks whether the object we
	-- recorded is still the object we made rather than guessing from a lifecycle event.
	local area = areaId()
	-- REFRESH WHILE STABLE. The connection block was only read when the map changed, which put the
	-- whole feature at the mercy of whether that single read landed after the engine finished
	-- writing it. Re-reading it every frame while the map is NOT changing costs ~17 byte reads and
	-- means the set is correct and settled long before it is ever needed -- so a crossing can no
	-- longer inherit one bad read. Deliberately skipped on the changing frame itself, where the
	-- seam test below still needs the departing map's set intact.
	if area == lastArea and ENGINE.xmap.armed() then ENGINE.xmap.build(area) end
	if area ~= lastArea then
		-- The connection block belongs to the map we just arrived on, so it is stale the moment
		-- the map changes. Rebuilt HERE as well as lazily in renderRemote so that the first peer
		-- state to arrive after a crossing is translated against the new map rather than the old
		-- one -- the block and the map bytes were measured changing on the SAME frame (lead 0
		-- across 26 crossings), so there is no window where this reads a half-updated block.
		--
		-- WAS THIS A SEAM OR A WARP? Asked BEFORE the rebuild, because the answer lives in the
		-- DEPARTING map's connection list and the rebuild overwrites it. A seam is a map change
		-- the old map's connections named; everything else is a warp.
		-- Either table may hold the departing map's set, depending on whether a peer state arrived
		-- this frame and rebuilt it first (it usually did -- see ENGINE.xmap.build). Asking both
		-- makes the answer independent of that ordering instead of quietly depending on it.
		local function seamTo(conns, forKey)
			return conns ~= nil and forKey == lastArea and conns[area] ~= nil
		end
		local wasSeam = seamTo(ENGINE.xmap.conns, ENGINE.xmap.connsFor)
			or seamTo(ENGINE.xmap.prevConns, ENGINE.xmap.prevFor)
		-- Stamped so the settle window above can tell a seam from a warp. It is read at a point in
		-- the frame that runs BEFORE this block, so it is deliberately a timestamp with a window
		-- rather than a flag consumed here -- a flag would always be one frame late.
		if wasSeam then ENGINE.xmap.seamAt = policyFrames end
		-- Computed BEFORE the rebuild, like the seam test itself, and for the same reason.
		local rebaseDX, rebaseDY = nil, nil
		if wasSeam then rebaseDX, rebaseDY = ENGINE.xmap.rebaseDelta(lastArea, area) end
		if lastArea and (MESHGHOST_CRYSTAL_XTRACE
			or os.getenv("MESHGHOST_CRYSTAL_XTRACE")) then
			ENGINE.xmap.traceUntil = policyFrames + 150
		end
		if lastArea and ENGINE.xmap.armed() then
			-- ONE LINE PER MAP CHANGE, which is rare enough to be free and is the only thing that
			-- says which branch the teardown below took. The previous version of this fix was
			-- wrong for a whole test round with nothing in the log to show it.
			log(string.format("map change %s -> %s: %s", lastArea, area,
				(wasSeam and rebaseDX)
					and string.format("SEAM (painted tier rebased by %+d,%+d tiles, no fade guard)",
						rebaseDX, rebaseDY)
					or (wasSeam and "SEAM but NO REBASE DELTA -- clearing (this should not happen)")
					or "WARP (full teardown)"))
		end
		if ENGINE.xmap.armed() then ENGINE.xmap.build(area) end
		if lastArea then
			-- A SEAM CROSSING IS NOT A WARP, and the teardown below was written when every map
			-- change was one. Both of these were safe exactly because nobody could survive a map
			-- change: a peer on the map you left was hidden the moment you left it. Cross-map
			-- ghosts break that premise -- the peer across the seam is visible before AND after --
			-- so the blanket teardown now removes a ghost that should never have gone anywhere,
			-- and it comes back a frame later. The user, 2026-08-27: *"whenever you cross over to
			-- a different route, their ghosts flickers a bit for you"*, and pointedly NOT for the
			-- person watching them arrive -- which is the tell, because only the crosser runs this
			-- block.
			--
			--   * the fade guard: a WARP fades the screen and painting over it is the bug this
			--     exists for. Walking across a connection does not fade at all, so 30 frames of
			--     held paint there is half a second of missing ghost and nothing gained.
			--   * the painted tier: its positions are recomputed every frame against the anchor,
			--     so a stale entry is corrected on the next paint rather than being wrong. Keeping
			--     it across a seam is the difference between one corrected frame and a gap.
			--
			-- The SPAWNED tier is dropped either way and that is not negotiable: the engine really
			-- does rebuild its object array on any map load, seam included, so every object we
			-- recorded belongs to the old map's array and `stillOurs()` would be asking about a
			-- slot that has already been handed to somebody else.
			if not wasSeam then
				playerHistory.settle = 30 -- a warp fades: do not paint over the fade-in
			end
			for id in pairs(ghosts) do
				ghosts[id] = nil
			end
			-- The drawn tier has no slots to forget, but it does have positions, and they were
			-- computed against the OLD map's camera. Clear them on a warp: a peer still on this
			-- map re-registers on its next state, which is at most a frame away.
			-- REBASED, not kept and not cleared. `wasSeam` alone is not enough to keep these: they
			-- are written in the frame of the map being left, and the crossing retires it. See
			-- ENGINE.xmap.rebaseDelta for why both of the simpler options were watched failing.
			if wasSeam and rebaseDX then
				for _, o in pairs(overflow) do
					ENGINE.xmap.rebaseEntry(o, rebaseDX, rebaseDY)
				end
				-- AND THE CAMERA CALIBRATION MOVES THE OPPOSITE WAY, or the rebase un-draws every
				-- peer for as long as the player keeps walking. The paint is `model + camA + K`:
				-- the rebase above shifts every model by the tile delta, so the sum jumps by the
				-- same amount unless K absorbs it -- the identical algebra to the camera-register
				-- rebase absorber (its comment: "a rebase absorbed into camA is cancelled only by
				-- the OPPOSITE change in K"). K's own big-jump recalibration cannot save this: it
				-- only runs after the camera has been STILL for 8 frames, and the player crossing
				-- a seam is walking by definition. Measured 2026-08-27, per-frame counters: off=1
				-- on every frame of every visit to the far map, drawing resuming the instant the
				-- player crossed back -- and the painted position during the gap was exactly the
				-- correct one plus the rebase (80,76 vs 400,-212 with a +320,-288 rebase). The
				-- user: the ghost "pops in/out", and only for "the 1st instance, that actually
				-- goes across" -- only the crosser runs this block.
				if facingFrames.camKX then
					facingFrames.camKX = facingFrames.camKX - rebaseDX * 16
					facingFrames.camKY = facingFrames.camKY - rebaseDY * 16
				end
			else
				overflow = {}
			end
			anchorIndex = nil -- the object array is rebuilt; last map's anchor means nothing
			-- A MENU CANNOT SURVIVE A MAP LOAD, so a menu rectangle still set here is stale by
			-- definition and must not go on hiding painted peers.
			--
			-- `wMenuBorderTopCoord`..`RightCoord` ($cf82-$cf85) are non-zero for exactly as long as
			-- a menu is open and are zeroed when one closes -- measured 2026-08-26 by driving a
			-- START menu open and shut (`probes/menu_state_table.lua`), which is why the level test
			-- in drawOverflow is correct and stays. The exception is a menu torn down by a WARP
			-- rather than closed: Fly is exactly that, so it left `0,10,15,19` -- the entire right
			-- half of the screen -- set permanently, `uiPanelOpen()` re-latched on it every frame,
			-- and every painted peer standing in that half was hidden for the rest of the session.
			-- The user, 2026-08-26: *"goes invisible when despawned afterwards if flying to the same
			-- town"*. Flying to a DIFFERENT town looked fine only because that reloads the map and
			-- respawns the peer into the engine tier, which this rectangle never applied to.
			--
			-- Cleared HERE rather than by a smarter test in drawOverflow because two such tests were
			-- tried and both were killed by measurement the same day (UNVERIFIED.md has the table):
			-- the panel's own frame tiles survive the menu closing, and LCDC/WY/WX are byte-identical
			-- with a menu open and shut. "The world was just rebuilt" is a fact this file already
			-- computes and already trusts for four other pieces of bookkeeping in this very block.
			uiSeenAt, lastMenuBox = nil, nil
			-- STEP_LAG's tile ring is per-map: tile numbers repeat across maps, so a stale entry
			-- would silently answer for a tile the player never took on THIS map.
			stepLag.commit, stepLag.seen, stepLag.open, stepLag.lastCommit = {}, {}, {}, nil

			-- The player's own history is stale for the same reason, and the tier must not measure
			-- against it. NOT cleared -- counted. See the readiness gate in drawOverflow for why
			-- clearing is the wrong instrument here: an empty ring makes the aged lookup fall
			-- through to this frame's own sample, which is a wrong reference rather than a missing
			-- one, and that shipped as a wiggle for one afternoon.
			playerHistory.since = 0
		end
		lastArea = area
	end

	-- XTRACE -- a BOUNDED per-frame tier trace around a map change, off unless asked for.
	--
	-- The question it exists to answer, and which no other instrument here can: across a seam
	-- crossing, is there a frame on which NEITHER tier holds the peer? That frame is the flicker.
	-- The per-second `holding:` line cannot see it (a gap of a few frames never survives a
	-- one-second sample), and the spawn/despawn lines cannot either -- they say what changed, not
	-- whether anything was on screen in between.
	--
	-- Armed for 40 frames by the map change above, so it costs nothing while walking and cannot
	-- run away: a per-frame log line is a per-frame stall (adapters/emulator/CLAUDE.md).
	if ENGINE.xmap.traceUntil and policyFrames <= ENGINE.xmap.traceUntil then
		local sp, pa = {}, {}
		for gid in pairs(ghosts) do sp[#sp + 1] = gid end
		for oid in pairs(overflow) do pa[#pa + 1] = oid end
		table.sort(sp)
		table.sort(pa)
		-- The stop reason may be one frame old (drawOverflow runs at its own point in the frame);
		-- that is fine for attribution and is stated so nobody reads it as exact.
		local why = (facingFrames.stopLastAt and policyFrames - facingFrames.stopLastAt <= 1)
			and facingFrames.stopLast or nil
		logFile(string.format("XTRACE f=%d area=%s spawned{%s} painted{%s}%s%s%s", policyFrames, area,
			table.concat(sp, ","), table.concat(pa, ","),
			why and ("  NOT-DRAWN:" .. why) or "",
			facingFrames.dbgCounts and ("  [" .. facingFrames.dbgCounts .. "]") or "",
			(#sp == 0 and #pa == 0) and "   <-- NEITHER TIER: this frame draws no peer at all" or ""))
		facingFrames.dbgCounts = nil
	end

	if ready then
		local state = getLocalState()
		diagnose(state)
		send({ type = "local_state", payload = { state = state } })
	end

	drawOverflow()
end

event.onexit(function()
	pcall(function()
		for id in pairs(ghosts) do
			despawnGhost(id)
		end
		if sock then
			sock:close()
		end
	end)
end)

-- Dev affordance, and the only one in this file: when loaded by dev-scripts/bizhawk-dev-loader.lua
-- (a development tool, never shipped), hand it the per-frame function instead of taking the frame
-- loop. Emerald's adapter has done this since 2026-08-18; Crystal's did not, so under the loader
-- it seized the loop, the loader never polled its control file again, and no probe, savestate or
-- screenshot script could run beside it -- the adapter looked fine while the tool around it was
-- dead. A player opening this file in the Lua Console sets neither global and gets the normal
-- loop below, unchanged.
MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function()
	-- The same three things Emerald's unload lists, for the same reasons: a leaked bridge socket
	-- makes the next load bounce off "busy: this core already has a game attached"; ghosts are
	-- real objects in the game that nothing else will clear; and the log file is an OS handle that
	-- stays locked on disk. disconnect() covers the first two -- it despawns every ghost.
	pcall(disconnect, nil)
	if logfile then
		pcall(function() logfile:close() end)
		logfile = nil
	end
end

if not MESHGHOST_DEV_LOADER then
	-- tick() under pcall, as Emerald's guardedFrame does: an error costs the rest of
	-- that frame, not the script. Bare, one bad field from one peer -- or one bug --
	-- killed the whole adapter until BizHawk was restarted. Logged once per distinct
	-- message so a per-frame error cannot flood the log. 2026-09-02.
	local lastTickError = nil
	while true do
		local ok, err = pcall(tick)
		if not ok and tostring(err) ~= lastTickError then
			lastTickError = tostring(err)
			log("MeshGhost: frame error (script continues): " .. lastTickError)
		end
		emu.frameadvance()
	end
end
