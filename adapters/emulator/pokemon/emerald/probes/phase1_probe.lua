-- Phase 1: prints the local player's x/y, map, avatar flags and facing whenever they change, to watch against motion
-- in a known direction. Reads only. gSaveBlock1Ptr is re-read every frame because the save block can move.

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
