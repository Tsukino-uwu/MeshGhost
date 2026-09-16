-- Phase 1 read-only verification probe. Prints local player X/Y and map bank/number
-- every 15 frames (~4/sec at 60fps) so they can be watched against known-direction motion.
-- Never writes memory.
--
-- Address source: pret/pokeemerald, built locally 2026-08-11 from a checkout matching
-- ROM SHA1 F3AE088181BF583E55DAF962A92BB46F4F1D07B7 (`make compare` -> "pokeemerald.gba: OK").
-- gSaveBlock1Ptr = 0x03005d8c, confirmed independently in both pokeemerald.map and
-- pokeemerald.sym from that build.
--
-- SaveBlock1 position and map-location offsets: looked up in include/global.h (struct
-- SaveBlock1); the code below holds the values, and this probe's on-screen test checks them.
--
-- gSaveBlock1Ptr is a pointer (the save block can relocate), so it is re-read every frame
-- rather than cached.
--
-- gPlayerAvatar = 0x02037590, confirmed the same way (pokeemerald.map + pokeemerald.sym,
-- same build; sym size 0x24 matches the struct's fields summed by hand). Unlike
-- gSaveBlock1Ptr, this is a plain global struct, not a pointer.
-- PlayerAvatar fields read here (flags with its dash bit, runningState, objectEventId): offsets
-- and meanings looked up in struct PlayerAvatar, include/global.fieldmap.h -- hypotheses this
-- probe's on-screen test checks.
--
-- gObjectEvents = 0x02037350, confirmed the same way (pokeemerald.map + pokeemerald.sym,
-- same build; sym size 0x240 = 16 * 0x24). Player's entry is taken as
-- gObjectEvents[gPlayerAvatar.objectEventId], each entry 0x24 bytes.
-- facingDirection (where to look: struct ObjectEvent, include/global.fieldmap.h; DIR_* in
--   constants/global.h) -- offset, low-4-bit packing and the 1-4 = down/up/left/right values are
--   NOT YET CONFIRMED ON SCREEN. Bitfield packing order is a compiler convention, not guaranteed,
--   so this needs the same known-direction test as everything else before it's trusted.

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
