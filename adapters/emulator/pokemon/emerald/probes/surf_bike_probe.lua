-- MeshGhost — the avatar flags and the frames per tile on foot, surfing and on both bikes (dev tool, read-only, never
-- shipped). Logs each change of PlayerAvatar.flags as set bit numbers, and the frame gap at every tile commit, to the
-- console; walk, surf and ride each bike a few tiles. Finds the avatar block on vanilla and the Archipelago ROM.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284
local MAP_GROUPS_COUNT = 34

-- A copy of meshghost_emerald.lua's tryDetectAvatarAddrOffset().
local function playerObjEventExistsAt(gObjectEventsBase)
    for i = 0, 15 do
        local addr = gObjectEventsBase + i * OBJECTEVENT_SIZE
        local isPlayerBit = memory.read_u8(addr + 0x02) & 0x1
        local localId = memory.read_u8(addr + 0x08)
        local mapGroup = memory.read_u8(addr + 0x0a)
        if isPlayerBit == 1 and localId == 0xff and mapGroup < MAP_GROUPS_COUNT then
            return true
        end
    end
    return false
end

local avatarAddrOffset = 0
local avatarAddrConfirmed = false
local function tryDetectAvatarAddrOffset()
    if playerObjEventExistsAt(GOBJECTEVENTS_ADDR) then
        avatarAddrOffset = 0
        avatarAddrConfirmed = true
        console.log("surf_bike_probe: gObjectEvents/gPlayerAvatar found at the vanilla address.")
    elseif playerObjEventExistsAt(GOBJECTEVENTS_ADDR + AVATAR_ADDR_ARCHIPELAGO_SHIFT) then
        avatarAddrOffset = AVATAR_ADDR_ARCHIPELAGO_SHIFT
        avatarAddrConfirmed = true
        console.log("surf_bike_probe: gObjectEvents/gPlayerAvatar found at the known Archipelago-shifted address.")
    end
end

-- Bit numbers, not names: which bit means what is what a run shows.
local function decodeFlags(flags)
    local parts = {}
    for i = 0, 7 do
        if (flags & (1 << i)) ~= 0 then
            parts[#parts + 1] = string.format("bit%d", i)
        end
    end
    if #parts == 0 then return "(none)" end
    return table.concat(parts, "|")
end

local frameCounter = 0
local lastFlags = nil
local committedTileX, committedTileY = nil, nil
local tileChangeFrame = 0

local function runFrame()
    frameCounter = frameCounter + 1

    if not avatarAddrConfirmed then
        tryDetectAvatarAddrOffset()
        return
    end

    local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if base == 0 then return end
    local rawX = memory.read_s16_le(base + 0x00)
    local rawY = memory.read_s16_le(base + 0x02)

    local flags = memory.read_u8(GPLAYERAVATAR_ADDR + avatarAddrOffset + 0x00)
    if flags ~= lastFlags then
        console.log(string.format("surf_bike_probe: frame=%d FLAGS CHANGED 0x%02X -> 0x%02X (%s)",
            frameCounter, lastFlags or 0, flags, decodeFlags(flags)))
        lastFlags = flags
    end

    if committedTileX == nil then
        committedTileX, committedTileY = rawX, rawY
        tileChangeFrame = frameCounter
    elseif rawX ~= committedTileX or rawY ~= committedTileY then
        local gap = frameCounter - tileChangeFrame
        console.log(string.format(
            "surf_bike_probe: frame=%d TILE COMMIT gap=%d flags=0x%02X (%s) x=%d y=%d",
            frameCounter, gap, flags, decodeFlags(flags), rawX, rawY))
        committedTileX, committedTileY = rawX, rawY
        tileChangeFrame = frameCounter
    end
end

console.log("surf_bike_probe: running. Walk/surf/Mach-Bike/Acro-Bike a few tiles each, then copy the console output.")

local function step()
    local ok, err = pcall(runFrame)
    if not ok then
        console.log("surf_bike_probe: frame error (continuing): " .. tostring(err))
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = step
else
    while true do
        step()
        emu.frameadvance()
    end
end
