-- MeshGhost — Pokémon Emerald: fishing recorder
--
-- READ-ONLY. Writes nothing, draws nothing.
--
-- WHY
-- Fishing is the one player state this adapter has never looked at. `phase8.md` files it as a
-- separate follow-up from surf/bike precisely because it is not a movement speed -- it is a
-- stationary action with its own graphics and its own multi-stage animation (cast, wait, bite,
-- reel). A ghost cannot be made to fish until it is known what fishing LOOKS like in memory.
--
-- WHAT IT RECORDS
-- A timeline, one line per change, of every field that could plausibly carry the animation:
--   * the player object event's graphicsId -- Emerald swaps the whole avatar graphic for special
--     states (sPlayerAvatarGfxIds), so a fishing pose is likely a different graphicsId entirely
--     rather than a different animation on the walking one. That distinction decides how a ghost
--     would reproduce it, so it is the single most valuable column here.
--   * movementActionId, facing/movement direction, and the held-movement bits.
--   * the sprite's animNum / animCmdIndex -- which frame of which animation is showing.
--   * gPlayerAvatar's flags byte, which already carries the dash bit the adapter reads and the
--     surf/bike bits phase8 wants (global.fieldmap.h:288-295).
--
-- Logging only on change is deliberate: a per-frame dump of a 200-frame fishing sequence is
-- unreadable, while the changes ARE the animation.
--
-- HOW TO RUN
--   Point dev-scripts/bizhawk-dev-loader.target at this file, then fish. Cast a few times,
--   including one that catches something and one that gets away, and face different directions.
--   Output goes to fishing_<timestamp>.log beside this script.

local GOBJECTEVENTS_ADDR = 0x02037350
local GPLAYERAVATAR_ADDR = 0x02037590
local GSPRITES_ADDR = 0x02020630
local OBJECTEVENT_SIZE = 0x24
local SPRITE_SIZE = 0x44
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284
local MAP_GROUPS_COUNT = 34

local logfile
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/fishing_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
end

local function log(msg)
	console.log(msg)
	if logfile then
		logfile:write(msg, "\n")
	end
end

local function u8(a) return memory.read_u8(a) end
local function s16(a) return memory.read_s16_le(a) end

local addrOffset, addrConfirmed = 0, false

local function playerObjEventExistsAt(base)
	for i = 0, 15 do
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
		log("addresses: vanilla")
	elseif playerObjEventExistsAt(GOBJECTEVENTS_ADDR + AVATAR_ADDR_ARCHIPELAGO_SHIFT) then
		addrOffset, addrConfirmed = AVATAR_ADDR_ARCHIPELAGO_SHIFT, true
		log("addresses: Archipelago-shifted")
	end
end

log("=== MeshGhost Emerald fishing recorder (READ-ONLY) ===")
log("Fish now. Cast several times -- one catch, one that gets away -- and face different ways.")
log("frame | gfx move action face held | anim cmd | avatarFlags run | pos")

if not memory.usememorydomain("System Bus") then
	log("FATAL: could not select the System Bus memory domain.")
	MESHGHOST_DEV_TICK = function() end
	return
end

local frames = 0
local last = nil
local seenGfx = {}

local function snapshot()
	local objId = u8(GPLAYERAVATAR_ADDR + addrOffset + 0x05)
	local a = GOBJECTEVENTS_ADDR + addrOffset + objId * OBJECTEVENT_SIZE
	local sprId = u8(a + 0x04)
	local sp = GSPRITES_ADDR + sprId * SPRITE_SIZE
	local b0 = u8(a + 0x00)
	return {
		gfx = u8(a + 0x05),
		move = u8(a + 0x06),
		action = u8(a + 0x1c),
		face = u8(a + 0x18) & 0x0f,
		held = (b0 >> 6) & 0x01,
		heldDone = (b0 >> 7) & 0x01,
		anim = u8(sp + 0x2a),
		cmd = u8(sp + 0x2b),
		flags = u8(GPLAYERAVATAR_ADDR + addrOffset + 0x00),
		running = u8(GPLAYERAVATAR_ADDR + addrOffset + 0x02),
		x = s16(a + 0x10), y = s16(a + 0x12),
		sprId = sprId,
	}
end

local function key(s)
	return string.format("%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d|%d",
		s.gfx, s.move, s.action, s.face, s.held, s.heldDone, s.anim, s.cmd,
		s.flags, s.running, s.x, s.y)
end

MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	if not addrConfirmed then
		tryDetect()
		if not addrConfirmed then return end
	end

	local ok, s = pcall(snapshot)
	if not ok then return end

	local k = key(s)
	if k ~= last then
		log(string.format(
			"%6d | gfx=%3d move=%3d action=%3d face=%d held=%d/%d | anim=%2d cmd=%d | "
				.. "flags=0x%02X run=%d | (%3d,%3d) spr=%2d",
			frames, s.gfx, s.move, s.action, s.face, s.held, s.heldDone, s.anim, s.cmd,
			s.flags, s.running, s.x, s.y, s.sprId))
		last = k
	end

	-- A graphicsId we have not seen before is the headline result: it means fishing is a whole
	-- different avatar graphic rather than an animation on the walking one, which is what decides
	-- how a ghost would ever reproduce it.
	if not seenGfx[s.gfx] then
		seenGfx[s.gfx] = true
		log(string.format("       *** new graphicsId seen: %d ***", s.gfx))
	end
end

if not MESHGHOST_DEV_LOADER then
	while true do
		local ok, err = pcall(MESHGHOST_DEV_TICK)
		if not ok then log("probe error: " .. tostring(err)) end
		emu.frameadvance()
	end
end
