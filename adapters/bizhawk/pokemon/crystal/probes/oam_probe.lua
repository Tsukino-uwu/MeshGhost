-- MeshGhost — Pokémon Crystal: is there room in the HARDWARE sprite list for a peer?
--
-- ============================================================================================
-- THIS PROBE WRITES GAME RAM. Read this paragraph before running it.
--
-- It writes FOUR OAM entries and nothing else: entries 36..39 of the game's shadow-OAM buffer
-- (wShadowOAM, 00:c400, ram/wram.asm:303) and/or of the hardware OAM the DMA copies it into. It
-- writes them ONLY on a frame where the engine's own layout pass has declared them unused --
-- hUsedSpriteIndex (00:ffbd) <= 144 -- and only while the map state machine says the world is
-- real (wMapStatus == MAPSTATUS_HANDLE, wBattleMode == 0, sprite updates enabled). On any frame
-- where the engine wants those entries the write is DECLINED and counted, because a run that
-- cannot find a free tail is itself the answer to the capacity question.
--
-- It restores what it touched by writing y = OAM_YCOORD_HIDDEN (160), which is the engine's own
-- value for "this entry is not in use" (constants/gfx_constants.asm:36, and the fill loop at
-- engine/overworld/map_objects.asm:2746). It never touches an object struct, a map object, a
-- save, or the ROM. A reset or a map load rebuilds everything it could possibly have disturbed.
--
-- Worst case if something goes wrong: up to four stray 8x8 sprites, two tiles to the right of
-- your character, until the next map load. Nothing in the save can be affected.
-- ============================================================================================
--
-- WHY THIS EXISTS
-- The adapter has two rendering tiers -- SPAWNED (a real map object plus an object struct, the
-- engine draws and animates it) and DRAWN (painted over the emulator's finished frame with gui.*,
-- which costs us hand-rolled animation and hand-rolled occlusion; BANDAGES.md entry 1). Emerald
-- gained a middle rung on 2026-08-21 by writing raw entries into the part of its OAM buffer the
-- engine's per-frame path never touches (architecture.md, "Extra hardware sprites come from OAM
-- injection above gOamLimit"). The question here is whether Crystal has the same seam.
--
-- Read from the decomp first, so this probe only has to settle what reading cannot:
--
--   * The overworld REBUILDS the whole buffer every frame. _UpdateSprites (map_objects.asm:2730)
--     zeroes hUsedSpriteIndex, calls InitSprites (:2812) which appends four entries per visible
--     character in priority order, then `.fill` (:2746) writes y=160 into every remaining entry
--     up to the end of the buffer. So an appended entry's Y IS STOMPED EVERY FRAME. There is no
--     Crystal equivalent of Emerald's gOamLimit: the fill runs to entry 39.
--     (The one exception is a mobile-adapter flag, LAST_12_SPRITE_OAM_STRUCTS_RESERVED_F, which
--     stops the fill at entry 27 -- but it does NOT stop InitSprites from allocating past 27, so
--     it reserves nothing against a crowd. constants/ram_constants.asm:107.)
--   * The rebuild happens in HandleMapBackground (engine/overworld/events.asm:209), and the
--     buffer reaches the hardware in VBlank via hTransferShadowOAM (home/vblank.asm:112,
--     engine/gfx/load_push_oam.asm), unless hOAMUpdate (00:ffd8) is non-zero.
--
-- What NONE of that can tell you is the only thing that decides whether the tier is buildable:
-- WHERE IN THAT SEQUENCE DOES A LUA FRAME BOUNDARY LAND? If our write happens after `.fill` and
-- before the DMA, an entry re-written every frame is displayed. If it happens before `.fill`, it
-- is erased before anyone sees it. Nothing in the decomp knows about BizHawk, so this is a
-- measurement, not a lookup.
--
-- WHAT IT MEASURES, in order
--   1. How many of the 40 entries the game actually uses, frame by frame, as a RANGE -- and the
--      worst per-scanline count, because the Game Boy drops sprites past 10 on a line and a
--      single sample cannot see a 2%-of-frames effect (probes.md, "One sample cannot see a
--      blinking thing").
--   2. Whether the tail is really cleared, by watching entry 36's Y with nobody writing it.
--   3. Whether a test entry written into the tail SURVIVES to the hardware. The evidence is a
--      read of the hardware OAM domain -- the buffer the PPU draws from, which the game's own
--      DMA fills -- never a read of the value we just wrote (CLAUDE.md).
--   4. The same, writing straight into hardware OAM instead of the shadow buffer.
--   5. What happens to an entry while a TEXT BOX is open, and while the START menu is open. This
--      is the one the whole idea rests on: documentation.md says the game's UI covers characters
--      by itself, but the confirmation behind that line was the START MENU, whose mechanism is
--      ClearSprites (home/clear_sprites.asm:1) wiping the buffer -- not hardware priority. A text
--      box is background tiles at palette 7 with NO priority attribute (home/text.asm:100,
--      TextboxPalette), and an overworld character's OAM attribute carries the priority bit only
--      when it is under tiles or in grass (map_objects.asm:2894). So the expectation from reading
--      is that a hardware sprite is NOT hidden by a text box -- and that expectation needs a
--      human's eyes, which is why this phase asks a question rather than answering one.
--
-- HOW TO RUN
--   Vanilla V1.0 only. The addresses below are this ROM's; an Archipelago build moves them and
--   this probe would write somewhere plausible instead of somewhere known.
--   Point dev-scripts/bizhawk-dev-loader.target at it, or Lua Console -> Script -> Open.
--   Stand in the overworld first. Every phase is a fixed length with a spoken countdown; there is
--   no moment to hit and nothing to time. Sloppy play costs a little data, never the run.
--   Log: oam_probe_<timestamp>.log beside this file.

local DOMAIN = "WRAM"      -- bank 1 laid flat, the domain the adapter uses (domain_probe.lua)
local OAM_DOMAIN = "OAM"   -- the hardware's own copy, offered by this core (domain_probe.lua)
local BUS = "System Bus"   -- for HRAM, which the flat WRAM domain does not cover

-- WRAM bank 1 laid flat: bank 0 is 0xC000-0xCFFF, bank 1 is 0xD000-0xDFFF.
local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- Every address below comes from our own hash-verified pokecrystal build's pokecrystal.sym.
local SHADOW_OAM = flat(0xC400)   -- wShadowOAM .. wShadowOAMEnd (0xC4A0), 40 entries of 4 bytes
local W_STATEFLAGS = flat(0xD0ED) -- wStateFlags
local W_MAPSTATUS = flat(0xD432)  -- wMapStatus
local W_BATTLEMODE = flat(0xD22D) -- wBattleMode
local H_USEDSPRITEINDEX = 0xFFBD  -- hUsedSpriteIndex, in bytes not entries
local H_OAMUPDATE = 0xFFD8        -- hOAMUpdate; non-zero suppresses the VBlank OAM DMA

local OAM_COUNT = 40
local OBJ_SIZE = 4
local OAM_SIZE = OAM_COUNT * OBJ_SIZE
local OAM_YCOORD_HIDDEN = 160     -- constants/gfx_constants.asm:36
local MAPSTATUS_HANDLE = 2
-- constants/ram_constants.asm:106 -- the name is the decomp's and it reads backwards: the bit
-- being SET means sprite updates are ENABLED (home/sprite_updates.asm:11).
local SPRITE_UPDATES_ENABLED_BIT = 0x01
local TEXT_STATE_BIT = 0x40       -- TEXT_STATE_F, bit 6 of wStateFlags

-- The four entries this probe is allowed to touch, and the used-byte-count above which it must
-- not. 36 * 4 = 144: if the engine has already laid out 144 bytes, entry 36 is its business.
local TEST_FIRST_ENTRY = 36
local TEST_LAST_ENTRY = 39
local TEST_MAX_USED = TEST_FIRST_ENTRY * OBJ_SIZE

-- Two tiles to the right of whatever we copy, so the test sprite never sits on the player and a
-- comparison is possible at a glance (a standing rule for every test ghost in this project).
local TEST_DX = 16

local function scriptDir()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end

local logfile = io.open(string.format("%s/oam_probe_%s.log", scriptDir(),
	os.date("%Y%m%d_%H%M%S")), "w")
-- Buffered, never flushed per line: a flush is a synchronous disk write on the emulator's own
-- thread, measured at 63-83ms -- four to five frames, every time (pitfalls.md, "ONE console line a
-- second cost 7.4 fps"). A probe that stalls the game changes what it measures, and this one
-- measures the sprite pipeline.
if logfile then
	pcall(function() logfile:setvbuf("full", 8192) end)
end
local function log(m)
	console.log(m)
	if logfile then
		logfile:write(m, "\n")
	end
end

local function u8(addr, domain)
	local ok, v = pcall(memory.read_u8, addr, domain)
	if ok and type(v) == "number" then
		return v
	end
	return nil
end

local function w8(addr, value, domain)
	pcall(memory.write_u8, addr, value & 0xFF, domain)
end

-- Ask the host what it has rather than trusting that a bulk read exists (probes.md). One
-- boundary crossing instead of 160 is worth having, but only if this build implements it.
local bulk = nil
do
	local ok, res = pcall(function()
		return memory.read_bytes_as_array(SHADOW_OAM, 4, DOMAIN)
	end)
	if ok and type(res) == "table" and (res[1] ~= nil or res[0] ~= nil) then
		bulk = true
	end
end

-- Returns a 0-based Lua table of OAM_SIZE bytes, whichever way this build allows.
local function readOAM(base, domain)
	local out = {}
	if bulk then
		local ok, res = pcall(memory.read_bytes_as_array, base, OAM_SIZE, domain)
		if ok and type(res) == "table" then
			-- BizHawk has returned both 0-based and 1-based arrays across builds; normalise by
			-- reading whichever index is populated rather than assuming one.
			local zeroBased = (res[0] ~= nil)
			for i = 0, OAM_SIZE - 1 do
				out[i] = res[zeroBased and i or (i + 1)] or 0
			end
			return out
		end
		bulk = false -- it answered once and then did not; stop paying for it
	end
	for i = 0, OAM_SIZE - 1 do
		out[i] = u8(base + i, domain) or 0
	end
	return out
end

-- An entry is "in use" if its Y is inside the visible band. The engine parks unused entries at
-- 160 and ClearSprites zeroes them, so both 0 and 160 mean absent -- and telling those two apart
-- is itself informative, so they are counted separately.
local function census(buf)
	local live, parked, zeroed = 0, 0, 0
	local perLine = {}
	local worstLine, worstCount = -1, 0
	for e = 0, OAM_COUNT - 1 do
		local y = buf[e * OBJ_SIZE] or 0
		if y == 0 then
			zeroed = zeroed + 1
		elseif y == OAM_YCOORD_HIDDEN then
			parked = parked + 1
		else
			live = live + 1
			-- Hardware Y is screen line + 16, and Crystal's overworld sprites are 8x8 (every
			-- Facings entry is four 8x8 quarters -- data/sprites/facings.asm:43).
			local top = y - 16
			for line = top, top + 7 do
				if line >= 0 and line < 144 then
					local n = (perLine[line] or 0) + 1
					perLine[line] = n
					if n > worstCount then
						worstCount, worstLine = n, line
					end
				end
			end
		end
	end
	return live, parked, zeroed, worstCount, worstLine
end

local function entryStr(buf, e)
	local b = e * OBJ_SIZE
	return string.format("y=%3d x=%3d tile=%02X attr=%02X",
		buf[b] or 0, buf[b + 1] or 0, buf[b + 2] or 0, buf[b + 3] or 0)
end

-- ---------------------------------------------------------------------------------------------
-- Running state
-- ---------------------------------------------------------------------------------------------

local frames = 0
local done = false
local touched = false          -- have we ever written a test entry (decides the restore)
local wroteHardware = false

local range = {}
local function note(key, value)
	if value == nil then return end
	local r = range[key]
	if r == nil then
		range[key] = { min = value, max = value }
	else
		if value < r.min then r.min = value end
		if value > r.max then r.max = value end
	end
end
local function rangeStr(key)
	local r = range[key]
	if r == nil then return "(never read)" end
	if r.min == r.max then return tostring(r.min) end
	return string.format("%d..%d", r.min, r.max)
end
local function clearRanges()
	range = {}
end

local counters = {}
local function bump(key)
	counters[key] = (counters[key] or 0) + 1
end

-- ---------------------------------------------------------------------------------------------
-- Writing a test entry
-- ---------------------------------------------------------------------------------------------

-- The template is whatever the engine laid out first this frame -- entries 0..3, which the
-- adapter already treats as the local player's four sprites. Copying a live entry means real
-- tiles, a real palette and a real VRAM bank, none of which this probe has to understand.
local function writeTest(shadow, domain, base)
	local dst = TEST_FIRST_ENTRY * OBJ_SIZE
	for q = 0, 3 do
		local src = q * OBJ_SIZE
		local y = shadow[src] or OAM_YCOORD_HIDDEN
		local x = ((shadow[src + 1] or 0) + TEST_DX) & 0xFF
		w8(base + dst + q * OBJ_SIZE + 0, y, domain)
		w8(base + dst + q * OBJ_SIZE + 1, x, domain)
		w8(base + dst + q * OBJ_SIZE + 2, shadow[src + 2] or 0, domain)
		w8(base + dst + q * OBJ_SIZE + 3, shadow[src + 3] or 0, domain)
	end
	touched = true
end

local function restore()
	if not touched then return end
	for e = TEST_FIRST_ENTRY, TEST_LAST_ENTRY do
		w8(SHADOW_OAM + e * OBJ_SIZE, OAM_YCOORD_HIDDEN, DOMAIN)
		w8(e * OBJ_SIZE, OAM_YCOORD_HIDDEN, OAM_DOMAIN)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Phases. Fixed lengths, spoken countdowns, nothing to time.
-- ---------------------------------------------------------------------------------------------

local PHASES = {
	{ name = "settle", frames = 300, ask =
		"Stand in the overworld and do nothing. Reading only." },
	{ name = "census", frames = 900, ask =
		"WALK AROUND normally for 15 seconds. Counting the entries the game itself uses." },
	{ name = "tailwatch", frames = 300, ask =
		"Stand still. Watching entry 36 with NOBODY writing it -- is the tail really cleared?" },
	{ name = "single", frames = 600, ask =
		"Stand still. Writing one test entry every 2 seconds and reading the hardware back." },
	{ name = "persist-shadow", frames = 600, ask =
		"Stand still, then take a few steps. A test character may appear TWO TILES TO YOUR " ..
		"RIGHT -- watch whether it is there at all, and whether it flickers." },
	{ name = "persist-hardware", frames = 600, ask =
		"Same again, but written straight into hardware OAM instead of the shadow buffer." },
	{ name = "textbox", frames = 1200, ask =
		"OPEN A TEXT BOX and leave it open -- talk to anything, read a sign. THE QUESTION IS " ..
		"WHETHER THE TEST CHARACTER IS DRAWN OVER THE TEXT BOX OR HIDDEN BEHIND IT." },
	{ name = "startmenu", frames = 900, ask =
		"Open the START menu and leave it open. Does the test character vanish with the rest?" },
	{ name = "restore", frames = 120, ask =
		"Putting the four entries back. Nothing to do." },
}

local phaseIndex = 1
local phaseFrame = 0

-- Per-phase carried state
local prevTailY = nil
local prevSig = nil
local pendingReadback = 0

local function phase()
	return PHASES[phaseIndex]
end

local function announce()
	local p = phase()
	log("")
	log(string.format("=== PHASE %d/%d: %s -- %d frames (%ds) ===",
		phaseIndex, #PHASES, p.name, p.frames, p.frames // 60))
	log("    " .. p.ask)
	clearRanges()
	counters = {}
	prevTailY = nil
	prevSig = nil
	pendingReadback = 0
end

local function endPhase()
	local p = phase()
	log(string.format("--- %s done: used=%s live=%s parked=%s zeroed=%s maxPerLine=%s " ..
		"hOAMUpdate=%s shadow~=hw bytes=%s",
		p.name, rangeStr("used"), rangeStr("live"), rangeStr("parked"), rangeStr("zeroed"),
		rangeStr("maxPerLine"), rangeStr("oamupdate"), rangeStr("diff")))
	local extra = {}
	for k, v in pairs(counters) do
		extra[#extra + 1] = string.format("%s=%d", k, v)
	end
	table.sort(extra)
	if #extra > 0 then
		log("    " .. table.concat(extra, "  "))
	end
end

-- ---------------------------------------------------------------------------------------------

local function tick()
	if done then return end
	frames = frames + 1
	phaseFrame = phaseFrame + 1
	local p = phase()

	local used = u8(H_USEDSPRITEINDEX, BUS)
	local oamUpdate = u8(H_OAMUPDATE, BUS)
	local stateFlags = u8(W_STATEFLAGS, DOMAIN) or 0
	local mapStatus = u8(W_MAPSTATUS, DOMAIN)
	local battleMode = u8(W_BATTLEMODE, DOMAIN)
	local spritesEnabled = (stateFlags & SPRITE_UPDATES_ENABLED_BIT) ~= 0
	local textState = (stateFlags & TEXT_STATE_BIT) ~= 0

	note("used", used)
	note("oamupdate", oamUpdate)

	local shadow = readOAM(SHADOW_OAM, DOMAIN)
	local hw = readOAM(0, OAM_DOMAIN)

	local live, parked, zeroed, worstCount, worstLine = census(shadow)
	note("live", live)
	note("parked", parked)
	note("zeroed", zeroed)
	note("maxPerLine", worstCount)
	if worstCount > 10 then
		bump("frames_over_10_per_scanline")
	end

	-- How far apart are the two buffers at the instant Lua gets the frame? This is the whole
	-- timing question in one number: 0 means the DMA has already carried this frame's layout to
	-- the hardware before we were woken, which puts our write AFTER the rebuild and BEFORE the
	-- next DMA -- the window a tier would need.
	local diff = 0
	for i = 0, OAM_SIZE - 1 do
		if shadow[i] ~= hw[i] then
			diff = diff + 1
		end
	end
	note("diff", diff)

	local inPlay = (mapStatus == MAPSTATUS_HANDLE) and (battleMode == 0)
	local tailFree = (used ~= nil) and (used <= TEST_MAX_USED)

	-- ----- phase behaviour ---------------------------------------------------------------

	if p.name == "settle" then
		if phaseFrame == 1 then
			log(string.format("    hUsedSpriteIndex=%s (%s bytes = %s entries), hOAMUpdate=%s",
				tostring(used), tostring(used), used and (used // OBJ_SIZE) or "?",
				tostring(oamUpdate)))
			log(string.format("    wStateFlags=%02X (sprite updates %s, text state %s)",
				stateFlags, spritesEnabled and "ENABLED" or "disabled",
				textState and "SET" or "clear"))
			log(string.format("    entry 0 (the engine's own first sprite): %s",
				entryStr(shadow, 0)))
			log(string.format("    entry %d before anyone touches it: %s",
				TEST_FIRST_ENTRY, entryStr(shadow, TEST_FIRST_ENTRY)))
		end

	elseif p.name == "tailwatch" then
		-- Nobody writes here. If the Y of entry 36 sits at 160 forever, the tail clear from
		-- map_objects.asm:2746 is doing exactly what the source says.
		local y = shadow[TEST_FIRST_ENTRY * OBJ_SIZE]
		if y ~= prevTailY then
			log(string.format("  f=%-7d entry %d Y %s -> %s (used=%s)",
				frames, TEST_FIRST_ENTRY, tostring(prevTailY), tostring(y), tostring(used)))
			prevTailY = y
		end
		if y == OAM_YCOORD_HIDDEN then bump("tail_parked_at_160")
		elseif y == 0 then bump("tail_zeroed")
		else bump("tail_something_else") end

	elseif p.name == "single" then
		if pendingReadback > 0 then
			-- The read-back that counts: the HARDWARE buffer, filled by the game's own DMA.
			-- Reading the shadow bytes back would only prove that write_u8 works.
			local sy = shadow[TEST_FIRST_ENTRY * OBJ_SIZE]
			local hy = hw[TEST_FIRST_ENTRY * OBJ_SIZE]
			log(string.format("  f=%-7d +%d frame(s): shadow entry %d %s | hardware entry %d %s",
				frames, 4 - pendingReadback, TEST_FIRST_ENTRY, entryStr(shadow, TEST_FIRST_ENTRY),
				TEST_FIRST_ENTRY, entryStr(hw, TEST_FIRST_ENTRY)))
			if hy ~= nil and hy ~= OAM_YCOORD_HIDDEN and hy ~= 0 then
				bump("hardware_showed_a_test_entry")
			end
			if sy == OAM_YCOORD_HIDDEN then
				bump("shadow_reparked_by_the_engine")
			end
			pendingReadback = pendingReadback - 1
		elseif phaseFrame % 120 == 1 then
			if inPlay and spritesEnabled and tailFree then
				log(string.format("  f=%-7d issuing a test entry into %d..%d, copied from " ..
					"entries 0..3 (%s) shifted +%dpx",
					frames, TEST_FIRST_ENTRY, TEST_LAST_ENTRY, entryStr(shadow, 0), TEST_DX))
				writeTest(shadow, DOMAIN, SHADOW_OAM)
				pendingReadback = 3
				bump("writes_issued")
			else
				bump("writes_declined")
			end
		end

	elseif p.name == "persist-shadow" then
		local hy = hw[TEST_FIRST_ENTRY * OBJ_SIZE]
		if hy ~= nil and hy ~= OAM_YCOORD_HIDDEN and hy ~= 0 then
			bump("frames_visible_in_hardware")
		end
		if inPlay and spritesEnabled and tailFree then
			writeTest(shadow, DOMAIN, SHADOW_OAM)
			bump("writes_issued")
		else
			bump("writes_declined")
		end

	elseif p.name == "persist-hardware" then
		-- Straight into the buffer the PPU reads, bypassing the shadow copy. The game's own DMA
		-- overwrites this every VBlank, so it only works at all if the Lua boundary sits after
		-- the DMA and before the PPU draws -- which is exactly the unknown.
		local hy = hw[TEST_FIRST_ENTRY * OBJ_SIZE]
		if hy ~= nil and hy ~= OAM_YCOORD_HIDDEN and hy ~= 0 then
			bump("frames_visible_in_hardware")
		end
		if inPlay and spritesEnabled and tailFree then
			writeTest(shadow, OAM_DOMAIN, 0)
			wroteHardware = true
			bump("writes_issued")
		else
			bump("writes_declined")
		end

	elseif p.name == "textbox" or p.name == "startmenu" then
		-- Keep the test entry alive in BOTH buffers, so whichever of the two phases above
		-- worked is still on screen for the user to judge.
		if inPlay and tailFree and spritesEnabled then
			writeTest(shadow, DOMAIN, SHADOW_OAM)
			bump("writes_issued")
		else
			bump("writes_declined")
			if not spritesEnabled then bump("declined_sprite_updates_off") end
			if not tailFree then bump("declined_engine_using_the_tail") end
		end
		if wroteHardware and inPlay and tailFree then
			writeTest(shadow, OAM_DOMAIN, 0)
		end
		local sig = string.format("%s|%s|%s|%s|%s",
			tostring(used), tostring(oamUpdate), spritesEnabled and 1 or 0,
			textState and 1 or 0, live)
		if sig ~= prevSig then
			log(string.format("  f=%-7d used=%s hOAMUpdate=%s spriteUpdates=%s textState=%s " ..
				"live=%d  hw entry %d: %s",
				frames, tostring(used), tostring(oamUpdate),
				spritesEnabled and "on" or "OFF", textState and "SET" or "clear", live,
				TEST_FIRST_ENTRY, entryStr(hw, TEST_FIRST_ENTRY)))
			prevSig = sig
		end

	elseif p.name == "restore" then
		if phaseFrame == 1 then
			restore()
			log(string.format("  entries %d..%d parked at y=%d, the engine's own idle value.",
				TEST_FIRST_ENTRY, TEST_LAST_ENTRY, OAM_YCOORD_HIDDEN))
		end
	end

	-- Countdown, once a second, so the player always knows where they are.
	if phaseFrame % 60 == 0 then
		local left = (p.frames - phaseFrame) // 60
		if left > 0 then
			log(string.format("  [%s] %ds left   used=%s live=%s maxPerLine=%s",
				p.name, left, tostring(used), tostring(live), tostring(worstCount)))
		end
	end

	if phaseFrame >= p.frames then
		endPhase()
		phaseIndex = phaseIndex + 1
		phaseFrame = 0
		if phaseIndex > #PHASES then
			restore()
			log("")
			log("=== DONE. What to write down ===")
			log("  * Entries the game itself uses, and the worst per-scanline count.")
			log("  * Whether the tail is cleared with nobody writing it (phase tailwatch).")
			log("  * Whether a written entry ever appeared in the HARDWARE buffer, and for how")
			log("    many frames -- 'frames_visible_in_hardware' in the persist phases.")
			log("  * shadow~=hw byte count: 0 means the DMA runs before Lua sees the frame.")
			log("  * THE USER'S ANSWER, which no counter here can supply: was the test character")
			log("    drawn OVER the text box, or hidden behind it?")
			done = true
			phaseIndex = #PHASES -- park on the last phase; nothing writes again
			return
		end
		announce()
	end
end

log("=== MeshGhost Crystal OAM probe ===")
log("WRITES GAME RAM: four OAM entries (36..39), only when the engine says they are unused,")
log("restored to y=160 at the end. No object struct, no map object, no save, no ROM.")
log(string.format("Bulk memory reads: %s", bulk and "available" or
	"NOT available on this build -- falling back to one call per byte"))
do
	-- Ask the host what it has rather than assuming a domain exists; the OAM domain in
	-- particular is the whole second half of this probe (domain_probe.lua listed it in 2026-08-18,
	-- and a dated fact is not a permanent guarantee).
	local ok, list = pcall(memory.getmemorydomainlist)
	local names = {}
	if ok and type(list) == "table" then
		for _, n in ipairs(list) do names[#names + 1] = tostring(n) end
	end
	log(string.format("Domains offered: %s",
		(#names > 0) and table.concat(names, ", ") or "(could not be listed)"))
end
log("Nine phases, all fixed-length with a countdown. Nothing to time.")
announce()

MESHGHOST_DEV_TICK = function()
	tick()
end

MESHGHOST_DEV_UNLOAD = function()
	restore()
	log("unloaded; test entries restored.")
	if logfile then
		pcall(function() logfile:flush() end)
		logfile:close()
		logfile = nil
	end
end

-- Standalone: a registered callback outlives its script under BizHawk, so this is a loop rather
-- than event.onframeend (pitfalls.md, and every probe in this folder since 2026-08-17).
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
