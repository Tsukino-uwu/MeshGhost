-- MeshGhost — Emerald: watch what the game CREATES while fishing (READ-ONLY)
--
-- Question: does fishing spawn a companion sprite the way surfing does? Surfing turned out to be a
-- pose PLUS a separate blue Pokemon attached through the object's `fieldEffectSpriteId`, so a
-- ghost given only the graphic was half the state. Fishing has to be asked the same question, and
-- the only honest way to ask is to fish and watch.
--
-- Fishing is a PROCESS with branches, not a flag (probes.md): nothing bites; something bites and
-- is missed; something bites and takes several rounds; something bites and a battle starts. So
-- this logs every change across the whole thing rather than sampling an endpoint -- the failure
-- branches are as informative as the success, and two of them end in the same standing pose.
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GSPRITES_ADDR = 0x02020630
local OBJECTEVENT_SIZE, SPRITE_SIZE, MAX_SPRITES = 0x24, 0x44, 64
local GMAIN_CALLBACK2_ADDR = 0x030022c4

local logfile
do
	local dir = "."
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		dir = info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	logfile = io.open(string.format("%s/fishing_watch_%s.log", dir, os.date("%Y%m%d_%H%M%S")), "w")
end
local function log(m) console.log(m) if logfile then logfile:write(m, "\n") logfile:flush() end end

local function u8(a) return memory.read_u8(a) end
local function u32(a) return memory.read_u32_le(a) end

local function spritesInUse()
	local n = 0
	for i = 0, MAX_SPRITES - 1 do
		if u8(GSPRITES_ADDR + i * SPRITE_SIZE + 0x3e) & 0x01 == 1 then n = n + 1 end
	end
	return n
end

log("=== fishing watch (READ-ONLY) ===")
log("Fish repeatedly: let some casts fail, miss a bite on purpose, and land one.")
log("frame | gfx anim | fieldEffectSpriteId | sprites in use | callback2")

local frames, last = 0, nil
MESHGHOST_DEV_TICK = function()
	frames = frames + 1
	local objId = u8(GPLAYERAVATAR_ADDR + 0x05)
	if objId > 15 then return end
	local a = GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE
	local sp = GSPRITES_ADDR + u8(a + 0x04) * SPRITE_SIZE
	-- fieldEffectSpriteId is the field surfing uses to own its blob (ObjectEvent +0x1A). If
	-- fishing owns a companion too, it shows up here as a non-zero id.
	local fx = u8(a + 0x1a)
	-- callback2 is part of the key, not just the output. Without it, entering a menu or a battle
	-- changed nothing this probe considered "a change", so a whole run logged one line and the
	-- silence was misread as "the game did nothing" (pitfalls.md). A probe's change-detection
	-- decides what it can see, so it has to include every transition worth noticing.
	local key = string.format("%d|%d|%d|%d|%08X",
		u8(a + 0x05), u8(sp + 0x2a), fx, spritesInUse(), u32(GMAIN_CALLBACK2_ADDR))
	if key ~= last then
		log(string.format("%6d | gfx=%3d anim=%2d | fieldEffect=%3d | sprites=%2d | cb2=%08X",
			frames, u8(a + 0x05), u8(sp + 0x2a), fx, spritesInUse(), u32(GMAIN_CALLBACK2_ADDR)))
		last = key
	end
end
