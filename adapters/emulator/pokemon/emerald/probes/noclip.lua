-- MeshGhost — Emerald: no clip (dev tool, writes the map grid and NPC elevations, vanilla only, never shipped).
-- Every frame it clears collision on the grid within RADIUS tiles of the player, since the engine streams blocks
-- back in from ROM as the camera scrolls, and puts each other object on an elevation the player is not on, which
-- object collision skips. Map borders and ledges are left alone. Dropping it from the loader target restores both.

local GBACKUPMAPLAYOUT = 0x03005dc0
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local MAPGRID_COLLISION_MASK = 0x0c00
local MAPGRID_METATILE_ID_MASK = 0x03ff
local MAPGRID_UNDEFINED = 0x03ff

local RADIUS = 6 -- tiles either side of the player; a step only ever asks about the next tile

local function u8(a) return memory.read_u8(a) end
local function u16(a) return memory.read_u16_le(a) end
local function s16(a) return memory.read_s16_le(a) end
local function u32(a) return memory.read_u32_le(a) end
local function s32(a) return memory.read_s32_le(a) end

local touched, where, cleared = {}, nil, 0

local function gridAddr(x, y)
    local width, height = s32(GBACKUPMAPLAYOUT + 0x00), s32(GBACKUPMAPLAYOUT + 0x04)
    local map = u32(GBACKUPMAPLAYOUT + 0x08)
    if map == 0 or width <= 0 or x < 0 or y < 0 or x >= width or y >= height then return nil end
    return map + (x + width * y) * 2
end

local function restore()
    local n = 0
    for _, t in pairs(touched) do
        -- Only a word still as we left it: a block the game has rewritten since is not ours to put back.
        if u16(t.addr) == t.now then memory.write_u16_le(t.addr, t.was) n = n + 1 end
    end
    touched = {}
    return n
end

local function tick()
    local sb1 = u32(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then return end
    local here = u8(sb1 + 0x04) * 256 + u8(sb1 + 0x05)
    if here ~= where then
        -- A new map's grid is rebuilt from ROM: drop the record rather than write it over the new tiles.
        touched, where, cleared = {}, here, 0
    end

    local objId = u8(GPLAYERAVATAR_ADDR + 0x05)
    if objId > 15 then return end
    local a = GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE
    local px, py = s16(a + 0x10), s16(a + 0x12)

    for y = py - RADIUS, py + RADIUS do
        for x = px - RADIUS, px + RADIUS do
            local addr = gridAddr(x, y)
            if addr then
                local block = u16(addr)
                if (block & MAPGRID_COLLISION_MASK) ~= 0
                    and (block & MAPGRID_METATILE_ID_MASK) ~= MAPGRID_UNDEFINED
                then
                    local now = block & (~MAPGRID_COLLISION_MASK & 0xffff)
                    -- Not as we left it means the engine streamed a new block in as the camera scrolled:
                    -- record that one, or a restore would stamp in another place's metatile.
                    local rec = touched[addr]
                    if not rec or rec.now ~= block then
                        touched[addr] = { addr = addr, was = block, now = now }
                        cleared = cleared + 1
                    end
                    memory.write_u16_le(addr, now)
                end
            end
        end
    end
end

-- ===== NPCs: a different elevation, so nothing blocks =====
local GOBJECTEVENTS_ADDR = 0x02037350
local GPLAYERAVATAR_ADDR = 0x02037590
local OBJECTEVENT_SIZE = 0x24
local OBJ_SLOTS = 16
local elevWas = {}

local function elevTick()
    local ok, playerObj = pcall(memory.read_u8, GPLAYERAVATAR_ADDR + 0x05)
    if not ok then return end
    local pElevByte = memory.read_u8(GOBJECTEVENTS_ADDR + playerObj * OBJECTEVENT_SIZE + 0x0b)
    local pElev = pElevByte & 0x0f
    -- An odd elevation the player is not on, so draw order holds and the two never match; never 0, the transition
    -- elevation, which is compatible with everything and would still block.
    local want = (pElev == 3) and 1 or 3
    for slot = 0, OBJ_SLOTS - 1 do
        local o = GOBJECTEVENTS_ADDR + slot * OBJECTEVENT_SIZE
        local active = (memory.read_u8(o) & 0x01) ~= 0
        if active and slot ~= playerObj then
            local byte = memory.read_u8(o + 0x0b)
            if (byte & 0x0f) ~= want then
                -- First value only: the engine rewrites it as an NPC changes elevation, so the latest may be ours.
                if elevWas[slot] == nil then elevWas[slot] = byte & 0x0f end
                memory.write_u8(o + 0x0b, (byte & 0xf0) | want)
            end
        end
    end
end

local function elevRestore()
    local n = 0
    for slot, was in pairs(elevWas) do
        local o = GOBJECTEVENTS_ADDR + slot * OBJECTEVENT_SIZE
        local okr, byte = pcall(memory.read_u8, o + 0x0b)
        if okr then
            pcall(memory.write_u8, o + 0x0b, (byte & 0xf0) | was)
            n = n + 1
        end
    end
    elevWas = {}
    return n
end

console.log("noclip: ON -- collision cleared around the player, and NPCs put on another elevation. "
    .. "Drop this line from the loader target to put every tile and every NPC back.")

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = function() tick() elevTick() end
    MESHGHOST_DEV_UNLOAD = function()
        console.log(("noclip: OFF -- restored %d of %d tiles and %d NPC elevations")
            :format(restore(), cleared, elevRestore()))
    end
else
    while true do tick() elevTick() emu.frameadvance() end
end
