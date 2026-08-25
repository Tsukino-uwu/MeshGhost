-- MeshGhost -- no clip: walk through anything (DEV TOOL, never shipped)
--
-- WHY. Reaching a state costs the user's time, and `agent_docs/playing.md` allows cheating to get
-- there -- collision edits explicitly. Warping lands you at a map's warp tile; getting from there
-- to the water, the ledge or the corner a test actually needs is the slow part.
--
-- HOW, and it is one field rather than a patched function. Every block of the live map grid is a
-- 16-bit word: metatile id in bits 0-9, COLLISION in bits 10-11, elevation in bits 12-15
-- (include/global.fieldmap.h:6-12). `MapGridGetCollisionAt` (fieldmap.c:327) returns those two
-- bits and is the first thing both collision paths ask -- `GetCollisionAtCoords` and its
-- movement-script twin (event_object_movement.c:4663, 4680). Zero those bits and the tile is
-- walkable, because as far as the game is concerned it always was.
--
-- ONLY A WINDOW AROUND THE PLAYER, re-applied every frame. The whole grid would be thousands of
-- reads a frame in Lua, and a probe that costs frame rate is a probe that changes what it is
-- measuring (`_template/probes.md`). Collision is only ever asked about the tile being stepped
-- into, so a few tiles of margin is the same cheat for a fraction of the cost. It is re-applied
-- rather than done once because the engine streams fresh blocks in from ROM as the camera scrolls.
--
-- WHAT IT DOES NOT DO. A block whose id is MAPGRID_UNDEFINED (0x03FF) reports collision whatever
-- its bits say, so the map's outer border still stops you -- you cannot walk off the world. Ledges
-- and one-way tiles go through `IsMetatileDirectionallyImpassable`, which reads the tileset's
-- behaviour bytes in ROM and is untouched here: a ledge still hops you rather than letting you
-- walk up it.
--
-- REVERSIBLE. Every word it changes is remembered and put back when the loader drops it. A map
-- change throws the record away instead -- the new map's grid is rebuilt from ROM, so there is
-- nothing of the old one left to restore.
--
-- ADDRESSES, from our own make-compare-verified pokeemerald build, the same ones watertile.lua
-- uses: gBackupMapLayout 03005DC0 { s32 width 0x00, s32 height 0x04, u16 *map 0x08 },
-- gPlayerAvatar 02037590 { objectEventId 0x05 }, gObjectEvents 02037350 stride 0x24
-- { currentCoords 0x10 }, gSaveBlock1Ptr 03005D8C { location 0x04 }.
--
-- HOW TO RUN. Add it to dev-scripts/bizhawk-dev-loader-emerald.target; remove that line to put
-- every tile back.

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
        -- Only if the word is still the one we left: a block the game has since rewritten is not
        -- ours to put back, and stamping an old metatile id into it would be a visible corruption.
        if u16(t.addr) == t.now then memory.write_u16_le(t.addr, t.was) n = n + 1 end
    end
    touched = {}
    return n
end

local function tick()
    local sb1 = u32(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then return end
    -- struct SaveBlock1: pos 0x00, location 0x04 { s8 mapGroup, s8 mapNum, ... }
    local here = u8(sb1 + 0x04) * 256 + u8(sb1 + 0x05)
    if here ~= where then
        -- A NEW MAP MEANS A NEW GRID, built from ROM. Nothing of ours survived into it, so the
        -- record is dropped rather than written back over somebody else's tiles.
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
                    -- A block we already own reads back as what we left; anything else means the
                    -- engine streamed a NEW tile into that slot as the camera scrolled, and it is
                    -- that one we now have to be able to put back. Keeping the first `was` would
                    -- restore a metatile id belonging to somewhere else entirely.
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

console.log("noclip: ON -- collision cleared around the player. Drop this line from the loader "
    .. "target to put every tile back.")

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function()
        console.log(("noclip: OFF -- restored %d of %d tiles"):format(restore(), cleared))
    end
else
    while true do tick() emu.frameadvance() end
end
