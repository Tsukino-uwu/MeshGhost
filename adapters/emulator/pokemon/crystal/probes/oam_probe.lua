-- Pokémon Crystal: is there room in the hardware sprite list for a peer, and does an entry written at the Lua frame
-- boundary reach the hardware? Vanilla V1.0 only; stand in the overworld, and each phase is fixed-length and prompted.
-- Writes four OAM entries, 36..39 of wShadowOAM and/or hardware OAM, only on frames where hUsedSpriteIndex <= 144
-- (the engine left them unused) and the world is real, and parks them at y = 160 when done. It never touches an
-- object struct, a map object, a save or the ROM; the worst case is four stray 8x8 sprites until the next map load.
-- It measures the entries in use and the worst per-scanline count, whether the tail stays cleared, whether a written
-- entry survives to the hardware (read from the OAM domain, never our own write), and what a text box and the START
-- menu do to one.

local DOMAIN = "WRAM"      -- bank 1 laid flat, as the adapter reads it
local OAM_DOMAIN = "OAM"   -- the hardware's own copy
local BUS = "System Bus"   -- for HRAM, which the flat WRAM domain does not cover

-- WRAM bank 1 laid flat: bank 0 is 0xC000-0xCFFF, bank 1 is 0xD000-0xDFFF.
local function flat(cpu_addr)
	if cpu_addr < 0xD000 then
		return cpu_addr - 0xC000
	end
	return 0x1000 + (cpu_addr - 0xD000)
end

-- Addresses from our build's .sym.
local SHADOW_OAM = flat(0xC400)   -- wShadowOAM .. wShadowOAMEnd (0xC4A0), 40 entries of 4 bytes
local W_STATEFLAGS = flat(0xD0ED) -- wStateFlags
local W_MAPSTATUS = flat(0xD432)  -- wMapStatus
local W_BATTLEMODE = flat(0xD22D) -- wBattleMode
local H_USEDSPRITEINDEX = 0xFFBD  -- hUsedSpriteIndex, in bytes not entries
local H_OAMUPDATE = 0xFFD8        -- hOAMUpdate; non-zero suppresses the VBlank OAM DMA

local OAM_COUNT = 40
local OBJ_SIZE = 4
local OAM_SIZE = OAM_COUNT * OBJ_SIZE
local OAM_YCOORD_HIDDEN = 160     -- the engine's not-in-use Y
local MAPSTATUS_HANDLE = 2
-- The bit is read as set meaning sprite updates are enabled: a reading of the source, not a measurement.
local SPRITE_UPDATES_ENABLED_BIT = 0x01
local TEXT_STATE_BIT = 0x40       -- TEXT_STATE_F, bit 6 of wStateFlags

-- The entries this probe may touch: 36 * 4 = 144 used bytes means the engine has claimed entry 36.
local TEST_FIRST_ENTRY = 36
local TEST_LAST_ENTRY = 39
local TEST_MAX_USED = TEST_FIRST_ENTRY * OBJ_SIZE

-- Two tiles right of what is copied, so the test sprite never sits on the player.
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
-- Buffered, never flushed per line: a flush stalls the emulator's thread for frames, and this measures sprites.
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

-- Asks the host whether a bulk read exists: one boundary crossing instead of 160.
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
			-- BizHawk has returned 0-based and 1-based arrays across builds: use whichever index is populated.
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

-- In use when Y is in the visible band. The engine parks unused entries at 160 and ClearSprites zeroes them, so the
-- two are counted apart.
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
			-- Hardware Y is screen line + 16, and an overworld entry is 8 lines tall.
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

-- The template is entries 0..3, the local player's four sprites: a live entry brings real tiles, palette and bank.
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

	-- How far apart the buffers are when Lua gets the frame: 0 means the DMA already ran, so a write lands after the
	-- rebuild and before the next DMA, the window a tier needs.
	local diff = 0
	for i = 0, OAM_SIZE - 1 do
		if shadow[i] ~= hw[i] then
			diff = diff + 1
		end
	end
	note("diff", diff)

	local inPlay = (mapStatus == MAPSTATUS_HANDLE) and (battleMode == 0)
	local tailFree = (used ~= nil) and (used <= TEST_MAX_USED)

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
		-- Nobody writes here: entry 36 at 160 throughout means the tail is cleared every frame.
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
			-- The read-back that counts is the hardware buffer the game's DMA fills; the shadow only proves write_u8.
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
		-- Straight into the buffer the PPU reads: the DMA overwrites it every VBlank, so it only shows if the Lua
		-- boundary falls after the DMA and before the PPU draws.
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
		-- Kept alive in both buffers, so whichever phase worked stays on screen to judge.
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
	-- Asks the host rather than assuming the OAM domain exists: the second half of this probe needs it.
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

-- A registered callback outlives its script under BizHawk, hence a loop rather than event.onframeend.
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
