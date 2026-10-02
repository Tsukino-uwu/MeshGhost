-- MeshGhost — Emerald turn/door probe: what the engine does for a turn in place and a house transition (dev tool,
-- read-only, vanilla only, never shipped). One line per change of the player's map, tile, facing, avatar flags, sprite
-- animation, flags and position, pos2, gSpriteCoordOffset, camera pixel offset, the tile origin and the active object
-- count, to turn_and_door_probe.log, flushed once a second. Addresses as in meshghost_emerald.lua.
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSPRITES_ADDR = 0x02020630
local SPRITE_SIZE = 0x44

local LOG_PATH = MESHGHOST_DIR .. "/turn_and_door_probe.log"
local logfile = io.open(LOG_PATH, "a")
local pending, frames, last = {}, 0, nil

local function say(m)
    pending[#pending + 1] = m
end

local function u8(a) return memory.read_u8(a) end

local function sample()
    local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if base == 0 then return "no save block (title/intro)" end

    local flags = u8(GPLAYERAVATAR_ADDR + 0x00)
    local runningState = u8(GPLAYERAVATAR_ADDR + 0x02)
    local objectEventId = u8(GPLAYERAVATAR_ADDR + 0x05)
    local objAddr = GOBJECTEVENTS_ADDR + objectEventId * OBJECTEVENT_SIZE
    local facing = memory.read_u16_le(objAddr + 0x18) & 0xF
    local spr = GSPRITES_ADDR + u8(GPLAYERAVATAR_ADDR + 0x04) * SPRITE_SIZE

    local active = 0
    for i = 0, 15 do
        if (u8(GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE) & 0x01) == 1 then active = active + 1 end
    end

    return string.format(
        "map=%d:%d pos=%d,%d facing=%d run=%d avatarFlags=%02X sprAnim=%d/%d sprFlags=%02X "
            .. "sprXY=%d,%d pos2=%d,%d coordOff=%d,%d camPix=%d,%d origin=%d,%d "
            .. "activeObjects=%d",
        memory.read_s8(base + 0x04), memory.read_s8(base + 0x05),
        memory.read_s16_le(base + 0x00), memory.read_s16_le(base + 0x02),
        facing, runningState, flags,
        u8(spr + 0x2a), u8(spr + 0x2b), u8(spr + 0x3e),
        memory.read_s16_le(spr + 0x20), memory.read_s16_le(spr + 0x22),
        memory.read_s16_le(spr + 0x24), memory.read_s16_le(spr + 0x26),
        memory.read_s16_le(0x02021bbc), memory.read_s16_le(0x02021bbe),
        memory.read_s16_le(0x03005dec), memory.read_s16_le(0x03005de8),
        -- origin: the screen position less pos2, the player's tile on screen if it moves only by 16 at a tile change.
        memory.read_s16_le(spr + 0x20) + memory.read_s16_le(spr + 0x24)
            + memory.read_s8(spr + 0x28) + memory.read_s16_le(0x02021bbc)
            - memory.read_s16_le(spr + 0x24),
        memory.read_s16_le(spr + 0x22) + memory.read_s16_le(spr + 0x26)
            + memory.read_s8(spr + 0x29) + memory.read_s16_le(0x02021bbe)
            - memory.read_s16_le(spr + 0x26),
        active)
end

say("=== turn/door probe start ===")

MESHGHOST_DEV_TICK = function()
    frames = frames + 1
    local s = sample()
    if s ~= last then
        last = s
        say(string.format("f=%d %s", frames, s))
    end
    if frames % 60 == 0 and #pending > 0 and logfile then
        logfile:write(table.concat(pending, "\n"), "\n")
        logfile:flush()
        pending = {}
    end
end

MESHGHOST_DEV_UNLOAD = function()
    if logfile then
        if #pending > 0 then logfile:write(table.concat(pending, "\n"), "\n") end
        logfile:write("=== turn/door probe stop ===\n")
        logfile:close()
        logfile = nil
    end
end
