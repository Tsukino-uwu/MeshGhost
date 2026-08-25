-- MeshGhost -- what the PLAYER's own sprite is doing (PROBE, never shipped).
--
-- WHY. A ghost mirrors the peer's animation number and then hands the animation to the engine by
-- setting `enableAnim`, which clears `animPaused`. That is right for fishing, where the game's own
-- task drives the frames -- but the overworld PAUSES an idle sprite, and a stationary bike is
-- supposed to be one of those. A spawned ghost on a Mach Bike pedals while standing still.
--
-- So the question is simply: is the player's own sprite paused while idle, and does that differ by
-- graphic? Logged on change only, so it is cheap enough to leave on while riding around.
--
-- ADDRESSES: gPlayerAvatar 02037590 {spriteId 0x04, objectEventId 0x05}, gObjectEvents 02037350
-- stride 0x24 (graphicsId 0x05, movementActionId 0x1C), gSprites 02020630 stride 0x44
-- (animNum 0x2A, animCmdIndex 0x2B, animPaused = bit 0x40 of 0x2C, animDelayCounter 0x2D).
-- Resolve this script's own directory instead of hardcoding one developer's
-- checkout. A tracked absolute path is unusable on anyone else's machine and is
-- the class of leak .githooks/pre-commit now refuses (pitfalls.md).
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GSPRITES_ADDR = 0x02020630

local function r8(a) return memory.read_u8(a) end
local last = nil
local logPath = MESHGHOST_DIR .. "/playeranim.log"
local f = io.open(logPath, "w")

local function tick()
    local objId = r8(GPLAYERAVATAR_ADDR + 0x05)
    if objId > 15 then return end
    local o = GOBJECTEVENTS_ADDR + objId * 0x24
    local d = GSPRITES_ADDR + r8(GPLAYERAVATAR_ADDR + 0x04) * 0x44
    local gfx = r8(o + 0x05)
    local anim, idx = r8(d + 0x2a), r8(d + 0x2b)
    local paused = (r8(d + 0x2c) & 0x40) ~= 0
    local act = r8(o + 0x1c)
    local key = string.format("%d/%d/%d/%s/%d", gfx, anim, idx, tostring(paused), act)
    if key == last then return end
    last = key
    local line = string.format("gfx=%-3d anim=%d/%d paused=%-5s action=%-3d  2c=%02X",
        gfx, anim, idx, tostring(paused), act, r8(d + 0x2c))
    console.log("playeranim: " .. line)
    if f then f:write(line .. string.char(10)) f:flush() end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() if f then f:close() f = nil end end
else
    while true do tick() emu.frameadvance() end
end
