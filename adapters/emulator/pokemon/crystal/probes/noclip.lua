-- Walk through walls, water and NPCs: a dev tool that writes the game, never shipped. It aims the loaded tileset's
-- collision pointer at a filtered copy of the real table (warp and grass values kept, the rest $00), placed in the
-- last 512 bytes of wOverworldMapBlocks only if all read zero, and flags NPCs within two tiles EMOTE_OBJECT. Its
-- premises past the tileset header and the zero run are unmeasured; a map edge stays solid, so measure a step past
-- one before opening it. Turn it off to test surf. Vanilla V1.0/V1.1 and Archipelago on a V1.0 base; others refuse.

local WRAM, ROM = "WRAM", "ROM"
local TABLE_LEN = 512
local TABLE_FLAT = 0x0D14 - TABLE_LEN -- flat WRAM, i.e. CPU $CB14-$CD13
local TABLE_CPU = 0xC000 + TABLE_FLAT
local OBJECT_LENGTH, NUM_OBJECT_STRUCTS = 0x28, 13
local EMOTE_BIT = 0x80
local NPC_RADIUS = 2

local BUILDS = {
	PM_CRYSTAL = { label = "vanilla Crystal (.sym)", tilesetsRom = 0x4D596, header = 0x11D9, objects = 0x14D6 },
	AP_CRYSTAL = { label = "Archipelago Crystal (measured)", tilesetsRom = 0x4D46B, header = 0x11E0, objects = 0x14DC },
}
local TILESET_ENTRIES, TILESET_LENGTH = 37, 15

local title = ""
for i = 0x134, 0x13E do
	local c = memory.read_u8(i, ROM)
	if c == 0 then break end
	title = title .. string.char(c)
end
local build = BUILDS[title]

local logfile
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/noclip_%s_%s.log", dir, title:gsub("%W", ""),
		os.date("%Y%m%d_%H%M%S")), "w")
	if logfile then
		pcall(function() logfile:setvbuf("full", 8192) end)
	end
end
local consoleLines = 0
local function log(msg)
	if logfile then logfile:write(string.format("[%d] %s\n", emu.framecount(), msg)) end
end
local function say(msg)
	consoleLines = consoleLines + 1
	if consoleLines <= 6 then console.log("noclip: " .. msg) end
	log(msg)
end

local function u8(a, d) return memory.read_u8(a, d or WRAM) end
local function w8(a, v, d) memory.write_u8(a, v & 0xFF, d or WRAM) end

if not build then
	say(string.format("ROM title %q is not a build this tool has addresses for -- nothing was changed.", title))
	MESHGHOST_DEV_TICK = function() end
	return
end
say(string.format("ON for %s. Terrain/water via a filtered collision table, NPCs via EMOTE_OBJECT.", build.label))

-- ===== terrain =====

-- The real collision pointer, from the ROM entry whose first six bytes match the header: right even after an unclean
-- unload left the WRAM pointer redirected.
local function romCollision()
	local h = memory.read_bytes_as_array(build.header, 6, WRAM)
	local t = memory.read_bytes_as_array(build.tilesetsRom, TILESET_ENTRIES * TILESET_LENGTH, ROM)
	for e = 0, TILESET_ENTRIES - 1 do
		local base = e * TILESET_LENGTH
		local same = true
		for k = 1, 6 do
			if t[base + k] ~= h[k] then same = false break end
		end
		if same then
			return t[base + 7], t[base + 8] + t[base + 9] * 256, e
		end
	end
	return nil
end

local function keep(v)
	return v == 0x60 or v == 0x68 or (v & 0xF0) == 0x70 -- the warp family (unmeasured)
		or v == 0x10 or v == 0x14 or v == 0x18 or v == 0x1C -- grass family
end

local terrain = { expected = nil, mode = nil, lastPtr = nil, waitLogged = false, fallbackAt = nil }

local function pointerNow()
	return u8(build.header + 7) + u8(build.header + 8) * 256
end
local function setPointer(ptr)
	w8(build.header + 7, ptr & 0xFF)
	w8(build.header + 8, (ptr >> 8) & 0xFF)
end

local function allZero(flat, len)
	local b = memory.read_bytes_as_array(flat, len, WRAM)
	for i = 1, len do
		if b[i] ~= 0 then return false end
	end
	return true
end

-- Longest zero run in $C000-$DFFF, for the all-floor fallback. Read-only.
local function longestZeroRun()
	local b = memory.read_bytes_as_array(0, 0x2000, WRAM)
	local bestS, bestL, s = nil, 0, nil
	for i = 1, #b + 1 do
		if b[i] == 0 then
			s = s or i
		elseif s then
			if i - s > bestL then bestS, bestL = s - 1, i - s end
			s = nil
		end
	end
	return bestS, bestL
end

local function applyTerrain()
	local bank, ptr, index = romCollision()
	if not bank then
		if not terrain.waitLogged then
			say("tileset header matches no ROM entry (mid map load?) -- terrain waits.")
			terrain.waitLogged = true
		end
		return
	end
	terrain.waitLogged = false
	if allZero(TABLE_FLAT, TABLE_LEN) then
		local src = memory.read_bytes_as_array(bank * 0x4000 + (ptr - 0x4000), TABLE_LEN, ROM)
		local out, kept, opened = {}, 0, 0
		for i = 1, TABLE_LEN do
			local v = src[i]
			if keep(v) then
				out[i] = v
				if v ~= 0 then kept = kept + 1 end
			else
				out[i] = 0
				if v ~= 0 then opened = opened + 1 end
			end
		end
		for i = 1, TABLE_LEN do
			w8(TABLE_FLAT + i - 1, out[i])
		end
		setPointer(TABLE_CPU)
		terrain.expected, terrain.mode = out, "filtered"
		log(string.format("tileset %d (bank %02X $%04X): filtered copy at $%04X -- %d entries kept "
			.. "(warps, grass), %d opened to floor. Read back pointer $%04X.", index, bank, ptr,
			TABLE_CPU, kept, opened, pointerNow()))
	else
		local s, l = longestZeroRun()
		if s and l >= 256 then
			setPointer(0xC000 + s)
			terrain.expected, terrain.mode, terrain.fallbackAt = nil, "all-floor", s
			say(string.format("tileset %d: map-buffer tail is in use on this map, so FALLBACK -- every "
				.. "tile reads floor via the zero run at $%04X (%d bytes). Doors will NOT warp here.",
				index, 0xC000 + s, l))
		else
			say("no free region for terrain on this map -- terrain collision stays on.")
			terrain.mode = "none"
		end
	end
	terrain.lastPtr = pointerNow()
end

local function tickTerrain(frames)
	local ptr = pointerNow()
	if ptr >= 0x4000 and ptr <= 0x7FFF then
		-- The game's own pointer (a tileset load, or this tool stood down): retry at most every two seconds.
		if frames >= (terrain.retryAt or 0) then
			terrain.retryAt = frames + 120
			applyTerrain()
		end
		return
	end
	terrain.retryAt = nil -- redirected: the next time the game takes the pointer back, rebuild at once
	if frames % 10 ~= 0 then return end
	if terrain.mode == "filtered" and terrain.expected then
		-- Every byte: a map load zero-fills the buffer while the pointer may still be ours, and a sparse sample would
		-- skip the few non-zero warp entries.
		local b = memory.read_bytes_as_array(TABLE_FLAT, TABLE_LEN, WRAM)
		for i = 1, TABLE_LEN do
			if b[i] ~= terrain.expected[i] then
				local bank, real = romCollision()
				if bank and real then setPointer(real) end
				say(string.format("the filtered table at $%04X was overwritten by the game (byte %d) -- "
					.. "real pointer restored; will rebuild after the next map load.", TABLE_CPU, i - 1))
				terrain.expected, terrain.mode = nil, "yielded"
				return
			end
		end
	elseif terrain.mode == "all-floor" and terrain.fallbackAt then
		if not allZero(terrain.fallbackAt, 256) then
			local bank, real = romCollision()
			if bank and real then setPointer(real) end
			say("the fallback zero run stopped being zeroes -- real pointer restored.")
			terrain.mode, terrain.fallbackAt = "yielded", nil
		end
	end
end

-- ===== NPCs =====
-- The adapter's emote reader also needs OBJECT_ACTION 8 on the player's tile, so a flagged NPC never goes on the wire.

local npc = { mine = {}, standDownUntil = 0, standingDown = false }

local function clearMine(why)
	local n = 0
	for slot, id in pairs(npc.mine) do
		local base = build.objects + slot * OBJECT_LENGTH
		if u8(base) == id.sprite and u8(base + 1) == id.mapobj then
			w8(base + 4, u8(base + 4) & ~EMOTE_BIT)
			n = n + 1
		end
		npc.mine[slot] = nil
	end
	if why and n > 0 then log(string.format("cleared EMOTE_OBJECT on %d NPC(s): %s", n, why)) end
end

local function tickNpcs(frames)
	local px, py = u8(build.objects + 0x10), u8(build.objects + 0x11)
	local native = false
	for slot = 1, NUM_OBJECT_STRUCTS - 1 do
		local base = build.objects + slot * OBJECT_LENGTH
		local sprite = u8(base)
		local id = npc.mine[slot]
		if sprite == 0 or (id and (id.sprite ~= sprite or id.mapobj ~= u8(base + 1))) then
			npc.mine[slot] = nil -- slot emptied or reused: not ours any more, never touch it
			id = nil
		end
		if sprite ~= 0 and not id and (u8(base + 4) & EMOTE_BIT) ~= 0 then
			native = true
		end
	end
	if native then
		if not npc.standingDown then
			clearMine("a real emote/shadow/shake object exists (and an emote ending may delete every flagged object -- UNMEASURED)")
			npc.standingDown = true
		end
		npc.standDownUntil = frames + 120
		return
	end
	if frames < npc.standDownUntil then return end
	if npc.standingDown then
		npc.standingDown = false
		log("decoration objects gone for 2s -- NPC noclip resumes")
	end
	for slot = 1, NUM_OBJECT_STRUCTS - 1 do
		local base = build.objects + slot * OBJECT_LENGTH
		local sprite = u8(base)
		if sprite ~= 0 then
			local x, y = u8(base + 0x10), u8(base + 0x11)
			local lx, ly = u8(base + 0x12), u8(base + 0x13)
			local near = math.abs(x - px) + math.abs(y - py) <= NPC_RADIUS
				or math.abs(lx - px) + math.abs(ly - py) <= NPC_RADIUS
			local flags = u8(base + 4)
			if near and not npc.mine[slot] and (flags & EMOTE_BIT) == 0 then
				w8(base + 4, flags | EMOTE_BIT)
				npc.mine[slot] = { sprite = sprite, mapobj = u8(base + 1) }
			elseif not near and npc.mine[slot] then
				w8(base + 4, flags & ~EMOTE_BIT)
				npc.mine[slot] = nil
			end
		end
	end
end

local frames = 0
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	tickTerrain(frames)
	tickNpcs(frames)
	if frames % 300 == 0 and logfile then
		pcall(function() logfile:flush() end)
	end
end

MESHGHOST_DEV_UNLOAD = function()
	clearMine("unload")
	local bank, real = romCollision()
	if bank and real and pointerNow() >= 0xC000 then
		setPointer(real)
	end
	if terrain.mode == "filtered" and terrain.expected then
		local b = memory.read_bytes_as_array(TABLE_FLAT, TABLE_LEN, WRAM)
		local intact = true
		for i = 1, TABLE_LEN do
			if b[i] ~= terrain.expected[i] then intact = false break end
		end
		if intact then
			for i = 0, TABLE_LEN - 1 do w8(TABLE_FLAT + i, 0) end
		end
	end
	say(string.format("OFF -- collision pointer now $%04X (the game's own), NPC flags cleared.", pointerNow()))
	if logfile then
		pcall(function() logfile:flush() end)
		logfile:close()
		logfile = nil
	end
end

-- A loop, not event.onframeend: a registered callback outlives its script under BizHawk.
if not MESHGHOST_DEV_LOADER then
	while true do
		MESHGHOST_DEV_TICK()
		emu.frameadvance()
	end
end
