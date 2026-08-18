-- MeshGhost — Pokémon Emerald: object-event / sprite slot probe
--
-- READ-ONLY DIAGNOSTIC. Writes nothing, sends nothing, draws nothing.
-- Emerald's shipped adapter draws its ghost with gui.drawPixel over a hand-rolled ROM sprite
-- decode. The goal this probe serves is replacing that with a real spawned object event, the way
-- adapters/pokemon/crystal does -- so the engine owns palettes, occlusion, priority and
-- animation. Spawning needs writes; writes are ADR-gated (agent_docs/architecture.md). This is
-- the evidence step that comes first, and it deliberately performs no writes at all.
--
-- WHAT HAS TO BE OBSERVED RATHER THAN ASSUMED
--   1. How many of the 16 object-event slots and 64 sprite slots are genuinely free during
--      ordinary play, indoors and out. Both are shared with every NPC the map already has.
--   2. What a live NPC's pair of records actually looks like, field by field, next to the
--      PLAYER's -- because a spawn is going to be built by copying one of them. The pointer
--      fields (anims/images/template/callback) are the interesting part: they cannot be
--      synthesised from Lua, only copied, so the probe prints them.
--   3. What the engine does on its own: it spawns NPCs as the camera scrolls toward them
--      (TrySpawnObjectEvents) and culls them again once they leave the window
--      (RemoveObjectEventsOutsideView). Both events are logged as they happen, since a ghost has
--      to survive -- or be re-spawned past -- exactly this.
--   4. What a map transition does to both arrays.
--
-- ADDRESSES, all from our own make-compare-verified pokeemerald build (agent_docs/verified.md,
-- agent_docs/environment.md); symbol sizes quoted from pokeemerald.sym:
--   gObjectEvents  0x02037350, size 0x240 = OBJECT_EVENTS_COUNT(16) * sizeof(ObjectEvent)(0x24)
--   gSprites       0x02020630, MAX_SPRITES(64) * sizeof(struct Sprite)(0x44)
--   gPlayerAvatar  0x02037590, size 0x24
-- Field offsets are the /*0xNN*/ comments in include/global.fieldmap.h (struct ObjectEvent) and
-- include/sprite.h (struct Sprite). No offset here is recalled or inferred.
--
-- HOW TO RUN
--   1. Open BizHawk, load the Emerald ROM (vanilla or Archipelago-patched -- the probe reports
--      which it detected), and be in the overworld with a real save loaded.
--   2. Lua Console -> Script -> Open, pick this file.
--   3. Walk a while outdoors so NPCs scroll in and out of view, then enter and leave a building.
--      Output also goes to object_slot_probe_<timestamp>.log beside this script.

local OBJECT_EVENTS_COUNT = 16
local OBJECTEVENT_SIZE = 0x24
local MAX_SPRITES = 64
local SPRITE_SIZE = 0x44

local GOBJECTEVENTS_ADDR = 0x02037350
local GPLAYERAVATAR_ADDR = 0x02037590
local GSPRITES_ADDR = 0x02020630
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local CB2_OVERWORLD_ARCHIPELAGO_ADDR = 0x080867f1
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c

-- The one known Archipelago relocation of gObjectEvents/gPlayerAvatar, established live
-- 2026-08-14 (verified.md, "Archipelago-relocated gObjectEvents"). Detection below mirrors the
-- shipped adapter's playerObjEventExistsAt() exactly, including its mapGroup plausibility term.
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284
local MAP_GROUPS_COUNT = 34

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	local path = string.format("%s/object_slot_probe_%s.log", dir, os.date("%Y%m%d_%H%M%S"))
	local f = io.open(path, "w")
	if f then
		logfile = f
		return path
	end
	return nil
end

local raw_log = console.log
local function log(msg)
	raw_log(msg)
	if logfile then
		logfile:write(msg, "\n")
		logfile:flush()
	end
end

local function u8(addr)
	local ok, v = pcall(memory.read_u8, addr)
	if ok and type(v) == "number" then return v end
	return nil
end

local function u16(addr)
	local ok, v = pcall(memory.read_u16_le, addr)
	if ok and type(v) == "number" then return v end
	return nil
end

local function s16(addr)
	local ok, v = pcall(memory.read_s16_le, addr)
	if ok and type(v) == "number" then return v end
	return nil
end

local function u32(addr)
	local ok, v = pcall(memory.read_u32_le, addr)
	if ok and type(v) == "number" then return v end
	return nil
end

-- ROM-variant detection, same two candidates and same test as the shipped adapter. Retried every
-- frame rather than latched once, for the timing reason recorded in the adapter's own comment:
-- a script loaded during the intro sees no player object event at EITHER address and would
-- otherwise lock in the wrong answer for the session.
local addrOffset = 0
local addrConfirmed = false

local function playerObjEventExistsAt(base)
	for i = 0, OBJECT_EVENTS_COUNT - 1 do
		local addr = base + i * OBJECTEVENT_SIZE
		local isPlayerBit = (u8(addr + 0x02) or 0) & 0x1
		local localId = u8(addr + 0x08) or 0
		local mapGroup = u8(addr + 0x0a) or 0xff
		if isPlayerBit == 1 and localId == 0xff and mapGroup < MAP_GROUPS_COUNT then
			return true
		end
	end
	return false
end

local function tryDetect()
	if playerObjEventExistsAt(GOBJECTEVENTS_ADDR) then
		addrOffset, addrConfirmed = 0, true
		log("ROM variant: vanilla addresses (gObjectEvents at 0x02037350).")
	elseif playerObjEventExistsAt(GOBJECTEVENTS_ADDR + AVATAR_ADDR_ARCHIPELAGO_SHIFT) then
		addrOffset, addrConfirmed = AVATAR_ADDR_ARCHIPELAGO_SHIFT, true
		log(string.format("ROM variant: Archipelago-shifted by 0x%X.", AVATAR_ADDR_ARCHIPELAGO_SHIFT))
	end
end

local function inOverworld()
	local cb = u32(GMAIN_CALLBACK2_ADDR) or 0
	return cb == CB2_OVERWORLD_ADDR or cb == CB2_OVERWORLD_ADDR + 1
		or cb == CB2_OVERWORLD_ARCHIPELAGO_ADDR or cb == CB2_OVERWORLD_ARCHIPELAGO_ADDR + 1
end

-- struct ObjectEvent, include/global.fieldmap.h. Bitfields are read as their containing byte and
-- masked here, so every number below traces to a /*0xNN*/ comment plus a bit position.
local function objectEvent(i)
	local a = GOBJECTEVENTS_ADDR + addrOffset + i * OBJECTEVENT_SIZE
	local b0, b1, b2 = u8(a + 0x00) or 0, u8(a + 0x01) or 0, u8(a + 0x02) or 0
	local dirs = u8(a + 0x18) or 0
	return {
		addr = a,
		active = b0 & 0x01,
		heldMovementActive = (b0 >> 6) & 0x01,
		frozen = b1 & 0x01,
		inanimate = (b1 >> 4) & 0x01,
		invisible = (b1 >> 5) & 0x01,
		offScreen = (b1 >> 6) & 0x01,
		trackedByCamera = (b1 >> 7) & 0x01,
		isPlayer = b2 & 0x01,
		hasReflection = (b2 >> 1) & 0x01,
		hasShadow = (b2 >> 6) & 0x01,
		spriteId = u8(a + 0x04),
		graphicsId = u8(a + 0x05),
		movementType = u8(a + 0x06),
		trainerType = u8(a + 0x07),
		localId = u8(a + 0x08),
		mapNum = u8(a + 0x09),
		mapGroup = u8(a + 0x0a),
		elevation = (u8(a + 0x0b) or 0) & 0x0f,
		prevElevation = ((u8(a + 0x0b) or 0) >> 4) & 0x0f,
		initX = s16(a + 0x0c), initY = s16(a + 0x0e),
		curX = s16(a + 0x10), curY = s16(a + 0x12),
		prevX = s16(a + 0x14), prevY = s16(a + 0x16),
		facingDirection = dirs & 0x0f,
		movementDirection = (dirs >> 4) & 0x0f,
		movementActionId = u8(a + 0x1c),
		currentMetatileBehavior = u8(a + 0x1e),
		playerCopyableMovement = u8(a + 0x22),
	}
end

-- struct Sprite, include/sprite.h.
local function sprite(i)
	local a = GSPRITES_ADDR + i * SPRITE_SIZE
	local f3e = u8(a + 0x3e) or 0
	local oam0 = u32(a + 0x00) or 0
	local oam4 = u32(a + 0x04) or 0
	return {
		addr = a,
		anims = u32(a + 0x08),
		images = u32(a + 0x0c),
		template = u32(a + 0x14),
		callback = u32(a + 0x1c),
		x = s16(a + 0x20), y = s16(a + 0x22),
		x2 = s16(a + 0x24), y2 = s16(a + 0x26),
		centerToCornerVecX = u8(a + 0x28), centerToCornerVecY = u8(a + 0x29),
		animNum = u8(a + 0x2a),
		data0 = s16(a + 0x2e),
		inUse = f3e & 0x01,
		coordOffsetEnabled = (f3e >> 1) & 0x01,
		invisible = (f3e >> 2) & 0x01,
		subpriority = u8(a + 0x43),
		-- OamData is a packed bitfield; priority/paletteNum live in the second word's high byte.
		-- Printed raw so nothing here depends on decoding it correctly today.
		oamRaw0 = oam0, oamRaw1 = oam4,
	}
end

local function spritesInUse()
	local n = 0
	for i = 0, MAX_SPRITES - 1 do
		if (u8(GSPRITES_ADDR + i * SPRITE_SIZE + 0x3e) or 0) & 0x01 == 1 then n = n + 1 end
	end
	return n
end

local function occupancy()
	local marks, used = {}, 0
	for i = 0, OBJECT_EVENTS_COUNT - 1 do
		local o = objectEvent(i)
		if o.active == 1 then
			marks[#marks + 1] = (o.isPlayer == 1) and "P" or "X"
			used = used + 1
		else
			marks[#marks + 1] = "."
		end
	end
	return table.concat(marks), used
end

local function fmtPtr(v)
	if not v then return "?" end
	return string.format("0x%08X", v)
end

local function dumpObjectEvent(i, o)
	local s = o.spriteId and sprite(o.spriteId) or nil
	log(string.format(
		"  obj %2d @%08X: gfx=%3d move=%3d localId=%3d map=%d/%-3d cur=(%3d,%3d) init=(%3d,%3d) "
			.. "elev=%d face=%d mvdir=%d action=%3d spriteId=%3d%s%s%s%s",
		i, o.addr, o.graphicsId or -1, o.movementType or -1, o.localId or -1,
		o.mapGroup or -1, o.mapNum or -1, o.curX or -1, o.curY or -1, o.initX or -1, o.initY or -1,
		o.elevation, o.facingDirection, o.movementDirection, o.movementActionId or -1,
		o.spriteId or -1,
		(o.isPlayer == 1) and "  <- PLAYER" or "",
		(o.invisible == 1) and " INVIS" or "",
		(o.offScreen == 1) and " OFFSCR" or "",
		(o.trackedByCamera == 1) and " CAM" or ""
	))
	if s then
		log(string.format(
			"        sprite %2d @%08X: inUse=%d pos=(%4d,%4d) off=(%3d,%3d) c2c=(%3d,%3d) anim=%2d "
				.. "data0=%3d subpri=%3d coordOff=%d invis=%d",
			o.spriteId, s.addr, s.inUse, s.x or -1, s.y or -1, s.x2 or -1, s.y2 or -1,
			s.centerToCornerVecX or -1, s.centerToCornerVecY or -1, s.animNum or -1,
			s.data0 or -1, s.subpriority or -1, s.coordOffsetEnabled, s.invisible
		))
		log(string.format(
			"        sprite %2d ptrs: callback=%s anims=%s images=%s template=%s oam=%s %s",
			o.spriteId, fmtPtr(s.callback), fmtPtr(s.anims), fmtPtr(s.images),
			fmtPtr(s.template), fmtPtr(s.oamRaw0), fmtPtr(s.oamRaw1)
		))
	end
end

local log_path = open_log()
log("=== MeshGhost Emerald object-event / sprite slot probe (READ-ONLY) ===")
if log_path then log("Logging to " .. log_path) end
log(string.format(
	"%d object events of 0x%02X bytes at 0x%08X; %d sprites of 0x%02X bytes at 0x%08X.",
	OBJECT_EVENTS_COUNT, OBJECTEVENT_SIZE, GOBJECTEVENTS_ADDR,
	MAX_SPRITES, SPRITE_SIZE, GSPRITES_ADDR))
log("Walk outdoors so NPCs scroll in and out, then enter and leave a building.")

if not memory.usememorydomain("System Bus") then
	log("FATAL: could not select the System Bus memory domain.")
	log("Domains available: " .. tostring(memory.getmemorydomainlist()))
	return
end

-- A heartbeat so a quiet room reads as quiet rather than as a broken probe -- the exact failure
-- that made Crystal's first object-slot run look like it had crashed (phases/phase9.md, step 5).
local HEARTBEAT_FRAMES = 600

local frames = 0
local lastKey, lastMap, lastHeartbeat = nil, nil, 0
local lastActive = {}

local function tick()
	frames = frames + 1

	if not addrConfirmed then
		tryDetect()
		if not addrConfirmed then
			if frames % 300 == 0 then
				log(string.format("[%6d] waiting: no player object event at either candidate address yet.", frames))
			end
			return
		end
	end

	if not inOverworld() then
		if frames - lastHeartbeat >= HEARTBEAT_FRAMES then
			log(string.format("[%6d] not in the overworld (callback2=%s) -- arrays not meaningful here.",
				frames, fmtPtr(u32(GMAIN_CALLBACK2_ADDR))))
			lastHeartbeat = frames
		end
		return
	end

	local sb1 = u32(GSAVEBLOCK1PTR_ADDR) or 0
	local mapKey, posKey = "?", "?"
	if sb1 ~= 0 then
		-- SaveBlock1: pos.x/pos.y at +0x00/+0x02, location.mapGroup/mapNum at +0x04/+0x05 --
		-- the same offsets the shipped adapter's getLocalState() reads. pos is what
		-- RemoveObjectEventIfOutsideView() measures its cull window from, so it is logged too.
		mapKey = string.format("%d/%d", u8(sb1 + 0x04) or -1, u8(sb1 + 0x05) or -1)
		posKey = string.format("(%d,%d)", s16(sb1 + 0x00) or -1, s16(sb1 + 0x02) or -1)
	end

	-- Per-slot arrival/departure edges. This is what shows the engine spawning an NPC as it
	-- scrolls into range and culling it as it leaves -- the two lifecycle events a spawned ghost
	-- has to survive, and the reason a snapshot alone would not be enough.
	for i = 0, OBJECT_EVENTS_COUNT - 1 do
		local o = objectEvent(i)
		local was = lastActive[i]
		if was ~= o.active then
			if o.active == 1 then
				log(string.format("[%6d] + slot %d became ACTIVE", frames, i))
				dumpObjectEvent(i, o)
			elseif was ~= nil then
				log(string.format("[%6d] - slot %d went inactive (culled or removed)", frames, i))
			end
			lastActive[i] = o.active
		end
	end

	local marks, used = occupancy()
	local spriteCount = spritesInUse()
	local key = marks .. "|" .. mapKey .. "|" .. tostring(spriteCount)

	if key ~= lastKey or frames - lastHeartbeat >= HEARTBEAT_FRAMES then
		if mapKey ~= lastMap then
			log(string.format("[%6d] --- map changed -> group/num %s ---", frames, mapKey))
			lastMap = mapKey
		end
		log(string.format(
			"[%6d] player %s  objects [%s] %d used / %d free    sprites %d used / %d free",
			frames, posKey, marks, used, OBJECT_EVENTS_COUNT - used,
			spriteCount, MAX_SPRITES - spriteCount))
		for i = 0, OBJECT_EVENTS_COUNT - 1 do
			local o = objectEvent(i)
			if o.active == 1 then dumpObjectEvent(i, o) end
		end
		lastKey = key
		lastHeartbeat = frames
	end
end

-- Runs either way: under dev-scripts/bizhawk-dev-loader.lua (which owns the frame loop and can
-- swap scripts without relaunching the emulator), or opened directly in the Lua Console.
MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function()
	if logfile then
		logfile:close()
		logfile = nil
	end
end

if not MESHGHOST_DEV_LOADER then
	-- while-true, never event.onframeend: a registered callback outlives its script, so stopping
	-- the script would leave it running and every reload would stack another. See pitfalls.md.
	while true do
		local ok, err = pcall(tick)
		if not ok then
			log("probe error: " .. tostring(err))
		end
		emu.frameadvance()
	end
end
