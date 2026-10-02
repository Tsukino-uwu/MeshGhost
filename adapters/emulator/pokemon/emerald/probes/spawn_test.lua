-- MeshGhost — Pokémon Emerald: spawn one real character (dev tool, writes game RAM, vanilla only, never shipped).
-- An object event and a sprite two tiles left of the player, walked a tile left and down by the engine, then turned
-- through all four facings and re-spawned whenever a map load or a cull clears it. Live RAM only: no save is touched
-- and a reset undoes it. Stand still in the overworld with clear ground to your left; it counts down before writing.

local OBJECT_EVENTS_COUNT = 16
local OBJECTEVENT_SIZE = 0x24
local MAX_SPRITES = 64
local SPRITE_SIZE = 0x44
local MAP_OFFSET = 7 -- object event coords are map coords + MAP_OFFSET

local GOBJECTEVENTS_ADDR = 0x02037350
local GPLAYERAVATAR_ADDR = 0x02037590
local GSPRITES_ADDR = 0x02020630
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c
local CB2_OVERWORLD_ARCHIPELAGO_ADDR = 0x080867f1

local GFIELDCAMERA_X_ADDR = 0x03005de0
local GFIELDCAMERA_Y_ADDR = 0x03005de4
local GTOTALCAMERAPIXELOFFSETY_ADDR = 0x03005de8
local GTOTALCAMERAPIXELOFFSETX_ADDR = 0x03005dec

-- Plays the held movements it is given and starts none of its own; +1 selects Thumb, as every live callback reads.
local MOVEMENTTYPE_NONE_CB = 0x0808f3e0 + 1

local SSPRITETILEALLOCBITMAP_ADDR = 0x02021b3c
local GRESERVEDSPRITETILECOUNT_ADDR = 0x02021b3a
local GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR = 0x08505620
local TOTAL_OBJ_TILE_COUNT = 1024
local TILE_SIZE_4BPP = 32

local MOVEMENT_TYPE_NONE = 0x00
local DIR_SOUTH = 1
local MOVEMENT_ACTION_WALK_NORMAL_DOWN = 0x08
local MOVEMENT_ACTION_WALK_NORMAL_LEFT = 0x0a

-- Facing without stepping.
local FACE_ACTIONS = {
	{ name = "DOWN",  action = 0x00 },
	{ name = "UP",    action = 0x01 },
	{ name = "LEFT",  action = 0x02 },
	{ name = "RIGHT", action = 0x03 },
}

local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284
local MAP_GROUPS_COUNT = 34

-- Two tiles left: never mistaken for the player's own sprite, and inside the cull window.
local GHOST_DX = -2
local GHOST_DY = 0

local logfile
local function open_log()
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	local f = io.open(string.format("%s/spawn_test_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
	if f then logfile = f end
end

local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
		-- Every 20 lines: a bounded cost, and the log stays live.
		flushEvery = (flushEvery or 0) + 1
		if flushEvery >= 20 then
			flushEvery = 0
			pcall(function() logfile:flush() end)
		end
	end
end

local function u8(a) return memory.read_u8(a) end
local function s16(a) return memory.read_s16_le(a) end
local function s32(a) return memory.read_s32_le(a) end
local function u32(a) return memory.read_u32_le(a) end
local function mem16(a) return memory.read_u16_le(a) end
local function w8(a, v) memory.write_u8(a, v & 0xff) end
local function w16(a, v) memory.write_u16_le(a, v & 0xffff) end
local function w32(a, v) memory.write_u32_le(a, v & 0xffffffff) end

local addrOffset, addrConfirmed = 0, false

local function playerObjEventExistsAt(base)
	for i = 0, OBJECT_EVENTS_COUNT - 1 do
		local a = base + i * OBJECTEVENT_SIZE
		if (u8(a + 0x02) & 0x1) == 1 and u8(a + 0x08) == 0xff and u8(a + 0x0a) < MAP_GROUPS_COUNT then
			return true
		end
	end
	return false
end

local function tryDetect()
	if playerObjEventExistsAt(GOBJECTEVENTS_ADDR) then
		addrOffset, addrConfirmed = 0, true
	elseif playerObjEventExistsAt(GOBJECTEVENTS_ADDR + AVATAR_ADDR_ARCHIPELAGO_SHIFT) then
		addrOffset, addrConfirmed = AVATAR_ADDR_ARCHIPELAGO_SHIFT, true
	end
end

local function objAddr(i) return GOBJECTEVENTS_ADDR + addrOffset + i * OBJECTEVENT_SIZE end
local function sprAddr(i) return GSPRITES_ADDR + i * SPRITE_SIZE end

local function inOverworld()
	local cb = u32(GMAIN_CALLBACK2_ADDR)
	return cb == CB2_OVERWORLD_ADDR or cb == CB2_OVERWORLD_ADDR + 1
		or cb == CB2_OVERWORLD_ARCHIPELAGO_ADDR or cb == CB2_OVERWORLD_ARCHIPELAGO_ADDR + 1
end

local function playerObjectEventId()
	return u8(GPLAYERAVATAR_ADDR + addrOffset + 0x05)
end

local function describeObj(i)
	local a = objAddr(i)
	local b0, b1 = u8(a + 0x00), u8(a + 0x01)
	return string.format(
		"obj %2d: active=%d gfx=%3d move=%3d localId=%3d map=%d/%-3d cur=(%3d,%3d) init=(%3d,%3d) "
			.. "elev=%d face=%d action=%3d held=%d spriteId=%3d invis=%d offscr=%d",
		i, b0 & 0x01, u8(a + 0x05), u8(a + 0x06), u8(a + 0x08), u8(a + 0x0a), u8(a + 0x09),
		s16(a + 0x10), s16(a + 0x12), s16(a + 0x0c), s16(a + 0x0e), u8(a + 0x0b) & 0x0f,
		u8(a + 0x18) & 0x0f, u8(a + 0x1c), (b0 >> 6) & 0x01, u8(a + 0x04),
		(b1 >> 5) & 0x01, (b1 >> 6) & 0x01)
end

local function describeSpr(i)
	local a = sprAddr(i)
	return string.format(
		"spr %2d: inUse=%d pos=(%4d,%4d) off=(%3d,%3d) anim=%2d cmdIdx=%d data0=%3d data2=%3d "
			.. "subpri=%3d cb=0x%08X invis=%d hFlip=%d attr1=0x%04X matrixNum=%2d(oamHFlip=%d) "
			.. "attr0=0x%04X affine=%d",
		i, u8(a + 0x3e) & 0x01, s16(a + 0x20), s16(a + 0x22), s16(a + 0x24), s16(a + 0x26),
		u8(a + 0x2a), u8(a + 0x2b), s16(a + 0x2e), s16(a + 0x32), u8(a + 0x43), u32(a + 0x1c),
		(u8(a + 0x3e) >> 2) & 0x01, u8(a + 0x3f) & 0x01,
		-- attr1 bit 12 is the hardware hFlip while affine is off.
		mem16(a + 0x02), (mem16(a + 0x02) >> 9) & 0x1f, (mem16(a + 0x02) >> 12) & 0x01,
		mem16(a + 0x00), (mem16(a + 0x00) >> 8) & 0x03)
end

-- ---------------------------------------------------------------------------------------------
-- The spawn itself
-- ---------------------------------------------------------------------------------------------

local function findFreeObjectSlot()
	for i = 0, OBJECT_EVENTS_COUNT - 1 do
		if (u8(objAddr(i) + 0x00) & 0x01) == 0 then return i end
	end
	return nil
end

local function findFreeSpriteSlot()
	-- From the top: the engine takes the lowest free index, so a high one stays out of its way.
	for i = MAX_SPRITES - 1, 0, -1 do
		if (u8(sprAddr(i) + 0x3e) & 0x01) == 0 then return i end
	end
	return nil
end

local function findFreeLocalId()
	-- One no live object uses, so the ghost never takes a real NPC's identity or its script.
	local used = {}
	for i = 0, OBJECT_EVENTS_COUNT - 1 do
		if (u8(objAddr(i) + 0x00) & 0x01) == 1 then used[u8(objAddr(i) + 0x08)] = true end
	end
	for id = 200, 250 do
		if not used[id] then return id end
	end
	return nil
end

-- Computed, never copied from a template's screen position; right only while the camera is at rest.
local function spriteScreenPos(mapX, mapY, centerToCornerVecY)
	local sb1 = u32(GSAVEBLOCK1PTR_ADDR)
	local camX = 0
	local fcx = s32(GFIELDCAMERA_X_ADDR)
	if fcx > 0 then camX = 1 elseif fcx < 0 then camX = -1 end
	local camY = 0
	local fcy = s32(GFIELDCAMERA_Y_ADDR)
	if fcy > 0 then camY = 1 elseif fcy < 0 then camY = -1 end

	local x = ((mapX + camX) - s16(sb1 + 0x00)) << 4
	local y = ((mapY + camY) - s16(sb1 + 0x02)) << 4
	x = x - s16(GTOTALCAMERAPIXELOFFSETX_ADDR)
	y = y - s16(GTOTALCAMERAPIXELOFFSETY_ADDR)
	-- centerToCornerVecY is stored as a signed byte; Lua read it unsigned.
	local c2cY = centerToCornerVecY
	if c2cY > 127 then c2cY = c2cY - 256 end
	return x + 8, y + 16 + c2cY
end

local function tileIsAllocated(n)
	return (u8(SSPRITETILEALLOCBITMAP_ADDR + (n // 8)) >> (n % 8)) & 1 == 1
end

local function setTileAllocated(n, on)
	local a = SSPRITETILEALLOCBITMAP_ADDR + (n // 8)
	local v = u8(a)
	if on then v = v | (1 << (n % 8)) else v = v & ~(1 << (n % 8)) end
	w8(a, v)
end

-- The first run of free tiles above the reserved count, marked taken; nil when none is long enough, as on a busy map.
local function allocSpriteTiles(tileCount)
	local i = mem16(GRESERVEDSPRITETILECOUNT_ADDR)
	while true do
		while tileIsAllocated(i) do
			i = i + 1
			if i >= TOTAL_OBJ_TILE_COUNT then return nil end
		end
		local start, found = i, 1
		while found ~= tileCount do
			i = i + 1
			if i >= TOTAL_OBJ_TILE_COUNT then return nil end
			if not tileIsAllocated(i) then found = found + 1 else break end
		end
		if found == tileCount then
			for t = start, start + tileCount - 1 do setTileAllocated(t, true) end
			return start
		end
	end
end

local function freeSpriteTiles(start, tileCount)
	for t = start, start + tileCount - 1 do setTileAllocated(t, false) end
end

local function graphicsFrameTileCount(graphicsId)
	local infoPtr = u32(GOBJECTEVENTGRAPHICSINFOPOINTERS_ADDR + graphicsId * 4)
	if infoPtr == 0 then return nil end
	local size = mem16(infoPtr + 0x06)
	if size == 0 then return nil end
	return size // TILE_SIZE_4BPP
end

local ghostObjId, ghostSprId, ghostLocalId = nil, nil, nil
local ghostTileStart, ghostTileCount = nil, nil

local function spawnGhost()
	local playerObjId = playerObjectEventId()
	local pObj = objAddr(playerObjId)
	local playerSprId = u8(pObj + 0x04)

	-- Before any write: the player's sprite's data[0] must name the player's object event, or gSprites is elsewhere
	-- and a write would corrupt a live sprite.
	if s16(sprAddr(playerSprId) + 0x2e) ~= playerObjId then
		log(string.format("REFUSING TO WRITE: cross-link check failed -- gSprites[%d].data[0]=%d, "
			.. "expected the player's object event id %d. gSprites is not where this script thinks.",
			playerSprId, s16(sprAddr(playerSprId) + 0x2e), playerObjId))
		return false
	end

	local objId = findFreeObjectSlot()
	local sprId = findFreeSpriteSlot()
	local localId = findFreeLocalId()
	if not objId or not sprId or not localId then
		log(string.format("REFUSING TO WRITE: no free slot (object=%s sprite=%s localId=%s).",
			tostring(objId), tostring(sprId), tostring(localId)))
		return false
	end

	local sb1 = u32(GSAVEBLOCK1PTR_ADDR)
	local mapGroup, mapNum = u8(sb1 + 0x04), u8(sb1 + 0x05)
	local gx = s16(pObj + 0x10) + GHOST_DX
	local gy = s16(pObj + 0x12) + GHOST_DY
	local elevation = u8(pObj + 0x0b) & 0x0f
	local graphicsId = u8(pObj + 0x05)

	log(string.format("spawning into object slot %d / sprite slot %d, localId %d, at map coords "
		.. "(%d,%d) [player is at (%d,%d)], gfx=%d elev=%d",
		objId, sprId, localId, gx, gy, s16(pObj + 0x10), s16(pObj + 0x12), graphicsId, elevation))

	-- --- the object event -------------------------------------------------------------------
	-- Zeroed, then the fields a template spawn sets, movementType NONE: copying an NPC would bring its localId,
	-- movement range and trainer data.
	local a = objAddr(objId)
	for off = 0, OBJECTEVENT_SIZE - 1 do w8(a + off, 0) end
	w8(a + 0x00, 0x05)              -- active (bit0) | triggerGroundEffectsOnMove (bit2)
	w8(a + 0x05, graphicsId)
	w8(a + 0x06, MOVEMENT_TYPE_NONE)
	w8(a + 0x08, localId)
	w8(a + 0x09, mapNum)
	w8(a + 0x0a, mapGroup)
	w8(a + 0x0b, elevation | (elevation << 4)) -- currentElevation | previousElevation
	w16(a + 0x0c, gx) w16(a + 0x0e, gy)        -- initialCoords
	w16(a + 0x10, gx) w16(a + 0x12, gy)        -- currentCoords
	w16(a + 0x14, gx) w16(a + 0x16, gy)        -- previousCoords
	w8(a + 0x18, DIR_SOUTH | (DIR_SOUTH << 4)) -- facingDirection | movementDirection
	w8(a + 0x20, DIR_SOUTH)                    -- previousMovementDirection
	w8(a + 0x04, sprId)

	-- --- the sprite -------------------------------------------------------------------------
	-- The player's sprite, copied for its ROM pointers, OAM shape and palette, then patched where it must differ.
	local src, dst = sprAddr(playerSprId), sprAddr(sprId)
	for off = 0, SPRITE_SIZE - 1 do w8(dst + off, u8(src + off)) end

	-- Its own OBJ tiles, which the engine fills with its frames; on the player's it shows the player's current frame.
	local tileCount = graphicsFrameTileCount(graphicsId)
	if not tileCount then
		log(string.format("REFUSING TO WRITE: no graphics info for graphicsId %d.", graphicsId))
		return false
	end
	local tileStart = allocSpriteTiles(tileCount)
	if not tileStart then
		log(string.format("REFUSING TO WRITE: no run of %d free OBJ tiles available.", tileCount))
		return false
	end
	ghostTileStart, ghostTileCount = tileStart, tileCount
	-- attr2 (+0x04) is tileNum:10, priority:2, paletteNum:4; only the tile number changes.
	local attr2 = mem16(dst + 0x04)
	w16(dst + 0x04, (attr2 & 0xfc00) | (tileStart & 0x03ff))
	log(string.format("  allocated %d OBJ tiles at %d for the ghost (player uses %d)",
		tileCount, tileStart, mem16(src + 0x04) & 0x03ff))

	local c2cY = u8(dst + 0x29)
	local sx, sy = spriteScreenPos(gx, gy, c2cY)
	w32(dst + 0x1c, MOVEMENTTYPE_NONE_CB)
	w16(dst + 0x20, sx) w16(dst + 0x22, sy)
	w16(dst + 0x24, 0) w16(dst + 0x26, 0)  -- x2/y2: no sub-tile offset yet
	for k = 0, 7 do w16(dst + 0x2e + k * 2, 0) end
	w16(dst + 0x2e, objId)                 -- data[0] = sObjEventId, the cross-link back
	w8(dst + 0x2a, 0)                      -- animNum: face south
	w8(dst + 0x2b, 0)                      -- animCmdIndex
	w8(dst + 0x3e, (u8(dst + 0x3e) | 0x03) & ~0x04) -- inUse | coordOffsetEnabled, not invisible
	w8(dst + 0x3f, u8(dst + 0x3f) | 0x04)  -- animBeginning: restart the animation cleanly

	ghostObjId, ghostSprId, ghostLocalId = objId, sprId, localId
	log("  wrote " .. describeObj(objId))
	log("  wrote " .. describeSpr(sprId))
	log(string.format("  (player for comparison) %s", describeObj(playerObjId)))
	log(string.format("  (player for comparison) %s", describeSpr(playerSprId)))
	return true
end

-- Frees exactly the tile range it allocated: a leak per re-spawn would leave a long session nothing to spawn with.
local function despawnGhost()
	if not ghostObjId then return end
	w8(objAddr(ghostObjId) + 0x00, 0)                        -- active = 0 (clears the flag byte)
	local d = sprAddr(ghostSprId)
	w8(d + 0x3e, u8(d + 0x3e) & ~0x01)                       -- inUse = 0
	w8(d + 0x3f, u8(d + 0x3f))                               -- (flags byte 2 left as-is)
	w8(d + 0x3e, u8(d + 0x3e) | 0x04)                        -- invisible = 1
	if ghostTileStart then
		freeSpriteTiles(ghostTileStart, ghostTileCount)
	end
	log(string.format("despawned ghost (object slot %d, sprite slot %d, %s OBJ tiles at %s)",
		ghostObjId, ghostSprId, tostring(ghostTileCount), tostring(ghostTileStart)))
	ghostObjId, ghostSprId, ghostLocalId = nil, nil, nil
	ghostTileStart, ghostTileCount = nil, nil
end

-- By identity, never slot state: after a map load the next map's NPCs take the same slots and read active.
local function ghostAlive()
	if not ghostObjId then return false end
	local a = objAddr(ghostObjId)
	local sb1 = u32(GSAVEBLOCK1PTR_ADDR)
	if sb1 == 0 then return false end
	return (u8(a + 0x00) & 0x01) == 1
		and u8(a + 0x08) == ghostLocalId
		and u8(a + 0x0a) == u8(sb1 + 0x04)
		and u8(a + 0x09) == u8(sb1 + 0x05)
end

local function requestStep(action)
	-- A held movement, not a coordinate write: the engine plays out the tile, animation and all.
	local a = objAddr(ghostObjId)
	w8(a + 0x1c, action)
	local b0 = u8(a + 0x00)
	b0 = (b0 | 0x40) & ~0x80 -- heldMovementActive = 1, heldMovementFinished = 0
	w8(a + 0x00, b0)
	w16(sprAddr(ghostSprId) + 0x32, 0) -- data[2] = sActionFuncId
end

-- ---------------------------------------------------------------------------------------------
-- Phases: a countdown, never a window to hit.
-- ---------------------------------------------------------------------------------------------

open_log()
log("=== MeshGhost Emerald spawn test 1 (WRITES GAME RAM -- live only, no save touched) ===")
log("Stand still in the overworld with clear ground two tiles to your LEFT.")

if not memory.usememorydomain("System Bus") then
	log("FATAL: could not select the System Bus memory domain.")
	return
end

local PHASE_READY = 300     -- 5s of preconditions before anything is written
local PHASE_OBSERVE = 300   -- 5s watching the spawned ghost sit
local PHASE_WALK = 240      -- 4s: one step left, then one step down

local frames, phaseFrames = 0, 0
local phase = "wait"
local lastReport = 0
local walkIssued = 0

local function tick()
	frames = frames + 1

	if not addrConfirmed then
		tryDetect()
		if not addrConfirmed then return end
		if addrOffset ~= 0 then
			log("REFUSING TO WRITE: this is an Archipelago-shifted ROM. Spawn test 1 is vanilla-only "
				.. "by design -- see the ADR's Archipelago condition. Nothing was written.")
			phase = "refused"
			return
		end
		log("ROM variant: vanilla. Addresses confirmed by finding the player's own object event.")
	end

	if phase == "refused" or phase == "done" then return end

	if not inOverworld() then
		if frames - lastReport >= 300 then
			log(string.format("[%6d] waiting: not in the overworld yet.", frames))
			lastReport = frames
		end
		return
	end

	phaseFrames = phaseFrames + 1

	-- A map load or a cull clears the ghost; re-spawning is normal operation, not error handling.
	if (phase == "observe" or phase == "walk" or phase == "cycle") and not ghostAlive() then
		log(string.format("[%6d] ghost is gone (map load or cull). Re-spawning.", frames))
		ghostObjId, ghostSprId, ghostLocalId = nil, nil, nil
		if spawnGhost() then
			phase, phaseFrames = "cycle", 0
		else
			phase = "refused"
		end
		return
	end

	if phase == "wait" then
		phase, phaseFrames = "ready", 0
		log("--- phase 1: preconditions (5 seconds) ---")

	elseif phase == "ready" then
		if phaseFrames % 60 == 0 then
			local secs = (PHASE_READY - phaseFrames) // 60
			local objId, sprId = findFreeObjectSlot(), findFreeSpriteSlot()
			log(string.format("[%6d] spawning in %d... free object slot=%s free sprite slot=%s",
				frames, secs, tostring(objId), tostring(sprId)))
			log("        " .. describeObj(playerObjectEventId()))
		end
		if phaseFrames >= PHASE_READY then
			log("--- phase 2: writing the ghost ---")
			if spawnGhost() then
				phase, phaseFrames = "observe", 0
				log("--- phase 3: watching it for 15 seconds (it should be standing to your left) ---")
			else
				phase = "refused"
			end
		end

	elseif phase == "observe" then
		-- What the engine maintains, never an echo of our own write, which would prove only that it landed.
		if phaseFrames % 60 == 0 then
			log(string.format("[%6d] %s", frames, describeObj(ghostObjId)))
			log(string.format("         %s", describeSpr(ghostSprId)))
		end
		if phaseFrames >= PHASE_OBSERVE then
			phase, phaseFrames, walkIssued = "walk", 0, 0
			log("--- phase 4: asking the engine to walk it one tile LEFT, then one tile DOWN ---")
		end

	elseif phase == "walk" then
		if walkIssued == 0 then
			requestStep(MOVEMENT_ACTION_WALK_NORMAL_LEFT)
			walkIssued = 1
			log(string.format("[%6d] requested WALK_NORMAL_LEFT", frames))
		elseif walkIssued == 1 and phaseFrames >= 120 then
			requestStep(MOVEMENT_ACTION_WALK_NORMAL_DOWN)
			walkIssued = 2
			log(string.format("[%6d] requested WALK_NORMAL_DOWN", frames))
		end
		if phaseFrames % 8 == 0 then
			log(string.format("[%6d] %s", frames, describeObj(ghostObjId)))
			log(string.format("         %s", describeSpr(ghostSprId)))
		end
		if phaseFrames >= PHASE_WALK then
			phase, phaseFrames = "cycle", 0
			log("--- phase 5: facing cycle. The ghost turns DOWN, UP, LEFT, RIGHT, 3s each, on ---")
			log("    repeat, announced in this log before each turn. Say which ones look wrong.")
		end

	elseif phase == "cycle" then
		-- A turn every 3 seconds, named in the log before it happens, looping so each direction comes round often.
		if phaseFrames % 180 == 1 then
			local step = (phaseFrames // 180) % #FACE_ACTIONS + 1
			local f = FACE_ACTIONS[step]
			requestStep(f.action)
			log(string.format("[%6d] turning to face %s (action 0x%02X)", frames, f.name, f.action))
		end
		if phaseFrames % 180 == 60 then -- read back a second later, once the turn has played out
			log(string.format("         %s", describeObj(ghostObjId)))
			log(string.format("         %s", describeSpr(ghostSprId)))
			-- The player's own sprite on the same frame, as the control: a field that differs is the suspect.
			local pObjId = playerObjectEventId()
			log(string.format("  PLAYER %s", describeObj(pObjId)))
			log(string.format("  PLAYER %s", describeSpr(u8(objAddr(pObjId) + 0x04))))
		end
	end
end

MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function()
	-- A ghost left behind on a script swap stacks a second on the next load, and nothing in the game removes it.
	pcall(despawnGhost)
	if logfile then pcall(function() logfile:flush() end)
		logfile:close() logfile = nil end
end

if not MESHGHOST_DEV_LOADER then
	while true do
		local ok, err = pcall(tick)
		if not ok then log("spawn test error: " .. tostring(err)) end
		emu.frameadvance()
	end
end
