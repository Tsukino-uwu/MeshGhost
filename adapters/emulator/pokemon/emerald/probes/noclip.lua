-- MeshGhost -- no clip: walk through anything (DEV TOOL, never shipped)
--
-- WHY. Reaching a state costs the user's time, and `.claude/skills/play-game/SKILL.md` allows cheating to get
-- there -- collision edits explicitly. Warping lands you at a map's warp tile; getting from there
-- to the water, the ledge or the corner a test actually needs is the slow part.
--
-- HOW, and it is one field rather than a patched function. Each block of the live map grid is
-- taken to be a 16-bit word with metatile id, collision and elevation bits (where to look: the
-- MAPGRID_* masks, include/global.fieldmap.h:6-12; the collision paths start at
-- `MapGridGetCollisionAt`, fieldmap.c:327, and event_object_movement.c:4663, 4680). The
-- hypothesis this tool runs on: zero the collision bits and the tile is walkable.
--
-- ONLY A WINDOW AROUND THE PLAYER, re-applied every frame. The whole grid would be thousands of
-- reads a frame in Lua, and a probe that costs frame rate is a probe that changes what it is
-- measuring (`_template/probes.md`). Collision is only ever asked about the tile being stepped
-- into, so a few tiles of margin is the same cheat for a fraction of the cost. It is re-applied
-- rather than done once because the engine streams fresh blocks in from ROM as the camera scrolls.
--
-- AND NPCs, WHICH ARE A SECOND CHECK ENTIRELY (2026-09-12, the user: *"i want it to affect npc's as
-- well, i keep walking into one"*). The decomp suggests object collision is a separate path that
-- is skipped between objects at different non-zero elevations (where to look:
-- `DoesObjectCollideWithObjectAt`, event_object_movement.c:4724, and `AreElevationsCompatible`,
-- :7789). That is the hypothesis this tool runs on -- the engine's own mechanism, not a patched
-- check -- and walking through an NPC with it loaded is what tests it.
--
-- So every non-player object is put on an elevation the player is not on, and put back on unload.
-- The value is chosen from the ODD elevations, which all share `sElevationToSubpriority`'s 115
-- (:7725) -- so the NPC keeps the draw order it had, and the only thing that changes is whether it
-- blocks. Elevation is the LOW NIBBLE of the object event's +0x0B, which is where this adapter
-- already reads it.
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
    -- An odd elevation the player is not standing on, so subpriority is unchanged and the two can
    -- never compare equal. Never 0: that is ELEVATION_TRANSITION, which is compatible with
    -- everything and would block exactly as before.
    local want = (pElev == 3) and 1 or 3
    for slot = 0, OBJ_SLOTS - 1 do
        local o = GOBJECTEVENTS_ADDR + slot * OBJECTEVENT_SIZE
        local active = (memory.read_u8(o) & 0x01) ~= 0
        if active and slot ~= playerObj then
            local byte = memory.read_u8(o + 0x0b)
            if (byte & 0x0f) ~= want then
                -- Remember the FIRST value only: the engine rewrites this as an NPC changes
                -- elevation, and keeping the latest would restore one of ours.
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
