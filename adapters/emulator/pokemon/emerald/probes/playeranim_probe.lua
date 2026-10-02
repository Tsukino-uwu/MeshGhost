-- MeshGhost — Emerald: the player's own sprite, on change: graphic, animation and frame, paused bit, action (dev tool).
-- The overworld pauses an idle sprite, and handing a ghost's animation to the engine unpauses it.
-- This script's own directory: a tracked absolute path is unusable on any other machine.
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
