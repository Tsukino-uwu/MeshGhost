-- MeshGhost — Emerald: what the game creates while fishing (dev tool, read-only, never shipped). Logs every change
-- of the player's graphic, animation, field-effect sprite, sprites in use and callback2, across every branch of a cast.
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
	-- fieldEffectSpriteId: surfing owns its blob through it, so a fishing companion would show here.
	local fx = u8(a + 0x1a)
	-- callback2 is in the key, so entering a menu or a battle counts as a change.
	local key = string.format("%d|%d|%d|%d|%08X",
		u8(a + 0x05), u8(sp + 0x2a), fx, spritesInUse(), u32(GMAIN_CALLBACK2_ADDR))
	if key ~= last then
		log(string.format("%6d | gfx=%3d anim=%2d | fieldEffect=%3d | sprites=%2d | cb2=%08X",
			frames, u8(a + 0x05), u8(sp + 0x2a), fx, spritesInUse(), u32(GMAIN_CALLBACK2_ADDR)))
		last = key
	end
end
