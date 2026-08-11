-- Phase 1 read-only verification probe. Prints local player X/Y and map bank/number
-- every 15 frames (~4/sec at 60fps) so they can be watched against known-direction motion.
-- Never writes memory.
--
-- Address source: pret/pokeemerald, built locally 2026-08-11 from a checkout matching
-- ROM SHA1 F3AE088181BF583E55DAF962A92BB46F4F1D07B7 (`make compare` -> "pokeemerald.gba: OK").
-- gSaveBlock1Ptr = 0x03005d8c, confirmed independently in both pokeemerald.map and
-- pokeemerald.sym from that build.
--
-- SaveBlock1 layout (include/global.h L984-991, L174-178, L581-587):
--   +0x00 pos.x        s16
--   +0x02 pos.y        s16
--   +0x04 location.mapGroup  s8
--   +0x05 location.mapNum    s8
--
-- gSaveBlock1Ptr is a pointer (the save block can relocate), so it is re-read every frame
-- rather than cached.
--
-- gPlayerAvatar = 0x02037590, confirmed the same way (pokeemerald.map + pokeemerald.sym,
-- same build; sym size 0x24 matches the struct's fields summed by hand). Unlike
-- gSaveBlock1Ptr, this is a plain global struct, not a pointer.
-- PlayerAvatar layout (include/global.fieldmap.h L342-362, flag bits L288-295):
--   +0x00 flags          u8   (bit 7 = PLAYER_AVATAR_FLAG_DASH, i.e. running-shoes dash)
--   +0x02 runningState   u8   (0 = not moving, 1 = turning, 2 = moving)
--   +0x05 objectEventId  u8   (index into gObjectEvents for the player's own entry)
--
-- gObjectEvents = 0x02037350, confirmed the same way (pokeemerald.map + pokeemerald.sym,
-- same build; sym size 0x240 = 16 * 0x24, matching OBJECT_EVENTS_COUNT (16, constants/
-- global.h L46) * sizeof(struct ObjectEvent). Player's entry is
-- gObjectEvents[gPlayerAvatar.objectEventId], each entry 0x24 bytes.
-- ObjectEvent layout (include/global.fieldmap.h L194-256):
--   +0x18 facingDirection  u16:4 (low 4 bits) -- NOT YET CONFIRMED ON SCREEN. Bitfield packing
--   order is a compiler convention, not guaranteed, so this needs the same known-direction
--   test as everything else before it's trusted. Values per constants/global.h L137-141:
--   DIR_SOUTH=1 (down), DIR_NORTH=2 (up), DIR_WEST=3 (left), DIR_EAST=4 (right).

local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24

if not memory.usememorydomain("System Bus") then
    console.log("ERROR: 'System Bus' memory domain not found on this core.")
    console.log("Domains available: " .. memory.getmemorydomainlist())
    return
end

console.log("MeshGhost Phase 1 probe running. Reading gSaveBlock1Ptr @ 0x" .. string.format("%08X", GSAVEBLOCK1PTR_ADDR))
console.log("Only prints when x/y/map changes - stand still and it will go quiet.")

local lastLine = nil

while true do
    local base = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    local line
    if base == 0 then
        line = "gSaveBlock1Ptr is null (no save loaded / not in-game yet)"
    else
        local x = memory.read_s16_le(base + 0x00)
        local y = memory.read_s16_le(base + 0x02)
        local mapGroup = memory.read_s8(base + 0x04)
        local mapNum = memory.read_s8(base + 0x05)
        local flags = memory.read_u8(GPLAYERAVATAR_ADDR + 0x00)
        local runningState = memory.read_u8(GPLAYERAVATAR_ADDR + 0x02)
        local objectEventId = memory.read_u8(GPLAYERAVATAR_ADDR + 0x05)
        local dashing = (flags & 0x80) ~= 0
        local objEventAddr = GOBJECTEVENTS_ADDR + (objectEventId * OBJECTEVENT_SIZE)
        local facingRaw = memory.read_u16_le(objEventAddr + 0x18)
        local facingDirection = facingRaw & 0xF
        line = string.format(
            "base=0x%08X  x=%d  y=%d  mapGroup=%d  mapNum=%d  flags=0x%02X  dash=%s  runningState=%d  objEventId=%d  facingDirection=%d",
            base, x, y, mapGroup, mapNum, flags, tostring(dashing), runningState, objectEventId, facingDirection)
    end
    if line ~= lastLine then
        console.log(line)
        lastLine = line
    end
    emu.frameadvance()
end
