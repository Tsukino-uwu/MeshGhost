-- Read-only probe, not part of the shipped adapter. Investigates two open questions from
-- agent_docs/status.md's 2026-08-14 "surf/Mach Bike/Acro Bike" next-step entry:
--
-- (1) Does PLAYER_AVATAR_FLAG_MACH_BIKE/_ACRO_BIKE/_SURFING (bits 1/2/3 on the same
--     PlayerAvatar.flags byte meshghost_emerald.lua already reads for the dash bit, bit 7 --
--     pokeemerald's real include/global.fieldmap.h:288-295) actually behave as documented on
--     this real Archipelago-patched ROM, the same "bitfields need an on-screen check" rule
--     agent_docs/pitfalls.md already states.
-- (2) What is the REAL per-tile frame duration for surfing/Mach Bike/Acro Bike -- measured the
--     same way walking (16) and running (8) were: log the real frame gap between consecutive
--     whole-tile position commits (gSaveBlock1Ptr x/y), per mode, and look for a clean,
--     repeated, near-zero-variance number the same way those two were confirmed.
--
-- Never writes memory. Logs only on a flag-byte CHANGE (not every frame) plus once per real
-- tile-position commit, to stay readable across a real multi-minute test covering all three
-- modes plus normal walking/running as a sanity baseline.
--
-- How to use: load this script (Lua Console -> Script -> Open Script), then in-game: walk a
-- few tiles normally (baseline), surf a few tiles, ride the Mach Bike a few tiles, ride the
-- Acro Bike a few tiles (plain riding is enough -- wheelies are a separate, later question).
-- Copy the full console output back.

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24
local AVATAR_ADDR_ARCHIPELAGO_SHIFT = 0x284
local MAP_GROUPS_COUNT = 34

-- Same live-detection logic as meshghost_emerald.lua's tryDetectAvatarAddrOffset() --
-- duplicated here rather than shared, since this is a standalone throwaway probe, not shipped
-- code. See that function's own comments for the full derivation/citation.
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

-- pokeemerald include/global.fieldmap.h:288-295 -- real cited bit layout of PlayerAvatar.flags.
local FLAG_NAMES = {
    { bit = 0x01, name = "ON_FOOT" },
    { bit = 0x02, name = "MACH_BIKE" },
    { bit = 0x04, name = "ACRO_BIKE" },
    { bit = 0x08, name = "SURFING" },
    { bit = 0x10, name = "UNDERWATER" },
    { bit = 0x20, name = "CONTROLLABLE" },
    { bit = 0x40, name = "FORCED_MOVE" },
    { bit = 0x80, name = "DASH" },
}

local function decodeFlags(flags)
    local parts = {}
    for _, f in ipairs(FLAG_NAMES) do
        if (flags & f.bit) ~= 0 then
            parts[#parts + 1] = f.name
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
while true do
    local ok, err = pcall(runFrame)
    if not ok then
        console.log("surf_bike_probe: frame error (continuing): " .. tostring(err))
    end
    emu.frameadvance()
end
